local AimAssist
local Targets
local Sort
local AimSpeed
local Distance
local AngleSlider
local StrafeIncrease
local KillauraTarget
local ClickAim

AimAssist = vain.Categories.Combat:CreateModule({
	Name = 'AimAssist',
	Function = function(callback)
		if callback then
			AimAssist:Clean(runService.Heartbeat:Connect(function(dt)
				if entitylib.isAlive and store.hand.toolType == 'sword' and ((not ClickAim.Enabled) or (tick() - bedwars.SwordController.lastSwing) < 0.4) then
					local ent = not KillauraTarget.Enabled and entitylib.EntityPosition({
						Range = Distance.Value,
						Part = 'RootPart',
						Wallcheck = Targets.Walls.Enabled,
						Players = Targets.Players.Enabled,
						NPCs = Targets.NPCs.Enabled,
						Preference = Targets.Preference.Value,
						Sort = sortmethods[Sort.Value]
					}) or store.KillauraTarget

					if ent and ent.RootPart then
						local delta = (ent.RootPart.Position - entitylib.character.RootPart.Position)
						local localfacing = entitylib.character.RootPart.CFrame.LookVector * Vector3.new(1, 0, 1)
						-- Flatten first and bail on a zero-length horizontal delta. A target
						-- directly above or below you (a diamond guardian over the generator
						-- you are standing under) leaves a zero vector, whose .Unit is NaN.
						-- Comparisons against NaN are always false, so the angle limit was
						-- silently skipped and the camera got yanked to a target that should
						-- have been rejected. Clamping the dot also guards float error
						-- pushing it a hair outside acos's valid range.
						local flat = delta * Vector3.new(1, 0, 1)
						if flat.Magnitude <= 0 then return end
						local angle = math.acos(math.clamp(localfacing:Dot(flat.Unit), -1, 1))
						if angle >= (math.rad(AngleSlider.Value) / 2) then return end
						targetinfo.Targets[ent] = tick() + 1
						gameCamera.CFrame = gameCamera.CFrame:Lerp(CFrame.lookAt(gameCamera.CFrame.p, ent.RootPart.Position), (AimSpeed.Value + (StrafeIncrease.Enabled and (inputService:IsKeyDown(Enum.KeyCode.A) or inputService:IsKeyDown(Enum.KeyCode.D)) and 10 or 0)) * dt)
					end
				end
			end))
		end
	end,
	Tooltip = 'Smoothly aims to closest valid target with sword'
})
Targets = AimAssist:CreateTargets({
	Players = true,
	Walls = true,
	Tooltip = 'Which entities this module is allowed to target'
})
-- Damage/Distance stay pinned to the front (Damage is the default), the rest are
-- sorted so the dropdown order stays stable - iterating sortmethods directly is
-- hash order, which reshuffles the list between injections.
local methods, extramethods = {'Damage', 'Distance'}, {}
for i in sortmethods do
	if not table.find(methods, i) then
		table.insert(extramethods, i)
	end
end
table.sort(extramethods)
for _, v in extramethods do
	table.insert(methods, v)
end
Sort = AimAssist:CreateDropdown({
	Name = 'Target Mode',
	Tooltip = 'How targets are ranked when several are valid at once',
	List = methods,
	Tooltips = sortmethodtips
})
AimSpeed = AimAssist:CreateSlider({
	Name = 'Aim Speed',
	Tooltip = 'How quickly your aim moves toward the target',
	Min = 1,
	Max = 20,
	Default = 6
})
Distance = AimAssist:CreateSlider({
	Name = 'Distance',
	Tooltip = 'Furthest a target can be, in studs',
	Min = 1,
	Max = 30,
	Default = 30,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
AngleSlider = AimAssist:CreateSlider({
	Name = 'Max angle',
	Tooltip = 'Widest angle from your view a target may be at',
	Min = 1,
	Max = 360,
	Default = 70
})
ClickAim = AimAssist:CreateToggle({
	Name = 'Click Aim',
	Tooltip = 'Only aims while you are clicking',
	Default = true
})
KillauraTarget = AimAssist:CreateToggle({
	Name = 'Use killaura target',
	Tooltip = 'Aims at whatever Killaura is currently attacking'
})
StrafeIncrease = AimAssist:CreateToggle({Name = 'Strafe increase', Tooltip = 'Speeds up while strafing'})