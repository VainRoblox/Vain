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
-- Timing is the whole thing. A frame runs
--
--     RenderStep -> render -> Stepped -> physics -> Heartbeat
--
-- and replication samples an owned part around the physics step. So the offset is
-- applied on Stepped, just before physics, and removed at render priority 0 on the
-- next frame, before the camera runs at priority 200. It therefore exists across
-- physics and Heartbeat - the window the server actually reads - and is gone again
-- before anything is drawn, so neither your screen nor your camera ever sees it.
--
-- Applying it on Heartbeat instead, as an earlier version did, put it entirely after
-- physics and removed it before the next one: the server never sampled it once, and
-- the module did nothing whatsoever.
--
-- Hitting while not being hit works because the two are not symmetric: their swings
-- arrive whenever they choose, so they land on offset samples, while yours are known
-- about in advance. Attacking stands the offset down for as long as you are attacking
-- and a moment after, so your own hits are validated against an honest position.
local AntiMelee
local realCF
local nearby = false
local offsetStep = false

-- Comfortably past sword reach, which is about 14.4 studs - anything under that leaves
-- you inside the region a swing covers and does nothing at all.
local OFFSET = Vector3.new(0, 18, 0)

-- Slightly wider than reach, so the offset is already in place by the time someone is
-- close enough to swing.
local RANGE = 18

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

			AntiMelee:Clean(runService.Stepped:Connect(function()
				if not (nearby and entitylib.isAlive) or attacking() then return end

				-- Alternated, not held. Replication is a single channel: if the server
				-- believes you are 18 studs up then so does every other client, their sword
				-- query finds you there, they swing there and the server agrees - a steady
				-- offset moves both views together and achieves nothing. What can be
				-- exploited is the gap between them. An attacker aims at their interpolated,
				-- slightly stale copy of you, so flipping the position every physics step
				-- leaves the server holding a different sample by the time their swing is
				-- validated. This is what the first version did, and why it worked.
				offsetStep = not offsetStep
				if not offsetStep then return end

				local root = entitylib.character.RootPart
				realCF = root.CFrame
				root.CFrame = realCF + OFFSET
			end))

			repeat
				local ok = pcall(function()
					nearby = entitylib.isAlive and entitylib.EntityPosition({
						Part = 'RootPart',
						Range = RANGE,
						Players = true,
						NPCs = true
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
	Tooltip = 'Makes the server hold a different position for you while someone is in melee range\nStands down while you attack so your own hits still land'
})
