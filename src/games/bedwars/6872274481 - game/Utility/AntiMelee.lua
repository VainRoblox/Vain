local AntiMelee
local Targets
local Range
local Resync
local choking

-- Roblox retires fast flags without warning and setfflag throws once the name is gone,
-- so every call goes through this - same reason Blink does it.
local function trySetFFlag(flag, value)
	return setfflag ~= nil and (pcall(setfflag, flag, value))
end

-- Choking physics replication freezes the server's copy of your position at wherever
-- you were when it started. Nothing about you becomes invulnerable: an attacker's hit
-- is validated against that stale position, so this only helps while you are actually
-- moving away from it. Standing still while choked leaves you exactly where they are
-- swinging.
local function setChoke(state)
	if choking == state then return end
	choking = state
	trySetFFlag('PhysicsSenderMaxBandwidthBps', state and '0' or '38760')
end

-- Blink drives the same two flags. Two modules writing them in opposite directions
-- would fight every frame, so this stands down and lets Blink own them.
local function blinkActive()
	local blink = vain.Modules.Blink
	return blink ~= nil and blink.Enabled
end

AntiMelee = vain.Categories.Utility:CreateModule({
	Name = 'AntiMelee',
	Function = function(callback)
		if callback then
			repeat
				local ok = pcall(function()
					if blinkActive() or not entitylib.isAlive then
						setChoke(false)
						return
					end

					local ent = entitylib.EntityPosition({
						Part = 'RootPart',
						Range = Range.Value,
						Players = Targets.Players.Enabled,
						NPCs = Targets.NPCs.Enabled,
						Preference = Targets.Preference.Value
					})

					if not ent then
						setChoke(false)
						return
					end

					-- Released briefly on a cycle. Choking indefinitely builds a larger and
					-- larger gap between where you are and where the server thinks you are,
					-- and the correction at the end of that is a hard snap backwards - which
					-- hands back more ground than the desync ever saved.
					setChoke(tick() % (Resync.Value + 0.1) <= Resync.Value)
				end)

				task.wait(ok and 0.03 or 0.25)
			until not AntiMelee.Enabled

			setChoke(false)
		else
			setChoke(false)
		end
	end,
	Tooltip = 'Chokes movement packets while someone is in melee range\nOnly works while you keep moving'
})
Targets = AntiMelee:CreateTargets({
	Players = true,
	Tooltip = 'Which entities this watches for'
})
Range = AntiMelee:CreateSlider({
	Name = 'Range',
	Tooltip = 'How close someone has to be before choking starts\nSword reach is about 14 studs',
	Min = 1,
	Max = 30,
	Default = 16,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
Resync = AntiMelee:CreateSlider({
	Name = 'Resync',
	Tooltip = 'How long to choke before letting a packet through\nLonger desyncs harder but snaps back further',
	Min = 0.05,
	Max = 1,
	Default = 0.35,
	Decimal = 100,
	Suffix = function(val)
		return val == 1 and 'second' or 'seconds'
	end
})
