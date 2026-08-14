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

	// Confirmed no longer in the guild (left/kicked/banned) - this must revoke rank
	// immediately, not fall back to whatever was cached. Cache the 0 too, so a repeat
	// check doesn't need to ask Discord again for the TTL window.
	if (roleIds === 'not_member') {
		await updateCachedRank(env.DB, binding.discord_id, 0);
		return 0;
	}

	// Transient failure (rate limited, network error, Discord outage) - we genuinely
	// don't know their current roles, so fall back to the last known value rather than
	// wrongly demoting someone to Free because of an unrelated API hiccup.
	if (roleIds === null) {
		return binding.rank_level;
	}

	const rankConfigRows = await getRankConfig(env.DB, env.DISCORD_GUILD_ID);
	const level = rankFromRoles(roleIds, rankConfigRows);
	await updateCachedRank(env.DB, binding.discord_id, level);
	return level;
}

export { rankFromRoles, resolveRank };
