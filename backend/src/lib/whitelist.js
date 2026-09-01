// Writes the player whitelist the Roblox clients actually read.
//
// Clients never talk to this API for their rank. They poll a plain JSON file on GitHub's
// raw CDN every ten seconds - see whitelist:update in the game source. That keeps the
// per-client cost at zero requests against us no matter how many people are injected,
// which an API endpoint could not survive on the free tier. This module is the other
// half: the bot owns the file, and Discord roles are what decide its contents.
//
// The client hashes a player as sha512(Name .. UserId .. "SelfReport") and compares that
// against every entry, so the file gives away nobody's identity. The key each entry sits
// under is never read by the client at all - it exists purely so this code can find an
// entry again to update or delete it - so it is hashed too rather than left as a
// plaintext Discord id the way Vape's file does it.

import { getGuildMemberRoles } from './discord.js';
import { getRankConfig } from './db.js';
import { rankFromRoles } from './ranks.js';

const REPO = 'VainRoblox/whitelist';
const PATH = 'PlayerWhitelist.json';
const SALT = 'SelfReport';

// Rank level -> the tag drawn over that player in game. Level 0 never gets an entry.
const TAGS = {
	1: { text: 'PREMIUM', color: [90, 200, 255] },
	2: { text: 'PRIVILEGED', color: [190, 120, 255] },
	3: { text: 'OWNER', color: [255, 60, 60] },
};

