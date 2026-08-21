local AntiMelee
local Mode
local Targets
local Range
local Resync
local Duration
local Offset
local Grace
local Every
local choking
local chokeUntil = 0

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

-- Teleport mode.
--
-- The offset is applied on Heartbeat and taken back off at the very start of the next
-- frame, at render priority 0 - before the camera runs, which sits at priority 200.
-- Replication samples the root between those two points, so the server sees the
-- displaced position while your screen and camera only ever see the real one.
--
-- The first version alternated the offset across whole frames instead, which is what
-- made the camera flicker: every other frame genuinely rendered you 16 studs up. It
-- also answers "which parts" - the character is one welded assembly, so there is no
-- subset to move on its own, and there is no need to: only the window matters, not
-- the parts. This is the same split Invisible uses, for the same reason.
local realCF
local nearby = false
local frame = 0

local function restore()
	if realCF and entitylib.isAlive then
		entitylib.character.RootPart.CFrame = realCF
	end
	realCF = nil
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
			chokeUntil = 0
			nearby = false
			realCF = nil

			local bindKey = httpService:GenerateGUID(true)
			runService:BindToRenderStep(bindKey, 0, restore)
			AntiMelee:Clean(function()
				runService:UnbindFromRenderStep(bindKey)
				restore()
			end)

			AntiMelee:Clean(runService.Heartbeat:Connect(function()
				if not (Mode.Value == 'Teleport' and nearby and entitylib.isAlive) then return end

				-- Your own attacks are validated against the server's copy of you as well,
				-- so being offset when you swing gets your hit rejected exactly the way it
				-- rejects theirs. Stand down for a moment around your own swings.
				local swordController = bedwars.SwordController
				if swordController then
					local since = math.min(
						tick() - (swordController.lastSwing or 0),
						workspace:GetServerTimeNow() - (swordController.lastAttack or 0)
					)
					if since < Grace.Value then return end
				end

				-- Offsetting on every single frame means the server almost never holds a
				-- true position for you, which is what its anti-teleport check reacts to -
				-- the lagback. Skipping frames leaves it a majority of honest samples while
				-- still poisoning enough of them to matter.
				frame += 1
				if frame % Every.Value ~= 0 then return end

				local root = entitylib.character.RootPart
				realCF = root.CFrame
				root.CFrame = realCF + Vector3.new(0, Offset.Value, 0)
			end))

			-- On Hit mode. The victim's client is told about damage after the fact -
			-- onEntityDamaged in the game, a health drop from here - which is useless for
			-- stopping the hit that just landed but is a precise trigger for the next
			-- one. Melee is repeated swings about a second apart, so choking for a
			-- fraction of a second on each hit breaks the follow-ups in a combo while
			-- leaving you fully synced the rest of the time.
			local function watchHealth(ent)
				AntiMelee:Clean(ent.Humanoid.HealthChanged:Connect(function(health)
					if health < (ent.Health or health) then
						chokeUntil = tick() + Duration.Value
					end
					ent.Health = health
				end))
			end
			AntiMelee:Clean(entitylib.Events.LocalAdded:Connect(watchHealth))
			if entitylib.isAlive then
				watchHealth(entitylib.character)
			end

			repeat
				local ok = pcall(function()
					if blinkActive() or not entitylib.isAlive then
						setChoke(false)
						nearby = false
						return
					end

					if Mode.Value == 'Teleport' then
						setChoke(false)
						-- Only the proximity test lives here. The offset itself is driven off
						-- Heartbeat so it always lands inside the replication window.
						nearby = entitylib.EntityPosition({
							Part = 'RootPart',
							Range = Range.Value,
							Players = Targets.Players.Enabled,
							NPCs = Targets.NPCs.Enabled
						}) ~= nil
						return
					end

					nearby = false

					if Mode.Value == 'On Hit' then
						setChoke(tick() < chokeUntil)
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
			nearby = false
			restore()
		else
			setChoke(false)
			nearby = false
			restore()
		end
	end,
	ExtraText = function()
		return Mode.Value
	end,
	Tooltip = 'Desyncs your position from the server while someone is in melee range'
})
Mode = AntiMelee:CreateDropdown({
	Name = 'Mode',
	Tooltip = 'How to break the position the server validates hits against',
	List = {'Teleport', 'On Hit', 'Proximity'},
	Tooltips = {
		Teleport = 'Offsets you only during the replication window, so the server sees you elsewhere\nThe camera never sees it, so there is no flicker',
		['On Hit'] = 'Chokes for a moment each time you take damage, to break the rest of a combo\nStays synced the rest of the time',
		Proximity = 'Chokes the whole time anyone is within range\nStronger, but you desync constantly'
	},
	Function = function()
		if AntiMelee.Enabled then
			setChoke(false)
			restore()
		end
	end
})
Offset = AntiMelee:CreateSlider({
	Name = 'Offset',
	Tooltip = 'How far up to sit during the replication window\nSword reach is about 14 studs, so less than that changes nothing',
	Min = 1,
	Max = 30,
	Default = 16,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
Grace = AntiMelee:CreateSlider({
	Name = 'Attack grace',
	Tooltip = 'How long to stay honest around your own swings, so your hits are not rejected too',
	Min = 0,
	Max = 1,
	Default = 0.35,
	Decimal = 100,
	Suffix = function(val)
		return val == 1 and 'second' or 'seconds'
	end
})
Every = AntiMelee:CreateSlider({
	Name = 'Every',
	Tooltip = 'Offset only one frame in this many\nHigher lags you back less but blocks fewer hits',
	Min = 1,
	Max = 10,
	Default = 3,
	Suffix = function(val)
		return val == 1 and 'frame' or 'frames'
	end
})
Range = AntiMelee:CreateSlider({
	Name = 'Range',
	Tooltip = 'How close someone has to be before this engages\nSword reach is about 14 studs',
	Min = 1,
	Max = 30,
	Default = 16,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
Duration = AntiMelee:CreateSlider({
	Name = 'Duration',
	Tooltip = 'How long to choke after being hit, in On Hit mode',
	Min = 0.05,
	Max = 1,
	Default = 0.4,
	Decimal = 100,
	Suffix = function(val)
		return val == 1 and 'second' or 'seconds'
	end
})
Resync = AntiMelee:CreateSlider({
	Name = 'Resync',
	Tooltip = 'How long to choke before letting a packet through, in Proximity mode\nLonger desyncs harder but snaps back further',
	Min = 0.05,
	Max = 1,
	Default = 0.35,
	Decimal = 100,
	Suffix = function(val)
		return val == 1 and 'second' or 'seconds'
	end
})
Targets = AntiMelee:CreateTargets({
	Players = true,
	Tooltip = 'Which entities this watches for'
})
