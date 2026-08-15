import { verifyDiscordRequest, replyMessage, postMessage, editMessage } from '../lib/discord.js';
import { lookupUserId } from '../lib/roblox.js';
import { upsertBinding, deleteBindingByDiscordId, getRankConfig, getRosterMessage, setRosterMessage } from '../lib/db.js';
import { rankFromRoles } from '../lib/ranks.js';
import { issueCommand } from '../lib/commands.js';
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

// Only members holding this role can run /add /remove /update /use /done. Discord's
// own default_member_permissions only understands built-in permission bits, not
// arbitrary custom roles, so this has to be enforced here in code.
const ROSTER_ROLE_ID = '1537821596977340416';
const ROSTER_CHANNEL_ID = '1537805418728919086';

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
async function handleWhitelistEdit(env, discordId, username) {
	const lookup = await lookupUserId(username);
	if (!lookup) {
		return replyMessage(`Couldn't find a Roblox user named "${username}".`);
	}

	const secret = await upsertBinding(env.DB, {
		discordId,
		robloxUserId: lookup.userId,
		robloxUsername: lookup.username,
		rankLevel: 0, // resolved live from Discord roles on first rank check, not needed here
	});

	return replyMessage(
		`Linked! Your Discord account is now bound to Roblox user "${lookup.username}".\n\n` +
			`Your personal Vain key (needed to issue commands - keep this private, don't share it):\n` +
			`\`${secret}\`\n\n` +
			`Paste it in-game with: \`;rank key ${secret}\` (or Settings → General → Rank key in the GUI)`
	);
}

async function handleWhitelistUnlink(env, discordId) {
	await deleteBindingByDiscordId(env.DB, discordId);
	return replyMessage('Unlinked. Your Roblox account no longer has a rank.');
}

async function handleCommandInteraction(env, interaction, action, targetUsername) {
	const target = await lookupUserId(targetUsername);
	if (!target) {
		return replyMessage(`Couldn't find a Roblox user named "${targetUsername}".`);
	}

	const roleIds = interaction.member?.roles ?? [];
	const rankConfigRows = await getRankConfig(env.DB, interaction.guild_id);
	const issuerRank = rankFromRoles(roleIds, rankConfigRows);

	const result = await issueCommand(env, {
		issuerDiscordId: interaction.member?.user?.id,
		issuerRankOverride: issuerRank,
		targetRobloxUserId: target.userId,
		command: action,
		args: [],
	});

	if (!result.ok) {
		return replyMessage(`Couldn't run that: ${result.error}`);
	}
	return replyMessage(`Queued "${action}" on ${target.username}.`);
}

// Re-renders the roster embed from the current DB state into the one tracked
// message, editing it in place. If that message was deleted (or none exists yet),
// posts a fresh one into the fixed roster channel and remembers its ID.
// Returns true/false rather than swallowing failures - a bad channel permission (or
// any other post/edit failure) needs to actually surface in the command reply, not
// look like a silent success while the embed never updates.
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
	const matches = focused?.name === 'kit' ? searchKits(query) : await searchAccountNames(env.DB, query);
	return Response.json({
		type: 8, // APPLICATION_COMMAND_AUTOCOMPLETE_RESULT
		data: { choices: matches.map((n) => ({ name: n, value: n })) },
	});
}

async function handleDiscordInteraction(request, env) {
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

	const discordId = interaction.member?.user?.id;
	const name = interaction.data.name;

	if (name === 'whitelist') {
		const sub = interaction.data.options?.[0];
		if (sub?.name === 'edit') {
			const username = getOption(sub.options, 'roblox');
			return Response.json(await handleWhitelistEdit(env, discordId, username));
		}
		if (sub?.name === 'unlink') {
			return Response.json(await handleWhitelistUnlink(env, discordId));
		}
	}

	if (name === 'command') {
		const action = getOption(interaction.data.options, 'action');
		const target = getOption(interaction.data.options, 'target');
		return Response.json(await handleCommandInteraction(env, interaction, action, target));
	}

	if (name === 'add') {
		const accName = getOption(interaction.data.options, 'name');
		const rank = getOption(interaction.data.options, 'rank');
		const twofa = getOption(interaction.data.options, '2fa_required');
		return Response.json(await handleRosterAdd(env, interaction, accName, rank, twofa));
	}
	if (name === 'remove') {
		const accName = getOption(interaction.data.options, 'name');
		return Response.json(await handleRosterRemove(env, interaction, accName));
	}
	if (name === 'update') {
		const accName = getOption(interaction.data.options, 'name');
		const rank = getOption(interaction.data.options, 'rank');
		return Response.json(await handleRosterUpdate(env, interaction, accName, rank));
	}
	if (name === 'set2fa') {
		const accName = getOption(interaction.data.options, 'name');
		const value = getOption(interaction.data.options, 'value');
		return Response.json(await handleSet2fa(env, interaction, accName, value));
	}
	if (name === 'reset') {
		return Response.json(await handleReset(env, interaction));
	}
	if (name === 'use') {
		const accName = getOption(interaction.data.options, 'name');
		return Response.json(await handleRosterUse(env, interaction, accName));
	}
	if (name === 'done') {
		return Response.json(await handleRosterDone(env, interaction));
	}
	if (name === 'addkit') {
		const accName = getOption(interaction.data.options, 'name');
		const kit = getOption(interaction.data.options, 'kit');
		return Response.json(await handleAddKit(env, interaction, accName, kit));
	}
	if (name === 'removekit') {
		const accName = getOption(interaction.data.options, 'name');
		const kit = getOption(interaction.data.options, 'kit');
		return Response.json(await handleRemoveKit(env, interaction, accName, kit));
	}
	if (name === 'kits') {
		const accName = getOption(interaction.data.options, 'name');
		return Response.json(await handleListKits(env, interaction, accName));
	}
	if (name === 'kitowners') {
		const kit = getOption(interaction.data.options, 'kit');
		return Response.json(await handleKitOwners(env, interaction, kit));
	}
	if (name === 'addwish') {
		const kit = getOption(interaction.data.options, 'kit');
		const acc = getOption(interaction.data.options, 'account');
		return Response.json(await handleAddWish(env, interaction, kit, acc));
	}
	if (name === 'removewish') {
		const kit = getOption(interaction.data.options, 'kit');
		const acc = getOption(interaction.data.options, 'account');
		return Response.json(await handleRemoveWish(env, interaction, kit, acc));
	}
	if (name === 'wishlist') {
		return Response.json(await handleWishlist(env));
	}
	if (name === 'status') {
		return Response.json(await handleStatus(env));
	}

	return Response.json(replyMessage('Unknown command.'));
}

export { handleDiscordInteraction };
