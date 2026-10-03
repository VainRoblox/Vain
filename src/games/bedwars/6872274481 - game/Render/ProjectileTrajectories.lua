--[[
	Projectile Trajectories.

	Every projectile in flight is a model in Workspace named by its type, carrying the
	shooter's id in ProjectileShooter. The game makes each one fall at its own gravity with a
	BodyForce cancelling part of the world's - so that gravity is read straight back off the
	force, and the rest of the flight is simply worked out from where it is and how fast it
	is going. The path is drawn ahead of it, with a marker where it comes down: incoming
	arrows and fireballs you can step out of the way of, and the exact spot an enemy's pearl
	is about to put them.

	Aim Preview works out your own shot exactly as the game will fire it, for anything with
	a projectile source - bows, crossbows, fireballs, pearls, snowballs, kit items:

	- the projectile is the one your ammo makes, the ammo picked the way
	  ProjectileSourceController:getAmmoType does (hotbar first, then inventory);
	- the speed is its launch velocity (or the kit override) at full draw, or at
	  minStrengthScalar for things that do not charge, as enableTargeting starts them;
	- the aim is ProjectileController:calculateImportantLaunchValues: from the launch
	  position, towards a point far along the cursor ray lifted by YTargetOffset;
	- the flight starts where ProjectileUtil.fireProjectile puts the model - the launch
	  position moved by the source's relative offset (0.8 right, 0.6 down by default) - and
	  falls at the projectile's own gravity, nothing else acting on it.

	Players in the way are checked against their whole body, as the game's projectile hits
	are not stopped by CanCollide, and whoever it would hit is highlighted for a moment.

	Lines are clipped where they pass behind the camera rather than dropped, so the start
	of the path right under the camera still draws in first person. A path that falls into
	the void ends where it crosses the void height AntiFall uses - just under the lowest
	open block on the map - with no landing marker, as it never comes down.
]]
local Trajectories
local ShowOwn, ShowTeam, PearlOnly, Marker, Danger, AimPreview, AimHighlight, MaxTime, Thickness
local LineStyle, MarkerStyle, MarkerSize, ChargingOnly, ImpactHighlight, TypeColors
local LineColor, DangerColor, PearlColor, AimColor, HighlightColor, ArrowColor, FireballColor, SnowballColor
local impactBox
local tracked = {}
local pools = {}
local highlights = {}
-- Seconds of flight per simulated step (two raycasts each for the aim preview, every
-- frame); 0.05 keeps the curve smooth at under two thirds of the cost of 0.03.
local STEP = 0.05
local HIGHLIGHT_FADE = 0.35
local NEAR = 0.1

-- The game's launch constants (ProjectileController and ProjectileUtil).
local Y_TARGET_OFFSET = inputService.TouchEnabled and not inputService.KeyboardEnabled and 0.25 or 0.05
local CAMERA_MULTIPLIER = 10
local RELATIVE = Vector3.new(0.8, -0.6, 0)

local HighlightFolder = Instance.new('Folder')
HighlightFolder.Name = 'TrajectoryHighlights'
HighlightFolder.Parent = vain.gui

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

local bodyParams = RaycastParams.new()
bodyParams.FilterType = Enum.RaycastFilterType.Include
bodyParams.RespectCanCollide = false

local function on(setting)
	return setting ~= nil and setting.Enabled
end

-- The void height comes from the shared getVoidHeight in the game base.

local function colorOf(setting, fallback)
	if not setting then return fallback end
	return Color3.fromHSV(setting.Hue or 0, setting.Sat or 0, setting.Value or 1)
end

local function isPearl(name)
	return (name or ''):lower():find('pearl', 1, true) ~= nil
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
	if on(PearlOnly) and not isPearl(model.Name) then return false end
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
		entry = {lines = {}, circle = nil, cross = nil}
		pools[key] = entry
	end
	return entry
end

local function hideMarker(entry)
	if entry.circle then entry.circle.Visible = false end
	if entry.cross then
		for _, line in entry.cross do line.Visible = false end
	end
end

local function hidePool(entry)
	for _, line in entry.lines do line.Visible = false end
	hideMarker(entry)
