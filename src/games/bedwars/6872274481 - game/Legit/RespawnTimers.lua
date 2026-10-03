--[[
	Respawn Timers.

	Every death reaches every client as EntityDeathEvent, carrying the character that died
	and its respawnDuration - the same number the game's own respawn screen counts down.
	The player's RespawningAtTime attribute (server time) is used instead when the game has
	set it. A death with the team's bed already broken is a final kill: no respawn.

	The dead are listed on a small panel with the seconds until they are back, and
	optionally marked where they fell. Someone who died in the void is marked at the last
	solid ground they stood on - the edge they went off - instead of out in the void, or on
	their team's bed if they were never seen on the ground. Nothing here asks the server
	for anything.
]]
local RespawnTimers
local Teammates, ShowFinals, WorldMarkers, Corner, Background
local RespawnSound, WarnBefore, OnlyNearby, NearbyRange, AlwaysShow, PanelScale, FontOption
local panel, list, scaler
local dead = {}
local rows = {}
local Folder = Instance.new('Folder')
Folder.Name = 'RespawnTimers'
Folder.Parent = vain.gui

local FINAL_HOLD = 6
local GROUND_CHECK = 0.3
local lastGround = {}
local lastGroundCheck = 0

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.RespectCanCollide = true

--[[
	The void height, the same line AntiFall and Trajectories use: AntiFall's floor when it
	has one, otherwise 2 studs under the lowest block with nothing on top of it. Read from
	the local block store and kept for 5 seconds.
]]
local voidHeight, voidCheckedAt = nil, 0
local function getVoidHeight()
	if AntiFallPart and AntiFallPart.Parent then
		return AntiFallPart.Position.Y
	end
	if os.clock() - voidCheckedAt < 5 then return voidHeight end
	voidCheckedAt = os.clock()
	local ok, low = pcall(function()
		local lowest = math.huge
		for _, pos in bedwars.BlockController:getStore():getAllBlockPositions() do
			pos *= 3
			if pos.Y < lowest and not getPlacedBlock(pos + Vector3.new(0, 3, 0)) then
				lowest = pos.Y
			end
		end
		return lowest
	end)
	voidHeight = ok and low ~= math.huge and (low - 2) or voidHeight
	return voidHeight
end

