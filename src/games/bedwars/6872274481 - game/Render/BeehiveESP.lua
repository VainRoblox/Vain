--[[
	Beehive ESP.

	Reworked out of the Beekeeper kit, where the plate was a small patch of text that blended
	into a busy base. Every beehive on the map is a part tagged 'beehive' carrying a Level (the
	number of bees it holds), a PlacedByUserId, and a Team<N>NoBreak attribute naming the side
	it belongs to. This draws a clean card over each one - its count, whose it is and how far -
	in the owner team's colour, plus a filled outline on the block itself so it reads across the
	map, through walls.
]]
local BeehiveESP
local ThroughWalls, FillOpacity, ShowCount, ShowOwner, ShowDistance, ShowOwn, ShowTeammates
local Icon, Background, BackgroundColor, Outline, FontOption, Range, Scale

local Folder = Instance.new('Folder')
Folder.Name = 'BeehiveESP'
Folder.Parent = vain.gui
local hives = {}
-- hive -> true, waiting for its card. A tag signal's thread cannot be given the capability to
-- make instances, so add() only queues and update() (on the RenderStepped loop, whose thread
-- can) builds it.
local pending = {}

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function iconOf(itemType)
	local meta = bedwars.ItemMeta[itemType]
	return meta and meta.image or ''
end

-- A hive is a part, not a model, but take either shape.
local function partOf(v)
	if v:IsA('BasePart') then return v end
	return v:FindFirstChildWhichIsA('BasePart', true)
end

local function ownHive(hive)
	return hive:GetAttribute('PlacedByUserId') == lplr.UserId
end

--[[
	The colour of the team a hive belongs to.

	Taken from the owner's own TeamColor, which is what the rest of Vain colours by, so a hive
	reads the same as the nametags over the players who own it. The block records its own side
	as a Team<N>NoBreak attribute - a hive cannot be broken by its own team - which stands in
	when whoever placed it has already left.
]]
local function hiveTeam(hive)
	local found
	for name in hive:GetAttributes() do
		local id = tonumber(name:match('^Team(%d+)NoBreak$'))
		if id and (not found or id < found) then found = id end
	end
	if found then return found end
	local placer = playersService:GetPlayerByUserId(hive:GetAttribute('PlacedByUserId') or 0)
	return placer and placer:GetAttribute('Team')
end

local function hiveColor(hive)
	local placer = playersService:GetPlayerByUserId(hive:GetAttribute('PlacedByUserId') or 0)
	if placer and tostring(placer.TeamColor) ~= 'White' then
		return placer.TeamColor.Color
	end
	local team = hiveTeam(hive)
	if team then
		for _, plr in playersService:GetPlayers() do
			if plr:GetAttribute('Team') == team and tostring(plr.TeamColor) ~= 'White' then
				return plr.TeamColor.Color
			end
		end
	end
	return Color3.new(1, 1, 1)
end

local function ownerName(hive)
	local placer = playersService:GetPlayerByUserId(hive:GetAttribute('PlacedByUserId') or 0)
	return placer and placer.Name or nil
end

-- Whether a hive should be drawn, by whose side it is on: your own behind Show Own, a
-- teammate's behind Show Teammates, and an enemy's (or one whose side cannot be worked out)
-- always, since that is what the ESP is for.
local function shouldShow(hive)
	if ownHive(hive) then return on(ShowOwn) end
	local team, mine = hiveTeam(hive), lplr:GetAttribute('Team')
	if team ~= nil and mine ~= nil and tostring(team) == tostring(mine) then
		return on(ShowTeammates)
	end
	return true
end

local function newText(parent, order, strokeless)
	local label = Instance.new('TextLabel')
	label.BackgroundTransparency = 1
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromScale(0, 1)
	label.TextStrokeTransparency = strokeless and 1 or 0.5
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.LayoutOrder = order
	label.Parent = parent
	return label
end

