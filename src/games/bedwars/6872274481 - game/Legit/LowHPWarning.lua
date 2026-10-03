--[[
	Low HP Warning.

	Your health is on your character as the Health and MaxHealth attributes. Below the
	threshold - a share of your max health or a flat amount - the screen edges glow,
	pulsing faster the lower you go, with your health written under the crosshair and a
	sound as you drop under, once or repeating. Below the critical level it pulses harder
	and faster still.
]]
local LowHPWarning
local Mode, Threshold, ThresholdHP, Critical, CriticalPercent, CriticalHP
local Vignette, ShowText, Sound, SoundChoice, Volume, Repeat, RepeatEvery, HideSpectate, PulseSpeed, Color
local screen, edges, label
local below, lastSound = false, 0

local SOUNDS = {
	Heartbeat = 'WEREWOLF_HEARTBEAT',
	Danger = 'PING_DANGER',
	Beep = 'METAL_DETECTOR_BEEP'
}

local function build()
	screen = Instance.new('Frame')
	screen.Name = 'LowHPWarning'
	screen.Size = UDim2.fromScale(1, 1)
	screen.BackgroundTransparency = 1
	screen.Visible = false
	screen.Parent = vain.gui

	-- Four edge strips fading towards the middle of the screen.
	edges = {}
	for _, side in {{0, 0, 1, 0.22, 90}, {0, 0.78, 1, 0.22, -90}, {0, 0, 0.16, 1, 0}, {0.84, 0, 0.16, 1, 180}} do
		local frame = Instance.new('Frame')
		frame.Position = UDim2.fromScale(side[1], side[2])
		frame.Size = UDim2.fromScale(side[3], side[4])
		frame.BorderSizePixel = 0
		frame.Parent = screen
		local gradient = Instance.new('UIGradient')
		gradient.Rotation = side[5]
		gradient.Transparency = NumberSequence.new(0, 1)
		gradient.Parent = frame
		edges[#edges + 1] = frame
	end

	label = Instance.new('TextLabel')
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0.5, 40)
	label.Size = UDim2.fromOffset(200, 24)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 18
	label.TextStrokeTransparency = 0.4
	label.Parent = screen
end

local function playSound()
	pcall(function()
		bedwars.SoundManager:playSound(bedwars.SoundList[SOUNDS[SoundChoice.Value]], {volumeMultiplier = Volume.Value / 100})
	end)
	lastSound = os.clock()
end

local function off()
	screen.Visible = false
	below = false
end

local function update()
	local character = lplr.Character
	local health = character and character:GetAttribute('Health')
	local maxHealth = character and character:GetAttribute('MaxHealth')
	if not (entitylib.isAlive and health and maxHealth and maxHealth > 0) or health <= 0 then
		return off()
	end
	if HideSpectate.Enabled and lplr:GetAttribute('Spectator') then
		return off()
	end

	-- The thresholds in health points, whichever way they are set.
	local byHP = Mode.Value == 'HP'
	local limit = byHP and ThresholdHP.Value or maxHealth * Threshold.Value / 100
	local critical = Critical.Enabled and (byHP and CriticalHP.Value or maxHealth * CriticalPercent.Value / 100) or -1
	if health > limit then
		return off()
	end

	if Sound.Enabled and (not below or (Repeat.Enabled and os.clock() - lastSound >= RepeatEvery.Value)) then
		playSound()
	end
	below = true

	-- Lower health, faster pulse: from 2 beats a second at the threshold to 6 near death,
	-- scaled by Pulse Speed; below critical, half again faster and at full strength.
	local isCritical = health <= critical
	local urgency = 1 - math.clamp(health / math.max(limit, 1), 0, 1)
	local rate = (2 + urgency * 4) * (PulseSpeed.Value / 100) * (isCritical and 1.5 or 1)
	local pulse = 0.5 + 0.5 * math.sin(os.clock() * math.pi * 2 * rate)
	local color = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
	local strength = (isCritical and 1 or Color.Opacity) * (0.55 + 0.45 * pulse)

	for _, edge in edges do
		edge.Visible = Vignette.Enabled
		edge.BackgroundColor3 = color
		edge.BackgroundTransparency = 1 - strength
	end
	label.Visible = ShowText.Enabled
	label.TextColor3 = color
	label.Text = string.format(isCritical and 'CRITICAL  %d HP' or '%d HP', math.ceil(health))
	screen.Visible = true
end

