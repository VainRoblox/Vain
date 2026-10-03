--[[
	Target HUD.

	A card for whoever you are fighting, picked one of three ways: the enemy nearest your
	crosshair within range, the last one you hit (store.lastHitCharacter, written where the
	attack is sent), or simply the nearest. The card stays a moment after they drop out so
	it does not flicker, and shows a preview of yourself while the GUI is open so it can be
	placed.

	It shows their avatar, name in their team colour, health (the Health and MaxHealth
	attributes the entity list keeps) against yours, distance, kit (PlayingAsKit), active
	enchants (StatusEffect_*enchant* attributes) and what they hold and wear (the
	inventories the game replicates, kept in store.inventories). Nothing is requested from
	the server; the avatar is a rbxthumb image.
]]
local TargetHUD
local Mode, Range, Angle, Linger, ShowEquipment, WinIndicator, Compact, Accent, ShowKitName, ShowEnchants, Background
local card, stroke, avatar, nameLabel, winLabel, infoLabel, extraLabel, barBack, barFill, barGhost, equipment
local icons = {}
local target, lastSeen = nil, 0
local hitsToKill
local ghost = 1
local LAST_HIT_HOLD = 6

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function guiOpen()
	local ok, open = pcall(function()
		return vain.gui.ScaledGui.ClickGui.Visible
	end)
	return ok and open == true
end

local function isEnemy(entity)
	return entity.Player and entity.Targetable and entity.RootPart and (entity.Health or 0) > 0
end

local function pick()
	if not entitylib.isAlive then return nil end
	local here = entitylib.character.RootPart.Position

	if Mode.Value == 'Last Hit' then
		if store.lastHitCharacter and tick() - (store.lastHitAt or 0) <= LAST_HIT_HOLD then
			local entity = entitylib.getEntity(store.lastHitCharacter)
			if entity and isEnemy(entity) and (entity.RootPart.Position - here).Magnitude <= Range.Value then
				return entity
			end
		end
		return nil
	end

	local look = gameCamera.CFrame.LookVector
	local best, bestScore
	for _, entity in entitylib.List do
		if isEnemy(entity) then
			local offset = entity.RootPart.Position - here
			local distance = offset.Magnitude
			if distance <= Range.Value and distance > 0 then
				local score
				if Mode.Value == 'Nearest' then
					score = distance
				else
					local angle = math.deg(math.acos(math.clamp(look:Dot(offset.Unit), -1, 1)))
					score = angle <= Angle.Value and angle or nil
				end
				if score and (not bestScore or score < bestScore) then
					best, bestScore = entity, score
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

