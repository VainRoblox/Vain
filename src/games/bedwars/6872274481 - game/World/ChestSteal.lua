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

local function personalFolder()
	local inventories = replicatedStorage:FindFirstChild('Inventories')
	return inventories and inventories:FindFirstChild(lplr.Name..'_personal')
end

--[[
	Your own chest, never looted whatever the settings say - it is AutoBank's, and taking
	back out what that just put in is never what anybody wants.

	Tested on the folder the items live in rather than on the block's name. The name was
	not enough: a personal chest is reached through an ordinary ChestFolderValue like any
	other chest, so from the outside it looks like nothing special, which is exactly how
	this was emptying the chest AutoBank had just filled.
]]
local function ownChest(folder)
	return folder ~= nil and folder == personalFolder()
end

--[[
	Your team's crate, which Skip Own covers.

	Found the way the game's own getTeamCrate finds it, by the Team attribute matching
	yours - an enemy crate belongs to another team and stays fair game.

	Compared as text and looked for up the parents, because the tag sits on a holder with
	the block underneath it and the id comes back as a string in some places and a number
	in others; a straight == between the two forms is quietly false.
]]
local function teamOf(inst)
	local team = inst:GetAttribute('Team')
	if team == nil then team = inst:GetAttribute('GeneratorTeam') end
	return team ~= nil and tostring(team) or nil
end

local function teamChest(block)
	local mine = lplr:GetAttribute('Team')
	if mine == nil or not block then return false end
	mine = tostring(mine)

	local node = block
	for _ = 1, 3 do
		if not node then break end
		if teamOf(node) == mine then return true end
		node = node.Parent
	end
	return false
end

-- Which chest block a folder belongs to, so a chest opened by hand can be judged the same
-- way as one walked up to.
local function blockFor(chests, folder)
	if not folder then return nil end
	for _, v in chests do
		local value = v:FindFirstChild('ChestFolderValue')
		if value and value.Value == folder then return v end
	end
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
									local folder = select(2, observedValue())
									-- Judged the same as any other chest, so opening your own
									-- by hand is not a way round the checks below.
									if not ownChest(folder)
										and not (SkipOwn.Enabled and teamChest(blockFor(chests, folder))) then
										lootChest(folder)
									end
								end
							else
								for _, v in chests do
									if not ChestSteal.Enabled then break end

									local value = v:FindFirstChild('ChestFolderValue')
									local folder = value and value.Value
									if folder and inRange(v)
										and not ownChest(folder)
										and not (SkipOwn.Enabled and teamChest(v)) then
										lootChest(folder, v)
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
	Tooltip = 'Leaves your team chest alone',
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
