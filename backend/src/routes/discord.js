import { verifyDiscordRequest, replyMessage, postMessage, editMessage, followUpOriginal } from '../lib/discord.js';
import { lookupUserId, lookupUserIds, getAvatarThumbnails } from '../lib/roblox.js';
import {
	upsertBinding,
	deleteBindingByDiscordId,
	getRankConfig,
	getRosterMessage,
	setRosterMessage,
	getTargetMessage,
	setTargetMessage,
} from '../lib/db.js';
import { rankFromRoles } from '../lib/ranks.js';
import { upsertWhitelistEntry, removeWhitelistEntry } from '../lib/whitelist.js';
import {
	upsertAccount,
	removeAccount,
	setHas2fa,
	resetAllRanks,
	getAccount,
	getAccountInUseByUser,
	setInUse,
	clearInUse,
	listAccounts,
	searchAccountNames,
	buildRosterEmbed,
	addKit,
	removeKit,
	listKitsForAccount,
	listAccountsWithKit,
	addWish,
	removeWish,
	listWishlist,
} from '../lib/roster.js';
import { searchKits } from '../lib/kits.js';
import { addTarget, removeTarget, listTargets, searchTargetNames, buildTargetsEmbeds, MAX_TARGET_THUMBNAILS } from '../lib/targets.js';

// Only members holding this role can run /add /remove /update /use /done (and, reusing
// the same role, /addtarget /removetarget). Discord's own default_member_permissions
// only understands built-in permission bits, not arbitrary custom roles, so this has to
// be enforced here in code.
const ROSTER_ROLE_ID = '1537821596977340416';
const ROSTER_CHANNEL_ID = '1537805418728919086';
const TARGET_CHANNEL_ID = '1538506373879439430';

function getOption(options, name) {
	return options?.find((o) => o.name === name)?.value;
}

function hasRosterRole(interaction) {
	return (interaction.member?.roles ?? []).includes(ROSTER_ROLE_ID);
}

// The 'Unranked' dropdown choice is a sentinel, not a real tier - normalize it (and a
// missing value, just in case) to the same empty-rank representation roster.js already
// uses to mean "no rank, show no emoji."
function normalizeRank(rank) {
	return rank && rank !== 'unranked' ? rank : '';
}

// One shot: binds discordId to the given Roblox username immediately and hands back
// the key. No proof-of-ownership step (no code-in-profile, no waiting) - this is safe
// because rank is never derived from the Roblox account claimed here, only from
// discordId's real (Discord-signed) role membership at command time. Worst case if
// someone types in a Roblox username that isn't really theirs: their own already-real
// rank ends up attributed to the wrong roblox_userid in logs - it can't grant anyone a
// rank they don't actually hold on Discord.
// Links a Discord account to a Roblox one, and writes that account into the whitelist
// file the game clients read.
//
// The rank is taken from the caller's own Discord roles, never from anything they type,
// so the only way to a higher level is to actually hold the role. Someone with no mapped
// role links fine and simply gets no whitelist entry - that is what Free means.
async function handleWhitelistEdit(env, interaction, discordId, username) {
	const lookup = await lookupUserId(username);
	if (!lookup) {
		return replyMessage(`Couldn't find a Roblox user named "${username}".`);
	}

	await upsertBinding(env.DB, {
		discordId,
		robloxUserId: lookup.userId,
		robloxUsername: lookup.username,
		rankLevel: 0, // resolved live from Discord roles on first rank check, not needed here
	});

	const roleIds = interaction.member?.roles ?? [];
	const rankConfigRows = await getRankConfig(env.DB, interaction.guild_id ?? env.DISCORD_GUILD_ID);
	const level = rankFromRoles(roleIds, rankConfigRows);

	// Written under the canonical username Roblox reports rather than the typed one: the
	// game hashes plr.Name, so the wrong casing produces an entry that silently matches
	// nobody.
	const result = await upsertWhitelistEntry(env, {
		discordId,
		robloxUsername: lookup.username,
		robloxUserId: lookup.userId,
		level,
	});

	const RANKS = { 0: 'Free', 1: 'Premium', 2: 'Privileged', 3: 'Owner' };
	let status;
	if (!result.ok) {
		// Say so plainly. A silent failure here looks identical to success until the
		// player loads in and finds they have no rank.
		status = `\n\n**The whitelist file could not be updated (${result.error}), so this rank is not live yet.** Tell an owner.`;
	} else if (level < 1) {
		status = `\n\nYou have no ranked role, so you are **Free** - linked, but not whitelisted.`;
	} else {
		status = `\n\nRank **${RANKS[level]}** is live. Clients pick it up within about ten seconds.`;
	}

	return replyMessage(`Linked! Your Discord account is now bound to Roblox user "${lookup.username}".${status}`);
}

