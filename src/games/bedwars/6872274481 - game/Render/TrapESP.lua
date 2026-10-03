--[[
	Trap ESP.

	Every trap is a placed block carrying a CollectionService tag from its item meta
	(collectionServiceTags) and PlacedByUserId: snap traps (snap_trap), the Trapper kit's
	snap, venom and explosive traps (trapper_trap), tesla coils (tesla-trap), invisible
	landmines (invisible-landmine - drawn fully see-through to enemies by the game), spike
	traps, grave traps, spider webs and turrets. This labels each one, through walls, with
	what it is and how far away, in red when it is someone else's.
]]
local TrapESP
local Snap, Tesla, Landmines, Spikes, Webs, Turrets
local ShowOwn, Distance, Highlight, EnemyColor, OwnColor, Range
local Folder = Instance.new('Folder')
Folder.Name = 'TrapESP'
Folder.Parent = vain.gui
local traps = {}
local connections = {}

-- Tag -> the setting it belongs to and what it is called when the block's name says
-- nothing better.
local TAGS = {
	snap_trap = {group = function() return Snap end, name = 'Snap Trap'},
	trapper_trap = {group = function() return Snap end, name = 'Trap'},
	GlueTrap = {group = function() return Snap end, name = 'Glue Trap'},
	['tesla-trap'] = {group = function() return Tesla end, name = 'Tesla Trap'},
	['invisible-landmine'] = {group = function() return Landmines end, name = 'Landmine'},
	spike_trap = {group = function() return Spikes end, name = 'Spike Trap'},
	GraveTrap = {group = function() return Spikes end, name = 'Grave Trap'},
	spider_web = {group = function() return Webs end, name = 'Spider Web'},
	Turret = {group = function() return Turrets end, name = 'Turret'},
	['shock-wave-turret'] = {group = function() return Turrets end, name = 'Shock Wave Turret'}
}

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function colorOf(setting)
	return Color3.fromHSV(setting.Hue, setting.Sat, setting.Value)
end

local function partOf(trap)
	if trap:IsA('BasePart') then return trap end
	return trap.PrimaryPart or trap:FindFirstChildWhichIsA('BasePart', true)
end

-- The block's own name is its item type ("venom_trap", "snap_trap"); that reads better
-- than the tag where there is item meta for it.
local function nameOf(trap, info)
	local meta = bedwars.ItemMeta[trap.Name]
	return meta and meta.displayName or info.name
end

local function isOwn(trap)
	local userId = trap:GetAttribute('PlacedByUserId')
	if userId == lplr.UserId then return true end
	local owner = playersService:GetPlayerByUserId(userId or 0)
	if owner then
		local mine, theirs = lplr:GetAttribute('Team'), owner:GetAttribute('Team')
		if mine ~= nil and theirs ~= nil then return tostring(mine) == tostring(theirs) end
	end
	-- The Trapper kit writes its team on the trap instead.
	local team = trap:GetAttribute('TrapperTeamId')
	return team ~= nil and tostring(team) == tostring(lplr:GetAttribute('Team'))
end

local function remove(trap)
	local entry = traps[trap]
	if not entry then return end
	entry.billboard:Destroy()
	if entry.highlight then entry.highlight:Destroy() end
	traps[trap] = nil
end

local function add(trap, info)
	if traps[trap] then return end
	local part = partOf(trap)
	if not part then return end

	local billboard = Instance.new('BillboardGui')
	billboard.Adornee = part
	billboard.Size = UDim2.fromOffset(160, 20)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 2.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Enabled = false
	billboard.Parent = Folder

	local label = Instance.new('TextLabel')
	label.Name = 'Label'
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextStrokeTransparency = 0.4
	label.Parent = billboard

	traps[trap] = {billboard = billboard, label = label, info = info, part = part}
end

