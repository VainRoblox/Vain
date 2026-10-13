--[[
	Killaura.

	Swings the equipped melee weapon at enemies around you, through the game's own attack.

	The game auto-swings a melee weapon while its handler's `holding` is set - its Update
	runs every frame and calls Swing, which gates itself on the weapon's own cooldown. Real
	input sets `holding` by pressing the attack, but that press is refused while the cursor
	is free (a menu open) and depends on the input path. So this sets `holding` straight on
	the live handler instead - the real one the game is running, read through base - which
	drives the exact same auto-swing with none of that in the way, and still only ever as
	fast as the weapon allows.

	It is a melee aura: a melee handler has a Detect method, a bow or a sling does not, so it
	only engages when a melee weapon is out. Detect is widened while on, through the shared
	hook, so a swing lands on whoever is around you at the range you set rather than only
	what is dead ahead.
]]
local Killaura
local Targets
local Range
local Angle
local Max
local Mouse
local MeleeOnly
local tribes = vain.Libraries.tribes

-- The handler we set holding on, kept so it can be released exactly once.
local held = nil

local function release()
	if held then
		pcall(function() held.holding = false end)
		held = nil
	end
	tribes.clearSwingDetect()
end

-- The live handler to drive, or nil when there is nothing to swing with. A melee handler is
-- the one with a Detect and a Swing; ranged handlers have neither. With Melee Only on, only
-- a melee weapon counts, so the aura never drives a bow or a sling; with it off, whatever is
-- equipped is driven.
local function activeHandler()
	local state = tribes.handlerState()
	local handler = state and state.handler
	if not handler then
		return nil
	end
	if MeleeOnly.Enabled then
		local melee = type(handler.Detect) == 'function' and type(handler.Swing) == 'function'
		return melee and handler or nil
	end
	return handler
end

-- Whether any enemy the module may hit is within range. entitylib has already dropped
-- teammates through the base team check.
local function enemyInRange()
	if not entitylib.isAlive then return false end
	local found = entitylib.AllPosition({
		Range = Range.Value,
		Part = 'RootPart',
		Players = Targets.Players.Enabled,
		NPCs = Targets.NPCs.Enabled,
		Limit = 1
	})
	return #found > 0
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
				if Mouse.Enabled and not inputService:IsMouseButtonPressed(0) then
					release()
					return
				end

				local handler = activeHandler()
				if not handler or not enemyInRange() then
					release()
					return
				end

				-- Widen the game's Detect so the swing reaches around you at the module's
				-- range, not only the weapon's own cone and reach.
				tribes.setSwingDetect(Angle.Value, Max.Value, Range.Value)

				-- Drive the game's own auto-swing on the real handler.
				handler.holding = true
				held = handler
			end))

			Killaura:Clean(release)
		else
			release()
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
	Tooltip = 'How close an enemy must be before it swings',
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
MeleeOnly = Killaura:CreateToggle({
	Name = 'Melee Only',
	Tooltip = 'Only swings when a melee weapon is held',
	Default = true
})
