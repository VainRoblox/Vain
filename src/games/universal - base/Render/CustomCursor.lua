local CustomCursor
local Source
local Preset
local ImageId
local File
local Mode
local Size
local Recolour
local Tint
local Hide

local cursor
local oldIcon
local oldEnabled

--[[
	The icons the old client shipped with, kept so there is something to use straight away.

	Carried over rather than reinvented: these are the ones people already know by name, and
	Arrow is the one it defaulted to.
]]
local PRESETS = {
	['Arrow'] = 'rbxassetid://14790316561',
	['Triangle'] = 'rbxassetid://14790304072',
	['CS:GO'] = 'rbxassetid://14789879068',
	['Old Roblox Mouse'] = 'rbxassetid://13546344315',
	['dx9ware'] = 'rbxassetid://12233942144',
	['Aimbot'] = 'rbxassetid://8680062686',
}

--[[
	Where the picture comes from.

	Two ways to name an image and they are not interchangeable: a Roblox asset is fetched by
	id, and a file on disk has to be handed to the engine by the executor first. getcustomasset
	does that - it copies the file somewhere the engine will load from and returns a path -
	and it only exists under an executor, so its absence is reported rather than left to fail
	silently as a cursor that never changes.
]]
local function chosenImage()
	if not (Source and Preset and ImageId and File) then return nil end

	if Source.Value == 'Preset' then
		return PRESETS[Preset.Value] or PRESETS.Arrow
	end

	if Source.Value == 'File' then
		local path = File.Value
		if path == '' then return nil, 'no file name given' end
		if isfile and not isfile(path) then return nil, path .. ' does not exist' end
		if not getcustomasset then return nil, 'this executor cannot load local images' end

		local ok, asset = pcall(getcustomasset, path)
		if not ok or not asset then return nil, 'could not load ' .. path end
		return asset
	end

	local id = ImageId.Value
	if id == '' then return nil, 'no image id given' end
	-- A bare number is what people paste, so it is accepted as well as the full path.
	if tonumber(id) then id = 'rbxassetid://' .. id end
	return id
end

local function complain(reason)
	if vain and vain.CreateNotification then
		vain:CreateNotification('Custom Cursor', reason, 5, 'alert')
	end
end

--[[
	Drawn rather than set, when the size matters.

	MouseIcon takes whatever image you give it at whatever size that image happens to be, so
	a cursor cannot be scaled or tinted that way. Overlay hides the real pointer and follows
	the mouse with an ImageLabel instead, which can be any size and any colour - at the cost
	of being drawn a frame behind where the pointer truly is.
]]
local function makeCursor()
	cursor = Instance.new('ImageLabel')
	cursor.Name = 'VainCursor'
	cursor.BackgroundTransparency = 1
	cursor.AnchorPoint = Vector2.new(0.5, 0.5)
	cursor.ZIndex = 10
	cursor.Parent = vain.gui
end

local function apply()
	-- Settings are created after the module, so during a config restore some of these do
	-- not exist yet and every one of them is read below.
	if not (CustomCursor and Mode and Size and Tint and Recolour and Hide) then return end
	if not CustomCursor.Enabled then return end

	local image, reason = chosenImage()
	if not image then
		if reason then complain(reason) end
		return
	end

	if Mode.Value == 'Overlay' then
		if not cursor then makeCursor() end
		cursor.Image = image
		cursor.Size = UDim2.fromOffset(Size.Value, Size.Value)
		-- Left alone unless asked: an image people chose is usually the colour they want.
		cursor.ImageColor3 = Recolour.Enabled and Color3.fromHSV(Tint.Hue, Tint.Sat, Tint.Value) or Color3.new(1, 1, 1)
		cursor.ImageTransparency = Recolour.Enabled and (1 - (Tint.Opacity or 1)) or 0
		inputService.MouseIconEnabled = not Hide.Enabled and true or false
	else
		if cursor then
			cursor:Destroy()
			cursor = nil
		end
		inputService.MouseIconEnabled = true
		inputService.MouseIcon = image
	end
