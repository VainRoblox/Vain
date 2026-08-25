local AutoUpgrade
local MinRarity
local Stat
local OnlyBetter

-- Every field below is taken from the lobby place dump rather than guessed at.
--
--   remotes.getPlayerStorage() -> {weapons, abilities, chests, helmets}
--   remotes.upgradeItem(category, uniqueItemNum, stat, count, mode)
--   items carry rarity, equipped, currentUpgrade and maxUpgrades
--
-- The stat argument is the thing being poured into, and only the stats an item actually
-- has can be upgraded on it - so a weapon takes physicalDamage or spellPower while armour
-- takes health.
local RARITY_ORDER = {'common', 'uncommon', 'rare', 'epic', 'legendary', 'unique', 'ultimate'}

local function rarityRank(name)
	if type(name) ~= 'string' then return 0 end
	name = name:lower()
	for i, v in RARITY_ORDER do
		if v == name then return i end
	end
	return 0
end

-- Storage comes back as {category = {["weapon_123"] = item}}, so this walks the
-- categories rather than assuming an array.
local function storage()
	local get = remote('getPlayerStorage')
	if not get then return nil end
	local ok, res = pcall(function() return get:InvokeServer() end)
	return ok and type(res) == 'table' and res or nil
end

-- What is currently equipped in the same category, so a candidate can be compared with
-- the thing it would replace. Abilities record equipped per slot (equipped.q / equipped.e)
-- rather than as a single flag, which is why this only treats a literal true as equipped.
local function equippedIn(list)
	for _, item in list do
		if fv(item, 'equipped') == true then return item end
	end
	return nil
end

local function statOf(item)
	local value = fv(item, Stat.Value)
	return tonumber(value) or 0
end

AutoUpgrade = vain.Categories.Utility:CreateModule({
	Name = 'Auto Upgrade',
	Tooltip = 'Upgrades gear that is worth upgrading, by rarity, and skips anything worse than what you already wear',
	Function = function(callback)
		if not callback then return end

		repeat
			pcall(function()
				local upgrade = remote('upgradeItem')
				local store = storage()
				if not (upgrade and store) then return end

				local floor = rarityRank(MinRarity.Value)

				for _, list in store do
					if type(list) ~= 'table' then continue end

					local worn = equippedIn(list)
					local wornStat = worn and statOf(worn) or 0

					for _, item in list do
						if type(item) ~= 'table' then continue end
						if rarityRank(fv(item, 'rarity')) < floor then continue end

						-- Nothing left to pour in.
						local current = tonumber(fv(item, 'currentUpgrade')) or 0
						local max = tonumber(fv(item, 'maxUpgrades')) or 0
						if current >= max then continue end

						-- Only worth spending on something you would actually wear. The
						-- item you have on is always worth upgrading; anything else has to
						-- beat it first, or the gold goes into gear that stays in storage.
						if OnlyBetter.Enabled and item ~= worn and statOf(item) <= wornStat then
							continue
						end

						local category = fv(item, 'itemType')
						local unique = fv(item, 'uniqueItemNum')
						if not (category and unique) then continue end

						-- One at a time, with no mode string: the ten and spend-all modes
						-- are what the interface sends when those toggles are lit, and
						-- asking for more than is affordable is refused outright rather
						-- than partially filled.
						upgrade:FireServer(category, unique, Stat.Value, 1, nil)
						return
					end
				end
			end)

			task.wait(0.6)
		until not AutoUpgrade.Enabled
	end
})
MinRarity = AutoUpgrade:CreateDropdown({
	Name = 'Minimum Rarity',
	Tooltip = 'Only upgrades gear at this rarity or above',
	-- Legendary first because a dropdown here takes its default from the first entry
	-- rather than from a Default field, which nothing else in the codebase passes. The
	-- rest stay in rarity order, since the setting is a floor and reads as a scale.
	List = {'Legendary', 'Common', 'Uncommon', 'Rare', 'Epic', 'Unique', 'Ultimate'}
})
Stat = AutoUpgrade:CreateDropdown({
	Name = 'Stat',
	Tooltip = 'Which stat the upgrades go into, and the one compared against your equipped gear',
	List = {'physicalDamage', 'spellPower', 'health', 'physicalPower'},
	Tooltips = {
		physicalDamage = 'Weapon damage',
		spellPower = 'Ability damage',
		health = 'Armour health',
		physicalPower = 'Armour power'
	}
})
OnlyBetter = AutoUpgrade:CreateToggle({
	Name = 'Only if better',
	Tooltip = 'Skips anything whose stat is no higher than the item you already have equipped in that slot',
	Default = true
})