end

local function destroyPool(key)
	local entry = pools[key]
	if not entry then return end
	for _, line in entry.lines do pcall(function() line:Remove() end) end
	if entry.circle then pcall(function() entry.circle:Remove() end) end
	for _, line in entry.cross or {} do pcall(function() line:Remove() end) end
	pools[key] = nil
end

local function refreshFilter()
	local ignore = {gameCamera}
	local bodies = {}
	for _, plr in playersService:GetPlayers() do
		if plr.Character then
			ignore[#ignore + 1] = plr.Character
			if plr ~= lplr then bodies[#bodies + 1] = plr.Character end
		end
	end
	for model in tracked do ignore[#ignore + 1] = model end
	rayParams.FilterDescendantsInstances = ignore
	bodyParams.FilterDescendantsInstances = bodies
end

--[[
	The flight from a point at a velocity under a gravity, until it hits something or the
	time runs out. Returns the points along it, where it stopped, and the character it hit
	if checkBodies is set.
]]
local function simulate(origin, velocity, gravity, checkBodies)
	local points = {origin}
	local previous = origin
	local limit = MaxTime and MaxTime.Value or 3
	local void = getVoidHeight()
	local t = 0
	while t < limit do
		t += STEP
		local point = origin + velocity * t - Vector3.new(0, 0.5 * gravity * t * t, 0)
		-- Into the void: cut off where it crosses, with nothing to land on.
		if void and point.Y < void and previous.Y >= void then
			points[#points + 1] = previous:Lerp(point, (previous.Y - void) / (previous.Y - point.Y))
			return points, nil
		elseif void and previous.Y < void then
			return points, nil
		end
		local delta = point - previous
		local hit = workspace:Raycast(previous, delta, rayParams)
		if checkBodies then
			local body = workspace:Raycast(previous, delta, bodyParams)
			if body and (not hit or (body.Position - previous).Magnitude <= (hit.Position - previous).Magnitude) then
				points[#points + 1] = body.Position
				local character = body.Instance:FindFirstAncestorOfClass('Model')
				while character and not character:FindFirstChildOfClass('Humanoid') do
					character = character.Parent and character.Parent:FindFirstAncestorOfClass('Model')
				end
				return points, body.Position, character
			end
		end
		if hit then
			points[#points + 1] = hit.Position
			return points, hit.Position, nil, hit.Instance
		end
		points[#points + 1] = point
		previous = point
	end
	return points, nil
end

-- A segment cut to the part in front of the camera, in screen space; nil if none of it is.
local function screenSegment(a, b)
	local cf = gameCamera.CFrame
	local la, lb = cf:PointToObjectSpace(a), cf:PointToObjectSpace(b)
	-- The camera looks down -Z: in front means z below -NEAR.
	local aFront, bFront = la.Z < -NEAR, lb.Z < -NEAR
	if not (aFront or bFront) then return nil end
	if not aFront then
		a = cf:PointToWorldSpace(la:Lerp(lb, (-NEAR - la.Z) / (lb.Z - la.Z)))
	elseif not bFront then
		b = cf:PointToWorldSpace(lb:Lerp(la, (-NEAR - lb.Z) / (la.Z - lb.Z)))
	end
	local sa = gameCamera:WorldToViewportPoint(a)
	local sb = gameCamera:WorldToViewportPoint(b)
	return Vector2.new(sa.X, sa.Y), Vector2.new(sb.X, sb.Y)
end

--[[
	Lines in the chosen style - solid, dashed (every other stretch left out) or fading out
	towards the end - and a marker where it comes down: a circle, a cross or a dot.
]]
local function draw(key, points, landing, color)
	local entry = pool(key)
	local thickness = Thickness and Thickness.Value or 2
	local style = LineStyle and LineStyle.Value or 'Solid'
	local viewport = gameCamera.ViewportSize
	local count = #points - 1
	local used = 0
	for i = 1, count do
		-- Dashes of two steps on, two off.
		if style == 'Dashed' and math.floor((i - 1) / 2) % 2 == 1 then continue end
		local from, to = screenSegment(points[i], points[i + 1])
		-- Skipped only when wholly off one side of the screen.
		if from and not ((from.X < 0 and to.X < 0) or (from.Y < 0 and to.Y < 0)
			or (from.X > viewport.X and to.X > viewport.X) or (from.Y > viewport.Y and to.Y > viewport.Y)) then
			used += 1
			local line = entry.lines[used]
			if not line then
				line = Drawing.new('Line')
				entry.lines[used] = line
			end
			line.From = from
			line.To = to
			line.Color = color
			line.Thickness = thickness
			-- Drawing transparency runs the other way: 1 is solid.
			line.Transparency = style == 'Fade' and math.clamp(1 - (i / count) * 0.85, 0.15, 1) or 1
			line.Visible = true
		end
	end
	for i = used + 1, #entry.lines do entry.lines[i].Visible = false end

	if not (landing and on(Marker)) then
		hideMarker(entry)
		return
	end
	local point, visible = gameCamera:WorldToViewportPoint(landing)
	if not (visible and point.Z > 0) then
		hideMarker(entry)
		return
	end
	local center = Vector2.new(point.X, point.Y)
	local size = MarkerSize and MarkerSize.Value or 7
	local mstyle = MarkerStyle and MarkerStyle.Value or 'Circle'
	if mstyle == 'Cross' then
		if entry.circle then entry.circle.Visible = false end
		if not entry.cross then
			entry.cross = {Drawing.new('Line'), Drawing.new('Line')}
		end
		local a, b = entry.cross[1], entry.cross[2]
		a.From, a.To = center + Vector2.new(-size, -size), center + Vector2.new(size, size)
		b.From, b.To = center + Vector2.new(-size, size), center + Vector2.new(size, -size)
		for _, line in entry.cross do
			line.Color = color
			line.Thickness = thickness
			line.Transparency = 1
			line.Visible = true
		end
	else
		if entry.cross then
			for _, line in entry.cross do line.Visible = false end
		end
		if not entry.circle then
			entry.circle = Drawing.new('Circle')
			entry.circle.NumSides = 24
		end
		entry.circle.Filled = mstyle == 'Dot'
		entry.circle.Position = center
		entry.circle.Radius = mstyle == 'Dot' and math.max(size * 0.6, 2) or size
		entry.circle.Thickness = thickness
		entry.circle.Color = color
		entry.circle.Transparency = 1
		entry.circle.Visible = true
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

-- The ammo the game would use: the first of the source's ammo types on the hotbar, then
-- in the inventory.
local function ammoFor(source)
	local types = source.ammoItemTypes
	if not types then return nil end
	local inventory = store.inventory or {}
	for _, ammo in types do
		for _, slot in inventory.hotbar or {} do
			if slot.item and slot.item.itemType == ammo then return ammo end
		end
	end
	for _, ammo in types do
		for _, item in (inventory.inventory and inventory.inventory.items) or {} do
			if item.itemType == ammo then return ammo end
		end
	end
	return types[1]
end

local function launchPosition(tool)
	local ok, position = pcall(function()
		return bedwars.ProjectileController:getLaunchPosition(tool)
	end)
	if ok and typeof(position) == 'Vector3' then return position end
	return entitylib.character.RootPart.Position
end

-- Your shot as the game will fire it: where the model starts, its velocity, its gravity.
local function aimLaunch()
	local tool = store.hand and store.hand.tool
	local meta = tool and bedwars.ItemMeta[tool.Name]
	local source = meta and meta.projectileSource
	if not source then return nil end

	local ammo = ammoFor(source)
	local ok, name = pcall(function()
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
	local charges = (tonumber(source.maxStrengthChargeSec) or 0) > 0
	speed *= charges and 1 or (source.minStrengthScalar or 1)

	local from = launchPosition(tool)
	local camera = gameCamera.CFrame.Position
	local mouse = cloneref(lplr:GetMouse())
	local ray = gameCamera:ScreenPointToRay(mouse.X, mouse.Y)
	local unit = (ray.Direction.Unit + Vector3.new(0, Y_TARGET_OFFSET, 0)).Unit
	local direction = (camera + unit * ((camera - from).Magnitude * CAMERA_MULTIPLIER) - from).Unit
	local velocity = direction * speed

	local relative = source.relativeOverride
	local offset = relative and Vector3.new(relative.relX or 0, relative.relY or 0, relative.relZ or 0) or RELATIVE
	local start = (CFrame.lookAt(from, from + velocity) * CFrame.new(offset)).Position
	return start, velocity, pmeta.gravitationalAcceleration or 196.2, name
end

-- Highlights who the shot would hit, held while aimed at and fading out after.
local function markHit(character)
	local entity = character and entitylib.getEntity(character)
	if not (entity and entity.Targetable) then return end
	local entry = highlights[character]
	if not entry then
		local highlight = Instance.new('Highlight')
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Adornee = character
		highlight.Parent = HighlightFolder
		entry = {highlight = highlight}
		highlights[character] = entry
	end
	entry.last = os.clock()
end

local function updateHighlights()
	local color = colorOf(HighlightColor, Color3.fromRGB(255, 80, 80))
	local opacity = HighlightColor and HighlightColor.Opacity or 0.5
	for character, entry in highlights do
		local age = os.clock() - entry.last
		if age > HIGHLIGHT_FADE or not character.Parent then
			entry.highlight:Destroy()
			highlights[character] = nil
		else
			local fade = age / HIGHLIGHT_FADE
			entry.highlight.FillColor = color
			entry.highlight.OutlineColor = color
			entry.highlight.FillTransparency = 1 - opacity * (1 - fade)
			entry.highlight.OutlineTransparency = fade
		end
	end
end

local function clearHighlights()
	for _, entry in highlights do entry.highlight:Destroy() end
	table.clear(highlights)
end

-- Shades the block the shot lands on.
local function setImpact(part, color)
	if not (part and on(ImpactHighlight) and part:IsA('BasePart')) then
		if impactBox then impactBox.Visible = false end
		return
	end
	if not impactBox then
		impactBox = Instance.new('BoxHandleAdornment')
		impactBox.AlwaysOnTop = true
		impactBox.ZIndex = 1
		impactBox.Parent = HighlightFolder
	end
	impactBox.Adornee = part
	impactBox.Size = part.Size + Vector3.new(0.05, 0.05, 0.05)
	impactBox.Color3 = color
	impactBox.Transparency = 0.6
	impactBox.Visible = true
end

-- Whether the game is aiming a shot right now (the bow drawn, the pearl wound up).
local function charging()
	local controller = bedwars.ProjectileController
	return controller ~= nil and controller.isTargeting == true
end

local function aimPreview()
	if not (on(AimPreview) and entitylib.isAlive) or (on(ChargingOnly) and not charging()) then
		destroyPool('aim')
		setImpact(nil)
		return
	end
	local start, velocity, gravity, name = aimLaunch()
	if not start or (on(PearlOnly) and not isPearl(name)) then
		local entry = pools.aim
		if entry then hidePool(entry) end
		setImpact(nil)
		return
	end

	local points, landing, character, part = simulate(start, velocity, gravity, true)
	if character and on(AimHighlight) then markHit(character) end
	local color = isPearl(name) and colorOf(PearlColor, Color3.fromRGB(200, 120, 255)) or colorOf(AimColor, Color3.fromRGB(120, 220, 255))
	draw('aim', points, landing, color)
	setImpact(not character and part or nil, color)
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
		local lower = model.Name:lower()
		if isPearl(model.Name) then
			color = colorOf(PearlColor, Color3.fromRGB(200, 120, 255))
		elseif on(Danger) and threatens(points) then
			color = colorOf(DangerColor, Color3.fromRGB(255, 70, 70))
		elseif on(TypeColors) and lower:find('arrow', 1, true) then
			color = colorOf(ArrowColor, Color3.fromRGB(255, 255, 255))
		elseif on(TypeColors) and lower:find('fireball', 1, true) then
			color = colorOf(FireballColor, Color3.fromRGB(255, 140, 40))
		elseif on(TypeColors) and lower:find('snowball', 1, true) then
			color = colorOf(SnowballColor, Color3.fromRGB(170, 220, 255))
		else
			color = colorOf(LineColor, Color3.fromRGB(255, 220, 120))
		end
		draw(model, points, landing, color)
	end
	pcall(aimPreview)
	updateHighlights()
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
			clearHighlights()
			if impactBox then
				impactBox:Destroy()
				impactBox = nil
			end
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
PearlOnly = Trajectories:CreateToggle({
	Name = 'Telepearl Only',
	Tooltip = 'Only draws telepearls'
})
Marker = Trajectories:CreateToggle({
	Name = 'Landing Marker',
	Tooltip = 'Marks where each one comes down',
	Default = true,
	Function = function(callback)
		for _, setting in {MarkerStyle, MarkerSize} do
			if setting and setting.Object then setting.Object.Visible = callback end
		end
	end
})
MarkerStyle = Trajectories:CreateDropdown({
	Name = 'Marker Style',
	List = {'Circle', 'Cross', 'Dot'},
	Tooltips = {Circle = 'A ring', Cross = 'An X', Dot = 'A filled dot'},
	Darker = true
})
MarkerSize = Trajectories:CreateSlider({
	Name = 'Marker Size',
	Tooltip = 'How big the marker is',
	Min = 3,
	Max = 20,
	Default = 7,
	Darker = true
})
LineStyle = Trajectories:CreateDropdown({
	Name = 'Line Style',
	List = {'Solid', 'Dashed', 'Fade'},
	Tooltips = {Solid = 'One unbroken line', Dashed = 'A dashed line', Fade = 'Fades out towards the end'}
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
		for _, setting in {AimHighlight, ChargingOnly, ImpactHighlight} do
			if setting and setting.Object then setting.Object.Visible = callback end
		end
		if HighlightColor and HighlightColor.Object then
			HighlightColor.Object.Visible = callback and on(AimHighlight)
		end
	end
})
AimHighlight = Trajectories:CreateToggle({
	Name = 'Aim Highlight',
	Tooltip = 'Briefly highlights who your shot would hit',
	Default = true,
	Visible = false,
	Function = function(callback)
		if HighlightColor and HighlightColor.Object then
			HighlightColor.Object.Visible = callback and on(AimPreview)
		end
		if not callback then clearHighlights() end
	end
})
ChargingOnly = Trajectories:CreateToggle({
	Name = 'Only While Aiming',
	Tooltip = 'Aim preview only while drawing or winding up',
	Visible = false
})
ImpactHighlight = Trajectories:CreateToggle({
	Name = 'Impact Highlight',
	Tooltip = 'Shades the block your shot lands on',
	Visible = false
})
TypeColors = Trajectories:CreateToggle({
	Name = 'Type Colors',
	Tooltip = 'Own colours for arrows, fireballs and snowballs',
	Function = function(callback)
		for _, setting in {ArrowColor, FireballColor, SnowballColor} do
			if setting and setting.Object then setting.Object.Visible = callback end
		end
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
HighlightColor = Trajectories:CreateColorSlider({
	Name = 'Highlight Color',
	Tooltip = 'Colour of the aim highlight',
	DefaultHue = 0,
	DefaultSat = 0.7,
	DefaultValue = 1,
	DefaultOpacity = 0.5,
	Darker = true,
	Visible = false
})
ArrowColor = Trajectories:CreateColorSlider({
	Name = 'Arrow Color',
	Tooltip = 'Colour of arrows',
	DefaultSat = 0,
	DefaultValue = 1,
	Darker = true,
	Visible = false
})
FireballColor = Trajectories:CreateColorSlider({
	Name = 'Fireball Color',
	Tooltip = 'Colour of fireballs',
	DefaultHue = 0.07,
	DefaultSat = 0.85,
	DefaultValue = 1,
	Darker = true,
	Visible = false
})
SnowballColor = Trajectories:CreateColorSlider({
	Name = 'Snowball Color',
	Tooltip = 'Colour of snowballs',
	DefaultHue = 0.57,
	DefaultSat = 0.35,
	DefaultValue = 1,
	Darker = true,
	Visible = false
})
