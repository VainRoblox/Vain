import { getGuildMemberRoles } from './discord.js';
import { getRankConfig, updateCachedRank } from './db.js';

// 0 = Free (default, no mapped role), 1 = Premium, 2 = Privileged, 3 = Owner.
function rankFromRoles(roleIds, rankConfigRows) {
	let level = 0;
	for (const row of rankConfigRows) {
		if (roleIds.includes(row.discord_role_id) && row.rank_level > level) {
			level = row.rank_level;
		}
	}
	return level;
}

// Returns the binding's current rank, refreshing from Discord if the cached value is
// stale. A binding's rank is always derived server-side here — the Roblox client is
// never trusted to assert its own rank.
async function resolveRank(env, binding) {
	if (!binding) return 0;

	const ttl = parseInt(env.RANK_CACHE_TTL_SECONDS, 10) || 120;
	const now = Math.floor(Date.now() / 1000);
	if (now - binding.rank_cached_at < ttl) {
		return binding.rank_level;
	}

	const roleIds = await getGuildMemberRoles(env.DISCORD_GUILD_ID, binding.discord_id, env.DISCORD_BOT_TOKEN);
	if (roleIds === null) {
		// Discord lookup failed (rate limited, member left, etc) - fall back to the
		// last known value rather than silently demoting someone to Free.
		return binding.rank_level;
	}

	const rankConfigRows = await getRankConfig(env.DB, env.DISCORD_GUILD_ID);
	const level = rankFromRoles(roleIds, rankConfigRows);
	await updateCachedRank(env.DB, binding.discord_id, level);
	return level;
}

export { rankFromRoles, resolveRank };
