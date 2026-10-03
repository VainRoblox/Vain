--[[
	Crop Tracker.

	Every Cletus crop is a placed block named by its type - pumpkin, carrot or melon
	(crop-meta) - carrying PlacedByUserId, so whose team it belongs to is
	that player's team. Crops ready to pick carry the HarvestableCrop tag. A card lists
	each team with how many of every crop it has growing and how many are ready; a type a
	team has none of is faded out or hidden.

	The blocks are read from the local block store every couple of seconds - nothing is
	asked of the server.
]]
local CropTracker
local FadeEmpty, HideMode, HideEmptyTeams, ShowReady, Scale, Background
local card, list, header, scaler
local rows = {}
local counts = {}
local lastScan = 0

local CROPS = {'carrot', 'melon', 'pumpkin'}
local ROW_HEIGHT = 20

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function guiOpen()
	local ok, open = pcall(function() return vain.gui.ScaledGui.ClickGui.Visible end)
	return ok and open == true
end

local function teamOfUser(userId)
	local player = playersService:GetPlayerByUserId(tonumber(userId) or 0)
	if not player then return nil end
	local team = player:GetAttribute('Team')
	return team ~= nil and tostring(team) or nil, player
end

-- Crops per team, by type, and how many of each are ready.
local function scan()
	if os.clock() - lastScan < 2 then return end
	lastScan = os.clock()
	table.clear(counts)
	local isCrop = {}
	for _, crop in CROPS do isCrop[crop] = true end
	local ready = {}
	for _, block in collectionService:GetTagged('HarvestableCrop') do ready[block] = true end

	local ok = pcall(function()
		local store = bedwars.BlockController:getStore()
		for _, position in store:getAllBlockPositions() do
			local block = store:getBlockAt(position)
			if block and isCrop[block.Name] then
				local team, player = teamOfUser(block:GetAttribute('PlacedByUserId'))
				if team then
					local entry = counts[team]
					if not entry then
						entry = {player = player, crops = {}, ready = {}}
						counts[team] = entry
					end
					entry.crops[block.Name] = (entry.crops[block.Name] or 0) + 1
					if ready[block] then entry.ready[block.Name] = (entry.ready[block.Name] or 0) + 1 end
				end
			end
		end
	end)
	if not ok then table.clear(counts) end
end

local function row(index)
	local entry = rows[index]
	if entry then return entry end
	local frame = Instance.new('Frame')
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	frame.LayoutOrder = index
	frame.Parent = list
	local layout = Instance.new('UIListLayout')
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame

	local name = Instance.new('TextLabel')
	name.BackgroundTransparency = 1
	name.Size = UDim2.fromOffset(52, ROW_HEIGHT)
	name.Font = Enum.Font.GothamBold
	name.TextSize = 12
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.LayoutOrder = 0
	name.Parent = frame

	local cells = {}
	for i, crop in CROPS do
		local cell = Instance.new('Frame')
		cell.BackgroundTransparency = 1
		cell.AutomaticSize = Enum.AutomaticSize.X
		cell.Size = UDim2.fromOffset(0, ROW_HEIGHT)
		cell.LayoutOrder = i
		cell.Parent = frame
		local cellLayout = Instance.new('UIListLayout')
		cellLayout.FillDirection = Enum.FillDirection.Horizontal
		cellLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		cellLayout.Padding = UDim.new(0, 2)
		cellLayout.SortOrder = Enum.SortOrder.LayoutOrder
		cellLayout.Parent = cell
		local icon = Instance.new('ImageLabel')
		icon.BackgroundTransparency = 1
		icon.Size = UDim2.fromOffset(16, 16)
		icon.ScaleType = Enum.ScaleType.Fit
		local meta = bedwars.ItemMeta[crop]
		icon.Image = meta and meta.image or ''
		icon.LayoutOrder = 1
		icon.Parent = cell
		local count = Instance.new('TextLabel')
		count.BackgroundTransparency = 1
		count.AutomaticSize = Enum.AutomaticSize.X
		count.Size = UDim2.fromOffset(0, ROW_HEIGHT)
		count.Font = Enum.Font.GothamBold
		count.TextSize = 12
		count.RichText = true
		count.TextColor3 = Color3.new(1, 1, 1)
		count.LayoutOrder = 2
		count.Parent = cell
		cells[crop] = {cell = cell, icon = icon, count = count}
	end
	entry = {frame = frame, name = name, cells = cells}
	rows[index] = entry
	return entry
end

