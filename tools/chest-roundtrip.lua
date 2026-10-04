--[[
	Bedwars - chest round trip.

	Sends one item from your inventory into a chest and takes it straight back out, once,
	then reports what each half of the trip did. Standalone: run it with your executor in
	a Bedwars match, no Vain loaded.

	This is the mechanism the chesting modules are built on, pulled out on its own so it
	can be watched. Every step prints, which is the point - a transfer that is refused and
	a transfer that was never sent look identical from in game, and the two remotes here
	are silent about both.

	The one thing that is not obvious: both transfers are honoured only against the chest
	the server has recorded you as having open, which is the ObservedChestFolder ObjectValue
	on your character - not the folder you can look up by name in ReplicatedStorage. That is
	announced here and waited on before anything is sent, and handed back afterwards unless
	you had the chest open by hand.

	Settings, changeable live:
	    ChestTrip.Item    = '*'         -- item type to send, or '*' for the first one you have
	    ChestTrip.Chest   = 'Personal'  -- 'Personal' for your own chest, 'Any' for the nearest
	    ChestTrip.Range   = 7.5         -- how close the chest has to be; the game's own limit
	    ChestTrip.Pause   = 0           -- seconds to hold the item in the chest
	    ChestTrip.Timeout = 2           -- how long to wait on the server for each half
	    ChestTrip.Run('iron')           -- another trip; the argument is optional
]]

local CollectionService = game:GetService('CollectionService')
local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local lplr = Players.LocalPlayer

local cfg = getgenv().ChestTrip or {}
cfg.Item = cfg.Item or '*'
cfg.Chest = cfg.Chest or 'Personal'
cfg.Range = cfg.Range or 7.5
cfg.Pause = cfg.Pause or 0
cfg.Timeout = cfg.Timeout or 2
getgenv().ChestTrip = cfg

local running = false

local function say(fmt, ...)
	print(string.format('[chest] '..fmt, ...))
end

--[[
	The two game internals this needs, each resolved on its own.

	Separately pcall'd and reported by name because these are the paths that move between
	updates, and a round trip that fails here has not touched the game at all - worth
	telling apart from one the server turned down.
]]
local function resolve()
	local okRemotes, remotes = pcall(function()
		return require(ReplicatedStorage.TS.remotes).default.Client:GetNamespace('Inventory')
	end)
	if not okRemotes or not remotes then
		say('cannot reach the Inventory remotes: %s', tostring(remotes))
		return nil
	end

	-- Where the tool instances live. The remotes want the instance the store is holding,
	-- which is why the inventory is read from here rather than off the character's
	-- InventoryFolder: that folder's children are named by item type and carry the amount,
	-- but nothing says they are the same objects.
	local okStore, store = pcall(function()
		return require(lplr.PlayerScripts.TS.ui.store).ClientStore
	end)
	if not okStore or not store then
		say('cannot reach the client store: %s', tostring(store))
		return nil
	end

	return remotes, store
end

local function inventoryItems(store)
	local ok, items = pcall(function()
		local state = store:getState()
		return state.Inventory.observedInventory.inventory.items
	end)
	return ok and items or {}
end

-- The entry carrying an item type, and the tool instance the remotes take.
local function findItem(store, wanted)
	for _, item in inventoryItems(store) do
		if item.tool and (wanted == '*' or item.itemType == wanted) then
			return item.tool, item.itemType, item.amount or 1
		end
	end
	return nil
end

local function root()
	local char = lplr.Character
	return char and char:FindFirstChild('HumanoidRootPart')
end

local function personalFolder()
	local inventories = ReplicatedStorage:FindFirstChild('Inventories')
	return inventories and inventories:FindFirstChild(lplr.Name..'_personal')
end

local function observedChest()
	local char = lplr.Character
	local observed = char and char:FindFirstChild('ObservedChestFolder')
	return observed, observed and observed.Value
end

--[[
	Which chest to use, and whether it was already open.

	A chest open by hand wins outright whatever the setting says: it is the one the server
	has on record, so it is the one transfers will be accepted against, and announcing
	another over the top of it would only clear what the game set.
]]
local function findChest()
	local _, current = observedChest()
	if current then
		return current, true
	end

	local part = root()
	if not part then
		say('no character')
		return nil
	end

	local pos = part.Position
	local range = cfg.Range

	if cfg.Chest == 'Personal' then
		-- One folder serves every personal chest on the map, so the blocks are only being
		-- searched for one within reach.
		local folder = personalFolder()
		if not folder then
			say('your personal chest folder does not exist yet')
			return nil
		end
		for _, block in CollectionService:GetTagged('personal-chest') do
			if block:IsA('BasePart') and (block.Position - pos).Magnitude <= range then
				return folder, false
			end
		end
		say('no personal chest within %.1f studs', range)
		return nil
	end

	local closest, mag = nil, range
	for _, block in CollectionService:GetTagged('chest') do
		if block:IsA('BasePart') then
			local dist = (block.Position - pos).Magnitude
			if dist <= mag then
				local value = block:FindFirstChild('ChestFolderValue')
				local folder = value and value.Value
				if folder then
					closest, mag = folder, dist
				end
			end
		end
	end
	if not closest then
		say('no chest within %.1f studs', range)
	end
	return closest, false
end

