import { verifyDiscordRequest, replyMessage, postMessage, editMessage } from '../lib/discord.js';
import { lookupUserId } from '../lib/roblox.js';
import { upsertBinding, deleteBindingByDiscordId, getRankConfig, getRosterMessage, setRosterMessage } from '../lib/db.js';
import { rankFromRoles } from '../lib/ranks.js';
import { issueCommand } from '../lib/commands.js';
import {
	upsertAccount,
	removeAccount,
	getAccount,
	getAccountInUseByUser,
	setInUse,
	clearInUse,
	listAccounts,
	searchAccountNames,
	buildRosterEmbed,
} from '../lib/roster.js';

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

async function handleRosterAdd(env, interaction, name, rank) {
	if (!hasRosterRole(interaction)) return replyMessage("You don't have permission to do that.");
	await upsertAccount(env.DB, name, rank ?? '');
	const synced = await syncRosterEmbed(env);
	return replyMessage(`Added **${name}**${rank ? ` (${rank})` : ' (unranked)'}.${synced ? '' : ROSTER_SYNC_FAILED_NOTE}`);
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
	await upsertAccount(env.DB, name, rank ?? '');
	const synced = await syncRosterEmbed(env);
	return replyMessage(`Updated **${name}** to ${rank || 'unranked'}.${synced ? '' : ROSTER_SYNC_FAILED_NOTE}`);
}

async function handleRosterUse(env, interaction, name) {
	if (!hasRosterRole(interaction)) return replyMessage("You don't have permission to do that.");
	const existing = await getAccount(env.DB, name);
	if (!existing) return replyMessage(`No account named "${name}" found.`);
	const requesterId = interaction.member.user.id;

	if (existing.in_use_by && existing.in_use_by !== requesterId) {
		return replyMessage(`**${name}** is already in use by <@${existing.in_use_by}>.`);
	}

	// One account at a time per person - /done has no parameters and relies on this
	// being true to know which account to release.
	const alreadyHave = await getAccountInUseByUser(env.DB, requesterId);
	if (alreadyHave && alreadyHave.name !== name) {
		return replyMessage(`You already have **${alreadyHave.name}** checked out. Run \`/done\` to release it first.`);
	}

	await setInUse(env.DB, name, requesterId);
	const synced = await syncRosterEmbed(env);
	return replyMessage(`Marked **${name}** as in use by you.${synced ? '' : ROSTER_SYNC_FAILED_NOTE}`);
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

// Live-queries account names for the `name` option on /update and /remove as the user
// types, rather than a static (and immediately stale) Discord `choices` list.
async function handleAutocomplete(env, interaction) {
	const focused = interaction.data.options?.find((o) => o.focused);
	const query = focused?.value ?? '';
	const matches = await searchAccountNames(env.DB, query);
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
		return Response.json(await handleRosterAdd(env, interaction, accName, rank));
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
	if (name === 'use') {
		const accName = getOption(interaction.data.options, 'name');
		return Response.json(await handleRosterUse(env, interaction, accName));
	}
	if (name === 'done') {
		return Response.json(await handleRosterDone(env, interaction));
	}

	return Response.json(replyMessage('Unknown command.'));
}

export { handleDiscordInteraction };
