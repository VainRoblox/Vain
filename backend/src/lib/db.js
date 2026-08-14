// Thin helpers over the D1 binding. Table shapes are defined in schema.sql.

async function getBindingByRobloxId(db, robloxUserId) {
	return db
		.prepare('SELECT * FROM bindings WHERE roblox_userid = ?')
		.bind(robloxUserId)
		.first();
}

async function getBindingByDiscordId(db, discordId) {
	return db.prepare('SELECT * FROM bindings WHERE discord_id = ?').bind(discordId).first();
}

function generateSecret() {
	return [...crypto.getRandomValues(new Uint8Array(32))].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// Returns the fresh binding_secret so the caller can show it to the user once - it's
// never retrievable again after this (only a fresh relink generates a new one).
async function upsertBinding(db, { discordId, robloxUserId, robloxUsername, rankLevel }) {
	const now = Math.floor(Date.now() / 1000);
	const bindingSecret = generateSecret();
	// A Roblox account can only be bound to one Discord account: remove any existing
	// binding for that roblox_userid (e.g. it was previously linked to someone else)
	// before inserting the new one, and remove any existing binding for this Discord
	// user (rebind case) so the UNIQUE constraints never collide.
	await db.batch([
		db.prepare('DELETE FROM bindings WHERE roblox_userid = ?').bind(robloxUserId),
		db.prepare('DELETE FROM bindings WHERE discord_id = ?').bind(discordId),
		db
			.prepare(
				`INSERT INTO bindings (discord_id, roblox_userid, roblox_username, binding_secret, linked_at, last_relinked_at, rank_level, rank_cached_at)
				 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
			)
			.bind(discordId, robloxUserId, robloxUsername, bindingSecret, now, now, rankLevel, now),
	]);
	return bindingSecret;
}

// Trust-on-first-use check for /poll and /rank: the first client to present a key for
// a given roblox_userid owns that identity from then on. Returns true if providedKey
// is (now, or already was) that uid's registered key.
async function verifyOrRegisterClientKey(db, robloxUserId, providedKey) {
	if (!providedKey) return false;
	const now = Math.floor(Date.now() / 1000);
	await db
		.prepare('INSERT INTO client_identities (roblox_userid, poll_key, first_seen) VALUES (?, ?, ?) ON CONFLICT(roblox_userid) DO NOTHING')
		.bind(robloxUserId, providedKey, now)
		.run();
	const row = await db.prepare('SELECT poll_key FROM client_identities WHERE roblox_userid = ?').bind(robloxUserId).first();
	return row?.poll_key === providedKey;
}

async function deleteBindingByDiscordId(db, discordId) {
	await db.prepare('DELETE FROM bindings WHERE discord_id = ?').bind(discordId).run();
}

async function updateCachedRank(db, discordId, rankLevel) {
	const now = Math.floor(Date.now() / 1000);
	await db
		.prepare('UPDATE bindings SET rank_level = ?, rank_cached_at = ? WHERE discord_id = ?')
		.bind(rankLevel, now, discordId)
		.run();
}

async function getRankConfig(db, guildId) {
	const { results } = await db
		.prepare('SELECT discord_role_id, rank_level FROM rank_config WHERE guild_id = ?')
		.bind(guildId)
		.all();
	return results;
}

async function queueCommand(db, { targetRobloxUserId, issuerRobloxUserId, issuerDiscordId, command, args, ttlSeconds }) {
	const now = Math.floor(Date.now() / 1000);
	const res = await db
		.prepare(
			`INSERT INTO commands (target_roblox_userid, issuer_roblox_userid, issuer_discord_id, command, args, status, created_at, expires_at)
			 VALUES (?, ?, ?, ?, ?, 'pending', ?, ?)`
		)
		.bind(targetRobloxUserId, issuerRobloxUserId ?? null, issuerDiscordId ?? null, command, JSON.stringify(args ?? []), now, now + ttlSeconds)
		.run();
	return res.meta.last_row_id;
}

async function claimNextCommand(db, targetRobloxUserId) {
	const now = Math.floor(Date.now() / 1000);
	const row = await db
		.prepare(
			`SELECT * FROM commands
			 WHERE target_roblox_userid = ? AND status = 'pending' AND expires_at > ?
			 ORDER BY created_at ASC LIMIT 1`
		)
		.bind(targetRobloxUserId, now)
		.first();
	if (!row) return null;

	// Mark it delivered before returning it, so a retried /poll (e.g. client didn't
	// get the response) never delivers the same command twice.
	await db
		.prepare("UPDATE commands SET status = 'delivered', claimed_at = ? WHERE id = ? AND status = 'pending'")
		.bind(now, row.id)
		.run();
	return row;
}

export {
	getBindingByRobloxId,
	getBindingByDiscordId,
	upsertBinding,
	deleteBindingByDiscordId,
	updateCachedRank,
	getRankConfig,
	queueCommand,
	claimNextCommand,
	verifyOrRegisterClientKey,
};
