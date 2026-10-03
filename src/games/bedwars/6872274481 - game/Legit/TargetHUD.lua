--[[
	Target HUD.

	A card for whoever you are fighting: the enemy nearest your crosshair within range,
	held for a moment after they leave it so the card does not flicker. It shows their
	avatar, name in their team colour, health (the Health and MaxHealth attributes the
	entity list keeps), distance, kit (the PlayingAsKit attribute) and what they hold and
	wear (the inventories the game replicates, kept in store.inventories). Nothing is
	requested from the server; the avatar is a rbxthumb image.
]]
local TargetHUD
local Range, Angle, Linger, ShowEquipment, Background
local card, avatar, nameLabel, infoLabel, barBack, barFill, barGhost, equipment
local icons = {}
local target, targetSince, lastSeen = nil, 0, 0
local ghost = 1

local function on(setting)
	return setting ~= nil and setting.Enabled
end

-- The enemy nearest the crosshair inside the range and the cone.
local function pick()
	if not entitylib.isAlive then return nil end
	local here = entitylib.character.RootPart.Position
	local look = gameCamera.CFrame.LookVector
	local best, bestAngle
	for _, entity in entitylib.List do
		if entity.Player and entity.Targetable and entity.RootPart and entity.Health > 0 then
			local offset = entity.RootPart.Position - here
			local distance = offset.Magnitude
			if distance <= Range.Value and distance > 0 then
				local angle = math.deg(math.acos(math.clamp(look:Dot(offset.Unit), -1, 1)))
				if angle <= Angle.Value and (not bestAngle or angle < bestAngle) then
					best, bestAngle = entity, angle
				end
			end
		end
	end
	return best
end

local function setIcon(index, image)
	local icon = icons[index]
	icon.Image = image or ''
	icon.Visible = image ~= nil and image ~= ''
end

local function update()
	local found = pick()
	if found then
		if found ~= target then
			target, targetSince = found, os.clock()
			ghost = math.clamp(found.Health / math.max(found.MaxHealth, 1), 0, 1)
		end
		lastSeen = os.clock()
	elseif target and os.clock() - lastSeen > Linger.Value then
		target = nil
	end

	-- Gone from the list (left, or the entity was replaced on respawn).
	if target and not table.find(entitylib.List, target) then target = nil end
	card.Visible = target ~= nil
	if not target then return end

	local player = target.Player
	local color = player.Team and player.TeamColor.Color or Color3.new(1, 1, 1)
	avatar.Image = 'rbxthumb://type=AvatarHeadShot&id=' .. player.UserId .. '&w=150&h=150'
	nameLabel.Text = player.DisplayName
	nameLabel.TextColor3 = color

	local fraction = math.clamp(target.Health / math.max(target.MaxHealth, 1), 0, 1)
	-- The pale bar trails the real one, so a hit shows how much it took off.
	ghost = fraction > ghost and fraction or ghost + (fraction - ghost) * 0.08
	barFill.Size = UDim2.fromScale(fraction, 1)
	barGhost.Size = UDim2.fromScale(ghost, 1)
	barFill.BackgroundColor3 = Color3.fromHSV(fraction / 3, 0.85, 0.95)

	local distance = entitylib.isAlive and (target.RootPart.Position - entitylib.character.RootPart.Position).Magnitude or 0
	infoLabel.Text = string.format('%d / %d HP   %dm', math.ceil(target.Health), math.ceil(target.MaxHealth), math.floor(distance))

	equipment.Visible = on(ShowEquipment)
	if on(ShowEquipment) then
		local inventory = store.inventories[player]
		local kit = player:GetAttribute('PlayingAsKit')
		local kitMeta = kit and kit ~= 'none' and bedwars.BedwarsKitMeta[kit]
		setIcon(1, kitMeta and kitMeta.renderImage or nil)
		setIcon(2, inventory and inventory.hand and bedwars.getIcon(inventory.hand, true) or nil)
		for i, slot in {4, 5, 6} do
			local piece = inventory and inventory.armor and inventory.armor[slot]
			setIcon(2 + i, piece and bedwars.getIcon(piece, true) or nil)
		end
	end
end

