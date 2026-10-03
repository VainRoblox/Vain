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
local WinMode
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
	local extra = not compact and on(ShowKitName)
	extraLabel.Visible = extra
	extraLabel.Position = UDim2.fromOffset(left, 54)
	equipment.Visible = not compact and (on(ShowEquipment) or on(ShowEnchants))
	equipment.Position = UDim2.fromOffset(8, extra and 74 or 58)
	local height = compact and 42 or (58 + (extra and 16 or 0) + ((on(ShowEquipment) or on(ShowEnchants)) and 20 or 0))
	card.Size = UDim2.new(1, 0, 0, height)
end

--[[
	The win check: how many hits each of you needs to finish the other.

	- Health: yours is read straight off your character (Health plus any shield) - the
	  entity list's copy did not follow your own damage, which is why it said winning while
	  losing. A Sound Barrier above half health counts its 50 shield on top.
	- Damage: the sword damage of what each of you holds, from the item meta (a fist when
	  it is not a sword), through the other's armor the way the game's ArmorUtil works it
	  out: damage x (1 - the summed damageReductionMultiplier of the armor worn).
	- Enchants (from the shared enchants helper, i.e. the game's enchant meta): Absorption
	  takes its 10% off the damage taken and Blocking stops one hit. The weapon enchants'
	  numbers live on the server, so those are estimates - Critical Strike, Fire, Static,
	  Forest and Execute as a bit more damage, Berserker more again at low health.
]]
local FIST_DAMAGE = 1
local WEAPON_BONUS = {
	critical_strike = 1.2, fire = 1.15, static = 1.15, forest = 1.1, execute = 1.1, berserker = 1.1
}

local function swordDamage(itemType)
	local meta = itemType and bedwars.ItemMeta[itemType]
	return meta and meta.sword and tonumber(meta.sword.damage) or FIST_DAMAGE
end

local function armorReduction(pieces)
	local total = 0
	for _, piece in (type(pieces) == 'table' and pieces or {}) do
		local itemType = type(piece) == 'table' and piece.itemType
		local meta = itemType and bedwars.ItemMeta[itemType]
		if meta and meta.armor and tonumber(meta.armor.damageReductionMultiplier) then
			total += meta.armor.damageReductionMultiplier
		end
	end
	return math.clamp(total, 0, 0.95)
end

local function enchantSet(character)
	local set = {}
	for _, enchant in enchants.of(character) do
		-- Tool enchants share names with weapon ones (Shatter Strike is critical_strike)
		-- and do nothing in a fight.
		if enchant.kind ~= 'tool' then
			set[tostring(enchant.type):lower()] = enchant
		end
	end
	return set
end

-- Damage one side's hit does to the other.
local function hitDamage(itemType, attackerEnchants, defenderArmor, defenderEnchants, defenderFraction)
	local damage = swordDamage(itemType)
	for name, bonus in WEAPON_BONUS do
		if attackerEnchants[name] then damage *= bonus end
	end
	if attackerEnchants.berserker and defenderFraction and defenderFraction < 0.5 then damage *= 1.15 end
	damage *= 1 - armorReduction(defenderArmor)
	if defenderEnchants.absorption then damage *= 0.9 end
	return math.max(damage, 0.1)
end

local function effectiveHealth(health, maxHealth, set)
	if set.safeguard and maxHealth > 0 and health / maxHealth > 0.5 then health += 50 end
	return health
end

-- Swings a second for what is held: the sword's attackSpeed is the gap between swings.
local function swingRate(itemType)
	local meta = itemType and bedwars.ItemMeta[itemType]
	local gap = meta and meta.sword and tonumber(meta.sword.attackSpeed)
	return gap and gap > 0 and math.clamp(1 / gap, 0.5, 5) or 2
end

-- Both sides of the fight as the item meta has it: effective health, damage a hit and
-- swings a second, for you and for them.
local function fightNumbers(player, theirHealth)
	local character = lplr.Character
	if not (entitylib.isAlive and character and player.Character) then return nil end
	local myHealth = (character:GetAttribute('Health') or 0) + getShieldAttribute(character)
	local myMax = character:GetAttribute('MaxHealth') or 100
	local theirMax = player.Character:GetAttribute('MaxHealth') or 100

	local mySet, theirSet = enchantSet(character), enchantSet(player.Character)
	local myTool = store.hand and store.hand.tool
	local inventory = store.inventories[player]
	local theirItem = inventory and inventory.hand and inventory.hand.itemType
	local myArmor = store.inventory and store.inventory.inventory and store.inventory.inventory.armor
	local theirArmor = inventory and inventory.armor
	return {
		myHealth = effectiveHealth(myHealth, myMax, mySet),
		theirHealth = effectiveHealth(theirHealth, theirMax, theirSet),
		myHit = hitDamage(myTool and myTool.Name, mySet, theirArmor, theirSet, theirHealth / math.max(theirMax, 1)),
		theirHit = hitDamage(theirItem, theirSet, myArmor, mySet, myHealth / math.max(myMax, 1)),
		myRate = swingRate(myTool and myTool.Name),
		theirRate = swingRate(theirItem)
	}
end

hitsToKill = function(player, theirHealth)
	local character = lplr.Character
	if not (entitylib.isAlive and character and player.Character) then return nil end
	local myHealth = (character:GetAttribute('Health') or 0) + getShieldAttribute(character)
	local myMax = character:GetAttribute('MaxHealth') or 100
	local theirMax = player.Character:GetAttribute('MaxHealth') or 100

	local mySet, theirSet = enchantSet(character), enchantSet(player.Character)
	local myTool = store.hand and store.hand.tool
	local inventory = store.inventories[player]
	local theirItem = inventory and inventory.hand and inventory.hand.itemType
	local myArmor = store.inventory and store.inventory.inventory and store.inventory.inventory.armor
	local theirArmor = inventory and inventory.armor

	local mine = math.ceil(effectiveHealth(theirHealth, theirMax, theirSet) / hitDamage(myTool and myTool.Name, mySet, theirArmor, theirSet, theirHealth / math.max(theirMax, 1)))
	local theirs = math.ceil(effectiveHealth(myHealth, myMax, mySet) / hitDamage(theirItem, theirSet, myArmor, mySet, myHealth / math.max(myMax, 1)))
	-- Blocking stops the first hit.
	if theirSet.blocking then mine += 1 end
	if mySet.blocking then theirs += 1 end
	return math.max(mine, 1), math.max(theirs, 1)
end

--[[
	Live Damage: the damage you and your target actually take, read from each character's
	Health attribute as it drops - so crits, kit buffs, real enchant numbers and how fast
	each of you is really hitting are all in it. Damage per second over the last few
	seconds gives each side's time to finish the other off. Until a few hits have landed it
	leans on the item-based estimate, and the verdict only flips once the gap is clear.
]]
local LIVE_WINDOW = 6
local live = {taken = {}, dealt = {}, conns = {}, verdict = 'EVEN'}

local function watchHealth(character, log)
	local last = character:GetAttribute('Health')
	return character:GetAttributeChangedSignal('Health'):Connect(function()
		local now = character:GetAttribute('Health')
		if type(now) == 'number' and type(last) == 'number' and now < last then
			table.insert(log, {time = os.clock(), amount = last - now})
		end
		last = now
	end)
end

local function liveReset()
	for _, conn in live.conns do conn:Disconnect() end
	table.clear(live.conns)
	table.clear(live.taken)
	table.clear(live.dealt)
	live.myChar, live.theirChar = nil, nil
	live.verdict = 'EVEN'
end

-- Keeps the two health watchers on the right characters.
local function liveTrack(player)
	local mine, theirs = lplr.Character, player and player.Character
	if mine == live.myChar and theirs == live.theirChar then return end
	liveReset()
	live.myChar, live.theirChar = mine, theirs
	if mine then table.insert(live.conns, watchHealth(mine, live.taken)) end
	if theirs then table.insert(live.conns, watchHealth(theirs, live.dealt)) end
end

-- Damage a second from a log, and how many hits it is based on.
local function liveRate(log)
	local now = os.clock()
	local total, hits, first = 0, 0, nil
	for i = #log, 1, -1 do
		local hit = log[i]
		if now - hit.time > LIVE_WINDOW then
			table.remove(log, i)
		else
			total += hit.amount
			hits += 1
			first = math.min(first or hit.time, hit.time)
		end
	end
	if hits == 0 then return 0, 0 end
	return total / math.max(now - first, 1.5), hits
end

local function liveVerdict(player, theirHealth)
	local numbers = fightNumbers(player, theirHealth)
	if not numbers then return nil end
	local dealt, dealtHits = liveRate(live.dealt)
	local taken, takenHits = liveRate(live.taken)
	-- Blended from the estimate to the real numbers over the first three hits each way.
	local myWeight, theirWeight = math.min(dealtHits / 3, 1), math.min(takenHits / 3, 1)
	local myDps = myWeight * dealt + (1 - myWeight) * numbers.myHit * numbers.myRate
	local theirDps = theirWeight * taken + (1 - theirWeight) * numbers.theirHit * numbers.theirRate
	local myTime = numbers.theirHealth / math.max(myDps, 0.1)
	local theirTime = numbers.myHealth / math.max(theirDps, 0.1)
	local gap = (theirTime - myTime) / math.max(myTime, theirTime, 0.1)
	-- Close is even; a clear gap is needed before it flips from one side to the other.
	if math.abs(gap) < 0.08 then
		live.verdict = 'EVEN'
	elseif gap > 0.15 or (gap > 0 and live.verdict == 'WINNING') then
		live.verdict = 'WINNING'
	elseif gap < -0.15 or (gap < 0 and live.verdict == 'LOSING') then
		live.verdict = 'LOSING'
	end
	return live.verdict
end

local VERDICT_COLORS = {
	EVEN = Color3.fromRGB(230, 230, 230),
	WINNING = Color3.fromRGB(110, 230, 120),
	LOSING = Color3.fromRGB(255, 90, 90)
}

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
	if winLabel.Visible and WinMode and WinMode.Value == 'Live Damage' then
		liveTrack(player)
		local verdict = liveVerdict(player, health)
		winLabel.Text = verdict or ''
		winLabel.TextColor3 = VERDICT_COLORS[verdict or 'EVEN']
	elseif winLabel.Visible then
		-- Who needs fewer hits to finish the other, with what each of you is holding.
		local mineLeft, theirsLeft = hitsToKill(player, health)
		if not mineLeft then
			winLabel.Text = ''
		else
			local diff = theirsLeft - mineLeft
			-- Just the verdict: fewer hits needed is winning, which weighs the damage each of
			-- you deals against the health each of you has left.
			winLabel.Text = diff == 0 and 'EVEN' or (diff > 0 and 'WINNING' or 'LOSING')
			winLabel.TextColor3 = diff == 0 and Color3.fromRGB(230, 230, 230) or (diff > 0 and Color3.fromRGB(110, 230, 120) or Color3.fromRGB(255, 90, 90))
		end
	end

	local distance = (entitylib.isAlive and entity.RootPart) and (entity.RootPart.Position - entitylib.character.RootPart.Position).Magnitude or 0
	infoLabel.Text = string.format('%d / %d HP   %dm', math.ceil(health), math.ceil(maxHealth), math.floor(distance))

	local kit = player:GetAttribute('PlayingAsKit')
	local kitMeta = kit and kit ~= 'none' and bedwars.BedwarsKitMeta[kit]
	local extra = {}
	if on(ShowKitName) and kitMeta then extra[#extra + 1] = kitMeta.name or kit end
	extraLabel.Text = table.concat(extra, '  ·  ')

	-- Their enchants as the game's own enchant icons, after the equipment.
	local list = (on(ShowEnchants) and entity.Character) and enchants.of(entity.Character) or {}
	for i = 6, #icons do
		local enchant = list[i - 5]
		setIcon(i, enchant and enchant.image or nil)
	end

	if not on(ShowEquipment) then
		for i = 1, 5 do setIcon(i, nil) end
	else
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
			liveReset()
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
	Default = true,
	Function = function(callback)
		if WinMode and WinMode.Object then WinMode.Object.Visible = callback end
	end
})
WinMode = TargetHUD:CreateDropdown({
	Name = 'Win Mode',
	List = {'Estimate', 'Live Damage'},
	Tooltips = {
		Estimate = 'From weapons, armor and enchants',
		['Live Damage'] = 'From the damage you both really deal'
	},
	Darker = true,
	Function = function()
		liveReset()
	end
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
	Tooltip = 'Shows their enchants\' icons'
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
-- Kit, held item, helmet, chestplate, boots, then up to four enchants.
for i = 1, 9 do
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
