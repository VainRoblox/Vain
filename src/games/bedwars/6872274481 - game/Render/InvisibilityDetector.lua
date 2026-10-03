--[[
	Invisibility Detector.

	Invisibility is written on the character: status effects as StatusEffect_<type>
	attributes (StatusEffectUtil:getAttributeName) - invisibility potions, smoke bombs, the
	ninja's jutsu, the snake's agility - and the cloak through the server's
	InvisibleCloakState event. Anyone showing any of these is outlined, with a tag saying so, through walls,
	and can leave footsteps behind and have a line drawn to them.
]]
local InvisibilityDetector
local Teammates, ShowTag, Color, Footsteps, TrailLength, Tracer, ShowDuration
local steps = {}
local tracers = {}
local lastStep = 0
local STEP_EVERY = 0.2
local Folder = Instance.new('Folder')
Folder.Name = 'InvisibilityDetector'
Folder.Parent = vain.gui
local marked = {}

local EFFECTS = {'invisibility', 'smoke_invisibility', 'ninja_invisible', 'snake_agility_invisible'}

--[[
	Who is cloaked, from the game's own InvisibleCloakState event: the cloak hides you by a
	transparency modifier, which nothing on the character records. Listened to from load,
	so a cloak put on before the module is switched on is still known.
]]
local cloaked = {}
-- In its own thread: getting the remote can wait for it, and a wait on the loading thread
-- brings it back without the identity the rest of the load needs to create instances.
task.spawn(function()
	pcall(function()
		local connection = bedwars.Client:Get('InvisibleCloakState'):Connect(function(data)
			if type(data) == 'table' and data.player then
				cloaked[data.player] = data.active == true or nil
			end
		end)
		vain:Clean(connection)
	end)
end)

--[[
	Invisible means one of the game's invisibility effects is on them, or their cloak is.

	The Transparency attribute and the head's own transparency used to count as well, and
	that is what made this wrong so often: the game sets Transparency to 1 whenever it plays
	a teleport - Lani landing, comet volley, portals, emotes - while a copy of the character
	does the animation, and a headless or custom head is see-through all the time.
]]
local function invisible(character, player)
	for _, effect in EFFECTS do
		if character:GetAttribute('StatusEffect_' .. effect) ~= nil then return true end
	end
	return player ~= nil and cloaked[player] == true
end

-- Seconds left on a status effect, when its attribute holds the server time it ends.
local function remaining(character)
	local now = workspace:GetServerTimeNow()
	for _, effect in EFFECTS do
		local value = character:GetAttribute('StatusEffect_' .. effect)
		if type(value) == 'number' and value > now and value - now < 600 then
			return value - now
		end
	end
	return nil
end

local function unmark(character)
	local entry = marked[character]
	if not entry then return end
	entry.highlight:Destroy()
	entry.billboard:Destroy()
	marked[character] = nil
	local line = tracers[character]
	if line then
		pcall(function() line:Remove() end)
		tracers[character] = nil
	end
end

-- A dot where their feet are, every fifth of a second, fading out along the trail.
local function addStep(root, color)
	local dot = Instance.new('SphereHandleAdornment')
	dot.Adornee = workspace.Terrain
	dot.Radius = 0.35
	dot.CFrame = CFrame.new(root.Position - Vector3.new(0, 2.8, 0))
	dot.AlwaysOnTop = true
	dot.ZIndex = 1
	dot.Color3 = color
	dot.Parent = Folder
	table.insert(steps, dot)
	while #steps > TrailLength.Value / STEP_EVERY do
		table.remove(steps, 1):Destroy()
	end
end

local function fadeSteps()
	local count = #steps
	for i, dot in steps do
		dot.Transparency = 0.2 + 0.75 * (1 - i / count)
	end
end

local function clearSteps()
	for _, dot in steps do dot:Destroy() end
	table.clear(steps)
end

local function drawTracer(character, root, color)
	local line = tracers[character]
	if not Tracer.Enabled then
		if line then line.Visible = false end
		return
	end
	if not line then
		line = Drawing.new('Line')
		line.Thickness = 1.5
		tracers[character] = line
	end
	local point, visible = gameCamera:WorldToViewportPoint(root.Position)
	local viewport = gameCamera.ViewportSize
	line.Visible = point.Z > 0
	line.From = Vector2.new(viewport.X / 2, viewport.Y)
	line.To = Vector2.new(point.X, point.Y)
	line.Color = color
	line.Transparency = 1
