local InventoryESP
local List
local Background
local Color = {}
local ShowAmount
local ShowArmor
local Reference = {}
local Folder = Instance.new('Folder')
Folder.Parent = vain.gui

local function nearItem(item)
	for _, v in List.ListEnabled do
		if item:find(v) then return v end
	end
end

local function refreshAdornee(billboard, plr)
	if not plr or not plr.Parent then
		billboard.Enabled = false
		return
	end

	local inventory = store.inventories[plr]
	if not inventory then
		billboard.Enabled = false
		return
	end

	for _, obj in billboard.Frame:GetChildren() do
		if obj:IsA('ImageLabel') and obj.Name ~= 'Blur' then
			obj:Destroy()
		end
	end

	billboard.Enabled = false
	local shown = {}

	-- Show held item (hand)
	if inventory.hand and (table.find(List.ListEnabled, inventory.hand.itemType) or nearItem(inventory.hand.itemType)) then
		if not shown[inventory.hand.itemType] then
			shown[inventory.hand.itemType] = true
			billboard.Enabled = true
			local image = Instance.new('ImageLabel')
			image.Size = UDim2.fromOffset(32, 32)
			image.BackgroundTransparency = 1
			image.Image = bedwars.getIcon(inventory.hand, true)
			image.Parent = billboard.Frame

			if ShowAmount.Enabled and inventory.hand.amount then
				local text = Instance.new('TextLabel')
				text.Name = 'Amount'
				text.Size = UDim2.fromOffset(16, 16)
				text.Position = UDim2.fromOffset(16, 16)
				text.BackgroundColor3 = Color3.new(0, 0, 0)
				text.BackgroundTransparency = 0.3
				text.TextColor3 = Color3.new(1, 1, 1)
				text.TextSize = 12
				text.Text = tostring(inventory.hand.amount)
				text.Parent = image
				local corner = Instance.new('UICorner')
				corner.CornerRadius = UDim.new(0, 2)
				corner.Parent = text
			end
		end
	end

	-- Show armor if enabled
	if ShowArmor.Enabled and inventory.armor then
		for slot = 4, 6 do
			local armor = inventory.armor[slot]
			if armor and not shown[armor.itemType] then
				shown[armor.itemType] = true
				billboard.Enabled = true
				local image = Instance.new('ImageLabel')
				image.Size = UDim2.fromOffset(32, 32)
				image.BackgroundTransparency = 1
				image.Image = bedwars.getIcon(armor, true)
				image.Parent = billboard.Frame

				if ShowAmount.Enabled and armor.amount then
					local text = Instance.new('TextLabel')
					text.Name = 'Amount'
					text.Size = UDim2.fromOffset(16, 16)
					text.Position = UDim2.fromOffset(16, 16)
					text.BackgroundColor3 = Color3.new(0, 0, 0)
					text.BackgroundTransparency = 0.3
					text.TextColor3 = Color3.new(1, 1, 1)
					text.TextSize = 12
					text.Text = tostring(armor.amount)
					text.Parent = image
					local corner = Instance.new('UICorner')
					corner.CornerRadius = UDim.new(0, 2)
					corner.Parent = text
				end
			end
		end
	end
end

local function Added(ent)
	if not ent.Player then return end

	local billboard = Instance.new('BillboardGui')
	billboard.Parent = Folder
	billboard.Name = 'inventory'
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
	billboard.Size = UDim2.fromOffset(36, 36)
	billboard.AlwaysOnTop = true
	billboard.ClipsDescendants = false
	billboard.Adornee = ent.RootPart
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
	Reference[ent] = billboard

	-- Refresh on inventory changes
	InventoryESP:Clean(runService.RenderStepped:Connect(function()
		if ent.Player and ent.Player.Parent then
			refreshAdornee(billboard, ent.Player)
		end
	end))
end

InventoryESP = vain.Categories.Render:CreateModule({
	Name = 'InventoryESP',
	Function = function(callback)
		if callback then
			for _, ent in entitylib.List do
				if ent.Player and not Reference[ent] then
					Added(ent)
				end
			end
			InventoryESP:Clean(entitylib.Events.EntityAdded:Connect(function(ent)
				if ent.Player and not Reference[ent] then
					Added(ent)
				end
			end))
			InventoryESP:Clean(entitylib.Events.EntityRemoved:Connect(function(ent)
				if Reference[ent] then
					Reference[ent]:Destroy()
					Reference[ent] = nil
				end
			end))
		else
			table.clear(Reference)
			Folder:ClearAllChildren()
		end
	end,
	Tooltip = 'Displays what players are holding and wearing'
})
List = InventoryESP:CreateTextList({
	Name = 'Item',
	Tooltip = 'Which held items this applies to',
	Function = function()
		for _, v in Reference do
			local plr = v.Adornee.Parent.Parent
			if plr then
				task.spawn(refreshAdornee, v, plr)
			end
		end
	end
})
Background = InventoryESP:CreateToggle({
	Name = 'Background',
	Tooltip = 'Draws a background behind the icons',
	Function = function(callback)
		if Color.Object then Color.Object.Visible = callback end
		for _, v in Reference do
			v.Frame.BackgroundTransparency = 1 - (callback and Color.Opacity or 0)
			v.Blur.Visible = callback
		end
	end,
	Default = true
})
Color = InventoryESP:CreateColorSlider({
	Name = 'Background Color',
	Tooltip = 'Color of the background',
	DefaultValue = 0.15,
	DefaultOpacity = 0.5,
	Function = function(hue, sat, val, opacity)
		for _, v in Reference do
			v.Frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			v.Frame.BackgroundTransparency = 1 - opacity
		end
	end,
	Darker = true
})
ShowAmount = InventoryESP:CreateToggle({
	Name = 'Show Amount',
	Tooltip = 'Displays the quantity of each item in the corner',
	Function = function()
		for _, v in Reference do
			local plr = v.Adornee.Parent.Parent
			if plr then
				task.spawn(refreshAdornee, v, plr)
			end
		end
	end
})
ShowArmor = InventoryESP:CreateToggle({
	Name = 'Show Armor',
	Tooltip = 'Displays the target armor pieces',
	Default = true,
	Function = function()
		for _, v in Reference do
			local plr = v.Adornee.Parent.Parent
			if plr then
				task.spawn(refreshAdornee, v, plr)
			end
		end
	end
})
