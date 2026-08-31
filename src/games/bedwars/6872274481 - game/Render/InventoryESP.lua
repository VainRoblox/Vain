local InventoryESP
local List
local Background
local Color = {}
local ShowAmount
local AllItems

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

-- Which entry of the list an item matches, or nil for one that matches nothing. The
-- position is what orders the icons, so they come out in the order the list is in rather
-- than however the inventory happened to be arranged.
local function listed(itemType)
	if not itemType then return nil end

	if List and List.ListEnabled then
		for i, v in List.ListEnabled do
			if itemType == v or itemType:find(v) then
				return i
			end
		end
	end

	-- Everything the list did not name, sorted after everything it did.
	if on(AllItems) then return math.huge end
	return nil
end

--[[
	How many of an item there are, right now.

	store.inventories is written once when a player is first seen and then only rebuilt
	when they swap their held item or change armor - those four things are all base
	watches for it. A count moving on its own never touches any of them, which is why the
	numbers sat at whatever they were when you injected.

	Each cached item keeps the folder Instance it came from, and that Instance's Amount
	attribute is what actually changes. Reading it is live without having to rebuild the
	inventory at all - which is what went wrong last time: a fresh read that came back
	with a smaller set of items than the cache replaced the good one and everything
	vanished. Nothing is replaced here, so there is nothing to lose.

	An item whose Instance has left the folder has been used up, and is reported gone.
]]
local function liveAmount(item)
	local tool = item.tool
	if typeof(tool) ~= 'Instance' then
		return tonumber(item.amount) or 1
	end
	if not tool.Parent then return nil end

	return tonumber(tool:GetAttribute('Amount')) or tonumber(item.amount) or 1
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
local function refreshAdornee(billboard, plr)
	if not (billboard and billboard.Parent and plr) then return end
	local frame = billboard:FindFirstChild('Frame')
	if not frame then return end

	--[[
		Both the cache and a fresh read, and never one instead of the other.

		The cache is written once when a player is first seen and then only rebuilt when
		they swap their held item or change armor, so anything they picked up after you
		injected - a TNT bought mid game - was never in it. A fresh read has those, but
		replacing the cache with one is what blanked the display before now: a read that
		comes back short overwrites everything that was there.

		Counting from both and letting neither remove the other is the way to have it
		both ways. The two overlap heavily, so the same stack has to be recognised across
		them - see the folder Instance check below.
	]]
	local cached = store.inventories[plr]
	local fresh = bedwars.getInventory and bedwars.getInventory(plr)
	if not (cached or fresh) then
		billboard.Enabled = false
		return
	end

	local totals, rank, order, seen = {}, {}, {}, {}

	local function count(item)
		if type(item) ~= 'table' or not item.itemType then return end

		-- Keyed on the folder Instance, because the cache and the fresh read describe the
		-- same stacks and counting one twice would double every number on screen.
		local tool = item.tool
		if typeof(tool) == 'Instance' then
			if seen[tool] then return end
			seen[tool] = true
		end

		local at = listed(item.itemType)
		if not at then return end

		local have = liveAmount(item)
		if not have then return end

		if not totals[item.itemType] then
			totals[item.itemType] = 0
			rank[item.itemType] = at
			table.insert(order, item.itemType)
		end
		totals[item.itemType] += have
	end

	-- Built up rather than written as a literal: either one can be missing, and a nil
	-- sitting in the first slot of a table stops the loop before it starts.
	local sources = {}
	if cached then table.insert(sources, cached) end
	if fresh then table.insert(sources, fresh) end

	for _, inventory in sources do
		if type(inventory.items) == 'table' then
			for _, item in inventory.items do
				count(item)
			end
		end

		-- Their hand is normally part of the list above already. One that carries a folder
		-- Instance is caught by the check inside count; one that does not has to be kept
		-- off a type that has already been counted, or it would be added twice.
		local hand = inventory.hand
		if type(hand) == 'table' and hand.itemType
			and (typeof(hand.tool) == 'Instance' or not totals[hand.itemType]) then
			count(hand)
		end
	end

	table.sort(order, function(a, b)
		if rank[a] == rank[b] then return a < b end
		return rank[a] < rank[b]
	end)

	-- Cleared only once there is something to put back. Doing it first meant anything
	-- that went wrong while working out the contents - and something did - left every
	-- icon destroyed and nothing drawn, which is why the display kept going blank
	-- instead of simply not updating.
	for _, obj in frame:GetChildren() do
		if obj:IsA('ImageLabel') and obj.Name ~= 'Blur' then
			obj:Destroy()
		end
	end

	local any = false
	for _, itemType in order do
		addIcon(frame, itemType, totals[itemType])
		any = true
	end

	billboard.Enabled = any
end

local function refreshAll()
	for ent, entry in Entries do
		if entry.Billboard.Parent and entry.Player and entry.Player.Parent then
			-- Guarded per player. A throw part way through used to abandon the whole pass,
			-- so everybody after the one that failed went unrefreshed too.
			pcall(refreshAdornee, entry.Billboard, entry.Player)
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
AllItems = InventoryESP:CreateToggle({
	Name = 'All Items',
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
