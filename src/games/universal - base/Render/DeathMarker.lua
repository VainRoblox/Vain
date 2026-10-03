--[[
	Death Marker.

	Marks where you last died, in any game: a label with how long ago it was and how far
	away, and if wanted a column of light to spot it from afar. A death from falling out of
	the world is marked at the last ground you stood on instead, since where you vanished
	is somewhere you cannot reach. Older deaths can be kept too, fading out.
]]
local DeathMarker
local Duration, KeepCount, Beacon, Color
local Folder = Instance.new('Folder')
Folder.Name = 'DeathMarker'
Folder.Parent = vain.gui
local markers = {}
local lastGround

local function colorOf()
	return Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
end

local function removeMarker(index)
	local marker = table.remove(markers, index)
	if not marker then return end
	marker.billboard:Destroy()
	marker.anchor:Destroy()
	if marker.beacon then marker.beacon:Destroy() end
end

local function addMarker(position)
	local anchor = Instance.new('Attachment')
	anchor.WorldPosition = position
	anchor.Parent = workspace.Terrain

	local billboard = Instance.new('BillboardGui')
	billboard.Adornee = anchor
	billboard.Size = UDim2.fromOffset(150, 34)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = Folder
	local label = Instance.new('TextLabel')
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextStrokeTransparency = 0.4
	label.Parent = billboard

	local beacon
	if Beacon.Enabled then
		beacon = Instance.new('Part')
		beacon.Anchored = true
		beacon.CanCollide = false
		beacon.CanQuery = false
		beacon.CanTouch = false
		beacon.CastShadow = false
		beacon.Material = Enum.Material.Neon
		beacon.Shape = Enum.PartType.Cylinder
		beacon.Size = Vector3.new(60, 0.6, 0.6)
		beacon.CFrame = CFrame.new(position + Vector3.new(0, 30, 0)) * CFrame.Angles(0, 0, math.rad(90))
		beacon.Transparency = 0.4
		beacon.Parent = gameCamera
	end

	table.insert(markers, 1, {anchor = anchor, billboard = billboard, label = label, beacon = beacon, position = position, time = os.clock()})
	while #markers > KeepCount.Value do removeMarker(#markers) end
end

local function update()
	local root = lplr.Character and lplr.Character:FindFirstChild('HumanoidRootPart')
	local humanoid = lplr.Character and lplr.Character:FindFirstChildOfClass('Humanoid')
	if root and humanoid and humanoid.Health > 0 and humanoid.FloorMaterial ~= Enum.Material.Air then
		lastGround = root.Position
	end

	local color = colorOf()
	for i = #markers, 1, -1 do
		local marker = markers[i]
		local age = os.clock() - marker.time
		if Duration.Value > 0 and age > Duration.Value * 60 then
			removeMarker(i)
		else
			local distance = root and (root.Position - marker.position).Magnitude
			local minutes, seconds = math.floor(age / 60), math.floor(age % 60)
			marker.label.Text = string.format('%s  %d:%02d ago%s', i == 1 and 'Death' or 'Older death', minutes, seconds,
				distance and string.format('\n%dm away', math.floor(distance)) or '')
			-- Older ones fade.
			local fade = math.clamp((i - 1) * 0.3, 0, 0.7)
			marker.label.TextColor3 = color
			marker.label.TextTransparency = fade
			if marker.beacon then
				marker.beacon.Color = color
				marker.beacon.Transparency = 0.4 + fade * 0.5
			end
		end
	end
end

local function watch(character)
	local humanoid = character:WaitForChild('Humanoid', 10)
	if not humanoid then return end
	DeathMarker:Clean(humanoid.Died:Connect(function()
		local root = character:FindFirstChild('HumanoidRootPart')
		local position = root and root.Position
		-- Fell out of the world: the last ground stood on is where to go back to.
		if position and lastGround and position.Y < workspace.FallenPartsDestroyHeight + 50 then
			position = lastGround
		end
		position = position or lastGround
		if position then addMarker(position) end
	end))
end

DeathMarker = vain.Categories.Render:CreateModule({
	Name = 'Death Marker',
	Tooltip = 'Marks where you last died',
	Function = function(callback)
		if callback then
			if lplr.Character then task.spawn(watch, lplr.Character) end
			DeathMarker:Clean(lplr.CharacterAdded:Connect(watch))
			local last = 0
			DeathMarker:Clean(runService.Heartbeat:Connect(function()
				if os.clock() - last < 0.25 then return end
				last = os.clock()
				pcall(update)
			end))
		else
			while #markers > 0 do removeMarker(1) end
		end
	end
})
Duration = DeathMarker:CreateSlider({
	Name = 'Duration',
	Tooltip = 'Minutes a marker stays (0 = until replaced)',
	Min = 0,
	Max = 30,
	Default = 5,
	Suffix = function(val) return val == 0 and 'forever' or 'min' end
})
KeepCount = DeathMarker:CreateSlider({
	Name = 'Keep',
	Tooltip = 'How many past deaths are marked',
	Min = 1,
	Max = 5,
	Default = 1
})
Beacon = DeathMarker:CreateToggle({
	Name = 'Beacon',
	Tooltip = 'A column of light over the spot',
	Default = true
})
Color = DeathMarker:CreateColorSlider({
	Name = 'Color',
	Tooltip = 'Colour of the marker',
	DefaultHue = 0,
	DefaultSat = 0.75,
	DefaultValue = 1
})