local function render(entry, teamName, color, data)
	entry.name.Text = teamName
	entry.name.TextColor3 = color
	for _, crop in CROPS do
		local cell = entry.cells[crop]
		local amount = data.crops[crop] or 0
		local readyCount = data.ready[crop] or 0
		local empty = amount == 0
		-- None of this type: faded out, or hidden entirely with Hide Instead.
		cell.cell.Visible = not (empty and on(FadeEmpty) and on(HideMode))
		cell.icon.ImageTransparency = empty and on(FadeEmpty) and 0.75 or 0
		cell.count.TextTransparency = empty and on(FadeEmpty) and 0.75 or 0
		cell.count.Text = tostring(amount) .. ((on(ShowReady) and readyCount > 0) and string.format(' <font color="#7CFF7C">(%d)</font>', readyCount) or '')
	end
	entry.frame.Visible = true
end

local function update()
	scan()
	local teams = {}
	for team, data in counts do
		local total = 0
		for _, amount in data.crops do total += amount end
		if total > 0 or not on(HideEmptyTeams) then
			teams[#teams + 1] = {team = team, data = data, total = total}
		end
	end
	table.sort(teams, function(a, b) return a.total > b.total end)

	local preview = #teams == 0 and guiOpen()
	if preview then
		teams = {{team = 'preview', data = {crops = {carrot = 4, melon = 2}, ready = {carrot = 1}}, total = 6, preview = true}}
	end

	for i, item in teams do
		local player = item.data.player
		local name = item.preview and 'Preview' or (player and player.Team and player.Team.Name or ('Team ' .. item.team))
		local color = item.preview and Color3.fromRGB(200, 200, 200) or (player and player.Team and player.TeamColor.Color or Color3.new(1, 1, 1))
		render(row(i), name, color, item.data)
	end
	for i = #teams + 1, #rows do rows[i].frame.Visible = false end
	card.Visible = #teams > 0
	card.Size = UDim2.fromOffset(250, 24 + #teams * ROW_HEIGHT)
	scaler.Scale = Scale.Value
end

CropTracker = vain.Legit:CreateModule({
	Name = 'Crop Tracker',
	Function = function(callback)
		if callback then
			lastScan = 0
			local last = 0
			CropTracker:Clean(runService.Heartbeat:Connect(function()
				if os.clock() - last < 0.5 then return end
				last = os.clock()
				if not pcall(update) then card.Visible = false end
			end))
		else
			card.Visible = false
		end
	end,
	Size = UDim2.fromOffset(250, 60),
	Tooltip = 'How many crops each team is growing'
})
FadeEmpty = CropTracker:CreateToggle({
	Name = 'Fade Empty',
	Tooltip = 'Fades out crop types a team has none of',
	Default = true,
	Function = function(callback)
		if HideMode and HideMode.Object then HideMode.Object.Visible = callback end
	end
})
HideMode = CropTracker:CreateToggle({
	Name = 'Hide Instead',
	Tooltip = 'Hides empty crop types instead of fading them',
	Darker = true
})
HideEmptyTeams = CropTracker:CreateToggle({
	Name = 'Hide Empty Teams',
	Tooltip = 'Leaves out teams growing nothing',
	Default = true
})
ShowReady = CropTracker:CreateToggle({
	Name = 'Ready Count',
	Tooltip = 'Shows how many are ready to pick, in green',
	Default = true
})
Scale = CropTracker:CreateSlider({
	Name = 'Scale',
	Tooltip = 'How big the card is',
	Min = 0.5,
	Max = 1.5,
	Default = 1,
	Decimal = 100
})
Background = CropTracker:CreateColorSlider({
	Name = 'Background',
	Tooltip = 'Colour of the card',
	DefaultValue = 0.08,
	DefaultOpacity = 0.6,
	Function = function(hue, sat, val, opacity)
		if card then
			card.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			card.BackgroundTransparency = 1 - opacity
		end
	end
})

card = Instance.new('Frame')
card.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
card.BackgroundTransparency = 0.4
card.BorderSizePixel = 0
card.Visible = false
card.Parent = CropTracker.Children
Instance.new('UICorner', card).CornerRadius = UDim.new(0, 8)
local stroke = Instance.new('UIStroke')
stroke.Color = Color3.new(1, 1, 1)
stroke.Transparency = 0.9
stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
stroke.Parent = card
local padding = Instance.new('UIPadding')
padding.PaddingLeft = UDim.new(0, 8)
padding.PaddingRight = UDim.new(0, 8)
padding.PaddingTop = UDim.new(0, 4)
padding.Parent = card
scaler = Instance.new('UIScale')
scaler.Parent = card
header = Instance.new('TextLabel')
header.BackgroundTransparency = 1
header.Size = UDim2.new(1, 0, 0, 16)
header.Font = Enum.Font.GothamBold
header.TextSize = 10
header.TextColor3 = Color3.fromRGB(150, 150, 150)
header.TextXAlignment = Enum.TextXAlignment.Left
header.Text = 'CROPS'
header.Parent = card
list = Instance.new('Frame')
list.BackgroundTransparency = 1
list.Position = UDim2.fromOffset(0, 18)
list.Size = UDim2.new(1, 0, 1, -18)
list.Parent = card
local layout = Instance.new('UIListLayout')
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = list
