--[[
	Bed Alarm.

	Warns you when an enemy comes for your bed, in two stages: a Warning range further out
	for someone heading your way, and a Danger range for someone who is actually there. It
	says who (in their team's colour), how far, how soon they will arrive, and what they are
	holding when it matters - a pearl, TNT, a fireball or something that breaks beds.

	Better than the old one in the ways that decide whether you go back: people only passing
	by are left out unless you ask for them, it keeps quiet while you are standing at your
	bed yourself, it reads the threat in their hand, and it stops for good once your bed is
	gone. Your bed is the one your own team is not allowed to break, the same attribute the
	game and BedPlates use.
]]
local BedAlarm
local WarnRange, DangerRange, OnlyApproaching, OnlyWhenAway, AwayDistance
local PearlCheck, PearlRange, ShowThreats, ShowKit, ShowDistance
local Repeat, RepeatDelay
local Highlight, HighlightColor
local Sound, SoundVolume, CustomSound, SoundId
local Folder = Instance.new('Folder')
Folder.Parent = vain.gui
local state = {}
local highlights = {}
local cachedBed, cachedAt = nil, 0
local lastSound = 0
local customSound

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function myTeam()
	local team = lplr:GetAttribute('Team')
	return team ~= nil and tostring(team) or nil
end

local function ownBed()
	if cachedBed and cachedBed.Parent and os.clock() - cachedAt < 2 then return cachedBed end
	cachedBed = nil
	local team = myTeam()
	if not team then return nil end
	for _, bed in collectionService:GetTagged('bed') do
		if bed:GetAttribute('Team' .. team .. 'NoBreak') then
			cachedBed, cachedAt = bed, os.clock()
			return bed
		end
	end
end

local function bedPosition(bed)
	if bed:IsA('BasePart') then return bed.Position end
	local ok, pivot = pcall(bed.GetPivot, bed)
	return ok and pivot.Position or nil
end

local function displayName(itemType)
	local meta = bedwars.ItemMeta[itemType]
	return meta and meta.displayName or itemType
end

-- What in their hand is a threat to a bed, or nil when nothing is.
local function threatOf(plr)
	local inventory = store.inventories[plr]
	local hand = inventory and inventory.hand
	local itemType = type(hand) == 'table' and hand.itemType
	if type(itemType) ~= 'string' then return nil end

	local lower = itemType:lower()
	if lower:find('pearl', 1, true) or lower:find('fireball', 1, true) or lower:find('tnt', 1, true) then
		return displayName(itemType), lower:find('pearl', 1, true) ~= nil
	end
	local meta = bedwars.ItemMeta[itemType]
	if meta and meta.breakBlock then
		return displayName(itemType), false
	end
end

local function kitOf(plr)
	local kit = plr:GetAttribute('PlayingAsKit') or plr:GetAttribute('PlayingAsKits')
	if type(kit) ~= 'string' or kit == '' or kit == 'none' then return nil end
	local meta = bedwars.BedwarsKitMeta[kit]
	return meta and meta.name or kit
end

local function playAlarm()
	if not on(Sound) or os.clock() - lastSound < 1.5 then return end
	lastSound = os.clock()

	if on(CustomSound) and SoundId.Value ~= '' then
		pcall(function()
			customSound = customSound or Instance.new('Sound')
			local id = SoundId.Value
			customSound.SoundId = tonumber(id) and ('rbxassetid://' .. id) or id
			customSound.Volume = SoundVolume.Value
			game:GetService('SoundService'):PlayLocalSound(customSound)
		end)
		return
	end
	pcall(function()
		bedwars.SoundManager:playSound(bedwars.SoundList.BED_ALARM, {volumeMultiplier = SoundVolume.Value})
	end)
end

local function setHighlight(ent, level)
	local highlight = highlights[ent]
	if level > 0 and on(Highlight) and ent.Character then
		if not (highlight and highlight.Parent) then
			highlight = Instance.new('Highlight')
			highlight.Name = 'BedAlarm'
			highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			highlight.Parent = Folder
			highlights[ent] = highlight
		end
		local color = Color3.fromHSV(HighlightColor.Hue or 0, HighlightColor.Sat or 0.9, HighlightColor.Value or 1)
		highlight.Adornee = ent.Character
		highlight.FillColor = color
		highlight.OutlineColor = color
		-- Fainter while they are only heading your way, solid once they are at the bed.
		highlight.FillTransparency = level == 2 and 0.45 or 0.75
		highlight.OutlineTransparency = 0
	elseif highlight then
		highlight:Destroy()
		highlights[ent] = nil
	end
end

local function clearAll()
	for ent in highlights do
		setHighlight(ent, 0)
	end
	table.clear(state)
end

local function announce(ent, level, distance, closing, threat)
	local name = itemAlerts.playerName(ent.Player)
	local text
	if level == 2 then
		text = name .. ' is at your bed'
	else
		text = name .. ' is heading for your bed'
	end

	local details = {}
	if on(ShowDistance) then
		details[#details + 1] = math.floor(distance) .. ' studs'
		if level == 1 and closing > 2 then
			details[#details + 1] = '~' .. math.max(1, math.floor(distance / closing + 0.5)) .. 's'
		end
	end
	if #details > 0 then text = text .. ' (' .. table.concat(details, ', ') .. ')' end
	if threat and on(ShowThreats) then text = text .. ' with ' .. threat end
	if on(ShowKit) then
		local kit = kitOf(ent.Player)
		if kit then text = text .. ' - ' .. kit end
	end

	notif('Bed Alarm', text, level == 2 and 5 or 4, level == 2 and 'alert' or 'warning')
	playAlarm()
end

local function check()
	local team = myTeam()
	-- No bed to guard any more, or none found yet.
	if not team or brokenbeds[team] or brokenbeds[tonumber(team)] then
		clearAll()
		return
	end
	local bed = ownBed()
	local center = bed and bedPosition(bed)
	if not center then
		clearAll()
		return
	end

	-- You are there yourself: nothing to be told.
	if on(OnlyWhenAway) and entitylib.isAlive
		and (entitylib.character.RootPart.Position - center).Magnitude <= AwayDistance.Value then
		clearAll()
		return
	end

	local now = os.clock()
	local seen = {}
	for _, ent in entitylib.List do
		local root = ent.RootPart
		if ent.Player and ent.Targetable and root and root.Parent then
			local offset = center - root.Position
			local distance = offset.Magnitude
			local closing = distance > 0 and root.AssemblyLinearVelocity:Dot(offset.Unit) or 0
			local threat, pearl = threatOf(ent.Player)

			local level = 0
			if distance <= DangerRange.Value then
				level = 2
			elseif distance <= WarnRange.Value and (closing > 2 or not on(OnlyApproaching)) then
				level = 1
			elseif pearl and on(PearlCheck) and distance <= PearlRange.Value then
				-- A pearl closes any gap in one throw, so its holder counts from much further.
				level = 1
			end

			if level > 0 then
				seen[ent] = true
				local entry = state[ent] or {level = 0, at = 0}
				if level > entry.level or (on(Repeat) and now - entry.at >= RepeatDelay.Value) then
					announce(ent, level, distance, closing, threat)
					entry.at = now
				end
				entry.level = level
				state[ent] = entry
			end
			setHighlight(ent, level)
		end
	end

	-- Whoever has left the ranges starts over, so coming back is said again.
	for ent in state do
		if not seen[ent] then
			state[ent] = nil
			setHighlight(ent, 0)
		end
	end
	for ent in highlights do
		if not seen[ent] then setHighlight(ent, 0) end
	end
end

BedAlarm = vain.Categories.Utility:CreateModule({
	Name = 'Bed Alarm',
	Tooltip = 'Warns you when enemies come for your bed',
	Function = function(callback)
		if callback then
			cachedBed = nil
			repeat
				-- Guarded so one unreadable player cannot stop the alarm.
				pcall(check)
				task.wait(0.1)
			until not BedAlarm.Enabled
			clearAll()
		else
			clearAll()
		end
	end
})
WarnRange = BedAlarm:CreateSlider({
	Name = 'Warning Range',
	Tooltip = 'How far out someone heading for your bed is noticed',
	Min = 10,
	Max = 120,
	Default = 50,
	Suffix = function(val) return val == 1 and 'stud' or 'studs' end
})
DangerRange = BedAlarm:CreateSlider({
	Name = 'Danger Range',
	Tooltip = 'How close counts as at your bed',
	Min = 5,
	Max = 60,
	Default = 18,
	Suffix = function(val) return val == 1 and 'stud' or 'studs' end
})
OnlyApproaching = BedAlarm:CreateToggle({
	Name = 'Only Approaching',
	Tooltip = 'Warning range only counts people moving toward your bed',
	Default = true
})
OnlyWhenAway = BedAlarm:CreateToggle({
	Name = 'Only When Away',
	Tooltip = 'Stays quiet while you are at your bed',
	Default = true,
	Function = function(callback)
		if AwayDistance and AwayDistance.Object then AwayDistance.Object.Visible = callback end
	end
})
AwayDistance = BedAlarm:CreateSlider({
	Name = 'Away Distance',
	Tooltip = 'How far from your bed counts as away',
	Min = 5,
	Max = 80,
	Default = 25,
	Darker = true,
	Suffix = function(val) return val == 1 and 'stud' or 'studs' end
})
PearlCheck = BedAlarm:CreateToggle({
	Name = 'Pearl Check',
	Tooltip = 'Warns about pearl holders from further away',
	Default = true,
	Function = function(callback)
		if PearlRange and PearlRange.Object then PearlRange.Object.Visible = callback end
	end
})
PearlRange = BedAlarm:CreateSlider({
	Name = 'Pearl Range',
	Tooltip = 'How far a pearl holder is noticed from',
	Min = 20,
	Max = 200,
	Default = 90,
	Darker = true,
	Suffix = function(val) return val == 1 and 'stud' or 'studs' end
})
ShowThreats = BedAlarm:CreateToggle({
	Name = 'Show Threats',
	Tooltip = 'Says if they hold a pearl, TNT, fireball or a tool',
	Default = true
})
ShowDistance = BedAlarm:CreateToggle({
	Name = 'Show Distance',
	Tooltip = 'Says how far away they are and how soon they arrive',
	Default = true
})
ShowKit = BedAlarm:CreateToggle({
	Name = 'Show Kit',
	Tooltip = 'Says which kit they are playing'
})
Repeat = BedAlarm:CreateToggle({
	Name = 'Repeat',
	Tooltip = 'Keeps warning while they stay near',
	Function = function(callback)
		if RepeatDelay and RepeatDelay.Object then RepeatDelay.Object.Visible = callback end
	end
})
RepeatDelay = BedAlarm:CreateSlider({
	Name = 'Repeat Delay',
	Tooltip = 'Seconds between repeated warnings',
	Min = 1,
	Max = 30,
	Default = 5,
	Darker = true,
	Visible = false,
	Suffix = function() return 's' end
})
Highlight = BedAlarm:CreateToggle({
	Name = 'Highlight',
	Tooltip = 'Outlines enemies near your bed',
	Default = true,
	Function = function(callback)
		if HighlightColor and HighlightColor.Object then HighlightColor.Object.Visible = callback end
		if not callback then
			for ent in highlights do setHighlight(ent, 0) end
		end
	end
})
HighlightColor = BedAlarm:CreateColorSlider({
	Name = 'Highlight Color',
	Tooltip = 'Colour of the outline',
	DefaultHue = 0,
	DefaultSat = 0.9,
	DefaultValue = 1,
	Darker = true
})
Sound = BedAlarm:CreateToggle({
	Name = 'Sound',
	Tooltip = 'Plays the bed alarm sound with each warning',
	Default = true,
	Function = function(callback)
		for _, setting in {SoundVolume, CustomSound} do
			if setting and setting.Object then setting.Object.Visible = callback end
		end
		if SoundId and SoundId.Object then SoundId.Object.Visible = callback and on(CustomSound) end
	end
})
SoundVolume = BedAlarm:CreateSlider({
	Name = 'Volume',
	Tooltip = 'How loud the alarm is',
	Min = 0.1,
	Max = 3,
	Default = 1,
	Decimal = 10,
	Darker = true
})
CustomSound = BedAlarm:CreateToggle({
	Name = 'Custom Sound',
	Tooltip = 'Plays a Roblox sound of your choice instead',
	Darker = true,
	Function = function(callback)
		if SoundId and SoundId.Object then SoundId.Object.Visible = callback and on(Sound) end
	end
})
SoundId = BedAlarm:CreateTextBox({
	Name = 'Sound ID',
	Tooltip = 'Roblox sound id to play',
	Default = '',
	Darker = true,
	Visible = false
})
