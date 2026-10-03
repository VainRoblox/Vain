--[[
	Party Finder.

	Who queued together. The match in progress is not in anyone's history yet, but every
	match in it lists each player with the partyId they queued under (the game only shows it
	to moderators). So each player's most recent matches are read - fetched once per player
	by the shared matchHistory helper - and anyone who shared their partyId there and is on
	their team now is taken as their party. Parties formed only this match cannot show.

	When the history carries no party ids, the teams do the job: every match lists each
	team's members (match.teams[].members), and random matchmaking almost never puts the
	same two players on one team twice - so being teammates again in recent matches is
	read as a party too.

	For more certainty, more matches can be compared: a pair then has to have queued or
	teamed together in at least the required number of them.

	Parties are numbered next to names in the game's tab list, and a panel can list each
	team's parties, marking a team that is one whole party as a full queue.
]]
local PartyFinder
local Matches, Required, ShowPanel, Teammates, Corner, ShowLeaderboard, Source
local badges = setmetatable({}, {__mode = 'k'})
local cachedTabList
local panel, list, rows = nil, nil, {}
local mates = {}
-- What came back, for the panel to explain an empty result: histories answered, and
-- how many of those carried any party data at all.
local status = {asked = 0, loaded = 0, withParty = 0, withTeams = 0, empty = 0}
local groups = {}
local confidence = {}

local COLORS = {
	Color3.fromRGB(255, 200, 70), Color3.fromRGB(110, 220, 255), Color3.fromRGB(255, 120, 200),
	Color3.fromRGB(140, 255, 140), Color3.fromRGB(200, 150, 255), Color3.fromRGB(255, 150, 90)
}
local CORNERS = {
	['Top Left'] = {Vector2.new(0, 0), UDim2.new(0, 12, 0, 60)},
	['Top Right'] = {Vector2.new(1, 0), UDim2.new(1, -12, 0, 60)},
	['Bottom Left'] = {Vector2.new(0, 1), UDim2.new(0, 12, 1, -110)},
	['Bottom Right'] = {Vector2.new(1, 1), UDim2.new(1, -12, 1, -110)}
}

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function teamOf(player)
	local team = player:GetAttribute('Team')
	return team ~= nil and tostring(team) or nil
end

-- How many of their last few matches each other player shared a party with them in, by
-- user id. Kept as counts so the requirement can change without asking again.
-- The party a match entry was queued in, wherever the entry keeps it.
local function partyOf(entry)
	if type(entry) ~= 'table' then return nil end
	local info = type(entry.playerInfo) == 'table' and entry.playerInfo or {}
	local party = type(entry.party) == 'table' and entry.party or {}
	local id = entry.partyId or entry.party_id or info.partyId or party.id or party.partyId
	-- 12345678 is the placeholder a fresh match record starts with, not a real party.
	if id == 12345678 or id == '12345678' then return nil end
	return id
end

-- Which sources are in use: the game's own party data, the match history, or both.
local function usesGameData()
	return not Source or Source.Value ~= 'Match History'
end

local function usesHistory()
	return not Source or Source.Value ~= 'Game Data'
end

