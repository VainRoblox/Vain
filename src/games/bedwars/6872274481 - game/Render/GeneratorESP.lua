--[[
	Generator ESP.

	Every generator on the map - diamond, emerald and the ones at each base - is a part tagged
	Generator, with an Id attribute naming what it makes ("diamond_1"), a GeneratorLevel,
	and the game's own label under it in RoactTree.TeamOreGeneratorApp: a Title and a
	Countdown with the seconds to the next spawn. The game hides those labels a short way
	off. This reads them and shows them over every generator, through walls and at any
	distance, together with how many of its resource are piled up on it waiting to be taken.
]]
local GeneratorESP
local Diamond, Emerald, Team, ShowItems, ShowTier, Range, TextSize
local Folder = Instance.new('Folder')
Folder.Parent = vain.gui
local generators = {}
local piles = {}
local lastPileScan = 0

local KINDS = {
	diamond = {color = Color3.fromRGB(110, 210, 255), item = 'diamond'},
	emerald = {color = Color3.fromRGB(90, 230, 120), item = 'emerald'},
	team = {color = Color3.fromRGB(235, 235, 235), item = 'iron'}
}

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function textOf(model, name)
	local label = model:FindFirstChild(name, true)
	return label and label:IsA('TextLabel') and label.Text or nil
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

-- Seconds to the next spawn, as the game's own label has it.
local function secondsOf(model)
	local text = textOf(model, 'Countdown') or textOf(model, 'Timer')
	return text and tonumber(text:match('%[([%d%.]+)%]') or text:match('([%d%.]+)')) or nil
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

local function add(part)
	if generators[part] or not part:IsA('BasePart') then return end

	local billboard = Instance.new('BillboardGui')
	billboard.Name = 'GeneratorESP'
	billboard.Adornee = part
	billboard.Size = UDim2.fromOffset(150, 24)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
	billboard.AlwaysOnTop = true
	billboard.Enabled = false
	billboard.Parent = Folder

	local label = Instance.new('TextLabel')
	label.Name = 'Label'
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextStrokeTransparency = 0.4
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Parent = billboard

	generators[part] = {billboard = billboard, adornee = part}
end

-- How many of each generator's resource are lying on it. Item drops carry the CollectionService
-- tag ItemDrop and are named by item type; read every half second rather than every frame.
local function scanPiles()
	if os.clock() - lastPileScan < 0.5 then return end
	lastPileScan = os.clock()
	table.clear(piles)

	local drops = collectionService:GetTagged('ItemDrop')
	for model, entry in generators do
		local kind = entry.kind
		local wanted = kind and KINDS[kind] and KINDS[kind].item
		if wanted and entry.adornee.Parent then
			local center = entry.adornee.Position
			local count = 0
			for _, drop in drops do
				if drop.Name == wanted then
					local part = drop:IsA('BasePart') and drop or drop:FindFirstChildWhichIsA('BasePart', true)
					if part and (part.Position - center).Magnitude <= 7 then
						count += tonumber(drop:GetAttribute('Amount')) or 1
					end
				end
			end
			piles[model] = count
		end
	end
end

local function refresh(model, entry, here, size)
	entry.kind = entry.kind or kindOf(model)
	local kind = entry.kind
	local billboard = entry.billboard
	local inRange = not here or (entry.adornee.Position - here).Magnitude <= Range.Value

	if kind and enabledKind(kind) and inRange then
		local parts = {}
		local seconds = secondsOf(model)
		local name = kind == 'diamond' and 'Diamond' or kind == 'emerald' and 'Emerald' or (textOf(model, 'Title') or 'Base Generator')
		parts[1] = name
		if seconds then
			parts[#parts + 1] = (kind == 'team' and string.format('%.1fs', seconds) or (seconds .. 's'))
		end
		if on(ShowItems) and piles[model] and piles[model] > 0 then
			parts[#parts + 1] = 'x' .. piles[model]
		end
		if on(ShowTier) then
			local tier = textOf(model, 'GenTier') or textOf(model, 'Tier')
			local level = model:GetAttribute('GeneratorLevel')
			if tier then
				parts[#parts + 1] = tier:upper()
			elseif level then
				parts[#parts + 1] = 'T' .. level
			end
		end
		billboard.Label.Text = table.concat(parts, '  ')
		billboard.Label.TextColor3 = KINDS[kind].color
		billboard.Label.TextSize = size
		billboard.Size = UDim2.fromOffset(math.max(150, size * 14), size + 10)
		billboard.Enabled = true
	else
		billboard.Enabled = false
	end
end

local function update()
	if on(ShowItems) then scanPiles() end
	local here = entitylib.isAlive and entitylib.character.RootPart.Position
	local size = TextSize and TextSize.Value or 14

	for model, entry in generators do
		if not (model.Parent and entry.adornee.Parent) then
			remove(model)
			continue
		end
		-- Each on its own, so one generator going wrong does not blank all the others.
		local ok = pcall(refresh, model, entry, here, size)
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
			GeneratorESP:Clean(runService.RenderStepped:Connect(function()
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
	Tooltip = 'Also shows the iron and gold generators at bases'
})
ShowItems = GeneratorESP:CreateToggle({
	Name = 'Show Items',
	Tooltip = 'Shows how many are piled up on each generator',
	Default = true
})
ShowTier = GeneratorESP:CreateToggle({
	Name = 'Show Tier',
	Tooltip = 'Shows each generator\'s tier'
})
Range = GeneratorESP:CreateSlider({
	Name = 'Range',
	Tooltip = 'How far away generators are shown',
	Min = 50,
	Max = 2000,
	Default = 2000,
	Suffix = function(val) return val == 1 and 'stud' or 'studs' end
})
TextSize = GeneratorESP:CreateSlider({
	Name = 'Text Size',
	Tooltip = 'How big the labels are',
	Min = 8,
	Max = 30,
	Default = 14
})
