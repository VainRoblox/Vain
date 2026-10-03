--[[
	Bed Alarm.

	The game's own bed alarm team upgrade, without buying it - done locally, the way its
	BedAlarmController does it:

	- an enemy within BedAlarmRadius (35 studs) of your bed sets it off;
	- the game's alarm model (Assets.Effects.BedAlarm) spins 15 studs over the bed, its
	  sides, bulb and glow flashing red and blue every half second, for
	  BedAlarmTriggeredDuration (5 seconds);
	- the alarm sound loops at the bed while you are near it, and the far version plays
	  wherever you are when you are not;
	- the intruder is highlighted red for PlayerHighlightDuration (10 seconds);
	- and, if you want it, the game's own "[Bed Alarm]" message.

	Every one of those numbers is a setting here. Your bed is the one your own team is not
	allowed to break (its Team<id>NoBreak attribute). It stops for good once the bed is gone.
]]
local BedAlarm
local Radius, HeightLimit, MaxHeight, OnlyWhenAway, AwayDistance
local ShowModel, AlarmDuration, Repeat, RepeatDelay
local Sound, Volume, FarSound
local Highlight, HighlightDuration, HighlightColor
local GameMessage
local Folder = Instance.new('Folder')
Folder.Name = 'BedAlarm'
Folder.Parent = vain.gui

local NEAR_SOUND_RANGE = 30
local alarm -- the active alarm: {model, sound, flash, endsAt}
local highlights = {}
local alerted = {} -- intruders already alarmed about, until they leave the radius
local lastTrigger = 0
local cachedBed, cachedAt = nil, 0

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function ownBed()
	if cachedBed and cachedBed.Parent and os.clock() - cachedAt < 2 then return cachedBed end
	cachedBed = nil
	local team = lplr:GetAttribute('Team')
	if team == nil then return nil end
	for _, bed in collectionService:GetTagged('bed') do
		if bed:GetAttribute('Team' .. tostring(team) .. 'NoBreak') then
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

-- The game's colours for the two halves of the flash.
local function paint(model, red)
	pcall(function()
		local sides = model:FindFirstChild('Sides')
		for _, child in (sides and sides:GetChildren() or {}) do
			if child:IsA('BasePart') then
				child.Color = red and Color3.fromRGB(226, 88, 88) or Color3.fromRGB(82, 124, 174)
			end
		end
		local recolor = model:FindFirstChild('Recolor')
		if not recolor then return end
		recolor.Inner.Color = red and Color3.fromRGB(195, 70, 70) or Color3.fromRGB(33, 84, 185)
		recolor.Outer.Color = red and Color3.fromRGB(188, 74, 74) or Color3.fromRGB(82, 124, 174)
		recolor.Bulb.Color = red and Color3.fromRGB(195, 70, 70) or Color3.fromRGB(0, 16, 176)
		recolor.Bulb.GlowAttachment.Glow.Color = ColorSequence.new(red and Color3.fromRGB(255, 0, 0) or Color3.fromRGB(0, 60, 255))
	end)
end

local function stopAlarm()
	if not alarm then return end
	if alarm.model then alarm.model:Destroy() end
	if alarm.sound then pcall(function() alarm.sound:Stop() end) end
	alarm = nil
end

local function highlightIntruder(character)
	local entry = highlights[character]
	if not entry then
		local highlight = Instance.new('Highlight')
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Adornee = character
		highlight.Parent = Folder
		entry = {highlight = highlight}
		highlights[character] = entry
	end
	local color = Color3.fromHSV(HighlightColor.Hue, HighlightColor.Sat, HighlightColor.Value)
	entry.highlight.FillColor = color
	entry.highlight.OutlineColor = color
	entry.highlight.FillTransparency = 1 - HighlightColor.Opacity
	entry.highlight.OutlineTransparency = 0
	entry.endsAt = os.clock() + HighlightDuration.Value
end

local function gameMessage()
	pcall(function()
		local Flamework = require(replicatedStorage['rbxts_include']['node_modules']['@flamework'].core.out).Flamework
		Flamework.resolveDependency('@easy-games/game-core:client/controllers/notification-controller@NotificationController'):sendInfoNotification({
			message = '[Bed Alarm]: An intruder is near your bed!'
		})
	end)
end

