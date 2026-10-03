local NameTags
local Targets
local Color
local Background
local DisplayName
local Health
local Distance
local Equipment
local DrawingToggle
local Scale
local FontOption
local Teammates
local DistanceCheck
local DistanceLimit
local Rank
local Enchants
local Effects
local KitStats
local Strings, Sizes, Reference, Prefixes = {}, {}, {}, {}
local Folder = Instance.new('Folder')
Folder.Parent = vain.gui
local methodused

--[[
	Enchantments and effects are the same thing underneath: the game writes both onto the
	character as a StatusEffect_<name> attribute, present while active and removed when it
	wears off. So one read of the character's attributes answers both settings.

	Three companion attributes sit under the same prefix carrying stack counts and extra
	data. They are not effects of their own and would otherwise show up as garbage entries.
]]
local STATUS_PREFIX = 'StatusEffect_'
local STATUS_COMPANION = {stacks = true, extraNumbers = true, extraBooleans = true}

-- At most this many per group, so somebody carrying a dozen effects widens their tag by a
-- readable amount rather than off the side of the screen. The rest are counted, not named.
local STATUS_SHOWN = 4

-- Effects the game keeps for its own bookkeeping - cooldown markers, spam guards, the
-- hidden half of a stacking effect - which mean nothing on a nametag.
local STATUS_INTERNAL = {'_ON_COOLDOWN$', '_INDICATOR$', '_SELF_STACK$', '^ANTI_', '^ANALYTICS', '^AFK_'}

-- The weapon enchants, whose effect name does not contain the word 'enchant' the way the
-- armour and tool ones do. Kept here so an enchantment is still told apart from an
-- ordinary effect even if the enum cannot be read.
local STATUS_WEAPON_ENCHANT = {
	fire_1 = true, static_1 = true, execute_3 = true, critical_strike_1 = true,
	forest_1 = true, cloud_3 = true, soul_reaver = true, berserker_1 = true,
	enchant_cleave = true
}

-- Matched against the effect name rather than the enum member, for the same reason.
local STATUS_HIDDEN = {'_on_cooldown$', '_indicator$', '_self_stack$', '^anti_', '^afk_', '^analytics'}

local StatusEnchant, StatusLabel
local StatusSig, StatusNext = {}, 0

-- How often the attributes are re-read. Nothing fires when an effect lands or wears off
-- that the entity events would catch, so this is polled rather than driven; a fifth of a
-- second is quicker than anyone reacts and costs one table read per entity.
local STATUS_POLL = 0.2

--[[
	Kit progress the server writes onto the player as an attribute, so it replicates to
	everyone: Void Knight's tier, Kaida's claw and spell levels, Ragnar's rage and so on.
	Read off the player (or the character) whichever kit they are on - the attribute only
	exists for the kit that uses it - and only shown once it is above zero.
]]
local KIT_STATS = {
	{'VoidKnightTier', 'Tier'},
	{'Summoner_ClawLevel', 'Claw'},
	{'Summoner_SpellLevel', 'Spell'},
	{'SpiritSummonerTier', 'Tier'},
	{'BountyHunterLevel', 'Lv'},
	{'TinkerMachineLevel', 'Lv'},
	{'BarbarianRageLevel', 'Rage'},
	{'WarlockEnergy', 'Energy'},
	{'InfernalShieldEnergy', 'Shield'},
	{'AeryStacks', 'Stacks'},
	{'BullyStack', 'Stacks'},
	{'SkeletonCount', 'Skeletons'},
	{'Vacuum_GhostCount', 'Ghosts'}
}

