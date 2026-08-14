import { getBindingByRobloxId } from './db.js';
import { resolveRank } from './ranks.js';
import { queueCommand } from './db.js';

// v1: only "kick" exists. Never execute an arbitrary client-supplied string - only
// names in this list can ever be queued.
const ALLOWED_COMMANDS = new Set(['kick']);

const COMMAND_TTL_SECONDS = 60; // undelivered commands expire rather than piling up

async function resolveRankForRobloxUserId(env, robloxUserId) {
	const binding = await getBindingByRobloxId(env.DB, robloxUserId);
	return resolveRank(env, binding);
}

// Returns { ok: true, id } or { ok: false, error, status }.
async function issueCommand(env, { issuerRobloxUserId, issuerDiscordId, issuerRankOverride, targetRobloxUserId, command, args }) {
	if (!ALLOWED_COMMANDS.has(command)) {
		return { ok: false, status: 400, error: 'unknown command' };
	}
	if (!targetRobloxUserId || targetRobloxUserId === issuerRobloxUserId) {
		return { ok: false, status: 400, error: 'invalid target' };
	}

	// issuerRankOverride is used by the Discord bot path, where Discord's own signed
	// interaction payload already told us the issuer's verified roles - no need to
	// re-look-up a binding, we resolve straight from those roles (see routes/discord.js).
	const issuerRank =
		issuerRankOverride !== undefined ? issuerRankOverride : await resolveRankForRobloxUserId(env, issuerRobloxUserId);
	const targetRank = await resolveRankForRobloxUserId(env, targetRobloxUserId);

	if (issuerRank <= targetRank) {
		return { ok: false, status: 403, error: 'target is not lower-ranked than you' };
	}

	const id = await queueCommand(env.DB, {
		targetRobloxUserId,
		issuerRobloxUserId: issuerRobloxUserId ?? null,
		issuerDiscordId: issuerDiscordId ?? null,
		command,
		args,
		ttlSeconds: COMMAND_TTL_SECONDS,
	});
	return { ok: true, id };
}

export { ALLOWED_COMMANDS, issueCommand, resolveRankForRobloxUserId };
