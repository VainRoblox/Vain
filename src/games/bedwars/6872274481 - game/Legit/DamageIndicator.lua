--[[
	Damage Indicator.

	Every damage number the game pops up is a part called DamageIndicatorPart carrying a
	billboard with the number on a label - heals the same, with a + in front. Each one is
	restyled the moment it appears: font, colour, size, outline and how far away it shows.

	The old version did this by rewriting constants inside the game's function at fixed
	positions, which is exactly what breaks the day the game is updated. Restyling the label
	the game hands out does not depend on how that function is written.
]]
local DamageIndicator
local FontOption, CustomColor, DamageColor, HealColor, ShowHeals, Size, Stroke, ThroughWalls, Unlimited

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function colorOf(setting, fallback)
	if not setting then return fallback end
	return Color3.fromHSV(setting.Hue or 0, setting.Sat or 0, setting.Value or 1)
end

local function style(part)
	if not (DamageIndicator.Enabled and part.Parent) then return end
	local billboard = part:FindFirstChildWhichIsA('BillboardGui')
	local label = billboard and billboard:FindFirstChildWhichIsA('TextLabel', true)
	if not label then return end

	local heal = label.Text:sub(1, 1) == '+'
	if heal and not on(ShowHeals) then
		part:Destroy()
		return
	end

	if FontOption then
		pcall(function() label.Font = Enum.Font[FontOption.Value] end)
	end
	if on(CustomColor) then
		-- A charged hit can come with its own gradient, which would paint over the colour.
		local gradient = label:FindFirstChildOfClass('UIGradient')
		if gradient then gradient:Destroy() end
		label.TextColor3 = heal and colorOf(HealColor, Color3.fromRGB(90, 230, 110)) or colorOf(DamageColor, Color3.fromRGB(255, 80, 80))
	end

	local stroke = label:FindFirstChildOfClass('UIStroke')
	if stroke then
		stroke.Enabled = on(Stroke)
		if on(Stroke) and stroke.Thickness < 1 then stroke.Thickness = 1.5 end
	end

	local scale = (Size and Size.Value or 100) / 100
	billboard.Size = UDim2.new(billboard.Size.X.Scale * scale, billboard.Size.X.Offset * scale, billboard.Size.Y.Scale * scale, billboard.Size.Y.Offset * scale)
	billboard.AlwaysOnTop = on(ThroughWalls)
	if on(Unlimited) then billboard.MaxDistance = math.huge end
end

DamageIndicator = vain.Legit:CreateModule({
	Name = 'Damage Indicator',
	Tooltip = 'Customise the damage numbers that pop up when you hit',
	Function = function(callback)
		if callback then
			DamageIndicator:Clean(workspace.DescendantAdded:Connect(function(descendant)
				if descendant.Name == 'DamageIndicatorPart' then
					-- Its billboard and label are built before or just after it is placed.
					task.defer(style, descendant)
				end
			end))
		end
	end
})

local fonts = {'GothamBlack'}
for _, font in Enum.Font:GetEnumItems() do
	if font.Name ~= 'GothamBlack' and font.Name ~= 'Unknown' then
		fonts[#fonts + 1] = font.Name
	end
end
FontOption = DamageIndicator:CreateDropdown({
	Name = 'Font',
	Tooltip = 'Font of the numbers',
	List = fonts
})
Size = DamageIndicator:CreateSlider({
	Name = 'Size',
	Tooltip = 'How big the numbers are',
	Min = 50,
	Max = 250,
	Default = 100,
	Suffix = function() return '%' end
})
CustomColor = DamageIndicator:CreateToggle({
	Name = 'Custom Color',
	Tooltip = 'Uses your own colours instead of the game\'s',
	Function = function(callback)
		for _, setting in {DamageColor, HealColor} do
			if setting and setting.Object then setting.Object.Visible = callback end
		end
	end
})
DamageColor = DamageIndicator:CreateColorSlider({
	Name = 'Damage Color',
	Tooltip = 'Colour of damage numbers',
	DefaultHue = 0,
	DefaultSat = 0.7,
	DefaultValue = 1,
	Darker = true,
	Visible = false
})
HealColor = DamageIndicator:CreateColorSlider({
	Name = 'Heal Color',
	Tooltip = 'Colour of heal numbers',
	DefaultHue = 0.36,
	DefaultSat = 0.6,
	DefaultValue = 0.9,
	Darker = true,
	Visible = false
})
ShowHeals = DamageIndicator:CreateToggle({
	Name = 'Show Heals',
	Tooltip = 'Also shows the + numbers when someone heals',
	Default = true
})
Stroke = DamageIndicator:CreateToggle({
	Name = 'Outline',
	Tooltip = 'Draws a dark outline around the numbers',
	Default = true
})
ThroughWalls = DamageIndicator:CreateToggle({
	Name = 'Through Walls',
	Tooltip = 'Shows numbers even behind blocks',
	Default = true
})
Unlimited = DamageIndicator:CreateToggle({
	Name = 'No Distance Limit',
	Tooltip = 'Keeps numbers visible further than the game\'s 100 studs'
})
