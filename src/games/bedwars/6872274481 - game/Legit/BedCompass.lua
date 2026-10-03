--[[
	Bed Compass.

	Every bed is a model tagged bed; your team's carries the Team<id>NoBreak attribute, and
	the blanket is coloured in its team's colour, which is how the others are told apart.
	Beds are remembered once seen, so a broken one - the model is removed - can still be
	shown, greyed out.

	Shown either as a small panel listing the beds with an arrow pointing to each relative
	to where you are looking, or as arrows on a ring around the crosshair.
]]
local BedCompass
local Style, RingRadius, ShowOwn, HideOwnClose, EnemyMode, ShowDistance, ShowBroken, Scale, FontOption, Background
local holder, list, ring
local rows, ringArrows = {}, {}
local known = {}

local OWN_CLOSE = 20

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function blanketOf(bed)
	local part = bed:FindFirstChild('Blanket') or bed:FindFirstChild('Covers')
	return part and part:IsA('BasePart') and part or nil
end

-- Yours when it carries your team's NoBreak attribute, or its blanket is your team's
-- colour - the attribute is not always there.
local function isOwn(bed, team)
	local id = lplr:GetAttribute('Team')
	if id ~= nil and bed:GetAttribute('Team' .. tostring(id) .. 'NoBreak') ~= nil then return true end
	if not team then return false end
	if team.id ~= nil and id ~= nil then return tostring(team.id) == tostring(id) end
	-- The game's own bed code matches its teams to players by name.
	if lplr.Team and team.name == lplr.Team.Name then return true end
	return team.team ~= nil and team.team == lplr.Team
end

