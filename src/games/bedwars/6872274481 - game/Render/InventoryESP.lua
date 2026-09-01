local InventoryESP
local List
local Background
local Color = {}
local ShowAmount
local Size
local Gap
local ShowAll

-- The things worth knowing an enemy has. Seeded straight into the item list, so they can
-- be switched off or removed there like anything else rather than being nine settings of
-- their own.
local PRESETS = {
	'iron',
	'gold',
	'diamond',
	'emerald',
	'telepearl',
	'fireball',
	'tnt',
	'tesla_trap',
	'glue_projectile',
	'snap_trap',
	'golden_apple'
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

-- Icons are drawn at 32 and the strip around them at 36, so one slider moves both.
local function iconSize()
	return math.round(32 * ((Size and Size.Value or 100) / 100))
end

local function stripSize()
	return math.round(36 * ((Size and Size.Value or 100) / 100))
end

-- Which entry of the list an item matches, or nil for one that matches nothing. The
-- position is what orders the icons, so they come out in the order the list is in rather
-- than however the inventory happened to be arranged.
local function listed(itemType)
	if not itemType then return nil end
	if not (List and List.ListEnabled) then return nil end

	for i, v in List.ListEnabled do
		if itemType == v or itemType:find(v) then
			return i
		end
	end

	-- Everything the list did not name, sorted after everything it did.
	if on(ShowAll) then return math.huge end
	return nil
end

--[[
	The folder a player's items actually live in, read straight off their character.

	This is where the game gets it from: an ObjectValue called InventoryFolder on the
	character, pointing at a folder whose children are the items - each named by its item
	type with the count on an Amount attribute. Reading it is live by definition, so
	nothing has to be cached or refreshed.

	Going through bedwars.getInventory instead is what kept emptying this display. That
	resolves the player to an entity first and returns an empty inventory when the lookup
	misses, so a miss is indistinguishable from somebody carrying nothing - and a display
	rebuilt from that shows nothing at all.
]]
local function inventoryFolder(plr)
	local char = plr.Character
	local value = char and char:FindFirstChild('InventoryFolder')
	return value and value.Value
end

local function addIcon(frame, itemType, amount)
	local image = Instance.new('ImageLabel')
	image.Size = UDim2.fromOffset(iconSize(), iconSize())
	image.BackgroundTransparency = 1
	image.Image = bedwars.getIcon({itemType = itemType}, true)
	image.Parent = frame

	if on(ShowAmount) and amount and amount > 1 then
		local text = Instance.new('TextLabel')
		text.Name = 'Amount'
		-- A strip across the bottom of the icon rather than a fixed box in the corner,
		-- with the text scaled to whatever is in it. Four digits at a fixed size ran
		-- straight out of a sixteen pixel box and across the icon next to it, which is
		-- what turned three stacks into one unreadable run of numbers.
		text.Size = UDim2.new(1, 0, 0, 14)
		text.Position = UDim2.new(0, 0, 1, -14)
		text.BackgroundTransparency = 1
		text.TextColor3 = Color3.new(1, 1, 1)
		text.TextScaled = true
		text.Text = tostring(amount)
		text.Parent = image
		-- Scaling alone would blow a single digit up to the full height of the strip.
		local size = Instance.new('UITextSizeConstraint')
		size.MaxTextSize = 12
		size.Parent = text

		-- What the panel behind it used to do. Without something separating the digits
		-- from the icon they sit on, a white number on a light block washes out as soon
		-- as the billboard shrinks with distance.
		local outline = Instance.new('UIStroke')
		outline.Color = Color3.new()
		outline.Thickness = 2
		outline.Parent = text
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
local function refreshAdornee(entry, plr)
	local container = entry.Billboard
	if not (container and container.Parent and plr) then return end
	local frame = container:FindFirstChild('Frame')
	if not frame then return end

	local inventory = store.inventories[plr] or {}

	for _, obj in frame:GetChildren() do
		if obj:IsA('ImageLabel') and obj.Name ~= 'Blur' then
			obj:Destroy()
		end
	end

	local totals, rank, order = {}, {}, {}

	local function count(item)
		if type(item) ~= 'table' or not item.itemType then return end

		local at = listed(item.itemType)
		if not at then return end

		if not totals[item.itemType] then
			totals[item.itemType] = 0
			rank[item.itemType] = at
			table.insert(order, item.itemType)
		end
		totals[item.itemType] += tonumber(item.amount) or 1
	end

	-- Live first. The snapshot is only used when the folder cannot be reached, so the
	-- display falls back to being stale rather than to being empty.
	local folder = inventoryFolder(plr)
	if folder then
		for _, child in folder:GetChildren() do
			count({itemType = child.Name, amount = child:GetAttribute('Amount')})
		end
	elseif type(inventory.items) == 'table' then
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

	table.sort(order, function(a, b)
		if rank[a] == rank[b] then return a < b end
		return rank[a] < rank[b]
	end)

	local any = false
	for _, itemType in order do
		addIcon(frame, itemType, totals[itemType])
		any = true
	end

	entry.Shown = any
end

local function refreshAll()
	for ent, entry in Entries do
		if entry.Billboard.Parent and entry.Player and entry.Player.Parent then
			-- Someone who outranks you is not read either. Knowing what they carry is as
			-- much a use of them as aiming at them, so this follows the same rule the
			-- other render modules do.
			if ent.Protected then
				entry.Shown = false
			else
				refreshAdornee(entry, entry.Player)
			end
		else
			entry.Billboard:Destroy()
			Entries[ent] = nil
		end
	end
end

local function Added(ent)
	if not ent.Player or Entries[ent] then return end

	--[[
		Drawn in screen space, the same way NameTags draws, rather than as a billboard.

		A BillboardGui is sized in the world, so it shrinks as the player gets further
		away - while the name above it is a plain label at a fixed pixel size that does
		not. Two things scaling at different rates cannot be held apart by any offset:
		whatever gap looks right up close is gone at range, which is exactly what kept
		them overlapping.

		Anchored to the same point NameTags anchors to, the head, but by the top edge
		rather than the bottom - so the name grows upward from that point and this hangs
		downward from it, and the two can never meet whatever the distance.
	]]
	local container = Instance.new('Frame')
	container.Name = 'inventory'
	container.AnchorPoint = Vector2.new(0.5, 0)
	container.Size = UDim2.fromOffset(stripSize(), stripSize())
	container.BackgroundTransparency = 1
	container.Visible = false
	container.Parent = Folder

	local blur = addBlur(container)
	blur.Visible = on(Background)

	local frame = Instance.new('Frame')
	frame.Name = 'Frame'
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromHSV(Color.Hue or 0, Color.Sat or 0, Color.Value or 0.15)
	frame.BackgroundTransparency = 1 - (on(Background) and (Color.Opacity or 0.5) or 0)
	frame.Parent = container

	local layout = Instance.new('UIListLayout')
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 4)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
		container.Size = UDim2.fromOffset(math.max(layout.AbsoluteContentSize.X + 4, stripSize()), stripSize())
	end)
	layout.Parent = frame

	local corner = Instance.new('UICorner')
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = frame

	Entries[ent] = {Billboard = container, Player = ent.Player}
