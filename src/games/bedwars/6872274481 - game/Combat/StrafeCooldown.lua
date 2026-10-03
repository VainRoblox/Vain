local StrafeCooldown
local Duration
local ItemCooldown
local BarColor
local old, hook
local cooldownController, oldCooldown, cooldownHook
local screen, bar, fill, label
local resetAt = 0
local length = 1

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

	local remaining = resetAt - tick()
	if remaining <= 0 then
		screen.Visible = false
		return
	end

	screen.Visible = true
	fill.Size = UDim2.fromScale(math.clamp(remaining / length, 0, 1), 1)
	label.Text = string.format('%.1fs', remaining)
end

-- Anything in hand that fires a projectile - bows, crossbows, headhunters, fireballs,
-- pearls, kit items - with the id the game puts its shot cooldown under
-- (ProjectileSourceController:getCooldownId).
local function heldSource()
	local tool = store.hand and store.hand.tool
	local meta = tool and bedwars.ItemMeta[tool.Name]
	local source = meta and meta.projectileSource
	if not source then return nil end
	return source, source.cooldownId or (tool.Name .. '-proj-source')
end

local function start(seconds)
	length = math.max(seconds, 0.05)
	resetAt = tick() + length
end

local function getCooldownController()
	if cooldownController then return cooldownController end
	local ok, controller = pcall(function()
		local Flamework = require(replicatedStorage['rbxts_include']['node_modules']['@flamework'].core.out).Flamework
		return Flamework.resolveDependency('@easy-games/game-core:client/controllers/cooldown/cooldown-controller@CooldownController')
	end)
	cooldownController = ok and controller or nil
	return cooldownController
end

StrafeCooldown = vain.Categories.Combat:CreateModule({
	Name = 'Strafe Cooldown',
	Tooltip = 'Shows a cooldown bar that resets each time you fire',
	Function = function(callback)
		if callback then
			buildBar()
			StrafeCooldown:Clean(runService.RenderStepped:Connect(step))

			--[[
				Started from the shot itself.

				launchProjectileWithValues is the fire path every projectile takes - separate
				from the aim-value function ProjectileAimbot wraps, so the two do not tread on
				each other - and it runs once per projectile that actually leaves. Gated to the
				projectile items so nothing else in hand starts the timer, and guarded so a
				fault in here can never take the game's own shooting down with it.
			]]
			local original = bedwars.ProjectileController.launchProjectileWithValues
			old = original
			hook = function(...)
				if StrafeCooldown.Enabled and not ItemCooldown.Enabled then
					pcall(function()
						if heldSource() then start(Duration.Value) end
					end)
				end
				return original(...)
			end
			bedwars.ProjectileController.launchProjectileWithValues = hook

			--[[
				Item Cooldown takes the time from the game itself: after every shot it puts the
				weapon on cooldown with CooldownController:setOnCooldown(id, seconds), the
				seconds already through the kit modifiers and overrides - so the bar runs
				exactly as long as the weapon is really waiting.
			]]
			local controller = getCooldownController()
			local originalCooldown = controller and controller.setOnCooldown
			if type(originalCooldown) == 'function' then
				oldCooldown = originalCooldown
				cooldownHook = function(self, id, seconds, ...)
					if StrafeCooldown.Enabled and ItemCooldown.Enabled then
						pcall(function()
							local source, cooldownId = heldSource()
							if source and id == cooldownId and type(seconds) == 'number' and seconds > 0 then
								start(seconds)
							end
						end)
					end
					return originalCooldown(self, id, seconds, ...)
				end
				controller.setOnCooldown = cooldownHook
			end
		else
			-- Restored only when ours is still the installed one, so a wrapper that captured
			-- ours keeps working rather than being cut out.
			if hook and old and bedwars.ProjectileController.launchProjectileWithValues == hook then
				bedwars.ProjectileController.launchProjectileWithValues = old
			end
			hook = nil
			if cooldownHook and cooldownController and cooldownController.setOnCooldown == cooldownHook then
				cooldownController.setOnCooldown = oldCooldown
			end
			cooldownHook = nil
			resetAt = 0
			clearBar()
		end
	end
})
ItemCooldown = StrafeCooldown:CreateToggle({
	Name = 'Item Cooldown',
	Tooltip = 'Uses each item\'s own cooldown',
	Function = function(callback)
		if Duration and Duration.Object then Duration.Object.Visible = not callback end
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
