-- Discord <-> Roblox account bindings. One row per linked Discord user.
--
-- binding_secret: a random per-account key, generated at link time and shown to the
-- user once (via an ephemeral Discord reply, never logged/stored client-side by us).
-- This is what actually proves "/command requests claiming to be this Roblox account
-- really are" - a single secret shared by every Vain install (the earlier design)
-- would let anyone who reads the public script impersonate ANY ranked user, since the
-- script is public. Only the real linked user ever sees their own binding_secret.
CREATE TABLE bindings (
	discord_id TEXT PRIMARY KEY,
	roblox_userid INTEGER NOT NULL UNIQUE,
	roblox_username TEXT,
	binding_secret TEXT NOT NULL,
	linked_at INTEGER NOT NULL,
	last_relinked_at INTEGER,
	rank_level INTEGER NOT NULL DEFAULT 0,
	rank_cached_at INTEGER NOT NULL DEFAULT 0
);

-- Discord role -> rank level mapping, per guild.
-- rank_level: 0 = Free, 1 = Premium, 2 = Privileged, 3 = Owner.
CREATE TABLE rank_config (
	guild_id TEXT NOT NULL,
	discord_role_id TEXT NOT NULL,
	rank_level INTEGER NOT NULL,
	PRIMARY KEY (guild_id, discord_role_id)
);

-- Queued commands waiting for delivery to a target's long-poll.
CREATE TABLE commands (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	target_roblox_userid INTEGER NOT NULL,
	issuer_roblox_userid INTEGER,
	issuer_discord_id TEXT,
	command TEXT NOT NULL,
	args TEXT NOT NULL DEFAULT '[]',
	status TEXT NOT NULL DEFAULT 'pending',
	created_at INTEGER NOT NULL,
	expires_at INTEGER NOT NULL,
	claimed_at INTEGER
);

CREATE INDEX idx_commands_target_pending
	ON commands (target_roblox_userid, status, created_at);

-- Every Roblox user is a potential command TARGET, including unranked ("Free") ones
-- who never linked a Discord account and so have no bindings.binding_secret. To stop
-- someone else's client from squatting on their uid and stealing their queued
-- commands, each client generates its own random key locally on first run and this
-- table remembers "whoever showed up first with uid X owns X's poll key from now on"
-- (trust-on-first-use, same trade-off SSH host keys make).
CREATE TABLE client_identities (
	roblox_userid INTEGER PRIMARY KEY,
	poll_key TEXT NOT NULL,
	first_seen INTEGER NOT NULL
);

-- Shared account roster: Roblox accounts the team owns, their current in-game rank,
-- and who (if anyone) currently has it checked out. Managed entirely via the
-- /add /remove /update /use /done Discord commands (role-gated - see ROSTER_ROLE_ID in
-- routes/discord.js) and rendered as a single live-edited embed, so anyone with that
-- role can update any entry instead of only whoever originally posted a chat message.
CREATE TABLE account_roster (
	name TEXT PRIMARY KEY,
	rank TEXT NOT NULL,
	in_use_by TEXT,
	updated_at INTEGER NOT NULL
);

-- The one live roster embed message, so commands edit it in place instead of posting
-- a new message every time. One row (singleton, no guild scoping needed for v1).
CREATE TABLE roster_message (
	id INTEGER PRIMARY KEY CHECK (id = 1),
	channel_id TEXT NOT NULL,
	message_id TEXT NOT NULL
);

-- Which Bedwars kits each roster account owns. Many-to-many; the kit catalog itself
-- isn't a table since it's a fixed reference list that lives in code (src/lib/kits.js)
-- and changes rarely - this table just tracks ownership against that list.
CREATE TABLE account_kits (
	account_name TEXT NOT NULL,
	kit_name TEXT NOT NULL,
	added_at INTEGER NOT NULL,
	PRIMARY KEY (account_name, kit_name)
);
