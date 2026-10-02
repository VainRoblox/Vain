local optionapi = {
	Type = 'Dropdown',
	Value = optionsettings.List[1] or 'None',
	Index = 0
}

local dropdown = Instance.new('TextButton')
dropdown.Name = optionsettings.Name..'Dropdown'
dropdown.Size = UDim2.new(1, 0, 0, 40)
dropdown.BackgroundColor3 = color.Dark(children.BackgroundColor3, optionsettings.Darker and 0.02 or 0)
dropdown.BorderSizePixel = 0
dropdown.AutoButtonColor = false
dropdown.Visible = optionsettings.Visible == nil or optionsettings.Visible
dropdown.Text = ''
dropdown.Parent = children
addTooltip(dropdown, optionsettings.Tooltip or optionsettings.Name)
local bkg = Instance.new('Frame')
bkg.Name = 'BKG'
bkg.Size = UDim2.new(1, -20, 1, -9)
bkg.Position = UDim2.fromOffset(10, 4)
bkg.BackgroundColor3 = color.Light(uipallet.Main, 0.034)
bkg.Parent = dropdown
addCorner(bkg, UDim.new(0, 6))
local button = Instance.new('TextButton')
button.Name = 'Dropdown'
button.Size = UDim2.new(1, -2, 1, -2)
button.Position = UDim2.fromOffset(1, 1)
button.BackgroundColor3 = uipallet.Main
button.AutoButtonColor = false
button.Text = ''
button.Parent = bkg
-- What an option is shown as. Labels lets a list carry stable ids - item types, which
-- are what a config saves - while showing the names people actually know them by.
local function labelOf(v)
	local labels = optionsettings.Labels
	return labels and labels[v] or tostring(v)
end

local title = Instance.new('TextLabel')
title.Name = 'Title'
title.Size = UDim2.new(1, 0, 0, 29)
title.BackgroundTransparency = 1
title.Text = '         '..optionsettings.Name..' - '..labelOf(optionapi.Value)
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = color.Dark(uipallet.Text, 0.16)
title.TextSize = 13
title.TextTruncate = Enum.TextTruncate.AtEnd
title.FontFace = uipallet.Font
title.Parent = button
addCorner(button, UDim.new(0, 6))
local arrow = Instance.new('ImageLabel')
arrow.Name = 'Arrow'
arrow.Size = UDim2.fromOffset(4, 8)
arrow.Position = UDim2.new(1, -17, 0, 11)
arrow.BackgroundTransparency = 1
arrow.Image = getcustomasset('vain/assets/new/expandright.png')
arrow.ImageColor3 = Color3.fromRGB(140, 140, 140)
arrow.Rotation = 90
arrow.Parent = button
optionsettings.Function = optionsettings.Function or function() end
local dropdownchildren

function optionapi:Save(tab)
	tab[optionsettings.Name] = {Value = self.Value}
end

function optionapi:Load(tab)
	if self.Value ~= tab.Value then
		self:SetValue(tab.Value)
	end
end

function optionapi:Change(list)
	optionsettings.List = list or {}
	if not table.find(optionsettings.List, self.Value) then
		self:SetValue(self.Value)
	end
end

function optionapi:SetValue(val, mouse)
	self.Value = table.find(optionsettings.List, val) and val or optionsettings.List[1] or 'None'
	title.Text = '         '..optionsettings.Name..' - '..labelOf(self.Value)
	if dropdownchildren then
		arrow.Rotation = 90
		dropdownchildren:Destroy()
		dropdownchildren = nil
		dropdown.Size = UDim2.new(1, 0, 0, 40)
	end
	optionsettings.Function(self.Value, mouse)
end

--[[
	A dropdown you can type into, for lists too long to scroll by eye.

	Opened, it shows a search box over a scrolling list of what matches - by the label shown
	or the id behind it - instead of laying every option out end to end. A few hundred items
	drawn the plain way made a dropdown taller than the screen; this keeps it to a handful of
	rows and only builds the matches it is going to show.

	It sits on the dropdown itself rather than inside the button, so typing in the box or
	scrolling the results is not taken as a click that closes it.
]]
local SEARCH_ROWS, SEARCH_LIMIT = 8, 80

