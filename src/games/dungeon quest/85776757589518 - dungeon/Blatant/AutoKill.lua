local AutoKill

-- Hit and run, rather than standing next to what you are fighting.
--
-- AutoFarm parks alongside an enemy and stays there, which leaves it in reach of
-- everything nearby for as long as the fight lasts. This darts to the nearest one, swings
-- once, and is back where it started before anything can answer - so the only moment you
-- are exposed is the swing itself.
local dq = vain.Libraries.dungeonquest

-- Where to sit for the swing: inside melee reach, with a little height so you are not
-- standing inside the target and being shoved about by it.
local STRIKE_OFFSET = Vector3.new(0, 6, 0)
local STRIKE_RANGE = 4

-- How long to stay before returning.
--
-- Not zero, however tempting. The swing is a click the game turns into a request, and
-- returning in the same frame puts you home before that request is dealt with - so it
-- arrives claiming a position you are no longer at and is thrown away. This is the
-- shortest wait that still lets the hit count.
local DWELL = 0.12

-- How long to stay home between trips.
--
-- Without this the loop went straight back in - a tenth of a second away, a tenth of a
-- second at the enemy - which is most of the time spent standing in reach and barely
-- different from parking there. Waiting between strikes is what makes this hit and run
-- rather than hit and stay, and it costs nothing: a weapon cannot swing faster than its
-- own animation, so the extra trips were never landing anything anyway.
local STRIKE_INTERVAL = 0.6
local nextStrike = 0

AutoKill = vain.Categories.Blatant:CreateModule({
	Name = 'AutoKill',
	Function = function(callback)
		if callback then
			nextStrike = 0
			task.spawn(function()
				repeat
					-- Guarded, yielding outside, so one bad pass cannot spin or end the
					-- module for the session.
					local ok = pcall(function()
						if not entitylib.isAlive then return end

						-- Abilities are cast from here, before going anywhere. They do not
						-- need to be near the target, so casting them on the trip would
						-- only lengthen the time spent in reach.
						dq.useAbility()

						if tick() < nextStrike then return end

						dq.rescan()
						local enemy, root = dq.findEnemy()
						if not (enemy and root) then return end

						local me = entitylib.character.RootPart
						-- Captured before moving and returned to afterwards, so the trip
						-- leaves you exactly where you were rather than drifting a little
						-- further out with each one.
						local home = me.CFrame

						dq.equipWeapon()

						-- Approached from the side you are already on, and aimed at the
						-- target itself so the pitch is right - a swing is a click at the
						-- centre of the screen, so it lands wherever the camera looks.
						local targetPos = root.Position
						local away = me.Position - targetPos
						away = Vector3.new(away.X, 0, away.Z)
						if away.Magnitude < 0.1 then
							local back = me.CFrame.LookVector * -1
							away = Vector3.new(back.X, 0, back.Z)
						end

						local spot = targetPos + (away.Unit * STRIKE_RANGE) + STRIKE_OFFSET
						me.CFrame = CFrame.new(spot, targetPos)
						me.AssemblyLinearVelocity = Vector3.zero
						pcall(function()
							gameCamera.CFrame = CFrame.new(gameCamera.CFrame.Position, targetPos)
						end)

						-- Godmode hides the part the server identifies you by and checks
						-- that same one when you swing, so a hit sent while hidden is
						-- rejected. Ask for it back and wait to be told it has arrived.
						-- With Godmode off there is nothing to wait for and this is skipped.
						if dq.combat.hidden then
							dq.combat.wantAttack = tick()
							if not dq.combat.attackReady then return end
						end

						nextStrike = tick() + STRIKE_INTERVAL
						dq.swing()

						task.wait(DWELL)

						-- Home again whatever happened in between. Wrapped because the
						-- character can be replaced mid trip, and being left parked on top
						-- of an enemy is the one outcome this module exists to avoid.
						pcall(function()
							if entitylib.isAlive then
								local back = entitylib.character.RootPart
								back.CFrame = home
								back.AssemblyLinearVelocity = Vector3.zero
							end
						end)
					end)

					task.wait(ok and 0.05 or 0.4)
				until not AutoKill.Enabled
			end)
		end
	end,
	Tooltip = 'Darts to the nearest enemy, swings, and returns instantly'
})
