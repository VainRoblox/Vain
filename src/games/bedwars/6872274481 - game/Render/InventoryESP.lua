local InventoryESP
local List
local Background
local Color = {}
local ShowAmount
local Presets = {}

-- The things worth knowing an enemy has. Ordered, so the icons always come out the same
-- way round rather than in whatever order the inventory happened to be in.
local PRESETS = {
	{Name = 'Iron', Type = 'iron'},
	{Name = 'Gold', Type = 'gold'},
	{Name = 'Diamond', Type = 'diamond'},
	{Name = 'Emerald', Type = 'emerald'},
	{Name = 'Telepearl', Type = 'telepearl'},
	{Name = 'Fireball', Type = 'fireball'},
	{Name = 'TNT', Type = 'tnt'},
	{Name = 'Obsidian', Type = 'obsidian'},
	{Name = 'Golden Apple', Type = 'golden_apple'}
}
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

	local preset = Presets[itemType]
	if preset and preset.Enabled then return true end

	if List and List.ListEnabled then
		if table.find(List.ListEnabled, itemType) then return true end
		for _, v in List.ListEnabled do
			if itemType:find(v) then return true end
		end
	end
	return false
end

local function addIcon(frame, itemType, amount)
	local image = Instance.new('ImageLabel')
	image.Size = UDim2.fromOffset(32, 32)
	image.BackgroundTransparency = 1
	image.Image = bedwars.getIcon({itemType = itemType}, true)
	image.Parent = frame

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

--[[
	Draws what a player is carrying.

	The whole inventory, not just their hand. Only inventory.hand was ever looked at
	before, which is why adding anything to the item list did nothing unless the target
	happened to be holding that exact thing at that exact moment - and why the amount
	never showed either, since a held item is usually a single one.

	Other players' items really are readable; Vain already reads them elsewhere to work
	out how dangerous somebody is. Stacks of the same thing are added together, so eight
	iron in one slot and twelve in another read as twenty rather than as two icons.
]]
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

	local totals, extra = {}, {}

	local function count(item)
		if type(item) ~= 'table' or not item.itemType then return end
		if not listed(item.itemType) then return end

		if not totals[item.itemType] then
			totals[item.itemType] = 0
			if not Presets[item.itemType] then
				table.insert(extra, item.itemType)
			end
		end
		totals[item.itemType] += tonumber(item.amount) or 1
	end

	if type(inventory.items) == 'table' then
		for _, item in inventory.items do
			count(item)
		end
	end

	-- Their hand is normally part of the list above already; this is only for the case
	-- where it is not.
	local hand = inventory.hand
	if type(hand) == 'table' and hand.itemType and not totals[hand.itemType] then
		count(hand)
	end

	-- Presets in their listed order, anything from the custom list after them.
	local any = false
	for _, preset in PRESETS do
		if totals[preset.Type] then
			addIcon(frame, preset.Type, totals[preset.Type])
			any = true
		end
	end
	for _, itemType in extra do
		addIcon(frame, itemType, totals[itemType])
		any = true
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
	Tooltip = 'Shows what players are carrying'
})
List = InventoryESP:CreateTextList({
	Name = 'Item',
	Tooltip = 'Extra items to show, on top of the ones below',
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
for _, preset in PRESETS do
	Presets[preset.Type] = InventoryESP:CreateToggle({
		Name = preset.Name,
		Tooltip = 'Shows '..preset.Name:lower(),
		Default = true,
		Darker = true,
		Function = function()
			task.spawn(refreshAll)
		end
	})
end
