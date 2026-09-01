local StorageESP
local List
local Background
local Color = {}
local ShowAmount
local ShowAll
local Reference = {}
local Folder = Instance.new('Folder')
Folder.Parent = vain.gui

-- Settings are created after CreateModule returns, so they can still be nil while
-- this file is executing - and the module can be switched on inside that window
-- when the GUI restores a saved config. Reading .Enabled straight off them threw.
local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function nearStorageItem(item)
	for _, v in List.ListEnabled do
		if item:find(v) then return v end
	end
end

local function refreshAdornee(v)
	local chest = v.Adornee:FindFirstChild('ChestFolderValue')
	chest = chest and chest.Value or nil
	if not chest then
		v.Enabled = false
		return
	end

	local chestitems = chest and chest:GetChildren() or {}
	for _, obj in v.Frame:GetChildren() do
		if obj:IsA('ImageLabel') and obj.Name ~= 'Blur' then
			obj:Destroy()
		end
	end

	v.Enabled = false

	--[[
		Tallied first, drawn second.

		How many of something a chest holds is an Amount attribute on the item, not a child
		of it - looking for a child called Value found nothing, every time, which is why no
		number was ever drawn.

		A chest can also hold the same item in more than one stack, so the amounts are
		summed. Reading only the first stack, the way the old dedup did, would under-report
		anything that arrived in separate drops.
	]]
	local order, totals = {}, {}
	for _, item in chestitems do
		--[[
			A child with no Amount is not an item.

			Every item the game builds is given one, defaulting to 1, so anything in the
			folder without it is the chest's own furniture rather than loot. Counting those
			as one apiece drew a phantom entry with a blank icon and a made-up count.
		]]
		local amount = item:GetAttribute('Amount')
		if type(amount) ~= 'number' then continue end

		-- ShowAll displays all items regardless of the list; otherwise use the filter
		local shouldShow = on(ShowAll) or table.find(List.ListEnabled, item.Name) or nearStorageItem(item.Name)
		if not shouldShow then continue end

		if totals[item.Name] == nil then
			order[#order + 1] = item.Name
			totals[item.Name] = 0
		end
		totals[item.Name] = totals[item.Name] + amount
	end

	for _, name in order do
		v.Enabled = true
		local blockimage = Instance.new('ImageLabel')
		blockimage.Size = UDim2.fromOffset(32, 32)
		blockimage.BackgroundTransparency = 1
		blockimage.Image = bedwars.getIcon({itemType = name}, true)
		blockimage.Parent = v.Frame

		if on(ShowAmount) then
			-- An endless supply reads as a symbol rather than as 'inf', and a count that
			-- is not a number at all is left off instead of printed as nonsense.
			local total = totals[name]
			local text = total == total and (math.abs(total) == math.huge and '\u{221E}' or tostring(total)) or nil

			local textlabel = Instance.new('TextLabel')
			textlabel.Name = 'Amount'
			textlabel.Size = UDim2.fromOffset(16, 16)
			textlabel.Position = UDim2.fromOffset(16, 16)
			textlabel.BackgroundColor3 = Color3.new(0, 0, 0)
			textlabel.BackgroundTransparency = 0.3
			textlabel.TextColor3 = Color3.new(1, 1, 1)
			textlabel.TextSize = 12
			textlabel.Text = text or ''
			textlabel.Visible = text ~= nil
			textlabel.Parent = blockimage
			local corner = Instance.new('UICorner')
			corner.CornerRadius = UDim.new(0, 2)
			corner.Parent = textlabel
		end
	end
	table.clear(chestitems)
end

local function Added(v)
	local chest = v:WaitForChild('ChestFolderValue', 3)
	if not (chest and StorageESP.Enabled) then return end
	chest = chest.Value
	local billboard = Instance.new('BillboardGui')
	billboard.Parent = Folder
	billboard.Name = 'chest'
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
	billboard.Size = UDim2.fromOffset(36, 36)
	billboard.AlwaysOnTop = true
	billboard.ClipsDescendants = false
	billboard.Adornee = v
	local blur = addBlur(billboard)
	blur.Visible = on(Background)
	local frame = Instance.new('Frame')
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
	frame.BackgroundTransparency = 1 - (on(Background) and (Color.Opacity or 0.5) or 0)
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

	-- Taking part of a stack changes the item's Amount without the folder gaining or
	-- losing a child, so ChildAdded alone would leave the number showing what was there
	-- when the chest was first looked at.
	local function watchAmount(item)
		StorageESP:Clean(item:GetAttributeChangedSignal('Amount'):Connect(function()
			refreshAdornee(billboard)
		end))
	end
	for _, item in chest:GetChildren() do
		watchAmount(item)
	end

	StorageESP:Clean(chest.ChildAdded:Connect(function(item)
		watchAmount(item)
		if on(ShowAll) or table.find(List.ListEnabled, item.Name) or nearStorageItem(item.Name) then
			refreshAdornee(billboard)
		end
	end))
	StorageESP:Clean(chest.ChildRemoved:Connect(function(item)
		if on(ShowAll) or table.find(List.ListEnabled, item.Name) or nearStorageItem(item.Name) then
			refreshAdornee(billboard)
		end
	end))
	task.spawn(refreshAdornee, billboard)
end

StorageESP = vain.Categories.Render:CreateModule({
	Name = 'StorageESP',
	Function = function(callback)
		if callback then
			StorageESP:Clean(collectionService:GetInstanceAddedSignal('chest'):Connect(Added))
			for _, v in collectionService:GetTagged('chest') do
				task.spawn(Added, v)
			end
		else
			table.clear(Reference)
			Folder:ClearAllChildren()
		end
	end,
	Tooltip = 'Displays items in chests'
})
List = StorageESP:CreateTextList({
	Name = 'Item',
	Tooltip = 'Which items this applies to',
	Function = function()
		for _, v in Reference do
			task.spawn(refreshAdornee, v)
		end
	end
})
Background = StorageESP:CreateToggle({
	Name = 'Background',
	Tooltip = 'Draws a background behind the text',
	Function = function(callback)
		if Color.Object then Color.Object.Visible = callback end
		for _, v in Reference do
			v.Frame.BackgroundTransparency = 1 - (callback and Color.Opacity or 0)
			v.Blur.Visible = callback
		end
	end,
	Default = true
})
Color = StorageESP:CreateColorSlider({
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
ShowAmount = StorageESP:CreateToggle({
	Name = 'Show Amount',
	Tooltip = 'Displays the quantity of each item in the corner',
	Function = function()
		for _, v in Reference do
			task.spawn(refreshAdornee, v)
		end
	end
})
ShowAll = StorageESP:CreateToggle({
	Name = 'Show All',
	Tooltip = 'Shows all items instead of only those in the list',
	Function = function()
		for _, v in Reference do
			task.spawn(refreshAdornee, v)
		end
	end
})