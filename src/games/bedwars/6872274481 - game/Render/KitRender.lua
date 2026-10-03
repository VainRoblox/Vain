local KitDisplay
local RankedOnly
local KitHistory
local HistoryCount

--[[
	The kits someone played in their last matches, from their match history.

	Asked for the way the game's Match History app does it -
	MatchHistoryController:requestMatchHistory with the player's name, which resolves to
	{player, matchHistory} - as that answers for any player, private profiles included.
	The user id as text is tried next, then the profile's own history (RequestProfileData),
	which comes back empty when the profile is friends only or hidden. Each match lists
	every player with the kit they played under bedwars.kit.

	Every request has a time limit, so one the server never answers still ends in "no
	history" instead of leaving the card waiting. Asked for once per player and kept for
	the session; the draft screen asks for everyone at once, so the requests are spread out.
]]
local REQUEST_TIMEOUT = 6

-- Runs a yielding request with a time limit; nil if it errors or takes too long.
local function within(seconds, request)
	local result, finished = nil, false
	local thread = task.spawn(function()
		local ok, value = pcall(request)
		result = ok and value or nil
		finished = true
	end)
	local started = os.clock()
	while not finished and os.clock() - started < seconds do
		task.wait(0.1)
	end
	if not finished then pcall(task.cancel, thread) end
	return result
end

local function historyFrom(data)
	if type(data) == 'table' and type(data.matchHistory) == 'table' and #data.matchHistory > 0 then
		return data.matchHistory
	end
end

local function requestMatches(player)
	local controller = bedwars.MatchHistoryController
	for _, query in {player.Name, tostring(player.UserId)} do
		local history = historyFrom(within(REQUEST_TIMEOUT, function()
			local promise = controller:requestMatchHistory(query)
			local ok, value = promise:await()
			return ok and value or nil
		end))
		if history then return history end
	end
	return historyFrom(within(REQUEST_TIMEOUT, function()
		return bedwars.Client:Get('RequestProfileData'):CallServer(player)
	end))
end

local historyCache, historyWaiters = {}, {}
local historyQueue = 0

local function fetchHistory(player, callback)
	local userId = player.UserId
	local cached = historyCache[userId]
	if type(cached) == 'table' then
		callback(cached)
		return
	end
	historyWaiters[userId] = historyWaiters[userId] or {}
	table.insert(historyWaiters[userId], callback)
	if cached == 'pending' then return end
	historyCache[userId] = 'pending'

	historyQueue += 1
	local delay = (historyQueue - 1) * 0.15
	task.delay(delay, function()
		historyQueue = math.max(historyQueue - 1, 0)
		local kits = {}
		local history = requestMatches(player)
		if history then
			local matches = table.clone(history)
			table.sort(matches, function(a, b)
				return (tonumber(a.matchStartTime) or 0) > (tonumber(b.matchStartTime) or 0)
			end)
			for _, match in matches do
				if #kits >= 10 then break end
				for _, entry in (type(match.players) == 'table' and match.players or {}) do
					local info = type(entry) == 'table' and entry.playerInfo
					if info and tonumber(info.userId) == userId then
						local kit = entry.bedwars and entry.bedwars.kit
						if type(kit) == 'string' and kit ~= '' then
							kits[#kits + 1] = kit
						end
						break
					end
				end
			end
		end
		historyCache[userId] = kits
		for _, waiting in historyWaiters[userId] or {} do
			pcall(waiting, kits)
		end
		historyWaiters[userId] = nil
	end)
end

-- A small row of kit icons in the bottom right of a player's card, newest on the right
-- edge. Kept inside the card, as anything hanging off it is clipped by the draft list.
local function newRow(card)
	local row = Instance.new('Frame')
	row.Name = 'KitHistory'
	row.BackgroundTransparency = 1
	row.AnchorPoint = Vector2.new(1, 1)
	row.Position = UDim2.new(1, -4, 1, -4)
	row.Size = UDim2.new(0.62, 0, 0.2, 0)
	row.ZIndex = 10
	row.Parent = card
	KitDisplay:Clean(row)

	local layout = Instance.new('UIListLayout')
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
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
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.ZIndex = 10
	label.Parent = row
end

local function drawHistory(card, player)
	if not card then return end
	local old = card:FindFirstChild('KitHistory')
	if old then old:Destroy() end
	if not (KitHistory and KitHistory.Enabled and player) then return end

	-- Cards are reused as the list reorders, so the answer is only drawn if the card still
	-- shows the player it was asked for.
	card:SetAttribute('KitHistoryUser', player.UserId)
	rowText(newRow(card), '…')
	fetchHistory(player, function(kits)
		if not (card.Parent and KitDisplay.Enabled) then return end
		if card:GetAttribute('KitHistoryUser') ~= player.UserId then return end
		if card:FindFirstChild('KitHistory') then card.KitHistory:Destroy() end

		local row = newRow(card)
		local shown = math.min(#kits, HistoryCount and HistoryCount.Value or 10)
		if shown == 0 then
			rowText(row, 'No history')
			return
		end
		for i = 1, shown do
			local meta = bedwars.BedwarsKitMeta[kits[i]]
			local icon = Instance.new('ImageLabel')
			icon.Name = kits[i]
			-- Laid out right to left: the newest sits on the edge.
			icon.LayoutOrder = shown - i
			icon.BackgroundColor3 = Color3.new(0, 0, 0)
			icon.BackgroundTransparency = 0.45
			icon.SizeConstraint = Enum.SizeConstraint.RelativeYY
			icon.Size = UDim2.fromScale(1, 1)
			icon.ScaleType = Enum.ScaleType.Crop
			icon.Image = meta and meta.renderImage or ''
			icon.ImageTransparency = math.clamp((i - 1) * 0.05, 0, 0.45)
			icon.ZIndex = 10
			icon.Parent = row
			Instance.new('UICorner', icon).CornerRadius = UDim.new(0.25, 0)
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
