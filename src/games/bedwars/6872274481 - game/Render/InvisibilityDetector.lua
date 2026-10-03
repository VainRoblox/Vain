--[[
	Invisibility Detector.

	Invisibility is written on the character: status effects as StatusEffect_<type>
	attributes (StatusEffectUtil:getAttributeName) - invisibility potions, smoke bombs, the
	ninja's jutsu, the snake's agility - and the potion's fade as a Transparency attribute,
	which InvisibilityPotionController applies. The cloak sets the character see-through
	directly. Anyone showing any of these is outlined, with a tag saying so, through walls.
]]
local InvisibilityDetector
local Teammates, ShowTag, Color
local Folder = Instance.new('Folder')
Folder.Name = 'InvisibilityDetector'
Folder.Parent = vain.gui
local marked = {}

local EFFECTS = {'invisibility', 'smoke_invisibility', 'ninja_invisible', 'snake_agility_invisible'}

local function invisible(character)
	for _, effect in EFFECTS do
		if character:GetAttribute('StatusEffect_' .. effect) ~= nil then return true end
	end
	local transparency = character:GetAttribute('Transparency')
	if type(transparency) == 'number' and transparency > 0.5 then return true end
	-- The cloak (and block disguises) fade the body itself, through Transparency or the
	-- CharacterTransparencyController's LocalTransparencyModifier; the head is a part every
	-- character keeps.
	local head = character:FindFirstChild('Head')
	return head ~= nil and head:IsA('BasePart') and math.max(head.Transparency, head.LocalTransparencyModifier) >= 0.85
end

local function unmark(character)
	local entry = marked[character]
	if not entry then return end
	entry.highlight:Destroy()
	entry.billboard:Destroy()
	marked[character] = nil
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
	entry.billboard.Enabled = ShowTag.Enabled
end

local function update()
	local seen = {}
	for _, entity in entitylib.List do
		local character = entity.Character
		if entity.Player and character and entity.Player ~= lplr and (entity.Targetable or Teammates.Enabled) then
			local head = entity.Head or character:FindFirstChild('Head')
			if head and invisible(character) then
				seen[character] = true
				mark(character, head)
			end
		end
	end
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
Color = InvisibilityDetector:CreateColorSlider({
	Name = 'Color',
	Tooltip = 'Colour of the outline',
	DefaultHue = 0.8,
	DefaultSat = 0.6,
	DefaultValue = 1,
	DefaultOpacity = 0.45
})
