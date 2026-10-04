local StorageESP
local List
local Background
local Color = {}
local ShowAmount
local ShowAll
local ShowOwn
local Alerts
local Reference = {}
-- chest -> {itemType = true} for what it has already been called out for, so each item is
-- said once when a chest reaches it and again only after it has dropped back below.
local alerted = {}
local Folder = Instance.new('Folder')
Folder.Parent = vain.gui

-- Settings are created after CreateModule returns, so they can still be nil while
-- this file is executing - and the module can be switched on inside that window
-- when the GUI restores a saved config. Reading .Enabled straight off them threw.
local function on(setting)
	return setting ~= nil and setting.Enabled
end

--[[
	Your own team's crate, found the way ChestSteal and the game's own getTeamCrate find it.

	The Team attribute sits on a holder with the block underneath it, so it is looked for up
	a few parents rather than only on the tagged instance, and compared as text because the
	id comes back as a string in some places and a number in others.
]]
local function teamOf(inst)
	local team = inst:GetAttribute('Team')
	if team == nil then team = inst:GetAttribute('GeneratorTeam') end
	return team ~= nil and tostring(team) or nil
end

local function ownTeamChest(block)
	local mine = lplr:GetAttribute('Team')
	if mine == nil or not block then return false end
	mine = tostring(mine)

	-- The game's own answer first: the crate it opens as yours.
	local ok, crate = pcall(function() return bedwars.ChestItemDisplayController:getTeamCrate() end)
	if ok and crate ~= nil and crate == block then return true end

	local node = block
	for _ = 1, 3 do
		if not node then break end
		if teamOf(node) == mine then return true end
		node = node.Parent
	end
	return false
end

-- Hidden unless asked for: what is in your own crate is something you already know. Item
-- Alerts with Ignore Self off asks for it too, so your team's chest is watched as well.
local function hiddenAsOwn(block)
	if on(ShowOwn) or (Alerts and Alerts.includeSelf()) then return false end
	return ownTeamChest(block)
end

local refreshAdornee

local function nearStorageItem(item)
	for _, v in List.ListEnabled do
		if item:find(v) then return v end
	end
end

local function where(inst)
	if inst:IsA('BasePart') then return inst.Position end
	if inst:IsA('Model') then
		local ok, pivot = pcall(inst.GetPivot, inst)
		if ok then return pivot.Position end
	end
	local part = inst:FindFirstChildWhichIsA('BasePart', true)
	return part and part.Position or nil
end

-- The tint and outline a chest wears while it holds enough of a watched item, or its usual
-- look when it does not.
local function paint(v, active)
	local frame = v:FindFirstChild('Frame')
	if not frame then return end

	local stroke = frame:FindFirstChild('AlertStroke')
	if active and Alerts then
		local tint, opacity = Alerts.color()
		frame.BackgroundColor3 = tint
		frame.BackgroundTransparency = 1 - opacity
		if not stroke then
			stroke = Instance.new('UIStroke')
			stroke.Name = 'AlertStroke'
			stroke.Thickness = 2
			stroke.Parent = frame
		end
		stroke.Color = tint
		stroke.Enabled = true
	else
		frame.BackgroundColor3 = Color3.fromHSV(Color.Hue or 0, Color.Sat or 0, Color.Value or 0)
		frame.BackgroundTransparency = 1 - (on(Background) and (Color.Opacity or 0.5) or 0)
		if stroke then stroke.Enabled = false end
	end
end

--[[
	Billboards waiting to be redrawn, and the thread that redraws them.

	Nothing is drawn from a chest's own signals any more. Those fire on threads the engine
	owns, and on executors without setthreadidentity there is no way to raise one - which is
	what "cannot access Instance (lacking capability Plugin)" was, hundreds of times a
	match, from every chest anybody opened. The guards below still run where that function
	exists; this is what covers the hosts where it does not.

	What the signals do now is mark a billboard dirty. The drawing happens on a connection
	made in the module's own enable, from Vain's thread, so it inherits Vain's identity
	rather than the engine's.

	It also stops the spam at the source: taking ten items out of a chest fired ten full
	redraws a frame apart, and now coalesces into one.
]]
local dirty = {}

local function queue(v)
	dirty[v] = true
end

local function refreshAll()
	for _, v in Reference do
		queue(v)
	end
end

