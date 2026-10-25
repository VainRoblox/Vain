--[[
	Notifications.

	Calls out key moments in a match. For now, the first time an enemy team gets hold of a
	crossbow or a set of diamond armor - the things worth telling your team about the instant
	they happen, and only worth hearing once.

	Only an enemy counts (your own side getting them is no news), and only the first of the
	match: once announced, that one stays quiet until a new match resets it. A player's whole
	inventory is live on their character - an InventoryFolder pointing at a folder whose
	children are their items, each named by type - so a crossbow is caught the instant it
	enters their inventory, not only when it is pulled out. Armor goes on as it is bought, so
	diamond armor is read from the worn slots as well.
]]
local Notifications
local FirstCrossbow, FirstDiamondArmor

-- Whether each has already been announced this match.
local crossbowFired, diamondFired = false, false
local lastMatchStart

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function isEnemy(plr)
	if plr == lplr then return false end
	local mine, theirs = lplr:GetAttribute('Team'), plr:GetAttribute('Team')
	return mine ~= nil and theirs ~= nil and tostring(mine) ~= tostring(theirs)
end

-- The item type in one of the character's single-item slots (hand or armor), or nil.
local function slotType(char, name)
	local slot = char:FindFirstChild(name)
	local tool = slot and slot.Value
	return tool and tool.Name or nil
end

-- The folder holding every item a player is carrying, named by item type, live on the
-- character the game reads it from.
local function inventoryFolder(plr)
	local char = plr.Character
	local value = char and char:FindFirstChild('InventoryFolder')
	return value and value.Value
end

local function isArmor(itemType)
	local meta = bedwars.ItemMeta[itemType]
	return meta ~= nil and meta.armor ~= nil
end

-- True the instant a crossbow is anywhere in their inventory, with the held item as a backup
-- for when the folder cannot be resolved.
local function hasCrossbow(plr)
	local folder = inventoryFolder(plr)
	if folder then
		for _, item in folder:GetChildren() do
			if item.Name:lower():find('crossbow') then return true end
		end
	end
	local char = plr.Character
	local held = char and slotType(char, 'HandInvItem')
	return type(held) == 'string' and held:lower():find('crossbow') ~= nil
end

-- Diamond armor, worn or carried. The worn slots only ever hold armor, so a 'diamond' there
-- is diamond armor; in the inventory folder it is filtered to real armor so the diamond
-- resource itself is never mistaken for it.
local function hasDiamondArmor(plr)
	local char = plr.Character
	if char then
		for i = 0, 3 do
			local worn = slotType(char, 'ArmorInvItem_' .. i)
			if type(worn) == 'string' and worn:lower():find('diamond') then return true end
		end
	end
	local folder = inventoryFolder(plr)
	if folder then
		for _, item in folder:GetChildren() do
			if item.Name:lower():find('diamond') and isArmor(item.Name) then return true end
		end
	end
	return false
end

--[[
	One sweep of the enemy players.

	announce is false on the first sweep after the module comes on, so a crossbow or diamond
	set already out when it started is not reported as "the first" - we only missed seeing it
	happen. Every sweep after announces.
]]
local function sweep(announce)
	local wantCross = on(FirstCrossbow) and not crossbowFired
	local wantDiamond = on(FirstDiamondArmor) and not diamondFired
	if not (wantCross or wantDiamond) then return end

	for _, plr in playersService:GetPlayers() do
		if isEnemy(plr) and plr.Character then
			if wantCross and hasCrossbow(plr) then
				crossbowFired, wantCross = true, false
				if announce then
					notif('Notifications', plr.Name .. ' got the first Crossbow', 6, 'alert')
				end
			end
			if wantDiamond and hasDiamondArmor(plr) then
				diamondFired, wantDiamond = true, false
				if announce then
					notif('Notifications', plr.Name .. ' got the first Diamond Armor', 6, 'alert')
				end
			end
			if not (wantCross or wantDiamond) then break end
		end
	end
end

Notifications = vain.Categories.Utility:CreateModule({
	Name = 'Notifications',
	Tooltip = 'Warns you about key match events, like an enemy getting the first crossbow',
	Function = function(callback)
		if callback then
			crossbowFired, diamondFired = false, false
			lastMatchStart = store.matchStartTime
			-- Baseline first, silently, so nothing already out is cried as the first.
			pcall(sweep, false)
			task.spawn(function()
				while Notifications.Enabled do
					-- A new match makes "first" mean first again.
					if store.matchStartTime ~= lastMatchStart then
						lastMatchStart = store.matchStartTime
						crossbowFired, diamondFired = false, false
					end
					pcall(sweep, true)
					task.wait(0.5)
				end
			end)
		end
	end
})
FirstCrossbow = Notifications:CreateToggle({
	Name = 'First Crossbow',
	Tooltip = 'Notifies the moment an enemy first gets a crossbow in their inventory this match',
	Default = true
})
FirstDiamondArmor = Notifications:CreateToggle({
	Name = 'First Diamond Armor',
	Tooltip = 'Notifies when an enemy first wears diamond armor this match',
	Default = true
})
