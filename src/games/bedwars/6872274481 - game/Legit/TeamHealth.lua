--[[
	Team Health.

	A card with a row per teammate: their avatar, name in the team colour and a health bar
	with the number (the Health and MaxHealth attributes, plus any shield), and if wanted
	their kit (PlayingAsKit), what they hold and wear (the inventories the game replicates,
	in store.inventories), their enchants (the shared enchants helper) and how far away
	they are. Sorted the way you pick; a preview of yourself shows while the GUI is open.
]]
local TeamHealth
local ShowSelf, ShowKit, ShowEquipment, ShowEnchants, ShowDistance, SortMode, Scale, Background
local card, list, header, scaler
local rows = {}

local ROW_HEIGHT = 26
local WIDTH = 210

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function guiOpen()
	local ok, open = pcall(function() return vain.gui.ScaledGui.ClickGui.Visible end)
	return ok and open == true
end

local function teammates()
	local mine = lplr:GetAttribute('Team')
	local list = {}
	for _, player in playersService:GetPlayers() do
		local character = player.Character
		local sameTeam = mine ~= nil and tostring(player:GetAttribute('Team')) == tostring(mine)
		if character and sameTeam and (player ~= lplr or on(ShowSelf)) then
			local health = character:GetAttribute('Health')
			if type(health) == 'number' and health > 0 then
				list[#list + 1] = player
			end
		end
	end
	return list
end

local function icon(parent, order, size)
	local image = Instance.new('ImageLabel')
	image.BackgroundTransparency = 1
	image.Size = UDim2.fromOffset(size, size)
	image.ScaleType = Enum.ScaleType.Fit
	image.LayoutOrder = order
	image.Visible = false
	image.Parent = parent
	return image
end

local function row(index)
	local entry = rows[index]
	if entry then return entry end
	local frame = Instance.new('Frame')
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	frame.LayoutOrder = index
	frame.Parent = list

	local avatar = Instance.new('ImageLabel')
	avatar.Size = UDim2.fromOffset(20, 20)
	avatar.Position = UDim2.fromOffset(0, 1)
	avatar.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	avatar.BorderSizePixel = 0
	avatar.Parent = frame
	Instance.new('UICorner', avatar).CornerRadius = UDim.new(1, 0)

	local name = Instance.new('TextLabel')
	name.BackgroundTransparency = 1
	name.Position = UDim2.fromOffset(26, 0)
	name.Size = UDim2.new(1, -80, 0, 14)
	name.Font = Enum.Font.GothamBold
	name.TextSize = 12
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Parent = frame

	local value = Instance.new('TextLabel')
	value.BackgroundTransparency = 1
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.new(1, 0, 0, 0)
	value.Size = UDim2.fromOffset(52, 14)
	value.Font = Enum.Font.GothamBold
	value.TextSize = 12
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.Parent = frame

	local track = Instance.new('Frame')
	track.Position = UDim2.fromOffset(26, 16)
	track.Size = UDim2.new(1, -26, 0, 3)
	track.BackgroundColor3 = Color3.new(1, 1, 1)
	track.BackgroundTransparency = 0.85
	track.BorderSizePixel = 0
	track.Parent = frame
	Instance.new('UICorner', track).CornerRadius = UDim.new(1, 0)
	local fill = Instance.new('Frame')
	fill.BorderSizePixel = 0
	fill.Parent = track
	Instance.new('UICorner', fill).CornerRadius = UDim.new(1, 0)

	-- Kit, held item, armour and enchants in a strip under the name.
	local strip = Instance.new('Frame')
	strip.BackgroundTransparency = 1
	strip.Position = UDim2.fromOffset(26, 20)
	strip.Size = UDim2.new(1, -26, 0, 14)
	strip.Parent = frame
	local layout = Instance.new('UIListLayout')
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 2)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = strip
	local icons = {}
	for i = 1, 9 do icons[i] = icon(strip, i, 14) end

	entry = {frame = frame, avatar = avatar, name = name, value = value, fill = fill, strip = strip, icons = icons}
	rows[index] = entry
	return entry
end

local function setIcon(entry, index, image)
	local slot = entry.icons[index]
	slot.Image = image or ''
	slot.Visible = image ~= nil and image ~= ''
end

