local AimAssist
local Targets
local Sort
local AimPart
local AimMode
local Smoothness
local AimSpeed
local Distance
local AngleSlider
local StrafeIncrease
local KillauraTarget
local ClickAim
local LockTarget
local Falloff
local Humanize
local UseProjectile

-- Reused for the projectile trajectory solve, same as ProjectileAimbot does: only the
-- map blocks the shot, players are not obstacles to aim around.
local aimRayCheck = RaycastParams.new()
aimRayCheck.FilterType = Enum.RaycastFilterType.Include
aimRayCheck.FilterDescendantsInstances = {workspace:FindFirstChild('Map')}

-- Remembered between frames so 'Lock on Target' can keep aiming at the same entity
-- instead of re-picking the closest one every heartbeat.
local locked

local function heldItemMeta()
	local hand = store.hand
	local tool = hand and hand.tool
	return tool and bedwars.ItemMeta[tool.Name] or nil
end

-- Sword always qualifies. With Use Projectile on, anything the game considers a
-- projectile source counts too - that covers thrown items and fired weapons alike,
-- since both carry a projectileSource in their item meta.
local function heldAllows()
	local hand = store.hand
	if not hand then return false end
	if hand.toolType == 'sword' then return true, true end
	if UseProjectile.Enabled then
		local meta = heldItemMeta()
		if meta and meta.projectileSource then return true, false end
	end
	return false
end

local function angleTo(position)
	local campos = gameCamera.CFrame.Position
	local delta = position - campos
	if delta.Magnitude <= 0 then return nil end
	return math.acos(math.clamp(gameCamera.CFrame.LookVector:Dot(delta.Unit), -1, 1)), delta
end

local function aimPart(ent)
	local head, root = ent.Head, ent.RootPart
	local value = AimPart.Value
	if value == 'Head' then return head or root end
	if value == 'Nearest' then
		-- Whichever part is currently the smaller camera movement away, so the assist
		-- takes the shortest correction rather than always dragging to one part.
		if not head then return root end
		if not root then return head end
		local ha, ra = angleTo(head.Position), angleTo(root.Position)
		if not ha then return root end
		if not ra then return head end
		return ha <= ra and head or root
	end
	return root
end

-- Where to point so a fired projectile actually lands on the target, rather than
-- pointing straight at them and shooting under their feet. Returns nil when the solve
-- fails or the item is not a projectile, in which case the caller aims directly.
local function projectileAimPos(ent, part)
	local meta = heldItemMeta()
	local source = meta and meta.projectileSource
	if not source then return nil end

	local ok, solved = pcall(function()
		local ammo = source.ammoItemTypes and source.ammoItemTypes[1] or 'arrow'
		local projname = type(source.projectileType) == 'function' and source.projectileType(ammo) or source.projectileType
		local projmeta = projname and bedwars.ProjectileMeta[projname]
		if not projmeta then return nil end

		return prediction.SolveTrajectory(
			gameCamera.CFrame.Position,
			projmeta.launchVelocity or 100,
			projmeta.gravitationalAcceleration or 196.2,
			part.Position,
			part.Velocity,
			workspace.Gravity,
			ent.HipHeight,
			ent.Jumping and 42.6 or nil,
			aimRayCheck
		)
	end)

	return ok and solved or nil
end

local function pickTarget()
	if KillauraTarget.Enabled then return store.KillauraTarget end

	if LockTarget.Enabled and locked and locked.RootPart and entitylib.isAlive then
		local stillvalid = pcall(function()
			return entitylib.isVulnerable(locked)
		end)
		if stillvalid and (locked.RootPart.Position - entitylib.character.RootPart.Position).Magnitude <= Distance.Value then
			return locked
		end
	end

	local ent = entitylib.EntityPosition({
		Range = Distance.Value,
		Part = 'RootPart',
		Wallcheck = Targets.Walls.Enabled,
		Players = Targets.Players.Enabled,
		NPCs = Targets.NPCs.Enabled,
		Preference = Targets.Preference.Value,
		Sort = sortmethods[Sort.Value]
	})
	locked = ent
	return ent
end

