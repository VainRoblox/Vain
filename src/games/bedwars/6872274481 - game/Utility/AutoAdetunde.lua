-- Lives in Utility/ rather than a Kit/ folder because VainBundler enumerates a
-- hardcoded category list (Combat, Blatant, Render, Utility, World, Inventory,
-- Minigames, Legit) - a Kit/ folder is skipped entirely and never reaches the
-- compiled bundle. The folder only decides what gets bundled; the category a
-- module appears under is the one it is created from, which is Kit below.
local AutoAdetunde
local Priority
local Notify
local KeepJump

-- How long after firing an upgrade to treat the player as "upgrading". The block is
-- brief, and keeping the window tight matters: leaps and dashes legitimately zero
-- jumping too, and restoring it during one of those would break the ability.
local JUMP_WINDOW = 2
local upgradingUntil = 0
local lastJumpHeight, lastJumpPower

-- Level costs are the same for all three tracks: 2, 5 then 12 frost crystals
-- (FrostyHammerBalance.{ATTACK,SPEED,SHIELD}_LEVEL{1,2,3}_COST).
local COSTS = {2, 5, 12}
local CURRENCY = 'frost_crystal'

-- The enum is not a Knit controller, so the bedwars table cannot reach it - that
-- metatable falls back to Knit.Controllers and would just hand back nil. Required
-- straight from the module the game imports it from, and left nil if that path
-- moves so the module degrades to doing nothing instead of throwing every pass.
local upgrades
local function resolveUpgrades()
	if upgrades then return upgrades end
	local ok, module = pcall(function()
		return require(replicatedStorage.TS.games.bedwars.items['frosty-hammer']['frosty-hammer-upgrades'])
	end)
	upgrades = ok and module or nil
	return upgrades
end
task.spawn(resolveUpgrades)

-- Levels live as attributes on the player, keyed by the enum's *value* rather than
-- its name, which is why these are read through the enum instead of hardcoded.
local function levelOf(upgrade)
	return lplr:GetAttribute(upgrade) or 0
end

local function crystals()
	local item = getItem(CURRENCY)
	return item and item.amount or 0
end

-- Priority track first until it is maxed, then whatever is left. Order within the
-- remainder is fixed so repeated passes cannot flip-flop between two tracks.
local function buyOrder(enum)
	local order, chosen = {}, Priority.Value:upper()
	if enum[chosen] then
		table.insert(order, enum[chosen])
	end
	for _, name in {'STRENGTH', 'SPEED', 'SHIELD'} do
		local value = enum[name]
		if value and value ~= enum[chosen] then
			table.insert(order, value)
		end
	end
	return order
end

local function nextPurchase(enum)
	for _, upgrade in buyOrder(enum) do
		local level = levelOf(upgrade)
		if level < #COSTS then
			return upgrade, level + 1, COSTS[level + 1]
		end
	end
end

AutoAdetunde = vain.Categories.Kit:CreateModule({
	Name = 'AutoAdetunde',
	Function = function(callback)
		if callback then
			upgradingUntil = 0
			AutoAdetunde:Clean(runService.RenderStepped:Connect(function()
				if not (KeepJump.Enabled and entitylib.isAlive) then return end
				local humanoid = entitylib.character.Humanoid

				-- Remember the last non-zero values so there is something real to put
				-- back, rather than assuming Roblox's defaults - the kit and the game
				-- both adjust these.
				if humanoid.JumpHeight > 0 then lastJumpHeight = humanoid.JumpHeight end
				if humanoid.JumpPower > 0 then lastJumpPower = humanoid.JumpPower end

				-- Only inside the upgrade window, so abilities that zero jumping on
				-- purpose are left alone.
				if tick() >= upgradingUntil then return end
				if lastJumpHeight and humanoid.JumpHeight <= 0 then
					humanoid.JumpHeight = lastJumpHeight
				end
				if lastJumpPower and humanoid.JumpPower <= 0 then
					humanoid.JumpPower = lastJumpPower
				end
			end))

			repeat
				-- Guarded and yielding outside the pcall, so a bad pass cannot spin.
				local ok = pcall(function()
					local enum = resolveUpgrades()
					enum = enum and enum.FrostyHammerUpgrade
					if not enum then return end
					if not entitylib.isAlive then return end
					if store.equippedKit ~= '' and store.equippedKit ~= 'adetunde' then return end

					local upgrade, level, cost = nextPurchase(enum)
					if not upgrade or crystals() < cost then return end

					upgradingUntil = tick() + JUMP_WINDOW
					bedwars.Client:Get('UpgradeFrostyHammer'):CallServerAsync(upgrade):andThen(function(result)
						if result ~= false and Notify.Enabled then
							notif('AutoAdetunde', 'Upgraded '..tostring(upgrade):lower()..' to '..level, 3)
						end
					end)
				end)

				task.wait(ok and 0.5 or 1)
			until not AutoAdetunde.Enabled
		end
	end,
	ExtraText = function()
		return Priority.Value
	end,
	Tooltip = 'Upgrades the Frosty Hammer as soon as you can afford it'
})
Priority = AutoAdetunde:CreateDropdown({
	Name = 'Priority',
	Tooltip = 'Which upgrade to max out before spending on anything else',
	List = {'Strength', 'Speed', 'Shield'},
	Tooltips = {
		Strength = 'More hammer damage',
		Speed = 'Faster hammer swings',
		Shield = 'More shield from the hammer'
	}
})
KeepJump = AutoAdetunde:CreateToggle({
	Name = 'Keep Jump',
	Tooltip = 'Restores your jump if buying an upgrade takes it away',
	Default = true
})
Notify = AutoAdetunde:CreateToggle({
	Name = 'Notify',
	Tooltip = 'Shows a notification for each upgrade bought',
	Default = true
})
