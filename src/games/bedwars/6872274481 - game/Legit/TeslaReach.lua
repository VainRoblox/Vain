--[[
	Tesla Reach.

	Every placed Tesla Coil Trap is a block tagged tesla-trap. Its targets are anyone whose
	root part comes within TeslaTrapBalance.SEARCH_RANGE (24 studs) of the block, once its
	ActivationTime (server time) has passed; PlacedByUserId says whose it is. This draws
	that range around each one - as a sphere, or as a ring on the ground where the range
	meets your own height - dimmed while it is still arming, and in the danger colour once
	you are inside it.
]]
local TeslaReach
local Mode, ShowTeam, TeamColor, Fill, ThroughWalls, Pulse, Color, DangerColor, Thickness
local Folder = Instance.new('Folder')
Folder.Name = 'TeslaReach'
Folder.Parent = vain.gui
local traps = {}

local RANGE = 24
local SEGMENTS = 64
-- The root part sits about this far above the ground when the humanoid gives nothing
-- better; the ring is lifted a little off it so the floor does not swallow it.
local ROOT_HEIGHT = 2.5
local LIFT = 0.2
local lastGround

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.RespectCanCollide = true

--[[
	The floor under you and how high your root stands above it. Measured from the floor
	rather than the root itself, so jumping or falling does not move or shrink the ring:
	it always shows the range for standing on the ground below you.
]]
local function standing(root)
	local humanoid = entitylib.character.Humanoid
	local rootHeight = humanoid and (humanoid.HipHeight + root.Size.Y / 2) or ROOT_HEIGHT
	local ignore = {gameCamera, Folder}
	for _, plr in playersService:GetPlayers() do
		if plr.Character then ignore[#ignore + 1] = plr.Character end
	end
	groundParams.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(root.Position, Vector3.new(0, -60, 0), groundParams)
	if hit then
		lastGround = hit.Position.Y
	end
	return lastGround or (root.Position.Y - rootHeight), rootHeight
end
local FILL_STRENGTH = 0.22

local function colorOf(setting)
	return Color3.fromHSV(setting.Hue, setting.Sat, setting.Value), setting.Opacity
end

local function ownerOf(trap)
	return playersService:GetPlayerByUserId(trap:GetAttribute('PlacedByUserId') or 0)
end

local function isOwnTeam(owner)
	if not owner then return false end
	if owner == lplr then return true end
	local mine, theirs = lplr:GetAttribute('Team'), owner:GetAttribute('Team')
	return mine ~= nil and theirs ~= nil and tostring(mine) == tostring(theirs)
end

local function remove(trap)
	local entry = traps[trap]
	if not entry then return end
	entry.sphere:Destroy()
	entry.disc:Destroy()
	for _, line in entry.lines do line:Destroy() end
	traps[trap] = nil
end

local function add(trap)
	if traps[trap] or not trap:IsA('PVInstance') then return end
	local sphere = Instance.new('SphereHandleAdornment')
	sphere.Radius = RANGE
	sphere.Adornee = trap
	sphere.AlwaysOnTop = false
	sphere.ZIndex = 0
	sphere.Visible = false
	sphere.Parent = Folder

	-- A flat disc filling the ring; a cylinder's axis runs along Z, so it is turned upright.
	local disc = Instance.new('CylinderHandleAdornment')
	disc.Adornee = workspace.Terrain
	disc.Height = 0.05
	disc.ZIndex = 0
	disc.Visible = false
	disc.Parent = Folder

	local lines = {}
	for i = 1, SEGMENTS do
		local line = Instance.new('LineHandleAdornment')
		line.Adornee = workspace.Terrain
		line.AlwaysOnTop = false
		line.ZIndex = 0
		line.Visible = false
		line.Parent = Folder
		lines[i] = line
	end
	traps[trap] = {sphere = sphere, disc = disc, lines = lines}
end

local function hide(entry)
	entry.sphere.Visible = false
	entry.disc.Visible = false
	for _, line in entry.lines do line.Visible = false end
end

local function update()
	local root = entitylib.isAlive and entitylib.character.RootPart
	local now = workspace:GetServerTimeNow()
	local ground, rootHeight
	if root and Mode.Value == 'Ring' and next(traps) then
		ground, rootHeight = standing(root)
	end
	for trap, entry in traps do
		if not trap.Parent then
			remove(trap)
			continue
		end
		local owner = ownerOf(trap)
		if isOwnTeam(owner) and not ShowTeam.Enabled then
			hide(entry)
			continue
		end

		local center = trap:GetPivot().Position
		local inside = root and (root.Position - center).Magnitude <= RANGE
		local color, opacity = colorOf(Color)
		if TeamColor.Enabled and owner and owner.Team then
			color = owner.TeamColor.Color
		end
		local danger = inside and not isOwnTeam(owner)
		if danger then
			color, opacity = colorOf(DangerColor)
			if Pulse.Enabled then
				opacity *= 0.6 + 0.4 * (0.5 + 0.5 * math.sin(os.clock() * 8))
			end
		end
		-- Still arming: drawn at a third of the strength.
		local activation = trap:GetAttribute('ActivationTime')
		if activation and now < activation then
			opacity *= 0.35
		end
		local transparency = 1 - opacity
		local onTop = ThroughWalls.Enabled

		if Mode.Value == 'Sphere' then
			for _, line in entry.lines do line.Visible = false end
			entry.disc.Visible = false
			entry.sphere.AlwaysOnTop = onTop
			entry.sphere.Color3 = color
			-- A whole sphere at full strength would hide everything behind it.
			entry.sphere.Transparency = 1 - opacity * 0.4
			entry.sphere.Visible = true
		else
			entry.sphere.Visible = false
			-- The circle where the range meets your root standing on the floor below you,
			-- laid on that floor.
			local floor, height = ground or (center.Y - ROOT_HEIGHT), rootHeight or ROOT_HEIGHT
			local dy = floor + height - center.Y
			if math.abs(dy) >= RANGE then
				hide(entry)
				continue
			end
			local radius = math.sqrt(RANGE * RANGE - dy * dy)
			local y = floor + LIFT
			local thickness = Thickness.Value * ((danger and Pulse.Enabled) and 1.5 or 1)

			entry.disc.Visible = Fill.Enabled
			if Fill.Enabled then
				entry.disc.Radius = radius
				entry.disc.CFrame = CFrame.new(center.X, y - 0.05, center.Z) * CFrame.Angles(math.rad(90), 0, 0)
				entry.disc.Color3 = color
				entry.disc.Transparency = 1 - opacity * FILL_STRENGTH
				entry.disc.AlwaysOnTop = onTop
			end
			for i, line in entry.lines do
				local a0 = (i - 1) / SEGMENTS * math.pi * 2
				local a1 = i / SEGMENTS * math.pi * 2
				local from = Vector3.new(center.X + math.cos(a0) * radius, y, center.Z + math.sin(a0) * radius)
				local to = Vector3.new(center.X + math.cos(a1) * radius, y, center.Z + math.sin(a1) * radius)
				line.CFrame = CFrame.lookAt(from, to)
				line.Length = (to - from).Magnitude
				line.Thickness = thickness
				line.Color3 = color
				line.Transparency = transparency
				line.AlwaysOnTop = onTop
				line.ZIndex = 1
				line.Visible = true
			end
		end
	end
end

TeslaReach = vain.Legit:CreateModule({
	Name = 'Tesla Reach',
	Function = function(callback)
		if callback then
			for _, trap in collectionService:GetTagged('tesla-trap') do add(trap) end
			TeslaReach:Clean(collectionService:GetInstanceAddedSignal('tesla-trap'):Connect(add))
			TeslaReach:Clean(collectionService:GetInstanceRemovedSignal('tesla-trap'):Connect(remove))
			TeslaReach:Clean(runService.RenderStepped:Connect(function()
				pcall(update)
			end))
		else
			for trap in traps do remove(trap) end
		end
	end,
	Tooltip = 'Shows how far tesla traps reach'
})
Mode = TeslaReach:CreateDropdown({
	Name = 'Mode',
	List = {'Ring', 'Sphere'},
	Tooltips = {'A ring on the ground at your height', 'The whole range as a sphere'},
	Function = function(val)
		if Thickness and Thickness.Object then Thickness.Object.Visible = val == 'Ring' end
	end
})
ShowTeam = TeslaReach:CreateToggle({
	Name = 'Show Own Team',
	Tooltip = 'Also shows your team\'s traps'
})
TeamColor = TeslaReach:CreateToggle({
	Name = 'Team Color',
	Tooltip = 'Colours each trap by its team',
	Default = true
})
Fill = TeslaReach:CreateToggle({
	Name = 'Fill',
	Tooltip = 'Shades the area inside the ring',
	Default = true
})
ThroughWalls = TeslaReach:CreateToggle({
	Name = 'Through Walls',
	Tooltip = 'Draws over blocks instead of behind them',
	Default = true
})
Pulse = TeslaReach:CreateToggle({
	Name = 'Pulse',
	Tooltip = 'Pulses while you are in range',
	Default = true
})
Color = TeslaReach:CreateColorSlider({
	Name = 'Color',
	Tooltip = 'Colour of the range',
	DefaultHue = 0.55,
	DefaultSat = 0.6,
	DefaultValue = 1,
	DefaultOpacity = 1
})
DangerColor = TeslaReach:CreateColorSlider({
	Name = 'Danger Color',
	Tooltip = 'Colour once you are in range',
	DefaultHue = 0,
	DefaultSat = 0.8,
	DefaultValue = 1,
	DefaultOpacity = 1
})
Thickness = TeslaReach:CreateSlider({
	Name = 'Thickness',
	Tooltip = 'How thick the ring is',
	Min = 1,
	Max = 12,
	Default = 6
})
