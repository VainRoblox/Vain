local AutoBank
local UIToggle
local GuiCheck
local Range
local Delay
local UpdateRate
local Toggles = {}
local UI
local Chests
local Items = {}
local banking = false

-- The app the game opens when you actually click a chest.
local CHEST_APP = 'ChestApp'

-- How close the game itself lets you open a chest from: the MaxActivationDistance on the
-- prompt it puts on every chest block. The default, since reaching further than the
-- prompt does is not something the server has any reason to honour.
local CHEST_RANGE = 7.5

-- What the on screen list shows, top to bottom, and what can be banked. Kept as a list
-- rather than a set so the icons always come out in the same order.
local RESOURCES = {
	{Type = 'iron', Name = 'Iron'},
	{Type = 'gold', Name = 'Gold'},
	{Type = 'diamond', Name = 'Diamond'},
	{Type = 'emerald', Name = 'Emerald'},
	{Type = 'void_crystal', Name = 'Void Crystal'}
}

local function personalChest()
	local inventories = replicatedStorage:FindFirstChild('Inventories')
	return inventories and inventories:FindFirstChild(lplr.Name..'_personal')
end

--[[
	The chest the server currently thinks you have open.

	This is the whole reason banking never worked. Both transfer remotes take this folder,
	not the one you can look up by name in ReplicatedStorage, and the server only fills it
	in once it has been told which chest you are at. Handing it the folder found by name
	meant every deposit was made against a chest the server had no record of you opening.
]]
local function observedChest()
	local char = lplr.Character
	local observed = char and char:FindFirstChild('ObservedChestFolder')
	return observed, observed and observed.Value
end

local function chestApp()
	local ok, open = pcall(function()
		return bedwars.AppController:isAppOpen(CHEST_APP)
	end)
	return ok and open or false
end

local function nearestChest()
	if not entitylib.isAlive then return nil end

	local pos = entitylib.character.RootPart.Position
	local closest, mag = nil, Range and Range.Value or CHEST_RANGE
	for _, chest in Chests do
		local dist = (chest.Position - pos).Magnitude
		if dist <= mag then
			closest, mag = chest, dist
		end
	end
	return closest
end

--[[
	Tells the server which chest you are at, which is exactly what opening one does.

	Left alone entirely while GUI Check is on: the game has already sent this itself, and
	sending it again would only risk clearing what it set.
]]
local function observe(folder)
	local observed, current = observedChest()
	if not observed then return false end
	if current == folder then return true end
	if GuiCheck and GuiCheck.Enabled then return false end

	pcall(function()
		bedwars.Client:GetNamespace('Inventory'):Get('SetObservedChest'):SendToServer(folder)
	end)

	-- The server answers by writing the folder back, so wait for that rather than
	-- assuming it took - a deposit sent before it lands is refused.
	for _ = 1, 20 do
		if observed.Value == folder then return true end
		task.wait()
	end
	return false
end

local function addItem(itemType)
	local item = Instance.new('ImageLabel')
	item.Image = bedwars.getIcon({itemType = itemType}, true)
	item.Size = UDim2.fromOffset(32, 32)
	item.Name = itemType
	item.BackgroundTransparency = 1
	item.LayoutOrder = #UI:GetChildren()
	item.Parent = UI
	local itemtext = Instance.new('TextLabel')
	itemtext.Name = 'Amount'
	itemtext.Size = UDim2.fromScale(1, 1)
	itemtext.BackgroundTransparency = 1
	itemtext.Text = ''
	itemtext.TextColor3 = Color3.new(1, 1, 1)
	itemtext.TextSize = 16
	itemtext.TextStrokeTransparency = 0.3
	itemtext.Font = Enum.Font.Arial
	itemtext.Parent = item
	Items[itemType] = itemtext
end

--[[
	Draws what is actually in the chest.

	Refreshed every pass off the chest folder itself, rather than only after a transfer
	went through. That is why the display sat empty: the old one was only ever reached
	from inside the depositing branch, so unless something had just been moved there was
	nothing to draw, and standing away from the chest showed nothing at all.

	The contents replicate whether or not you are near it, so there is no reason to only
	show them when you are.
]]
local function refreshBank()
	local chest = personalChest()
	for itemType, label in Items do
		local entry = chest and chest:FindFirstChild(itemType)
		local amount = entry and entry:GetAttribute('Amount')
		label.Text = amount and tostring(amount) or ''
	end
end

