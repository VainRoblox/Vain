--[[
	Generator ESP.

	Every generator on the map - diamond, emerald and the ones at each base - is a part tagged
	Generator, with an Id attribute naming what it makes ("diamond_1"), a GeneratorLevel, a
	Cooldown between spawns, and the game's own label under it in
	RoactTree.TeamOreGeneratorApp: a Title and a Countdown with the seconds to the next
	spawn. The game hides those labels a short way off. This reads them and shows a card over
	every generator, through walls and at any distance, with everything piled up on it
	waiting to be taken.
]]
local GeneratorESP
local Diamond, Emerald, Team, ShowItems, ShowTier, ShowTimer, ProgressBar, Icons
local Background, BackgroundColor, Outline, FontOption, Range, Scale
local ShowDistance, Compact, HideEmpty, FullAlert, FullAmount, FullColor, ShowTierUp

--[[
	When the diamond and emerald generators level up: the game's BWOreGenLevelSystem steps
	them up at fixed times into the match - 0, 5, 10, 15 and 20 minutes - so the next one
	is simply the next of those after how long the match has run.
]]
local LEVEL_TIMES = {0, 300, 600, 900, 1200}
local function nextTierIn()
	local started = store.matchStartTime
	if type(started) ~= 'number' or started <= 0 then return nil end
	local elapsed = os.time() - started
	for _, at in LEVEL_TIMES do
		if at > elapsed then return at - elapsed end
	end
	return nil
end
local Folder = Instance.new('Folder')
Folder.Parent = vain.gui
local generators = {}
local piles = {}
local lastPileScan = 0

local KINDS = {
	diamond = {color = Color3.fromRGB(110, 210, 255), item = 'diamond', name = 'Diamond'},
	emerald = {color = Color3.fromRGB(90, 230, 120), item = 'emerald', name = 'Emerald'},
	team = {color = Color3.fromRGB(235, 235, 235), item = 'iron', name = 'Base'}
}
-- The order the contents are listed in; anything else lying there comes after.
local ORDER = {iron = 1, gold = 2, diamond = 3, emerald = 4}

local function on(setting)
	return setting ~= nil and setting.Enabled
end

--[[
	The game's labels, found once and remembered: a recursive search for each of them on
	every generator every frame was the costly part of this module. A label that is not
	there yet is looked for again every couple of seconds rather than every frame.
]]
local labelCache = setmetatable({}, {__mode = 'k'})
local function textOf(model, name)
	local cache = labelCache[model]
	if not cache then
		cache = {}
		labelCache[model] = cache
	end
	local label = cache[name]
	if label and not label:IsDescendantOf(model) then label = nil end
	if not label and os.clock() >= (cache[name .. '#retry'] or 0) then
		label = model:FindFirstChild(name, true)
		label = label and label:IsA('TextLabel') and label or nil
		if not label then cache[name .. '#retry'] = os.clock() + 2 end
	end
	cache[name] = label
	return label and label.Text or nil
end

local function iconOf(itemType)
	local meta = bedwars.ItemMeta[itemType]
	return meta and meta.image or ''
end

-- What a generator makes, from its Id, or its label if the Id says nothing. Nil until
-- either has loaded in.
local function kindOf(part)
	local id = tostring(part:GetAttribute('Id') or ''):lower()
	local title = (textOf(part, 'Title') or textOf(part, 'Countdown') or ''):lower()
	for _, text in {id, title} do
		if text:find('diamond', 1, true) then return 'diamond' end
		if text:find('emerald', 1, true) then return 'emerald' end
	end
	if id ~= '' or part:FindFirstChild('TeamGenMain', true) then return 'team' end
	return nil
end

-- Seconds to the next spawn, as the game's own label has it: "[25]", "0:25" (its
-- Countdown component formats as minutes and seconds) or a bare number.
local function secondsOf(model)
	local text = textOf(model, 'Countdown') or textOf(model, 'Timer')
	if not text then return nil end
	local bracket = text:match('%[([%d%.]+)%]')
	if bracket then return tonumber(bracket) end
	local minutes, seconds = text:match('(%d+):(%d+)')
	if minutes then return tonumber(minutes) * 60 + tonumber(seconds) end
	return tonumber(text:match('([%d%.]+)'))
end

local function enabledKind(kind)
	if kind == 'diamond' then return on(Diamond) end
	if kind == 'emerald' then return on(Emerald) end
	if kind == 'team' then return on(Team) end
	return false
