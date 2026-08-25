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

-- The stats an item can actually be upgraded on. A weapon carries damage stats and
-- armour carries health, so most items only have some of these - the ones it does not
-- have simply read as nothing and are skipped.
local UPGRADEABLE = {'physicalDamage', 'spellPower', 'health', 'physicalPower'}

-- Which stat to pour into for a given item.
--
-- On Highest this is whichever of its stats is already the largest, so upgrades stack
-- into what the item is good at instead of being spread across stats it was never going
-- to be used for. Anything else is the fixed choice from the dropdown.
local function statFor(item)
	if Stat.Value ~= 'Highest' then return Stat.Value end

	local best, bestValue
	for _, name in UPGRADEABLE do
		local value = tonumber(fv(item, name))
		if value and (not bestValue or value > bestValue) then
			best, bestValue = name, value
		end
	end
	return best
end

local function statOf(item, name)
	return tonumber(fv(item, name)) or 0
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

					for _, item in list do
						if type(item) ~= 'table' then continue end
						if rarityRank(fv(item, 'rarity')) < floor then continue end

						-- Nothing left to pour in.
						local current = tonumber(fv(item, 'currentUpgrade')) or 0
						local max = tonumber(fv(item, 'maxUpgrades')) or 0
						if current >= max then continue end

						-- Whichever stat this item is getting upgraded on is also the one
						-- it is judged by, so a candidate is compared with the equipped
						-- item on the same footing rather than on a stat it happens not to
						-- have.
						local stat = statFor(item)
						if not stat then continue end

						-- Only worth spending on something you would actually wear. The
						-- item you have on is always worth upgrading; anything else has to
						-- beat it first, or the gold goes into gear that stays in storage.
						if OnlyBetter.Enabled and item ~= worn then
							local wornStat = worn and statOf(worn, stat) or 0
							if statOf(item, stat) <= wornStat then continue end
						end

						local category = fv(item, 'itemType')
						local unique = fv(item, 'uniqueItemNum')
						if not (category and unique) then continue end

						-- Everything remaining in one go, which is what the interface's own
						-- spend-all toggle sends: the count is maxUpgrades minus
						-- currentUpgrade and the mode string is 'spendAll'.
						--
						-- An earlier version sent one at a time on the assumption that
						-- asking for more than was affordable would be refused outright.
						-- That was never checked, and it is not what the game does - it
						-- sends the full remainder itself.
						upgrade:FireServer(category, unique, stat, max - current, 'spendAll')
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
	Tooltip = 'Which stat the upgrades go into, and the one your gear is compared on',
	List = {'Highest', 'physicalDamage', 'spellPower', 'health', 'physicalPower'},
	Tooltips = {
		Highest = 'Whichever stat the item is already highest in, so upgrades stack into what it is good at',
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
