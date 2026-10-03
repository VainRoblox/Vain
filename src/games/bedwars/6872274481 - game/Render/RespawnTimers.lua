--[[
	Respawn Timers.

	Every death reaches every client as EntityDeathEvent, carrying the character that died
	and its respawnDuration - the same number the game's own respawn screen counts down.
	The player's RespawningAtTime attribute (server time) is used instead when the game has
	set it. A death with the team's bed already broken is a final kill: no respawn.

	The dead are listed on a small panel with the seconds until they are back, and
	optionally marked where they fell. Nothing here asks the server for anything.
]]
local RespawnTimers
local Teammates, ShowFinals, WorldMarkers, Corner, Background
local panel, list
local dead = {}
local rows = {}
local Folder = Instance.new('Folder')
Folder.Name = 'RespawnTimers'
Folder.Parent = vain.gui

local FINAL_HOLD = 6

local CORNERS = {
	['Top Right'] = {Vector2.new(1, 0), UDim2.new(1, -12, 0, 60)},
	['Top Left'] = {Vector2.new(0, 0), UDim2.new(0, 12, 0, 60)},
	['Bottom Right'] = {Vector2.new(1, 1), UDim2.new(1, -12, 1, -110)},
	['Bottom Left'] = {Vector2.new(0, 1), UDim2.new(0, 12, 1, -110)}
}

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function sameTeam(player)
	local mine, theirs = lplr:GetAttribute('Team'), player:GetAttribute('Team')
	return mine ~= nil and theirs ~= nil and tostring(mine) == tostring(theirs)
end

local function forget(player)
	local entry = dead[player]
	if not entry then return end
	if entry.marker then entry.marker:Destroy() end
	if entry.connection then entry.connection:Disconnect() end
	dead[player] = nil
end

local function onDeath(deathTable)
	if type(deathTable) ~= 'table' then return end
	local player = playersService:GetPlayerFromCharacter(deathTable.entityInstance)
	if not player or player == lplr then return end
	forget(player)

	local team = player:GetAttribute('Team')
	local final = team ~= nil and brokenbeds[team] ~= nil
	local now = workspace:GetServerTimeNow()
	local entry = {
		final = final,
		respawnAt = now + (tonumber(deathTable.respawnDuration) or 5),
		diedAt = now
	}

	local root = deathTable.entityInstance:FindFirstChild('HumanoidRootPart') or deathTable.entityInstance.PrimaryPart
	if root then
		local marker = Instance.new('BillboardGui')
		marker.Size = UDim2.fromOffset(140, 20)
		marker.AlwaysOnTop = true
		marker.StudsOffsetWorldSpace = Vector3.new(0, 2, 0)
		local anchor = Instance.new('Attachment')
		anchor.WorldPosition = root.Position
		anchor.Parent = workspace.Terrain
		marker.Adornee = anchor
		marker.Destroying:Connect(function() anchor:Destroy() end)
		local label = Instance.new('TextLabel')
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextSize = 13
		label.TextStrokeTransparency = 0.4
		label.Parent = marker
		marker.Parent = Folder
		entry.marker = marker
		entry.markerLabel = label
	end

	-- Back in the game: off the list.
	entry.connection = player.CharacterAdded:Connect(function()
		task.delay(0.5, function()
			if dead[player] == entry then forget(player) end
		end)
	end)
	dead[player] = entry
end

local function row(index)
	local entry = rows[index]
	if entry then return entry end
	local label = Instance.new('TextLabel')
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

