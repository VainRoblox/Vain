--[[
	Projectile Trajectories.

	Every projectile in flight is a model in Workspace named by its type, carrying the
	shooter's id in ProjectileShooter. The game makes each one fall at its own gravity with a
	BodyForce cancelling part of the world's - so that gravity is read straight back off the
	force, and the rest of the flight is simply worked out from where it is and how fast it
	is going. The path is drawn ahead of it, with a marker where it comes down: incoming
	arrows and fireballs you can step out of the way of, and the exact spot an enemy's pearl
	is about to put them.

	Aim Preview does the same for whatever you are holding, worked out the way
	ProjectileController:calculateImportantLaunchValues does at full draw, so it shows where
	a fully charged shot lands.
]]
local Trajectories
local ShowOwn, ShowTeam, Marker, Danger, AimPreview, MaxTime, Thickness
local LineColor, DangerColor, PearlColor, AimColor
local tracked = {}
local pools = {}
local STEP = 0.03

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function colorOf(setting, fallback)
	if not setting then return fallback end
	return Color3.fromHSV(setting.Hue or 0, setting.Sat or 0, setting.Value or 1)
end

local function sameTeam(userId)
	local plr = playersService:GetPlayerByUserId(userId or 0)
	if not plr then return false end
	local mine, theirs = lplr:GetAttribute('Team'), plr:GetAttribute('Team')
	return mine ~= nil and theirs ~= nil and tostring(mine) == tostring(theirs)
end

local function wanted(model)
	local shooter = model:GetAttribute('ProjectileShooter')
	if shooter == nil then return false end
	if shooter == lplr.UserId then return on(ShowOwn) end
	if sameTeam(shooter) then return on(ShowTeam) end
	return true
end

local function track(model)
	if not model:IsA('Model') or tracked[model] then return end
	-- The shooter attribute can land a moment after the model does.
	task.defer(function()
		if model.Parent and model.PrimaryPart and model:GetAttribute('ProjectileShooter') ~= nil then
			tracked[model] = true
		end
	end)
end

-- Drawing lines kept per path and reused, so a frame costs no allocation.
local function pool(key)
	local entry = pools[key]
	if not entry then
		entry = {lines = {}, circle = nil}
		pools[key] = entry
	end
	return entry
end

local function hidePool(entry)
	for _, line in entry.lines do line.Visible = false end
	if entry.circle then entry.circle.Visible = false end
end

local function destroyPool(key)
	local entry = pools[key]
	if not entry then return end
	for _, line in entry.lines do pcall(function() line:Remove() end) end
	if entry.circle then pcall(function() entry.circle:Remove() end) end
	pools[key] = nil
end

