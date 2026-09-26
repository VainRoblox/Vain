local StrafeCooldown
local Duration
local BarColor
local old, hook
local screen, bar, fill, label
local resetAt = 0

-- The weapons whose shots start the timer, matched by a word in the tool name so every
-- skin and variant is covered - tactical and flower headhunters, crossbow reskins - without
-- a list to keep up to date. Anything else in hand is left alone.
local WEAPONS = {'crossbow', 'headhunter'}

local function buildBar()
	screen = Instance.new('Frame')
	screen.Name = 'VainStrafeCooldown'
	screen.AnchorPoint = Vector2.new(0.5, 0.5)
	screen.Position = UDim2.fromScale(0.5, 0.78)
	screen.Size = UDim2.fromOffset(220, 16)
	screen.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
	screen.BackgroundTransparency = 0.35
	screen.BorderSizePixel = 0
	screen.Visible = false
	screen.Parent = vain.gui

	local corner = Instance.new('UICorner')
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = screen

	fill = Instance.new('Frame')
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.fromScale(0, 0.5)
	fill.Size = UDim2.fromScale(1, 1)
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = BarColor and Color3.fromHSV(BarColor.Hue, BarColor.Sat, BarColor.Value) or Color3.fromRGB(90, 170, 255)
	fill.Parent = screen

	local fillcorner = Instance.new('UICorner')
	fillcorner.CornerRadius = UDim.new(0, 4)
	fillcorner.Parent = fill

	label = Instance.new('TextLabel')
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 11
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.5
	label.Parent = screen
end

local function clearBar()
	if screen then
		screen:Destroy()
		screen = nil
		bar, fill, label = nil, nil, nil
	end
end

--[[
	Redrawn every frame while it counts down.

	The fill drains from full to empty over the cooldown and the bar hides once it is up, so
	the moment it disappears is the moment the next shot is ready.
]]
local function step()
	if not (screen and Duration) then return end

	local length = math.max(Duration.Value, 0.05)
	local remaining = resetAt - tick()
	if remaining <= 0 then
		screen.Visible = false
		return
	end

	screen.Visible = true
	fill.Size = UDim2.fromScale(math.clamp(remaining / length, 0, 1), 1)
	label.Text = string.format('%.1fs', remaining)
end

local function heldWeapon()
	local tool = store.hand and store.hand.tool
	if not tool then return false end
	local name = tool.Name:lower()
	for _, word in WEAPONS do
		if name:find(word, 1, true) then return true end
	end
	return false
end

StrafeCooldown = vain.Categories.Combat:CreateModule({
	Name = 'Strafe Cooldown',
	Tooltip = 'Shows a cooldown bar that resets each time you fire your crossbow or headhunter',
	Function = function(callback)
		if callback then
			buildBar()
			StrafeCooldown:Clean(runService.RenderStepped:Connect(step))

			--[[
				Started from the shot itself.

				launchProjectileWithValues is the fire path every projectile takes - separate
				from the aim-value function ProjectileAimbot wraps, so the two do not tread on
				each other - and it runs once per projectile that actually leaves. Gated to the
				crossbow so nothing else in hand starts the timer, and guarded so a fault in
				here can never take the game's own shooting down with it.
			]]
			old = bedwars.ProjectileController.launchProjectileWithValues
			hook = function(...)
				if StrafeCooldown.Enabled then
					pcall(function()
						if heldWeapon() then
							resetAt = tick() + math.max(Duration.Value, 0.05)
						end
					end)
				end
				return old(...)
			end
			bedwars.ProjectileController.launchProjectileWithValues = hook
		else
			-- Restored only when ours is still the installed one, so a wrapper that captured
			-- ours keeps working rather than being cut out.
			if hook and old and bedwars.ProjectileController.launchProjectileWithValues == hook then
				bedwars.ProjectileController.launchProjectileWithValues = old
			end
			hook = nil
			resetAt = 0
			clearBar()
		end
	end
})
Duration = StrafeCooldown:CreateSlider({
	Name = 'Cooldown',
	Tooltip = 'How long the bar takes to refill',
	Min = 0.1,
	Max = 5,
	Default = 1.5,
	Decimal = 10,
	Suffix = function()
		return 's'
	end
})
BarColor = StrafeCooldown:CreateColorSlider({
	Name = 'Bar Color',
	Tooltip = 'Colour of the cooldown bar',
	Darker = true,
	Function = function(hue, sat, val)
		if fill then
			fill.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
		end
	end
})