-- "ARMOR_ENCHANT_FROST" style status names, read as "Frost".
local function enchantsOf(character)
	local list = {}
	for name in character:GetAttributes() do
		local effect = name:match('^StatusEffect_(.+)$')
		if effect and not effect:find('_stacks$') and not effect:find('_extra') and effect:lower():find('enchant', 1, true) then
			local word = effect:lower():gsub('armor_enchant_', ''):gsub('_enchant', ''):gsub('enchant_', ''):gsub('_', ' ')
			list[#list + 1] = word:gsub('^%l', string.upper)
		end
	end
	table.sort(list)
	return list
end

local function layout()
	local compact = on(Compact)
	avatar.Visible = not compact
	infoLabel.Visible = not compact
	local left = compact and 8 or 62
	nameLabel.Position = UDim2.fromOffset(left, 6)
	nameLabel.Size = UDim2.new(1, -left - 96, 0, 18)
	barBack.Position = UDim2.fromOffset(left, 27)
	barBack.Size = UDim2.new(1, -left - 8, 0, 8)
	infoLabel.Position = UDim2.fromOffset(left, 38)
	infoLabel.Size = UDim2.new(1, -left - 8, 0, 16)
	local extra = not compact and (on(ShowKitName) or on(ShowEnchants))
	extraLabel.Visible = extra
	extraLabel.Position = UDim2.fromOffset(left, 54)
	equipment.Visible = not compact and on(ShowEquipment)
	equipment.Position = UDim2.fromOffset(8, extra and 74 or 58)
	local height = compact and 42 or (58 + (extra and 16 or 0) + (on(ShowEquipment) and 20 or 0))
	card.Size = UDim2.new(1, 0, 0, height)
end

--[[
	The win check: how many hits each of you needs to finish the other. Your own health is
	read straight off your character (Health plus any shield) - the entity list's copy of it
	did not follow your own damage, which is why it said winning while losing. Damage is the
	sword damage of what each of you holds, from the item meta; anything that is not a sword
	counts as a fist.
]]
local FIST_DAMAGE = 1

local function swordDamage(itemType)
	local meta = itemType and bedwars.ItemMeta[itemType]
	return meta and meta.sword and tonumber(meta.sword.damage) or FIST_DAMAGE
end

hitsToKill = function(player, theirHealth)
	local character = lplr.Character
	if not (entitylib.isAlive and character) then return nil end
	local myHealth = (character:GetAttribute('Health') or 0) + getShieldAttribute(character)
	local myTool = store.hand and store.hand.tool
	local inventory = store.inventories[player]
	local theirItem = inventory and inventory.hand and inventory.hand.itemType
	local mine = math.max(math.ceil(theirHealth / swordDamage(myTool and myTool.Name)), 1)
	local theirs = math.max(math.ceil(myHealth / swordDamage(theirItem)), 1)
	return mine, theirs
end

local function show(entity, player)
	local color = player.Team and player.TeamColor.Color or Color3.new(1, 1, 1)
	avatar.Image = 'rbxthumb://type=AvatarHeadShot&id=' .. player.UserId .. '&w=150&h=150'
	nameLabel.Text = player.DisplayName
	nameLabel.TextColor3 = color
	stroke.Enabled = on(Accent)
	stroke.Color = color

	local health, maxHealth = entity.Health or 0, math.max(entity.MaxHealth or 100, 1)
	local fraction = math.clamp(health / maxHealth, 0, 1)
	-- The pale bar trails the real one, so a hit shows how much it took off.
	ghost = fraction > ghost and fraction or ghost + (fraction - ghost) * 0.08
	barFill.Size = UDim2.fromScale(fraction, 1)
	barGhost.Size = UDim2.fromScale(ghost, 1)
	barFill.BackgroundColor3 = Color3.fromHSV(fraction / 3, 0.85, 0.95)

	winLabel.Visible = on(WinIndicator) and player ~= lplr
	if winLabel.Visible then
		-- Who needs fewer hits to finish the other, with what each of you is holding.
		local mineLeft, theirsLeft = hitsToKill(player, health)
		if not mineLeft then
			winLabel.Text = ''
		else
			local diff = theirsLeft - mineLeft
			winLabel.Text = string.format('%s %dv%d', diff == 0 and 'EVEN' or (diff > 0 and 'WINNING' or 'LOSING'), mineLeft, theirsLeft)
			winLabel.TextColor3 = diff == 0 and Color3.fromRGB(230, 230, 230) or (diff > 0 and Color3.fromRGB(110, 230, 120) or Color3.fromRGB(255, 90, 90))
		end
	end

	local distance = (entitylib.isAlive and entity.RootPart) and (entity.RootPart.Position - entitylib.character.RootPart.Position).Magnitude or 0
	infoLabel.Text = string.format('%d / %d HP   %dm', math.ceil(health), math.ceil(maxHealth), math.floor(distance))

	local kit = player:GetAttribute('PlayingAsKit')
	local kitMeta = kit and kit ~= 'none' and bedwars.BedwarsKitMeta[kit]
	local extra = {}
	if on(ShowKitName) and kitMeta then extra[#extra + 1] = kitMeta.name or kit end
	if on(ShowEnchants) and entity.Character then
		local enchants = enchantsOf(entity.Character)
		if #enchants > 0 then extra[#extra + 1] = table.concat(enchants, ', ') end
	end
	extraLabel.Text = table.concat(extra, '  ·  ')

	if on(ShowEquipment) then
		local inventory = store.inventories[player]
		setIcon(1, kitMeta and kitMeta.renderImage or nil)
		setIcon(2, inventory and inventory.hand and bedwars.getIcon(inventory.hand, true) or nil)
		for i, slot in {4, 5, 6} do
			local piece = inventory and inventory.armor and inventory.armor[slot]
			setIcon(2 + i, piece and bedwars.getIcon(piece, true) or nil)
		end
	end
	layout()
end

local function update()
	local found = pick()
	if found then
		if found ~= target then
			target = found
			ghost = math.clamp((found.Health or 0) / math.max(found.MaxHealth or 100, 1), 0, 1)
		end
		lastSeen = os.clock()
	elseif target and os.clock() - lastSeen > Linger.Value then
		target = nil
	end
	-- Gone from the list (left, or the entity was replaced on respawn).
	if target and not table.find(entitylib.List, target) then target = nil end

	if target then
		show(target, target.Player)
		card.Visible = true
	elseif guiOpen() and entitylib.isAlive then
		-- A preview of yourself, so the card can be seen and dragged into place.
		show(entitylib.character, lplr)
		card.Visible = true
	else
		card.Visible = false
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
	Size = UDim2.fromOffset(240, 96),
	Tooltip = 'Shows who you are fighting'
})
Mode = TargetHUD:CreateDropdown({
	Name = 'Target Mode',
	List = {'Crosshair', 'Last Hit', 'Nearest'},
	Tooltips = {
		Crosshair = 'The enemy nearest your crosshair',
		['Last Hit'] = 'The last enemy you hit',
		Nearest = 'The nearest enemy'
	},
	Function = function(val)
		if Angle and Angle.Object then Angle.Object.Visible = val == 'Crosshair' end
	end
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
WinIndicator = TargetHUD:CreateToggle({
	Name = 'Win Indicator',
	Tooltip = 'Compares their health with yours',
	Default = true
})
Compact = TargetHUD:CreateToggle({
	Name = 'Compact',
	Tooltip = 'Just the name and health bar'
})
Accent = TargetHUD:CreateToggle({
	Name = 'Team Accent',
	Tooltip = 'Borders the card in their team colour',
	Default = true
})
ShowEquipment = TargetHUD:CreateToggle({
	Name = 'Equipment',
	Tooltip = 'Shows their kit, held item and armour',
	Default = true
})
ShowKitName = TargetHUD:CreateToggle({
	Name = 'Kit Name',
	Tooltip = 'Writes out their kit'
})
ShowEnchants = TargetHUD:CreateToggle({
	Name = 'Enchants',
	Tooltip = 'Lists their active enchants'
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
stroke = Instance.new('UIStroke')
stroke.Thickness = 1.5
stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
stroke.Parent = card

avatar = Instance.new('ImageLabel')
avatar.Position = UDim2.fromOffset(8, 8)
avatar.Size = UDim2.fromOffset(46, 46)
avatar.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
avatar.BorderSizePixel = 0
avatar.Parent = card
Instance.new('UICorner', avatar).CornerRadius = UDim.new(0, 6)

nameLabel = Instance.new('TextLabel')
nameLabel.BackgroundTransparency = 1
nameLabel.Font = Enum.Font.GothamBold
nameLabel.TextSize = 15
nameLabel.TextXAlignment = Enum.TextXAlignment.Left
nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
nameLabel.Parent = card

winLabel = Instance.new('TextLabel')
winLabel.BackgroundTransparency = 1
winLabel.AnchorPoint = Vector2.new(1, 0)
winLabel.Position = UDim2.new(1, -8, 0, 6)
winLabel.Size = UDim2.fromOffset(90, 18)
winLabel.Font = Enum.Font.GothamBold
winLabel.TextSize = 11
winLabel.TextXAlignment = Enum.TextXAlignment.Right
winLabel.Parent = card

barBack = Instance.new('Frame')
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
infoLabel.Font = Enum.Font.Gotham
infoLabel.TextSize = 12
infoLabel.TextColor3 = Color3.fromRGB(210, 210, 210)
infoLabel.TextXAlignment = Enum.TextXAlignment.Left
infoLabel.Parent = card

extraLabel = Instance.new('TextLabel')
extraLabel.BackgroundTransparency = 1
extraLabel.Size = UDim2.new(1, -70, 0, 16)
extraLabel.Font = Enum.Font.Gotham
extraLabel.TextSize = 11
extraLabel.TextColor3 = Color3.fromRGB(180, 180, 255)
extraLabel.TextXAlignment = Enum.TextXAlignment.Left
extraLabel.TextTruncate = Enum.TextTruncate.AtEnd
extraLabel.Parent = card

equipment = Instance.new('Frame')
equipment.BackgroundTransparency = 1
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
layout()