LowHPWarning = vain.Legit:CreateModule({
	Name = 'Low HP Warning',
	Function = function(callback)
		if callback then
			build()
			LowHPWarning:Clean(screen)
			LowHPWarning:Clean(runService.RenderStepped:Connect(function()
				pcall(update)
			end))
		else
			below = false
		end
	end,
	Tooltip = 'Warns you when your health gets low'
})
Mode = LowHPWarning:CreateDropdown({
	Name = 'Mode',
	List = {'Percent', 'HP'},
	Tooltips = {Percent = 'Thresholds as a share of your max health', HP = 'Thresholds in health points'},
	Function = function(val)
		local byHP = val == 'HP'
		local critical = Critical and Critical.Enabled
		if Threshold and Threshold.Object then Threshold.Object.Visible = not byHP end
		if ThresholdHP and ThresholdHP.Object then ThresholdHP.Object.Visible = byHP end
		if CriticalPercent and CriticalPercent.Object then CriticalPercent.Object.Visible = critical and not byHP end
		if CriticalHP and CriticalHP.Object then CriticalHP.Object.Visible = critical and byHP end
	end
})
Threshold = LowHPWarning:CreateSlider({
	Name = 'Threshold',
	Tooltip = 'Health left when it starts',
	Min = 5,
	Max = 90,
	Default = 35,
	Suffix = function() return '%' end
})
ThresholdHP = LowHPWarning:CreateSlider({
	Name = 'Threshold HP',
	Tooltip = 'Health left when it starts',
	Min = 1,
	Max = 100,
	Default = 35,
	Visible = false,
	Suffix = function() return ' HP' end
})
Critical = LowHPWarning:CreateToggle({
	Name = 'Critical',
	Tooltip = 'A stronger warning when very low',
	Default = true,
	Function = function(callback)
		local byHP = Mode and Mode.Value == 'HP'
		if CriticalPercent and CriticalPercent.Object then CriticalPercent.Object.Visible = callback and not byHP end
		if CriticalHP and CriticalHP.Object then CriticalHP.Object.Visible = callback and byHP end
	end
})
CriticalPercent = LowHPWarning:CreateSlider({
	Name = 'Critical Level',
	Tooltip = 'Health left when it turns critical',
	Min = 1,
	Max = 50,
	Default = 15,
	Darker = true,
	Suffix = function() return '%' end
})
CriticalHP = LowHPWarning:CreateSlider({
	Name = 'Critical HP',
	Tooltip = 'Health left when it turns critical',
	Min = 1,
	Max = 50,
	Default = 15,
	Darker = true,
	Visible = false,
	Suffix = function() return ' HP' end
})
PulseSpeed = LowHPWarning:CreateSlider({
	Name = 'Pulse Speed',
	Tooltip = 'How fast it pulses',
	Min = 25,
	Max = 300,
	Default = 100,
	Suffix = function() return '%' end
})
Vignette = LowHPWarning:CreateToggle({
	Name = 'Vignette',
	Tooltip = 'Makes the screen edges glow',
	Default = true
})
ShowText = LowHPWarning:CreateToggle({
	Name = 'Text',
	Tooltip = 'Shows your health under the crosshair',
	Default = true
})
HideSpectate = LowHPWarning:CreateToggle({
	Name = 'Hide In Spectate',
	Tooltip = 'No warning while spectating',
	Default = true
})
Sound = LowHPWarning:CreateToggle({
	Name = 'Sound',
	Tooltip = 'Plays a sound when you drop below',
	Default = true,
	Function = function(callback)
		for _, setting in {SoundChoice, Volume, Repeat, RepeatEvery} do
			if setting and setting.Object then setting.Object.Visible = callback end
		end
		if callback and RepeatEvery and RepeatEvery.Object then RepeatEvery.Object.Visible = Repeat and Repeat.Enabled end
	end
})
SoundChoice = LowHPWarning:CreateDropdown({
	Name = 'Sound Type',
	List = {'Heartbeat', 'Danger', 'Beep'},
	Tooltips = {Heartbeat = 'A heartbeat', Danger = 'The danger ping', Beep = 'A short beep'},
	Darker = true
})
Volume = LowHPWarning:CreateSlider({
	Name = 'Volume',
	Tooltip = 'How loud the sound is',
	Min = 10,
	Max = 300,
	Default = 100,
	Darker = true,
	Suffix = function() return '%' end
})
Repeat = LowHPWarning:CreateToggle({
	Name = 'Repeat',
	Tooltip = 'Keeps playing while you stay low',
	Darker = true,
	Function = function(callback)
		if RepeatEvery and RepeatEvery.Object then RepeatEvery.Object.Visible = callback and Sound and Sound.Enabled end
	end
})
RepeatEvery = LowHPWarning:CreateSlider({
	Name = 'Repeat Every',
	Tooltip = 'Seconds between sounds',
	Min = 0.5,
	Max = 10,
	Default = 2,
	Decimal = 10,
	Darker = true,
	Visible = false,
	Suffix = function() return 's' end
})
Color = LowHPWarning:CreateColorSlider({
	Name = 'Color',
	Tooltip = 'Colour of the warning',
	DefaultHue = 0,
	DefaultSat = 0.85,
	DefaultValue = 1,
	DefaultOpacity = 0.55
})
