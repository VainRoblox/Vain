local AntiMelee
local Mode
local Targets
local Range
local Resync
local Duration
local Offset
local choking
local chokeUntil = 0
-- Tracks the offset currently applied to the root, so it can always be taken back
-- off relative to wherever you have since walked to. Left un-reverted you would be
-- permanently displaced upward.
local applied = Vector3.zero

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

-- Teleport mode. Roblox replicates the value a part holds at send time, not every
-- assignment, so offsetting and restoring inside one frame reaches the server as
-- nothing at all - the offset has to survive at least one replication tick. That is
-- also why this is visible: anyone watching sees you flick between the two spots.
local function revert()
	if applied == Vector3.zero then return end
	if entitylib.isAlive then
		local root = entitylib.character.RootPart
		-- Subtracted relative to the current position so walking in between is kept.
		root.CFrame = root.CFrame - applied
	end
	applied = Vector3.zero
end

local function jitter()
	if not entitylib.isAlive then
		applied = Vector3.zero
		return
	end

	local root = entitylib.character.RootPart
	if applied == Vector3.zero then
		applied = Vector3.new(0, Offset.Value, 0)
		root.CFrame = root.CFrame + applied
	else
		revert()
	end
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

			-- On Hit mode. The victim's client is told about damage after the fact -
			-- onEntityDamaged in the game, a health drop from here - which is useless for
			-- stopping the hit that just landed but is a precise trigger for the next
			-- one. Melee is repeated swings about a second apart, so choking for a
			-- fraction of a second on each hit breaks the follow-ups in a combo while
			-- leaving you fully synced the rest of the time.
			AntiMelee:Clean(entitylib.Events.LocalAdded:Connect(function(ent)
				AntiMelee:Clean(ent.Humanoid.HealthChanged:Connect(function(health)
					if health < (ent.Health or health) then
						chokeUntil = tick() + Duration.Value
					end
					ent.Health = health
				end))
			end))
			if entitylib.isAlive then
				local ent = entitylib.character
				AntiMelee:Clean(ent.Humanoid.HealthChanged:Connect(function(health)
					if health < (ent.Health or health) then
						chokeUntil = tick() + Duration.Value
					end
					ent.Health = health
				end))
			end

			repeat
				local ok = pcall(function()
					if blinkActive() or not entitylib.isAlive then
						setChoke(false)
						return
					end

					if Mode.Value == 'Teleport' then
						setChoke(false)
						local ent = entitylib.EntityPosition({
							Part = 'RootPart',
							Range = Range.Value,
							Players = Targets.Players.Enabled,
							NPCs = Targets.NPCs.Enabled
						})
						if ent then jitter() else revert() end
						return
					end

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
			revert()
		else
			setChoke(false)
			revert()
		end
	end,
	Tooltip = 'Chokes movement packets while someone is in melee range\nOnly works while you keep moving'
})
Mode = AntiMelee:CreateDropdown({
	Name = 'Mode',
	Tooltip = 'When to choke movement packets',
	List = {'On Hit', 'Proximity', 'Teleport'},
	Tooltips = {
		['On Hit'] = 'Chokes for a moment each time you take damage, to break the rest of a combo\nStays synced the rest of the time',
		Proximity = 'Chokes the whole time anyone is within range\nStronger, but you desync constantly',
		Teleport = 'Flicks you in and out of an offset position so swings land where you are not\nVery visible, and the offset has to clear sword reach to do anything'
	},
	Function = function()
		if AntiMelee.Enabled then
			setChoke(false)
			revert()
		end
	end
})
Offset = AntiMelee:CreateSlider({
	Name = 'Offset',
	Tooltip = 'How far to flick away in Teleport mode\nSword reach is about 14 studs, so less than that changes nothing',
	Min = 1,
	Max = 30,
	Default = 16,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
Duration = AntiMelee:CreateSlider({
	Name = 'Duration',
	Tooltip = 'How long to choke after being hit',
	Min = 0.05,
	Max = 1,
	Default = 0.4,
	Decimal = 100,
	Suffix = function(val)
		return val == 1 and 'second' or 'seconds'
	end
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
