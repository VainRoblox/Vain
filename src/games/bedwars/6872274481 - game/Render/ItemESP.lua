--[[
	Item ESP.

	Items lying on the ground are parts tagged ItemDrop, named by their item type and
	carrying their stack size in Amount. Each wanted one gets a small label - its icon, how
	many and how far - through walls, optionally with an outline. Drops sitting on a
	generator can be left out, since Generator ESP already counts those.
]]
local ItemESP
local Diamonds, Emeralds, Iron, Gold, Pearls, TNT, Others, OtherList
local SkipGenerators, Range, ShowDistance, Outline, TextSize, Group, GroupRadius
local Folder = Instance.new('Folder')
Folder.Name = 'ItemESP'
Folder.Parent = vain.gui
local drops = {}

local GROUPS = {
	diamond = function() return Diamonds end,
	emerald = function() return Emeralds end,
	iron = function() return Iron end,
	gold = function() return Gold end,
	telepearl = function() return Pearls end,
	tnt = function() return TNT end
}
local COLORS = {
	diamond = Color3.fromRGB(110, 210, 255),
	emerald = Color3.fromRGB(90, 230, 120),
	iron = Color3.fromRGB(220, 220, 220),
	gold = Color3.fromRGB(255, 210, 80),
	telepearl = Color3.fromRGB(200, 120, 255),
	tnt = Color3.fromRGB(255, 90, 80)
}

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function wanted(itemType)
	local group = GROUPS[itemType]
	if group then return on(group()) end
	return on(Others) and table.find(OtherList.ListEnabled, itemType) ~= nil
end

-- Whether a drop is lying on a generator's pile.
local function onGenerator(position)
	for _, generator in collectionService:GetTagged('Generator') do
		if generator:IsA('BasePart') then
			local offset = position - generator.Position
			if Vector2.new(offset.X, offset.Z).Magnitude <= 9 and offset.Y <= 4 and offset.Y >= -14 then
				return true
			end
		end
	end
	return false
end

local function remove(drop)
	local entry = drops[drop]
	if not entry then return end
	entry.billboard:Destroy()
	if entry.highlight then entry.highlight:Destroy() end
	drops[drop] = nil
end

local function add(drop)
	if drops[drop] then return end
	local part = drop:IsA('BasePart') and drop or drop:FindFirstChildWhichIsA('BasePart', true)
	if not part then return end

	local billboard = Instance.new('BillboardGui')
	billboard.Adornee = part
	billboard.Size = UDim2.fromOffset(120, 20)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 1.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Enabled = false
	billboard.Parent = Folder
	local holder = Instance.new('Frame')
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromScale(1, 1)
	holder.Parent = billboard
	local layout = Instance.new('UIListLayout')
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 3)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = holder
	local icon = Instance.new('ImageLabel')
	icon.BackgroundTransparency = 1
	icon.SizeConstraint = Enum.SizeConstraint.RelativeYY
	icon.Size = UDim2.fromScale(1, 1)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.LayoutOrder = 1
	local meta = bedwars.ItemMeta[drop.Name]
	icon.Image = meta and meta.image or ''
	icon.Parent = holder
	local label = Instance.new('TextLabel')
	label.BackgroundTransparency = 1
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromScale(0, 1)
	label.Font = Enum.Font.GothamBold
	label.TextStrokeTransparency = 0.4
	label.LayoutOrder = 2
	label.Parent = holder

	drops[drop] = {billboard = billboard, label = label, part = part}
end

--[[
	Drops of the same item lying close together share one label with their total, on the
	first of them, so a scattered pile reads "x12" once rather than twelve times.
]]
local function show(entry, drop, amount, distance, here)
	local color = COLORS[drop.Name] or Color3.new(1, 1, 1)
	entry.label.Text = 'x' .. amount .. (on(ShowDistance) and here and string.format('  %dm', math.floor(distance)) or '')
	entry.label.TextColor3 = color
	entry.label.TextSize = TextSize.Value
	entry.billboard.Size = UDim2.fromOffset(TextSize.Value * 9, TextSize.Value + 6)
	entry.billboard.Enabled = true
	if on(Outline) then
		if not entry.highlight then
			entry.highlight = Instance.new('Highlight')
			entry.highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			entry.highlight.FillTransparency = 0.6
			entry.highlight.Adornee = drop
			entry.highlight.Parent = Folder
		end
		entry.highlight.FillColor = color
		entry.highlight.OutlineColor = color
		entry.highlight.Enabled = true
	elseif entry.highlight then
		entry.highlight.Enabled = false
	end
end

local function hide(entry)
	entry.billboard.Enabled = false
	if entry.highlight then entry.highlight.Enabled = false end
end

