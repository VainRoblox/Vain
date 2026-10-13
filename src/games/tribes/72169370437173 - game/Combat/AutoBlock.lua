--[[
	Auto Block.

	Raises your guard when an enemy near you is facing your way - the moment a swing is most
	likely coming - and lowers it again when the threat passes, so you block the hit without
	holding guard up the whole fight. Blocking is the game's own Secondary on a weapon that
	can block; on a weapon that cannot, Secondary is a heavy or a lunge, so this never
	presses it unless the equipped weapon actually guards. That check reads the live handler
	through base, which is also why a true parry - blocking only in the split second a swing
	lands - is left for later: the timing has to come from the attacker's swing, not from how
	near they are.

	Facing is the tell it uses: an enemy within range whose look is turned toward you is
	treated as a threat. It is not frame-perfect, but it blocks the hits that a held guard
	would, without giving up your own swings the rest of the time.
]]
local AutoBlock
local Range
local Angle
local tribes = vain.Libraries.tribes

-- Held, so the guard is raised and dropped exactly once rather than re-sent every frame.
local blocking = false

local function setBlock(controller, on)
	if on == blocking then return end
	blocking = on
	if controller and controller.Dispatch then
		pcall(controller.Dispatch, 'Secondary', on)
	end
end

-- Whether an enemy near you is turned toward you. The dot of the enemy's look against the
-- direction from them to you rises as they face you; the slider is that cone in degrees.
local function threatNear()
	if not entitylib.isAlive then return false end
	local me = entitylib.character.RootPart
	if not me then return false end

	local threshold = math.cos(math.rad(Angle.Value / 2))
	for _, entity in entitylib.List do
		local root = entity.RootPart
		if entity.Targetable and root then
			local delta = me.Position - root.Position
			local dist = delta.Magnitude
			if dist <= Range.Value and dist > 0.05 then
				if root.CFrame.LookVector:Dot(delta.Unit) >= threshold then
					return true
				end
			end
		end
	end
	return false
end

AutoBlock = vain.Categories.Combat:CreateModule({
	Name = 'Auto Block',
	Function = function(callback)
		if callback then
			AutoBlock:Clean(runService.Heartbeat:Connect(function()
				local controller = tribes.resolveCombat().Controller
				if not (controller and controller.Dispatch) then
					return
				end

				-- Never guard with a weapon that does not guard - Secondary there is an
				-- attack, not a block.
				if not tribes.canBlock() then
					setBlock(controller, false)
					return
				end

				setBlock(controller, threatNear())
			end))

			AutoBlock:Clean(function()
				setBlock(tribes.resolveCombat().Controller, false)
			end)
		else
			setBlock(tribes.resolveCombat().Controller, false)
		end
	end,
	Tooltip = 'Raises your guard when an enemy faces you'
})
Range = AutoBlock:CreateSlider({
	Name = 'Range',
	Tooltip = 'How close an enemy must be to guard against them',
	Min = 4,
	Max = 30,
	Default = 12,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
Angle = AutoBlock:CreateSlider({
	Name = 'Facing Angle',
	Tooltip = 'How directly an enemy must face you to count as a threat\nWider guards against more',
	Min = 10,
	Max = 180,
	Default = 80,
	Suffix = 'degrees'
})
