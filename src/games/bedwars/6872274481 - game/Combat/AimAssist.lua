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
local ProjectileSpeed
-- Brought over from the Aim Assist that used to live in KitModules, so the two could
-- become one module rather than two with almost the same name.
local ViewMode
local MinDistance
local ShopCheck
local LimitToItem
local HealthCheck
local HealthThreshold

-- Reused for the projectile trajectory solve, same as ProjectileAimbot does: only the
-- map blocks the shot, players are not obstacles to aim around.
local aimRayCheck = RaycastParams.new()
aimRayCheck.FilterType = Enum.RaycastFilterType.Include
local mapfolder

-- Resolved on use rather than once at load, which is what the sibling modules do and
-- what the comment above always claimed this did. The map does not exist yet if you
-- inject while the round is loading, and an Include filter holding nothing hits nothing -
-- so the solve never saw the ground and never clamped a falling target to it.
local function refreshMapFilter()
	local map = workspace:FindFirstChild('Map')
	if map ~= mapfolder then
		mapfolder = map
		aimRayCheck.FilterDescendantsInstances = map and {map} or {}
	end
end

-- Remembered between frames so 'Lock on Target' can keep aiming at the same entity
-- instead of re-picking the closest one every heartbeat.
local locked

-- Humanize state. The drift is a slow wander toward a re-rolled target offset, not a
-- fresh random value per frame: per-frame randomness is white noise, which reads on
-- screen as a harsh flicker rather than as a human hand. Holding an offset and easing
-- toward a new one keeps the motion continuous.
local humanizeoffset, humanizetarget, humanizenext = Vector2.zero, Vector2.zero, 0

-- Named once so binding and unbinding cannot drift apart.
local RENDER_BIND = 'VainAimAssist'

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
	-- Off, this assists with whatever is in hand rather than only a weapon. Nothing else
	-- changes: without a projectile source there is no arc to solve, so it aims straight.
	if LimitToItem ~= nil and not LimitToItem.Enabled then return true, false end
	return false
end

-- A UI being open is the mouse being free, which is the same test the shop check in the
-- module this was merged from used.
local function uiOpen()
	return inputService.MouseBehavior == Enum.MouseBehavior.Default
end

local function viewAllows()
	if ViewMode == nil or ViewMode.Value == 'Both' then return true end
	local first = bedwars.isFirstPerson and bedwars.isFirstPerson()
	return (ViewMode.Value == 'First Person') == (first == true)
end

