--[[
	TNT Timer.

	Placed TNT carries the CollectionService tag 'tnt' and the game's timeUntilExplosion
	attribute - three seconds when it does not say otherwise - and the fuse runs from the
	moment it appears. So each one is timed from when it shows up, and a countdown to a tenth
	of a second hangs over it, running from green at a fresh fuse to red as it is about to go.
]]
local TNTTimer
local ThroughWalls, TextSize, ShowSuffix
local Folder = Instance.new('Folder')
Folder.Parent = vain.gui
local timers = {}

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function partOf(tnt)
	if tnt:IsA('BasePart') then return tnt end
	return tnt:FindFirstChildWhichIsA('BasePart', true)
end

local function remove(tnt)
	local entry = timers[tnt]
	if entry then
		entry.billboard:Destroy()
		timers[tnt] = nil
	end
end

local function add(tnt)
	if timers[tnt] then return end
	local part = partOf(tnt)
	if not part then return end

	local fuse = tonumber(tnt:GetAttribute('timeUntilExplosion')) or 3
	local billboard = Instance.new('BillboardGui')
	billboard.Name = 'TNTTimer'
	billboard.Adornee = part
	billboard.Size = UDim2.fromOffset(80, 36)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = on(ThroughWalls)
	billboard.Parent = Folder

	local label = Instance.new('TextLabel')
	label.Name = 'Label'
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextStrokeTransparency = 0.3
	label.Parent = billboard

	timers[tnt] = {billboard = billboard, started = os.clock(), fuse = math.max(fuse, 0.1)}
end

local function update()
	local now = os.clock()
	local size = TextSize and TextSize.Value or 22
	for tnt, entry in timers do
		local remaining = entry.fuse - (now - entry.started)
		if not tnt.Parent or remaining < -1 then
			remove(tnt)
			continue
		end
		remaining = math.max(remaining, 0)
		-- Green with the whole fuse left, red as it runs out.
		local fraction = math.clamp(remaining / entry.fuse, 0, 1)
		local label = entry.billboard.Label
		label.Text = string.format('%.1f', remaining) .. (on(ShowSuffix) and 's' or '')
		label.TextColor3 = Color3.fromHSV(fraction * 0.33, 0.95, 1)
		label.TextSize = size
		entry.billboard.Size = UDim2.fromOffset(size * 4, size + 12)
		entry.billboard.AlwaysOnTop = on(ThroughWalls)
	end
end

TNTTimer = vain.Legit:CreateModule({
	Name = 'TNT Timer',
	Tooltip = 'Shows how long until each placed TNT explodes',
	Function = function(callback)
		if callback then
			for _, tnt in collectionService:GetTagged('tnt') do add(tnt) end
			TNTTimer:Clean(collectionService:GetInstanceAddedSignal('tnt'):Connect(add))
			TNTTimer:Clean(collectionService:GetInstanceRemovedSignal('tnt'):Connect(remove))
			TNTTimer:Clean(runService.RenderStepped:Connect(function()
				pcall(update)
			end))
		else
			for tnt in timers do remove(tnt) end
		end
	end
})
ThroughWalls = TNTTimer:CreateToggle({
	Name = 'Through Walls',
	Tooltip = 'Shows the timer even behind blocks',
	Default = true
})
TextSize = TNTTimer:CreateSlider({
	Name = 'Text Size',
	Tooltip = 'How big the timer is',
	Min = 10,
	Max = 40,
	Default = 22
})
ShowSuffix = TNTTimer:CreateToggle({
	Name = 'Show Seconds',
	Tooltip = 'Adds an s after the number'
})
