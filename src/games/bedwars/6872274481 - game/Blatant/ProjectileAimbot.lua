local ProjectileAimbot
local TargetPart
local Targets
local FOV
local Range
local HitChance
local OtherProjectiles
local InstantCharge
local ChargeSpeed
local CircleColor
local CircleTransparency
local CircleFilled
local CircleObject
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

local function mousePosition()
	if inputService.TouchEnabled then
		return gameCamera.ViewportSize / 2
	end
	return inputService:GetMouseLocation()
end

-- Whichever of the two is closer to your cursor right now.
local function nearestPart(ent)
	local closest, closestmag = 'RootPart', math.huge
	local mouse = mousePosition()
	for _, name in {'Head', 'RootPart'} do
		local part = ent[name]
		if part then
			local screen, vis = gameCamera:WorldToViewportPoint(part.Position)
			local mag = vis and (mouse - Vector2.new(screen.X, screen.Y)).Magnitude or math.huge
			if mag < closestmag then
				closest, closestmag = name, mag
			end
		end
	end
	return closest
end

-- Pushes the aim point off the target when the roll fails. The offset is worked out as
-- an angle rather than a fixed distance, so the same miss lands beside the head from
-- close up and a long way wide from across the map, which is how a real miss behaves.
local function applySpread(aimpos, origin)
	local delta = aimpos - origin
	local dist = delta.Magnitude
	if dist <= 0 then return aimpos end

	local spread = math.rad(math.random(60, 200) / 100)
	local miss = math.max(2.5, dist * math.tan(spread))
	local look = delta.Unit
	local right = look:Cross(Vector3.yAxis)
	right = right.Magnitude > 0 and right.Unit or Vector3.xAxis
	local up = right:Cross(look).Unit
	local angle = math.random() * math.pi * 2

	return aimpos + (right * math.cos(angle) + up * math.sin(angle)) * miss
end

-- The game builds the draw strength itself, every frame, from drawDurationSeconds:
-- ratio = min(1, drawDurationSeconds / maxStrengthChargeSec), and the launch speed is
-- scaled from minStrengthScalar up to full at ratio 1. Writing the draw time is enough -
-- the game recomputes the speed and fires its own max charge handling from there.
local function applyCharge(projmeta)
	if not InstantCharge.Enabled or projmeta.drawDurationSeconds == nil then return end

	local tool = store.hand.tool
	local meta = tool and bedwars.ItemMeta[tool.Name]
	local source = meta and meta.projectileSource
	local maxcharge = source and source.maxStrengthChargeSec
	if not maxcharge then return end

	local wanted = maxcharge * (ChargeSpeed.Value / 100)
	if projmeta.drawDurationSeconds < wanted then
		projmeta.drawDurationSeconds = wanted
	end
end