-- Where each player last stood on something: a short ray down from their root finds a
-- block under their feet. A few rays every 0.3 seconds, not every frame.
local function trackGround()
	if os.clock() - lastGroundCheck < GROUND_CHECK then return end
	lastGroundCheck = os.clock()
	local ignore = {gameCamera, Folder}
	for _, plr in playersService:GetPlayers() do
		if plr.Character then ignore[#ignore + 1] = plr.Character end
	end
	groundParams.FilterDescendantsInstances = ignore
	for _, entity in entitylib.List do
		local player, root = entity.Player, entity.RootPart
		if player and player ~= lplr and root and root.Parent and entity.Health > 0 then
			local hit = workspace:Raycast(root.Position, Vector3.new(0, -6, 0), groundParams)
			if hit then lastGround[player] = hit.Position end
		end
	end
end

-- Their team's bed: the blanket is in the team colour.
local function bedOf(player)
	if not player.Team then return nil end
	local target = player.TeamColor.Color
	for _, bed in collectionService:GetTagged('bed') do
		local blanket = bed:FindFirstChild('Blanket') or bed:FindFirstChild('Covers')
		if blanket and blanket:IsA('BasePart') then
			local c = blanket.Color
			if math.abs(c.R - target.R) + math.abs(c.G - target.G) + math.abs(c.B - target.B) < 0.1 then
				return bed:GetPivot().Position
			end
		end
	end
	return nil
end

-- Where to put the marker: where they died, unless that is out in the void.
local function markerPosition(player, died)
	local void = getVoidHeight()
	if not void or died.Y > void + 2 then return died end
	return lastGround[player] or bedOf(player) or Vector3.new(died.X, void + 10, died.Z)
end

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
	trackGround()

	local team = player:GetAttribute('Team')
	local final = team ~= nil and brokenbeds[team] ~= nil
	local now = workspace:GetServerTimeNow()
	local entry = {
		final = final,
		respawnAt = now + (tonumber(deathTable.respawnDuration) or 5),
		diedAt = now
	}
	entry.duration = math.max(entry.respawnAt - now, 0.1)

	local root = deathTable.entityInstance:FindFirstChild('HumanoidRootPart') or deathTable.entityInstance.PrimaryPart
	entry.deathPosition = root and root.Position
	if root then
		local marker = Instance.new('BillboardGui')
		marker.Size = UDim2.fromOffset(140, 20)
		marker.AlwaysOnTop = true
		marker.StudsOffsetWorldSpace = Vector3.new(0, 2, 0)
		local anchor = Instance.new('Attachment')
		anchor.WorldPosition = markerPosition(player, root.Position)
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

--[[
	The panel: a rounded card with a small header and count, and a row per player - their
	avatar, name in their team colour, the seconds left on the right and a thin bar in the
	team colour draining to the respawn. It grows and shrinks smoothly as rows come and go,
	and while the GUI is open with nobody dead it shows a preview so it can be placed.
]]
local ROW_HEIGHT = 28
local HEADER_HEIGHT = 22
local PANEL_WIDTH = 200
local header, countLabel, sizeTween, lastHeight

local function guiOpen()
	local ok, open = pcall(function() return vain.gui.ScaledGui.ClickGui.Visible end)
	return ok and open == true
end

local function row(index)
	local entry = rows[index]
	if entry then return entry end
	local frame = Instance.new('Frame')
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	frame.LayoutOrder = index
	frame.Parent = list

	local avatar = Instance.new('ImageLabel')
	avatar.Size = UDim2.fromOffset(20, 20)
	avatar.Position = UDim2.fromOffset(0, 2)
	avatar.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	avatar.BorderSizePixel = 0
	avatar.Parent = frame
	Instance.new('UICorner', avatar).CornerRadius = UDim.new(1, 0)

	local name = Instance.new('TextLabel')
	name.BackgroundTransparency = 1
	name.Position = UDim2.fromOffset(27, 2)
	name.Size = UDim2.new(1, -80, 0, 20)
	name.TextSize = 13
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Parent = frame

	local timer = Instance.new('TextLabel')
	timer.BackgroundTransparency = 1
	timer.AnchorPoint = Vector2.new(1, 0)
	timer.Position = UDim2.new(1, 0, 0, 2)
	timer.Size = UDim2.fromOffset(50, 20)
	timer.TextSize = 13
	timer.TextXAlignment = Enum.TextXAlignment.Right
	timer.Parent = frame

	local track = Instance.new('Frame')
	track.Position = UDim2.new(0, 27, 1, -3)
	track.Size = UDim2.new(1, -27, 0, 2)
	track.BackgroundColor3 = Color3.new(1, 1, 1)
	track.BackgroundTransparency = 0.88
	track.BorderSizePixel = 0
	track.Parent = frame
	Instance.new('UICorner', track).CornerRadius = UDim.new(1, 0)
	local fill = Instance.new('Frame')
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(1, 1)
	fill.Parent = track
	Instance.new('UICorner', fill).CornerRadius = UDim.new(1, 0)

	entry = {frame = frame, avatar = avatar, name = name, timer = timer, track = track, fill = fill}
	rows[index] = entry
	return entry
end

local function render(items, font)
	for i, item in items do
		local entry = row(i)
		local color = item.player.Team and item.player.TeamColor.Color or Color3.fromRGB(230, 230, 230)
		entry.avatar.Image = 'rbxthumb://type=AvatarHeadShot&id=' .. item.player.UserId .. '&w=48&h=48'
		entry.name.Text = item.player.DisplayName
		entry.name.TextColor3 = color
		entry.name.FontFace = font
		entry.timer.Text = item.text
		entry.timer.TextColor3 = item.final and Color3.fromRGB(255, 95, 95) or Color3.fromRGB(235, 235, 235)
		entry.timer.FontFace = font
		entry.track.Visible = not item.final
		entry.fill.BackgroundColor3 = color
		entry.fill.Size = UDim2.fromScale(math.clamp(item.fraction or 0, 0, 1), 1)
		entry.frame.Visible = true
	end
	for i = #items + 1, #rows do rows[i].frame.Visible = false end
end

-- Resized with a short tween rather than snapping.
local function resize(count)
	local height = HEADER_HEIGHT + math.max(count, 1) * ROW_HEIGHT + 10
	if height == lastHeight then return end
	lastHeight = height
	if sizeTween then sizeTween:Cancel() end
	sizeTween = tweenService:Create(panel, TweenInfo.new(0.15, Enum.EasingStyle.Quad), {Size = UDim2.fromOffset(PANEL_WIDTH, height)})
	sizeTween:Play()
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
		if wanted and on(OnlyNearby) and entry.deathPosition and entitylib.isAlive then
			wanted = (entry.deathPosition - entitylib.character.RootPart.Position).Magnitude <= NearbyRange.Value
		end
		-- A ping just before an enemy is back, once per death.
		if wanted and on(RespawnSound) and not entry.final and not entry.warned and remaining <= WarnBefore.Value and not sameTeam(player) then
			entry.warned = true
			pcall(function()
				bedwars.SoundManager:playSound(bedwars.SoundList.PING_DANGER)
			end)
		end
		local text = entry.final and 'FINAL' or string.format('%.1fs', math.max(remaining, 0))
		if entry.marker then
			entry.marker.Enabled = wanted and on(WorldMarkers)
			entry.markerLabel.Text = player.DisplayName .. '  ' .. text
			entry.markerLabel.TextColor3 = player.Team and player.TeamColor.Color or Color3.new(1, 1, 1)
		end
		if wanted then
			local duration = math.max(entry.respawnAt - entry.diedAt, 0.1)
			shown[#shown + 1] = {player = player, text = text, final = entry.final, remaining = remaining, fraction = remaining / duration}
		end
	end
	table.sort(shown, function(a, b)
		if a.final ~= b.final then return not a.final end
		return a.remaining < b.remaining
	end)

	local font = FontOption and FontOption.Value or Font.fromEnum(Enum.Font.GothamBold)
	if header then header.FontFace = font end
	if scaler then scaler.Scale = PanelScale.Value end

	local preview = #shown == 0 and guiOpen()
	if preview then
		-- A stand-in so the panel can be seen and placed while the GUI is open.
		local t = os.clock() % 5
		shown = {
			{player = lplr, text = string.format('%.1fs', 5 - t), fraction = (5 - t) / 5},
			{player = lplr, text = 'FINAL', final = true}
		}
	end

	countLabel.Text = preview and 'PREVIEW' or (#shown > 0 and tostring(#shown) or '')
	if #shown == 0 and on(AlwaysShow) then
		render({}, font)
		countLabel.Text = 'none'
		panel.Visible = true
		resize(0)
		return
	end
	render(shown, font)
	panel.Visible = #shown > 0
	resize(#shown)
end

-- Inside the module's draggable frame where the GUI gives it one; pinned to a corner of
-- the screen otherwise.
local function place()
	if not panel then return end
	if RespawnTimers.Children then
		panel.AnchorPoint = Vector2.zero
		panel.Position = UDim2.fromOffset(0, 0)
		return
	end
	local corner = CORNERS[Corner.Value] or CORNERS['Top Right']
	panel.AnchorPoint = corner[1]
	panel.Position = corner[2]
end

local function build()
	lastHeight = nil
	panel = Instance.new('Frame')
	panel.Name = 'RespawnTimers'
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, HEADER_HEIGHT + ROW_HEIGHT + 10)
	panel.ClipsDescendants = true
	panel.Parent = RespawnTimers.Children or vain.gui
	Instance.new('UICorner', panel).CornerRadius = UDim.new(0, 8)
	local stroke = Instance.new('UIStroke')
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Transparency = 0.9
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = panel
	local padding = Instance.new('UIPadding')
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.PaddingTop = UDim.new(0, 6)
	padding.Parent = panel

	scaler = Instance.new('UIScale')
	scaler.Parent = panel

	header = Instance.new('TextLabel')
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, -60, 0, HEADER_HEIGHT - 6)
	header.TextSize = 11
	header.TextColor3 = Color3.fromRGB(150, 150, 150)
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = 'RESPAWNING'
	header.Parent = panel
	countLabel = Instance.new('TextLabel')
	countLabel.BackgroundTransparency = 1
	countLabel.AnchorPoint = Vector2.new(1, 0)
	countLabel.Position = UDim2.fromScale(1, 0)
	countLabel.Size = UDim2.fromOffset(60, HEADER_HEIGHT - 6)
	countLabel.Font = Enum.Font.GothamBold
	countLabel.TextSize = 11
	countLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
	countLabel.TextXAlignment = Enum.TextXAlignment.Right
	countLabel.Parent = panel

	list = Instance.new('Frame')
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromOffset(0, HEADER_HEIGHT)
	list.Size = UDim2.new(1, 0, 1, -HEADER_HEIGHT)
	list.Parent = panel
	local layout = Instance.new('UIListLayout')
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	panel.BackgroundColor3 = Color3.fromHSV(Background.Hue, Background.Sat, Background.Value)
	panel.BackgroundTransparency = 1 - Background.Opacity
	place()
end

RespawnTimers = vain.Legit:CreateModule({
	Name = 'Respawn Timers',
	Tooltip = 'Shows when dead players respawn',
	Size = UDim2.fromOffset(200, 60),
	Function = function(callback)
		if callback then
			build()
			RespawnTimers:Clean(panel)
			RespawnTimers:Clean(vainEvents.EntityDeathEvent.Event:Connect(function(deathTable)
				pcall(onDeath, deathTable)
			end))
			RespawnTimers:Clean(runService.RenderStepped:Connect(function()
				pcall(trackGround)
				pcall(update)
			end))
		else
			for player in dead do forget(player) end
			table.clear(rows)
			table.clear(lastGround)
			panel, list, header, countLabel, scaler = nil, nil, nil, nil, nil
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
RespawnSound = RespawnTimers:CreateToggle({
	Name = 'Respawn Sound',
	Tooltip = 'Pings just before an enemy is back',
	Function = function(callback)
		if WarnBefore and WarnBefore.Object then WarnBefore.Object.Visible = callback end
	end
})
WarnBefore = RespawnTimers:CreateSlider({
	Name = 'Warn Before',
	Tooltip = 'Seconds before they respawn',
	Min = 0,
	Max = 5,
	Default = 1,
	Decimal = 10,
	Darker = true,
	Visible = false,
	Suffix = function() return 's' end
})
OnlyNearby = RespawnTimers:CreateToggle({
	Name = 'Only Nearby',
	Tooltip = 'Only players who died near you',
	Function = function(callback)
		if NearbyRange and NearbyRange.Object then NearbyRange.Object.Visible = callback end
	end
})
NearbyRange = RespawnTimers:CreateSlider({
	Name = 'Nearby Range',
	Tooltip = 'How close they had to die',
	Min = 10,
	Max = 300,
	Default = 80,
	Darker = true,
	Visible = false,
	Suffix = function(val) return val == 1 and 'stud' or 'studs' end
})
AlwaysShow = RespawnTimers:CreateToggle({
	Name = 'Always Show',
	Tooltip = 'Keeps the panel up even when nobody is dead'
})
PanelScale = RespawnTimers:CreateSlider({
	Name = 'Scale',
	Tooltip = 'How big the panel is',
	Min = 0.6,
	Max = 2,
	Default = 1,
	Decimal = 10
})
FontOption = RespawnTimers:CreateFont({
	Name = 'Font',
	Tooltip = 'Font used for the panel',
	Blacklist = 'GothamBold'
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
	Function = place,
	-- Only needed where there is no draggable frame to put it in.
	Visible = RespawnTimers.Children == nil
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
