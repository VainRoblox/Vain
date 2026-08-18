local TriggerBot
local CPS
local FakeSwing
local SwingAngle
local rayParams = RaycastParams.new()

-- True when any targetable entity is inside reach and within the swing arc in front of
-- you. This is a looser test than the attack check below, which requires the crosshair
-- to actually land on the entity - that gap is what the fake swing fills.
local function targetInAngle(localPos, reach)
	local facing = gameCamera.CFrame.LookVector * Vector3.new(1, 0, 1)
	-- Looking straight up or down flattens to a zero vector, whose .Unit is NaN.
	if facing.Magnitude <= 0 then return false end
	facing = facing.Unit

	for _, ent in entitylib.List do
		if ent.Targetable and ent.RootPart then
			local delta = ent.RootPart.Position - localPos
			if delta.Magnitude <= reach then
				local flat = delta * Vector3.new(1, 0, 1)
				if flat.Magnitude > 0 then
					local angle = math.acos(math.clamp(facing:Dot(flat.Unit), -1, 1))
					if angle <= (math.rad(SwingAngle.Value) / 2) then return true end
				end
			end
		end
	end

	return false
end

local function refreshVisibility()
	if SwingAngle and SwingAngle.Object then
		SwingAngle.Object.Visible = FakeSwing and FakeSwing.Enabled or false
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
					if bedwars.AppController:isLayerOpen(bedwars.UILayers.MAIN) then return end
					if not entitylib.isAlive or store.hand.toolType ~= 'sword' then return end
					if bedwars.DaoController and bedwars.DaoController.chargingMaid then return end

					local tool = store.hand.tool
					local meta = tool and bedwars.ItemMeta[tool.Name]
					-- An unrecognised item leaves meta nil, which used to throw on .sword.
					if not meta or not meta.sword then return end

					local attackRange = meta.sword.attackRange
					local reach = attackRange or 14.4
					local localPos = entitylib.character.RootPart.Position
					rayParams.FilterDescendantsInstances = {lplr.Character}

					local unit = lplr:GetMouse().UnitRay
					local doAttack = false
					local ray = bedwars.QueryUtil:raycast(unit.Origin, unit.Direction * 200, rayParams)
					if ray and (localPos - ray.Instance.Position).Magnitude <= reach then
						for _, ent in entitylib.List do
							if ent.Targetable and ent.RootPart and ent.Character
								and ray.Instance:IsDescendantOf(ent.Character)
								and (localPos - ent.RootPart.Position).Magnitude <= reach then
								doAttack = true
								break
							end
						end
					end

					doAttack = doAttack or bedwars.SwordController:getTargetInRegion(attackRange or 3.8 * 3, 0) and true or false

					if doAttack then
						bedwars.SwordController:swingSwordAtMouse()
						acted = true
					elseif FakeSwing.Enabled and targetInAngle(localPos, reach) then
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
CPS = TriggerBot:CreateTwoSlider({
	Name = 'CPS',
	Tooltip = 'Clicks per second, picked at random between both values',
	Min = 1,
	Max = 9,
	DefaultMin = 7,
	DefaultMax = 7
})
FakeSwing = TriggerBot:CreateToggle({
	Name = 'Fake Swing',
	Tooltip = 'Plays the swing animation when a target is in reach and angle, without attacking',
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
refreshVisibility()
