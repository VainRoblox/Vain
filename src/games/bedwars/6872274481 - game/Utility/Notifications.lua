--[[
	Notifications.

	Calls out key moments in a match. For now, the first time an enemy team gets hold of a
	crossbow or a set of diamond armor - the things worth telling your team about the instant
	they happen, and only worth hearing once.

	Only an enemy counts (your own side getting them is no news), and only the first of the
	match: once announced, that one stays quiet until a new match resets it. What another
	player is carrying is not fully replicated to you - only their worn armor and the item in
	their hand are - so a crossbow is caught the moment an enemy pulls one out, and diamond
	armor the moment it goes on.
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

-- The item type held in one of the character's inventory slots (hand or armor), or nil.
local function slotType(char, name)
	local slot = char:FindFirstChild(name)
	local tool = slot and slot.Value
	return tool and tool.Name or nil
end

local function holdingCrossbow(char)
	local held = slotType(char, 'HandInvItem')
	return type(held) == 'string' and held:lower():find('crossbow') ~= nil
end

local function wearingDiamond(char)
	-- Armor sits in ArmorInvItem_0..3; only armor is ever in those slots, so a 'diamond' in
	-- the name there is diamond armor rather than, say, a held diamond.
	for i = 0, 3 do
		local worn = slotType(char, 'ArmorInvItem_' .. i)
		if type(worn) == 'string' and worn:lower():find('diamond') then
			return true
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
		local char = isEnemy(plr) and plr.Character
		if char then
			if wantCross and holdingCrossbow(char) then
				crossbowFired, wantCross = true, false
				if announce then
					notif('Notifications', plr.Name .. ' got the first Crossbow', 6, 'alert')
				end
			end
			if wantDiamond and wearingDiamond(char) then
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
	Tooltip = 'Notifies when an enemy first pulls out a crossbow this match',
	Default = true
})
FirstDiamondArmor = Notifications:CreateToggle({
	Name = 'First Diamond Armor',
	Tooltip = 'Notifies when an enemy first wears diamond armor this match',
	Default = true
})