--[[
	The card, built once per hive: a filled through-wall highlight on the block, and a small
	rounded plate over it carrying an icon, the bee count, the owner and the distance. update()
	only sets what changes.
]]
local function create(hive)
	if hives[hive] then return end
	local part = partOf(hive)
	if not part then return end

	local highlight = Instance.new('Highlight')
	highlight.Name = 'BeehiveHighlight'
	highlight.Adornee = part
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillTransparency = 0.7
	highlight.OutlineTransparency = 0
	highlight.Enabled = false
	highlight.Parent = Folder

	local billboard = Instance.new('BillboardGui')
	billboard.Name = 'Beehive'
	billboard.Adornee = part
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Enabled = false
	billboard.Parent = Folder

	local card = Instance.new('Frame')
	card.Name = 'Card'
	card.AnchorPoint = Vector2.new(0.5, 1)
	card.Position = UDim2.fromScale(0.5, 1)
	card.AutomaticSize = Enum.AutomaticSize.XY
	card.Size = UDim2.fromOffset(0, 0)
	card.BackgroundColor3 = Color3.new(0, 0, 0)
	card.BorderSizePixel = 0
	card.Parent = billboard
	Instance.new('UICorner', card).CornerRadius = UDim.new(0, 6)

	local stroke = Instance.new('UIStroke')
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Thickness = 1.5
	stroke.Transparency = 0.1
	stroke.Parent = card

	local padding = Instance.new('UIPadding')
	padding.Parent = card

	local layout = Instance.new('UIListLayout')
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 5)
	layout.Parent = card

	local icon = Instance.new('ImageLabel')
	icon.Name = 'Icon'
	icon.BackgroundTransparency = 1
	icon.SizeConstraint = Enum.SizeConstraint.RelativeYY
	icon.Size = UDim2.fromScale(1, 1)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.LayoutOrder = 1
	icon.Parent = card

	local count = newText(card, 2)
	local owner = newText(card, 3)
	local distance = newText(card, 4)
	-- A solid dark outline on every label, so the text holds up over a light background or a
	-- busy world, not just the dark card - the readability the plate was missing.
	count.TextStrokeTransparency = 0.25
	owner.TextStrokeTransparency = 0.4
	distance.TextStrokeTransparency = 0.5

	hives[hive] = {
		Highlight = highlight,
		Billboard = billboard,
		Card = card,
		Stroke = stroke,
		Padding = padding,
		Icon = icon,
		Count = count,
		Owner = owner,
		Distance = distance,
		Adornee = part
	}
end

-- Only queues; the card is built in update() where instances can be made.
local function add(hive)
	if hives[hive] or pending[hive] then return end
	pending[hive] = true
end

local function remove(hive)
	pending[hive] = nil
	local entry = hives[hive]
	if entry then
		hives[hive] = nil
		entry.Billboard:Destroy()
		entry.Highlight:Destroy()
	end
end

local function refresh(hive, entry, here)
	local part = entry.Adornee
	if not shouldShow(hive) then
		entry.Billboard.Enabled = false
		entry.Highlight.Enabled = false
		return
	end
	local inRange = not here or (part.Position - here).Magnitude <= Range.Value
	if not inRange then
		entry.Billboard.Enabled = false
		entry.Highlight.Enabled = false
		return
	end

	local tint = hiveColor(hive)
	local size = math.floor(14 * Scale.Value)
	local font = FontOption and FontOption.Value or Font.fromEnum(Enum.Font.GothamBold)

	-- Highlight on the block itself, through walls, in the team colour.
	entry.Highlight.Enabled = on(ThroughWalls)
	entry.Highlight.FillColor = tint
	entry.Highlight.OutlineColor = tint
	entry.Highlight.FillTransparency = 1 - (FillOpacity and FillOpacity.Value or 0.3)

	-- Card background and outline.
	local bg = BackgroundColor
	entry.Card.BackgroundColor3 = Color3.fromHSV(bg.Hue, bg.Sat, bg.Value)
	entry.Card.BackgroundTransparency = on(Background) and (1 - bg.Opacity) or 1
	entry.Stroke.Enabled = on(Outline)
	entry.Stroke.Color = tint
	local pad = math.floor(size * 0.35)
	entry.Padding.PaddingLeft = UDim.new(0, pad + 2)
	entry.Padding.PaddingRight = UDim.new(0, pad + 2)
	entry.Padding.PaddingTop = UDim.new(0, pad)
	entry.Padding.PaddingBottom = UDim.new(0, pad)

	-- Icon.
	local image = iconOf('beehive')
	entry.Icon.Image = image
	entry.Icon.Visible = on(Icon) and image ~= ''

	-- Count, in the team colour so a full hive on your side reads apart from an enemy's.
	entry.Count.Visible = on(ShowCount)
	entry.Count.Text = tostring(hive:GetAttribute('Level') or 0)
	entry.Count.TextSize = size + 2
	entry.Count.FontFace = font
	entry.Count.TextColor3 = tint

	-- Owner, only for hives that are not yours (yours are obvious).
	local name = not ownHive(hive) and ownerName(hive) or nil
	entry.Owner.Visible = on(ShowOwner) and name ~= nil
	entry.Owner.Text = name or ''
	entry.Owner.TextSize = size - 1
	entry.Owner.FontFace = font
	entry.Owner.TextColor3 = Color3.fromRGB(235, 235, 235)

	-- Distance.
	entry.Distance.Visible = on(ShowDistance) and here ~= nil
	entry.Distance.Text = here and string.format('%dm', math.floor((part.Position - here).Magnitude)) or ''
	entry.Distance.TextSize = size - 2
	entry.Distance.FontFace = font
	entry.Distance.TextColor3 = Color3.fromRGB(180, 180, 180)

	entry.Billboard.StudsOffsetWorldSpace = Vector3.new(0, math.clamp(part.Size.Y * 0.5 + 1.5, 1.5, 6), 0)
	entry.Billboard.Size = UDim2.fromOffset(size * 20, size * 4)
	entry.Billboard.Enabled = true