--[[
	The team whose colour is nearest the blanket's, from the game's own team list
	(Game.teams in its store, each with an id, name and colour) - the Roblox Teams are often
	empty in BedWars. Falls back to the Roblox Teams if the store has none.
]]
local function teamList()
	local list = {}
	local ok, teams = pcall(function() return bedwars.Store:getState().Game.teams end)
	for _, team in (ok and type(teams) == 'table' and teams or {}) do
		if typeof(team.color) == 'Color3' then
			list[#list + 1] = {id = team.id, name = team.name, color = team.color}
		end
	end
	if #list == 0 then
		for _, team in game:GetService('Teams'):GetTeams() do
			list[#list + 1] = {name = team.Name, color = team.TeamColor.Color, team = team}
		end
	end
	return list
end

local function teamOf(bed)
	local blanket = blanketOf(bed)
	if not blanket then return nil end
	local best, bestDiff
	for _, team in teamList() do
		local c, b = team.color, blanket.Color
		local diff = math.abs(c.R - b.R) + math.abs(c.G - b.G) + math.abs(c.B - b.B)
		if not bestDiff or diff < bestDiff then
			best, bestDiff = team, diff
		end
	end
	return best
end

--[[
	Every bed seen this match, kept after it is broken. Whose it is gets worked out again
	each time rather than once, as teams are often not handed out yet when the beds first
	appear - which left your own bed counted as an enemy's, and pointed at as the nearest.
]]
local lastRemember = 0
local function remember()
	if os.clock() - lastRemember < 0.5 then return end
	lastRemember = os.clock()
	for _, bed in collectionService:GetTagged('bed') do
		if bed:IsA('PVInstance') then
			local team = teamOf(bed)
			local info = known[bed] or {}
			info.position = bed:GetPivot().Position
			info.own = isOwn(bed, team)
			info.name = team and team.name or 'Enemy'
			info.color = team and team.color or Color3.new(1, 1, 1)
			known[bed] = info
		end
	end
	for bed, info in known do
		info.broken = bed.Parent == nil
	end
end

local function row(index)
	local entry = rows[index]
	if entry then return entry end

	local frame = Instance.new('Frame')
	frame.BackgroundTransparency = 1
	frame.LayoutOrder = index
	frame.Parent = list

	local arrow = Instance.new('ImageLabel')
	arrow.BackgroundTransparency = 1
	arrow.AnchorPoint = Vector2.new(0.5, 0.5)
	arrow.Image = getcustomasset('vain/assets/new/expandup.png')
	arrow.ScaleType = Enum.ScaleType.Fit
	arrow.Parent = frame

	local label = Instance.new('TextLabel')
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextStrokeTransparency = 0.5
	label.Parent = frame

	entry = {frame = frame, arrow = arrow, label = label}
	rows[index] = entry
	return entry
end

local function ringArrow(index)
	local entry = ringArrows[index]
	if entry then return entry end
	local arrow = Instance.new('ImageLabel')
	arrow.BackgroundTransparency = 1
	arrow.AnchorPoint = Vector2.new(0.5, 0.5)
	arrow.Image = getcustomasset('vain/assets/new/expandup.png')
	arrow.ScaleType = Enum.ScaleType.Fit
	arrow.Parent = ring
	local label = Instance.new('TextLabel')
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Font = Enum.Font.GothamBold
	label.TextStrokeTransparency = 0.4
	label.Parent = ring
	entry = {arrow = arrow, label = label}
	ringArrows[index] = entry
	return entry
end

local function hideAll()
	for _, entry in rows do entry.frame.Visible = false end
	for _, entry in ringArrows do
		entry.arrow.Visible = false
		entry.label.Visible = false
	end
end

local function update()
	remember()
	if not entitylib.isAlive then
		hideAll()
		return
	end
	local here = entitylib.character.RootPart.Position
	local look = gameCamera.CFrame.LookVector
	local facing = math.atan2(look.X, -look.Z)

	local own, enemies, broken = nil, {}, {}
	for _, info in known do
		local item = {info = info, distance = (info.position - here).Magnitude}
		if info.own then
			if not info.broken then own = item end
		elseif info.broken then
			broken[#broken + 1] = item
		else
			enemies[#enemies + 1] = item
		end
	end
	table.sort(enemies, function(a, b) return a.distance < b.distance end)

	local shown = {}
	if own and on(ShowOwn) and not (on(HideOwnClose) and own.distance <= OWN_CLOSE) then
		shown[#shown + 1] = own
	end
	local limit = EnemyMode.Value == 'Nearest' and 1 or #enemies
	for i = 1, math.min(limit, #enemies) do shown[#shown + 1] = enemies[i] end
	if on(ShowBroken) then
		for _, item in broken do shown[#shown + 1] = item end
	end

	local scale = Scale.Value
	local size = math.floor(13 * scale)
	local font = FontOption and FontOption.Value or Font.fromEnum(Enum.Font.GothamBold)
	local isRing = Style.Value == 'Ring'
	holder.Visible = not isRing
	ring.Visible = isRing
	hideAll()

	for i, item in shown do
		local info = item.info
		local flat = info.position - here
		-- Arrow up means straight ahead of the camera.
		local bearing = math.atan2(flat.X, -flat.Z) - facing
		local color = info.broken and Color3.fromRGB(120, 120, 120) or (info.own and Color3.fromRGB(120, 230, 140) or info.color)
		local name = info.own and 'Your Bed' or (info.name .. ' Bed')
		local distanceText = on(ShowDistance) and string.format('%dm', math.floor(item.distance)) or ''

		if isRing then
			local entry = ringArrow(i)
			local radius = RingRadius.Value
			local offset = Vector2.new(math.sin(bearing), -math.cos(bearing)) * radius
			entry.arrow.Position = UDim2.new(0.5, offset.X, 0.5, offset.Y)
			entry.arrow.Size = UDim2.fromOffset(size + 4, size + 4)
			entry.arrow.Rotation = math.deg(bearing)
			entry.arrow.ImageColor3 = color
			entry.arrow.Visible = true
			local labelOffset = Vector2.new(math.sin(bearing), -math.cos(bearing)) * (radius + size + 8)
			entry.label.Position = UDim2.new(0.5, labelOffset.X, 0.5, labelOffset.Y)
			entry.label.Size = UDim2.fromOffset(60, size)
			entry.label.TextSize = size - 2
			entry.label.FontFace = font
			entry.label.TextColor3 = color
			entry.label.Text = distanceText
			entry.label.Visible = distanceText ~= ''
		else
			local entry = row(i)
			local height = size + 9
			entry.frame.Size = UDim2.new(1, 0, 0, height)
			entry.arrow.Position = UDim2.fromOffset(height / 2 + 2, height / 2)
			entry.arrow.Size = UDim2.fromOffset(size + 1, size + 1)
			entry.arrow.Rotation = math.deg(bearing)
			entry.arrow.ImageColor3 = color
			entry.label.Position = UDim2.fromOffset(height + 4, 0)
			entry.label.Size = UDim2.new(1, -height - 8, 1, 0)
			entry.label.TextSize = size
			entry.label.FontFace = font
			entry.label.TextColor3 = color
			entry.label.Text = name .. (info.broken and '  (broken)' or '') .. (distanceText ~= '' and '  ' .. distanceText or '')
			entry.frame.Visible = true
		end
	end
	holder.Size = UDim2.new(1, 0, 0, math.max(#shown, 1) * (size + 9) + 8)
end

BedCompass = vain.Legit:CreateModule({
	Name = 'Bed Compass',
	Function = function(callback)
		if callback then
			BedCompass:Clean(runService.RenderStepped:Connect(function()
				pcall(update)
			end))
		else
			hideAll()
			ring.Visible = false
		end
	end,
	Size = UDim2.fromOffset(170, 80),
	Tooltip = 'Points to your bed and the enemy beds'
})
Style = BedCompass:CreateDropdown({
	Name = 'Style',
	List = {'List', 'Ring'},
	Tooltips = {List = 'A panel listing the beds', Ring = 'Arrows on a ring round the crosshair'},
	Function = function(val)
		if RingRadius and RingRadius.Object then RingRadius.Object.Visible = val == 'Ring' end
	end
})
RingRadius = BedCompass:CreateSlider({
	Name = 'Ring Radius',
	Tooltip = 'How far from the crosshair the arrows sit',
	Min = 40,
	Max = 300,
	Default = 90,
	Darker = true,
	Visible = false,
	Suffix = function() return 'px' end
})
ShowOwn = BedCompass:CreateToggle({
	Name = 'Own Bed',
	Tooltip = 'Also points to your own bed',
	Default = true,
	Function = function(callback)
		if HideOwnClose and HideOwnClose.Object then HideOwnClose.Object.Visible = callback end
	end
})
HideOwnClose = BedCompass:CreateToggle({
	Name = 'Hide Own When Close',
	Tooltip = 'Hides your bed while you are next to it',
	Darker = true
})
EnemyMode = BedCompass:CreateDropdown({
	Name = 'Enemy Beds',
	List = {'Nearest', 'All'},
	Tooltips = {Nearest = 'Only the nearest enemy bed', All = 'Every enemy bed still standing'}
})
ShowBroken = BedCompass:CreateToggle({
	Name = 'Broken Beds',
	Tooltip = 'Also shows broken beds, greyed out'
})
ShowDistance = BedCompass:CreateToggle({
	Name = 'Distance',
	Tooltip = 'Shows how far away each bed is',
	Default = true
})
Scale = BedCompass:CreateSlider({
	Name = 'Scale',
	Tooltip = 'How big it is',
	Min = 0.6,
	Max = 2,
	Default = 1,
	Decimal = 10
})
FontOption = BedCompass:CreateFont({
	Name = 'Font',
	Tooltip = 'Font used for the text',
	Blacklist = 'GothamBold'
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

-- The ring sits on the screen itself, centred on the crosshair.
ring = Instance.new('Frame')
ring.Name = 'BedCompassRing'
ring.BackgroundTransparency = 1
ring.AnchorPoint = Vector2.new(0.5, 0.5)
ring.Position = UDim2.fromScale(0.5, 0.5)
ring.Size = UDim2.fromOffset(0, 0)
ring.Visible = false
ring.Parent = vain.gui
