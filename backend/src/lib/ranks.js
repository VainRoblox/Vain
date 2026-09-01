
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

export { rankFromRoles };
