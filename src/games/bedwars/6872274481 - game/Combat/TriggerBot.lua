local TriggerBot
local Targets
local CPS
local GUICheck
local Range
local SwingHeld
local FakeSwing
local SwingAngle
local FakeSwingRange
local rayParams = RaycastParams.new()

local function allowedEntity(ent)
	if not Targets.Players.Enabled and ent.Player then return false end
	if not Targets.NPCs.Enabled and ent.NPC then return false end
	return true
end

local function blocked(localPos, position)
	if not Targets.Walls.Enabled then return false end
	return entitylib.Wallcheck(localPos, position, true) and true or false
end

-- getTargetInRegion is the game's own check and knows nothing about our target filters,
-- so its result is resolved back to one of our entities and tested. If it cannot be
-- resolved the result is accepted rather than dropped, since silently ignoring the
-- game's own hit detection would be worse than letting an unfiltered target through.
local function regionTargetAllowed(result, localPos)
	if not result then return false end

	local ok, ent = pcall(function()
		local instance = result.getInstance and result:getInstance()
		return instance and entitylib.getEntity(instance) or nil
	end)
	if not ok or not ent then return true end

	if not allowedEntity(ent) then return false end
	if ent.RootPart and blocked(localPos, ent.RootPart.Position) then return false end
	return true
end

-- True when any allowed entity is inside the fake swing distance and within the swing arc
-- in front of you. Looser than the attack check below, which needs the crosshair to
-- actually land on the entity - that gap is what the fake swing fills.
local function targetInAngle(localPos)
	local reach = FakeSwingRange.Value
	local facing = gameCamera.CFrame.LookVector * Vector3.new(1, 0, 1)
	-- Looking straight up or down flattens to a zero vector, whose .Unit is NaN.
	if facing.Magnitude <= 0 then return false end
	facing = facing.Unit

	for _, ent in entitylib.List do
		if ent.Targetable and ent.RootPart and allowedEntity(ent) then
			local delta = ent.RootPart.Position - localPos
			if delta.Magnitude <= reach then
				local flat = delta * Vector3.new(1, 0, 1)
				if flat.Magnitude > 0 then
					local angle = math.acos(math.clamp(facing:Dot(flat.Unit), -1, 1))
					if angle <= (math.rad(SwingAngle.Value) / 2) and not blocked(localPos, ent.RootPart.Position) then
						return true
					end
				end
			end
		end
	end

	return false
end

local function refreshVisibility()
	for _, option in {SwingAngle, FakeSwingRange} do
		if option and option.Object then
			option.Object.Visible = FakeSwing and FakeSwing.Enabled or false
		end
	end
end

TriggerBot = vain.Categories.Combat:CreateModule({
	Name = 'TriggerBot',
	Function = function(callback)
		if callback then
			repeat
				local acted = false
				-- Guarded: this reads controllers and item metadata that can be missing for
				-- a frame while switching items or respawning. An error used to kill the
				-- loop outright, leaving the module switched on but permanently dead. The
				-- wait stays outside so a repeating error cannot spin the CPU.
				local ok = pcall(function()
					if GUICheck.Enabled and bedwars.AppController:isLayerOpen(bedwars.UILayers.MAIN) then return end
					if SwingHeld.Enabled and not inputService:IsMouseButtonPressed(0) then return end
					if not entitylib.isAlive or store.hand.toolType ~= 'sword' then return end
					if bedwars.DaoController and bedwars.DaoController.chargingMaid then return end

					local tool = store.hand.tool
					local meta = tool and bedwars.ItemMeta[tool.Name]
					-- An unrecognised item leaves meta nil, which used to throw on .sword.
					if not meta or not meta.sword then return end

					local attackRange = meta.sword.attackRange
					-- Range only ever narrows the item's own reach; going past it would not
					-- land hits anyway.
					local reach = math.min(attackRange or 14.4, Range.Value)
					local localPos = entitylib.character.RootPart.Position
					rayParams.FilterDescendantsInstances = {lplr.Character}

					local unit = lplr:GetMouse().UnitRay
					local doAttack = false
					local ray = bedwars.QueryUtil:raycast(unit.Origin, unit.Direction * 200, rayParams)
					if ray and (localPos - ray.Instance.Position).Magnitude <= reach then
						for _, ent in entitylib.List do
							if ent.Targetable and ent.RootPart and ent.Character and allowedEntity(ent)
								and ray.Instance:IsDescendantOf(ent.Character)
								and (localPos - ent.RootPart.Position).Magnitude <= reach
								and not blocked(localPos, ent.RootPart.Position) then
								doAttack = true
								break
							end
						end
					end

					if not doAttack then
						doAttack = regionTargetAllowed(bedwars.SwordController:getTargetInRegion(attackRange or 3.8 * 3, 0), localPos)
					end

					if doAttack then
						bedwars.SwordController:swingSwordAtMouse()
						acted = true
					elseif FakeSwing.Enabled and targetInAngle(localPos) then
						-- Animation only. playSwordEffect draws the swing without sending an
						-- attack, so a near miss still looks like you are swinging rather
						-- than standing still.
						bedwars.SwordController:playSwordEffect(meta, false)
						if meta.displayName and meta.displayName:find(' Scythe') then
							bedwars.ScytheController:playLocalAnimation()
						end
						acted = true
					end
				end)

				task.wait((ok and acted) and 1 / CPS.GetRandomValue() or 0.016)
			until not TriggerBot.Enabled
		end
	end,
	Tooltip = 'Automatically swings when hovering over a entity'
})
Targets = TriggerBot:CreateTargets({
	Players = true,
	NPCs = true,
	Tooltip = 'Which entities this module is allowed to target'
})
CPS = TriggerBot:CreateTwoSlider({
	Name = 'CPS',
	Tooltip = 'Clicks per second, picked at random between both values',
	Min = 1,
	Max = 9,
	DefaultMin = 7,
	DefaultMax = 7
})
Range = TriggerBot:CreateSlider({
	Name = 'Range',
	Tooltip = 'Caps how far a target can be, in studs',
	Min = 1,
	Max = 18,
	Default = 18,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
GUICheck = TriggerBot:CreateToggle({
	Name = 'GUI check',
	Tooltip = 'Stops swinging while a game menu is open',
	Default = true
})
SwingHeld = TriggerBot:CreateToggle({
	Name = 'Swing While Held',
	Tooltip = 'Only swings while you hold the left mouse button'
})
FakeSwing = TriggerBot:CreateToggle({
	Name = 'Fake Swing',
	Tooltip = 'Plays the swing animation when a target is in distance and angle, without attacking',
	Function = refreshVisibility
})
SwingAngle = TriggerBot:CreateSlider({
	Name = 'Swing Angle',
	Tooltip = 'How wide the arc in front of you counts for the fake swing',
	Min = 1,
	Max = 360,
	Default = 90,
	Darker = true,
	Visible = false
})
FakeSwingRange = TriggerBot:CreateSlider({
	Name = 'Fake Swing Distance',
	Tooltip = 'How far a target can be for the fake swing to play, in studs',
	Min = 1,
	Max = 30,
	Default = 14,
	Darker = true,
	Visible = false,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
refreshVisibility()