function refreshAdornee(v)
	-- Called from the chest's own ChildAdded and Amount signals, which run on game threads
	-- without the identity to touch Vain's UI ("cannot access Instance").
	if vain.ThreadFix then
		setthreadidentity(8)
	end
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
	local order, totals, all = {}, {}, {}
	local watches = Alerts and Alerts.watches() or {}
	for _, item in chestitems do
		--[[
			A child with no Amount is not an item.

			Every item the game builds is given one, defaulting to 1, so anything in the
			folder without it is the chest's own furniture rather than loot. Counting those
			as one apiece drew a phantom entry with a blank icon and a made-up count.
		]]
		local amount = item:GetAttribute('Amount')
		if type(amount) ~= 'number' then continue end
		all[item.Name] = (all[item.Name] or 0) + amount

		-- ShowAll displays all items regardless of the list; otherwise use the filter. A
		-- watched item is always shown, since it is what the alert is about.
		local shouldShow = on(ShowAll) or watches[item.Name] ~= nil or table.find(List.ListEnabled, item.Name) or nearStorageItem(item.Name)
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

	--[[
		Whether it holds enough of something watched.

		Counted over everything in the chest, not just what is drawn, and said once per
		item: a chest that keeps its emeralds is not news every time someone opens it. An
		item that drops back below is forgotten, so reaching it again is said again.
	]]
	local block = v.Adornee
	-- Ignore Self keeps your own team's chest out of the alerts even while Show Own draws
	-- it: it only ever decided whether the chest was drawn, so with Show Own on, your own
	-- stash was flagged and announced like an enemy's.
	local ignored = Alerts and not Alerts.includeSelf() and ownTeamChest(block)
	local found = (Alerts and Alerts.enabled() and not ignored) and Alerts.matches(all, watches) or {}
	if #found > 0 then v.Enabled = true end
	paint(v, #found > 0)

	if block then
		local before = alerted[block] or {}
		local now, fresh = {}, {}
		for _, hit in found do
			now[hit.itemType] = true
			if not before[hit.itemType] then fresh[#fresh + 1] = hit end
		end
		alerted[block] = now

		if #fresh > 0 and Alerts then
			local position = where(block)
			local distance = position and entitylib.isAlive
				and math.floor((position - entitylib.character.RootPart.Position).Magnitude) or nil
			-- Whose chest it is, in their colour, from the same Team attribute Show Own reads.
			local owner
			local node = block
			for _ = 1, 3 do
				if not node then break end
				owner = teamOf(node)
				if owner then break end
				node = node.Parent
			end
			local team = itemAlerts.teamName(owner)
			Alerts.notify('StorageESP', (team and (team .. "'s chest holds ") or 'A chest holds ')
				.. Alerts.describe(fresh) .. (distance and (' (' .. distance .. ' studs away)') or ''))
		end
	end
end

local function Added(v)
	if vain.ThreadFix then
		setthreadidentity(8)
	end
	local chest = v:WaitForChild('ChestFolderValue', 3)
	if not (chest and StorageESP.Enabled) then return end
	-- The wait can resume on a thread without it again.
	if vain.ThreadFix then
		setthreadidentity(8)
	end
	if hiddenAsOwn(v) then return end
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
			queue(billboard)
		end))
	end
	for _, item in chest:GetChildren() do
		watchAmount(item)
	end

	StorageESP:Clean(chest.ChildAdded:Connect(function(item)
		watchAmount(item)
		queue(billboard)
	end))
	StorageESP:Clean(chest.ChildRemoved:Connect(function()
		queue(billboard)
	end))
	queue(billboard)
end

StorageESP = vain.Categories.Render:CreateModule({
	Name = 'StorageESP',
	Function = function(callback)
		if callback then
			table.clear(dirty)
			-- Connected here rather than anywhere nested inside a game signal: a callback
			-- inherits the identity of the thread that made the connection, and this one is
			-- made on Vain's.
			StorageESP:Clean(runService.Heartbeat:Connect(function()
				if not next(dirty) then return end

				local todo = dirty
				dirty = {}
				for v in todo do
					-- A billboard destroyed between being marked and being drawn is not an
					-- error worth a stack trace in the console every time a chest breaks.
					if v.Parent then
						pcall(refreshAdornee, v)
					end
				end
			end))

			StorageESP:Clean(collectionService:GetInstanceAddedSignal('chest'):Connect(Added))
			for _, v in collectionService:GetTagged('chest') do
				task.spawn(Added, v)
			end
		else
			table.clear(Reference)
			table.clear(alerted)
			table.clear(dirty)
			Folder:ClearAllChildren()
		end
	end,
	Tooltip = 'Displays items in chests'
})
List = StorageESP:CreateTextList({
	Name = 'Item',
	Tooltip = 'Which items this applies to',
	Function = function()
		refreshAll()
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
		-- A chest that is flagged keeps its alert colour.
		refreshAll()
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
		refreshAll()
	end,
	Darker = true
})
ShowAmount = StorageESP:CreateToggle({
	Name = 'Show Amount',
	Tooltip = 'Displays the quantity of each item in the corner',
	Function = function()
		refreshAll()
	end
})
ShowAll = StorageESP:CreateToggle({
	Name = 'Show All',
	Tooltip = 'Shows all items instead of only those in the list',
	Function = function()
		refreshAll()
	end
})
ShowOwn = StorageESP:CreateToggle({
	Name = 'Show Own',
	Tooltip = "Also shows your own team's chest",
	Function = function()
		-- Which chests exist changes, not just what they show, so they are rebuilt.
		if StorageESP.Enabled then
			StorageESP:Toggle()
			StorageESP:Toggle()
		end
	end
})
Alerts = itemAlerts.create(StorageESP, {
	refresh = refreshAll,
	-- Ignore Self changes which chests are shown at all, so they are rebuilt.
	rebuild = function()
		if StorageESP.Enabled then
			StorageESP:Toggle()
			StorageESP:Toggle()
		end
	end,
	defaults = {'emerald x10', 'diamond x10'}
})
