import { verifyDiscordRequest, replyMessage } from '../lib/discord.js';
import { lookupUserId } from '../lib/roblox.js';
import { upsertBinding, deleteBindingByDiscordId, getRankConfig } from '../lib/db.js';
import { rankFromRoles } from '../lib/ranks.js';
import { issueCommand } from '../lib/commands.js';

function getOption(options, name) {
	return options?.find((o) => o.name === name)?.value;
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

	return Response.json(replyMessage('Unknown command.'));
}

export { handleDiscordInteraction };