async function handleWhitelistUnlink(env, discordId) {
	await deleteBindingByDiscordId(env.DB, discordId);

	// Take them out of the whitelist too, or unlinking would leave the rank live and the
	// binding gone - the worst of both.
	const result = await removeWhitelistEntry(env, discordId);
	if (!result.ok) {
		return replyMessage(`Unlinked, but the whitelist file could not be updated (${result.error}) - your rank may still be live. Tell an owner.`);
	}
	return replyMessage('Unlinked. Your Roblox account no longer has a rank.');
}

async function syncRosterEmbed(env) {
	const accounts = await listAccounts(env.DB);
	const embed = buildRosterEmbed(accounts);
	const existing = await getRosterMessage(env.DB);

	if (existing) {
		const ok = await editMessage(existing.channel_id, existing.message_id, { embeds: [embed] }, env.DISCORD_BOT_TOKEN);
		if (ok) return true;
	}

	const posted = await postMessage(ROSTER_CHANNEL_ID, { embeds: [embed] }, env.DISCORD_BOT_TOKEN);
	if (posted) {
		await setRosterMessage(env.DB, ROSTER_CHANNEL_ID, posted.id);
		return true;
	}
	return false;
}

const ROSTER_SYNC_FAILED_NOTE =
	"\n\n⚠️ Saved, but I couldn't post/update the roster embed - I likely don't have access to that channel. Check the bot's permissions there (View Channel, Send Messages, Embed Links).";

// Re-resolves every shown target's Roblox avatar fresh each time this runs (i.e. every
// /addtarget or /removetarget), rather than caching it - avatars do change over time and
// this only touches Roblox's public API, not the Discord/Workers request budget.
async function syncTargetEmbed(env) {
	const targets = await listTargets(env.DB);
	const shown = targets.slice(0, MAX_TARGET_THUMBNAILS);
	const resolved = await lookupUserIds(shown.map((t) => t.name));
	const thumbnails = await getAvatarThumbnails(resolved.map((r) => r.userId));
	const avatarUrls = {};
	for (const r of resolved) {
		const url = thumbnails[r.userId];
		if (url) avatarUrls[(r.requestedUsername ?? r.username).toLowerCase()] = url;
	}

	const embeds = buildTargetsEmbeds(targets, avatarUrls);
	const existing = await getTargetMessage(env.DB);

	if (existing) {
		const ok = await editMessage(existing.channel_id, existing.message_id, { embeds }, env.DISCORD_BOT_TOKEN);
		if (ok) return true;
	}

	const posted = await postMessage(TARGET_CHANNEL_ID, { embeds }, env.DISCORD_BOT_TOKEN);
	if (posted) {
		await setTargetMessage(env.DB, TARGET_CHANNEL_ID, posted.id);
		return true;
	}
	return false;
}

const TARGET_SYNC_FAILED_NOTE =
	"\n\n⚠️ Saved, but I couldn't post/update the targets embed - I likely don't have access to that channel. Check the bot's permissions there (View Channel, Send Messages, Embed Links).";

async function handleAddTarget(env, interaction, name, reason) {
	if (!hasRosterRole(interaction)) return replyMessage("You don't have permission to do that.");
	const addedBy = interaction.member.user.id;
	await addTarget(env.DB, name, addedBy, reason);
	const synced = await syncTargetEmbed(env);
	return replyMessage(`Added **${name}** to targets.${synced ? '' : TARGET_SYNC_FAILED_NOTE}`);
}