async function sha512Hex(input) {
	const digest = await crypto.subtle.digest('SHA-512', new TextEncoder().encode(input));
	return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// Must match the game exactly: plr.Name .. plr.UserId .. 'SelfReport'. The name is the
// canonical casing Roblox reports, not whatever was typed into the command, which is why
// callers pass the resolved username rather than the raw argument.
function playerHash(robloxUsername, robloxUserId) {
	return sha512Hex(`${robloxUsername}${robloxUserId}${SALT}`);
}

function entryKey(discordId) {
	return sha512Hex(`${discordId}${SALT}`);
}

function ghHeaders(env) {
	return {
		Authorization: `Bearer ${env.GITHUB_TOKEN}`,
		Accept: 'application/vnd.github+json',
		'User-Agent': 'vain-api',
		'X-GitHub-Api-Version': '2022-11-28',
	};
}

// Reads the file plus the blob sha GitHub needs back on write to detect a conflicting
// edit. Returns null on any failure so callers refuse to write rather than clobbering
// the live whitelist with a file rebuilt from nothing.
async function readWhitelist(env) {
	const res = await fetch(`https://api.github.com/repos/${REPO}/contents/${PATH}`, {
		headers: ghHeaders(env),
	});
	if (!res.ok) return null;

	const body = await res.json();
	try {
		return { data: JSON.parse(atob(body.content.replace(/\n/g, ''))), sha: body.sha };
	} catch {
		return null;
	}
}

async function writeWhitelist(env, data, sha, message) {
	// btoa cannot take multi-byte characters, and a tag could contain one.
	const json = JSON.stringify(data, null, '\t') + '\n';
	const bytes = new TextEncoder().encode(json);
	const content = btoa(String.fromCharCode(...bytes));

	const res = await fetch(`https://api.github.com/repos/${REPO}/contents/${PATH}`, {
		method: 'PUT',
		headers: { ...ghHeaders(env), 'Content-Type': 'application/json' },
		body: JSON.stringify({ message, content, sha }),
	});
	return res.ok;
}

// Adds or updates one member. Level 0 is not whitelisted, so it removes instead - that
// is what makes losing the Discord role actually take effect rather than leaving a stale
// entry behind forever.
async function upsertWhitelistEntry(env, { discordId, robloxUsername, robloxUserId, level }) {
	if (!env.GITHUB_TOKEN) return { ok: false, error: 'no_token' };
	if (level < 1) return await removeWhitelistEntry(env, discordId);

	const file = await readWhitelist(env);
	if (!file) return { ok: false, error: 'read_failed' };

	const key = await entryKey(discordId);
	const hash = await playerHash(robloxUsername, robloxUserId);
	file.data.WhitelistedUsers = file.data.WhitelistedUsers || {};

	// One entry per player, whoever wrote it. Two entries sharing a hash is a state the
	// client should never have to reason about, so stale ones for this player are cleared
	// rather than left to accumulate - e.g. an account that was linked under a different
	// Discord id before.
	for (const [existingKey, entry] of Object.entries(file.data.WhitelistedUsers)) {
		if (entry?.hash === hash && existingKey !== key) delete file.data.WhitelistedUsers[existingKey];
	}

	file.data.WhitelistedUsers[key] = {
		hash,
		level,
		attackable: false,
		tags: TAGS[level] ? [TAGS[level]] : [],
	};

	const ok = await writeWhitelist(env, file.data, file.sha, `Whitelist ${robloxUsername} at level ${level}`);
	return ok ? { ok: true, level } : { ok: false, error: 'write_failed' };
}

async function removeWhitelistEntry(env, discordId) {
	if (!env.GITHUB_TOKEN) return { ok: false, error: 'no_token' };

	const file = await readWhitelist(env);
	if (!file) return { ok: false, error: 'read_failed' };

	const key = await entryKey(discordId);
	if (!file.data.WhitelistedUsers?.[key]) return { ok: true, level: 0, unchanged: true };

	delete file.data.WhitelistedUsers[key];
	const ok = await writeWhitelist(env, file.data, file.sha, 'Remove a whitelist entry');
	return ok ? { ok: true, level: 0 } : { ok: false, error: 'write_failed' };
}

/*
	Rewrites the whole file from what Discord currently says, on a schedule.

	A rank is otherwise only written when somebody runs /whitelist edit, which means
	losing a role revokes nothing: the entry sits there at the old level indefinitely and
	the only way to take it back is to ask the person to unlink themselves. Demotions and
	people leaving the server have to take effect on their own.

	Every binding is re-resolved and the file written once at the end, so a run costs one
	commit rather than one per member. A member Discord will not answer about is left
	exactly as they are - a rate limit or an outage is not evidence that anybody lost a
	role, and treating it as such would wipe the whitelist over a hiccup.
*/
async function syncWhitelist(env) {
	if (!env.GITHUB_TOKEN || !env.DISCORD_BOT_TOKEN) return;

	const bindings = await env.DB.prepare('SELECT discord_id, roblox_username, roblox_userid FROM bindings').all();
	const rows = bindings?.results ?? [];
	if (!rows.length) return;

	const file = await readWhitelist(env);
	if (!file) return;

	const rankConfigRows = await getRankConfig(env.DB, env.DISCORD_GUILD_ID);
	const users = file.data.WhitelistedUsers || {};
	let changed = 0;

	for (const row of rows) {
		const roleIds = await getGuildMemberRoles(env.DISCORD_GUILD_ID, row.discord_id, env.DISCORD_BOT_TOKEN);
		if (roleIds === null) continue; // could not ask - leave them alone

		const level = roleIds === 'not_member' ? 0 : rankFromRoles(roleIds, rankConfigRows);
		const key = await entryKey(row.discord_id);
		const current = users[key];

		if (level < 1) {
			if (current) {
				delete users[key];
				changed++;
			}
			continue;
		}

		if (current?.level === level) continue;

		users[key] = {
			hash: await playerHash(row.roblox_username, row.roblox_userid),
			level,
			attackable: false,
			tags: TAGS[level] ? [TAGS[level]] : [],
		};
		changed++;
	}

	if (!changed) return;

	file.data.WhitelistedUsers = users;
	await writeWhitelist(env, file.data, file.sha, `Sync ${changed} whitelist ${changed === 1 ? 'entry' : 'entries'} with Discord roles`);
}


export { upsertWhitelistEntry, removeWhitelistEntry, syncWhitelist, playerHash, entryKey, TAGS };
