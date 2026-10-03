local Keystrokes
local Style
local Color
local ShowSpace, ShowMouse, ShowCPS
local keys, holder = {}
-- Click times per mouse button, for clicks per second over the last second.
local clicks = {[Enum.UserInputType.MouseButton1] = {}, [Enum.UserInputType.MouseButton2] = {}}

local function createKeystroke(keybutton, pos, pos2, text, size)
	if keys[keybutton] then
		keys[keybutton].Key:Destroy()
		keys[keybutton] = nil
	end

	local key = Instance.new('Frame')
	key.Size = size or (keybutton == Enum.KeyCode.Space and UDim2.new(0, 110, 0, 24) or UDim2.new(0, 34, 0, 36))
	key.BackgroundColor3 = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
	key.BackgroundTransparency = 1 - Color.Opacity
	key.Position = pos
	key.Name = keybutton.Name
	key.Parent = holder
	local keytext = Instance.new('TextLabel')
	keytext.BackgroundTransparency = 1
	keytext.Size = UDim2.fromScale(1, 1)
	keytext.Font = Enum.Font.Gotham
	keytext.Text = text or keybutton.Name
	keytext.TextXAlignment = Enum.TextXAlignment.Left
	keytext.TextYAlignment = Enum.TextYAlignment.Top
	keytext.Position = pos2
	keytext.TextSize = keybutton == Enum.KeyCode.Space and 18 or 15
	keytext.TextColor3 = Color3.new(1, 1, 1)
	keytext.Parent = key
	local corner = Instance.new('UICorner')
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = key

	keys[keybutton] = {Key = key}
	return key
end

-- A mouse button: its name, and the clicks per second under it when CPS is on.
local function createMouseKey(button, pos, text)
	local key = createKeystroke(button, pos, UDim2.new(0, 0, 0, 0), '', UDim2.new(0, 53, 0, 36))
	local label = key.TextLabel
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.RichText = true
	keys[button].Label = text
	label.Text = text
end

local function cps(button)
	local list = clicks[button]
	local now = os.clock()
	for i = #list, 1, -1 do
		if now - list[i] > 1 then table.remove(list, i) end
	end
	return #list
end

local function refreshCPS()
	for _, button in {Enum.UserInputType.MouseButton1, Enum.UserInputType.MouseButton2} do
		local key = keys[button]
		if key then
			key.Key.TextLabel.Text = ShowCPS.Enabled
				and string.format('%s\n<font size="11">%d CPS</font>', key.Label, cps(button))
				or key.Label
		end
	end
end

local function updateKey(inputType)
	local isMouse = inputType.UserInputType == Enum.UserInputType.MouseButton1 or inputType.UserInputType == Enum.UserInputType.MouseButton2
	local key = keys[isMouse and inputType.UserInputType or inputType.KeyCode]
	if key then
		if key.Tween then
			key.Tween:Cancel()
		end

		if key.Tween2 then
			key.Tween2:Cancel()
		end

		local pressed = inputType.UserInputState == Enum.UserInputState.Begin
		if pressed and isMouse then
			table.insert(clicks[inputType.UserInputType], os.clock())
			refreshCPS()
		end
		key.Pressed = pressed
		key.Tween = tweenService:Create(key.Key, TweenInfo.new(0.1), {
			BackgroundColor3 = pressed and Color3.new(1, 1, 1) or Color3.fromHSV(Color.Hue, Color.Sat, Color.Value),
			BackgroundTransparency = pressed and 0 or 1 - Color.Opacity
		})
		key.Tween2 = tweenService:Create(key.Key.TextLabel, TweenInfo.new(0.1), {
			TextColor3 = pressed and Color3.new() or Color3.new(1, 1, 1)
		})
		key.Tween:Play()
		key.Tween2:Play()
	end
end

-- Lays the keys out from the settings: WASD, then the spacebar, then the mouse buttons.
local function build()
	for button, key in keys do
		key.Key:Destroy()
		keys[button] = nil
	end
	createKeystroke(Enum.KeyCode.W, UDim2.new(0, 38, 0, 0), UDim2.new(0, 6, 0, 5), Style.Value == 'Arrow' and '↑' or nil)
	createKeystroke(Enum.KeyCode.S, UDim2.new(0, 38, 0, 42), UDim2.new(0, 8, 0, 5), Style.Value == 'Arrow' and '↓' or nil)
	createKeystroke(Enum.KeyCode.A, UDim2.new(0, 0, 0, 42), UDim2.new(0, 7, 0, 5), Style.Value == 'Arrow' and '←' or nil)
	createKeystroke(Enum.KeyCode.D, UDim2.new(0, 76, 0, 42), UDim2.new(0, 8, 0, 5), Style.Value == 'Arrow' and '→' or nil)

	local height = 78
	if ShowSpace.Enabled then
		createKeystroke(Enum.KeyCode.Space, UDim2.new(0, 0, 0, 83), UDim2.new(0, 25, 0, -10), '______')
		height = 107
	end
	if ShowMouse.Enabled then
		local y = height + 4
		createMouseKey(Enum.UserInputType.MouseButton1, UDim2.new(0, 0, 0, y), 'LMB')
		createMouseKey(Enum.UserInputType.MouseButton2, UDim2.new(0, 57, 0, y), 'RMB')
		height = y + 36
		refreshCPS()
	end
	Keystrokes.Children.Size = UDim2.fromOffset(110, height)
end

Keystrokes = vain.Legit:CreateModule({
	Name = 'Keystrokes',
	Function = function(callback)
		if callback then
			build()
			Keystrokes:Clean(inputService.InputBegan:Connect(updateKey))
			Keystrokes:Clean(inputService.InputEnded:Connect(updateKey))
			-- Counts fall back down after you stop clicking.
			Keystrokes:Clean(runService.Heartbeat:Connect(function()
				if ShowMouse.Enabled and ShowCPS.Enabled then refreshCPS() end
			end))
		end
	end,
	Size = UDim2.fromOffset(110, 176),
	Tooltip = 'Shows your keys and clicks onscreen'
})
holder = Instance.new('Frame')
holder.Size = UDim2.fromScale(1, 1)
holder.BackgroundTransparency = 1
holder.Parent = Keystrokes.Children

local function rebuild()
	if Keystrokes.Enabled then build() end
end

Style = Keystrokes:CreateDropdown({
	Name = 'Key Style',
	List = {'Keyboard', 'Arrow'},
	Function = rebuild
})
Color = Keystrokes:CreateColorSlider({
	Name = 'Color',
	DefaultValue = 0,
	DefaultOpacity = 0.5,
	Function = function(hue, sat, val, opacity)
		for _, v in keys do
			if not v.Pressed then
				v.Key.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
				v.Key.BackgroundTransparency = 1 - opacity
			end
		end
	end
})
ShowSpace = Keystrokes:CreateToggle({
	Name = 'Show Spacebar',
	Function = rebuild,
	Default = true
})
ShowMouse = Keystrokes:CreateToggle({
	Name = 'Mouse Buttons',
	Tooltip = 'Shows your left and right clicks',
	Default = true,
	Function = function(callback)
		if ShowCPS and ShowCPS.Object then ShowCPS.Object.Visible = callback end
		rebuild()
	end
})
ShowCPS = Keystrokes:CreateToggle({
	Name = 'CPS',
	Tooltip = 'Clicks per second on each mouse button',
	Default = true,
	Darker = true,
	Function = function()
		refreshCPS()
	end
})