async function handleRemoveTarget(env, interaction, name) {
	if (!hasRosterRole(interaction)) return replyMessage("You don't have permission to do that.");
	const removed = await removeTarget(env.DB, name);
	if (!removed) return replyMessage(`No target named "${name}" found.`);
	const synced = await syncTargetEmbed(env);
	return replyMessage(`Removed **${name}** from targets.${synced ? '' : TARGET_SYNC_FAILED_NOTE}`);
}

async function handleRosterAdd(env, interaction, name, rank, has2fa) {
	if (!hasRosterRole(interaction)) return replyMessage("You don't have permission to do that.");
	const normalizedRank = normalizeRank(rank);
	await upsertAccount(env.DB, name, normalizedRank, has2fa ?? false);
	const synced = await syncRosterEmbed(env);
	const twofaNote = has2fa ? ' 🔒 has 2FA.' : '';
	return replyMessage(`Added **${name}** (${normalizedRank || 'Unranked'}).${twofaNote}${synced ? '' : ROSTER_SYNC_FAILED_NOTE}`);
}

async function handleRosterRemove(env, interaction, name) {
	if (!hasRosterRole(interaction)) return replyMessage("You don't have permission to do that.");
	const removed = await removeAccount(env.DB, name);
	if (!removed) return replyMessage(`No account named "${name}" found.`);
	const synced = await syncRosterEmbed(env);
	return replyMessage(`Removed **${name}**.${synced ? '' : ROSTER_SYNC_FAILED_NOTE}`);
}

async function handleRosterUpdate(env, interaction, name, rank) {
	if (!hasRosterRole(interaction)) return replyMessage("You don't have permission to do that.");
	const existing = await getAccount(env.DB, name);
	if (!existing) return replyMessage(`No account named "${name}" found. Use /add first.`);
	const normalizedRank = normalizeRank(rank);
	await upsertAccount(env.DB, name, normalizedRank);
	const synced = await syncRosterEmbed(env);
	return replyMessage(`Updated **${name}** to ${normalizedRank || 'Unranked'}.${synced ? '' : ROSTER_SYNC_FAILED_NOTE}`);
}

async function handleSet2fa(env, interaction, name, has2fa) {
	if (!hasRosterRole(interaction)) return replyMessage("You don't have permission to do that.");
	const existing = await getAccount(env.DB, name);
	if (!existing) return replyMessage(`No account named "${name}" found.`);
	await setHas2fa(env.DB, name, has2fa);
	const synced = await syncRosterEmbed(env);
	return replyMessage(`Set **${name}**'s 2FA Required to **${has2fa ? 'true' : 'false'}**.${synced ? '' : ROSTER_SYNC_FAILED_NOTE}`);
}

// "A new season begins" - resets every account's rank to Unranked, leaving checkout
// status, kits, 2FA, and wishlist entries untouched.
async function handleReset(env, interaction) {
	if (!hasRosterRole(interaction)) return replyMessage("You don't have permission to do that.");
	const count = await resetAllRanks(env.DB);
	const synced = await syncRosterEmbed(env);
	return replyMessage(`Reset ${count} account${count === 1 ? '' : 's'} to Unranked.${synced ? '' : ROSTER_SYNC_FAILED_NOTE}`);
}

async function handleRosterUse(env, interaction, name) {
	if (!hasRosterRole(interaction)) return replyMessage("You don't have permission to do that.");
	const existing = await getAccount(env.DB, name);
	if (!existing) return replyMessage(`No account named "${name}" found.`);
	const requesterId = interaction.member.user.id;

	if (existing.in_use_by && existing.in_use_by !== requesterId) {
		return replyMessage(`**${name}** is currently used by <@${existing.in_use_by}>.`);
	}

	// One account at a time per person - /done has no parameters and relies on this
	// being true to know which account to release.
	const alreadyHave = await getAccountInUseByUser(env.DB, requesterId);
	if (alreadyHave && alreadyHave.name !== name) {
		return replyMessage(`You already have **${alreadyHave.name}** checked out. Run \`/done\` to release it first.`);
	}

	await setInUse(env.DB, name, requesterId);
	const synced = await syncRosterEmbed(env);
	return replyMessage(`Marked **${name}** as currently used by you.${synced ? '' : ROSTER_SYNC_FAILED_NOTE}`);
}

