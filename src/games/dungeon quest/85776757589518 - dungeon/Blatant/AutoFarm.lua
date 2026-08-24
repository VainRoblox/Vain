local AutoFarm
local warned = false
local nextAbility = 0
local abilityIndex = 1
local candidates = {}
local nextScan = 0
local incoming = {}
local currentRoot
local autoRotate
local nextSwing = 0

-- Swings are paced rather than thrown every pass.
--
-- Without this the module asked Godmode for an attack window on every single pass, so
-- the window never closed and the root never went back into hiding - Godmode was
-- surfaced permanently and protected nothing. Leaving gaps between swings is what gives
-- it somewhere to hide, and a weapon cannot swing faster than its own animation anyway,
-- so nothing is lost.
local SWING_INTERVAL = 0.6

-- Dodging.
--
-- What counts as a projectile here is not something that can be looked up, so it is
-- recognised by behaviour instead: a loose part, not part of anybody's body, travelling
-- fast enough that it was fired rather than dropped. Anything matching is watched
-- briefly then forgotten, since projectiles do not live long and a stale list is worse
-- than none.
local PROJECTILE_SPEED = 25
local WATCH_FOR = 3
-- How close it has to be heading, and how far ahead to care. Reacting to everything on
-- the map would have you sidestepping shots that were never going to land.
local DODGE_RADIUS = 10
local LOOK_AHEAD = 1.5
local DODGE_DISTANCE = 14

-- Where to sit relative to the enemy.
--
-- Overhead, and high enough that ground melee cannot reach you - being hit back was
-- killing runs. An earlier version blamed height for swings not landing, but attacks
-- were going through tool:Activate then, which does nothing in this game at all; height
-- was never why they missed. Now that a swing is a real click at the crosshair the limit
-- is the weapon's own range, so height is free and worth taking.
local STAND_OFF = 2
-- Just inside melee reach. Higher was out of range of your own swings, and height is not
-- what keeps you alive anyway - Godmode is, by moving the part you are hit through.
--
-- WeaponReach stretches the weapon's own hit check, so with that on there is room to
-- stand further off. It is left short here regardless, because this has to work whether
-- that module is on or not, and standing close costs nothing when it is.
local STAND_UP = 7

-- Attacking through tool:Activate and firetouchinterest does nothing here. That works in
-- games whose damage comes off a touch or off the tool itself; this one runs combat
-- through its own input handlers, which fire its own remotes. Simulating the input lets
-- the game's own code do the rest, and whatever validation it applies is satisfied
-- because these are its own attacks.
local virtualInput = cloneref(game:GetService('VirtualInputManager'))

-- The game's actual ability keys, rather than a spread of guesses.
--
-- Two earlier versions cycled a broad set hoping to land on the right ones. The number
-- row turned out to be Roblox's backpack hotbar, so those presses were unequipping the
-- weapon rather than casting, and the letters after that were no better than a guess.
-- Pressing only what is bound means nothing is wasted and nothing has a side effect.
local ABILITY_KEYS = {
	Enum.KeyCode.Q,
	Enum.KeyCode.E
}

-- The scan, the swing, the abilities and the equip check all live in the base now, so
-- AutoKill shares one copy of each rather than carrying its own that drifts.
local dq = vain.Libraries.dungeonquest

-- Projectile watching and the dodge maths stay here rather than moving to the base with
-- the rest: they are AutoFarm's alone, and nothing else needs them.
-- Watched from the moment they appear rather than found by scanning: a projectile is in
-- the air for a fraction of a second, so anything rebuilt on a timer would miss it.
local function watchProjectiles()
	return workspace.DescendantAdded:Connect(function(object)
		if not object:IsA('BasePart') then return end
		-- Bodies are made of fast moving parts too, whenever their owner is running.
		local model = object:FindFirstAncestorWhichIsA('Model')
		if model and model:FindFirstChildOfClass('Humanoid') then return end
		incoming[object] = tick() + WATCH_FOR
	end)
end

-- Returns which way to step, or nil if nothing is actually coming at you. Works out the
-- closest the thing will ever get on its current course rather than how far away it is
-- now, so a shot that is near but passing wide is correctly ignored.
local function dodgeDirection(myPos)
	for part, expiry in incoming do
		if tick() > expiry or not part.Parent then
			incoming[part] = nil
			continue
		end

		local velocity = part.AssemblyLinearVelocity
		if velocity.Magnitude < PROJECTILE_SPEED then continue end

		local relative = part.Position - myPos
		-- Positive means it is moving away, so it can be left alone.
		local closing = relative:Dot(velocity)
		if closing >= 0 then continue end

		local time = -closing / velocity:Dot(velocity)
		if time > LOOK_AHEAD then continue end

		local closest = (relative + (velocity * time)).Magnitude
		if closest > DODGE_RADIUS then continue end

		-- Sideways relative to its travel, which is the shortest way out of its path.
		local sideways = Vector3.new(-velocity.Z, 0, velocity.X)
		if sideways.Magnitude < 0.1 then continue end
		return sideways.Unit
	end
	return nil