local function openSearch()
	dropdownchildren = Instance.new('Frame')
	dropdownchildren.Name = 'Children'
	dropdownchildren.Position = UDim2.fromOffset(11, 32)
	dropdownchildren.Size = UDim2.new(1, -22, 0, 0)
	dropdownchildren.BackgroundTransparency = 1
	dropdownchildren.Parent = dropdown

	local box = Instance.new('TextBox')
	box.Name = 'Search'
	box.Size = UDim2.new(1, 0, 0, 24)
	box.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.PlaceholderText = 'Search...'
	box.PlaceholderColor3 = color.Dark(uipallet.Text, 0.43)
	box.Text = ''
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextColor3 = color.Dark(uipallet.Text, 0.16)
	box.TextSize = 13
	box.FontFace = uipallet.Font
	box.Parent = dropdownchildren
	addCorner(box, UDim.new(0, 4))
	local padding = Instance.new('UIPadding')
	padding.PaddingLeft = UDim.new(0, 8)
	padding.Parent = box

	local results = Instance.new('ScrollingFrame')
	results.Name = 'Results'
	results.Position = UDim2.fromOffset(0, 28)
	results.BackgroundTransparency = 1
	results.BorderSizePixel = 0
	results.ScrollBarThickness = 3
	results.ScrollBarImageColor3 = color.Light(uipallet.Main, 0.37)
	results.CanvasSize = UDim2.new()
	results.Parent = dropdownchildren

	local function rebuild()
		for _, child in results:GetChildren() do
			child:Destroy()
		end

		local query = box.Text:lower()
		local shown = 0
		for _, v in optionsettings.List do
			if shown >= SEARCH_LIMIT then break end
			local label = labelOf(v)
			if query == '' or label:lower():find(query, 1, true) or tostring(v):lower():find(query, 1, true) then
				local option = Instance.new('TextButton')
				option.Name = tostring(v)..'Option'
				option.Size = UDim2.new(1, -4, 0, 26)
				option.Position = UDim2.fromOffset(0, shown * 26)
				option.BackgroundColor3 = v == optionapi.Value and color.Light(uipallet.Main, 0.04) or uipallet.Main
				option.BorderSizePixel = 0
				option.AutoButtonColor = false
				option.Text = '   '..label
				option.TextXAlignment = Enum.TextXAlignment.Left
				option.TextColor3 = color.Dark(uipallet.Text, v == optionapi.Value and 0 or 0.16)
				option.TextSize = 13
				option.TextTruncate = Enum.TextTruncate.AtEnd
				option.FontFace = uipallet.Font
				option.Parent = results
				addTooltip(option, optionsettings.Tooltips and optionsettings.Tooltips[v])
				option.MouseEnter:Connect(function()
					tween:Tween(option, uipallet.Tween, {
						BackgroundColor3 = color.Light(uipallet.Main, 0.02)
					})
				end)
				option.MouseLeave:Connect(function()
					tween:Tween(option, uipallet.Tween, {
						BackgroundColor3 = v == optionapi.Value and color.Light(uipallet.Main, 0.04) or uipallet.Main
					})
				end)
				option.MouseButton1Click:Connect(function()
					optionapi:SetValue(v, true)
				end)
				shown += 1
			end
		end

		if shown == 0 then
			local empty = Instance.new('TextLabel')
			empty.Size = UDim2.new(1, 0, 0, 26)
			empty.BackgroundTransparency = 1
			empty.Text = '   Nothing matches'
			empty.TextXAlignment = Enum.TextXAlignment.Left
			empty.TextColor3 = color.Dark(uipallet.Text, 0.43)
			empty.TextSize = 13
			empty.FontFace = uipallet.Font
			empty.Parent = results
		end

		local rows = math.clamp(shown, 1, SEARCH_ROWS)
		results.Size = UDim2.new(1, 0, 0, rows * 26)
		results.CanvasSize = UDim2.fromOffset(0, shown * 26)
		dropdownchildren.Size = UDim2.new(1, -22, 0, 28 + rows * 26)
		dropdown.Size = UDim2.new(1, 0, 0, 40 + 30 + rows * 26)
	end

	box:GetPropertyChangedSignal('Text'):Connect(rebuild)
	rebuild()
	task.defer(function()
		if box.Parent then
			pcall(box.CaptureFocus, box)
		end
	end)
end

button.MouseButton1Click:Connect(function()
	if not dropdownchildren then
		arrow.Rotation = 270
		if optionsettings.Search then
			openSearch()
			return
		end
		dropdown.Size = UDim2.new(1, 0, 0, 40 + (#optionsettings.List - 1) * 26)
		dropdownchildren = Instance.new('Frame')
		dropdownchildren.Name = 'Children'
		dropdownchildren.Size = UDim2.new(1, 0, 0, (#optionsettings.List - 1) * 26)
		dropdownchildren.Position = UDim2.fromOffset(0, 27)
		dropdownchildren.BackgroundTransparency = 1
		dropdownchildren.Parent = button
		local ind = 0
		for _, v in optionsettings.List do
			if v == optionapi.Value then continue end
			local dropdownoption = Instance.new('TextButton')
			dropdownoption.Name = v..'Option'
			dropdownoption.Size = UDim2.new(1, 0, 0, 26)
			dropdownoption.Position = UDim2.fromOffset(0, ind * 26)
			dropdownoption.BackgroundColor3 = uipallet.Main
			dropdownoption.BorderSizePixel = 0
			dropdownoption.AutoButtonColor = false
			dropdownoption.Text = '         '..labelOf(v)
			dropdownoption.TextXAlignment = Enum.TextXAlignment.Left
			dropdownoption.TextColor3 = color.Dark(uipallet.Text, 0.16)
			dropdownoption.TextSize = 13
			dropdownoption.TextTruncate = Enum.TextTruncate.AtEnd
			dropdownoption.FontFace = uipallet.Font
			dropdownoption.Parent = dropdownchildren
			-- Per-option tooltip, from optionsettings.Tooltips keyed by option name.
			-- addTooltip no-ops on nil, so dropdowns without the table are unaffected.
			addTooltip(dropdownoption, optionsettings.Tooltips and optionsettings.Tooltips[v])
			dropdownoption.MouseEnter:Connect(function()
				tween:Tween(dropdownoption, uipallet.Tween, {
					BackgroundColor3 = color.Light(uipallet.Main, 0.02)
				})
			end)
			dropdownoption.MouseLeave:Connect(function()
				tween:Tween(dropdownoption, uipallet.Tween, {
					BackgroundColor3 = uipallet.Main
				})
			end)
			dropdownoption.MouseButton1Click:Connect(function()
				optionapi:SetValue(v, true)
			end)
			ind += 1
		end
	else
		optionapi:SetValue(optionapi.Value, true)
	end
end)
dropdown.MouseEnter:Connect(function()
	tween:Tween(bkg, uipallet.Tween, {
		BackgroundColor3 = color.Light(uipallet.Main, 0.0875)
	})
end)
dropdown.MouseLeave:Connect(function()
	tween:Tween(bkg, uipallet.Tween, {
		BackgroundColor3 = color.Light(uipallet.Main, 0.034)
	})
end)

optionapi.Object = dropdown
api.Options[optionsettings.Name] = optionapi

return optionapi