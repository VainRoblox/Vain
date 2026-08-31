local ChestSteal
local Range
local Delay
local UpdateRate
local Open
local SkipOwn
local Skywars
local Delays = {}
local looting = false

-- How close the game itself lets you open a chest from: the MaxActivationDistance on the
-- prompt it puts on every chest block.
local CHEST_RANGE = 7.5
local CHEST_APP = 'ChestApp'

-- How long to leave a chest alone after working through it, so one that will not give
-- anything up is not retried on every pass.
local RETRY = 1

local OWN = {personal_chest = true, og_personal_chest = true}

--[[
	Your own chest and your team's crate.

	Your personal one is AutoBank's job, so looting it would only hand the same items back
	and forth between the two modules. The team crate is found the way the game finds it,
	by the Team attribute on the block matching your own - which is also why an enemy
	crate, being another team's, is still fair game.
]]
local function ownChest(block)
	if OWN[block.Name] then return true end

	local team = lplr:GetAttribute('Team')
	return team ~= nil and block:GetAttribute('Team') == team
end

local function chestApp()
	local ok, open = pcall(function()
		return bedwars.AppController:isAppOpen(CHEST_APP)
	end)
	return ok and open or false
end

local function observedValue()
	local char = lplr.Character
	local observed = char and char:FindFirstChild('ObservedChestFolder')
	return observed, observed and observed.Value
end

--[[
	Tells the server which chest is being looted, and waits for it to agree.

	Both of these were wrong before. The transfers went out in the same breath as the
	message announcing the chest, so they could reach the server before it had recorded
	which chest was open, and the message clearing it again was sent immediately after -
	before a single transfer had come back. With GUI Check on that clear was worse still,
	because the chest it cleared was the one you had open by hand.
]]
local function observe(folder)
	local observed, current = observedValue()
	if not observed then return false end
	if current == folder then return true end
	-- With GUI Check on the game has already sent this itself, so nothing is sent here.
	if Open.Enabled then return false end

	pcall(function()
		bedwars.Client:GetNamespace('Inventory'):Get('SetObservedChest'):SendToServer(folder)
	end)

	for _ = 1, 20 do
		if observed.Value == folder then return true end
		task.wait()
	end
	return false
end

local function release(folder)
	-- Only ever let go of a chest this module took hold of. One you opened yourself stays
	-- open.
	if Open.Enabled then return end
	local _, current = observedValue()
	if current ~= folder then return end

	pcall(function()
		bedwars.Client:GetNamespace('Inventory'):Get('SetObservedChest'):SendToServer(nil)
	end)
end

local function inRange(block)
	if not entitylib.isAlive then return false end
	return (entitylib.character.RootPart.Position - block.Position).Magnitude <= Range.Value
end

local function lootChest(folder, block)
	if not folder then return end
	if Delays[folder] and Delays[folder] > tick() then return end

	local taking = {}
	for _, v in folder:GetChildren() do
		if v:IsA('Accessory') then
			table.insert(taking, v)
		end
	end
	if #taking == 0 then return end

	Delays[folder] = tick() + RETRY
	if not observe(folder) then return end

	for _, item in taking do
		if not ChestSteal.Enabled then break end

		-- Waited before every item, the first one included, so a chest is not emptied in
		-- a single frame.
		if Delay.Value > 0 then
			task.wait(Delay.Value)
			-- Walking off, or closing the chest, stops the rest.
			if block and not inRange(block) then break end
			if Open.Enabled and not chestApp() then break end
		end

		-- Sent one at a time and waited on. Firing them all off at once meant none of
		-- them had answered by the time the chest was handed back.
		pcall(function()
			bedwars.Client:GetNamespace('Inventory'):Get('ChestGetItem'):CallServer(folder, item)
		end)
	end

	release(folder)
end

ChestSteal = vain.Categories.World:CreateModule({
	Name = 'ChestSteal',
	Function = function(callback)
		if callback then
			local chests = collection('chest', ChestSteal)
			table.clear(Delays)
			repeat task.wait() until store.queueType ~= 'bedwars_test'
			if (not Skywars.Enabled) or store.queueType:find('skywars') then
				repeat
					if entitylib.isAlive and store.matchState ~= 2 and not looting then
						looting = true
						pcall(function()
							if Open.Enabled then
								if chestApp() then
									lootChest(select(2, observedValue()))
								end
							else
								for _, v in chests do
									if not ChestSteal.Enabled then break end
									if not (SkipOwn.Enabled and ownChest(v)) and inRange(v) then
										local folder = v:FindFirstChild('ChestFolderValue')
										lootChest(folder and folder.Value, v)
									end
								end
							end
						end)
						looting = false
					end

					-- A saved config can switch this on while the file is still running, so
					-- the slider is not guaranteed to exist on the first pass.
					task.wait(UpdateRate and (1 / UpdateRate.Value) or 0.25)
				until not ChestSteal.Enabled
			end
		else
			looting = false
			table.clear(Delays)
		end
	end,
	Tooltip = 'Takes items out of nearby chests'
})
Range = ChestSteal:CreateSlider({
	Name = 'Range',
	Tooltip = 'How far this reaches\nGame default is 7.5',
	Min = 1,
	Max = 20,
	Default = CHEST_RANGE,
	Decimal = 10,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
Delay = ChestSteal:CreateSlider({
	Name = 'Delay',
	Tooltip = 'Wait between each item taken\nDefault is 0.25',
	Min = 0,
	Max = 3,
	Default = 0.25,
	Decimal = 100,
	Suffix = 'seconds'
})
UpdateRate = ChestSteal:CreateSlider({
	Name = 'Update Rate',
	Tooltip = 'How often it checks for chests\nDefault is 4hz',
	Min = 1,
	Max = 20,
	Default = 4,
	Suffix = 'hz'
})
Open = ChestSteal:CreateToggle({
	Name = 'GUI Check',
	Tooltip = 'Only takes while a chest is open'
})
SkipOwn = ChestSteal:CreateToggle({
	Name = 'Skip Own',
	Tooltip = 'Leaves your own and your team chest alone',
	Default = true
})
Skywars = ChestSteal:CreateToggle({
	Name = 'Only Skywars',
	Tooltip = 'Only runs while in a skywars queue',
	Function = function()
		if ChestSteal.Enabled then
			ChestSteal:Toggle()
			ChestSteal:Toggle()
		end
	end,
	Default = true
})