async function handleRosterDone(env, interaction) {
	if (!hasRosterRole(interaction)) return replyMessage("You don't have permission to do that.");
	const requesterId = interaction.member.user.id;
	const existing = await getAccountInUseByUser(env.DB, requesterId);
	if (!existing) return replyMessage("You don't have any account checked out.");
	await clearInUse(env.DB, existing.name);
	const synced = await syncRosterEmbed(env);
	return replyMessage(`Marked **${existing.name}** as free.${synced ? '' : ROSTER_SYNC_FAILED_NOTE}`);
}

// Kit ownership - separate from the main roster embed on purpose (the user wants it
// only visible via an ephemeral /kits reply, not shown to everyone in the channel).
// /addkit and /removekit are mutations, so role-gated like the other 5; /kits is
// read-only, so open to anyone who can already see the roster embed in this channel.

async function handleAddKit(env, interaction, accountName, kitName) {
	if (!hasRosterRole(interaction)) return replyMessage("You don't have permission to do that.");
	const account = await getAccount(env.DB, accountName);
	if (!account) return replyMessage(`No account named "${accountName}" found.`);
	await addKit(env.DB, accountName, kitName);
	return replyMessage(`Added **${kitName}** to **${accountName}**'s kits.`);
}

async function handleRemoveKit(env, interaction, accountName, kitName) {
	if (!hasRosterRole(interaction)) return replyMessage("You don't have permission to do that.");
	const removed = await removeKit(env.DB, accountName, kitName);
	if (!removed) return replyMessage(`**${accountName}** doesn't have **${kitName}** recorded.`);
	return replyMessage(`Removed **${kitName}** from **${accountName}**'s kits.`);
}

async function handleListKits(env, interaction, accountName) {
	const account = await getAccount(env.DB, accountName);
	if (!account) return replyMessage(`No account named "${accountName}" found.`);
	const kits = await listKitsForAccount(env.DB, accountName);
	if (!kits.length) return replyMessage(`**${accountName}** has no kits recorded yet.`);
	return replyMessage(`**${accountName}**'s kits:\n${kits.map((k) => `• ${k}`).join('\n')}`);
}

async function handleKitOwners(env, interaction, kitName) {
	const owners = await listAccountsWithKit(env.DB, kitName);
	if (!owners.length) return replyMessage(`No accounts have **${kitName}** recorded.`);
	return replyMessage(`Accounts with **${kitName}**:\n${owners.map((n) => `• ${n}`).join('\n')}`);
}

// Wishlist - kits nobody owns yet, optionally with a preferred account to put them on.
// Not role-gated: it's just a suggestion/desire note, not authoritative roster state, so
// anyone in the channel can add to or clear it (same as the read-only kit commands).

async function handleAddWish(env, interaction, kitName, preferredAccount) {
	if (preferredAccount) {
		const account = await getAccount(env.DB, preferredAccount);
		if (!account) return replyMessage(`No account named "${preferredAccount}" found.`);
	}
	const requestedBy = interaction.member.user.id;
	await addWish(env.DB, kitName, preferredAccount ?? null, requestedBy);
	const target = preferredAccount ? ` for **${preferredAccount}**` : '';
	return replyMessage(`Added **${kitName}** to the wishlist${target}.`);
}

async function handleRemoveWish(env, interaction, kitName, preferredAccount) {
	const removed = await removeWish(env.DB, kitName, preferredAccount ?? null);
	if (!removed) return replyMessage(`No matching wishlist entry for **${kitName}**${preferredAccount ? ` (**${preferredAccount}**)` : ''}.`);
	return replyMessage(`Removed **${kitName}**${preferredAccount ? ` (**${preferredAccount}**)` : ''} from the wishlist.`);
}

async function handleWishlist(env) {
	const entries = await listWishlist(env.DB);
	if (!entries.length) return replyMessage('The wishlist is empty.');
	const lines = entries.map(
		(e) => `• **${e.kit_name}**${e.preferred_account ? ` — for **${e.preferred_account}**` : ''} (requested by <@${e.requested_by}>)`
	);
	return replyMessage(`**Kit Wishlist**\n${lines.join('\n')}`);
}