end

-- Positioned every frame, since a screen position only means anything for the frame it
-- was worked out in.
local function positionAll()
	for ent, entry in Entries do
		local container = entry.Billboard
		if not container.Parent then continue end

		if not (ent.RootPart and ent.RootPart.Parent) or not entry.Shown then
			container.Visible = false
			continue
		end

		local head = ent.RootPart.Position + Vector3.new(0, (ent.HipHeight or 2.6) + 1, 0)
		local point, onScreen = gameCamera:WorldToViewportPoint(head)
		container.Visible = onScreen
		if onScreen then
			container.Position = UDim2.fromOffset(point.X, point.Y + (Gap and Gap.Value or 4))
		end
	end
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

			-- Position every frame, contents on a timer. A screen position is only valid
			-- for the frame it was worked out in, but rebuilding icons that often is far
			-- more work than this needs and was the source of the old error spam.
			InventoryESP:Clean(runService.RenderStepped:Connect(positionAll))

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
	Tooltip = 'Which items to show',
	Default = PRESETS,
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
Size = InventoryESP:CreateSlider({
	Name = 'Size',
	Tooltip = 'How big the icons are\nDefault is 60, which matches NameTags',
	Min = 25, Max = 250, Default = 60, Suffix = '%',
	Function = function()
		task.spawn(refreshAll)
	end
})
Gap = InventoryESP:CreateSlider({
	Name = 'Gap',
	Tooltip = 'Pixels between the name and the icons\nDefault is 2',
	Min = 0, Max = 40, Default = 2, Suffix = 'px'
})
ShowAll = InventoryESP:CreateToggle({
	Name = 'Show All',
	Tooltip = 'Shows everything they carry, not just the list',
	Function = function()
		task.spawn(refreshAll)
	end
})
ShowAmount = InventoryESP:CreateToggle({
	Name = 'Show Amount',
	Tooltip = 'Displays the quantity of each item in the corner',
	Function = function()
		task.spawn(refreshAll)
	end
})