end

local function update()
	-- Build queued hives here, on this thread, which can make instances.
	if next(pending) then
		for hive in pending do
			pending[hive] = nil
			if hive.Parent then create(hive) end
		end
	end

	local here = entitylib.isAlive and entitylib.character.RootPart.Position or nil
	for hive, entry in hives do
		if not (hive.Parent and entry.Adornee.Parent) then
			remove(hive)
			continue
		end
		-- Each on its own, so one hive going wrong does not blank the rest.
		local ok = pcall(refresh, hive, entry, here)
		if not ok then
			entry.Billboard.Enabled = false
			entry.Highlight.Enabled = false
		end
	end
end

BeehiveESP = vain.Categories.Render:CreateModule({
	Name = 'Beehive ESP',
	Tooltip = 'Shows every beehive, its bee count and whose it is, through walls',
	Function = function(callback)
		if callback then
			for _, hive in collectionService:GetTagged('beehive') do add(hive) end
			BeehiveESP:Clean(collectionService:GetInstanceAddedSignal('beehive'):Connect(add))
			BeehiveESP:Clean(collectionService:GetInstanceRemovedSignal('beehive'):Connect(remove))
			-- The count changes rarely; ten times a second keeps the distance smooth at no cost.
			local lastUpdate = 0
			BeehiveESP:Clean(runService.RenderStepped:Connect(function()
				if os.clock() - lastUpdate < 0.1 then return end
				lastUpdate = os.clock()
				pcall(update)
			end))
		else
			for hive in hives do remove(hive) end
			table.clear(hives)
			table.clear(pending)
		end
	end
})
ThroughWalls = BeehiveESP:CreateToggle({
	Name = 'Highlight',
	Tooltip = 'Fills each hive through walls in its team colour',
	Default = true,
	Function = function(callback)
		if FillOpacity and FillOpacity.Object then FillOpacity.Object.Visible = callback end
	end
})
FillOpacity = BeehiveESP:CreateSlider({
	Name = 'Fill Opacity',
	Tooltip = 'How solid the hive fill is',
	Min = 0,
	Max = 1,
	Default = 0.3,
	Decimal = 100,
	Darker = true
})
ShowCount = BeehiveESP:CreateToggle({
	Name = 'Show Count',
	Tooltip = 'Shows how many bees the hive is holding',
	Default = true
})
ShowOwner = BeehiveESP:CreateToggle({
	Name = 'Show Owner',
	Tooltip = 'Shows whose hive it is',
	Default = true
})
ShowDistance = BeehiveESP:CreateToggle({
	Name = 'Show Distance',
	Tooltip = 'Shows how far away the hive is'
})
ShowOwn = BeehiveESP:CreateToggle({
	Name = 'Show Own',
	Tooltip = 'Includes hives you placed yourself',
	Default = true
})
ShowTeammates = BeehiveESP:CreateToggle({
	Name = 'Show Teammates',
	Tooltip = 'Includes hives your teammates placed',
	Default = true
})
Icon = BeehiveESP:CreateToggle({
	Name = 'Icon',
	Tooltip = 'Shows the hive\'s item icon on the card',
	Default = true
})
Background = BeehiveESP:CreateToggle({
	Name = 'Background',
	Tooltip = 'Draws a background behind the card',
	Default = true,
	Function = function(callback)
		if BackgroundColor and BackgroundColor.Object then BackgroundColor.Object.Visible = callback end
	end
})
BackgroundColor = BeehiveESP:CreateColorSlider({
	-- Renamed from 'Background Color' on purpose: the first build shipped with no colour
	-- default, so the slider fell back to the component's cyan (hue 0.44) and that got saved
	-- into profiles, overriding the black default added later. A fresh name drops that stale
	-- saved value so the black below actually takes.
	Name = 'Card Color',
	Tooltip = 'Colour and opacity of the card background',
	-- Near-black, the same dark card the rest of Vain's ESP uses, so the team-coloured count
	-- and the white text read against it instead of washing out on a light background.
	DefaultHue = 0,
	DefaultSat = 0,
	DefaultValue = 0.08,
	DefaultOpacity = 0.55,
	Darker = true
})
Outline = BeehiveESP:CreateToggle({
	Name = 'Outline',
	Tooltip = 'Outlines each card in its team colour',
	Default = true
})
FontOption = BeehiveESP:CreateFont({
	Name = 'Font',
	Tooltip = 'Font used for the cards',
	Blacklist = 'GothamBold'
})
Range = BeehiveESP:CreateSlider({
	Name = 'Range',
	Tooltip = 'How far away hives are shown',
	Min = 20,
	Max = 2000,
	Default = 500,
	Suffix = function(val) return val == 1 and 'stud' or 'studs' end
})
Scale = BeehiveESP:CreateSlider({
	Name = 'Scale',
	Tooltip = 'How big the cards are',
	Min = 0.5,
	Max = 2,
	Default = 1,
	Decimal = 10
})
