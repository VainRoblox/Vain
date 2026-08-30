local BedPlates
local Background
local Color = {}
local Quantity
local FullLayers
local FullColor = {}
local Reference = {}
local Folder = Instance.new('Folder')
Folder.Parent = vain.gui

-- How deep a wrap is worth reporting on. Past this the layers stop being defences.
local MAX_LAYERS = 4

--[[
	The same walk outwards along each face that already decides which blocks to show,
	keeping two more things while it is there: how many of each block it passed, and
	what each layer is made of. Step i away from the bed is layer i, so a layer counts
	as complete when everything at that step is the same block and no direction ran out
	into open air before reaching it.
]]
local function scanSide(self, start, found, open)
	for _, side in sides do
		for i = 1, 15 do
			local pos = start + (side * i)
			local block = getPlacedBlock(pos)
			if not block then
				-- Nothing here, so this layer and everything past it has a way in.
				for depth = i, MAX_LAYERS do
					open[depth] = true
				end
				break
			end
			if block == self then break end

			-- A bed covers two positions, so the same block can be one step from one half
			-- and two from the other. It belongs to the nearer layer, and counts once.
			local prev = found[pos]
			if not prev or i < prev.Depth then
				found[pos] = {Block = block, Depth = i}
			end
		end
	end
end

local function scanBed(bed)
	local names, counts, layers, found, open = {}, {}, {}, {}, {}
	for depth = 1, MAX_LAYERS do
		layers[depth] = {}
	end

	-- Straight off the block handler rather than assuming which way the bed lies, so a
	-- rotated one is walked from both of its halves like any other.
	for _, v in bedwars.getContainedPositions(bed) do
		scanSide(bed, v * 3, found, open)
	end

	for _, entry in found do
		local block = entry.Block
		if block:GetAttribute('NoBreak') then continue end

		if not table.find(names, block.Name) then
			table.insert(names, block.Name)
		end
		counts[block.Name] = (counts[block.Name] or 0) + 1

		if entry.Depth <= MAX_LAYERS then
			local types = layers[entry.Depth]
			types[block.Name] = (types[block.Name] or 0) + 1
		end
	end

	local full = {}
	for depth, types in layers do
		if open[depth] then continue end

		local only, kinds = nil, 0
		for name in types do
			only = name
			kinds += 1
		end
		if kinds == 1 then
			full[only] = true
		end
	end

	return names, counts, full
end

local function refreshAdornee(v)
	if not v.Adornee then return end

	for _, obj in v.Frame:GetChildren() do
		if obj.Name == 'Block' then
			obj:Destroy()
		end
	end

	local order, counts, full = scanBed(v.Adornee)
	-- Toughest first. A block the metadata has never heard of sorts last rather than
	-- throwing, which would take every plate down with it.
	local function health(name)
		local meta = bedwars.ItemMeta[name]
		return (meta and meta.block and meta.block.health) or 0
	end
	table.sort(order, function(a, b)
		return health(a) > health(b)
	end)
	v.Enabled = #order > 0

	local showfull = FullLayers and FullLayers.Enabled
	local showcount = Quantity and Quantity.Enabled

	for _, block in order do
		local complete = showfull and full[block]

		local holder = Instance.new('Frame')
		holder.Name = 'Block'
		holder.Size = UDim2.fromOffset(32, 32)
		holder.BackgroundColor3 = Color3.fromHSV(FullColor.Hue or 0, FullColor.Sat or 0, FullColor.Value or 1)
		holder.BackgroundTransparency = complete and (1 - (FullColor.Opacity or 1)) or 1
		holder.Parent = v.Frame
		local holdercorner = Instance.new('UICorner')
		holdercorner.CornerRadius = UDim.new(0, 4)
		holdercorner.Parent = holder

		local blockimage = Instance.new('ImageLabel')
		blockimage.Size = UDim2.fromScale(1, 1)
		blockimage.BackgroundTransparency = 1
		blockimage.Image = bedwars.getIcon({itemType = block}, true)
		blockimage.Parent = holder

		if showcount then
			-- Across the whole icon rather than tucked into a corner: at the size these
			-- plates are drawn on screen, anything smaller cannot be read at a glance.
			-- White on a dark outline so it stands off whatever block is behind it.
			local amount = Instance.new('TextLabel')
			amount.Size = UDim2.fromScale(1, 1)
			amount.BackgroundTransparency = 1
			amount.Text = tostring(counts[block])
			amount.TextColor3 = Color3.new(1, 1, 1)
			amount.TextScaled = true
			amount.FontFace = uipallet.FontSemiBold
			amount.ZIndex = 2
			amount.Parent = holder
			local outline = Instance.new('UIStroke')
			outline.Color = Color3.new()
			outline.Thickness = 2
			outline.Parent = amount
			-- Keeps a two digit count off the edges of the icon.
			local padding = Instance.new('UIPadding')
			padding.PaddingTop = UDim.new(0, 3)
			padding.PaddingBottom = UDim.new(0, 3)
			padding.Parent = amount
		end
	end
