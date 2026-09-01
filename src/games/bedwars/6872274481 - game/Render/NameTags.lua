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
local Device
local Enchants
local Effects
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

	local enchants, effects, attributes = {}, {}, nil
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

		local enchant = StatusEnchant[name]
		if enchant == nil then
			enchant = name:find('enchant') ~= nil or STATUS_WEAPON_ENCHANT[name] or false
		end

		local into = enchant and enchants or effects
		into[#into + 1] = label
	end

	table.sort(enchants)
	table.sort(effects)
	return enchants, effects
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
	if Enchants and Enchants.Enabled then
		text = text .. statusText(enchants, rich and '#d0a3ff')
	end
	if Effects and Effects.Enabled then
		text = text .. statusText(effects, rich and '#7fd8ff')
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
local function rankGap(ent, textSize, font)
	if not (Rank and Rank.Enabled) or not ent.Player or not divisionImage(ent.Player) then return '' end

	local space = getfontsize(' ', textSize, font, MEASURE).X
	if space <= 0 then return ' ' end

	local height = getfontsize('X', textSize, font, MEASURE).Y + 7
	return string.rep(' ', math.max(1, math.ceil((height + 2) / space)))
end

-- The badge dropped into that gap. The text before it is measured as drawn, so the badge
-- lands between the distance and the name however wide the distance happens to be.
local function placeRankIcon(nametag, ent, prefix)
	local icon = nametag:FindFirstChild('RankIcon')
	if not icon then return end

	local image = (Rank and Rank.Enabled) and ent.Player and divisionImage(ent.Player) or nil
	icon.Image = image or ''
	icon.Visible = image ~= nil
	if not image then return end

	local height = nametag.Size.Y.Offset
	icon.Size = UDim2.fromOffset(height, height)
	-- 4 is the tag's own left padding: it is sized to the text plus 8, centred.
	icon.Position = UDim2.new(0, 4 + getfontsize(removeTags(prefix or ''), nametag.TextSize, nametag.FontFace, MEASURE).X, 0.5, 0)
end

-- Everyone not asked about yet, in one call rather than one call each.
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
	if not enchants then return '' end
	return table.concat(enchants, ',') .. '|' .. table.concat(effects, ',')
end

local Added = {
	Normal = function(ent)
		if not Targets.Players.Enabled and ent.Player then return end
		if not Targets.NPCs.Enabled and ent.NPC then return end
		if Teammates.Enabled and (not ent.Targetable) and (not ent.Friend) then return end

		local nametag = Instance.new('TextLabel')
		Strings[ent] = ent.Player and whitelist:tag(ent.Player, true, true)..(DisplayName.Enabled and ent.Player.DisplayName or ent.Player.Name) or ent.Character.Name

		if Device.Enabled and ent.Player then
			local executor = (identifyexecutor and identifyexecutor() or {'Unknown'})[1] or 'Unknown'
			local deviceIcon = executor:find('Mobile') and '📱' or '💻'
			Strings[ent] = Strings[ent]..' '..deviceIcon
		end

		if Health.Enabled then
			local healthColor = Color3.fromHSV(math.clamp(ent.Health / ent.MaxHealth, 0, 1) / 2.5, 0.89, 0.75)
			Strings[ent] = Strings[ent]..' <font color="rgb('..tostring(math.floor(healthColor.R * 255))..','..tostring(math.floor(healthColor.G * 255))..','..tostring(math.floor(healthColor.B * 255))..')">'..math.round(ent.Health)..'</font>'
		end

		Strings[ent] = appendStatus(ent, Strings[ent], true)

		-- The badge sits between the distance and the name, so the distance is kept aside
		-- as the run of text the badge has to clear.
		Prefixes[ent] = Distance.Enabled and '<font color="rgb(85, 255, 85)">[</font><font color="rgb(255, 255, 255)">%s</font><font color="rgb(85, 255, 85)">]</font> ' or ''
		Strings[ent] = Prefixes[ent]..rankGap(ent, 14 * Scale.Value, FontOption.Value)..Strings[ent]

		if Equipment.Enabled then
			for i, v in {'Hand', 'Helmet', 'Chestplate', 'Boots', 'Kit'} do
				local Icon = Instance.new('ImageLabel')
				Icon.Name = v
				Icon.Size = UDim2.fromOffset(30, 30)
				Icon.Position = UDim2.fromOffset(-60 + (i * 30), -30)
				Icon.BackgroundTransparency = 1
				Icon.Image = ''
				Icon.Parent = nametag
			end
		end

		nametag.TextSize = 14 * Scale.Value
		nametag.FontFace = FontOption.Value
		local size = getfontsize(removeTags(Strings[ent]), nametag.TextSize, nametag.FontFace, Vector2.new(100000, 100000))
		nametag.Name = ent.Player and ent.Player.Name or ent.Character.Name
		nametag.Size = UDim2.fromOffset(size.X + 8, size.Y + 7)
		nametag.AnchorPoint = Vector2.new(0.5, 1)
		nametag.BackgroundColor3 = Color3.new()
		nametag.BackgroundTransparency = Background.Value
		nametag.BorderSizePixel = 0
		nametag.Visible = false
		nametag.Text = Strings[ent]

		local rankicon = Instance.new('ImageLabel')
		rankicon.Name = 'RankIcon'
		rankicon.AnchorPoint = Vector2.new(0, 0.5)
		rankicon.BackgroundTransparency = 1
		rankicon.ScaleType = Enum.ScaleType.Fit
		rankicon.Image = ''
		rankicon.Visible = false
		rankicon.Parent = nametag
		-- With a distance showing, the loop places it instead, once the number is in the
		-- text and there is something real to measure.
		if not Distance.Enabled then
			placeRankIcon(nametag, ent, '')
		end

		nametag.TextColor3 = entitylib.getEntityColor(ent) or Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
		nametag.RichText = true
		nametag.Parent = Folder
		Reference[ent] = nametag
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

		if Device.Enabled and ent.Player then
			local executor = (identifyexecutor and identifyexecutor() or {'Unknown'})[1] or 'Unknown'
			local deviceIcon = executor:find('Mobile') and '📱' or '💻'
			Strings[ent] = Strings[ent]..' '..deviceIcon
		end

		if Health.Enabled then
			Strings[ent] = Strings[ent]..' '..math.round(ent.Health)
		end

		Strings[ent] = appendStatus(ent, Strings[ent], false)

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
		if nametag then
			Sizes[ent] = nil
			Strings[ent] = ent.Player and whitelist:tag(ent.Player, true, true)..(DisplayName.Enabled and ent.Player.DisplayName or ent.Player.Name) or ent.Character.Name

			if Device.Enabled and ent.Player then
				local executor = (identifyexecutor and identifyexecutor() or {'Unknown'})[1] or 'Unknown'
				local deviceIcon = executor:find('Mobile') and '📱' or '💻'
				Strings[ent] = Strings[ent]..' '..deviceIcon
			end

			if Health.Enabled then
				local healthColor = Color3.fromHSV(math.clamp(ent.Health / ent.MaxHealth, 0, 1) / 2.5, 0.89, 0.75)
				Strings[ent] = Strings[ent]..' <font color="rgb('..tostring(math.floor(healthColor.R * 255))..','..tostring(math.floor(healthColor.G * 255))..','..tostring(math.floor(healthColor.B * 255))..')">'..math.round(ent.Health)..'</font>'
			end

			Strings[ent] = appendStatus(ent, Strings[ent], true)

			Prefixes[ent] = Distance.Enabled and '<font color="rgb(85, 255, 85)">[</font><font color="rgb(255, 255, 255)">%s</font><font color="rgb(85, 255, 85)">]</font> ' or ''
			Strings[ent] = Prefixes[ent]..rankGap(ent, nametag.TextSize, nametag.FontFace)..Strings[ent]

			if Equipment.Enabled and store.inventories[ent.Player] then
				local kit = ent.Player:GetAttribute('PlayingAsKit')
				local inventory = store.inventories[ent.Player]
				nametag.Hand.Image = bedwars.getIcon(inventory.hand or {itemType = ''}, true)
				nametag.Helmet.Image = bedwars.getIcon(inventory.armor[4] or {itemType = ''}, true)
				nametag.Chestplate.Image = bedwars.getIcon(inventory.armor[5] or {itemType = ''}, true)
				nametag.Boots.Image = bedwars.getIcon(inventory.armor[6] or {itemType = ''}, true)
				nametag.Kit.Image = kit and kit ~= 'none' and bedwars.BedwarsKitMeta[kit].renderImage or ''
			end

			local size = getfontsize(removeTags(Strings[ent]), nametag.TextSize, nametag.FontFace, Vector2.new(100000, 100000))
			nametag.Size = UDim2.fromOffset(size.X + 8, size.Y + 7)
			nametag.Text = Strings[ent]
			-- Placed here only when there is no distance to measure around; otherwise the
			-- loop does it, once the number is actually in the text.
			if not Distance.Enabled then
				placeRankIcon(nametag, ent, '')
			end
		end
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

			if Device.Enabled and ent.Player then
				local executor = (identifyexecutor and identifyexecutor() or {'Unknown'})[1] or 'Unknown'
				local deviceIcon = executor:find('Mobile') and '📱' or '💻'
				Strings[ent] = Strings[ent]..' '..deviceIcon
			end

			if Health.Enabled then
				Strings[ent] = Strings[ent]..' '..math.round(ent.Health)
			end

			Strings[ent] = appendStatus(ent, Strings[ent], false)

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
			v.TextColor3 = entitylib.getEntityColor(i) or color
		end
	end,
	Drawing = function(hue, sat, val)
		local color = Color3.fromHSV(hue, sat, val)
		for i, v in Reference do
			v.Text.Color = entitylib.getEntityColor(i) or color
		end
	end
}

local Loop = {
	Normal = function()
		local due = statusDue()
		if due then
			fetchDivisions()
			if DivisionsChanged then
				DivisionsChanged = false
				for ent in Reference do
					Updated[methodused](ent)
				end
			end
		end
		for ent, nametag in Reference do
			if due and ((Enchants and Enchants.Enabled) or (Effects and Effects.Enabled)) then
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
					continue
				end
			end

			local headPos, headVis = gameCamera:WorldToViewportPoint(ent.RootPart.Position + Vector3.new(0, ent.HipHeight + 1, 0))
			nametag.Visible = headVis
			if not headVis then
				continue
			end

			if Distance.Enabled then
				local mag = entitylib.isAlive and math.floor((entitylib.character.RootPart.Position - ent.RootPart.Position).Magnitude) or 0
				if Sizes[ent] ~= mag then
					nametag.Text = string.format(Strings[ent], mag)
					local ize = getfontsize(removeTags(nametag.Text), nametag.TextSize, nametag.FontFace, Vector2.new(100000, 100000))
					nametag.Size = UDim2.fromOffset(ize.X + 8, ize.Y + 7)
					Sizes[ent] = mag
					-- Only when the number changed, so the badge is not re-measured every frame.
					placeRankIcon(nametag, ent, string.format(Prefixes[ent] or '', mag))
				end
			end
			nametag.Position = UDim2.fromOffset(headPos.X, headPos.Y)
		end
	end,
	Drawing = function()
		local due = statusDue()
		if due then
			fetchDivisions()
			if DivisionsChanged then
				DivisionsChanged = false
				for ent in Reference do
					Updated[methodused](ent)
				end
			end
		end
		for ent, nametag in Reference do
			if due and ((Enchants and Enchants.Enabled) or (Effects and Effects.Enabled)) then
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
					continue
				end
			end

			local headPos, headVis = gameCamera:WorldToViewportPoint(ent.RootPart.Position + Vector3.new(0, ent.HipHeight + 1, 0))
			nametag.Text.Visible = headVis
			nametag.BG.Visible = headVis
			if not headVis then
				continue
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
	Tooltip = 'Shows the enchantments they have active',
	Function = function()
		if NameTags.Enabled then
			NameTags:Toggle()
			NameTags:Toggle()
		end
	end
})
Effects = NameTags:CreateToggle({
	Name = 'Effects',
	Tooltip = 'Shows their active effects like jump, pie or gloop',
	Function = function()
		if NameTags.Enabled then
			NameTags:Toggle()
			NameTags:Toggle()
		end
	end
})
Device = NameTags:CreateToggle({
	Name = 'Device',
	Tooltip = 'Shows executor type with an icon',
	Function = function()
		if NameTags.Enabled then
			NameTags:Toggle()
			NameTags:Toggle()
		end
	end
})