-- The target is close enough to matter and hurt enough to be worth it. Health is read off
-- the entity, which mirrors the character's Health attribute - Humanoid.Health is pinned
-- at 100 in this game and says nothing.
local function targetAllows(ent)
	if MinDistance ~= nil and MinDistance.Value > 0 and ent.RootPart and entitylib.character and entitylib.character.RootPart then
		if (ent.RootPart.Position - entitylib.character.RootPart.Position).Magnitude < MinDistance.Value then
			return false
		end
	end

	if HealthCheck ~= nil and HealthCheck.Enabled then
		local hp = ent.Health
		if hp == nil and ent.Character then
			hp = ent.Character:GetAttribute('Health')
		end
		if hp and hp > (HealthThreshold and HealthThreshold.Value or 100) then
			return false
		end
	end

	return true
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

	refreshMapFilter()

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
			--[[
				Bound to the render step above the camera, not to Heartbeat.

				Roblox's camera script runs during the render step and builds the CFrame
				from its own yaw and pitch - it never reads Camera.CFrame back. Heartbeat
				fires after the frame is already rendered, so a write there survived only
				until the next render step recomputed over the top of it, and the assist
				moved the camera for no frame anyone ever saw.

				Binding one priority above Camera puts this after that recompute in the
				same frame, which is the only point a write to the camera holds.
			]]
			runService:BindToRenderStep(RENDER_BIND, Enum.RenderPriority.Camera.Value + 1, function(dt)
				-- Guarded as a whole: this reads game state that can disappear between
				-- frames (entities dying, the held item changing mid-swing). A throw here
				-- would otherwise spam the console every single frame.
				pcall(function()
					if not entitylib.isAlive then return end

					local allowed, issword = heldAllows()
					if not allowed then return end

					if not viewAllows() then return end
					if ShopCheck ~= nil and ShopCheck.Enabled and uiOpen() then return end

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
					if not targetAllows(ent) then return end

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

					-- Projectiles get their own, much higher speed. A bow shot is a single
					-- instant with no second chance, so the camera has to be on target
					-- before it leaves your hand - unlike melee, where a slow drift still
					-- lands hits because you keep swinging. At 60+ the per-frame alpha
					-- reaches 1 and it snaps outright.
					local basespeed = (not issword) and ProjectileSpeed.Value or AimSpeed.Value
					local speed = basespeed + (StrafeIncrease.Enabled and (inputService:IsKeyDown(Enum.KeyCode.A) or inputService:IsKeyDown(Enum.KeyCode.D)) and 10 or 0)
					local alpha
					if AimMode.Value == 'Constant' then
						-- Turn at a fixed angular rate: work out what fraction of the
						-- remaining error that rate covers this frame. Distance to the
						-- target stops mattering, which is what makes it look steady.
						local step = math.rad(speed * 15) * dt
						alpha = err > 0 and (step / err) or 0
					else
						alpha = speed * dt
						-- Smooth easing is deliberately skipped for projectiles. Easing off
						-- near the target is what makes melee tracking look human, but it is
						-- precisely the last degree that decides whether a shot lands, and
						-- damping it there is what made shooting feel slow.
						if AimMode.Value == 'Smooth' and issword then
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
						local amplitude = math.rad(Humanize.Value / 40)
						-- Re-roll where the drift is heading every third of a second or so.
						-- The random interval stops it settling into a visible rhythm.
						if tick() >= humanizenext then
							humanizenext = tick() + 0.25 + math.random() * 0.35
							humanizetarget = Vector2.new((math.random() - 0.5) * 2, (math.random() - 0.5) * 2) * amplitude
						end
						-- Ease toward that target rather than jumping to it, so every frame
						-- is a small continuation of the last instead of an independent jolt.
						humanizeoffset = humanizeoffset:Lerp(humanizetarget, math.clamp(dt * 4, 0, 1))
						newcframe = newcframe * CFrame.Angles(humanizeoffset.Y, humanizeoffset.X, 0)
					end

					gameCamera.CFrame = newcframe
				end)
			end)

			AimAssist:Clean(function()
				pcall(runService.UnbindFromRenderStep, runService, RENDER_BIND)
			end)
		else
			locked = nil
			humanizeoffset, humanizetarget, humanizenext = Vector2.zero, Vector2.zero, 0
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
		RootPart = 'Aims at the body',
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
		Smooth = 'Eases off as the crosshair approaches',
		Constant = 'Turns at a steady speed no matter how far off the target is'
	}
})
Smoothness = AimAssist:CreateSlider({
	Name = 'Smoothness',
	Tooltip = 'Only used by Smooth mode.\nHigher values start easing off from further away.',
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
ProjectileSpeed = AimAssist:CreateSlider({
	Name = 'Projectile Aim Speed',
	Tooltip = 'Aim speed used while holding a projectile, replacing Aim Speed.\n60 and above snaps instantly.',
	Min = 1,
	Max = 100,
	Default = 45
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
	Tooltip = 'Adds a slow, continuous drift to the aim.\n0 disables it.',
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
	Tooltip = 'Sticks to one target until it dies or leaves range'
})
UseProjectile = AimAssist:CreateToggle({
	Name = 'Use Projectile',
	Tooltip = 'Also aims while holding a projectile weapon, and leads the shot to where the target is moving'
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
ViewMode = AimAssist:CreateDropdown({
	Name = 'View Mode',
	Tooltip = 'Which camera view this aims in',
	List = {'Both', 'First Person', 'Third Person'},
	Default = 'Both'
})
MinDistance = AimAssist:CreateSlider({
	Name = 'Min Distance',
	Tooltip = 'Skips targets closer than this, where you do not need the help. 0 is off',
	Min = 0, Max = 50, Default = 0, Suffix = 'm'
})
LimitToItem = AimAssist:CreateToggle({
	Name = 'Limit to item',
	Tooltip = 'Only assists while holding a weapon. Off assists with anything in hand',
	Default = true
})
ShopCheck = AimAssist:CreateToggle({
	Name = 'Shop Check',
	Tooltip = 'Stops while the shop or any other menu is open'
})
HealthCheck = AimAssist:CreateToggle({
	Name = 'Target HP Check',
	Tooltip = 'Only assists once the target is hurt enough',
	Function = function(callback)
		if HealthThreshold and HealthThreshold.Object then
			HealthThreshold.Object.Visible = callback
		end
	end
})
HealthThreshold = AimAssist:CreateSlider({
	Name = 'Target Health',
	Tooltip = 'The health at or below which a target is worth assisting on',
	Min = 1, Max = 100, Default = 100, Suffix = 'hp',
	Visible = false,
	Darker = true
})