end

local function mark(character, head)
	local entry = marked[character]
	if not entry then
		local highlight = Instance.new('Highlight')
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Adornee = character
		highlight.Parent = Folder

		local billboard = Instance.new('BillboardGui')
		billboard.Adornee = head
		billboard.Size = UDim2.fromOffset(120, 18)
		billboard.StudsOffsetWorldSpace = Vector3.new(0, 2.5, 0)
		billboard.AlwaysOnTop = true
		billboard.Parent = Folder
		local label = Instance.new('TextLabel')
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextSize = 13
		label.TextStrokeTransparency = 0.4
		label.Text = 'INVISIBLE'
		label.Parent = billboard

		entry = {highlight = highlight, billboard = billboard, label = label}
		marked[character] = entry
	end
	local color = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
	entry.highlight.FillColor = color
	entry.highlight.OutlineColor = color
	entry.highlight.FillTransparency = 1 - Color.Opacity
	entry.label.TextColor3 = color
	local left = ShowDuration.Enabled and remaining(character)
	entry.label.Text = left and string.format('INVISIBLE %.1fs', left) or 'INVISIBLE'
	entry.billboard.Enabled = ShowTag.Enabled
end

local function update()
	local seen = {}
	local stepNow = Footsteps.Enabled and os.clock() - lastStep >= STEP_EVERY
	if stepNow then lastStep = os.clock() end
	local color = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
	for _, entity in entitylib.List do
		local character = entity.Character
		if entity.Player and character and entity.Player ~= lplr and (entity.Targetable or Teammates.Enabled) then
			local head = entity.Head or character:FindFirstChild('Head')
			if head and (entity.Health or 0) > 0 and invisible(character, entity.Player) then
				seen[character] = true
				mark(character, head)
				local root = entity.RootPart
				if root then
					if stepNow then addStep(root, color) end
					drawTracer(character, root, color)
				end
			end
		end
	end
	if not Footsteps.Enabled and #steps > 0 then clearSteps() end
	fadeSteps()
	for character in marked do
		if not seen[character] then unmark(character) end
	end
end

InvisibilityDetector = vain.Categories.Render:CreateModule({
	Name = 'Invisibility Detector',
	Tooltip = 'Outlines players who are invisible',
	Function = function(callback)
		if callback then
			InvisibilityDetector:Clean(runService.RenderStepped:Connect(function()
				pcall(update)
			end))
		else
			for character in marked do unmark(character) end
			clearSteps()
		end
	end
})
Teammates = InvisibilityDetector:CreateToggle({
	Name = 'Teammates',
	Tooltip = 'Also outlines invisible teammates'
})
ShowTag = InvisibilityDetector:CreateToggle({
	Name = 'Tag',
	Tooltip = 'Writes INVISIBLE above them',
	Default = true
})
ShowDuration = InvisibilityDetector:CreateToggle({
	Name = 'Duration',
	Tooltip = 'Shows how long they stay invisible, when known',
	Default = true
})
Footsteps = InvisibilityDetector:CreateToggle({
	Name = 'Footsteps',
	Tooltip = 'Leaves dots where they walk',
	Default = true,
	Function = function(callback)
		if TrailLength and TrailLength.Object then TrailLength.Object.Visible = callback end
	end
})
TrailLength = InvisibilityDetector:CreateSlider({
	Name = 'Trail Length',
	Tooltip = 'How many seconds of footsteps stay',
	Min = 1,
	Max = 15,
	Default = 5,
	Darker = true,
	Suffix = function() return 's' end
})
Tracer = InvisibilityDetector:CreateToggle({
	Name = 'Tracer',
	Tooltip = 'Draws a line to each of them'
})
Color = InvisibilityDetector:CreateColorSlider({
	Name = 'Color',
	Tooltip = 'Colour of the outline',
	DefaultHue = 0.8,
	DefaultSat = 0.6,
	DefaultValue = 1,
	DefaultOpacity = 0.45
})