local function bank()
	if not nearestChest() then return end
	if GuiCheck and GuiCheck.Enabled and not chestApp() then return end

	local folder = personalChest()
	if not folder or not observe(folder) then return end

	-- Worked out up front, because the transfer below waits on the server and the
	-- inventory is rebuilt underneath it every time one lands.
	local sending = {}
	for _, item in store.inventory.inventory.items do
		local toggle = Toggles[item.itemType]
		if toggle and toggle.Enabled and item.tool then
			table.insert(sending, item.tool)
		end
	end

	for i, tool in sending do
		if not AutoBank.Enabled then return end

		-- The first goes in the moment you are in reach; the delay sits between them, so
		-- a full inventory is not emptied into the chest in a single frame.
		if i > 1 and Delay and Delay.Value > 0 then
			task.wait(Delay.Value)
			-- Walking off mid way through stops the rest, rather than carrying on posting
			-- items to a chest you are no longer standing at.
			if not nearestChest() then return end
			if GuiCheck and GuiCheck.Enabled and not chestApp() then return end
		end

		-- One at a time and waited on. The old version spawned a call per item on every
		-- pass without ever waiting for one, so a full inventory fired the same transfers
		-- over and over a tenth of a second apart.
		pcall(function()
			bedwars.Client:GetNamespace('Inventory'):Get('ChestGiveItem'):CallServer(folder, tool)
		end)
	end
end

AutoBank = vain.Categories.Inventory:CreateModule({
	Name = 'AutoBank',
	Function = function(callback)
		if callback then
			Chests = collection('personal-chest', AutoBank)
			UI = Instance.new('Frame')
			UI.Size = UDim2.new(1, 0, 0, 32)
			UI.Position = UDim2.fromOffset(0, -240)
			UI.BackgroundTransparency = 1
			UI.Visible = not UIToggle or UIToggle.Enabled
			UI.Parent = vain.gui
			AutoBank:Clean(UI)
			local Sort = Instance.new('UIListLayout')
			Sort.FillDirection = Enum.FillDirection.Horizontal
			Sort.HorizontalAlignment = Enum.HorizontalAlignment.Center
			Sort.SortOrder = Enum.SortOrder.LayoutOrder
			Sort.Parent = UI

			table.clear(Items)
			for _, resource in RESOURCES do
				addItem(resource.Type)
			end

			repeat
				local hotbar = lplr.PlayerGui:FindFirstChild('hotbar')
				hotbar = hotbar and hotbar['1']:FindFirstChild('HotbarHealthbarContainer')
				if hotbar then
					UI.Position = UDim2.fromOffset(0, (hotbar.AbsolutePosition.Y + guiService:GetGuiInset().Y) - 40)
				end

				if not UIToggle or UIToggle.Enabled then
					pcall(refreshBank)
				end

				-- Guarded so a pass that is still waiting on the server cannot be started
				-- a second time underneath itself.
				if not banking then
					banking = true
					pcall(bank)
					banking = false
				end

				-- A saved config can switch this on while the file is still running, so the
				-- sliders are not guaranteed to exist on the first pass.
				task.wait(UpdateRate and (1 / UpdateRate.Value) or 0.25)
			until not AutoBank.Enabled
		else
			banking = false
			table.clear(Items)
		end
	end,
	Tooltip = 'Puts resources into your personal chest'
})
UIToggle = AutoBank:CreateToggle({
	Name = 'UI',
	Tooltip = 'Shows your chest contents on screen',
	Function = function(callback)
		if AutoBank.Enabled and UI then
			UI.Visible = callback
		end
	end,
	Default = true
})
GuiCheck = AutoBank:CreateToggle({
	Name = 'GUI Check',
	Tooltip = 'Only banks while the chest is open'
})
Range = AutoBank:CreateSlider({
	Name = 'Range',
	Tooltip = 'How close to the chest you must be\nGame default is 7.5',
	Min = 1,
	Max = 20,
	Default = CHEST_RANGE,
	Decimal = 10,
	Suffix = 'studs'
})
Delay = AutoBank:CreateSlider({
	Name = 'Delay',
	Tooltip = 'Wait between each item going in',
	Min = 0,
	Max = 3,
	Default = 0.25,
	Decimal = 100,
	Suffix = 'seconds'
})
UpdateRate = AutoBank:CreateSlider({
	Name = 'Update Rate',
	Tooltip = 'How often it banks\nLower costs less performance',
	Min = 1,
	Max = 20,
	Default = 4,
	Suffix = 'hz'
})
for _, resource in RESOURCES do
	Toggles[resource.Type] = AutoBank:CreateToggle({
		Name = resource.Name,
		Tooltip = 'Banks '..resource.Name:lower(),
		Default = true,
		Darker = true
	})
end