local function refreshFilter()
	local ignore = {gameCamera}
	for _, plr in playersService:GetPlayers() do
		if plr.Character then ignore[#ignore + 1] = plr.Character end
	end
	for model in tracked do ignore[#ignore + 1] = model end
	rayParams.FilterDescendantsInstances = ignore
end

-- The flight from a point at a velocity under a gravity, until it hits something or the
-- time runs out. Returns the points along it and where it stopped.
local function simulate(origin, velocity, gravity)
	local points = {origin}
	local previous = origin
	local limit = MaxTime and MaxTime.Value or 3
	local t = 0
	while t < limit do
		t += STEP
		local point = origin + velocity * t - Vector3.new(0, 0.5 * gravity * t * t, 0)
		local hit = workspace:Raycast(previous, point - previous, rayParams)
		if hit then
			points[#points + 1] = hit.Position
			return points, hit.Position
		end
		points[#points + 1] = point
		previous = point
	end
	return points, nil
end

local function draw(key, points, landing, color)
	local entry = pool(key)
	local thickness = Thickness and Thickness.Value or 2
	local used = 0
	for i = 1, #points - 1 do
		local a, aVisible = gameCamera:WorldToViewportPoint(points[i])
		local b, bVisible = gameCamera:WorldToViewportPoint(points[i + 1])
		if a.Z > 0 and b.Z > 0 and (aVisible or bVisible) then
			used += 1
			local line = entry.lines[used]
			if not line then
				line = Drawing.new('Line')
				entry.lines[used] = line
			end
			line.From = Vector2.new(a.X, a.Y)
			line.To = Vector2.new(b.X, b.Y)
			line.Color = color
			line.Thickness = thickness
			line.Visible = true
		end
	end
	for i = used + 1, #entry.lines do entry.lines[i].Visible = false end

	if landing and on(Marker) then
		local point, visible = gameCamera:WorldToViewportPoint(landing)
		if visible and point.Z > 0 then
			if not entry.circle then
				entry.circle = Drawing.new('Circle')
				entry.circle.NumSides = 24
				entry.circle.Filled = false
			end
			entry.circle.Position = Vector2.new(point.X, point.Y)
			entry.circle.Radius = 7
			entry.circle.Thickness = thickness
			entry.circle.Color = color
			entry.circle.Visible = true
		elseif entry.circle then
			entry.circle.Visible = false
		end
	elseif entry.circle then
		entry.circle.Visible = false
	end
end

-- Whether a path passes close enough to you to hit.
local function threatens(points)
	if not entitylib.isAlive then return false end
	local here = entitylib.character.RootPart.Position
	for _, point in points do
		if (point - here).Magnitude <= 4 then return true end
	end
	return false
end

local function projectileGravity(root)
	local force = root:FindFirstChildOfClass('BodyForce')
	local mass = root.AssemblyMass
	if force and mass > 0 then
		return workspace.Gravity - force.Force.Y / mass
	end
	return workspace.Gravity
end

-- What you are holding, if it throws or fires something: speed and gravity from its meta,
-- with the overrides some kits put on them.
local function heldProjectile()
	local tool = store.hand and store.hand.tool
	local meta = tool and bedwars.ItemMeta[tool.Name]
	local source = meta and meta.projectileSource
	if not source then return nil end
	local ok, name = pcall(function()
		local ammo = source.ammoItemTypes and source.ammoItemTypes[1] or 'arrow'
		return type(source.projectileType) == 'function' and source.projectileType(ammo) or source.projectileType
	end)
	local pmeta = ok and name and bedwars.ProjectileMeta[name]
	if not pmeta then return nil end
	local overrides
	if pmeta.getProjectileOverridesFunction then
		local fine, result = pcall(pmeta.getProjectileOverridesFunction, lplr)
		overrides = fine and type(result) == 'table' and result or nil
	end
	local speed = overrides and overrides.launchVelocityOverride or pmeta.launchVelocity or 100
	return speed, pmeta.gravitationalAcceleration or 196.2, name, tool
end

-- The game's launch constants (ProjectileController): the aim is lifted slightly above the
-- cursor ray and pointed at a spot far along it, not at whatever the cursor touches.
local Y_TARGET_OFFSET = inputService.TouchEnabled and not inputService.KeyboardEnabled and 0.25 or 0.05
local CAMERA_MULTIPLIER = 10

local function launchPosition(tool)
	local ok, position = pcall(function()
		return bedwars.ProjectileController:getLaunchPosition(tool)
	end)
	if ok and typeof(position) == 'Vector3' then return position end
	return entitylib.character.Head.Position
end

local function aimPreview()
	if not (on(AimPreview) and entitylib.isAlive) then
		destroyPool('aim')
		return
	end
	local speed, gravity, name, tool = heldProjectile()
	if not speed then
		local entry = pools.aim
		if entry then hidePool(entry) end
		return
	end

	local origin = launchPosition(tool)
	local mouse = cloneref(lplr:GetMouse())
	local ray = gameCamera:ScreenPointToRay(mouse.X, mouse.Y)
	local camera = gameCamera.CFrame.Position
	local unit = (ray.Direction.Unit + Vector3.new(0, Y_TARGET_OFFSET, 0)).Unit
	local direction = camera + unit * ((camera - origin).Magnitude * CAMERA_MULTIPLIER) - origin
	if direction.Magnitude <= 0 then return end
	local points, landing = simulate(origin, direction.Unit * speed, gravity)
	draw('aim', points, landing, (name or ''):find('pearl') and colorOf(PearlColor, Color3.fromRGB(200, 120, 255)) or colorOf(AimColor, Color3.fromRGB(120, 220, 255)))
end

local function step()
	refreshFilter()
	for model in tracked do
		local root = model.PrimaryPart
		if not (model.Parent and root and root.Parent) then
			tracked[model] = nil
			destroyPool(model)
			continue
		end
		if not wanted(model) then
			local entry = pools[model]
			if entry then hidePool(entry) end
			continue
		end

		local velocity = root.AssemblyLinearVelocity
		if velocity.Magnitude < 2 then
			local entry = pools[model]
			if entry then hidePool(entry) end
			continue
		end

		local points, landing = simulate(root.Position, velocity, projectileGravity(root))
		local color
		if model.Name:lower():find('pearl', 1, true) then
			color = colorOf(PearlColor, Color3.fromRGB(200, 120, 255))
		elseif on(Danger) and threatens(points) then
			color = colorOf(DangerColor, Color3.fromRGB(255, 70, 70))
		else
			color = colorOf(LineColor, Color3.fromRGB(255, 220, 120))
		end
		draw(model, points, landing, color)
	end
	aimPreview()
end

Trajectories = vain.Categories.Render:CreateModule({
	Name = 'Trajectories',
	Tooltip = 'Draws where projectiles in flight will land',
	Function = function(callback)
		if callback then
			for _, child in workspace:GetChildren() do track(child) end
			Trajectories:Clean(workspace.ChildAdded:Connect(track))
			Trajectories:Clean(runService.RenderStepped:Connect(function()
				pcall(step)
			end))
		else
			for key in pools do destroyPool(key) end
			table.clear(tracked)
		end
	end
})
ShowOwn = Trajectories:CreateToggle({
	Name = 'Show Own',
	Tooltip = 'Also draws your own projectiles'
})
ShowTeam = Trajectories:CreateToggle({
	Name = 'Show Teammates',
	Tooltip = 'Also draws your teammates\' projectiles'
})
Marker = Trajectories:CreateToggle({
	Name = 'Landing Marker',
	Tooltip = 'Circles where each one comes down',
	Default = true
})
Danger = Trajectories:CreateToggle({
	Name = 'Danger Color',
	Tooltip = 'Colours a path that will hit you',
	Default = true,
	Function = function(callback)
		if DangerColor and DangerColor.Object then DangerColor.Object.Visible = callback end
	end
})
AimPreview = Trajectories:CreateToggle({
	Name = 'Aim Preview',
	Tooltip = 'Draws where what you are holding will land',
	Function = function(callback)
		if AimColor and AimColor.Object then AimColor.Object.Visible = callback end
	end
})
MaxTime = Trajectories:CreateSlider({
	Name = 'Max Time',
	Tooltip = 'Seconds of flight each path shows',
	Min = 0.5,
	Max = 6,
	Default = 3,
	Decimal = 10,
	Suffix = function() return 's' end
})
Thickness = Trajectories:CreateSlider({
	Name = 'Thickness',
	Tooltip = 'How thick the lines are',
	Min = 1,
	Max = 5,
	Default = 2
})
LineColor = Trajectories:CreateColorSlider({
	Name = 'Line Color',
	Tooltip = 'Colour of other players\' projectiles',
	DefaultHue = 0.12,
	DefaultSat = 0.55,
	DefaultValue = 1
})
DangerColor = Trajectories:CreateColorSlider({
	Name = 'Hit Color',
	Tooltip = 'Colour of a path that will hit you',
	DefaultHue = 0,
	DefaultSat = 0.75,
	DefaultValue = 1,
	Darker = true
})
PearlColor = Trajectories:CreateColorSlider({
	Name = 'Pearl Color',
	Tooltip = 'Colour of pearls, which show where someone will appear',
	DefaultHue = 0.78,
	DefaultSat = 0.55,
	DefaultValue = 1
})
AimColor = Trajectories:CreateColorSlider({
	Name = 'Aim Color',
	Tooltip = 'Colour of your aim preview',
	DefaultHue = 0.55,
	DefaultSat = 0.55,
	DefaultValue = 1,
	Darker = true,
	Visible = false
})