local function trigger(position, intruders)
	lastTrigger = os.clock()
	local here = entitylib.isAlive and entitylib.character.RootPart.Position
	local near = here and (here - position).Magnitude < NEAR_SOUND_RANGE

	stopAlarm()
	alarm = {endsAt = os.clock() + AlarmDuration.Value, flashAt = 0, red = true}
	if on(ShowModel) then
		pcall(function()
			local model = replicatedStorage.Assets.Effects.BedAlarm:Clone()
			model:PivotTo(CFrame.new(position + Vector3.new(0, 15, 0)))
			for _, part in model:GetDescendants() do
				if part:IsA('BasePart') then
					part.CanCollide = false
					part.CanQuery = false
					part.CanTouch = false
					part.Anchored = true
				end
			end
			model.Parent = workspace
			alarm.model = model
			alarm.pivot = model:GetPivot()
		end)
	end
	if on(Sound) then
		pcall(function()
			local sound = (near or not on(FarSound)) and bedwars.SoundList.BED_ALARM or bedwars.SoundList.BED_ALARM_TRIGGERED_FAR
			alarm.sound = bedwars.SoundManager:playSound(sound, {
				looped = true,
				volumeMultiplier = Volume.Value / 100,
				position = (near or not on(FarSound)) and position or nil,
				rollOffMaxDistance = 100
			})
		end)
	end
	if on(Highlight) then
		for _, character in intruders do highlightIntruder(character) end
	end
	if on(GameMessage) then gameMessage() end
end

-- The alarm model spins and flashes like the game's, and everything ends on time.
local function animate(dt)
	if alarm then
		if os.clock() >= alarm.endsAt then
			stopAlarm()
		else
			if alarm.model and alarm.pivot then
				alarm.spin = (alarm.spin or 0) + dt * math.rad(270)
				alarm.model:PivotTo(alarm.pivot * CFrame.Angles(0, alarm.spin, 0))
			end
			if alarm.model and os.clock() >= alarm.flashAt then
				alarm.flashAt = os.clock() + 0.5
				alarm.red = not alarm.red
				paint(alarm.model, alarm.red)
			end
		end
	end
	for character, entry in highlights do
		if os.clock() >= entry.endsAt or not character.Parent then
			entry.highlight:Destroy()
			highlights[character] = nil
		end
	end
end