end

CustomCursor = vain.Categories.Render:CreateModule({
	Name = 'Custom Cursor',
	Tooltip = 'Replaces the mouse pointer with a Roblox image or a file from your Vain folder',
	Function = function(callback)
		if callback then
			oldIcon = inputService.MouseIcon
			oldEnabled = inputService.MouseIconEnabled
			apply()

			--[[
				Put back every so often, because games take it away.

				Plenty of games set the pointer themselves - hovering their own buttons,
				equipping a tool, opening a menu - and whatever they set wins until something
				sets it again. Reapplying keeps ours in place without fighting for it every
				frame.
			]]
			CustomCursor:Clean(runService.Heartbeat:Connect(function()
				if cursor then
					local mouse = inputService:GetMouseLocation()
					local inset = guiService:GetGuiInset()
					cursor.Position = UDim2.fromOffset(mouse.X - inset.X, mouse.Y - inset.Y)
				end
			end))

			task.spawn(function()
				repeat
					if Mode.Value ~= 'Overlay' and inputService.MouseIcon ~= '' then
						local image = chosenImage()
						if image and inputService.MouseIcon ~= image then
							inputService.MouseIcon = image
						end
					end
					task.wait(0.25)
				until not CustomCursor.Enabled
			end)
		else
			if cursor then
				cursor:Destroy()
				cursor = nil
			end
			if oldIcon ~= nil then inputService.MouseIcon = oldIcon end
			if oldEnabled ~= nil then inputService.MouseIconEnabled = oldEnabled end
		end
	end
})
Source = CustomCursor:CreateDropdown({
	Name = 'Source',
	List = {'Preset', 'Image ID', 'File'},
	Default = 'Preset',
	Tooltip = 'Where the image comes from',
	ItemTooltips = {
		Preset = 'One of the icons the client ships with, for when you have none of your own',
		['Image ID'] = 'A Roblox asset, by id',
		File = 'An image in your executor folder, loaded from disk',
	},
	Function = apply
})
Preset = CustomCursor:CreateDropdown({
	Name = 'Preset',
	List = {'Arrow', 'Triangle', 'CS:GO', 'Old Roblox Mouse', 'dx9ware', 'Aimbot'},
	Default = 'Arrow',
	Tooltip = 'Which shipped icon to use',
	Function = apply
})
ImageId = CustomCursor:CreateTextBox({
	Name = 'Image ID',
	Default = '',
	Tooltip = 'Roblox asset id, with or without rbxassetid://',
	Function = apply
})
File = CustomCursor:CreateTextBox({
	Name = 'File',
	Default = 'vain/assets/cursor.png',
	Tooltip = 'Path to an image in your executor folder',
	Function = apply
})
Mode = CustomCursor:CreateDropdown({
	Name = 'Mode',
	List = {'System', 'Overlay'},
	Default = 'System',
	Tooltip = 'How the cursor is replaced',
	ItemTooltips = {
		System = 'Sets the real mouse pointer. Sharp, but the image decides its own size',
		Overlay = 'Draws the image over the mouse instead, so it can be sized and tinted',
	},
	Function = apply
})
Size = CustomCursor:CreateSlider({
	Name = 'Size',
	Min = 8,
	Max = 128,
	Default = 24,
	Suffix = 'px',
	Tooltip = 'Overlay only - how big the drawn cursor is',
	Function = apply
})
Recolour = CustomCursor:CreateToggle({
	Name = 'Recolour',
	Default = false,
	Tooltip = 'Overlay only - tints the image with the colour below instead of leaving it as it is',
	Function = apply
})
Tint = CustomCursor:CreateColorSlider({
	Name = 'Tint',
	Darker = true,
	Tooltip = 'Overlay only - the colour to tint with when Recolour is on',
	Function = apply
})
Hide = CustomCursor:CreateToggle({
	Name = 'Hide real cursor',
	Default = true,
	Tooltip = 'Overlay only - hides the pointer underneath the drawn one',
	Function = apply
})
