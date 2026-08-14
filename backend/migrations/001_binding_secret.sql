ALTER TABLE bindings ADD COLUMN binding_secret TEXT;

CREATE TABLE client_identities (
	roblox_userid INTEGER PRIMARY KEY,
	poll_key TEXT NOT NULL,
	first_seen INTEGER NOT NULL
);