local function update()
	local here = entitylib.isAlive and entitylib.character.RootPart.Position
	local wantedDrops = {}
	for drop, entry in drops do
		if not (drop.Parent and entry.part.Parent) then
			remove(drop)
			continue
		end
		local position = entry.part.Position
		local distance = here and (position - here).Magnitude or 0
		if wanted(drop.Name) and distance <= Range.Value and not (on(SkipGenerators) and onGenerator(position)) then
			wantedDrops[#wantedDrops + 1] = {drop = drop, entry = entry, position = position, distance = distance,
				amount = tonumber(drop:GetAttribute('Amount')) or 1}
		else
			hide(entry)
		end
	end

	if not on(Group) then
		for _, item in wantedDrops do show(item.entry, item.drop, item.amount, item.distance, here) end
		return
	end
	-- Nearest first, so each group's label sits on the drop closest to you.
	table.sort(wantedDrops, function(a, b) return a.distance < b.distance end)
	local taken = {}
	for i, leader in wantedDrops do
		if not taken[i] then
			local total = leader.amount
			for j = i + 1, #wantedDrops do
				local other = wantedDrops[j]
				if not taken[j] and other.drop.Name == leader.drop.Name and (other.position - leader.position).Magnitude <= GroupRadius.Value then
					taken[j] = true
					total += other.amount
					hide(other.entry)
				end
			end
			show(leader.entry, leader.drop, total, leader.distance, here)
		end
	end
end

ItemESP = vain.Categories.Render:CreateModule({
	Name = 'Item ESP',
	Tooltip = 'Shows valuable items lying on the ground',
	Function = function(callback)
		if callback then
			for _, drop in collectionService:GetTagged('ItemDrop') do add(drop) end
			ItemESP:Clean(collectionService:GetInstanceAddedSignal('ItemDrop'):Connect(function(drop)
				task.defer(add, drop)
			end))
			ItemESP:Clean(collectionService:GetInstanceRemovedSignal('ItemDrop'):Connect(remove))
			-- Five times a second; drops do not move much once they land.
			local last = 0
			ItemESP:Clean(runService.Heartbeat:Connect(function()
				if os.clock() - last < 0.2 then return end
				last = os.clock()
				pcall(update)
			end))
		else
			for drop in drops do remove(drop) end
		end
	end
})
Diamonds = ItemESP:CreateToggle({Name = 'Diamonds', Tooltip = 'Shows diamonds', Default = true})
Emeralds = ItemESP:CreateToggle({Name = 'Emeralds', Tooltip = 'Shows emeralds', Default = true})
Iron = ItemESP:CreateToggle({Name = 'Iron', Tooltip = 'Shows iron'})
Gold = ItemESP:CreateToggle({Name = 'Gold', Tooltip = 'Shows gold'})
Pearls = ItemESP:CreateToggle({Name = 'Pearls', Tooltip = 'Shows telepearls', Default = true})
TNT = ItemESP:CreateToggle({Name = 'TNT', Tooltip = 'Shows TNT', Default = true})
Others = ItemESP:CreateToggle({
	Name = 'Other Items',
	Tooltip = 'Also shows the items listed below',
	Function = function(callback)
		if OtherList and OtherList.Object then OtherList.Object.Visible = callback end
	end
})
OtherList = ItemESP:CreateTextList({
	Name = 'Items',
	Tooltip = 'Item names to show too',
	Placeholder = 'item name (fireball)',
	Visible = false
})
SkipGenerators = ItemESP:CreateToggle({
	Name = 'Skip Generators',
	Tooltip = 'Leaves out drops piled on generators',
	Default = true
})
Group = ItemESP:CreateToggle({
	Name = 'Group Nearby',
	Tooltip = 'One label with the total for close drops',
	Default = true,
	Function = function(callback)
		if GroupRadius and GroupRadius.Object then GroupRadius.Object.Visible = callback end
	end
})
GroupRadius = ItemESP:CreateSlider({
	Name = 'Group Radius',
	Tooltip = 'How close drops have to be to share a label',
	Min = 1,
	Max = 20,
	Default = 5,
	Darker = true,
	Suffix = function(val) return val == 1 and 'stud' or 'studs' end
})
ShowDistance = ItemESP:CreateToggle({Name = 'Distance', Tooltip = 'Shows how far away each one is', Default = true})
Outline = ItemESP:CreateToggle({Name = 'Outline', Tooltip = 'Outlines the item itself'})
Range = ItemESP:CreateSlider({
	Name = 'Range',
	Tooltip = 'How far away items are shown',
	Min = 10,
	Max = 500,
	Default = 120,
	Suffix = function(val) return val == 1 and 'stud' or 'studs' end
})
TextSize = ItemESP:CreateSlider({
	Name = 'Text Size',
	Tooltip = 'How big the labels are',
	Min = 8,
	Max = 22,
	Default = 13
})
