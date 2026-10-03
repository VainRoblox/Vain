--[[
	Bed Compass.

	Every bed is a model tagged bed; your team's carries the Team<id>NoBreak attribute, and
	the blanket is coloured in its team's colour, which is how the others are told apart. A
	small panel lists your bed and the enemy beds still standing, each with an arrow
	pointing to it relative to where you are looking and how far away it is.
]]
local BedCompass
local ShowOwn, EnemyMode, ShowDistance, Background
local holder, list
local rows = {}

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function blanketOf(bed)
	local part = bed:FindFirstChild('Blanket') or bed:FindFirstChild('Covers')
	return part and part:IsA('BasePart') and part or nil
end

local function isOwn(bed)
	local team = lplr:GetAttribute('Team')
	return team ~= nil and bed:GetAttribute('Team' .. tostring(team) .. 'NoBreak') ~= nil
end

-- The team whose colour is nearest the blanket's.
local function teamOf(bed)
	local blanket = blanketOf(bed)
	if not blanket then return nil end
	local best, bestDiff
	for _, team in game:GetService('Teams'):GetTeams() do
		local c, b = team.TeamColor.Color, blanket.Color
		local diff = math.abs(c.R - b.R) + math.abs(c.G - b.G) + math.abs(c.B - b.B)
		if not bestDiff or diff < bestDiff then
			best, bestDiff = team, diff
		end
	end
	return best
end

local function row(index)
	local entry = rows[index]
	if entry then return entry end

	local frame = Instance.new('Frame')
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, 22)
	frame.LayoutOrder = index
	frame.Parent = list

	local arrow = Instance.new('ImageLabel')
	arrow.BackgroundTransparency = 1
	arrow.AnchorPoint = Vector2.new(0.5, 0.5)
	arrow.Position = UDim2.fromOffset(13, 11)
	arrow.Size = UDim2.fromOffset(14, 14)
	arrow.Image = getcustomasset('vain/assets/new/expandup.png')
	arrow.ScaleType = Enum.ScaleType.Fit
	arrow.Parent = frame

	local label = Instance.new('TextLabel')
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(26, 0)
	label.Size = UDim2.new(1, -30, 1, 0)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextStrokeTransparency = 0.5
	label.Parent = frame

	entry = {frame = frame, arrow = arrow, label = label}
	rows[index] = entry
	return entry
end

local function update()
	if not entitylib.isAlive then
		for _, entry in rows do entry.frame.Visible = false end
		return
	end
	local here = entitylib.character.RootPart.Position
	local look = gameCamera.CFrame.LookVector
	local facing = math.atan2(look.X, -look.Z)

	local own, enemies = nil, {}
	for _, bed in collectionService:GetTagged('bed') do
		if bed.Parent and bed:IsA('PVInstance') then
			local position = bed:GetPivot().Position
			local item = {bed = bed, position = position, distance = (position - here).Magnitude}
			if isOwn(bed) then
				own = item
			else
				enemies[#enemies + 1] = item
			end
		end
	end
	table.sort(enemies, function(a, b) return a.distance < b.distance end)

	local shown = {}
	if own and on(ShowOwn) then shown[#shown + 1] = own end
	local limit = EnemyMode.Value == 'Nearest' and 1 or #enemies
	for i = 1, math.min(limit, #enemies) do shown[#shown + 1] = enemies[i] end

	for i, item in shown do
		local entry = row(i)
		local team = teamOf(item.bed)
		local flat = item.position - here
		-- Arrow up means straight ahead of the camera.
		local bearing = math.atan2(flat.X, -flat.Z) - facing
		entry.arrow.Rotation = math.deg(bearing)
		local color = item == own and Color3.fromRGB(120, 230, 140) or (team and team.TeamColor.Color or Color3.new(1, 1, 1))
		entry.arrow.ImageColor3 = color
		entry.label.TextColor3 = color
		local name = item == own and 'Your Bed' or ((team and team.Name or 'Enemy') .. ' Bed')
		entry.label.Text = name .. (on(ShowDistance) and string.format('  %dm', math.floor(item.distance)) or '')
		entry.frame.Visible = true
	end
	for i = #shown + 1, #rows do rows[i].frame.Visible = false end
	holder.Size = UDim2.new(1, 0, 0, math.max(#shown, 1) * 22 + 8)
end

BedCompass = vain.Legit:CreateModule({
	Name = 'Bed Compass',
	Function = function(callback)
		if callback then
			BedCompass:Clean(runService.RenderStepped:Connect(function()
				pcall(update)
			end))
		end
	end,
	Size = UDim2.fromOffset(170, 80),
	Tooltip = 'Points to your bed and the enemy beds'
})
ShowOwn = BedCompass:CreateToggle({
	Name = 'Own Bed',
	Tooltip = 'Also points to your own bed',
	Default = true
})
EnemyMode = BedCompass:CreateDropdown({
	Name = 'Enemy Beds',
	List = {'Nearest', 'All'},
	Tooltips = {Nearest = 'Only the nearest enemy bed', All = 'Every enemy bed still standing'}
})
ShowDistance = BedCompass:CreateToggle({
	Name = 'Distance',
	Tooltip = 'Shows how far away each bed is',
	Default = true
})
Background = BedCompass:CreateColorSlider({
	Name = 'Background',
	Tooltip = 'Colour of the panel',
	DefaultValue = 0,
	DefaultOpacity = 0.5,
	Function = function(hue, sat, val, opacity)
		if holder then
			holder.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			holder.BackgroundTransparency = 1 - opacity
		end
	end
})

holder = Instance.new('Frame')
holder.BackgroundColor3 = Color3.new()
holder.BackgroundTransparency = 0.5
holder.BorderSizePixel = 0
holder.Size = UDim2.new(1, 0, 0, 30)
holder.Parent = BedCompass.Children
Instance.new('UICorner', holder).CornerRadius = UDim.new(0, 6)
local padding = Instance.new('UIPadding')
padding.PaddingTop = UDim.new(0, 4)
padding.PaddingBottom = UDim.new(0, 4)
padding.Parent = holder
list = Instance.new('Frame')
list.BackgroundTransparency = 1
list.Size = UDim2.fromScale(1, 1)
list.Parent = holder
local layout = Instance.new('UIListLayout')
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = list