local function kitStatsOf(ent)
	if not (KitStats and KitStats.Enabled and ent.Player) then return '' end
	local parts = {}
	for _, stat in KIT_STATS do
		local value = ent.Player:GetAttribute(stat[1])
		if value == nil and ent.Character then value = ent.Character:GetAttribute(stat[1]) end
		if type(value) == 'number' and value > 0 then
			parts[#parts + 1] = stat[2] .. ' ' .. math.floor(value)
		end
	end
	return table.concat(parts, ' · ')
end

--[[
	Worked out once, from the game's own enum rather than a list written out here, so an
	effect added in an update names itself instead of vanishing.

	The label comes from the enum member: BERSERKER_1 reads as Berserker, ARMOR_ENCHANT_
	ABSORPTION as Absorption. The game's own display name is preferred where it has one,
	since it is usually the friendlier word - Greasy rather than Greased - but it only
	covers about two thirds of them, and none of the ones worth calling an enchantment.
]]
local function statusTitle(name)
	local words = {}
	for word in name:gsub('_%d+$', ''):gmatch('[^_]+') do
		words[#words + 1] = word:sub(1, 1):upper() .. word:sub(2):lower()
	end
	return table.concat(words, ' ')
end

local function classifyStatus()
	if StatusLabel then return end
	StatusEnchant, StatusLabel = {}, {}

	-- Nicer labels when the enum can be read, nothing worse than plainer wording when it
	-- cannot. Everything below this point works either way.
	local ok, enum = pcall(function() return bedwars.StatusEffectType end)
	if not ok or type(enum) ~= 'table' then return end

	for name, value in enum do
		-- Members only. Some of these enums carry a reverse map alongside the forward one,
		-- and a lowercase key there would otherwise read as an effect called GREASED.
		if type(name) ~= 'string' or type(value) ~= 'string' or name ~= name:upper() then continue end

		local internal = false
		for _, pattern in STATUS_INTERNAL do
			if name:find(pattern) then
				internal = true
				break
			end
		end
		if internal then continue end

		-- An enchantment is anything the enum calls one, however it is spelt: ENCHANT_FIRE,
		-- ARMOR_ENCHANT_FROST, GROUNDED_ENCHANT.
		local enchant = name:find('ENCHANT') ~= nil
		StatusEnchant[value] = enchant

		local ok, meta = pcall(function() return bedwars.StatusEffectMeta[value] end)
		StatusLabel[value] = (not enchant and ok and meta and meta.displayName) or statusTitle((name:gsub('^.*ENCHANT_', ''):gsub('_ENCHANT$', '')))
	end
end

-- What is currently on the character, split the two ways the settings ask for. Sorted,
-- because attributes come back in no particular order and an unsorted tag would shuffle
-- its own words every time it refreshed.
local function statusOf(ent)
	classifyStatus()

	local character = ent.Character
	if not character then return end

	local found, effects, attributes = {}, {}, nil
	local ok, result = pcall(character.GetAttributes, character)
	if not ok then return end
	attributes = result

	for key in attributes do
		local name = key:sub(1, #STATUS_PREFIX) == STATUS_PREFIX and key:sub(#STATUS_PREFIX + 1) or nil
		if not name or STATUS_COMPANION[name:match('_([%a]+)$') or ''] then continue end

		--[[
			An effect the enum did not name still gets shown, under its own name tidied up.

			This is the whole reason enchantments were coming out blank: they are perfectly
			ordinary status effects, so anything that stops the enum being read - a renamed
			module, a Flamework wrapper that does not iterate - silently emptied the table
			and every lookup missed. Nothing here depends on that table existing any more.
		]]
		local label = StatusLabel[name]
		if not label then
			local hidden = false
			for _, pattern in STATUS_HIDDEN do
				if name:find(pattern) then
					hidden = true
					break
				end
			end
			if hidden then continue end
			label = statusTitle(name)
		end

		local stacks = attributes[key .. '_stacks']
		if type(stacks) == 'number' and stacks > 1 then
			label = label .. ' x' .. stacks
		end

		-- Whether it is an enchant comes from the game's enchant meta (the shared enchants
		-- helper): its name and icon too. The enum guess is only the fallback.
		local enchantInfo, enchantLevel = enchants.lookup(name)
		local enchant = enchantInfo ~= nil
		if enchantInfo then
			label = enchantInfo.name .. (enchantLevel and enchantLevel > 1 and (' ' .. enchantLevel) or '')
			if type(stacks) == 'number' and stacks > 1 then label = label .. ' x' .. stacks end
		elseif StatusEnchant[name] ~= nil then
			enchant = StatusEnchant[name]
		else
			enchant = name:find('enchant') ~= nil or STATUS_WEAPON_ENCHANT[name] or false
		end

		--[[
			Its own icon, whichever kind it is.

			The meta carries an image for enchantments as much as for effects - FIRE_ENCHANT,
			the poison splash, the shield - so both are drawn as icons now rather than the
			enchantments being written out. A few effects have no image of their own but name
			an item instead (Speed Pie is the pie), so that item's icon stands in, and only
			the ones with neither fall back to their word.
		]]
		local ok, meta = pcall(function() return bedwars.StatusEffectMeta[name] end)
		meta = ok and meta or nil
		if meta and meta.noDisplay and not enchantInfo then continue end

		local image = (enchantInfo and enchantInfo.image) or (meta and meta.image) or nil
		if not image and meta and meta.item then
			local got, icon = pcall(function() return bedwars.getIcon({itemType = meta.item}, true) end)
			image = got and icon or nil
		end

		local entry = {label = label, image = image}
		if enchant then
			found[#found + 1] = entry
		else
			effects[#effects + 1] = entry
		end
	end

	table.sort(found, function(a, b) return a.label < b.label end)
	table.sort(effects, function(a, b) return a.label < b.label end)
	return found, effects
end

-- One group rendered, capped, with the overflow counted rather than dropped silently.
local function statusText(list, color)
	if not list or #list == 0 then return '' end

	local shown = list
	if #list > STATUS_SHOWN then
		shown = table.move(list, 1, STATUS_SHOWN, 1, {})
		shown[STATUS_SHOWN + 1] = '+' .. (#list - STATUS_SHOWN)
	end

	local text = ' [' .. table.concat(shown, '] [') .. ']'
	return color and ('<font color="' .. color .. '">' .. text .. '</font>') or text
end

-- Both groups appended to a tag, in whichever form the current renderer wants.
local function appendStatus(ent, text, rich)
	if not ((Enchants and Enchants.Enabled) or (Effects and Effects.Enabled)) then return text end

	local enchants, effects = statusOf(ent)
	--[[
		Both groups are drawn as icons now, so the rich renderer appends nothing - it lets
		drawEffects place the images. The Drawing renderer cannot place an image, so there
		it keeps the words for whichever groups are switched on.
	]]
	if not rich then
		local words = {}
		if Enchants and Enchants.Enabled then
			for _, entry in enchants do words[#words + 1] = entry.label end
		end
		if Effects and Effects.Enabled then
			for _, entry in effects do words[#words + 1] = entry.label end
		end
		text = text .. statusText(words)
	end
	return text
end

--[[
	The in-game ranked division - Diamond, Platinum, Nightmare.

	It is on neither the player nor the character. The game asks the server for it through
	a FetchRanks call and keeps the answers in its own RankController cache, so this asks
	that same controller, once per player, and keeps the answer for the round.

	A player with no ranked history answers with nothing, stored as false so they are not
	asked about again on every sweep.
]]
local Divisions = {}
local DivisionFetching = false
local DivisionsChanged = false

local function divisionOf(plr)
	local division = Divisions[plr.UserId]
	if not division and division ~= 0 then return end

	local ok, meta = pcall(function() return bedwars.RankMeta[division] end)
	if not ok or type(meta) ~= 'table' then return end

	-- The tier rather than the division, so it reads Diamond rather than Diamond 2.
	local tier = meta.tier
	return type(tier) == 'string' and (tier:sub(1, 1):upper() .. tier:sub(2)) or meta.name
end

-- The game's own badge for a division, rather than the word for it.
local function divisionImage(plr)
	local division = Divisions[plr.UserId]
	if not division and division ~= 0 then return end

	local ok, meta = pcall(function() return bedwars.RankMeta[division] end)
	if not ok or type(meta) ~= 'table' then return end
	return meta.image
end

local MEASURE = Vector2.new(100000, 100000)

--[[
	A run of spaces standing in for the badge.

	RichText cannot place an image inline, so the badge is a child image laid over a gap
	held open in the text. The gap is measured in spaces at the tag's own font and size, so
	it stays the right width at any Scale rather than being a fixed guess.
]]
local function fetchDivisions()
	if DivisionFetching or not (Rank and Rank.Enabled) then return end

	local ids = {}
	for _, plr in playersService:GetPlayers() do
		if Divisions[plr.UserId] == nil then
			ids[#ids + 1] = plr.UserId
		end
	end
	if #ids == 0 then return end

	DivisionFetching = true
	task.spawn(function()
		local ok, result = pcall(function()
			return bedwars.RankController:getRanks(ids):expect()
		end)
		DivisionFetching = false

		-- A failed call leaves them unasked so the next sweep tries again, rather than
		-- marking them rankless and never looking at them a second time.
		if not ok or type(result) ~= 'table' then return end

		for _, id in ids do
			Divisions[id] = false
		end
		for _, entry in result do
			if type(entry) == 'table' and entry.userId then
				Divisions[entry.userId] = entry.rankDivision or false
			end
		end

		-- Left for the render loop to act on. Rebuilding here would mean naming Updated,
		-- which is declared further down the file, so the name would reach a global that
		-- does not exist rather than the table meant.
		DivisionsChanged = true
	end)
end

-- True once per interval for the whole set, rather than each entity keeping its own
-- clock, so one pass re-reads everyone or nobody.
local function statusDue()
	local now = os.clock()
	if now < StatusNext then return false end
	StatusNext = now + STATUS_POLL
	return true
end

-- The set of what is showing, as one string, so the loop can tell a real change from a
-- re-read that found exactly the same thing and skip the rebuild.
local function statusSignature(ent)
	local enchants, effects = statusOf(ent)
	if not enchants then return kitStatsOf(ent) end

	local parts = {}
	for _, entry in enchants do
		parts[#parts + 1] = entry.label
	end
	parts[#parts + 1] = '|'
	for _, entry in effects do
		parts[#parts + 1] = entry.label
	end
	parts[#parts + 1] = '|' .. kitStatsOf(ent)
	return table.concat(parts, ',')
end

--[[
	The row of effect icons that sits above the name.

	Rebuilt whole rather than reconciled: there are only ever a handful, and the set
	changes rarely enough that tracking which one moved costs more than it saves.
]]
local function drawEffects(nametag, ent)
	local strip = nametag:FindFirstChild('Effects')
	if not strip then return end

	strip:ClearAllChildren()

	local layout = Instance.new('UIListLayout')
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = strip

	local wantEnchants = Enchants and Enchants.Enabled
	local wantEffects = Effects and Effects.Enabled
	if not (wantEnchants or wantEffects) then
		strip.Visible = false
		return
	end

	local enchants, effects = statusOf(ent)

	-- Enchantments first, then effects, so a tag reads the same way every time. Both are
	-- drawn as their own icon; the handful with no icon keep their word rather than vanish.
	local entries = {}
	if wantEnchants and enchants then
		for _, entry in enchants do entries[#entries + 1] = entry end
	end
	if wantEffects and effects then
		for _, entry in effects do entries[#entries + 1] = entry end
	end
	if #entries == 0 then
		strip.Visible = false
		return
	end

	local size = math.max(10, math.floor(18 * Scale.Value))
	local shown = 0

	for _, entry in entries do
		if shown >= STATUS_SHOWN then break end
		shown += 1

		if entry.image then
			local icon = Instance.new('ImageLabel')
			icon.BackgroundTransparency = 1
			icon.Size = UDim2.fromOffset(size, size)
			icon.Image = entry.image
			icon.LayoutOrder = shown
			icon.Parent = strip
		else
			local word = Instance.new('TextLabel')
			word.BackgroundTransparency = 1
			word.AutomaticSize = Enum.AutomaticSize.X
			word.Size = UDim2.fromOffset(0, size)
			word.Text = entry.label
			word.TextColor3 = Color3.new(1, 1, 1)
			word.TextStrokeTransparency = 0.4
			word.TextSize = math.max(8, math.floor(size * 0.6))
			word.FontFace = FontOption.Value
			word.LayoutOrder = shown
			word.Parent = strip
		end
	end

	strip.Size = UDim2.fromOffset(0, size)
	strip.Visible = shown > 0
end

--[[
	A tag is a row of separate pieces - the distance, the ranked badge, the name and the
	health - laid out side by side by a UIListLayout inside a Row frame, with the tag's
	background sized to that row. Nothing is measured: each piece takes its own room, so
	a badge or an icon can never end up over the text. The equipment icons and the status
	strip sit above the tag, outside the row.
]]
local function newPiece(row, name, order)
	local label = Instance.new('TextLabel')
	label.Name = name
	label.BackgroundTransparency = 1
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromScale(0, 1)
	label.RichText = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.LayoutOrder = order
	label.Parent = row
	return label
end

local function textHeight()
	return math.floor(14 * Scale.Value) + 3
end

local Added = {
	Normal = function(ent)
		if not Targets.Players.Enabled and ent.Player then return end
		if not Targets.NPCs.Enabled and ent.NPC then return end
		if Teammates.Enabled and (not ent.Targetable) and (not ent.Friend) then return end

		local height = textHeight()
		local nametag = Instance.new('Frame')
		nametag.Name = ent.Player and ent.Player.Name or ent.Character.Name
		nametag.AnchorPoint = Vector2.new(0.5, 1)
		nametag.BackgroundColor3 = Color3.new()
		nametag.BackgroundTransparency = Background.Value
		nametag.BorderSizePixel = 0
		nametag.Size = UDim2.fromOffset(60, height + 4)
		nametag.Visible = false
		Instance.new('UICorner', nametag).CornerRadius = UDim.new(0, 4)

		local row = Instance.new('Frame')
		row.Name = 'Row'
		row.BackgroundTransparency = 1
		row.AutomaticSize = Enum.AutomaticSize.X
		row.Size = UDim2.fromOffset(0, height)
		row.Position = UDim2.fromOffset(4, 2)
		row.Parent = nametag
		local layout = Instance.new('UIListLayout')
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 4)
		layout.Parent = row

		newPiece(row, 'Distance', 1)
		local rankicon = Instance.new('ImageLabel')
		rankicon.Name = 'RankIcon'
		rankicon.BackgroundTransparency = 1
		rankicon.Size = UDim2.fromOffset(height, height)
		rankicon.ScaleType = Enum.ScaleType.Fit
		rankicon.LayoutOrder = 2
		rankicon.Visible = false
		rankicon.Parent = row
		newPiece(row, 'NameLabel', 3)
		newPiece(row, 'HealthLabel', 4)
		newPiece(row, 'KitStat', 5)

		if Equipment.Enabled then
			for i, v in {'Hand', 'Helmet', 'Chestplate', 'Boots', 'Kit'} do
				local Icon = Instance.new('ImageLabel')
				Icon.Name = v
				Icon.Size = UDim2.fromOffset(30, 30)
				Icon.AnchorPoint = Vector2.new(0.5, 1)
				Icon.Position = UDim2.new(0.5, (i - 3) * 30, 0, -2)
				Icon.BackgroundTransparency = 1
				Icon.Image = ''
				Icon.Parent = nametag
			end
		end

		local strip = Instance.new('Frame')
		strip.Name = 'Effects'
		strip.AnchorPoint = Vector2.new(0.5, 1)
		strip.Position = UDim2.new(0.5, 0, 0, Equipment.Enabled and -34 or -2)
		strip.Size = UDim2.fromOffset(0, 0)
		strip.AutomaticSize = Enum.AutomaticSize.X
		strip.BackgroundTransparency = 1
		strip.Visible = false
		strip.Parent = nametag

		nametag.Parent = Folder
		Reference[ent] = nametag
		-- Filled in by Updated, which the loop runs for any tag not built yet.
	end,
	Drawing = function(ent)
		if not Targets.Players.Enabled and ent.Player then return end
		if not Targets.NPCs.Enabled and ent.NPC then return end
		if Teammates.Enabled and (not ent.Targetable) and (not ent.Friend) then return end

		local nametag = {}
		nametag.BG = Drawing.new('Square')
		nametag.BG.Filled = true
		nametag.BG.Transparency = 1 - Background.Value
		nametag.BG.Color = Color3.new()
		nametag.BG.ZIndex = 1
		nametag.Text = Drawing.new('Text')
		nametag.Text.Size = 15 * Scale.Value
		nametag.Text.Font = 0
		nametag.Text.ZIndex = 2
		Strings[ent] = ent.Player and whitelist:tag(ent.Player, true)..(DisplayName.Enabled and ent.Player.DisplayName or ent.Player.Name) or ent.Character.Name

		if Rank.Enabled and ent.Player then
			local division = divisionOf(ent.Player)
			if division then
				Strings[ent] = Strings[ent]..' '..division
			end
		end

		if Health.Enabled then
			Strings[ent] = Strings[ent]..' '..math.round(ent.Health)
		end

		Strings[ent] = appendStatus(ent, Strings[ent], false)
		local kitText = kitStatsOf(ent)
		if kitText ~= '' then Strings[ent] = Strings[ent]..' ['..kitText..']' end

		if Distance.Enabled then
			Strings[ent] = '[%s] '..Strings[ent]
		end

		nametag.Text.Text = Strings[ent]
		nametag.Text.Color = entitylib.getEntityColor(ent) or Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
		nametag.BG.Size = Vector2.new(nametag.Text.TextBounds.X + 8, nametag.Text.TextBounds.Y + 7)
		Reference[ent] = nametag
	end
}

local Removed = {
	Normal = function(ent)
		local v = Reference[ent]
		if v then
			Reference[ent] = nil
			Strings[ent] = nil
			Sizes[ent] = nil
			Prefixes[ent] = nil
			StatusSig[ent] = nil
			v:Destroy()
		end
	end,
	Drawing = function(ent)
		local v = Reference[ent]
		if v then
			Reference[ent] = nil
			Strings[ent] = nil
			Sizes[ent] = nil
			Prefixes[ent] = nil
			StatusSig[ent] = nil
			for _, obj in v do
				pcall(function()
					obj.Visible = false
					obj:Remove()
				end)
			end
		end
	end
}

local Updated = {
	Normal = function(ent)
		local nametag = Reference[ent]
		if not nametag then return end
		local row = nametag:FindFirstChild('Row')
		if not row then return end
		Sizes[ent] = nil
		-- Marks the tag as built, for the loop's rebuild check.
		Strings[ent] = true

		local size = math.floor(14 * Scale.Value)
		local font = FontOption.Value
		local height = textHeight()
		row.Size = UDim2.fromOffset(0, height)
		for _, piece in {row.Distance, row.NameLabel, row.HealthLabel, row.KitStat} do
			piece.TextSize = size
			piece.FontFace = font
		end

		row.Distance.Visible = Distance.Enabled
		row.NameLabel.Text = ent.Player and whitelist:tag(ent.Player, true, true)..(DisplayName.Enabled and ent.Player.DisplayName or ent.Player.Name) or ent.Character.Name
		row.NameLabel.TextColor3 = entitylib.getEntityColor(ent) or Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)

		row.HealthLabel.Visible = Health.Enabled
		if Health.Enabled then
			row.HealthLabel.Text = tostring(math.round(ent.Health))
			row.HealthLabel.TextColor3 = Color3.fromHSV(math.clamp(ent.Health / math.max(ent.MaxHealth, 1), 0, 1) / 2.5, 0.89, 0.75)
		end

		local kitText = kitStatsOf(ent)
		row.KitStat.Text = kitText
		row.KitStat.TextColor3 = Color3.fromRGB(255, 200, 60)
		row.KitStat.Visible = kitText ~= ''

		local image = Rank and Rank.Enabled and ent.Player and divisionImage(ent.Player) or nil
		row.RankIcon.Image = image or ''
		row.RankIcon.Visible = image ~= nil
		row.RankIcon.Size = UDim2.fromOffset(height, height)

		if Equipment.Enabled and store.inventories[ent.Player] and nametag:FindFirstChild('Hand') then
			local kit = ent.Player:GetAttribute('PlayingAsKit')
			local inventory = store.inventories[ent.Player]
			nametag.Hand.Image = bedwars.getIcon(inventory.hand or {itemType = ''}, true)
			nametag.Helmet.Image = bedwars.getIcon(inventory.armor[4] or {itemType = ''}, true)
			nametag.Chestplate.Image = bedwars.getIcon(inventory.armor[5] or {itemType = ''}, true)
			nametag.Boots.Image = bedwars.getIcon(inventory.armor[6] or {itemType = ''}, true)
			nametag.Kit.Image = kit and kit ~= 'none' and bedwars.BedwarsKitMeta[kit] and bedwars.BedwarsKitMeta[kit].renderImage or ''
		end

		drawEffects(nametag, ent)
	end,
	Drawing = function(ent)
		local nametag = Reference[ent]
		if nametag then
			if vain.ThreadFix then
				setthreadidentity(8)
			end
			Sizes[ent] = nil
			Strings[ent] = ent.Player and whitelist:tag(ent.Player, true)..(DisplayName.Enabled and ent.Player.DisplayName or ent.Player.Name) or ent.Character.Name

			if Rank.Enabled and ent.Player then
				local division = divisionOf(ent.Player)
				if division then
					Strings[ent] = Strings[ent]..' '..division
				end
			end

			if Health.Enabled then
				Strings[ent] = Strings[ent]..' '..math.round(ent.Health)
			end

			Strings[ent] = appendStatus(ent, Strings[ent], false)
			local kitText = kitStatsOf(ent)
			if kitText ~= '' then Strings[ent] = Strings[ent]..' ['..kitText..']' end

			if Distance.Enabled then
				Strings[ent] = '[%s] '..Strings[ent]
				nametag.Text.Text = entitylib.isAlive and string.format(Strings[ent], math.floor((entitylib.character.RootPart.Position - ent.RootPart.Position).Magnitude)) or Strings[ent]
			else
				nametag.Text.Text = Strings[ent]
			end

			nametag.BG.Size = Vector2.new(nametag.Text.TextBounds.X + 8, nametag.Text.TextBounds.Y + 7)
			nametag.Text.Color = entitylib.getEntityColor(ent) or Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
		end
	end
}

local ColorFunc = {
	Normal = function(hue, sat, val)
		local color = Color3.fromHSV(hue, sat, val)
		for i, v in Reference do
			local row = v:FindFirstChild('Row')
			if row then row.NameLabel.TextColor3 = entitylib.getEntityColor(i) or color end
		end
	end,
	Drawing = function(hue, sat, val)
		local color = Color3.fromHSV(hue, sat, val)
		for i, v in Reference do
			v.Text.Color = entitylib.getEntityColor(i) or color
		end
	end
}

--[[
	Tags whose entity is gone, swept up.

	Removal hangs entirely off the EntityRemoved event, and anything that event does not
	reach stays on screen for the rest of the session - a tag built while one render mode
	was active and removed under another, an entity dropped while the module was off, a
	character replaced without the event landing. There is nothing that ever looks again.

	So the render loop checks as it goes. An entity whose character has left the world is
	not one to draw a name over, whatever did or did not fire - and neither is one the
	entity list has let go of: a respawn makes a new entity while the old body can linger
	in the world, which left its tag frozen where the player died.
]]
local function stale(ent, listed)
	if not ent or not listed[ent] then return true end
	local char = ent.Character
	if not (char and char.Parent) then return true end
	local root = ent.RootPart
	return not (root and root.Parent)
end

local function sweep()
	local listed = {}
	for _, ent in entitylib.List do listed[ent] = true end
	for ent in Reference do
		if stale(ent, listed) then
			Removed[methodused](ent)
		end
	end
end

local Loop = {
	Normal = function()
		sweep()
		local due = statusDue()
		if due then
			fetchDivisions()
			if DivisionsChanged then
				DivisionsChanged = false
				for ent in Reference do
					pcall(Updated[methodused], ent)
				end
			end
		end
		for ent, nametag in Reference do
			-- Each tag on its own, so one that errors does not stop the rest from being
			-- moved - which froze every tag on screen.
			pcall(function()
				-- Text that was never built would fail every frame; build it now.
				if not Strings[ent] then Updated[methodused](ent) end
				if due and ((Enchants and Enchants.Enabled) or (Effects and Effects.Enabled) or (KitStats and KitStats.Enabled)) then
					local sig = statusSignature(ent)
					if StatusSig[ent] ~= sig then
						StatusSig[ent] = sig
						Updated[methodused](ent)
					end
				end

				if DistanceCheck.Enabled then
					local distance = entitylib.isAlive and (entitylib.character.RootPart.Position - ent.RootPart.Position).Magnitude or math.huge
					if distance < DistanceLimit.ValueMin or distance > DistanceLimit.ValueMax then
						nametag.Visible = false
						return
					end
				end

				local headPos, headVis = gameCamera:WorldToViewportPoint(ent.RootPart.Position + Vector3.new(0, ent.HipHeight + 1, 0))
				nametag.Visible = headVis
				if not headVis then
					return
				end

				local row = nametag:FindFirstChild('Row')
				if Distance.Enabled and row then
					local mag = entitylib.isAlive and math.floor((entitylib.character.RootPart.Position - ent.RootPart.Position).Magnitude) or 0
					if Sizes[ent] ~= mag then
						row.Distance.Text = '<font color="rgb(85, 255, 85)">[</font>' .. mag .. '<font color="rgb(85, 255, 85)">]</font>'
						Sizes[ent] = mag
					end
				end
				-- The background follows the row, which lays itself out.
				if row then
					local width = row.AbsoluteSize.X + 8
					if nametag.Size.X.Offset ~= width then
						nametag.Size = UDim2.fromOffset(width, row.AbsoluteSize.Y + 4)
					end
				end
				nametag.Position = UDim2.fromOffset(headPos.X, headPos.Y)
			end)
		end
	end,
	Drawing = function()
		sweep()
		local due = statusDue()
		if due then
			fetchDivisions()
			if DivisionsChanged then
				DivisionsChanged = false
				for ent in Reference do
					pcall(Updated[methodused], ent)
				end
			end
		end
		for ent, nametag in Reference do
			-- Each tag on its own, so one that errors does not stop the rest from being
			-- moved - which froze every tag on screen.
			pcall(function()
				-- Text that was never built would fail every frame; build it now.
				if not Strings[ent] then Updated[methodused](ent) end
				if due and ((Enchants and Enchants.Enabled) or (Effects and Effects.Enabled) or (KitStats and KitStats.Enabled)) then
					local sig = statusSignature(ent)
					if StatusSig[ent] ~= sig then
						StatusSig[ent] = sig
						Updated[methodused](ent)
					end
				end

				if DistanceCheck.Enabled then
					local distance = entitylib.isAlive and (entitylib.character.RootPart.Position - ent.RootPart.Position).Magnitude or math.huge
					if distance < DistanceLimit.ValueMin or distance > DistanceLimit.ValueMax then
						nametag.Text.Visible = false
						nametag.BG.Visible = false
						return
					end
				end

				local headPos, headVis = gameCamera:WorldToViewportPoint(ent.RootPart.Position + Vector3.new(0, ent.HipHeight + 1, 0))
				nametag.Text.Visible = headVis
				nametag.BG.Visible = headVis
				if not headVis then
					return
				end

				if Distance.Enabled then
					local mag = entitylib.isAlive and math.floor((entitylib.character.RootPart.Position - ent.RootPart.Position).Magnitude) or 0
					if Sizes[ent] ~= mag then
						nametag.Text.Text = string.format(Strings[ent], mag)
						nametag.BG.Size = Vector2.new(nametag.Text.TextBounds.X + 8, nametag.Text.TextBounds.Y + 7)
						Sizes[ent] = mag
					end
				end
				nametag.BG.Position = Vector2.new(headPos.X - (nametag.BG.Size.X / 2), headPos.Y - nametag.BG.Size.Y)
				nametag.Text.Position = nametag.BG.Position + Vector2.new(4, 3)
			end)
		end
	end
}

NameTags = vain.Categories.Render:CreateModule({
	Name = 'NameTags',
	Function = function(callback)
		if callback then
			methodused = DrawingToggle.Enabled and 'Drawing' or 'Normal'
			if Removed[methodused] then
				NameTags:Clean(entitylib.Events.EntityRemoved:Connect(Removed[methodused]))
			end
			if Added[methodused] then
				for _, v in entitylib.List do
					if Reference[v] then
						Removed[methodused](v)
					end
					Added[methodused](v)
				end
				NameTags:Clean(entitylib.Events.EntityAdded:Connect(function(ent)
					-- Entity events can run on a game thread that may not create instances.
					if vain.ThreadFix then
						setthreadidentity(8)
					end
					if Reference[ent] then
						Removed[methodused](ent)
					end
					Added[methodused](ent)
				end))
			end
			if Updated[methodused] then
				NameTags:Clean(entitylib.Events.EntityUpdated:Connect(Updated[methodused]))
				for _, v in entitylib.List do
					Updated[methodused](v)
				end
			end
			if ColorFunc[methodused] then
				NameTags:Clean(vain.Categories.Friends.ColorUpdate.Event:Connect(function()
					ColorFunc[methodused](Color.Hue, Color.Sat, Color.Value)
				end))
			end
			if Loop[methodused] then
				NameTags:Clean(runService.RenderStepped:Connect(Loop[methodused]))
			end
		else
			if Removed[methodused] then
				for i in Reference do
					Removed[methodused](i)
				end
			end
		end
	end,
	Tooltip = 'Renders nametags on entities through walls.'
})
Targets = NameTags:CreateTargets({
	Players = true,
	Function = function()
		if NameTags.Enabled then
			NameTags:Toggle()
			NameTags:Toggle()
		end
	end,
	Tooltip = 'Which entities this module is allowed to target'
})
FontOption = NameTags:CreateFont({
	Name = 'Font',
	Tooltip = 'Font used for the text',
	Blacklist = 'Arial',
	Function = function()
		if NameTags.Enabled then
			NameTags:Toggle()
			NameTags:Toggle()
		end
	end
})
Color = NameTags:CreateColorSlider({
	Name = 'Player Color',
	Tooltip = 'Color of the name text',
	Function = function(hue, sat, val)
		if NameTags.Enabled and ColorFunc[methodused] then
			ColorFunc[methodused](hue, sat, val)
		end
	end
})
Scale = NameTags:CreateSlider({
	Name = 'Scale',
	Tooltip = 'Size of the nametag',
	Function = function()
		if NameTags.Enabled then
			NameTags:Toggle()
			NameTags:Toggle()
		end
	end,
	Default = 1,
	Min = 0.1,
	Max = 1.5,
	Decimal = 10
})
Background = NameTags:CreateSlider({
	Name = 'Transparency',
	Tooltip = 'How see-through the nametag is',
	Function = function()
		if NameTags.Enabled then
			NameTags:Toggle()
			NameTags:Toggle()
		end
	end,
	Default = 0.5,
	Min = 0,
	Max = 1,
	Decimal = 10
})
Health = NameTags:CreateToggle({
	Name = 'Health',
	Tooltip = 'Shows the target health',
	Function = function()
		if NameTags.Enabled then
			NameTags:Toggle()
			NameTags:Toggle()
		end
	end
})
Distance = NameTags:CreateToggle({
	Name = 'Distance',
	Tooltip = 'Shows how far away the player is',
	Function = function()
		if NameTags.Enabled then
			NameTags:Toggle()
			NameTags:Toggle()
		end
	end
})
Equipment = NameTags:CreateToggle({
	Name = 'Equipment',
	Tooltip = 'Shows what the player is holding and wearing',
	Function = function()
		if NameTags.Enabled then
			NameTags:Toggle()
			NameTags:Toggle()
		end
	end
})
DisplayName = NameTags:CreateToggle({
	Name = 'Use Displayname',
	Tooltip = 'Shows display names instead of usernames',
	Function = function()
		if NameTags.Enabled then
			NameTags:Toggle()
			NameTags:Toggle()
		end
	end,
	Default = true
})
Teammates = NameTags:CreateToggle({
	Name = 'Priority Only',
	Tooltip = 'Hides teammates and non targetable entities',
	Function = function()
		if NameTags.Enabled then
			NameTags:Toggle()
			NameTags:Toggle()
		end
	end,
	Default = true
})
DrawingToggle = NameTags:CreateToggle({
	Name = 'Drawing',
	Tooltip = 'Renders with the Drawing API instead of Roblox instances',
	Function = function()
		if NameTags.Enabled then
			NameTags:Toggle()
			NameTags:Toggle()
		end
	end,
})
DistanceCheck = NameTags:CreateToggle({
	Name = 'Distance Check',
	Tooltip = 'Only shows players within a set distance',
	Function = function(callback)
		DistanceLimit.Object.Visible = callback
	end
})
DistanceLimit = NameTags:CreateTwoSlider({
	Name = 'Player Distance',
	Tooltip = 'Distance range a player must be within',
	Min = 0,
	Max = 256,
	DefaultMin = 0,
	DefaultMax = 64,
	Darker = true,
	Visible = false
})
Rank = NameTags:CreateToggle({
	Name = 'Rank',
	Tooltip = 'Shows their ranked division like Diamond or Nightmare',
	Function = function()
		fetchDivisions()
		if NameTags.Enabled then
			NameTags:Toggle()
			NameTags:Toggle()
		end
	end
})
Enchants = NameTags:CreateToggle({
	Name = 'Enchantments',
	Tooltip = 'Shows the enchantments they have active, as icons',
	Function = function()
		if NameTags.Enabled then
			NameTags:Toggle()
			NameTags:Toggle()
		end
	end
})
Effects = NameTags:CreateToggle({
	Name = 'Effects',
	Tooltip = 'Shows their active effects like jump, pie or gloop, as icons',
	Function = function()
		if NameTags.Enabled then
			NameTags:Toggle()
			NameTags:Toggle()
		end
	end
})
KitStats = NameTags:CreateToggle({
	Name = 'Kit Stats',
	Tooltip = 'Shows kit levels like Void Knight tier or Kaida claw',
	Function = function()
		if NameTags.Enabled then
			NameTags:Toggle()
			NameTags:Toggle()
		end
	end
})
-- Device was removed: the game tells no client what device anyone else is on, so it
-- showed your own executor's device for every player.