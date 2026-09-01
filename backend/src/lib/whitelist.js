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
	file.data.WhitelistedUsers = file.data.WhitelistedUsers || {};
	file.data.WhitelistedUsers[key] = {
		hash: await playerHash(robloxUsername, robloxUserId),
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

export { upsertWhitelistEntry, removeWhitelistEntry, playerHash, entryKey, TAGS };
