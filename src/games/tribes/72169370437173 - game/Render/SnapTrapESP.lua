--[[
	Snap Trap ESP.

	Snap traps are placed in the world as instances carrying the CollectionService tag
	BearTrap, so they are found by the tag rather than by guessing at names - a new trap is
	picked up the instant it is tagged, and dropped when it is removed. Each gets a highlight
	drawn through walls and, if you want it, a label with how far off it is, so a trap set in
	a doorway or round a corner is seen before you walk onto it.
]]
local SnapTrapESP
local Color
local ShowDistance
local Range
local TextSize

local collectionService = cloneref(game:GetService('CollectionService'))

local TAG = 'BearTrap'

-- trap instance -> {highlight, billboard, label}
local marks = {}

-- A folder for the billboards, so they are torn down in one go and never leak into the
-- world the way a stray BillboardGui parented to a trap would when the trap is removed.
local folder = Instance.new('Folder')
folder.Name = 'VainSnapTrapESP'
folder.Parent = vain.gui

local function colour()
	return Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
end

local function partOf(trap)
	if trap:IsA('BasePart') then return trap end
	return trap.PrimaryPart or trap:FindFirstChildWhichIsA('BasePart', true)
end

local function clear(trap)
	local mark = marks[trap]
	if mark then
		pcall(function() mark.highlight:Destroy() end)
		pcall(function() mark.billboard:Destroy() end)
		marks[trap] = nil
	end
end

local function clearAll()
	for trap in marks do
		clear(trap)
	end
end

local function ensure(trap)
	if marks[trap] then return marks[trap] end
	local part = partOf(trap)
	if not part then return nil end

	local highlight = Instance.new('Highlight')
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Adornee = trap
	highlight.FillTransparency = 0.6
	highlight.OutlineTransparency = 0
	highlight.Parent = folder

	local billboard = Instance.new('BillboardGui')
	billboard.Size = UDim2.fromOffset(140, 20)
	billboard.StudsOffset = Vector3.new(0, 2, 0)
	billboard.AlwaysOnTop = true
	billboard.Adornee = part
	billboard.Parent = folder
	local label = Instance.new('TextLabel')
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextStrokeTransparency = 0.4
	label.Text = 'Snap Trap'
	label.Parent = billboard

	marks[trap] = {highlight = highlight, billboard = billboard, label = label, part = part}
	return marks[trap]
end

SnapTrapESP = vain.Categories.Render:CreateModule({
	Name = 'Snap Trap ESP',
	Function = function(callback)
		if callback then
			-- Mark whatever is already down, then follow the tag as traps are set and sprung.
			for _, trap in collectionService:GetTagged(TAG) do
				ensure(trap)
			end
			SnapTrapESP:Clean(collectionService:GetInstanceAddedSignal(TAG):Connect(ensure))
			SnapTrapESP:Clean(collectionService:GetInstanceRemovedSignal(TAG):Connect(clear))

			SnapTrapESP:Clean(runService.RenderStepped:Connect(function()
				local tint = colour()
				local origin = entitylib.isAlive and entitylib.character.RootPart.Position or gameCamera.CFrame.Position

				for trap, mark in marks do
					if not trap.Parent or not mark.part.Parent then
						clear(trap)
					else
						mark.highlight.FillColor = tint
						mark.highlight.OutlineColor = tint

						if ShowDistance.Enabled then
							local dist = math.floor((mark.part.Position - origin).Magnitude)
							if dist > Range.Value then
								mark.highlight.Enabled = false
								mark.billboard.Enabled = false
							else
								mark.highlight.Enabled = true
								mark.billboard.Enabled = true
								mark.label.TextColor3 = tint
								mark.label.TextSize = TextSize.Value
								mark.label.Text = 'Snap Trap  '..dist..'m'
							end
						else
							mark.highlight.Enabled = true
							mark.billboard.Enabled = false
						end
					end
				end
			end))

			SnapTrapESP:Clean(clearAll)
		else
			clearAll()
		end
	end,
	Tooltip = 'Shows snap traps through walls'
})
Color = SnapTrapESP:CreateColorSlider({
	Name = 'Color',
	Tooltip = 'Colour of the trap highlight',
	DefaultHue = 0,
	DefaultSat = 0.8,
	DefaultValue = 1
})
ShowDistance = SnapTrapESP:CreateToggle({
	Name = 'Show Distance',
	Tooltip = 'Labels each trap with how far away it is',
	Function = function(callback)
		if TextSize and TextSize.Object then
			TextSize.Object.Visible = callback
		end
	end,
	Default = true
})
TextSize = SnapTrapESP:CreateSlider({
	Name = 'Text Size',
	Tooltip = 'How large the label is drawn',
	Min = 8,
	Max = 24,
	Default = 14,
	Darker = true
})
Range = SnapTrapESP:CreateSlider({
	Name = 'Range',
	Tooltip = 'How far a trap can be and still be shown',
	Min = 20,
	Max = 500,
	Default = 300,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