end

local function remove(model)
	local entry = generators[model]
	if entry then
		entry.billboard:Destroy()
		generators[model] = nil
	end
end

local function newText(parent, order)
	local label = Instance.new('TextLabel')
	label.BackgroundTransparency = 1
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromScale(0, 1)
	label.TextStrokeTransparency = 0.6
	label.TextColor3 = Color3.new(1, 1, 1)
	label.LayoutOrder = order
	label.Parent = parent
	return label
end

local function newIcon(parent, order)
	local image = Instance.new('ImageLabel')
	image.BackgroundTransparency = 1
	image.SizeConstraint = Enum.SizeConstraint.RelativeYY
	image.Size = UDim2.fromScale(1, 1)
	image.ScaleType = Enum.ScaleType.Fit
	image.LayoutOrder = order
	image.Parent = parent
	return image
end

--[[
	The card: a row of the generator's icon, name, timer and tier, a row of what is piled on
	it, and a bar running down to the next spawn. Built once per generator; update only sets
	what changed.
]]
local function add(part)
	if generators[part] or not part:IsA('BasePart') then return end

	local billboard = Instance.new('BillboardGui')
	billboard.Name = 'GeneratorESP'
	billboard.Adornee = part
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 4.5, 0)
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
	card.BorderSizePixel = 0
	card.Parent = billboard
	Instance.new('UICorner', card).CornerRadius = UDim.new(0, 6)
	local stroke = Instance.new('UIStroke')
	stroke.Thickness = 1
	stroke.Transparency = 0.3
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = card
	local padding = Instance.new('UIPadding')
	padding.Parent = card
	local layout = Instance.new('UIListLayout')
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, 2)
	layout.Parent = card

	local function row(order)
		local frame = Instance.new('Frame')
		frame.BackgroundTransparency = 1
		frame.AutomaticSize = Enum.AutomaticSize.X
		frame.LayoutOrder = order
		frame.Parent = card
		local list = Instance.new('UIListLayout')
		list.FillDirection = Enum.FillDirection.Horizontal
		list.VerticalAlignment = Enum.VerticalAlignment.Center
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Padding = UDim.new(0, 4)
		list.Parent = frame
		return frame
	end

	local header = row(1)
	local icon = newIcon(header, 1)
	local title = newText(header, 2)
	local timer = newText(header, 3)
	local tier = newText(header, 4)
	local distance = newText(header, 5)
	local tierUp = newText(header, 6)
	local contents = row(2)

	local bar = Instance.new('Frame')
	bar.Name = 'Bar'
	bar.BackgroundColor3 = Color3.new(0, 0, 0)
	bar.BackgroundTransparency = 0.5
	bar.BorderSizePixel = 0
	bar.LayoutOrder = 3
	bar.Parent = card
	Instance.new('UICorner', bar).CornerRadius = UDim.new(1, 0)
	local fill = Instance.new('Frame')
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(1, 1)
	fill.Parent = bar
	Instance.new('UICorner', fill).CornerRadius = UDim.new(1, 0)

	generators[part] = {
		billboard = billboard, adornee = part, card = card, stroke = stroke, padding = padding,
		header = header, icon = icon, title = title, timer = timer, tier = tier, distance = distance, tierUp = tierUp,
		contents = contents, chips = {}, bar = bar, fill = fill
	}
end