AimAssist = vain.Categories.Combat:CreateModule({
	Name = 'AimAssist',
	Function = function(callback)
		if callback then
			AimAssist:Clean(runService.Heartbeat:Connect(function(dt)
				-- Guarded as a whole: this reads game state that can disappear between
				-- frames (entities dying, the held item changing mid-swing). A throw here
				-- would otherwise spam the console every single frame.
				pcall(function()
					if not entitylib.isAlive then return end

					local allowed, issword = heldAllows()
					if not allowed then return end

					if ClickAim.Enabled then
						if issword then
							if (tick() - bedwars.SwordController.lastSwing) >= 0.4 then return end
						elseif not inputService:IsMouseButtonPressed(0) then
							-- Projectiles have no swing to time against, so fall back to
							-- "only while actually holding the mouse down".
							return
						end
					end

					local ent = pickTarget()
					if not ent or not ent.RootPart then return end

					local part = aimPart(ent)
					if not part then return end

					local delta = (ent.RootPart.Position - entitylib.character.RootPart.Position)
					local localfacing = entitylib.character.RootPart.CFrame.LookVector * Vector3.new(1, 0, 1)
					-- Flatten first and bail on a zero-length horizontal delta. A target
					-- directly above or below you (a diamond guardian over the generator
					-- you are standing under) leaves a zero vector, whose .Unit is NaN.
					-- Comparisons against NaN are always false, so the angle limit was
					-- silently skipped and the camera got yanked to a target that should
					-- have been rejected.
					local flat = delta * Vector3.new(1, 0, 1)
					if flat.Magnitude <= 0 then return end
					local facingangle = math.acos(math.clamp(localfacing:Dot(flat.Unit), -1, 1))
					if facingangle >= (math.rad(AngleSlider.Value) / 2) then return end

					local aimpos = part.Position
					if not issword and UseProjectile.Enabled then
						aimpos = projectileAimPos(ent, part) or aimpos
					end

					local err, aimdelta = angleTo(aimpos)
					if not err then return end

					targetinfo.Targets[ent] = tick() + 1

					local speed = AimSpeed.Value + (StrafeIncrease.Enabled and (inputService:IsKeyDown(Enum.KeyCode.A) or inputService:IsKeyDown(Enum.KeyCode.D)) and 10 or 0)
					local alpha
					if AimMode.Value == 'Constant' then
						-- Turn at a fixed angular rate: work out what fraction of the
						-- remaining error that rate covers this frame. Distance to the
						-- target stops mattering, which is what makes it look steady.
						local step = math.rad(speed * 15) * dt
						alpha = err > 0 and (step / err) or 0
					else
						alpha = speed * dt
						if AimMode.Value == 'Smooth' then
							-- Ease out: the closer the crosshair already is, the gentler the
							-- correction, so it settles instead of snapping the last degree.
							-- Higher Smoothness widens the window over which it eases.
							alpha = alpha * math.clamp(err / math.rad(Smoothness.Value * 2), 0.08, 1)
						end
					end

					if Falloff.Enabled then
						-- Strength drops off with range, so distant targets get a nudge and
						-- close ones get the full pull. Independent of Smooth, which eases on
						-- angle rather than distance.
						alpha = alpha * math.clamp(1 - (aimdelta.Magnitude / math.max(Distance.Value, 1)), 0.15, 1)
					end

					local newcframe = gameCamera.CFrame:Lerp(CFrame.lookAt(gameCamera.CFrame.Position, aimpos), math.clamp(alpha, 0, 1))

					if Humanize.Value > 0 then
						-- Small random wobble so the path is not perfectly mechanical.
						local jitter = math.rad(Humanize.Value / 20)
						newcframe = newcframe * CFrame.Angles((math.random() - 0.5) * jitter, (math.random() - 0.5) * jitter, 0)
					end

					gameCamera.CFrame = newcframe
				end)
			end))
		else
			locked = nil
		end
	end,
	Tooltip = 'Smoothly aims at a valid target while holding a sword, or any projectile with Use Projectile on'
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
AimPart = AimAssist:CreateDropdown({
	Name = 'Aim Part',
	Tooltip = 'Which part of the target to aim at',
	List = {'RootPart', 'Head', 'Nearest'},
	Tooltips = {
		RootPart = 'Aims at the body - the largest and most forgiving target',
		Head = 'Aims at the head',
		Nearest = 'Aims at whichever of the two needs the smaller camera movement'
	}
})
AimMode = AimAssist:CreateDropdown({
	Name = 'Aim Mode',
	Tooltip = 'How the camera moves toward the target',
	List = {'Linear', 'Smooth', 'Constant'},
	Tooltips = {
		Linear = 'Moves a fixed fraction of the way each frame - fast at first, slower as it closes in',
		Smooth = 'Eases off as the crosshair approaches, so it settles instead of snapping',
		Constant = 'Turns at a steady speed no matter how far off the target is'
	}
})
Smoothness = AimAssist:CreateSlider({
	Name = 'Smoothness',
	Tooltip = 'Only used by Smooth mode.\nHigher values start easing off from further away, giving a softer finish.',
	Min = 1,
	Max = 30,
	Default = 10
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
Humanize = AimAssist:CreateSlider({
	Name = 'Humanize',
	Tooltip = 'Adds a small random wobble so the aim path is not perfectly mechanical.\n0 disables it.',
	Min = 0,
	Max = 100,
	Default = 0,
	Suffix = function()
		return '%'
	end
})
ClickAim = AimAssist:CreateToggle({
	Name = 'Click Aim',
	Tooltip = 'Only aims while you are attacking - holding the mouse down for projectiles',
	Default = true
})
LockTarget = AimAssist:CreateToggle({
	Name = 'Lock on Target',
	Tooltip = 'Sticks to one target until it dies or leaves range, instead of switching to whoever is closest each frame'
})
UseProjectile = AimAssist:CreateToggle({
	Name = 'Use Projectile',
	Tooltip = 'Also aims while holding a projectile weapon, and leads the shot so the arrow lands on the target instead of pointing straight at them'
})
Falloff = AimAssist:CreateToggle({
	Name = 'Falloff',
	Tooltip = 'Weakens the assist the further away the target is'
})
KillauraTarget = AimAssist:CreateToggle({
	Name = 'Use killaura target',
	Tooltip = 'Aims at whatever Killaura is currently attacking'
})
StrafeIncrease = AimAssist:CreateToggle({Name = 'Strafe increase', Tooltip = 'Speeds up while strafing'})
