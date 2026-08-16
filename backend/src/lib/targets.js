// Shared target list (players being tracked) - separate concern from account_roster,
// its own table and its own embed. See schema.sql's targets table for the shape.

async function addTarget(db, name, addedBy, reason) {
	const now = Math.floor(Date.now() / 1000);
	await db
		.prepare('INSERT INTO targets (name, added_by, reason, added_at) VALUES (?, ?, ?, ?) ON CONFLICT(name) DO NOTHING')
		.bind(name, addedBy, reason ?? null, now)
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

// Discord caps a message at 10 embeds total. Each target gets its own embed (that's the
// only way to show a per-target thumbnail - a single embed only has one image slot), so
// one slot is reserved here for the header/commands embed.
const MAX_TARGET_THUMBNAILS = 9;

// avatarUrls: { [lowercased target name]: imageUrl }, resolved by the caller (see
// syncTargetEmbed in routes/discord.js) since fetching from Roblox's API doesn't belong
// in this module. Missing/failed lookups just mean that target's embed has no thumbnail
// - not an error.
function buildTargetsEmbeds(targets, avatarUrls) {
	const header = {
		title: 'Targets',
		color: 0xb80000,
		fields: [
			{
				name: 'Commands',
				value: [
					'`/addtarget target:<name> reason:<optional>` — add a player to the targets list',
					'`/removetarget target:<name>` — remove a player from the targets list',
				].join('\n'),
			},
		],
		footer: { text: `${targets.length} target${targets.length === 1 ? '' : 's'}` },
		timestamp: new Date().toISOString(),
	};

	if (!targets.length) {
		header.description = '*No targets yet — add one with `/addtarget`.*';
		return [header];
	}

	const shown = targets.slice(0, MAX_TARGET_THUMBNAILS);
	const overflow = targets.length - shown.length;
	if (overflow > 0) {
		header.description = `*Showing ${shown.length} of ${targets.length} — remove some to see pictures for the rest.*`;
	}

	const targetEmbeds = shown.map((t) => {
		const embed = {
			title: t.name,
			description: `${t.reason ? `*${t.reason}*\n` : ''}Added by <@${t.added_by}>`,
			color: 0xb80000,
		};
		const avatarUrl = avatarUrls[t.name.toLowerCase()];
		if (avatarUrl) embed.thumbnail = { url: avatarUrl };
		return embed;
	});

	return [header, ...targetEmbeds];
}

export { addTarget, removeTarget, listTargets, searchTargetNames, buildTargetsEmbeds, MAX_TARGET_THUMBNAILS };