local function learn(player)
	if not usesHistory() then return end
	if mates[player.UserId] ~= nil then return end
	mates[player.UserId] = false
	status.asked += 1
	matchHistory.fetch(player, function(matches)
		status.loaded += 1
		if #matches == 0 then status.empty += 1 end
		local hadParty, hadTeams = false, false
		local found = {}
		for i = 1, math.min(10, #matches) do
			local match = matches[i]
			-- Teammates in that match, from its team list.
			for _, team in (type(match.teams) == 'table' and match.teams or {}) do
				local members = type(team) == 'table' and type(team.members) == 'table' and team.members
				local size = 0
				for _ in (members or {}) do size += 1 end
				-- Big teams (20v20 and up) share players by chance, so they say nothing.
				if members and size <= 8 and (members[player.UserId] ~= nil or members[tostring(player.UserId)] ~= nil) then
					hadTeams = true
					for key in members do
						local userId = tonumber(key)
						if userId and userId ~= player.UserId then
							found[userId] = found[userId] or {}
							found[userId][i] = true
						end
					end
					break
				end
			end

			local mine = matchHistory.entryFor(match, player.UserId)
			local partyId = partyOf(mine)
			if partyId ~= nil then
				hadParty = true
				for _, entry in (type(match.players) == 'table' and match.players or {}) do
					local info = type(entry) == 'table' and entry.playerInfo
					local userId = info and tonumber(info.userId)
					if userId and userId ~= player.UserId and partyOf(entry) == partyId then
						found[userId] = found[userId] or {}
						found[userId][i] = true
					end
				end
			end
		end
		if hadParty then status.withParty += 1 end
		if hadTeams then status.withTeams += 1 end
		mates[player.UserId] = found
	end)
end

-- Your own party, exactly: the game keeps it in its party store (leader and members) for
-- the whole match - the hotbar's party list reads the same - so it needs no history.
local function ownParty()
	local ids = {}
	local ok, players = pcall(function()
		return bedwars.PartyController:getLocalPartyPlayers()
	end)
	for _, member in (ok and type(players) == 'table' and players or {}) do
		local id = type(member) == 'table' and tonumber(member.userId)
		if id then ids[id] = true end
	end
	return ids
end

--[[
	Every party in the match, exactly, when the game has it: the MatchController keeps a
	parties list (members as user ids, and a displayId) filled by the server's
	MatchPartiesUpdate - the tab list's own party markers read it, and only check on the
	client whether you may see them. Empty when the server does not send it to you.
]]
local function exactParties()
	local ok, parties = pcall(function()
		return bedwars.MatchController:getParties()
	end)
	local list = {}
	for _, party in (ok and type(parties) == 'table' and parties or {}) do
		local members = type(party) == 'table' and party.members
		if type(members) == 'table' and #members > 1 then
			list[#list + 1] = members
		end
	end
	return list
end

-- In how many of the compared matches two players queued together, from either side.
local function shared(a, b)
	local best = 0
	for _, pair in {{a, b}, {b, a}} do
		local seen = mates[pair[1].UserId] and mates[pair[1].UserId][pair[2].UserId]
		if seen then
			local count = 0
			for i = 1, Matches.Value do
				if seen[i] then count += 1 end
			end
			best = math.max(best, count)
		end
	end
	return best
end

--[[
	Groups the players in this match into parties: two players are together when they
	queued together in enough of the compared matches and are on the same team now.
	Parties of one are left out.
]]
local function regroup()
	local players = playersService:GetPlayers()
	local parent = {}
	local function find(id)
		while parent[id] and parent[id] ~= id do id = parent[id] end
		return id
	end
	for _, player in players do parent[player.UserId] = player.UserId end
	table.clear(confidence)

	-- The game's own party list first, then your own party, then match history - each only
	-- when the Source setting uses it.
	for _, members in (usesGameData() and exactParties() or {}) do
		local first
		for _, id in members do
			id = tonumber(id)
			if id and parent[id] then
				if first then
					local ra, rb = find(id), find(first)
					if ra ~= rb then parent[ra] = rb end
					confidence[first .. ':' .. id] = math.huge
				else
					first = id
				end
			end
		end
	end

	local own = usesGameData() and ownParty() or {}
	for _, player in players do
		if player ~= lplr and own[player.UserId] then
			local ra, rb = find(player.UserId), find(lplr.UserId)
			if ra ~= rb then parent[ra] = rb end
			confidence[lplr.UserId .. ':' .. player.UserId] = math.huge
		end
	end
	for _, a in (usesHistory() and players or {}) do
		for _, b in players do
			if a ~= b and teamOf(a) and teamOf(a) == teamOf(b) then
				local count = shared(a, b)
				if count >= math.min(Required.Value, Matches.Value) then
					confidence[a.UserId .. ':' .. b.UserId] = count
					local ra, rb = find(a.UserId), find(b.UserId)
					if ra ~= rb then parent[ra] = rb end
				end
			end
		end
	end

	local byRoot = {}
	for _, player in players do
		local root = find(player.UserId)
		byRoot[root] = byRoot[root] or {}
		table.insert(byRoot[root], player)
	end
	table.clear(groups)
	for _, members in byRoot do
		if #members > 1 then
			table.sort(members, function(a, b) return a.UserId < b.UserId end)
			groups[#groups + 1] = {members = members, team = teamOf(members[1])}
		end
	end
	table.sort(groups, function(a, b)
		if a.team ~= b.team then return tostring(a.team) < tostring(b.team) end
		return a.members[1].UserId < b.members[1].UserId
	end)
	for i, group in groups do
		group.color = COLORS[(i - 1) % #COLORS + 1]
		-- How sure: the most matches any member shared with another.
		local best = 0
		for key, count in confidence do
			for _, member in group.members do
				if key:find('^' .. member.UserId .. ':') then best = math.max(best, count) end
			end
		end
		group.seen = best
		group.exact = best == math.huge
	end
end

--[[
	Party numbers in the game's tab list. Each player row shows its name in a PlayerName
	label inside PlayerNameContainer (a horizontal list), so a small numbered badge in the
	party's colour goes into that container, before the name. Roact leaves children it did
	not make alone, so the badge stays until it is taken off here.
]]
local function stripTags(text)
	return (text or ''):gsub('<[^<>]->', '')
end

local function clearBadges()
	for badge in badges do pcall(function() badge:Destroy() end) end
	table.clear(badges)
end

local function updateLeaderboard()
	local gui = lplr:FindFirstChildOfClass('PlayerGui')
	-- Found once and kept while it exists, rather than searching all of PlayerGui each time.
	if not (cachedTabList and cachedTabList:IsDescendantOf(gui or game)) then
		cachedTabList = gui and gui:FindFirstChild('TabListFrame', true)
	end
	local tabList = cachedTabList
	-- Only while the tab list is actually up; nothing to number otherwise.
	if not (tabList and tabList:IsA('GuiObject') and tabList.Visible and tabList.AbsoluteSize.X > 0) then return end

	local byName = {}
	for _, player in playersService:GetPlayers() do
		byName[player.DisplayName] = player
		byName[player.Name] = player
	end
	local partyOfPlayer = {}
	for index, group in groups do
		for _, player in group.members do
			partyOfPlayer[player] = {index = index, color = group.color, team = group.team}
		end
	end

	for _, label in tabList:GetDescendants() do
		if label.Name == 'PlayerName' and label:IsA('TextLabel') then
			local text = stripTags(label.Text)
			local player = byName[text]
			if not player then
				for name, candidate in byName do
					if #name > 2 and text:sub(-#name) == name then player = candidate break end
				end
			end
			local party = player and partyOfPlayer[player]
			local own = party and teamOf(lplr) ~= nil and party.team == teamOf(lplr)
			local container = label.Parent
			local badge = container and container:FindFirstChild('VainPartyBadge')
			if party and on(ShowLeaderboard) and (not own or on(Teammates)) then
				if not badge then
					badge = Instance.new('Frame')
					badge.Name = 'VainPartyBadge'
					badge.SizeConstraint = Enum.SizeConstraint.RelativeYY
					badge.Size = UDim2.fromScale(0.7, 0.7)
					badge.LayoutOrder = -1
					badge.Parent = container
					Instance.new('UICorner', badge).CornerRadius = UDim.new(1, 0)
					local number = Instance.new('TextLabel')
					number.Name = 'Number'
					number.BackgroundTransparency = 1
					number.Size = UDim2.fromScale(1, 1)
					number.TextScaled = true
					number.Font = Enum.Font.GothamBold
					number.TextColor3 = Color3.new(0, 0, 0)
					number.Parent = badge
					badges[badge] = true
				end
				badge.BackgroundColor3 = party.color
				badge.Number.Text = tostring(party.index)
				badge.Visible = true
			elseif badge then
				badge.Visible = false
			end
		end
	end
end

local function row(index)
	local label = rows[index]
	if label then return label end
	label = Instance.new('TextLabel')
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 18)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextStrokeTransparency = 0.5
	label.RichText = true
	label.LayoutOrder = index
	label.Parent = list
	rows[index] = label
	return label
end

local function updatePanel()
	if not panel then return end
	panel.Visible = on(ShowPanel)
	if not panel.Visible then return end

	-- Team sizes now, to tell a full queue from a partial one.
	local sizes = {}
	for _, player in playersService:GetPlayers() do
		local team = teamOf(player)
		if team then sizes[team] = (sizes[team] or 0) + 1 end
	end

	local lines = {}
	for index, group in groups do
		local own = teamOf(lplr) ~= nil and group.team == teamOf(lplr)
		if not own or on(Teammates) then
			local first = group.members[1]
			local teamColor = first.Team and first.TeamColor.Color or Color3.new(1, 1, 1)
			local names = {}
			for _, player in group.members do names[#names + 1] = player.DisplayName end
			local full = sizes[group.team] and #group.members >= sizes[group.team]
			lines[#lines + 1] = {
				color = teamColor,
				text = string.format('%s  <font color="#%s">P%d</font> %s%s',
					first.Team and first.Team.Name or 'Team', group.color:ToHex(), index, table.concat(names, ', '),
					full and '  <font color="#ff6060">FULL QUEUE</font>' or '')
			}
		end
	end
	if #lines == 0 then
		-- Says why, so an empty panel can be told apart from nobody being partied.
		local why
		if not usesHistory() then
			why = #exactParties() == 0 and 'The game sends you no party data' or 'No parties in the game data'
		elseif status.loaded < status.asked then
			why = string.format('Loading histories %d/%d', status.loaded, status.asked)
		elseif status.loaded > 0 and status.empty == status.loaded then
			why = 'No match history came back'
		elseif status.loaded > 0 and status.withParty == 0 and status.withTeams == 0 then
			why = 'Histories have no party or team data'
		elseif not teamOf(lplr) then
			why = 'Waiting for teams'
		else
			why = string.format('No parties found (%d/%d histories)', status.loaded, status.asked)
		end
		lines[1] = {color = Color3.fromRGB(150, 150, 150), text = why}
	end
	for i, line in lines do
		local label = row(i)
		label.TextColor3 = line.color
		label.Text = line.text
		label.Visible = true
	end
	for i = #lines + 1, #rows do rows[i].Visible = false end
	panel.Size = UDim2.fromOffset(300, #lines * 18 + 30)
end

local function place()
	if not panel then return end
	local corner = CORNERS[Corner.Value] or CORNERS['Top Left']
	panel.AnchorPoint = corner[1]
	panel.Position = corner[2]
end

local function build()
	panel = Instance.new('Frame')
	panel.Name = 'PartyFinder'
	panel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	panel.BackgroundTransparency = 0.4
	panel.BorderSizePixel = 0
	panel.Parent = vain.gui
	Instance.new('UICorner', panel).CornerRadius = UDim.new(0, 6)
	local padding = Instance.new('UIPadding')
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.PaddingTop = UDim.new(0, 4)
	padding.Parent = panel
	local title = Instance.new('TextLabel')
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 20)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.TextColor3 = Color3.fromRGB(170, 170, 170)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = 'Parties'
	title.Parent = panel
	list = Instance.new('Frame')
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromOffset(0, 20)
	list.Size = UDim2.new(1, 0, 1, -20)
	list.Parent = panel
	local layout = Instance.new('UIListLayout')
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	place()
end

PartyFinder = vain.Categories.Render:CreateModule({
	Name = 'Party Finder',
	Tooltip = 'Shows who queued together',
	Function = function(callback)
		if callback then
			build()
			PartyFinder:Clean(panel)
			for _, player in playersService:GetPlayers() do learn(player) end
			PartyFinder:Clean(playersService.PlayerAdded:Connect(learn))
			-- Grouping is cheap; redone twice a second as answers and teams come in.
			local last = 0
			PartyFinder:Clean(runService.Heartbeat:Connect(function()
				if os.clock() - last < 0.5 then return end
				last = os.clock()
				pcall(regroup)
				pcall(updatePanel)
				pcall(updateLeaderboard)
			end))
		else
			clearBadges()
			table.clear(rows)
			panel, list = nil, nil
			-- Answers stay in the shared cache, so turning it back on asks nobody again.
			table.clear(mates)
			status = {asked = 0, loaded = 0, withParty = 0, withTeams = 0, empty = 0}
		end
	end
})
Source = PartyFinder:CreateDropdown({
	Name = 'Source',
	List = {'Both', 'Game Data', 'Match History'},
	Tooltips = {
		Both = 'The game\'s party data, then match history',
		['Game Data'] = 'Only the game\'s own party data',
		['Match History'] = 'Only comparing match histories'
	},
	Function = function(val)
		for _, setting in {Matches, Required} do
			if setting and setting.Object then setting.Object.Visible = val ~= 'Game Data' end
		end
		if Required and Required.Object and Matches then Required.Object.Visible = val ~= 'Game Data' and Matches.Value > 1 end
		-- Switched onto history: ask for anyone not asked yet.
		if PartyFinder.Enabled and val ~= 'Game Data' then
			for _, player in playersService:GetPlayers() do learn(player) end
		end
	end
})
Matches = PartyFinder:CreateSlider({
	Name = 'Matches Compared',
	Tooltip = 'How many recent matches to compare',
	Min = 1,
	Max = 10,
	Default = 1,
	Function = function(val)
		if Required and Required.Object then Required.Object.Visible = val > 1 end
	end
})
Required = PartyFinder:CreateSlider({
	Name = 'Required Matches',
	Tooltip = 'How many of those they must have teamed in',
	Min = 1,
	Max = 10,
	Default = 1,
	Darker = true,
	Visible = false
})
ShowLeaderboard = PartyFinder:CreateToggle({
	Name = 'Leaderboard',
	Tooltip = 'Numbers each party next to names in the tab list',
	Default = true
})
ShowPanel = PartyFinder:CreateToggle({
	Name = 'Panel',
	Tooltip = 'Lists every team\'s parties',
	Function = function(callback)
		if Corner and Corner.Object then Corner.Object.Visible = callback end
	end
})
Corner = PartyFinder:CreateDropdown({
	Name = 'Position',
	List = {'Top Left', 'Top Right', 'Bottom Left', 'Bottom Right'},
	Tooltips = {
		['Top Left'] = 'Top left of the screen',
		['Top Right'] = 'Top right of the screen',
		['Bottom Left'] = 'Bottom left of the screen',
		['Bottom Right'] = 'Bottom right of the screen'
	},
	Darker = true,
	Function = place
})
Teammates = PartyFinder:CreateToggle({
	Name = 'Own Team',
	Tooltip = 'Also shows your own team\'s parties',
	Default = true
})