local function render(player, entry, here)
	local character = player.Character
	local health = (character:GetAttribute('Health') or 0) + getShieldAttribute(character)
	local maxHealth = math.max(character:GetAttribute('MaxHealth') or 100, 1)
	local fraction = math.clamp(health / maxHealth, 0, 1)
	local color = player.Team and player.TeamColor.Color or Color3.fromRGB(230, 230, 230)

	entry.avatar.Image = 'rbxthumb://type=AvatarHeadShot&id=' .. player.UserId .. '&w=48&h=48'
	entry.name.Text = player.DisplayName
	entry.name.TextColor3 = color
	local root = character:FindFirstChild('HumanoidRootPart')
	local distance = (here and root) and (root.Position - here).Magnitude or nil
	entry.value.Text = math.ceil(health) .. (on(ShowDistance) and distance and player ~= lplr and string.format('  %dm', math.floor(distance)) or '')
	entry.value.TextColor3 = Color3.fromHSV(fraction / 3, 0.8, 0.95)
	entry.fill.Size = UDim2.fromScale(fraction, 1)
	entry.fill.BackgroundColor3 = Color3.fromHSV(fraction / 3, 0.8, 0.95)

	local kit = player:GetAttribute('PlayingAsKit')
	local kitMeta = kit and kit ~= 'none' and bedwars.BedwarsKitMeta[kit]
	setIcon(entry, 1, on(ShowKit) and kitMeta and kitMeta.renderImage or nil)
	local inventory = on(ShowEquipment) and store.inventories[player]
	setIcon(entry, 2, inventory and inventory.hand and bedwars.getIcon(inventory.hand, true) or nil)
	for i, slot in {4, 5, 6} do
		local piece = inventory and inventory.armor and inventory.armor[slot]
		setIcon(entry, 2 + i, piece and bedwars.getIcon(piece, true) or nil)
	end
	local list = on(ShowEnchants) and enchants.of(character) or {}
	for i = 6, 9 do
		local enchant = list[i - 5]
		setIcon(entry, i, enchant and enchant.image or nil)
	end
	local anyIcon = false
	for _, slot in entry.icons do anyIcon = anyIcon or slot.Visible end
	entry.strip.Visible = anyIcon
	entry.frame.Size = UDim2.new(1, 0, 0, anyIcon and 36 or 22)
	entry.frame.Visible = true
	return anyIcon and 36 or 22
end

local function update()
	local here = entitylib.isAlive and entitylib.character.RootPart.Position
	local players = teammates()
	local preview = #players == 0 and guiOpen() and lplr.Character ~= nil
	if preview then players = {lplr} end

	local function healthOf(player)
		local character = player.Character
		return character and (character:GetAttribute('Health') or 0) or 0
	end
	local function distanceOf(player)
		local root = player.Character and player.Character:FindFirstChild('HumanoidRootPart')
		return (here and root) and (root.Position - here).Magnitude or math.huge
	end
	table.sort(players, function(a, b)
		if SortMode.Value == 'Health' then return healthOf(a) < healthOf(b) end
		if SortMode.Value == 'Distance' then return distanceOf(a) < distanceOf(b) end
		return a.DisplayName:lower() < b.DisplayName:lower()
	end)

	local height = 22
	for i, player in players do
		height += render(player, row(i), here)
	end
	for i = #players + 1, #rows do rows[i].frame.Visible = false end
	header.Text = preview and 'TEAM  ·  PREVIEW' or 'TEAM'
	card.Visible = #players > 0
	card.Size = UDim2.fromOffset(WIDTH, height + 6)
	scaler.Scale = Scale.Value
end

TeamHealth = vain.Legit:CreateModule({
	Name = 'Team Health',
	Function = function(callback)
		if callback then
			local last = 0
			TeamHealth:Clean(runService.Heartbeat:Connect(function()
				if os.clock() - last < 0.15 then return end
				last = os.clock()
				if not pcall(update) then card.Visible = false end
			end))
		else
			card.Visible = false
		end
	end,
	Size = UDim2.fromOffset(210, 80),
	Tooltip = 'Your teammates\' health at a glance'
})
SortMode = TeamHealth:CreateDropdown({
	Name = 'Sort',
	List = {'Health', 'Distance', 'Name'},
	Tooltips = {Health = 'Lowest health first', Distance = 'Nearest first', Name = 'By name'}
})
ShowSelf = TeamHealth:CreateToggle({Name = 'Include Self', Tooltip = 'Also lists you'})
ShowKit = TeamHealth:CreateToggle({Name = 'Kit', Tooltip = 'Shows their kit', Default = true})
ShowEquipment = TeamHealth:CreateToggle({Name = 'Equipment', Tooltip = 'Shows their held item and armour', Default = true})
ShowEnchants = TeamHealth:CreateToggle({Name = 'Enchants', Tooltip = 'Shows their enchants\' icons'})
ShowDistance = TeamHealth:CreateToggle({Name = 'Distance', Tooltip = 'Shows how far away they are', Default = true})
Scale = TeamHealth:CreateSlider({
	Name = 'Scale',
	Tooltip = 'How big the card is',
	Min = 0.5,
	Max = 1.5,
	Default = 0.9,
	Decimal = 100
})
Background = TeamHealth:CreateColorSlider({
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
card.Size = UDim2.fromOffset(WIDTH, 80)
card.Parent = TeamHealth.Children
Instance.new('UICorner', card).CornerRadius = UDim.new(0, 8)
local stroke = Instance.new('UIStroke')
stroke.Color = Color3.new(1, 1, 1)
stroke.Transparency = 0.9
stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
stroke.Parent = card
local padding = Instance.new('UIPadding')
padding.PaddingLeft = UDim.new(0, 8)
padding.PaddingRight = UDim.new(0, 8)
padding.PaddingTop = UDim.new(0, 5)
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
header.Text = 'TEAM'
header.Parent = card
list = Instance.new('Frame')
list.BackgroundTransparency = 1
list.Position = UDim2.fromOffset(0, 18)
list.Size = UDim2.new(1, 0, 1, -18)
list.Parent = card
local layout = Instance.new('UIListLayout')
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 2)
layout.Parent = list