TargetHUD = vain.Legit:CreateModule({
	Name = 'Target HUD',
	Function = function(callback)
		if callback then
			TargetHUD:Clean(runService.RenderStepped:Connect(function()
				pcall(update)
			end))
		else
			target = nil
			card.Visible = false
		end
	end,
	Size = UDim2.fromOffset(240, 78),
	Tooltip = 'Shows who you are fighting'
})
Range = TargetHUD:CreateSlider({
	Name = 'Range',
	Tooltip = 'How far away a target can be',
	Min = 5,
	Max = 60,
	Default = 22,
	Suffix = function(val) return val == 1 and 'stud' or 'studs' end
})
Angle = TargetHUD:CreateSlider({
	Name = 'Angle',
	Tooltip = 'How far off your crosshair they can be',
	Min = 5,
	Max = 180,
	Default = 60,
	Suffix = function() return '°' end
})
Linger = TargetHUD:CreateSlider({
	Name = 'Linger',
	Tooltip = 'How long the card stays after',
	Min = 0,
	Max = 5,
	Default = 1.5,
	Decimal = 10,
	Suffix = function() return 's' end
})
ShowEquipment = TargetHUD:CreateToggle({
	Name = 'Equipment',
	Tooltip = 'Shows their kit, held item and armour',
	Default = true
})
Background = TargetHUD:CreateColorSlider({
	Name = 'Background',
	Tooltip = 'Colour of the card',
	DefaultValue = 0.08,
	DefaultOpacity = 0.7,
	Function = function(hue, sat, val, opacity)
		if card then
			card.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			card.BackgroundTransparency = 1 - opacity
		end
	end
})

card = Instance.new('Frame')
card.Size = UDim2.fromScale(1, 1)
card.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
card.BackgroundTransparency = 0.3
card.BorderSizePixel = 0
card.Visible = false
card.Parent = TargetHUD.Children
Instance.new('UICorner', card).CornerRadius = UDim.new(0, 8)

avatar = Instance.new('ImageLabel')
avatar.Position = UDim2.fromOffset(8, 8)
avatar.Size = UDim2.fromOffset(46, 46)
avatar.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
avatar.BorderSizePixel = 0
avatar.Parent = card
Instance.new('UICorner', avatar).CornerRadius = UDim.new(0, 6)

nameLabel = Instance.new('TextLabel')
nameLabel.BackgroundTransparency = 1
nameLabel.Position = UDim2.fromOffset(62, 6)
nameLabel.Size = UDim2.new(1, -70, 0, 18)
nameLabel.Font = Enum.Font.GothamBold
nameLabel.TextSize = 15
nameLabel.TextXAlignment = Enum.TextXAlignment.Left
nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
nameLabel.Parent = card

barBack = Instance.new('Frame')
barBack.Position = UDim2.fromOffset(62, 27)
barBack.Size = UDim2.new(1, -70, 0, 8)
barBack.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
barBack.BorderSizePixel = 0
barBack.Parent = card
Instance.new('UICorner', barBack).CornerRadius = UDim.new(1, 0)
barGhost = Instance.new('Frame')
barGhost.BackgroundColor3 = Color3.fromRGB(235, 235, 235)
barGhost.BackgroundTransparency = 0.4
barGhost.BorderSizePixel = 0
barGhost.Parent = barBack
Instance.new('UICorner', barGhost).CornerRadius = UDim.new(1, 0)
barFill = Instance.new('Frame')
barFill.BorderSizePixel = 0
barFill.Parent = barBack
Instance.new('UICorner', barFill).CornerRadius = UDim.new(1, 0)

infoLabel = Instance.new('TextLabel')
infoLabel.BackgroundTransparency = 1
infoLabel.Position = UDim2.fromOffset(62, 38)
infoLabel.Size = UDim2.new(1, -70, 0, 16)
infoLabel.Font = Enum.Font.Gotham
infoLabel.TextSize = 12
infoLabel.TextColor3 = Color3.fromRGB(210, 210, 210)
infoLabel.TextXAlignment = Enum.TextXAlignment.Left
infoLabel.Parent = card

equipment = Instance.new('Frame')
equipment.BackgroundTransparency = 1
equipment.Position = UDim2.fromOffset(8, 58)
equipment.Size = UDim2.new(1, -16, 0, 16)
equipment.Parent = card
local equipmentLayout = Instance.new('UIListLayout')
equipmentLayout.FillDirection = Enum.FillDirection.Horizontal
equipmentLayout.Padding = UDim.new(0, 4)
equipmentLayout.SortOrder = Enum.SortOrder.LayoutOrder
equipmentLayout.Parent = equipment
-- Kit, held item, helmet, chestplate, boots.
for i = 1, 5 do
	local icon = Instance.new('ImageLabel')
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.fromOffset(16, 16)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.LayoutOrder = i
	icon.Visible = false
	icon.Parent = equipment
	icons[i] = icon
end
