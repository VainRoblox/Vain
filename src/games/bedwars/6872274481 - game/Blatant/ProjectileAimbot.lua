local TargetPart
local Targets
local FOV
local OtherProjectiles
local rayCheck = RaycastParams.new()
rayCheck.FilterType = Enum.RaycastFilterType.Include
local mapfolder
local old

-- Resolved on use rather than once at load. The map does not exist yet if you inject
-- while the round is still loading, and an Include filter holding nothing hits nothing -
-- which silently switched off the landing prediction below for the whole session.
local function refreshMapFilter()
	local map = workspace:FindFirstChild('Map')
	if map ~= mapfolder then
		mapfolder = map
		rayCheck.FilterDescendantsInstances = map and {map} or {}
	end
end

-- Returns the launch values to use, or nil to let the game work it out itself.
local function solve(self, projmeta, worldmeta, origin, shootpos)
	-- The game returns nil for a missing projmeta before touching it, so match that
	-- rather than indexing it and throwing back into the game's own call stack.
	if not projmeta then return nil end

	local plr = entitylib.EntityMouse({
		Part = 'RootPart',
		Range = FOV.Value,
		Players = Targets.Players.Enabled,
		NPCs = Targets.NPCs.Enabled,
		Preference = Targets.Preference.Value,
		Wallcheck = Targets.Walls.Enabled,
		Origin = entitylib.isAlive and (shootpos or entitylib.character.RootPart.Position) or Vector3.zero
	})
	if not plr then return nil end

	local pos = shootpos or self:getLaunchPosition(origin)
	if not pos then return nil end

	if (not OtherProjectiles.Enabled) and not projmeta.projectile:find('arrow') then
		return nil
	end

	local target = plr[TargetPart.Value]
	local character = plr.Character
	if not target or not character then return nil end

	local meta = projmeta:getProjectileMeta()
	-- Kits can hand back overrides for the speed and lifetime of their own projectiles.
	-- Solving with the base numbers instead aimed for a shot the game was never going
	-- to fire.
	local overrides = meta.getProjectileOverridesFunction and meta.getProjectileOverridesFunction(projmeta.player) or nil
	local lifetime = (worldmeta
		and ((overrides and overrides.predictionLifetimeOverride) or meta.predictionLifetimeSec)
		or ((overrides and overrides.lifetimeOverride) or meta.lifetimeSec)) or 3
	local gravity = (meta.gravitationalAcceleration or 196.2) * projmeta.gravityMultiplier
	-- velocityMultiplier is how far the bow is drawn. It was being left out while its
	-- sibling gravityMultiplier was applied, so every partly charged shot was solved at
	-- full power and fell short.
	local projSpeed = ((overrides and overrides.launchVelocityOverride) or meta.launchVelocity or 100) * projmeta.velocityMultiplier
	local offsetpos = pos + (projmeta.projectile == 'owl_projectile' and Vector3.zero or projmeta.fromPositionOffset)
	local balloons = character:GetAttribute('InflatedBalloons')
	local playerGravity = workspace.Gravity

	if balloons and balloons > 0 then
		playerGravity = (workspace.Gravity * (1 - ((balloons >= 4 and 1.2 or balloons >= 3 and 1 or 0.975))))
	end

	local primary = character.PrimaryPart
	if primary and primary:FindFirstChild('rbxassetid://8200754399') then
		playerGravity = 6
	end

	-- NPCs have no Player, and this used to index it regardless. Since this whole
	-- function replaces one the game calls itself, that error did not just lose the
	-- shot, it broke the game's projectile code for the rest of the round.
	if plr.Player and plr.Player:GetAttribute('IsOwlTarget') then
		for _, owl in collectionService:GetTagged('Owl') do
			if owl:GetAttribute('Target') == plr.Player.UserId and owl:GetAttribute('Status') == 2 then
				playerGravity = 0
			end
		end
	end

	refreshMapFilter()

	local newlook = CFrame.new(offsetpos, target.Position) * CFrame.new(projmeta.projectile == 'owl_projectile' and Vector3.zero or Vector3.new(bedwars.BowConstantsTable.RelX, bedwars.BowConstantsTable.RelY, bedwars.BowConstantsTable.RelZ))
	local calc = prediction.SolveTrajectory(newlook.p, projSpeed, gravity, target.Position, projmeta.projectile == 'telepearl' and Vector3.zero or target.Velocity, playerGravity, plr.HipHeight, plr.Jumping and 42.6 or nil, rayCheck)
	if not calc then return nil end

	targetinfo.Targets[plr] = tick() + 1
	return {
		initialVelocity = CFrame.new(newlook.Position, calc).LookVector * projSpeed,
		positionFrom = offsetpos,
		deltaT = lifetime,
		gravitationalAcceleration = gravity,
		drawDurationSeconds = 5
	}
end

local ProjectileAimbot = vain.Categories.Blatant:CreateModule({
	Name = 'ProjectileAimbot',
	Function = function(callback)
		if callback then
			old = bedwars.ProjectileController.calculateImportantLaunchValues
			bedwars.ProjectileController.calculateImportantLaunchValues = function(...)
				-- Guarded because the game calls this, not us. Anything that throws in
				-- here used to surface inside the game's own bow logic and take the bow
				-- with it; now a failure just hands the shot back untouched. old() stays
				-- outside so its own errors still behave exactly as the game expects.
				local ok, result = pcall(solve, ...)
				if ok and result then
					return result
				end
				return old(...)
			end
		else
			bedwars.ProjectileController.calculateImportantLaunchValues = old
		end
	end,
	Tooltip = 'Silently adjusts your aim towards the enemy'
})
Targets = ProjectileAimbot:CreateTargets({
	Players = true,
	Walls = true,
	Tooltip = 'Which entities this module is allowed to target'
})
TargetPart = ProjectileAimbot:CreateDropdown({
	Name = 'Part',
	Tooltip = 'Which body part to target',
	List = {'RootPart', 'Head'},
	Tooltips = {
		RootPart = 'Aims at the middle of the body',
		Head = 'Aims at the head'
	}
})
FOV = ProjectileAimbot:CreateSlider({
	Name = 'FOV',
	Tooltip = 'How far from your cursor a target may be on screen',
	Min = 1,
	Max = 1000,
	Default = 1000
})
OtherProjectiles = ProjectileAimbot:CreateToggle({
	Name = 'Other Projectiles',
	Tooltip = 'Also handles projectiles other than arrows',
	Default = true
})
