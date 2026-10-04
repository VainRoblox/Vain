local KitDisplay
local RankedOnly
local KitHistory
local HistoryCount
local ShowTeam, MostPlayed, IconSize, RowPosition, WinTint
local showsPlayer

--[[
	The kits someone played in their last matches, from their match history (fetched once
	per player by the shared matchHistory helper). Each match lists every player with the
	kit they played under bedwars.kit, and the teams with their placement.
]]

-- Whether they won: their team in match.teams is the one placed first (placement 0).
-- Nil when the match does not say.
local function wonMatch(match, userId)
	for _, team in (type(match.teams) == 'table' and match.teams or {}) do
		local members = type(team) == 'table' and team.members
		if type(members) == 'table' and (members[userId] ~= nil or members[tostring(userId)] ~= nil) then
			local placement = tonumber(team.placement)
			if placement == nil then return nil end
			return placement == 0
		end
	end
	return nil
end

local function fetchHistory(player, callback)
	local userId = player.UserId
	matchHistory.fetch(player, function(matches, failed)
		local kits = {}
		for _, match in matches do
			if #kits >= 10 then break end
			local entry = matchHistory.entryFor(match, userId)
			local kit = entry and entry.bedwars and entry.bedwars.kit
			if type(kit) == 'string' and kit ~= '' then
				kits[#kits + 1] = {kit = kit, won = wonMatch(match, userId)}
			end
		end
		callback(kits, failed)
	end)
end

-- A small row of kit icons in the bottom right of a player's card, newest on the right
-- edge. Kept inside the card, as anything hanging off it is clipped by the draft list.
local POSITIONS = {
	['Bottom Right'] = {Vector2.new(1, 1), UDim2.new(1, -4, 1, -4), Enum.HorizontalAlignment.Right},
	['Top Right'] = {Vector2.new(1, 0), UDim2.new(1, -4, 0, 4), Enum.HorizontalAlignment.Right},
	['Bottom Left'] = {Vector2.new(0, 1), UDim2.new(0, 4, 1, -4), Enum.HorizontalAlignment.Left}
}

-- How far down the card the name bar starts, as a share of the card's height, so the
-- bottom positions sit just above it rather than over the name and the vote label.
local function nameBarTop(card)
	local bar = card:FindFirstChild('TextBackgroundBar', true)
	if not (bar and bar:IsA('GuiObject') and card.AbsoluteSize.Y > 0) then return 1 end
	local top = (bar.AbsolutePosition.Y - card.AbsolutePosition.Y) / card.AbsoluteSize.Y
	return (top > 0.3 and top <= 1) and top or 1
end

local function newRow(card)
	local place = POSITIONS[RowPosition and RowPosition.Value or 'Bottom Right'] or POSITIONS['Bottom Right']
	local row = Instance.new('Frame')
	row.Name = 'KitHistory'
	row.BackgroundTransparency = 1
	row.AnchorPoint = place[1]
	row.Position = place[2]
	if place[1].Y == 1 then
		row.Position = UDim2.new(place[2].X.Scale, place[2].X.Offset, nameBarTop(card), -3)
	end
	row.Size = UDim2.new(0.62, 0, IconSize and IconSize.Value / 100 or 0.2, 0)
	row.ZIndex = 10
	row.Parent = card
	KitDisplay:Clean(row)

	local layout = Instance.new('UIListLayout')
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = place[3]
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = row
	return row
end

local function rowText(row, text)
	local label = Instance.new('TextLabel')
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = text
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(200, 200, 200)
	label.TextStrokeTransparency = 0.5
	label.TextXAlignment = RowPosition and RowPosition.Value == 'Bottom Left' and Enum.TextXAlignment.Left or Enum.TextXAlignment.Right
	label.ZIndex = 10
	label.Parent = row
end

-- Show Team off leaves out kit history on your own team's cards, yours included; their
-- kits still show, as the game shows them anyway.
showsPlayer = function(player)
	if not ShowTeam or ShowTeam.Enabled then return true end
	if player == lplr then return false end
	local mine, theirs = lplr:GetAttribute('Team'), player:GetAttribute('Team')
	return not (mine ~= nil and theirs ~= nil and tostring(mine) == tostring(theirs))
end

local function kitIcon(row, kit, order, transparency)
	local meta = bedwars.BedwarsKitMeta[kit]
	local icon = Instance.new('ImageLabel')
	icon.Name = kit
	icon.LayoutOrder = order
	icon.BackgroundColor3 = Color3.new(0, 0, 0)
	icon.BackgroundTransparency = 0.45
	icon.SizeConstraint = Enum.SizeConstraint.RelativeYY
	icon.Size = UDim2.fromScale(1, 1)
	icon.ScaleType = Enum.ScaleType.Crop
	icon.Image = meta and meta.renderImage or ''
	icon.ImageTransparency = transparency
	icon.ZIndex = 10
	icon.Parent = row
	Instance.new('UICorner', icon).CornerRadius = UDim.new(0.25, 0)
	return icon
end

local function drawHistory(card, player)
	if not card then return end
	local old = card:FindFirstChild('KitHistory')
	if old then old:Destroy() end
	if not (KitHistory and KitHistory.Enabled and player) then return end
	if not showsPlayer(player) then return end

	-- Cards are reused as the list reorders, so the answer is only drawn if the card still
	-- shows the player it was asked for.
	card:SetAttribute('KitHistoryUser', player.UserId)
	rowText(newRow(card), '…')
	fetchHistory(player, function(kits, failed)
		if not (card.Parent and KitDisplay.Enabled) then return end
		if card:GetAttribute('KitHistoryUser') ~= player.UserId then return end
		if card:FindFirstChild('KitHistory') then card.KitHistory:Destroy() end

		local row = newRow(card)
		local shown = math.min(#kits, HistoryCount and HistoryCount.Value or 10)
		if shown == 0 then
			-- No answer is not the same as no matches: unavailable only once the lookup
			-- has failed four times over half a minute.
			rowText(row, failed and 'History unavailable' or 'No history')
			return
		end
		local leftAligned = RowPosition and RowPosition.Value == 'Bottom Left'
		for i = 1, shown do
			-- The newest sits on the outer edge of the card.
			local order = leftAligned and i or (shown - i)
			local icon = kitIcon(row, kits[i].kit, order, math.clamp((i - 1) * 0.05, 0, 0.45))
			if WinTint and WinTint.Enabled and kits[i].won ~= nil then
				local stroke = Instance.new('UIStroke')
				stroke.Thickness = 1
				stroke.Color = kits[i].won and Color3.fromRGB(90, 220, 110) or Color3.fromRGB(235, 80, 80)
				stroke.Parent = icon
			end
		end

		-- Their most played kit across those matches, with how many times.
		if MostPlayed and MostPlayed.Enabled then
			local counts, best, bestCount = {}, nil, 0
			for i = 1, shown do
				local kit = kits[i].kit
				counts[kit] = (counts[kit] or 0) + 1
				if counts[kit] > bestCount then best, bestCount = kit, counts[kit] end
			end
			if best and bestCount > 1 then
				local order = leftAligned and -2 or (shown + 2)
				local spacer = Instance.new('Frame')
				spacer.BackgroundTransparency = 1
				spacer.Size = UDim2.fromOffset(4, 0)
				spacer.LayoutOrder = leftAligned and -1 or (shown + 1)
				spacer.Parent = row
				local icon = kitIcon(row, best, order, 0)
				local count = Instance.new('TextLabel')
				count.BackgroundTransparency = 1
				count.AnchorPoint = Vector2.new(1, 1)
				count.Position = UDim2.fromScale(1.1, 1.1)
				count.Size = UDim2.fromScale(0.7, 0.55)
				count.Text = 'x' .. bestCount
				count.TextScaled = true
				count.Font = Enum.Font.GothamBold
				count.TextColor3 = Color3.new(1, 1, 1)
				count.TextStrokeTransparency = 0.2
				count.ZIndex = 11
				count.Parent = icon
				local mark = Instance.new('UIStroke')
				mark.Thickness = 1
				mark.Color = Color3.fromRGB(255, 210, 90)
				mark.Parent = icon
			end
		end
	end)
end

local function getKitMeta(player)
	local kit = player:GetAttribute('PlayingAsKits') or player:GetAttribute('PlayingAsKit') or 'none'
	return bedwars.BedwarsKitMeta[kit] or bedwars.BedwarsKitMeta.none or {renderImage = ''}
end

local function getPlayerFromDraft(render, name)
	local id = render and render:match('id=(%d+)')
	if id then
		local player = playersService:GetPlayerByUserId(tonumber(id))
		if player then
			return player
		end
	end

	for _, v in playersService:GetPlayers() do
		if render and render:find('id=' .. v.UserId, 1, true) then
			return v
		end

		if name and (v.Name == name or v.DisplayName == name or v:GetAttribute('DisguiseDisplayName') == name) then
			return v
		end

		local displayName
		pcall(function()
			displayName = bedwars.StreamerModeController:getDisplayName(v)
		end)
		if name and displayName == name then
			return v
		end
	end
	return nil
end

local waitForChild = function(start, ...)
	local parent = start
	for _, v in {...} do
		parent = parent and parent:WaitForChild(v, 5)
		if not parent then
			break
		end
	end
	return parent
end

local function getPlayerName(card)
	local textbar = card and card:FindFirstChild('TextBackgroundBar')
	local label = textbar and textbar:FindFirstChild('PlayerName') or card and card:FindFirstChild('PlayerName', true)
	return label and label.Text or ''
end

local function getDraftCard(container)
	if not container then
		return
	end
	return container.Name == 'MatchDraftPlayerCard' and container or container:FindFirstChild('MatchDraftPlayerCard', true)
end

local function callback5v5(v, plr)
	if not v then
		return
	end
	local render = v:FindFirstChild('PlayerRender', true)
	local player = plr or getPlayerFromDraft(render and render.Image or '', getPlayerName(v))

	if player then
		local kitImage = getKitMeta(player)
		local roact = v:FindFirstChild('KitImage')

		if not roact then
			roact = Instance.new('ImageLabel', v)
			roact.BackgroundTransparency = 1
			roact.AnchorPoint = Vector2.new(1, 0.5)
			roact.Position = UDim2.fromScale(1.05, 0.5)
			roact.Name = 'KitImage'
			roact.Size = UDim2.fromScale(1.5, 1.5)
			roact.ZIndex = 1
			roact.ImageTransparency = 0.4
			roact.SliceCenter = Rect.new(0, 0, 0, 0)
			roact.SliceScale = 1
			roact.ScaleType = Enum.ScaleType.Crop

			KitDisplay:Clean(roact)

			local ratio = Instance.new('UIAspectRatioConstraint', roact)
			ratio.Name = '1'
			ratio.AspectRatio = 1
			ratio.AspectType = Enum.AspectType.FitWithinMaxSize
			ratio.DominantAxis = Enum.DominantAxis.Width
		end

		roact.Image = kitImage.renderImage
		roact.Position = UDim2.fromScale(1.05, 0)
		tweenService:Create(roact, TweenInfo.new(0.2, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out), {Position = UDim2.fromScale(1.05, 0.4)}):Play()

		local function update()
			roact.Image = getKitMeta(player).renderImage
		end

		-- Re-bind the kit listener to whichever player the card currently shows.
		-- Draft cards are reused as the list reorders, so a card can switch to a
		-- new player; without this the kit image stays stuck on the old player.
		local kitConn
		local function bindKit()
			if kitConn then kitConn:Disconnect() end
			kitConn = player:GetAttributeChangedSignal('PlayingAsKits'):Connect(update)
			KitDisplay:Clean(kitConn)
			update()
			drawHistory(v, player)
		end
		bindKit()

		if render then
			KitDisplay:Clean(render:GetPropertyChangedSignal('Image'):Connect(function()
				local newplayer = getPlayerFromDraft(render.Image, getPlayerName(v))
				if newplayer and newplayer ~= player then
					player = newplayer
					bindKit()
				end
			end))
		end
	end
end

local function callbacksquad(v)
	if not v then
		return
	end
	local render = v:FindFirstChild('PlayerRender', true)
	local player = render and getPlayerFromDraft(render.Image, '') or nil

	if player then
		local kitImage = getKitMeta(player)
		local Roact = v:FindFirstChild('Kitcvrender')

		if not Roact then
			local base = v:FindFirstChild('3') or v:WaitForChild('3', 5)
			if not base then
				return
			end
			Roact = base:Clone()
			Roact.Parent = v
			Roact.Name = 'Kitcvrender'
			KitDisplay:Clean(Roact)
		end

		Roact.Image = kitImage.renderImage

		local function update()
			Roact.Image = getKitMeta(player).renderImage
		end

		-- Keep the kit listener bound to whichever player this card now shows.
		local kitConn
		local function bindKit()
			if kitConn then kitConn:Disconnect() end
			kitConn = player:GetAttributeChangedSignal('PlayingAsKits'):Connect(update)
			KitDisplay:Clean(kitConn)
			update()
			drawHistory(v, player)
		end
		bindKit()

		KitDisplay:Clean(render:GetPropertyChangedSignal('Image'):Connect(function()
			local newplayer = getPlayerFromDraft(render.Image, '')
			if newplayer and newplayer ~= player then
				player = newplayer
				bindKit()
			end
		end))
	end
end

local function setup5v5(DraftApp)
	local Background = DraftApp:FindFirstChild('DraftAppBackground')
	local BodyContainer = Background and Background:FindFirstChild('1') and Background['1']:FindFirstChild('BodyContainer')
	local hooked = false

	for i = 1, 2 do
		local dtc = BodyContainer and BodyContainer:FindFirstChild('Team' .. i .. 'Column')
		if dtc then
			hooked = true
			KitDisplay:Clean(dtc.ChildAdded:Connect(function(child)
				task.delay(0.2, function()
					if KitDisplay.Enabled then
						callback5v5(getDraftCard(child))
					end
				end)
			end))

			for _, v in dtc:GetChildren() do
				if v:IsA('Frame') then
					callback5v5(getDraftCard(v))
				end
			end
		end
	end

	if not hooked then
		for _, label in DraftApp:GetDescendants() do
			if label:IsA('TextLabel') and label.Name == 'PlayerName' then
				local container = label.Parent
				for _ = 1, 3 do
					container = container and container.Parent
				end
				if container then
					callback5v5(getDraftCard(container))
				end
			end
		end

		KitDisplay:Clean(DraftApp.DescendantAdded:Connect(function(child)
			if child:IsA('TextLabel') and child.Name == 'PlayerName' then
				task.delay(0.2, function()
					local container = child.Parent
					for _ = 1, 3 do
						container = container and container.Parent
					end
					if KitDisplay.Enabled and container then
						callback5v5(getDraftCard(container))
					end
				end)
			end
		end))
	end

	return hooked
end

local function setupSquad(DraftApp)
	local Background = DraftApp:FindFirstChild('DraftAppBackground')
	local BodyContainer = Background and Background:FindFirstChild('1') and Background['1']:FindFirstChild('BodyContainer')
	local TeamsColumn = BodyContainer and BodyContainer:FindFirstChild('TeamsColumn')
	if not TeamsColumn then
		return
	end

	for _, v: Instance in TeamsColumn:GetChildren() do
		if v:IsA('Frame') then
			local plrframe = waitForChild(v, '1', '2', '4')
			if plrframe then
				for _, plr in plrframe:GetChildren() do
					callbacksquad(plr)
				end

				-- Apply directly to the newly added card instead of restarting the
				-- whole module (the old code toggled itself off/on, which combined
				-- with the infinite WaitForChild below would hang/flicker it).
				KitDisplay:Clean(plrframe.ChildAdded:Connect(function(plr)
					task.delay(0.2, function()
						if KitDisplay.Enabled then
							callbacksquad(plr)
						end
					end)
				end))
			end
		end
	end
end

-- Ranked by the queue's name, the same way AntiRender picks it out, so a ranked playlist
-- added later is covered without a list to keep up to date.
local function ranked()
	return (store.queueType or ''):find('ranked') ~= nil
end

local function runSetup(DraftApp)
	if not DraftApp or not KitDisplay.Enabled then return end
	if RankedOnly and RankedOnly.Enabled and not ranked() then return end
	-- 5v5 first; if it found no team columns it hooks PlayerName labels itself.
	setup5v5(DraftApp)
	setupSquad(DraftApp)
end

KitDisplay = vain.Categories.Render:CreateModule({
	Name = 'Kit Render',
	Tooltip = 'Enables the Kit Display module',
	Function = function(call)
		if call then
			-- The draft UI (MatchDraftApp) is created at the start of every kit
			-- phase and removed after, so a one-shot wait misses later rounds.
			-- Set up on whatever's there now, and again each time it reappears.
			local existing = lplr.PlayerGui:FindFirstChild('MatchDraftApp')
			if existing then
				runSetup(existing)
			end
			KitDisplay:Clean(lplr.PlayerGui.ChildAdded:Connect(function(child)
				if child.Name == 'MatchDraftApp' and KitDisplay.Enabled then
					task.wait(0.2)
					runSetup(child)
				end
			end))
		end
	end,
	Tooltip = 'Allows you to see the other opponent kits'
})
RankedOnly = KitDisplay:CreateToggle({
	Name = 'Ranked Only',
	Tooltip = 'Only shows kits while queueing ranked',
	Function = function()
		-- Restarted so kit images already drawn come off, or go on, straight away.
		if KitDisplay.Enabled then
			KitDisplay:Toggle()
			KitDisplay:Toggle()
		end
	end
})
KitHistory = KitDisplay:CreateToggle({
	Name = 'Kit History',
	Tooltip = 'Shows the kits each player used in their last matches',
	Function = function(callback)
		if HistoryCount and HistoryCount.Object then HistoryCount.Object.Visible = callback end
		if KitDisplay.Enabled then
			KitDisplay:Toggle()
			KitDisplay:Toggle()
		end
	end
})
HistoryCount = KitDisplay:CreateSlider({
	Name = 'History Matches',
	Tooltip = 'How many of their recent matches to show',
	Min = 1,
	Max = 10,
	Default = 10,
	Darker = true,
	Visible = false
})
ShowTeam = KitDisplay:CreateToggle({
	Name = 'Show Team',
	Tooltip = 'Also shows kit history for your team',
	Default = true,
	Function = function()
		if KitDisplay.Enabled then
			KitDisplay:Toggle()
			KitDisplay:Toggle()
		end
	end
})
MostPlayed = KitDisplay:CreateToggle({
	Name = 'Most Played',
	Tooltip = 'Marks their most played kit with a count',
	Default = true,
	Darker = true
})
WinTint = KitDisplay:CreateToggle({
	Name = 'Win Tint',
	Tooltip = 'Rings each kit green for a win, red for a loss',
	Darker = true
})
IconSize = KitDisplay:CreateSlider({
	Name = 'Icon Size',
	Tooltip = 'How big the history icons are',
	Min = 10,
	Max = 40,
	Default = 20,
	Darker = true,
	Suffix = function() return '%' end
})
RowPosition = KitDisplay:CreateDropdown({
	Name = 'History Position',
	List = {'Bottom Right', 'Top Right', 'Bottom Left'},
	Tooltips = {
		['Bottom Right'] = 'Bottom right of the card',
		['Top Right'] = 'Top right of the card',
		['Bottom Left'] = 'Bottom left of the card'
	},
	Darker = true
})
