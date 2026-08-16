// Shared target list (players being tracked) - separate concern from account_roster,
// its own table and its own embed. See schema.sql's targets table for the shape.

async function addTarget(db, name, addedBy) {
	const now = Math.floor(Date.now() / 1000);
	await db
		.prepare('INSERT INTO targets (name, added_by, added_at) VALUES (?, ?, ?) ON CONFLICT(name) DO NOTHING')
		.bind(name, addedBy, now)
		.run();
}

async function removeTarget(db, name) {
	const res = await db.prepare('DELETE FROM targets WHERE name = ?').bind(name).run();
	return res.meta.changes > 0;
}

async function listTargets(db) {
	const { results } = await db.prepare('SELECT * FROM targets ORDER BY name COLLATE NOCASE').all();
	return results;
}

// Backs the autocomplete on /removetarget's `target` option - live-queried for the same
// reason searchAccountNames is: a static choices list would go stale between
// registrations. Discord caps autocomplete results at 25.
async function searchTargetNames(db, query) {
	const { results } = await db
		.prepare("SELECT name FROM targets WHERE name LIKE ? ESCAPE '\\' ORDER BY name COLLATE NOCASE LIMIT 25")
		.bind(`%${query.replace(/[%_]/g, '\\$&')}%`)
		.all();
	return results.map((r) => r.name);
}

function buildTargetsEmbed(targets) {
	const lines = targets.length
		? targets.map((t) => `**${t.name}** — added by <@${t.added_by}>`)
		: ['*No targets yet — add one with `/addtarget`.*'];

	return {
		title: 'Targets',
		description: lines.join('\n'),
		color: 0xb80000,
		footer: { text: `${targets.length} target${targets.length === 1 ? '' : 's'}` },
		timestamp: new Date().toISOString(),
	};
}

export { addTarget, removeTarget, listTargets, searchTargetNames, buildTargetsEmbed };