local function check()
	local bed = ownBed()
	if not bed then
		stopAlarm()
		return
	end
	local position = bedPosition(bed)
	if not position then return end

	local here = entitylib.isAlive and entitylib.character.RootPart.Position
	if on(OnlyWhenAway) and here and (here - position).Magnitude < AwayDistance.Value then return end

	local intruders = {}
	for _, entity in entitylib.List do
		if entity.Player and entity.Targetable and entity.RootPart and entity.Character then
			local offset = entity.RootPart.Position - position
			if offset.Magnitude <= Radius.Value and not (on(HeightLimit) and math.abs(offset.Y) > MaxHeight.Value) then
				intruders[#intruders + 1] = entity.Character
			end
		end
	end
	-- Who is new since last time; anyone who left can set it off again later.
	local present, fresh = {}, false
	for _, character in intruders do
		present[character] = true
		if not alerted[character] then fresh = true end
	end
	for character in alerted do
		if not present[character] then alerted[character] = nil end
	end
	if #intruders == 0 then return end

	-- Repeat keeps it going while they stay, after the delay; otherwise only someone new
	-- sets it off.
	local due = on(Repeat) and (fresh or os.clock() - lastTrigger >= RepeatDelay.Value) or fresh
	for _, character in intruders do alerted[character] = true end
	if due then
		trigger(position, intruders)
	elseif on(Highlight) then
		for _, character in intruders do
			if highlights[character] then highlightIntruder(character) end
		end
	end
end

BedAlarm = vain.Categories.Utility:CreateModule({
	Name = 'Bed Alarm',
	Tooltip = 'The game\'s bed alarm, without buying it',
	Function = function(callback)
		if callback then
			local last = 0
			BedAlarm:Clean(runService.Heartbeat:Connect(function(dt)
				pcall(animate, dt)
				if os.clock() - last < 0.2 then return end
				last = os.clock()
				pcall(check)
			end))
		else
			stopAlarm()
			table.clear(alerted)
			for character, entry in highlights do
				entry.highlight:Destroy()
				highlights[character] = nil
			end
		end
	end
})
Radius = BedAlarm:CreateSlider({
	Name = 'Radius',
	Tooltip = 'How close an enemy has to get (game: 35)',
	Min = 5,
	Max = 120,
	Default = 35,
	Suffix = function(val) return val == 1 and 'stud' or 'studs' end
})
HeightLimit = BedAlarm:CreateToggle({
	Name = 'Height Limit',
	Tooltip = 'Ignores enemies far above or below the bed',
	Function = function(callback)
		if MaxHeight and MaxHeight.Object then MaxHeight.Object.Visible = callback end
	end
})
MaxHeight = BedAlarm:CreateSlider({
	Name = 'Max Height',
	Tooltip = 'How far above or below still counts',
	Min = 3,
	Max = 60,
	Default = 15,
	Darker = true,
	Visible = false,
	Suffix = function(val) return val == 1 and 'stud' or 'studs' end
})
OnlyWhenAway = BedAlarm:CreateToggle({
	Name = 'Only When Away',
	Tooltip = 'Stays quiet while you are at your bed',
	Function = function(callback)
		if AwayDistance and AwayDistance.Object then AwayDistance.Object.Visible = callback end
	end
})
AwayDistance = BedAlarm:CreateSlider({
	Name = 'Away Distance',
	Tooltip = 'How far from the bed counts as away',
	Min = 5,
	Max = 100,
	Default = 25,
	Darker = true,
	Visible = false,
	Suffix = function(val) return val == 1 and 'stud' or 'studs' end
})
AlarmDuration = BedAlarm:CreateSlider({
	Name = 'Alarm Duration',
	Tooltip = 'How long it goes off (game: 5s)',
	Min = 1,
	Max = 20,
	Default = 5,
	Suffix = function() return 's' end
})
Repeat = BedAlarm:CreateToggle({
	Name = 'Repeat While Near',
	Tooltip = 'Keeps going off while they stay',
	Default = true,
	Function = function(callback)
		if RepeatDelay and RepeatDelay.Object then RepeatDelay.Object.Visible = callback end
	end
})
RepeatDelay = BedAlarm:CreateSlider({
	Name = 'Repeat Delay',
	Tooltip = 'Seconds between going off again',
	Min = 1,
	Max = 30,
	Default = 5,
	Darker = true,
	Suffix = function() return 's' end
})
ShowModel = BedAlarm:CreateToggle({
	Name = 'Alarm Light',
	Tooltip = 'The game\'s spinning alarm over your bed',
	Default = true
})
Sound = BedAlarm:CreateToggle({
	Name = 'Sound',
	Tooltip = 'The game\'s alarm sound',
	Default = true,
	Function = function(callback)
		for _, setting in {Volume, FarSound} do
			if setting and setting.Object then setting.Object.Visible = callback end
		end
	end
})
Volume = BedAlarm:CreateSlider({
	Name = 'Volume',
	Tooltip = 'How loud it is',
	Min = 10,
	Max = 300,
	Default = 75,
	Darker = true,
	Suffix = function() return '%' end
})
FarSound = BedAlarm:CreateToggle({
	Name = 'Far Sound',
	Tooltip = 'Plays the distant alarm when you are away',
	Default = true,
	Darker = true
})
Highlight = BedAlarm:CreateToggle({
	Name = 'Highlight Intruder',
	Tooltip = 'Outlines whoever set it off',
	Default = true,
	Function = function(callback)
		for _, setting in {HighlightDuration, HighlightColor} do
			if setting and setting.Object then setting.Object.Visible = callback end
		end
	end
})
HighlightDuration = BedAlarm:CreateSlider({
	Name = 'Highlight Time',
	Tooltip = 'How long they stay outlined (game: 10s)',
	Min = 1,
	Max = 30,
	Default = 10,
	Darker = true,
	Suffix = function() return 's' end
})
HighlightColor = BedAlarm:CreateColorSlider({
	Name = 'Highlight Color',
	Tooltip = 'Colour of the outline',
	DefaultHue = 0,
	DefaultSat = 0.86,
	DefaultValue = 0.8,
	DefaultOpacity = 0.3,
	Darker = true
})
GameMessage = BedAlarm:CreateToggle({
	Name = 'Game Message',
	Tooltip = 'Shows the game\'s own bed alarm message'
})