// Reads today's/yesterday's request counts from Cloudflare's Workers Analytics
// (GraphQL) instead of self-counting in D1 - self-counting would mean writing a row on
// every single request, which would double D1 write load right when it's already under
// the most pressure (lots of online clients polling).
const DAILY_REQUEST_BUDGET = 100000;

async function handleStatus(env) {
	const today = new Date().toISOString().slice(0, 10);
	const yesterday = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
	const query = `query {
		viewer {
			accounts(filter: { accountTag: "${env.CLOUDFLARE_ACCOUNT_ID}" }) {
				workersInvocationsAdaptive(
					limit: 2
					filter: { scriptName: "vain-api", date_geq: "${yesterday}", date_leq: "${today}" }
					orderBy: [date_DESC]
				) {
					sum { requests }
					dimensions { date }
				}
			}
		}
	}`;
	const res = await fetch('https://api.cloudflare.com/client/v4/graphql', {
		method: 'POST',
		headers: { Authorization: `Bearer ${env.CLOUDFLARE_ANALYTICS_TOKEN}`, 'Content-Type': 'application/json' },
		body: JSON.stringify({ query }),
	});
	if (!res.ok) return replyMessage("Couldn't reach Cloudflare's Analytics API.");
	const data = await res.json();
	const rows = data?.data?.viewer?.accounts?.[0]?.workersInvocationsAdaptive ?? [];
	const todayRow = rows.find((r) => r.dimensions.date === today);
	const todayCount = todayRow?.sum?.requests ?? 0;
	const pct = ((todayCount / DAILY_REQUEST_BUDGET) * 100).toFixed(1);
	return replyMessage(`**API usage today:** ${todayCount.toLocaleString()} / ${DAILY_REQUEST_BUDGET.toLocaleString()} requests (${pct}%)`);
}

// Live-queries account names (or, for the `kit` option, the static kit catalog) as the
// user types, rather than a static (and immediately stale, or in the kit list's case
// way over Discord's 25-choice cap) `choices` list.
async function handleAutocomplete(env, interaction) {
	const focused = interaction.data.options?.find((o) => o.focused);
	const query = focused?.value ?? '';
	let matches;
	if (focused?.name === 'kit') matches = searchKits(query);
	else if (focused?.name === 'target') matches = await searchTargetNames(env.DB, query);
	else matches = await searchAccountNames(env.DB, query);
	return Response.json({
		type: 8, // APPLICATION_COMMAND_AUTOCOMPLETE_RESULT
		data: { choices: matches.map((n) => ({ name: n, value: n })) },
	});
}

async function handleDiscordInteraction(request, env, ctx) {
	const bodyText = await request.text();
	const valid = await verifyDiscordRequest(request, bodyText, env.DISCORD_PUBLIC_KEY);
	if (!valid) {
		return new Response('bad signature', { status: 401 });
	}

	const interaction = JSON.parse(bodyText);

	if (interaction.type === 1) {
		return Response.json({ type: 1 }); // PING
	}

	if (interaction.type === 4) {
		return handleAutocomplete(env, interaction);
	}

	if (interaction.type !== 2) {
		return Response.json({ error: 'unsupported interaction type' }, { status: 400 });
	}

	// Discord gives an interaction 3 seconds to be acknowledged, and several of these
	// commands cannot make that: the roster ones run two D1 queries and then a Discord
	// REST call to edit the roster embed before they reply, which on a cold start is
	// comfortably past the deadline. Discord then shows "the application did not
	// respond" even though the work completed - the command had simply answered too
	// late to count.
	//
	// So acknowledge immediately with a deferred response and edit the real answer in
	// once the work finishes. waitUntil keeps the Worker alive for that after the
	// response has already gone back.
	// application_id comes in on the interaction itself, so this does not depend on
	// DISCORD_APP_ID being set as a Worker secret - it is only ever needed as an env var
	// for the registration script, so relying on it here would have quietly skipped the
	// deferral on any deployment that never set it.
	const appId = interaction.application_id ?? env.DISCORD_APP_ID;
	if (ctx && appId) {
		ctx.waitUntil(
			(async () => {
				let payload;
				try {
					payload = await runCommand(request, env, ctx, interaction);
				} catch (err) {
					payload = replyMessage(`Something went wrong running that command: ${err}`);
				}
				await followUpOriginal(appId, interaction.token, payload?.data);
			})(),
		);
		// Ephemeral, matching replyMessage's default - the flag is fixed at defer time
		// and cannot be changed by the follow-up.
		return Response.json({ type: 5, data: { flags: 64 } });
	}

	// No execution context to defer with, so answer inline and hope it fits the budget.
	return Response.json(await runCommand(request, env, ctx, interaction));
}

