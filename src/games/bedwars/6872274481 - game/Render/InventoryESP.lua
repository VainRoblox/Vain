local InventoryESP
local List
local Background
local Color = {}
local ShowAmount
local ShowArmor
-- ent -> {Billboard = BillboardGui, Player = Player}
-- The player is kept alongside the billboard because the adornee is the root
-- part, and walking up its Parent chain lands on the workspace, not the player.
local Entries = {}
local Folder = Instance.new('Folder')
Folder.Parent = vain.gui

-- Every setting below is created *after* CreateModule returns, so any of them can
-- still be nil while the file is executing. The module can be switched on inside
-- that window when the GUI restores a saved config, which made reading .Enabled
-- straight off them throw once per entity, every frame.
local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function listed(itemType)
	if not itemType then return false end
	if not (List and List.ListEnabled) then return false end
	if table.find(List.ListEnabled, itemType) then return true end
	for _, v in List.ListEnabled do
		if itemType:find(v) then return true end
	end
	return false
end

local function addIcon(frame, item)
	local image = Instance.new('ImageLabel')
	image.Size = UDim2.fromOffset(32, 32)
	image.BackgroundTransparency = 1
	image.Image = bedwars.getIcon(item, true)
	image.Parent = frame

	local amount = tonumber(item.amount)
	if on(ShowAmount) and amount and amount > 1 then
		local text = Instance.new('TextLabel')
		text.Name = 'Amount'
		text.Size = UDim2.fromOffset(16, 16)
		text.Position = UDim2.fromOffset(16, 16)
		text.BackgroundColor3 = Color3.new(0, 0, 0)
		text.BackgroundTransparency = 0.3
		text.TextColor3 = Color3.new(1, 1, 1)
		text.TextSize = 12
		text.Text = tostring(amount)
		text.Parent = image
		local corner = Instance.new('UICorner')
		corner.CornerRadius = UDim.new(0, 2)
		corner.Parent = text
	end
end

local function refreshAdornee(billboard, plr)
	if not (billboard and billboard.Parent and plr) then return end
	local frame = billboard:FindFirstChild('Frame')
	if not frame then return end

	local inventory = store.inventories[plr]
	if not inventory then
		billboard.Enabled = false
		return
	end

	for _, obj in frame:GetChildren() do
		if obj:IsA('ImageLabel') and obj.Name ~= 'Blur' then
			obj:Destroy()
		end
	end

	local shown, any = {}, false

	local hand = inventory.hand
	if type(hand) == 'table' and hand.itemType and listed(hand.itemType) then
		shown[hand.itemType] = true
		any = true
		addIcon(frame, hand)
	end

	-- Armor slot numbering has moved around between updates, so this walks whatever
	-- the table holds rather than assuming fixed indices. Empty slots come through
	-- as the string 'empty'.
	if on(ShowArmor) and type(inventory.armor) == 'table' then
		for _, armor in inventory.armor do
			if type(armor) == 'table' and armor.itemType and not shown[armor.itemType] then
				shown[armor.itemType] = true
				any = true
				addIcon(frame, armor)
			end
		end
	end

	billboard.Enabled = any
end

local function refreshAll()
	for ent, entry in Entries do
		if entry.Billboard.Parent and entry.Player and entry.Player.Parent then
			refreshAdornee(entry.Billboard, entry.Player)
		else
			entry.Billboard:Destroy()
			Entries[ent] = nil
		end
	end
end

local function Added(ent)
	if not ent.Player or Entries[ent] then return end

	local billboard = Instance.new('BillboardGui')
	billboard.Parent = Folder
	billboard.Name = 'inventory'
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
	billboard.Size = UDim2.fromOffset(36, 36)
	billboard.AlwaysOnTop = true
	billboard.ClipsDescendants = false
	billboard.Adornee = ent.RootPart
	billboard.Enabled = false
	local blur = addBlur(billboard)
	blur.Visible = on(Background)
	local frame = Instance.new('Frame')
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromHSV(Color.Hue or 0, Color.Sat or 0, Color.Value or 0.15)
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

	Entries[ent] = {Billboard = billboard, Player = ent.Player}
end

InventoryESP = vain.Categories.Render:CreateModule({
	Name = 'InventoryESP',
	Function = function(callback)
		if callback then
			for _, ent in entitylib.List do
				Added(ent)
			end
			InventoryESP:Clean(entitylib.Events.EntityAdded:Connect(Added))
			InventoryESP:Clean(entitylib.Events.EntityRemoved:Connect(function(ent)
				local entry = Entries[ent]
				if entry then
					entry.Billboard:Destroy()
					Entries[ent] = nil
				end
			end))

			-- A single throttled pass, not a RenderStepped connection per entity.
			-- Rebuilding every icon for every player each frame was both the source
			-- of the error spam and far more work than this needs.
			task.spawn(function()
				repeat
					local ok = pcall(refreshAll)
					task.wait(ok and 0.2 or 0.5)
				until not InventoryESP.Enabled
			end)
		else
			table.clear(Entries)
			Folder:ClearAllChildren()
		end
	end,
	Tooltip = 'Shows what players are holding and wearing'
})
List = InventoryESP:CreateTextList({
	Name = 'Item',
	Tooltip = 'Which held items this applies to',
	Function = function()
		task.spawn(refreshAll)
	end
})
Background = InventoryESP:CreateToggle({
	Name = 'Background',
	Tooltip = 'Draws a background behind the icons',
	Function = function(callback)
		if Color.Object then Color.Object.Visible = callback end
		for _, entry in Entries do
			local frame = entry.Billboard:FindFirstChild('Frame')
			local blur = entry.Billboard:FindFirstChild('Blur')
			if frame then
				frame.BackgroundTransparency = 1 - (callback and (Color.Opacity or 0.5) or 0)
			end
			if blur then
				blur.Visible = callback
			end
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
		for _, entry in Entries do
			local frame = entry.Billboard:FindFirstChild('Frame')
			if frame then
				frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
				frame.BackgroundTransparency = 1 - opacity
			end
		end
	end,
	Darker = true
})
ShowAmount = InventoryESP:CreateToggle({
	Name = 'Show Amount',
	Tooltip = 'Displays the quantity of each item in the corner',
	Function = function()
		task.spawn(refreshAll)
	end
})
ShowArmor = InventoryESP:CreateToggle({
	Name = 'Show Armor',
	Tooltip = 'Also displays the armor the target is wearing',
	Default = true,
	Function = function()
		task.spawn(refreshAll)
	end
})