--[[
	Everything lying on each generator, by item type. Drops are parts tagged ItemDrop,
	named by item type, with the stack size in Amount. The tagged generator part floats
	above the generator itself, so drops are matched by distance across the ground and a
	generous height window rather than straight-line distance. Read every half second
	rather than every frame.
]]
local function scanPiles()
	if os.clock() - lastPileScan < 0.5 then return end
	lastPileScan = os.clock()
	table.clear(piles)

	local drops = collectionService:GetTagged('ItemDrop')
	-- Drops also live in the ItemDrops folder; anything there without the tag is counted too.
	local folder = workspace:FindFirstChild('ItemDrops')
	if folder then
		local seen = {}
		for _, drop in drops do seen[drop] = true end
		for _, drop in folder:GetChildren() do
			if not seen[drop] then drops[#drops + 1] = drop end
		end
	end
	for model, entry in generators do
		if entry.kind and entry.adornee.Parent then
			local center = entry.adornee.Position
			local radius = entry.kind == 'team' and 9 or 7
			local counts = {}
			for _, drop in drops do
				local part = drop:IsA('BasePart') and drop or drop:FindFirstChildWhichIsA('BasePart', true)
				local offset = part and part.Position - center
				if offset and Vector2.new(offset.X, offset.Z).Magnitude <= radius and offset.Y <= 4 and offset.Y >= -14 then
					counts[drop.Name] = (counts[drop.Name] or 0) + (tonumber(drop:GetAttribute('Amount')) or 1)
				end
			end
			piles[model] = counts
		end
	end
end

-- One icon-and-count chip per item type piled up, reused between updates.
local function setContents(entry, counts, size, font)
	local list = {}
	for itemType, amount in counts or {} do
		list[#list + 1] = {itemType = itemType, amount = amount}
	end
	table.sort(list, function(a, b)
		local oa, ob = ORDER[a.itemType] or 99, ORDER[b.itemType] or 99
		if oa ~= ob then return oa < ob end
		return a.itemType < b.itemType
	end)

	for i, item in list do
		local chip = entry.chips[i]
		if not chip then
			local frame = Instance.new('Frame')
			frame.BackgroundTransparency = 1
			frame.AutomaticSize = Enum.AutomaticSize.X
			frame.Size = UDim2.fromScale(0, 1)
			frame.LayoutOrder = i
			frame.Parent = entry.contents
			local layout = Instance.new('UIListLayout')
			layout.FillDirection = Enum.FillDirection.Horizontal
			layout.VerticalAlignment = Enum.VerticalAlignment.Center
			layout.Padding = UDim.new(0, 2)
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			layout.Parent = frame
			chip = {frame = frame, icon = newIcon(frame, 1), label = newText(frame, 2)}
			entry.chips[i] = chip
		end
		local image = iconOf(item.itemType)
		chip.icon.Image = image
		chip.icon.Visible = on(Icons) and image ~= ''
		chip.label.Text = (on(Icons) and image ~= '') and tostring(item.amount) or (item.amount .. ' ' .. item.itemType)
		chip.label.TextSize = size
		chip.label.FontFace = font
		chip.label.TextColor3 = KINDS[item.itemType] and KINDS[item.itemType].color or Color3.new(1, 1, 1)
		chip.frame.Visible = true
	end
	for i = #list + 1, #entry.chips do entry.chips[i].frame.Visible = false end
	entry.contents.Visible = #list > 0
	entry.contents.Size = UDim2.fromOffset(0, size + 2)
end

local function refresh(model, entry, here)
	entry.kind = entry.kind or kindOf(model)
	local kind = entry.kind
	local billboard = entry.billboard
	local inRange = not here or (entry.adornee.Position - here).Magnitude <= Range.Value
	if not (kind and enabledKind(kind) and inRange) then
		billboard.Enabled = false
		return
	end

	local info = KINDS[kind]
	local size = math.floor(14 * Scale.Value)
	local font = FontOption and FontOption.Value or Font.fromEnum(Enum.Font.GothamBold)

	-- What is waiting on it: its own resource for diamond and emerald, everything for a base.
	local counts = piles[model] or {}
	local total = 0
	for itemType, amount in counts do
		if kind == 'team' or itemType == info.item then total += amount end
	end
	if on(HideEmpty) and total == 0 then
		billboard.Enabled = false
		return
	end
	local full = on(FullAlert) and total >= FullAmount.Value
	local compact = on(Compact)

	-- Card
	local bg = BackgroundColor
	entry.card.BackgroundColor3 = Color3.fromHSV(bg.Hue, bg.Sat, bg.Value)
	entry.card.BackgroundTransparency = on(Background) and (1 - bg.Opacity) or 1
	-- A full pile pulses the outline in the alert colour, outline setting or not.
	entry.stroke.Enabled = on(Outline) or full
	if full then
		local pulse = 0.5 + 0.5 * math.sin(os.clock() * 6)
		entry.stroke.Color = Color3.fromHSV(FullColor.Hue, FullColor.Sat, FullColor.Value)
		entry.stroke.Thickness = 1 + pulse
	else
		entry.stroke.Color = info.color
		entry.stroke.Thickness = 1
	end
	local pad = math.floor(size * 0.35)
	entry.padding.PaddingLeft = UDim.new(0, pad + 2)
	entry.padding.PaddingRight = UDim.new(0, pad + 2)
	entry.padding.PaddingTop = UDim.new(0, pad)
	entry.padding.PaddingBottom = UDim.new(0, pad)

	-- Header
	entry.header.Size = UDim2.fromOffset(0, size + 2)
	local image = iconOf(info.item)
	entry.icon.Image = image
	-- Compact keeps just the icon, the amount and the timer.
	entry.icon.Visible = image ~= '' and (compact or (on(Icons) and kind ~= 'team'))
	if compact then
		entry.title.Text = 'x' .. total
	else
		entry.title.Text = kind == 'team' and (textOf(model, 'Title') or 'Base Generator') or info.name
	end
	entry.title.TextColor3 = full and Color3.fromHSV(FullColor.Hue, FullColor.Sat, FullColor.Value) or info.color
	local seconds = secondsOf(model)
	entry.timer.Visible = on(ShowTimer) and seconds ~= nil
	entry.timer.Text = seconds and (seconds % 1 == 0 and (seconds .. 's') or string.format('%.1fs', seconds)) or ''
	local level = model:GetAttribute('GeneratorLevel')
	local tierText = textOf(model, 'GenTier') or textOf(model, 'Tier')
	entry.tier.Visible = not compact and on(ShowTier) and (tierText ~= nil or level ~= nil)
	entry.tier.Text = tierText and tierText:upper() or ('T' .. tostring(level or ''))
	entry.tier.TextColor3 = Color3.fromRGB(200, 200, 200)
	entry.distance.Visible = not compact and on(ShowDistance) and here ~= nil
	entry.distance.Text = here and string.format('%dm', math.floor((entry.adornee.Position - here).Magnitude)) or ''
	entry.distance.TextColor3 = Color3.fromRGB(170, 170, 170)
	local untilTier = kind ~= 'team' and on(ShowTierUp) and not compact and nextTierIn()
	entry.tierUp.Visible = untilTier ~= nil and untilTier ~= false
	if entry.tierUp.Visible then
		entry.tierUp.Text = string.format('Tier up %d:%02d', untilTier // 60, untilTier % 60)
		entry.tierUp.TextColor3 = Color3.fromRGB(255, 210, 90)
	end
	for _, label in {entry.title, entry.timer, entry.tier, entry.distance, entry.tierUp} do
		label.TextSize = size
		label.FontFace = font
	end

	-- Contents
	if on(ShowItems) and not compact then
		setContents(entry, piles[model], size, font)
	else
		entry.contents.Visible = false
	end

	-- Progress to the next spawn, full just after one and empty as the next lands.
	local cooldown = tonumber(model:GetAttribute('Cooldown'))
	entry.bar.Visible = not compact and on(ProgressBar) and seconds ~= nil and cooldown ~= nil and cooldown > 0
	if entry.bar.Visible then
		entry.bar.Size = UDim2.fromOffset(math.max(entry.header.AbsoluteSize.X, size * 4), math.max(2, math.floor(size / 5)))
		entry.fill.Size = UDim2.fromScale(math.clamp(seconds / cooldown, 0, 1), 1)
		entry.fill.BackgroundColor3 = info.color
	end

	billboard.Size = UDim2.fromOffset(size * 22, size * 6)
	billboard.Enabled = true
end

local function update()
	if on(ShowItems) or on(HideEmpty) or on(FullAlert) or on(Compact) then scanPiles() end
	local here = entitylib.isAlive and entitylib.character.RootPart.Position

	for model, entry in generators do
		if not (model.Parent and entry.adornee.Parent) then
			remove(model)
			continue
		end
		-- Each on its own, so one generator going wrong does not blank all the others.
		local ok = pcall(refresh, model, entry, here)
		if not ok then entry.billboard.Enabled = false end
	end
end

GeneratorESP = vain.Categories.Render:CreateModule({
	Name = 'GeneratorESP',
	Tooltip = 'Shows generator timers and resource piles through walls',
	Function = function(callback)
		if callback then
			for _, part in collectionService:GetTagged('Generator') do add(part) end
			GeneratorESP:Clean(collectionService:GetInstanceAddedSignal('Generator'):Connect(add))
			GeneratorESP:Clean(collectionService:GetInstanceRemovedSignal('Generator'):Connect(remove))
			-- Ten times a second is plenty: the timers only change once a second.
			local lastUpdate = 0
			GeneratorESP:Clean(runService.RenderStepped:Connect(function()
				if os.clock() - lastUpdate < 0.1 then return end
				lastUpdate = os.clock()
				pcall(update)
			end))
		else
			for model in generators do remove(model) end
			table.clear(piles)
		end
	end
})
Diamond = GeneratorESP:CreateToggle({
	Name = 'Diamond',
	Tooltip = 'Shows diamond generators',
	Default = true
})
Emerald = GeneratorESP:CreateToggle({
	Name = 'Emerald',
	Tooltip = 'Shows emerald generators',
	Default = true
})
Team = GeneratorESP:CreateToggle({
	Name = 'Team Generators',
	Tooltip = 'Also shows the generators at bases'
})
ShowItems = GeneratorESP:CreateToggle({
	Name = 'Show Items',
	Tooltip = 'Shows everything piled up on each generator',
	Default = true
})
ShowTimer = GeneratorESP:CreateToggle({
	Name = 'Show Timer',
	Tooltip = 'Shows the seconds to the next spawn',
	Default = true
})
ProgressBar = GeneratorESP:CreateToggle({
	Name = 'Progress Bar',
	Tooltip = 'A bar running down to the next spawn',
	Default = true
})
ShowTier = GeneratorESP:CreateToggle({
	Name = 'Show Tier',
	Tooltip = 'Shows each generator\'s tier'
})
ShowTierUp = GeneratorESP:CreateToggle({
	Name = 'Tier Up Timer',
	Tooltip = 'Time until diamond and emerald gens level up',
	Default = true
})
ShowDistance = GeneratorESP:CreateToggle({
	Name = 'Distance',
	Tooltip = 'Shows how far away each one is'
})
Compact = GeneratorESP:CreateToggle({
	Name = 'Compact',
	Tooltip = 'Just the icon, amount and timer'
})
HideEmpty = GeneratorESP:CreateToggle({
	Name = 'Hide Empty',
	Tooltip = 'Hides generators with nothing on them'
})
FullAlert = GeneratorESP:CreateToggle({
	Name = 'Full Alert',
	Tooltip = 'Flashes a generator once its pile is big enough',
	Function = function(callback)
		for _, setting in {FullAmount, FullColor} do
			if setting and setting.Object then setting.Object.Visible = callback end
		end
	end
})
FullAmount = GeneratorESP:CreateSlider({
	Name = 'Full Amount',
	Tooltip = 'How many count as full',
	Min = 1,
	Max = 30,
	Default = 4,
	Darker = true,
	Visible = false
})
FullColor = GeneratorESP:CreateColorSlider({
	Name = 'Full Color',
	Tooltip = 'Colour of the full alert',
	DefaultHue = 0.13,
	DefaultSat = 0.9,
	DefaultValue = 1,
	Darker = true,
	Visible = false
})
Icons = GeneratorESP:CreateToggle({
	Name = 'Icons',
	Tooltip = 'Item icons instead of names',
	Default = true
})
Background = GeneratorESP:CreateToggle({
	Name = 'Background',
	Tooltip = 'Puts each card on a background',
	Default = true,
	Function = function(callback)
		if BackgroundColor and BackgroundColor.Object then BackgroundColor.Object.Visible = callback end
	end
})
BackgroundColor = GeneratorESP:CreateColorSlider({
	Name = 'Background Color',
	Tooltip = 'Colour and opacity of the background',
	DefaultHue = 0,
	DefaultSat = 0,
	DefaultValue = 0.08,
	DefaultOpacity = 0.55
})
Outline = GeneratorESP:CreateToggle({
	Name = 'Outline',
	Tooltip = 'Outlines each card in its generator\'s colour',
	Default = true
})
FontOption = GeneratorESP:CreateFont({
	Name = 'Font',
	Tooltip = 'Font used for the cards',
	Blacklist = 'GothamBold'
})
Range = GeneratorESP:CreateSlider({
	Name = 'Range',
	Tooltip = 'How far away generators are shown',
	Min = 50,
	Max = 2000,
	Default = 2000,
	Suffix = function(val) return val == 1 and 'stud' or 'studs' end
})
Scale = GeneratorESP:CreateSlider({
	Name = 'Scale',
	Tooltip = 'How big the cards are',
	Min = 0.5,
	Max = 2,
	Default = 1,
	Decimal = 10
})
