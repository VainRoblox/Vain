// The shared account roster: name, current in-game rank, and who (if anyone) has it
// checked out. See schema.sql's account_roster table for the shape.

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

function buildRosterEmbed(accounts) {
	const lines = accounts.length
		? accounts.map((a) => {
				const inUse = a.in_use_by ? ` — *in use by <@${a.in_use_by}>*` : '';
				return `**${a.name}** — ${a.rank}${inUse}`;
			})
		: ['*No accounts yet — add one with `/add`.*'];

	return {
		title: 'Account Roster',
		description: lines.join('\n'),
		color: 0x054785,
		footer: { text: `${accounts.length} account${accounts.length === 1 ? '' : 's'}` },
		timestamp: new Date().toISOString(),
	};
}

export { upsertAccount, removeAccount, getAccount, setInUse, clearInUse, listAccounts, buildRosterEmbed };
