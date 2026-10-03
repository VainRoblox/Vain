--[[
	Generator ESP.

	Every diamond and emerald generator on the map is a GlobalOreGeneratorModel carrying the
	game's own label - "Diamond Generator [10]", the seconds to the next spawn in brackets -
	and each team generator a label with its own timer. The game hides those labels a short
	way off. This reads them and shows them over every generator, through walls and at any
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
	team = {color = Color3.fromRGB(235, 235, 235)}
}

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function textOf(model, name)
	local label = model:FindFirstChild(name, true)
	return label and label:IsA('TextLabel') and label.Text or nil
end

-- Which kind of generator this is, from its own label.
local function kindOf(model)
	local countdown = textOf(model, 'Countdown')
	if countdown then
		local lower = countdown:lower()
		if lower:find('diamond', 1, true) then return 'diamond' end
		if lower:find('emerald', 1, true) then return 'emerald' end
	end
	if textOf(model, 'Timer') then return 'team' end
	return nil
end

-- Seconds to the next spawn, as the game's own label has it.
local function secondsOf(model, kind)
	if kind == 'team' then
		local text = textOf(model, 'Timer')
		return text and tonumber(text:match('([%d%.]+)')) or nil
	end
	local text = textOf(model, 'Countdown')
	return text and tonumber(text:match('%[(%d+)%]')) or nil
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

local function add(model)
	if generators[model] or not (model:IsA('Model') and model.Name == 'GlobalOreGeneratorModel') then return end
	local adornee = model:FindFirstChild('GeneratorAdornee') or model.PrimaryPart or model:FindFirstChildWhichIsA('BasePart', true)
	if not adornee then return end

	local billboard = Instance.new('BillboardGui')
	billboard.Name = 'GeneratorESP'
	billboard.Adornee = adornee
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

	generators[model] = {billboard = billboard, adornee = adornee}
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

local function update()
	if on(ShowItems) then scanPiles() end
	local here = entitylib.isAlive and entitylib.character.RootPart.Position
	local size = TextSize and TextSize.Value or 14

	for model, entry in generators do
		if not (model.Parent and entry.adornee.Parent) then
			remove(model)
			continue
		end
		entry.kind = entry.kind or kindOf(model)
		local kind = entry.kind
		local billboard = entry.billboard
		local inRange = not here or (entry.adornee.Position - here).Magnitude <= Range.Value

		if kind and enabledKind(kind) and inRange then
			local parts = {}
			local seconds = secondsOf(model, kind)
			local name = kind == 'diamond' and 'Diamond' or kind == 'emerald' and 'Emerald' or (textOf(model, 'Title') or 'Generator')
			parts[1] = name
			if seconds then
				parts[#parts + 1] = (kind == 'team' and string.format('%.1fs', seconds) or (seconds .. 's'))
			end
			if on(ShowItems) and piles[model] and piles[model] > 0 then
				parts[#parts + 1] = 'x' .. piles[model]
			end
			if on(ShowTier) then
				local tier = textOf(model, 'GenTier') or textOf(model, 'Tier')
				if tier then parts[#parts + 1] = tier:upper() end
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
end

GeneratorESP = vain.Categories.Render:CreateModule({
	Name = 'GeneratorESP',
	Tooltip = 'Shows generator timers and resource piles through walls',
	Function = function(callback)
		if callback then
			-- Generators are part of the map, so they are found once and then watched for.
			task.spawn(function()
				for _, descendant in workspace:GetDescendants() do
					if descendant.Name == 'GlobalOreGeneratorModel' then add(descendant) end
				end
			end)
			GeneratorESP:Clean(workspace.DescendantAdded:Connect(function(descendant)
				if descendant.Name == 'GlobalOreGeneratorModel' then
					task.defer(add, descendant)
				end
			end))
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