end

local function refreshAll()
	for _, v in Reference do
		refreshAdornee(v)
	end
end

local function Added(v)
	local billboard = Instance.new('BillboardGui')
	billboard.Parent = Folder
	billboard.Name = 'bed'
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
	billboard.Size = UDim2.fromOffset(36, 36)
	billboard.AlwaysOnTop = true
	billboard.ClipsDescendants = false
	billboard.Adornee = v
	local blur = addBlur(billboard)
	blur.Visible = Background.Enabled
	local frame = Instance.new('Frame')
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
	frame.BackgroundTransparency = 1 - (Background.Enabled and Color.Opacity or 0)
	frame.Parent = billboard
	local layout = Instance.new('UIListLayout')
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 4)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
		billboard.Size = UDim2.fromOffset(math.max(layout.AbsoluteContentSize.X + 4, 36), 36)
	end)
	layout.Parent = frame
	local corner = Instance.new('UICorner')
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = frame
	Reference[v] = billboard
	refreshAdornee(billboard)
end

local function refreshNear(data)
	data = data.blockRef.blockPosition * 3
	for i, v in Reference do
		if (data - i.Position).Magnitude <= 30 then
			refreshAdornee(v)
		end
	end
end

BedPlates = vain.Categories.Minigames:CreateModule({
	Name = 'BedPlates',
	Function = function(callback)
		if callback then
			for _, v in collectionService:GetTagged('bed') do
				task.spawn(Added, v)
			end
			BedPlates:Clean(vainEvents.PlaceBlockEvent.Event:Connect(refreshNear))
			BedPlates:Clean(vainEvents.BreakBlockEvent.Event:Connect(refreshNear))
			BedPlates:Clean(collectionService:GetInstanceAddedSignal('bed'):Connect(Added))
			BedPlates:Clean(collectionService:GetInstanceRemovedSignal('bed'):Connect(function(v)
				if Reference[v] then
					Reference[v]:Destroy()
					Reference[v]:ClearAllChildren()
					Reference[v] = nil
				end
			end))
		else
			table.clear(Reference)
			Folder:ClearAllChildren()
		end
	end,
	Tooltip = 'Displays blocks over the bed'
})
Quantity = BedPlates:CreateToggle({
	Name = 'Quantity',
	Tooltip = 'Shows how many of each block there are',
	Function = refreshAll,
	Default = true
})
FullLayers = BedPlates:CreateToggle({
	Name = 'Full Layers',
	Tooltip = 'Highlights blocks that cover a whole layer on their own',
	Function = function(callback)
		if FullColor.Object then
			FullColor.Object.Visible = callback
		end
		refreshAll()
	end,
	Default = true
})
FullColor = BedPlates:CreateColorSlider({
	Name = 'Full Layer Color',
	Tooltip = 'Color of the full layer highlight',
	DefaultHue = 0.33,
	DefaultSat = 0.75,
	DefaultValue = 1,
	DefaultOpacity = 0.6,
	Function = refreshAll,
	Darker = true
})
Background = BedPlates:CreateToggle({
	Name = 'Background',
	Tooltip = 'Draws a background behind the text',
	Function = function(callback)
		if Color.Object then
			Color.Object.Visible = callback
		end
		for _, v in Reference do
			v.Frame.BackgroundTransparency = 1 - (callback and Color.Opacity or 0)
			v.Blur.Visible = callback
		end
	end,
	Default = true
})
Color = BedPlates:CreateColorSlider({
	Name = 'Background Color',
	Tooltip = 'Color of the background',
	DefaultValue = 0,
	DefaultOpacity = 0.5,
	Function = function(hue, sat, val, opacity)
		for _, v in Reference do
			v.Frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			v.Frame.BackgroundTransparency = 1 - opacity
		end
	end,
	Darker = true
})
