--[[
	Hotbar.

	Recolours the game's hotbar. Each slot's tile is a frame the game paints #1D242E with a
	lighter border, so tiles are found by that colour the first time they are seen and
	remembered; which one is selected comes from your hotbar slot (store.inventory
	.hotbarSlot) and the tiles' order across the screen. The health bar is
	HotbarHealthbarContainer, its fill the first frame inside HealthbarProgressWrapper.

	Roact only writes a property again when its own value for it changes, so the colours set
	here mostly stay; they are put back on a short interval in case a tile is redrawn.
]]
local Hotbar
local SlotColor, SelectedColor, BorderColor, SelectedBorder, RecolorHealth, HealthGradient, HealthColor, HealthBack
local tiles = setmetatable({}, {__mode = 'k'})
local healthContainer
local lastScan, lastApply = 0, 0

local GAME_TILE = Color3.fromRGB(29, 36, 46)

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function colorOf(setting)
	return Color3.fromHSV(setting.Hue, setting.Sat, setting.Value)
end

local function close(a, b)
	return math.abs(a.R - b.R) + math.abs(a.G - b.G) + math.abs(a.B - b.B) < 0.02
end

-- Finds the hotbar's tiles and health bar, once a second.
local function scan()
	if os.clock() - lastScan < 1 then return end
	lastScan = os.clock()
	local gui = lplr:FindFirstChildOfClass('PlayerGui')
	if not gui then return end
	healthContainer = gui:FindFirstChild('HotbarHealthbarContainer', true)
	local items = gui:FindFirstChild('ItemsHotbar', true)
	if not items then return end
	for _, object in items:GetDescendants() do
		if object:IsA('GuiObject') and not tiles[object] and object.SizeConstraint == Enum.SizeConstraint.RelativeYY
			and object.BorderSizePixel == 1 and close(object.BackgroundColor3, GAME_TILE) then
			tiles[object] = true
		end
	end
end

local function applyTiles()
	local list = {}
	for tile in tiles do
		if tile.Parent and tile.Visible then list[#list + 1] = tile end
	end
	table.sort(list, function(a, b) return a.AbsolutePosition.X < b.AbsolutePosition.X end)
	local selected = store.inventory and store.inventory.hotbarSlot
	for index, tile in list do
		local isSelected = selected ~= nil and index - 1 == selected
		local fill = isSelected and SelectedColor or SlotColor
		tile.BackgroundColor3 = colorOf(fill)
		tile.BackgroundTransparency = 1 - fill.Opacity
		tile.BorderColor3 = isSelected and colorOf(SelectedBorder) or colorOf(BorderColor)
	end
end

local function applyHealth()
	if not (on(RecolorHealth) and healthContainer and healthContainer.Parent) then return end
	healthContainer.BackgroundColor3 = colorOf(HealthBack)
	healthContainer.BackgroundTransparency = 1 - HealthBack.Opacity
	local wrapper = healthContainer:FindFirstChild('HealthbarProgressWrapper', true)
	local fill = wrapper and wrapper:FindFirstChildWhichIsA('Frame')
	if not fill then return end

	local color = colorOf(HealthColor)
	if on(HealthGradient) then
		-- Green when full, through yellow, to red when nearly out.
		local character = lplr.Character
		local health = character and character:GetAttribute('Health')
		local maxHealth = character and character:GetAttribute('MaxHealth')
		if health and maxHealth and maxHealth > 0 then
			color = Color3.fromHSV(math.clamp(health / maxHealth, 0, 1) / 3, 0.85, 0.9)
		end
	end
	fill.BackgroundColor3 = color
end

Hotbar = vain.Legit:CreateModule({
	Name = 'Hotbar',
	Function = function(callback)
		if callback then
			lastScan = 0
			Hotbar:Clean(runService.RenderStepped:Connect(function()
				pcall(scan)
				-- Tiles a few times a second; the health bar every frame, as it changes colour
				-- with every hit.
				if os.clock() - lastApply >= 0.15 then
					lastApply = os.clock()
					pcall(applyTiles)
				end
				pcall(applyHealth)
			end))
		else
			-- The game's own look back: the tile colour and its normal border and fade.
			for tile in tiles do
				pcall(function()
					tile.BackgroundColor3 = GAME_TILE
					tile.BackgroundTransparency = 0.4
					tile.BorderColor3 = Color3.fromRGB(114, 127, 172)
				end)
			end
			table.clear(tiles)
			healthContainer = nil
		end
	end,
	Tooltip = 'Recolours the hotbar and health bar'
})
SlotColor = Hotbar:CreateColorSlider({
	Name = 'Slot Color',
	Tooltip = 'Colour of the slots',
	DefaultHue = 0.6,
	DefaultSat = 0.37,
	DefaultValue = 0.18,
	DefaultOpacity = 0.6
})
SelectedColor = Hotbar:CreateColorSlider({
	Name = 'Selected Color',
	Tooltip = 'Colour of the selected slot',
	DefaultHue = 0.6,
	DefaultSat = 0.37,
	DefaultValue = 0.3,
	DefaultOpacity = 0.8
})
BorderColor = Hotbar:CreateColorSlider({
	Name = 'Border Color',
	Tooltip = 'Border of the slots',
	DefaultHue = 0.63,
	DefaultSat = 0.34,
	DefaultValue = 0.67
})
SelectedBorder = Hotbar:CreateColorSlider({
	Name = 'Selected Border',
	Tooltip = 'Border of the selected slot',
	DefaultSat = 0,
	DefaultValue = 1
})
RecolorHealth = Hotbar:CreateToggle({
	Name = 'Health Bar',
	Tooltip = 'Recolours the health bar',
	Default = true,
	Function = function(callback)
		for _, setting in {HealthGradient, HealthColor, HealthBack} do
			if setting and setting.Object then setting.Object.Visible = callback end
		end
		if callback and HealthColor and HealthColor.Object then
			HealthColor.Object.Visible = not on(HealthGradient)
		end
	end
})
HealthGradient = Hotbar:CreateToggle({
	Name = 'Health Gradient',
	Tooltip = 'Green to red as your health drops',
	Default = true,
	Darker = true,
	Function = function(callback)
		if HealthColor and HealthColor.Object then
			HealthColor.Object.Visible = not callback and on(RecolorHealth)
		end
	end
})
HealthColor = Hotbar:CreateColorSlider({
	Name = 'Health Color',
	Tooltip = 'Colour of the health bar',
	DefaultHue = 0.02,
	DefaultSat = 0.82,
	DefaultValue = 0.8,
	Darker = true,
	Visible = false
})
HealthBack = Hotbar:CreateColorSlider({
	Name = 'Health Background',
	Tooltip = 'Colour behind the health bar',
	DefaultHue = 0.6,
	DefaultSat = 0.37,
	DefaultValue = 0.25,
	DefaultOpacity = 1,
	Darker = true
})