local function update()
	local here = entitylib.isAlive and entitylib.character.RootPart.Position
	for trap, entry in traps do
		if not (trap.Parent and entry.part.Parent) then
			remove(trap)
			continue
		end
		local own = isOwn(trap)
		local distance = here and (entry.part.Position - here).Magnitude or 0
		local show = on(entry.info.group()) and (not own or on(ShowOwn)) and distance <= Range.Value
		entry.billboard.Enabled = show

		if show then
			local color = own and colorOf(OwnColor) or colorOf(EnemyColor)
			entry.label.TextColor3 = color
			entry.label.Text = nameOf(trap, entry.info) .. (on(Distance) and here and string.format(' [%d]', math.floor(distance)) or '')

			if on(Highlight) then
				if not entry.highlight then
					entry.highlight = Instance.new('Highlight')
					entry.highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
					entry.highlight.Adornee = trap
					entry.highlight.Parent = Folder
				end
				entry.highlight.FillColor = color
				entry.highlight.OutlineColor = color
				entry.highlight.FillTransparency = 0.6
				entry.highlight.Enabled = true
			elseif entry.highlight then
				entry.highlight.Enabled = false
			end
		elseif entry.highlight then
			entry.highlight.Enabled = false
		end
	end
end

TrapESP = vain.Categories.Render:CreateModule({
	Name = 'Trap ESP',
	Tooltip = 'Shows every trap on the map through walls',
	Function = function(callback)
		if callback then
			for tag, info in TAGS do
				for _, trap in collectionService:GetTagged(tag) do add(trap, info) end
				TrapESP:Clean(collectionService:GetInstanceAddedSignal(tag):Connect(function(trap)
					add(trap, info)
				end))
				TrapESP:Clean(collectionService:GetInstanceRemovedSignal(tag):Connect(remove))
			end
			TrapESP:Clean(runService.RenderStepped:Connect(function()
				pcall(update)
			end))
		else
			for trap in traps do remove(trap) end
		end
	end
})
Snap = TrapESP:CreateToggle({
	Name = 'Snap Traps',
	Tooltip = 'Snap, venom, explosive and glue traps',
	Default = true
})
Tesla = TrapESP:CreateToggle({
	Name = 'Tesla Traps',
	Tooltip = 'Tesla coil traps',
	Default = true
})
Landmines = TrapESP:CreateToggle({
	Name = 'Landmines',
	Tooltip = 'Invisible landmines',
	Default = true
})
Spikes = TrapESP:CreateToggle({
	Name = 'Spike Traps',
	Tooltip = 'Spike and grave traps',
	Default = true
})
Webs = TrapESP:CreateToggle({
	Name = 'Spider Webs',
	Tooltip = 'Spider webs',
	Default = true
})
Turrets = TrapESP:CreateToggle({
	Name = 'Turrets',
	Tooltip = 'Turrets of every kind',
	Default = true
})
ShowOwn = TrapESP:CreateToggle({
	Name = 'Show Own',
	Tooltip = 'Also shows your team\'s traps',
	Function = function(callback)
		if OwnColor and OwnColor.Object then OwnColor.Object.Visible = callback end
	end
})
Distance = TrapESP:CreateToggle({
	Name = 'Distance',
	Tooltip = 'Shows how far away each one is',
	Default = true
})
Highlight = TrapESP:CreateToggle({
	Name = 'Highlight',
	Tooltip = 'Also outlines the trap itself',
	Default = true
})
Range = TrapESP:CreateSlider({
	Name = 'Range',
	Tooltip = 'How far away traps are shown',
	Min = 10,
	Max = 500,
	Default = 150,
	Suffix = function(val) return val == 1 and 'stud' or 'studs' end
})
EnemyColor = TrapESP:CreateColorSlider({
	Name = 'Enemy Color',
	Tooltip = 'Colour of enemy traps',
	DefaultHue = 0,
	DefaultSat = 0.65,
	DefaultValue = 1
})
OwnColor = TrapESP:CreateColorSlider({
	Name = 'Own Color',
	Tooltip = 'Colour of your team\'s traps',
	DefaultHue = 0.36,
	DefaultSat = 0.5,
	DefaultValue = 0.9,
	Visible = false
})
