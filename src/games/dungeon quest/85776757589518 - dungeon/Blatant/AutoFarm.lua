local AutoFarm
local warned = false
local nextAbility = 0
local abilityIndex = 1
local candidates = {}
local nextScan = 0
local incoming = {}

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

AutoFarm = vain.Categories.Blatant:CreateModule({
	Name = 'AutoFarm',
	Function = function(callback)
		if callback then
			warned = false
			nextAbility = 0
			nextScan = 0
			table.clear(candidates)
			table.clear(incoming)
			AutoFarm:Clean(watchProjectiles())

			task.spawn(function()
				repeat
					-- Guarded, yielding outside, so one bad pass cannot spin or end the
					-- farm for the session.
					local ok = pcall(function()
						if not entitylib.isAlive then return end

						dq.dq.rescan()
						local enemy, root = dq.findEnemy()

						-- Deliberately does nothing when there is nothing to do. An
						-- earlier version returned you to where you switched it on, every
						-- tenth of a second, which pinned you in place whenever nothing
						-- was found. Enemies also only appear once a room starts, so
						-- finding none early on is normal rather than a fault.
						if not enemy then
							if not warned then
								warned = true
								notif('AutoFarm', 'Waiting for enemies to spawn.', 6, 'info')
							end
							return
						end

						warned = false
						dq.dq.equipWeapon()

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

						-- Godmode hides the part the server identifies you by, and it
						-- checks that same position when you swing - so attacking while
						-- hidden is rejected. Ask for it back, wait to be told it has
						-- arrived, then attack. When Godmode is off there is nothing to
						-- wait for and this is skipped entirely.
						local combat = dq.combat
						if combat.hidden then
							combat.wantAttack = tick()
							if not combat.attackReady then return end
						end

						dq.swing()
						dq.useAbility()
					end)

					task.wait(ok and 0.15 or 0.4)
				until not AutoFarm.Enabled
			end)
		end
	end,
	Tooltip = 'Stands next to the nearest enemy, swings whatever is equipped and cycles abilities'
})
