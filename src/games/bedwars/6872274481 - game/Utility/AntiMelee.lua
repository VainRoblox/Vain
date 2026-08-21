-- Desyncs the position the server holds for you from the one you actually occupy,
-- while someone is close enough to melee you.
--
-- Why this shape: the server takes a hit's reach from the attacker's own claimed
-- selfPosition and targetPosition - which is exactly how Reach works, by editing
-- selfPosition on the way out - so your real position never enters that check, and
-- choking replication cannot influence it. What the server does check against its own
-- copy of you is whether the attacker's claimed targetPosition matches it. That is the
-- check this breaks.
--
-- The offset is applied on Heartbeat and removed at render priority 0, before the
-- camera runs at priority 200. Replication samples the root between those two points,
-- so the server sees the offset while your screen and camera only ever see the real
-- position.
--
-- Hitting while not being hit works because the two are not symmetric: their swings
-- arrive whenever they choose, so they land on offset samples, while yours are known
-- about in advance. Attacking stands the offset down for as long as you are attacking
-- and a moment after, so your own hits are validated against an honest position.
local AntiMelee
local Targets
local Range
local Offset
local realCF
local nearby = false

-- Long enough to cover the flight of a swing that has already been sent, short enough
-- that letting go leaves you covered again almost immediately.
local ATTACK_GRACE = 0.3

local function restore()
	if realCF and entitylib.isAlive then
		entitylib.character.RootPart.CFrame = realCF
	end
	realCF = nil
end

-- Held mouse covers manual swings before they are even sent; the controller timestamps
-- cover Killaura, which attacks without the mouse held.
local function attacking()
	if inputService:IsMouseButtonPressed(0) and not inputService:GetFocusedTextBox() then
		return true
	end

	local controller = bedwars.SwordController
	if not controller then return false end

	if tick() - (controller.lastSwing or 0) < ATTACK_GRACE then return true end
	return workspace:GetServerTimeNow() - (controller.lastAttack or 0) < ATTACK_GRACE
end

AntiMelee = vain.Categories.Utility:CreateModule({
	Name = 'AntiMelee',
	Function = function(callback)
		if callback then
			nearby = false
			realCF = nil

			local bindKey = httpService:GenerateGUID(true)
			runService:BindToRenderStep(bindKey, 0, restore)
			AntiMelee:Clean(function()
				runService:UnbindFromRenderStep(bindKey)
				restore()
			end)

			AntiMelee:Clean(runService.Heartbeat:Connect(function()
				if not (nearby and entitylib.isAlive) or attacking() then return end

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
	Tooltip = 'Makes the server hold a different position for you while someone is in melee range\nStands down while you attack so your own hits still land'
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
Targets = AntiMelee:CreateTargets({
	Players = true,
	Tooltip = 'Which entities this watches for'
})
