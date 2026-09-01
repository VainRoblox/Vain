// Thin helpers over the D1 binding. Table shapes are defined in schema.sql.


function generateSecret() {
	return [...crypto.getRandomValues(new Uint8Array(32))].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// Returns the fresh binding_secret so the caller can show it to the user once - it's
// never retrievable again after this (only a fresh relink generates a new one).
// Who currently holds a Roblox account, if anyone. Needed before binding it: without
// this check upsertBinding below happily takes an account off whoever had it, which is
// the whole hijack.
async function getBindingByRobloxId(db, robloxUserId) {
	return await db.prepare('SELECT * FROM bindings WHERE roblox_userid = ?').bind(robloxUserId).first();
}

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

async function deleteBindingByDiscordId(db, discordId) {
	await db.prepare('DELETE FROM bindings WHERE discord_id = ?').bind(discordId).run();
}

async function getRankConfig(db, guildId) {
	const { results } = await db
		.prepare('SELECT discord_role_id, rank_level FROM rank_config WHERE guild_id = ?')
		.bind(guildId)
		.all();
	return results;
}

async function getRosterMessage(db) {
	return db.prepare('SELECT * FROM roster_message WHERE id = 1').first();
}

async function setRosterMessage(db, channelId, messageId) {
	await db
		.prepare(
			`INSERT INTO roster_message (id, channel_id, message_id) VALUES (1, ?, ?)
			 ON CONFLICT(id) DO UPDATE SET channel_id = excluded.channel_id, message_id = excluded.message_id`
		)
		.bind(channelId, messageId)
		.run();
}

async function getTargetMessage(db) {
	return db.prepare('SELECT * FROM target_message WHERE id = 1').first();
}

async function setTargetMessage(db, channelId, messageId) {
	await db
		.prepare(
			`INSERT INTO target_message (id, channel_id, message_id) VALUES (1, ?, ?)
			 ON CONFLICT(id) DO UPDATE SET channel_id = excluded.channel_id, message_id = excluded.message_id`
		)
		.bind(channelId, messageId)
		.run();
}

async function getUsageAlertDate(db) {
	const row = await db.prepare('SELECT alerted_date FROM usage_alert_state WHERE id = 1').first();
	return row?.alerted_date ?? null;
}

async function setUsageAlertDate(db, date) {
	await db
		.prepare(
			`INSERT INTO usage_alert_state (id, alerted_date) VALUES (1, ?)
			 ON CONFLICT(id) DO UPDATE SET alerted_date = excluded.alerted_date`
		)
		.bind(date)
		.run();
}

export {
	getBindingByRobloxId,
	upsertBinding,
	deleteBindingByDiscordId,
	getRankConfig,
	getRosterMessage,
	setRosterMessage,
	getTargetMessage,
	setTargetMessage,
	getUsageAlertDate,
	setUsageAlertDate,
};
