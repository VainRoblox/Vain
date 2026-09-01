local KitRender

--[[
	Shows the kit each player picked on the draft cards, so the opponents' picks are
	readable before the round starts rather than being found out in the fight.

	Only the other team is drawn. Which side a card belongs to is settled two ways: the
	team attribute where it is set, and failing that the card's own container, since the
	draft groups cards by team and one of those groups is yours.
]]
local OwnColumn
local Decorated = {}

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
end

local function waitForChild(start, ...)
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
	if not container then return end
	return container.Name == 'MatchDraftPlayerCard' and container or container:FindFirstChild('MatchDraftPlayerCard', true)
end

-- Anything already drawn on our own side is taken back off. A card can be read before the
-- one identifying us has been, so our column is not always known the first time round.
local function clearColumn(column)
	for card, image in Decorated do
		if card.Parent and card:IsDescendantOf(column) then
			image:Destroy()
			Decorated[card] = nil
		end
	end
end

local function isTeammate(player, card)
	if player == lplr then
		-- Our own card names our column, and with it everyone sharing it.
		local column = card and card.Parent
		if column and OwnColumn ~= column then
			OwnColumn = column
			clearColumn(column)
		end
		return true
	end

	if OwnColumn and card and card:IsDescendantOf(OwnColumn) then return true end
	return bedwars.sameTeam(player)
end

local function callback5v5(v, plr)
	if not v then return end

	local render = v:FindFirstChild('PlayerRender', true)
	local player = plr or getPlayerFromDraft(render and render.Image or '', getPlayerName(v))
	if not player or isTeammate(player, v) then return end

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

		KitRender:Clean(roact)
		Decorated[v] = roact

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

	-- Re-bind the kit listener to whichever player the card currently shows. Draft cards
	-- are reused as the list reorders, so a card can switch to a new player; without this
	-- the kit image stays stuck on the old one.
	local kitConn
	local function bindKit()
		if kitConn then kitConn:Disconnect() end
		kitConn = player:GetAttributeChangedSignal('PlayingAsKits'):Connect(update)
		KitRender:Clean(kitConn)
		update()
	end
	bindKit()

	if render then
		KitRender:Clean(render:GetPropertyChangedSignal('Image'):Connect(function()
			local newplayer = getPlayerFromDraft(render.Image, getPlayerName(v))
			if newplayer and newplayer ~= player then
				player = newplayer
				-- The card may have been handed to somebody on our own side.
				if isTeammate(player, v) then
					if Decorated[v] then
						Decorated[v]:Destroy()
						Decorated[v] = nil
					end
					if kitConn then kitConn:Disconnect() end
					return
				end
				bindKit()
			end
		end))
	end
end

local function callbacksquad(v)
	if not v then return end

	local render = v:FindFirstChild('PlayerRender', true)
	local player = render and getPlayerFromDraft(render.Image, '') or nil
	if not player or isTeammate(player, v) then return end

	local kitImage = getKitMeta(player)
	local Roact = v:FindFirstChild('Kitcvrender')

	if not Roact then
		local base = v:FindFirstChild('3') or v:WaitForChild('3', 5)
		if not base then return end
		Roact = base:Clone()
		Roact.Parent = v
		Roact.Name = 'Kitcvrender'
		KitRender:Clean(Roact)
		Decorated[v] = Roact
	end

	Roact.Image = kitImage.renderImage

	local function update()
		Roact.Image = getKitMeta(player).renderImage
	end

	local kitConn
	local function bindKit()
		if kitConn then kitConn:Disconnect() end
		kitConn = player:GetAttributeChangedSignal('PlayingAsKits'):Connect(update)
		KitRender:Clean(kitConn)
		update()
	end
	bindKit()

	KitRender:Clean(render:GetPropertyChangedSignal('Image'):Connect(function()
		local newplayer = getPlayerFromDraft(render.Image, '')
		if newplayer and newplayer ~= player then
			player = newplayer
			if isTeammate(player, v) then
				if Decorated[v] then
					Decorated[v]:Destroy()
					Decorated[v] = nil
				end
				if kitConn then kitConn:Disconnect() end
				return
			end
			bindKit()
		end
	end))
end

local function setup5v5(DraftApp)
	local Background = DraftApp:FindFirstChild('DraftAppBackground')
	local BodyContainer = Background and Background:FindFirstChild('1') and Background['1']:FindFirstChild('BodyContainer')
	local hooked = false

	for i = 1, 2 do
		local dtc = BodyContainer and BodyContainer:FindFirstChild('Team' .. i .. 'Column')
		if dtc then
			hooked = true
			KitRender:Clean(dtc.ChildAdded:Connect(function(child)
				task.delay(0.2, function()
					if KitRender.Enabled then
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

		KitRender:Clean(DraftApp.DescendantAdded:Connect(function(child)
			if child:IsA('TextLabel') and child.Name == 'PlayerName' then
				task.delay(0.2, function()
					local container = child.Parent
					for _ = 1, 3 do
						container = container and container.Parent
					end
					if KitRender.Enabled and container then
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
	if not TeamsColumn then return end

	for _, v in TeamsColumn:GetChildren() do
		if v:IsA('Frame') then
			local plrframe = waitForChild(v, '1', '2', '4')
			if plrframe then
				for _, plr in plrframe:GetChildren() do
					callbacksquad(plr)
				end

				KitRender:Clean(plrframe.ChildAdded:Connect(function(plr)
					task.delay(0.2, function()
						if KitRender.Enabled then
							callbacksquad(plr)
						end
					end)
				end))
			end
		end
	end
end

local function runSetup(DraftApp)
	if not DraftApp or not KitRender.Enabled then return end
	-- 5v5 first; if it found no team columns it hooks PlayerName labels itself.
	setup5v5(DraftApp)
	setupSquad(DraftApp)
end

KitRender = vain.Categories.Render:CreateModule({
	Name = 'KitRender',
	Function = function(callback)
		if callback then
			OwnColumn = nil
			table.clear(Decorated)

			-- The draft UI is built at the start of every kit phase and removed after, so
			-- a one-shot wait would catch the first round and nothing later.
			local existing = lplr.PlayerGui:FindFirstChild('MatchDraftApp')
			if existing then
				runSetup(existing)
			end

			KitRender:Clean(lplr.PlayerGui.ChildAdded:Connect(function(child)
				if child.Name == 'MatchDraftApp' and KitRender.Enabled then
					OwnColumn = nil
					table.clear(Decorated)
					task.wait(0.2)
					runSetup(child)
				end
			end))
		else
			OwnColumn = nil
			table.clear(Decorated)
		end
	end,
	Tooltip = 'Shows the enemy team kit picks during the draft'
})
