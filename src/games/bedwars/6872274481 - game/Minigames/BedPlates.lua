local BedPlates
local Background
local Color = {}
local Quantity
local FullLayers
local FullColor = {}
local UpdateRate
local Reference = {}
local Signature = {}
local Folder = Instance.new('Folder')
Folder.Parent = vain.gui

-- How deep a wrap is worth reporting on, and a ceiling on how much can be walked in
-- one go so a huge base cannot stall a refresh.
local MAX_LAYERS = 6
local SCAN_LIMIT = 1200

-- Ore is part of the map that happens to be sitting against somebody's wrap, not
-- something they built to defend it. It is walked past rather than counted, so a bed
-- that touches a generator does not pick up a stray icon reading 1.
-- Terrain the map is made of rather than anything anybody placed. Snow is not on sale
-- in the shop at all - it is what a winter map's ground is covered in - so a bed sitting
-- on it picked up a plate counting the field it stands in, and the walk spread out
-- across that field instead of following the wrap round. Stepped over exactly the way
-- the island underneath is: not counted, not walked through, and not a hole in the layer
-- either, since it is solid.
local TERRAIN = {
	snow = true
}

local IGNORED = {
	iron_ore = true,
	iron_ore_mesh_block = true,
	diamond_ore = true,
	emerald_ore = true,
	crystal_ore = true
}

--[[
	Walks outwards from the bed one layer at a time and reports what is around it: how
	many of each block, and what each layer is made of.

	Following the six faces out from the bed the way the old scan did can only ever meet
	one block per direction per step, so every layer came back as about eight however
	many blocks were really in it. This walks the whole shell instead.

	Unbreakable blocks are stepped over rather than counted, which is what keeps the walk
	out of the island the bed is standing on - it is solid, so it is not a hole in the
	layer either, it just is not part of anybody's defence.
]]
local function scanBed(bed)
	local names, counts, layers, open, mixed = {}, {}, {}, {}, {}
	local seen, frontier, visited = {}, {}, 0

	-- Straight off the block handler rather than assuming which way the bed lies, so a
	-- rotated one is walked from both of its halves like any other.
	for _, v in bedwars.getContainedPositions(bed) do
		local pos = v * 3
		seen[pos] = true
		table.insert(frontier, pos)
	end

	for depth = 1, MAX_LAYERS do
		local nextfrontier, types = {}, {}
		layers[depth] = types

		for _, pos in frontier do
			for _, side in sides do
				local at = pos + side
				local block = getPlacedBlock(at)
				if not block then
					-- Nothing here, so this layer has a way through it. Checked before the
					-- already-visited test on purpose: a gap next to two different layers
					-- was being claimed by the nearer one and never counted against the
					-- other, so a layer with a hole beside it still came out complete.
					open[depth] = true
					seen[at] = true
					continue
				end

				if seen[at] then continue end
				seen[at] = true
				if block == bed or block:GetAttribute('NoBreak') or TERRAIN[block.Name] then continue end

				-- Still stepped through, so a wrap with ore embedded in it is followed all
				-- the way round, and still solid, so it does not read as a hole either.
				if IGNORED[block.Name] then
					-- It does stop the layer being a full layer of anything though. A spot
					-- taken by a generator is a spot nobody wrapped, whatever is around it.
					mixed[depth] = true
				else
					if not table.find(names, block.Name) then
						table.insert(names, block.Name)
					end
					counts[block.Name] = (counts[block.Name] or 0) + 1
					types[block.Name] = (types[block.Name] or 0) + 1
				end

				visited += 1
				table.insert(nextfrontier, at)
			end
		end

		frontier = nextfrontier
		if #frontier == 0 or visited >= SCAN_LIMIT then break end
	end

	-- A hole anywhere further in means the wrap has already been breached, so nothing
	-- outside it is a complete layer either. Breaking blocks reshuffles which layer the
	-- survivors land in, and a layer left holding two blocks of one kind would otherwise
	-- report itself complete.
	local breached = false
	local full = {}
	for depth = 1, MAX_LAYERS do
		local types = layers[depth]
		if not types then break end
		if open[depth] then breached = true end
		if breached or mixed[depth] then continue end

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

-- What the plate would look like, as a string. Re-checking is cheap but tearing down
-- and rebuilding every icon is not, so with a refresh running on a timer the drawing
-- only happens when this comes out different from last time.
local function signature(order, counts, full)
	local parts = {}
	for _, name in order do
		table.insert(parts, name .. 'x' .. counts[name] .. (full[name] and '!' or ''))
	end
	table.insert(parts, tostring(Quantity and Quantity.Enabled) .. tostring(FullLayers and FullLayers.Enabled))
	table.insert(parts, string.format('%.3f %.3f %.3f %.3f', FullColor.Hue or 0, FullColor.Sat or 0, FullColor.Value or 0, FullColor.Opacity or 0))
	return table.concat(parts, '|')
end

local function refreshAdornee(v)
	if not v.Adornee then return end

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

	local sig = signature(order, counts, full)
	if Signature[v] == sig then return end
	Signature[v] = sig

	for _, obj in v.Frame:GetChildren() do
		if obj.Name == 'Block' then
			obj:Destroy()
		end
	end

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
					Signature[Reference[v]] = nil
					Reference[v]:Destroy()
					Reference[v]:ClearAllChildren()
					Reference[v] = nil
				end
			end))

			-- The block events only report what the server tells us about, and a layer
			-- that quietly stopped being complete is exactly the thing you want to notice.
			-- Guarded so one bad pass cannot kill the loop, with the wait outside so a
			-- repeating error cannot spin the CPU.
			task.spawn(function()
				repeat
					local ok = pcall(refreshAll)
					-- The slider may not exist yet if a saved config switched this on while the
					-- file was still running, and an error out here would end the loop for good.
					task.wait(ok and UpdateRate and (1 / UpdateRate.Value) or 0.5)
				until not BedPlates.Enabled
			end)
		else
			table.clear(Reference)
			table.clear(Signature)
			Folder:ClearAllChildren()
		end
	end,
	Tooltip = 'Displays blocks over the bed'
})
UpdateRate = BedPlates:CreateSlider({
	Name = 'Update Rate',
	Tooltip = 'How often the plates are re-checked\nLower costs less performance',
	Min = 1,
	Max = 60,
	Default = 10,
	Suffix = 'hz'
})
Quantity = BedPlates:CreateToggle({
	Name = 'Show Amount',
	Tooltip = 'Shows how many of each block there are',
	Function = refreshAll,
	Default = true
})
FullLayers = BedPlates:CreateToggle({
	Name = 'Highlight Full Layers',
	Tooltip = 'Marks blocks that cover a whole layer on their own',
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