-- Tells the server which chest you are at, which is exactly what opening one does, and
-- waits for it to write the folder back rather than assuming it took - a transfer sent
-- before that lands is refused.
local function observe(remotes, folder)
	local observed, current = observedChest()
	if not observed then
		say('no ObservedChestFolder on your character')
		return false
	end
	if current == folder then
		return true
	end

	pcall(function()
		remotes:Get('SetObservedChest'):SendToServer(folder)
	end)

	for _ = 1, 20 do
		if observed.Value == folder then
			return true
		end
		task.wait()
	end
	return false
end

local function release(remotes, folder)
	local _, current = observedChest()
	if current ~= folder then
		return
	end

	pcall(function()
		remotes:Get('SetObservedChest'):SendToServer(nil)
	end)
end

--[[
	What a folder is holding of one item type.

	Both the child and its count, because a deposit does not have to show up as a new
	child: a chest already holding that item type stacks onto the entry that is there and
	only the Amount moves. Watching for a new instance alone is how a deposit into a chest
	you have used before reads as a deposit that never arrived.

	A missing Amount counts as one. Items that do not stack do not carry the attribute.
]]
local function entryOf(folder, itemType)
	local entry = folder:FindFirstChild(itemType)
	if not entry then
		return nil, 0
	end
	return entry, entry:GetAttribute('Amount') or 1
end

local function awaitDeposit(folder, itemType, startEntry, startAmount)
	local deadline = tick() + cfg.Timeout
	repeat
		local entry, amount = entryOf(folder, itemType)
		if entry and (entry ~= startEntry or amount > startAmount) then
			return entry, amount
		end
		task.wait()
	until tick() > deadline
	return nil
end

-- The item back in your hands. Matched on the tool being a different instance to the one
-- that was sent, since the entry that went in is gone and the server does not have to
-- hand the same object back.
local function awaitReturn(store, itemType, sent)
	local deadline = tick() + cfg.Timeout
	repeat
		for _, item in inventoryItems(store) do
			if item.itemType == itemType and item.tool and item.tool ~= sent then
				return item.amount or 1
			end
		end
		task.wait()
	until tick() > deadline
	return nil
end

--[[
	Which queue you are in, and whether it is one where any of this means anything.

	The personal chest does not persist outside a match. In the training room the server
	takes the deposit, answers true and stores nothing, while your own client reparents the
	item locally for responsiveness and replication puts it back one round trip later - a
	bounce that looks exactly like a server that moved the item and changed its mind.
	Hours went into that distinction, so every tool here says where it is running.
]]
local function queueCheck()
	local ok, game_ = pcall(function()
		return require(lplr.PlayerScripts.TS.ui.store).ClientStore:getState().Game
	end)
	if not ok or not game_ then
		say('queue: could not read it')
		return true
	end

	local queue = game_.queueType or 'unknown'
	say('queue: %s (match state %s)', tostring(queue), tostring(game_.matchState))
	if queue == 'training_room' or queue == 'bedwars_test' or queue:find('lobby') then
		say('WARNING: chest transfers do not persist in %s - run this in a real match or every result is the refusal path', queue)
		return false
	end
	return true
end

local function roundTrip(wanted)
	if running then
		say('already running')
		return false
	end
	running = true
	queueCheck()

	local remotes, store = resolve()
	if not remotes then
		running = false
		return false
	end

	wanted = wanted or cfg.Item
	local tool, itemType, held = findItem(store, wanted)
	if not tool then
		say(wanted == '*' and 'your inventory is empty' or 'you are not carrying %s', wanted)
		running = false
		return false
	end

	local folder, wasOpen = findChest()
	if not folder then
		running = false
		return false
	end

	say('chest %s (%s), sending %s x%s', folder.Name, wasOpen and 'already open' or 'in range', itemType, tostring(held))

	if not observe(remotes, folder) then
		say('the server would not record the chest as open, nothing sent')
		running = false
		return false
	end

	local startEntry, startAmount = entryOf(folder, itemType)
	if startEntry then
		say('chest already holds %s x%d, watching the count', itemType, startAmount)
	end

	local started = tick()
	local okGive, giveErr = pcall(function()
		return remotes:Get('ChestGiveItem'):CallServer(folder, tool)
	end)
	if not okGive then
		say('ChestGiveItem threw: %s', tostring(giveErr))
	end

	local entry, amount = awaitDeposit(folder, itemType, startEntry, startAmount)
	if not entry then
		say('nothing reached the chest in %.1fs - the server refused the deposit', cfg.Timeout)
		-- Let go of it first: a chest left announced keeps the game's own transfers
		-- pointed at it.
		if not wasOpen then
			release(remotes, folder)
		end
		running = false
		return false
	end
	say('in the chest after %.2fs, now x%d', tick() - started, amount)

	if cfg.Pause > 0 then
		task.wait(cfg.Pause)
	end

	started = tick()
	local okGet, getErr = pcall(function()
		return remotes:Get('ChestGetItem'):CallServer(folder, entry)
	end)
	if not okGet then
		say('ChestGetItem threw: %s', tostring(getErr))
	end

	local back = awaitReturn(store, itemType, tool)
	if not wasOpen then
		release(remotes, folder)
	end

	if not back then
		-- Said plainly rather than reported as a finished trip: the item is sitting in the
		-- chest, and walking off now leaves it there.
		say('it did not come back in %.1fs - %s is still in the chest', cfg.Timeout, itemType)
		running = false
		return false
	end

	say('back after %.2fs, holding x%s - round trip done', tick() - started, tostring(back))
	running = false
	return true
end

cfg.Run = roundTrip

task.spawn(roundTrip, cfg.Item)
