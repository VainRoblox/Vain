--[[
	Session Stats.

	Your numbers for this match, counted from what reaches every client: EntityDeathEvent
	(your character as fromEntity is a kill - finalKill says whether it was a final one -
	and as entityInstance is a death) and BedwarsBedBreak (its player is who broke it).
	Shown as a small card; each stat can be switched off.
]]
local SessionStats
local ShowKills, ShowFinals, ShowBeds, ShowDeaths, ShowKD, ShowTime, Background, Scale
local card, header, list, scaler
local rows = {}
local stats = {kills = 0, finals = 0, beds = 0, deaths = 0}

local ROW_HEIGHT = 18
local HEADER_HEIGHT = 20
local WIDTH = 150

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function row(index)
	local entry = rows[index]
	if entry then return entry end
	local frame = Instance.new('Frame')
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	frame.LayoutOrder = index
	frame.Parent = list
	local name = Instance.new('TextLabel')
	name.BackgroundTransparency = 1
	name.Size = UDim2.fromScale(0.6, 1)
	name.Font = Enum.Font.Gotham
	name.TextSize = 13
	name.TextColor3 = Color3.fromRGB(190, 190, 190)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Parent = frame
	local value = Instance.new('TextLabel')
	value.BackgroundTransparency = 1
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.fromScale(1, 0)
	value.Size = UDim2.fromScale(0.4, 1)
	value.Font = Enum.Font.GothamBold
	value.TextSize = 13
	value.TextColor3 = Color3.new(1, 1, 1)
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.Parent = frame
	entry = {frame = frame, name = name, value = value}
	rows[index] = entry
	return entry
end

local function matchTime()
	local started = store.matchStartTime
	if type(started) ~= 'number' or started <= 0 then return '0:00' end
	local seconds = math.max(os.time() - started, 0)
	return string.format('%d:%02d', seconds // 60, seconds % 60)
end

local function update()
	local lines = {}
	if on(ShowKills) then lines[#lines + 1] = {'Kills', tostring(stats.kills)} end
	if on(ShowFinals) then lines[#lines + 1] = {'Final Kills', tostring(stats.finals)} end
	if on(ShowBeds) then lines[#lines + 1] = {'Beds', tostring(stats.beds)} end
	if on(ShowDeaths) then lines[#lines + 1] = {'Deaths', tostring(stats.deaths)} end
	if on(ShowKD) then
		lines[#lines + 1] = {'K/D', string.format('%.2f', stats.kills / math.max(stats.deaths, 1))}
	end
	if on(ShowTime) then lines[#lines + 1] = {'Time', matchTime()} end

	for i, line in lines do
		local entry = row(i)
		entry.name.Text = line[1]
		entry.value.Text = line[2]
		entry.frame.Visible = true
	end
	for i = #lines + 1, #rows do rows[i].frame.Visible = false end
	card.Size = UDim2.fromOffset(WIDTH, HEADER_HEIGHT + #lines * ROW_HEIGHT + 10)
	scaler.Scale = Scale.Value
end

SessionStats = vain.Legit:CreateModule({
	Name = 'Session Stats',
	Function = function(callback)
		if callback then
			SessionStats:Clean(vainEvents.EntityDeathEvent.Event:Connect(function(deathTable)
				if type(deathTable) ~= 'table' then return end
				local character = lplr.Character
				if character and deathTable.fromEntity == character and deathTable.entityInstance ~= character then
					stats.kills += 1
					if deathTable.finalKill then stats.finals += 1 end
				elseif character and deathTable.entityInstance == character then
					stats.deaths += 1
				end
			end))
			SessionStats:Clean(vainEvents.BedwarsBedBreak.Event:Connect(function(bedTable)
				if type(bedTable) == 'table' and bedTable.player == lplr then
					stats.beds += 1
				end
			end))
			local last = 0
			SessionStats:Clean(runService.Heartbeat:Connect(function()
				if os.clock() - last < 0.25 then return end
				last = os.clock()
				pcall(update)
			end))
			pcall(update)
		end
	end,
	Size = UDim2.fromOffset(150, 120),
	Tooltip = 'Your kills, beds and deaths this match'
})
ShowKills = SessionStats:CreateToggle({Name = 'Kills', Tooltip = 'Shows your kills', Default = true})
ShowFinals = SessionStats:CreateToggle({Name = 'Final Kills', Tooltip = 'Shows your final kills', Default = true})
ShowBeds = SessionStats:CreateToggle({Name = 'Beds', Tooltip = 'Shows beds you broke', Default = true})
ShowDeaths = SessionStats:CreateToggle({Name = 'Deaths', Tooltip = 'Shows your deaths', Default = true})
ShowKD = SessionStats:CreateToggle({Name = 'K/D', Tooltip = 'Kills per death'})
ShowTime = SessionStats:CreateToggle({Name = 'Match Time', Tooltip = 'How long the match has run', Default = true})
Scale = SessionStats:CreateSlider({
	Name = 'Scale',
	Tooltip = 'How big the card is',
	Min = 0.6,
	Max = 2,
	Default = 1,
	Decimal = 10
})
Background = SessionStats:CreateColorSlider({
	Name = 'Background',
	Tooltip = 'Colour of the card',
	DefaultValue = 0.08,
	DefaultOpacity = 0.6,
	Function = function(hue, sat, val, opacity)
		if card then
			card.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			card.BackgroundTransparency = 1 - opacity
		end
	end
})

card = Instance.new('Frame')
card.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
card.BackgroundTransparency = 0.4
card.BorderSizePixel = 0
card.Size = UDim2.fromOffset(WIDTH, 120)
card.Parent = SessionStats.Children
Instance.new('UICorner', card).CornerRadius = UDim.new(0, 8)
local stroke = Instance.new('UIStroke')
stroke.Color = Color3.new(1, 1, 1)
stroke.Transparency = 0.9
stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
stroke.Parent = card
local padding = Instance.new('UIPadding')
padding.PaddingLeft = UDim.new(0, 10)
padding.PaddingRight = UDim.new(0, 10)
padding.PaddingTop = UDim.new(0, 6)
padding.Parent = card
scaler = Instance.new('UIScale')
scaler.Parent = card
header = Instance.new('TextLabel')
header.BackgroundTransparency = 1
header.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT - 6)
header.Font = Enum.Font.GothamBold
header.TextSize = 11
header.TextColor3 = Color3.fromRGB(150, 150, 150)
header.TextXAlignment = Enum.TextXAlignment.Left
header.Text = 'THIS MATCH'
header.Parent = card
list = Instance.new('Frame')
list.BackgroundTransparency = 1
list.Position = UDim2.fromOffset(0, HEADER_HEIGHT)
list.Size = UDim2.new(1, 0, 1, -HEADER_HEIGHT)
list.Parent = card
local layout = Instance.new('UIListLayout')
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = list