-- Returns the launch values to use, or nil to let the game work it out itself.
local function solve(self, projmeta, worldmeta, origin, shootpos)
	-- The game returns nil for a missing projmeta before touching it, so match that
	-- rather than indexing it and throwing back into the game's own call stack.
	if not projmeta then return nil end

	applyCharge(projmeta)

	if (not OtherProjectiles.Enabled) and not projmeta.projectile:find('arrow') then
		return nil
	end

	local selectpart = TargetPart.Value == 'Nearest' and 'RootPart' or TargetPart.Value
	local plr = entitylib.EntityMouse({
		Part = selectpart,
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

	local target = plr[TargetPart.Value == 'Nearest' and nearestPart(plr) or TargetPart.Value]
	local character = plr.Character
	if not target or not character then return nil end
	if (target.Position - pos).Magnitude > Range.Value then return nil end

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

	local aimpos = target.Position
	if HitChance.Value < 100 and math.random(1, 100) > HitChance.Value then
		aimpos = applySpread(aimpos, offsetpos)
	end

	local newlook = CFrame.new(offsetpos, aimpos) * CFrame.new(projmeta.projectile == 'owl_projectile' and Vector3.zero or Vector3.new(bedwars.BowConstantsTable.RelX, bedwars.BowConstantsTable.RelY, bedwars.BowConstantsTable.RelZ))
	local calc = prediction.SolveTrajectory(newlook.p, projSpeed, gravity, aimpos, projmeta.projectile == 'telepearl' and Vector3.zero or target.Velocity, playerGravity, plr.HipHeight, plr.Jumping and 42.6 or nil, rayCheck)
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

ProjectileAimbot = vain.Categories.Blatant:CreateModule({
	Name = 'ProjectileAimbot',
	Function = function(callback)
		if CircleObject then
			CircleObject.Visible = callback
		end

		if callback then
			ProjectileAimbot:Clean(runService.RenderStepped:Connect(function()
				if CircleObject then
					CircleObject.Position = mousePosition()
				end
			end))

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
	Tooltip = 'Which body part to aim at',
	List = {'RootPart', 'Head', 'Nearest'},
	Tooltips = {
		RootPart = 'Aims at the middle of the body',
		Head = 'Aims at the head',
		Nearest = 'Aims at whichever part is closer to your cursor'
	}
})
FOV = ProjectileAimbot:CreateSlider({
	Name = 'FOV',
	Tooltip = 'How far from your cursor a target may be on screen',
	Min = 1,
	Max = 1000,
	Default = 1000,
	Function = function(val)
		if CircleObject then
			CircleObject.Radius = val
		end
	end
})
Range = ProjectileAimbot:CreateSlider({
	Name = 'Range',
	Tooltip = 'How far a target can be, in studs',
	Min = 10,
	Max = 500,
	Default = 500,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
HitChance = ProjectileAimbot:CreateSlider({
	Name = 'Hit Chance',
	Tooltip = 'How often a shot is aimed at the target instead of beside it',
	Min = 0,
	Max = 100,
	Default = 100,
	Suffix = function()
		return '%'
	end
})
OtherProjectiles = ProjectileAimbot:CreateToggle({
	Name = 'Other Projectiles',
	Tooltip = 'Also handles projectiles other than arrows',
	Default = true
})
InstantCharge = ProjectileAimbot:CreateToggle({
	Name = 'Instant Charge',
	Tooltip = 'Draws charged projectiles the moment you start aiming',
	Function = function(callback)
		ChargeSpeed.Object.Visible = callback
	end
})
ChargeSpeed = ProjectileAimbot:CreateSlider({
	Name = 'Charge Speed',
	Tooltip = 'How much of a full draw is applied instantly',
	Min = 0,
	Max = 100,
	Default = 100,
	Darker = true,
	Visible = false,
	Suffix = function()
		return '%'
	end
})
ProjectileAimbot:CreateToggle({
	Name = 'Show FOV',
	Tooltip = 'Draws the circle around your cursor that targets are picked from',
	Function = function(callback)
		if callback then
			pcall(function()
				CircleObject = Drawing.new('Circle')
				CircleObject.Filled = CircleFilled.Enabled
				CircleObject.Color = Color3.fromHSV(CircleColor.Hue, CircleColor.Sat, CircleColor.Value)
				CircleObject.Position = vain.gui.AbsoluteSize / 2
				CircleObject.Radius = FOV.Value
				CircleObject.NumSides = 100
				CircleObject.Transparency = 1 - CircleTransparency.Value
				CircleObject.Visible = ProjectileAimbot.Enabled
			end)
		else
			pcall(function()
				CircleObject.Visible = false
				CircleObject:Remove()
			end)
			CircleObject = nil
		end
		CircleColor.Object.Visible = callback
		CircleTransparency.Object.Visible = callback
		CircleFilled.Object.Visible = callback
	end
})
CircleColor = ProjectileAimbot:CreateColorSlider({
	Name = 'Circle Color',
	Tooltip = 'Color used for the circle',
	Function = function(hue, sat, val)
		if CircleObject then
			CircleObject.Color = Color3.fromHSV(hue, sat, val)
		end
	end,
	Darker = true,
	Visible = false
})
CircleTransparency = ProjectileAimbot:CreateSlider({
	Name = 'Transparency',
	Tooltip = 'How solid the circle is drawn',
	Min = 0,
	Max = 1,
	Decimal = 10,
	Default = 0.5,
	Function = function(val)
		if CircleObject then
			CircleObject.Transparency = 1 - val
		end
	end,
	Darker = true,
	Visible = false
})
CircleFilled = ProjectileAimbot:CreateToggle({
	Name = 'Circle Filled',
	Tooltip = 'Fills the circle in instead of drawing its outline',
	Function = function(callback)
		if CircleObject then
			CircleObject.Filled = callback
		end
	end,
	Darker = true,
	Visible = false
})
