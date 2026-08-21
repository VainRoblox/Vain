-- Desyncs the position the server holds for you from the one you actually occupy,
-- while someone is close enough to melee you.
--
-- Why this shape and not the others: the server validates a hit's reach from the
-- attacker's own claimed selfPosition and targetPosition - which is exactly how Reach
-- works, by editing selfPosition on the way out - so your real position never enters
-- that check. Choking replication, whether on proximity or reactively when hit, cannot
-- influence it and those modes were dropped. What the server does check against its own
-- copy of you is whether the attacker's claimed targetPosition matches it, and that is
-- the check this breaks.
--
-- The offset is applied on Heartbeat and removed at render priority 0, before the
-- camera runs at priority 200. Replication samples the root between those two points,
-- so the server sees the offset while your screen and camera only ever see the real
-- position - the earlier version alternated across whole frames, which is what made the
-- camera flicker.
local AntiMelee
local Targets
local Range
local Offset
local Grace
local Every
local realCF
local nearby = false
local frame = 0

local function restore()
	if realCF and entitylib.isAlive then
		entitylib.character.RootPart.CFrame = realCF
	end
	realCF = nil
end

-- Your own attacks are validated against the server's copy of you as well, so being
-- offset while you swing gets your hit rejected the same way it rejects theirs.
local function swinging()
	local controller = bedwars.SwordController
	if not controller then return false end

	local since = math.min(
		tick() - (controller.lastSwing or 0),
		workspace:GetServerTimeNow() - (controller.lastAttack or 0)
	)
	return since < Grace.Value
end

AntiMelee = vain.Categories.Utility:CreateModule({
	Name = 'AntiMelee',
	Function = function(callback)
		if callback then
			nearby = false
			realCF = nil
			frame = 0

			local bindKey = httpService:GenerateGUID(true)
			runService:BindToRenderStep(bindKey, 0, restore)
			AntiMelee:Clean(function()
				runService:UnbindFromRenderStep(bindKey)
				restore()
			end)

			AntiMelee:Clean(runService.Heartbeat:Connect(function()
				if not (nearby and entitylib.isAlive) or swinging() then return end

				-- Every frame by default. Skipping frames leaves the server a majority of
				-- honest samples, which lags you back less but also blocks far fewer hits -
				-- most swings simply land on one of the honest samples instead. Raise it
				-- only if the lagback is worse than the hits.
				frame += 1
				if frame % Every.Value ~= 0 then return end

				local root = entitylib.character.RootPart
				realCF = root.CFrame
				root.CFrame = realCF + Vector3.new(0, Offset.Value, 0)
			end))

			repeat
				local ok = pcall(function()
					nearby = entitylib.isAlive and entitylib.EntityPosition({
						Part = 'RootPart',
						Range = Range.Value,
						Players = Targets.Players.Enabled,
						NPCs = Targets.NPCs.Enabled,
						Preference = Targets.Preference.Value
					}) ~= nil
				end)

				task.wait(ok and 0.05 or 0.25)
			until not AntiMelee.Enabled

			nearby = false
			restore()
		else
			nearby = false
			restore()
		end
	end,
	ExtraText = function()
		return Offset.Value .. ''
	end,
	Tooltip = 'Offsets the position the server holds for you while someone is in melee range'
})
Offset = AntiMelee:CreateSlider({
	Name = 'Offset',
	Tooltip = 'How far up the server sees you\nSword reach is about 14 studs, so below that changes nothing',
	Min = 1,
	Max = 40,
	Default = 18,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
Range = AntiMelee:CreateSlider({
	Name = 'Range',
	Tooltip = 'How close someone has to be before this engages',
	Min = 1,
	Max = 30,
	Default = 18,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
Grace = AntiMelee:CreateSlider({
	Name = 'Attack grace',
	Tooltip = 'How long to stay honest around your own swings, so your own hits are not rejected too',
	Min = 0,
	Max = 1,
	Default = 0.3,
	Decimal = 100,
	Suffix = function(val)
		return val == 1 and 'second' or 'seconds'
	end
})
Every = AntiMelee:CreateSlider({
	Name = 'Every',
	Tooltip = 'Offset one frame in this many\n1 is strongest, higher lags you back less but blocks fewer hits',
	Min = 1,
	Max = 10,
	Default = 1,
	Suffix = function(val)
		return val == 1 and 'frame' or 'frames'
	end
})
Targets = AntiMelee:CreateTargets({
	Players = true,
	Tooltip = 'Which entities this watches for'
})