// The dispatch itself, returning an interaction payload rather than a Response so it
// can be used either as an immediate reply or as the follow-up to a deferred one.
async function runCommand(request, env, ctx, interaction) {
	const discordId = interaction.member?.user?.id;
	const name = interaction.data.name;

	if (name === 'whitelist') {
		const sub = interaction.data.options?.[0];
		if (sub?.name === 'edit') {
			const username = getOption(sub.options, 'roblox');
			return await handleWhitelistEdit(env, interaction, discordId, username);
		}
		if (sub?.name === 'unlink') {
			return await handleWhitelistUnlink(env, discordId);
		}
	}

	if (name === 'add') {
		const accName = getOption(interaction.data.options, 'name');
		const rank = getOption(interaction.data.options, 'rank');
		const twofa = getOption(interaction.data.options, '2fa_required');
		return await handleRosterAdd(env, interaction, accName, rank, twofa);
	}
	if (name === 'remove') {
		const accName = getOption(interaction.data.options, 'name');
		return await handleRosterRemove(env, interaction, accName);
	}
	if (name === 'update') {
		const accName = getOption(interaction.data.options, 'name');
		const rank = getOption(interaction.data.options, 'rank');
		return await handleRosterUpdate(env, interaction, accName, rank);
	}
	if (name === 'set2fa') {
		const accName = getOption(interaction.data.options, 'name');
		const value = getOption(interaction.data.options, 'value');
		return await handleSet2fa(env, interaction, accName, value);
	}
	if (name === 'reset') {
		return await handleReset(env, interaction);
	}
	if (name === 'use') {
		const accName = getOption(interaction.data.options, 'name');
		return await handleRosterUse(env, interaction, accName);
	}
	if (name === 'done') {
		return await handleRosterDone(env, interaction);
	}
	if (name === 'addkit') {
		const accName = getOption(interaction.data.options, 'name');
		const kit = getOption(interaction.data.options, 'kit');
		return await handleAddKit(env, interaction, accName, kit);
	}
	if (name === 'removekit') {
		const accName = getOption(interaction.data.options, 'name');
		const kit = getOption(interaction.data.options, 'kit');
		return await handleRemoveKit(env, interaction, accName, kit);
	}
	if (name === 'kits') {
		const accName = getOption(interaction.data.options, 'name');
		return await handleListKits(env, interaction, accName);
	}
	if (name === 'kitowners') {
		const kit = getOption(interaction.data.options, 'kit');
		return await handleKitOwners(env, interaction, kit);
	}
	if (name === 'addwish') {
		const kit = getOption(interaction.data.options, 'kit');
		const acc = getOption(interaction.data.options, 'account');
		return await handleAddWish(env, interaction, kit, acc);
	}
	if (name === 'removewish') {
		const kit = getOption(interaction.data.options, 'kit');
		const acc = getOption(interaction.data.options, 'account');
		return await handleRemoveWish(env, interaction, kit, acc);
	}
	if (name === 'wishlist') {
		return await handleWishlist(env);
	}
	if (name === 'status') {
		return await handleStatus(env);
	}
	if (name === 'addtarget') {
		const targetName = getOption(interaction.data.options, 'target');
		const reason = getOption(interaction.data.options, 'reason');
		return await handleAddTarget(env, interaction, targetName, reason);
	}
	if (name === 'removetarget') {
		const targetName = getOption(interaction.data.options, 'target');
		return await handleRemoveTarget(env, interaction, targetName);
	}

	return replyMessage('Unknown command.');
}

export { handleDiscordInteraction };
