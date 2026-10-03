--[[
	Low HP Warning.

	Your health is on your character as the Health and MaxHealth attributes. Below the
	threshold the screen edges glow, pulsing faster the lower you go, with your health
	written under the crosshair and a sound as you drop under - played once per drop, not
	on a loop.
]]
local LowHPWarning
local Threshold, Vignette, ShowText, Sound, SoundChoice, Color
local screen, edges, label
local below = false

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

local function update()
	local character = lplr.Character
	local health = character and character:GetAttribute('Health')
	local maxHealth = character and character:GetAttribute('MaxHealth')
	if not (entitylib.isAlive and health and maxHealth and maxHealth > 0) then
		screen.Visible = false
		below = false
		return
	end

	local fraction = health / maxHealth
	local limit = Threshold.Value / 100
	if fraction > limit or health <= 0 then
		screen.Visible = false
		below = false
		return
	end

	if not below and Sound.Enabled then
		pcall(function()
			bedwars.SoundManager:playSound(bedwars.SoundList[SOUNDS[SoundChoice.Value]])
		end)
	end
	below = true

	-- Lower health, faster pulse: from 2 beats a second at the threshold to 6 near death.
	local urgency = 1 - math.clamp(fraction / limit, 0, 1)
	local pulse = 0.5 + 0.5 * math.sin(os.clock() * math.pi * 2 * (2 + urgency * 4))
	local color = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
	local strength = Color.Opacity * (0.55 + 0.45 * pulse)

	for _, edge in edges do
		edge.Visible = Vignette.Enabled
		edge.BackgroundColor3 = color
		edge.BackgroundTransparency = 1 - strength
	end
	label.Visible = ShowText.Enabled
	label.TextColor3 = color
	label.Text = string.format('%d HP', math.ceil(health))
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
Threshold = LowHPWarning:CreateSlider({
	Name = 'Threshold',
	Tooltip = 'Health left when it starts',
	Min = 5,
	Max = 90,
	Default = 35,
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
Sound = LowHPWarning:CreateToggle({
	Name = 'Sound',
	Tooltip = 'Plays a sound when you drop below',
	Default = true,
	Function = function(callback)
		if SoundChoice and SoundChoice.Object then SoundChoice.Object.Visible = callback end
	end
})
SoundChoice = LowHPWarning:CreateDropdown({
	Name = 'Sound Type',
	List = {'Heartbeat', 'Danger', 'Beep'},
	Tooltips = {Heartbeat = 'A heartbeat', Danger = 'The danger ping', Beep = 'A short beep'},
	Darker = true
})
Color = LowHPWarning:CreateColorSlider({
	Name = 'Color',
	Tooltip = 'Colour of the warning',
	DefaultHue = 0,
	DefaultSat = 0.85,
	DefaultValue = 1,
	DefaultOpacity = 0.55
})
