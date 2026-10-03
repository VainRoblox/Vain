--[[
	Party Finder.

	Who queued together. The match in progress is not in anyone's history yet, but every
	match in it lists each player with the partyId they queued under (the game only shows it
	to moderators). So each player's most recent matches are read - fetched once per player
	by the shared matchHistory helper - and anyone who shared their partyId there and is on
	their team now is taken as their party. Parties formed only this match cannot show.

	Partied players get a tag over their head in their party's colour, and a panel lists each
	team's parties, marking a team that is one whole party as a full queue.
]]
local PartyFinder
local Matches, ShowTags, ShowPanel, Teammates, Corner
local panel, list, rows = nil, nil, {}
local mates = {}
local groups = {}
local tags = {}
local Folder = Instance.new('Folder')
Folder.Name = 'PartyFinder'
Folder.Parent = vain.gui

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

-- Everyone who shared a party with them in their last few matches, by user id.
local function learn(player)
	matchHistory.fetch(player, function(matches)
		local found = {}
		for i = 1, math.min(Matches.Value, #matches) do
			local match = matches[i]
			local mine = matchHistory.entryFor(match, player.UserId)
			local partyId = mine and mine.partyId
			if partyId ~= nil then
				for _, entry in (type(match.players) == 'table' and match.players or {}) do
					local info = type(entry) == 'table' and entry.playerInfo
					local userId = info and tonumber(info.userId)
					if userId and userId ~= player.UserId and entry.partyId == partyId then
						found[userId] = true
					end
				end
			end
		end
		mates[player.UserId] = found
	end)
end

--[[
	Groups the players in this match into parties: two players are together when either
	lists the other and they are on the same team now. Parties of one are left out.
]]
local function regroup()
	local players = playersService:GetPlayers()
	local parent = {}
	local function find(id)
		while parent[id] and parent[id] ~= id do id = parent[id] end
		return id
	end
	for _, player in players do parent[player.UserId] = player.UserId end
	for _, a in players do
		for _, b in players do
			if a ~= b and teamOf(a) and teamOf(a) == teamOf(b) then
				local known = (mates[a.UserId] and mates[a.UserId][b.UserId]) or (mates[b.UserId] and mates[b.UserId][a.UserId])
				if known then
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
	for i, group in groups do group.color = COLORS[(i - 1) % #COLORS + 1] end
end

local function clearTags()
	for _, tag in tags do tag:Destroy() end
	table.clear(tags)
end

local function updateTags()
	local wanted = {}
	if on(ShowTags) then
		for index, group in groups do
			local own = teamOf(lplr) ~= nil and group.team == teamOf(lplr)
			if not own or on(Teammates) then
				for _, player in group.members do
					local head = player.Character and player.Character:FindFirstChild('Head')
					if head then
						wanted[player] = true
						local tag = tags[player]
						if not tag or tag.Adornee ~= head then
							if tag then tag:Destroy() end
							tag = Instance.new('BillboardGui')
							tag.Size = UDim2.fromOffset(120, 18)
							tag.StudsOffsetWorldSpace = Vector3.new(0, 3.4, 0)
							tag.AlwaysOnTop = true
							tag.Adornee = head
							tag.Parent = Folder
							local label = Instance.new('TextLabel')
							label.Name = 'Label'
							label.Size = UDim2.fromScale(1, 1)
							label.BackgroundTransparency = 1
							label.Font = Enum.Font.GothamBold
							label.TextSize = 12
							label.TextStrokeTransparency = 0.4
							label.Parent = tag
							tags[player] = tag
						end
						tag.Label.Text = string.format('Party %d (%d)', index, #group.members)
						tag.Label.TextColor3 = group.color
					end
				end
			end
		end
	end
	for player, tag in tags do
		if not wanted[player] then
			tag:Destroy()
			tags[player] = nil
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
		lines[1] = {color = Color3.fromRGB(150, 150, 150), text = 'No parties found yet'}
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
				pcall(updateTags)
				pcall(updatePanel)
			end))
		else
			clearTags()
			table.clear(rows)
			panel, list = nil, nil
		end
	end
})
Matches = PartyFinder:CreateSlider({
	Name = 'Matches Checked',
	Tooltip = 'How many recent matches to look at',
	Min = 1,
	Max = 5,
	Default = 1
})
ShowTags = PartyFinder:CreateToggle({
	Name = 'Tags',
	Tooltip = 'Tags partied players with their party',
	Default = true
})
ShowPanel = PartyFinder:CreateToggle({
	Name = 'Panel',
	Tooltip = 'Lists every team\'s parties',
	Default = true,
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
