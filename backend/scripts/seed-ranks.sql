-- Discord role -> rank level for the Vain guild.
-- 0 Free (no mapped role) / 1 Premium / 2 Privileged / 3 Owner.
-- Re-runnable: REPLACE overwrites an existing mapping rather than failing on the
-- (guild_id, discord_role_id) primary key.
REPLACE INTO rank_config (guild_id, discord_role_id, rank_level) VALUES
	('1537794664931795005', '1537860418079301852', 3),  -- Owner
	('1537794664931795005', '1537860343379009646', 2),  -- Privileged
	('1537794664931795005', '1537860304581562398', 1);  -- Premium