local function update()
	local now = workspace:GetServerTimeNow()
	local shown = {}
	for player, entry in dead do
		if not player.Parent then
			forget(player)
			continue
		end
		local respawnAt = player:GetAttribute('RespawningAtTime')
		if type(respawnAt) == 'number' and respawnAt > entry.diedAt then entry.respawnAt = respawnAt end
		local remaining = entry.respawnAt - now
		if (entry.final and now - entry.diedAt > FINAL_HOLD) or (not entry.final and remaining < -1) then
			forget(player)
			continue
		end

		local wanted = (on(Teammates) or not sameTeam(player)) and (on(ShowFinals) or not entry.final)
		local text = entry.final and 'FINAL' or string.format('%.1fs', math.max(remaining, 0))
		if entry.marker then
			entry.marker.Enabled = wanted and on(WorldMarkers)
			entry.markerLabel.Text = player.DisplayName .. '  ' .. text
			entry.markerLabel.TextColor3 = player.Team and player.TeamColor.Color or Color3.new(1, 1, 1)
		end
		if wanted then
			shown[#shown + 1] = {player = player, text = text, final = entry.final, remaining = remaining}
		end
	end
	table.sort(shown, function(a, b)
		if a.final ~= b.final then return not a.final end
		return a.remaining < b.remaining
	end)

	for i, item in shown do
		local label = row(i)
		local color = item.player.Team and item.player.TeamColor.Color or Color3.new(1, 1, 1)
		label.TextColor3 = color
		label.Text = item.player.DisplayName .. '  <font color="rgb(' .. (item.final and '255,90,90' or '230,230,230') .. ')">' .. item.text .. '</font>'
		label.Visible = true
	end
	for i = #shown + 1, #rows do rows[i].Visible = false end
	panel.Visible = #shown > 0
	panel.Size = UDim2.fromOffset(190, #shown * 18 + 30)
end

local function place()
	if not panel then return end
	local corner = CORNERS[Corner.Value] or CORNERS['Top Right']
	panel.AnchorPoint = corner[1]
	panel.Position = corner[2]
end

local function build()
	panel = Instance.new('Frame')
	panel.Name = 'RespawnTimers'
	panel.BorderSizePixel = 0
	panel.Visible = false
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
	title.Text = 'Respawning'
	title.Parent = panel

	list = Instance.new('Frame')
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromOffset(0, 20)
	list.Size = UDim2.new(1, 0, 1, -20)
	list.Parent = panel
	local layout = Instance.new('UIListLayout')
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	panel.BackgroundColor3 = Color3.fromHSV(Background.Hue, Background.Sat, Background.Value)
	panel.BackgroundTransparency = 1 - Background.Opacity
	place()
end

RespawnTimers = vain.Categories.Render:CreateModule({
	Name = 'Respawn Timers',
	Tooltip = 'Shows when dead players respawn',
	Function = function(callback)
		if callback then
			build()
			RespawnTimers:Clean(panel)
			RespawnTimers:Clean(vainEvents.EntityDeathEvent.Event:Connect(function(deathTable)
				pcall(onDeath, deathTable)
			end))
			RespawnTimers:Clean(runService.RenderStepped:Connect(function()
				pcall(update)
			end))
		else
			for player in dead do forget(player) end
			table.clear(rows)
			panel, list = nil, nil
		end
	end
})
Teammates = RespawnTimers:CreateToggle({
	Name = 'Teammates',
	Tooltip = 'Also lists your teammates'
})
ShowFinals = RespawnTimers:CreateToggle({
	Name = 'Final Kills',
	Tooltip = 'Briefly lists players who are out for good',
	Default = true
})
WorldMarkers = RespawnTimers:CreateToggle({
	Name = 'World Markers',
	Tooltip = 'Marks where each one died',
	Default = true
})
Corner = RespawnTimers:CreateDropdown({
	Name = 'Position',
	List = {'Top Right', 'Top Left', 'Bottom Right', 'Bottom Left'},
	Tooltips = {
		['Top Right'] = 'Top right of the screen',
		['Top Left'] = 'Top left of the screen',
		['Bottom Right'] = 'Bottom right of the screen',
		['Bottom Left'] = 'Bottom left of the screen'
	},
	Function = place
})
Background = RespawnTimers:CreateColorSlider({
	Name = 'Background',
	Tooltip = 'Colour of the panel',
	DefaultValue = 0.08,
	DefaultOpacity = 0.6,
	Function = function(hue, sat, val, opacity)
		if panel then
			panel.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			panel.BackgroundTransparency = 1 - opacity
		end
	end
})
