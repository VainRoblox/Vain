--[[
	Killaura.

	The swing is the game's own: when an enemy is in range this presses Primary through the
	Controller exactly as holding the mouse would, and the game runs its Detect pass and
	sends the hits itself. Nothing here fakes a hit packet - it drives the real attack - so
	it respects the weapon's cooldown and combo and carries the equip token the server checks,
	which a hand-built packet would get wrong.

	Detect only looks down a cone in front of you, so on its own it would hit nobody you were
	not already facing. While this is on it widens that cone through the shared Detect hook,
	so a swing lands on whoever is around you rather than only what is dead ahead, and the
	cone is put back the moment there is nothing to hit or the module goes off.
]]
local Killaura
local Targets
local Range
local Angle
local Max
local Mouse
local tribes = vain.Libraries.tribes

-- Held, not clicked: pressing and releasing every frame fights the game's own combo timing,
-- while holding lets it swing on its own cooldown the way the mouse would. This tracks
-- whether we are currently holding so it is released exactly once.
local holding = false

local function release(controller)
	if holding then
		holding = false
		tribes.clearSwingDetect()
		if controller and controller.Dispatch then
			pcall(controller.Dispatch, 'Primary', false)
		end
	end
end

-- Whether any enemy the module is allowed to hit is within range. Uses the library's own
-- list, so the team check in base has already removed teammates.
local function enemyInRange()
	if not entitylib.isAlive then return false end
	local here = entitylib.character.RootPart
	if not here then return false end
	local plrs = entitylib.AllPosition({
		Range = Range.Value,
		Part = 'RootPart',
		Players = Targets.Players.Enabled,
		NPCs = Targets.NPCs.Enabled,
		Limit = 1
	})
	return #plrs > 0
end

Killaura = vain.Categories.Combat:CreateModule({
	Name = 'Killaura',
	Function = function(callback)
		if callback then
			tribes.hookDetect()
			if not tribes.resolveCombat().Controller then
				notif('Killaura', 'Combat system not found yet - try again in a match', 6, 'alert')
			end

			Killaura:Clean(runService.Heartbeat:Connect(function()
				local controller = tribes.resolveCombat().Controller
				if not (controller and controller.Dispatch) then
					return
				end

				-- Hold only while the mouse is down, when that is asked for.
				if Mouse.Enabled and not inputService:IsMouseButtonPressed(0) then
					release(controller)
					return
				end

				if not enemyInRange() then
					release(controller)
					return
				end

				-- Widen the game's Detect so the swing reaches who is around, not only
				-- ahead, and cap it at the chosen number of targets.
				tribes.setSwingDetect(Angle.Value, Max.Value)

				if not holding then
					holding = true
					pcall(controller.Dispatch, 'Primary', true)
				end
			end))

			Killaura:Clean(function()
				release(tribes.resolveCombat().Controller)
			end)
		else
			release(tribes.resolveCombat().Controller)
		end
	end,
	Tooltip = 'Swings at enemies around you automatically'
})
Targets = Killaura:CreateTargets({
	Players = true,
	Tooltip = 'Which entities it swings at'
})
Range = Killaura:CreateSlider({
	Name = 'Range',
	Tooltip = 'How close an enemy must be before it swings\nYour weapon\'s own reach still applies to the hit',
	Min = 4,
	Max = 30,
	Default = 14,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
Angle = Killaura:CreateSlider({
	Name = 'Angle',
	Tooltip = 'How wide a cone the swing hits in\n180 hits all around you',
	Min = 1,
	Max = 180,
	Default = 180,
	Suffix = 'degrees'
})
Max = Killaura:CreateSlider({
	Name = 'Max Targets',
	Tooltip = 'How many enemies one swing may hit',
	Min = 1,
	Max = 6,
	Default = 3
})
Mouse = Killaura:CreateToggle({
	Name = 'Require Mouse',
	Tooltip = 'Only swings while you hold left click'
})
