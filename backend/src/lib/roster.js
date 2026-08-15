// The shared account roster: name, current in-game rank, and who (if anyone) has it
// checked out. See schema.sql's account_roster table for the shape.

// Guild's custom tier emoji (fetched once via GET /guilds/{id}/emojis and hardcoded
// here - these are static per-emoji IDs, not something that changes at runtime).
const RANK_EMOJIS = {
	bronze: '<:bronze:1537805324101353623>',
	silver: '<:silver:1537805259571859536>',
	gold: '<:gold:1537805148527656960>',
	platinum: '<:platinum:1537805203703730270>',
	diamond: '<:diamond:1537805177497722920>',
	emerald: '<:emerald:1537799234055700520>',
	nightmare: '<:nightmare:1537799266159042701>',
};

async function upsertAccount(db, name, rank) {
	const now = Math.floor(Date.now() / 1000);
	await db
		.prepare(
			`INSERT INTO account_roster (name, rank, updated_at) VALUES (?, ?, ?)
			 ON CONFLICT(name) DO UPDATE SET rank = excluded.rank, updated_at = excluded.updated_at`
		)
		.bind(name, rank, now)
		.run();
}

async function removeAccount(db, name) {
	const res = await db.prepare('DELETE FROM account_roster WHERE name = ?').bind(name).run();
	return res.meta.changes > 0;
}

async function getAccount(db, name) {
	return db.prepare('SELECT * FROM account_roster WHERE name = ?').bind(name).first();
}

// Each Discord user can only have one account checked out at a time - this is what
// lets /done skip the name parameter entirely (auto-detects which one to release) and
// what /use checks before letting someone grab a second account.
async function getAccountInUseByUser(db, discordUserId) {
	return db.prepare('SELECT * FROM account_roster WHERE in_use_by = ?').bind(discordUserId).first();
}

async function setInUse(db, name, discordUserId) {
	const now = Math.floor(Date.now() / 1000);
	await db.prepare('UPDATE account_roster SET in_use_by = ?, updated_at = ? WHERE name = ?').bind(discordUserId, now, name).run();
}

async function clearInUse(db, name) {
	const now = Math.floor(Date.now() / 1000);
	await db.prepare('UPDATE account_roster SET in_use_by = NULL, updated_at = ? WHERE name = ?').bind(now, name).run();
}

async function listAccounts(db) {
	const { results } = await db.prepare('SELECT * FROM account_roster ORDER BY name COLLATE NOCASE').all();
	return results;
}

// Backs the autocomplete on /update and /remove's `name` option - a static Discord
// `choices` list can't work here since it's fixed at command-registration time and
// would go stale the moment an account gets added/removed, so this queries live
// instead. Discord caps autocomplete results at 25.
async function searchAccountNames(db, query) {
	const { results } = await db
		.prepare("SELECT name FROM account_roster WHERE name LIKE ? ESCAPE '\\' ORDER BY name COLLATE NOCASE LIMIT 25")
		.bind(`%${query.replace(/[%_]/g, '\\$&')}%`)
		.all();
	return results.map((r) => r.name);
}

// Highest to lowest. Unranked (no rank at all) always sorts below every tier here;
// unrecognized rank text (a typo, or something without an emoji) sorts just above
// unranked but below every real tier.
const RANK_ORDER = ['nightmare', 'emerald', 'diamond', 'platinum', 'gold', 'silver', 'bronze'];

function rankPriority(rank) {
	if (!rank) return -Infinity;
	const idx = RANK_ORDER.indexOf(rank.toLowerCase());
	return idx === -1 ? -1 : RANK_ORDER.length - idx;
}

function sortByRank(accounts) {
	return [...accounts].sort((a, b) => {
		const diff = rankPriority(b.rank) - rankPriority(a.rank);
		return diff !== 0 ? diff : a.name.localeCompare(b.name, undefined, { sensitivity: 'base' });
	});
}

function buildRosterEmbed(accounts) {
	const lines = accounts.length
		? sortByRank(accounts).map((a) => {
				let rankLabel = '';
				if (a.rank) {
					const emoji = RANK_EMOJIS[a.rank.toLowerCase()];
					// Unrecognized rank text (typo, or a tier without an emoji) - fall back to
					// showing it as plain text rather than dropping it silently.
					rankLabel = (emoji || `\`${a.rank}\``) + ' ';
				}
				// No rank at all (unranked) - no emoji, no label, just the name.
				const inUse = a.in_use_by ? ` — *currently used by <@${a.in_use_by}>*` : '';
				return `${rankLabel}**${a.name}**${inUse}`;
			})
		: ['*No accounts yet — add one with `/add`.*'];

	return {
		title: 'Account Roster',
		description: lines.join('\n'),
		color: 0x054785,
		fields: [
			{
				name: 'Commands',
				value: [
					'`/add name:<account> rank:<tier>` — add an account (pick Unranked if it has none)',
					'`/update name:<account> rank:<tier>` — change its rank (pick Unranked to clear it)',
					'`/remove name:<account>` — remove it',
					'`/use name:<account>` — check it out (marks it currently used by you; one at a time)',
					'`/done` — release whichever account you currently have checked out',
				].join('\n'),
			},
		],
		footer: { text: `${accounts.length} account${accounts.length === 1 ? '' : 's'}` },
		timestamp: new Date().toISOString(),
	};
}

// Kit ownership is deliberately separate from the main embed (the user asked for it to
// only be visible via an ephemeral /kits reply, not shown to everyone in the channel).

async function addKit(db, accountName, kitName) {
	const now = Math.floor(Date.now() / 1000);
	await db
		.prepare('INSERT INTO account_kits (account_name, kit_name, added_at) VALUES (?, ?, ?) ON CONFLICT(account_name, kit_name) DO NOTHING')
		.bind(accountName, kitName, now)
		.run();
}

async function removeKit(db, accountName, kitName) {
	const res = await db.prepare('DELETE FROM account_kits WHERE account_name = ? AND kit_name = ?').bind(accountName, kitName).run();
	return res.meta.changes > 0;
}

async function listKitsForAccount(db, accountName) {
	const { results } = await db
		.prepare('SELECT kit_name FROM account_kits WHERE account_name = ? ORDER BY kit_name COLLATE NOCASE')
		.bind(accountName)
		.all();
	return results.map((r) => r.kit_name);
}

export {
	upsertAccount,
	removeAccount,
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
};