end

AutoFarm = vain.Categories.Blatant:CreateModule({
	Name = 'AutoFarm',
	Function = function(callback)
		if callback then
			warned = false
			nextSwing = 0
			nextScan = 0
			table.clear(candidates)
			table.clear(incoming)
			AutoFarm:Clean(watchProjectiles())

			-- Aim is held every frame, not once per pass.
			--
			-- Setting it on the 0.15s loop left the character free to turn in between,
			-- because the humanoid rotates itself toward wherever it thinks you are
			-- heading - so swings kept going out while facing somewhere else. AutoRotate
			-- is switched off for the same reason, and put back when the module stops.
			AutoFarm:Clean(runService.PostSimulation:Connect(function()
				if not (currentRoot and currentRoot.Parent and entitylib.isAlive) then return end

				local me = entitylib.character.RootPart
				local targetPos = currentRoot.Position
				-- Aimed at the target itself, pitch included, rather than at a point level
				-- with you. Flattening it to the horizontal meant that standing above an
				-- enemy you faced its direction but never looked down at it, so swings
				-- went out over its head.
				me.CFrame = CFrame.new(me.CFrame.Position, targetPos)
				pcall(function()
					gameCamera.CFrame = CFrame.new(gameCamera.CFrame.Position, targetPos)
				end)
			end))

			AutoFarm:Clean(function()
				currentRoot = nil
				local character = lplr.Character
				local humanoid = character and character:FindFirstChildOfClass('Humanoid')
				if humanoid and autoRotate ~= nil then
					humanoid.AutoRotate = autoRotate
				end
			end)

			task.spawn(function()
				repeat
					-- Guarded, yielding outside, so one bad pass cannot spin or end the
					-- farm for the session.
					local ok = pcall(function()
						if not entitylib.isAlive then return end

						dq.rescan()
						local enemy, root = dq.findEnemy()

						-- Deliberately does nothing when there is nothing to do. An
						-- earlier version returned you to where you switched it on, every
						-- tenth of a second, which pinned you in place whenever nothing
						-- was found. Enemies also only appear once a room starts, so
						-- finding none early on is normal rather than a fault.
						if not enemy then
							currentRoot = nil
							if not warned then
								warned = true
								notif('AutoFarm', 'Waiting for enemies to spawn.', 6, 'info')
							end
							return
						end

						warned = false
						dq.equipWeapon()

						local me = entitylib.character.RootPart
						local targetPos = root.Position

						-- Approached from whichever side you are already on, so it does
						-- not drag you through the target every pass.
						local away = me.Position - targetPos
						away = Vector3.new(away.X, 0, away.Z)
						if away.Magnitude < 0.1 then
							local back = me.CFrame.LookVector * -1
							away = Vector3.new(back.X, 0, back.Z)
						end

						local spot = targetPos + (away.Unit * STAND_OFF) + Vector3.new(0, STAND_UP, 0)

						-- Stepped aside before being placed, rather than moved after, so
						-- the dodge is not immediately undone by the next pass putting
						-- you back over the enemy.
						local dodge = dodgeDirection(me.Position)
						if dodge then
							spot += dodge * DODGE_DISTANCE
						end

						currentRoot = root

						local humanoid = entitylib.character.Humanoid
						if humanoid then
							if autoRotate == nil then
								autoRotate = humanoid.AutoRotate
							end
							humanoid.AutoRotate = false
						end

						me.CFrame = CFrame.new(spot, targetPos)
						-- Zeroed so hovering above the floor does not turn into a fall.
						me.AssemblyLinearVelocity = Vector3.zero

						-- The camera has to point at the enemy too, not just the
						-- character. A swing is a click at the centre of the screen, so
						-- it hits whatever the camera is looking at - aiming the body
						-- alone left the crosshair wherever the camera happened to be.
						pcall(function()
							gameCamera.CFrame = CFrame.new(gameCamera.CFrame.Position, targetPos)
						end)

						-- Abilities first, and outside everything below. They do not need
						-- the root to be back where you are, and gating them behind the
						-- swing meant they only went off when a swing was due - so one
						-- coming off cooldown sat unused until then.
						dq.useAbility()

						if tick() < nextSwing then return end

						-- Godmode hides the part the server identifies you by and checks
						-- that same one when you swing, so a hit sent while hidden is
						-- rejected. Ask for it back and wait to be told it has arrived.
						-- Asking only when a swing is actually due is what lets it hide in
						-- between; asking every pass held it open permanently.
						local combat = dq.combat
						if combat.hidden then
							combat.wantAttack = tick()
							if not combat.attackReady then return end
						end

						nextSwing = tick() + SWING_INTERVAL
						dq.swing()
					end)

					task.wait(ok and 0.15 or 0.4)
				until not AutoFarm.Enabled
			end)
		end
	end,
	Tooltip = 'Stands next to the nearest enemy, swings whatever is equipped and cycles abilities'
})
