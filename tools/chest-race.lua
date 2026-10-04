--[[
	Bedwars - chest bounce race.

	The personal chest takes a deposit and gives it straight back. Watched frame by frame,
	one ChestGiveItem produces this:

	    items: - iron        the item leaves your inventory
	    chest: + iron        it arrives in the chest
	    chest: - iron        it is taken back out
	    items: + iron        and rebuilt in your inventory, as a new instance

	All of it inside a second, without anything being asked for. That is the whole reason
	the earlier probe read 'the deposit never arrived': it waited for the count to hold
	still before measuring, and by then the bounce had already put everything back.

	So the question is what happens if the item is claimed while it is in the chest. The
	deposit is a real move the server performed, and the bounce is a second move undoing
	it. If a ChestGetItem lands between the two, the item is being handed back twice - once
	to the taker and once by the revert - and only one of those should count.

	Timing is the whole experiment, which is why nothing here polls. The get is fired from
	the ChildAdded that announces the arrival, so it goes out on the frame the item appears
	rather than after a wait that has already missed it. Pass 1 only measures: it times the
	window from arrival to bounce without touching it, so the trials afterwards can be read
	against how many frames there actually were.

	Counts come off the Accessory attributes rather than the store, since those are the
	instances being moved and the store is a frame or two behind them.

	A delta of zero is the expected result. Before reading anything into a positive one,
	check the window line: a bounce measured at under a frame means the get almost certainly
	landed after it, and whatever moved did so for some other reason.

	Settings:
	    ChestRace.Item   = 'iron'
	    ChestRace.Grabs  = 2      -- gets fired the moment the item lands
	    ChestRace.Trials = 5
	    ChestRace.Run()
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local lplr = Players.LocalPlayer

local cfg = getgenv().ChestRace or {}
cfg.Item = cfg.Item or 'iron'
cfg.Grabs = cfg.Grabs or 2
cfg.Trials = cfg.Trials or 5
cfg.Settle = cfg.Settle or 1
getgenv().ChestRace = cfg

local running = false

local function say(fmt, ...)
	print(string.format('[race] '..fmt, ...))
end

local function remotes()
	local ok, inv = pcall(function()
		return require(ReplicatedStorage.TS.remotes).default.Client:GetNamespace('Inventory')
	end)
	return ok and inv or nil
end

local function personalFolder()
	local inventories = ReplicatedStorage:FindFirstChild('Inventories')
	return inventories and inventories:FindFirstChild(lplr.Name..'_personal')
end

local function itemsFolder()
	local char = lplr.Character
	local value = char and char:FindFirstChild('InventoryFolder')
	return value and value.Value
end

-- The count off the instance itself. An item that does not stack carries no Amount, so a
-- missing attribute is a single item.
local function amountIn(folder, itemType)
	if not folder then
		return 0, nil
	end
	local entry = folder:FindFirstChild(itemType)
	if not entry then
		return 0, nil
	end
	return entry:GetAttribute('Amount') or 1, entry
end

local function total(itemType)
	local held = amountIn(itemsFolder(), itemType)
	local stored = amountIn(personalFolder(), itemType)
	return held + stored, held, stored
end

local function observe(inv, folder)
	local char = lplr.Character
	local observed = char and char:FindFirstChild('ObservedChestFolder')
	if not observed then
		say('no ObservedChestFolder on your character')
		return false
	end
	if observed.Value == folder then
		return true
	end

	pcall(function()
		inv:Get('SetObservedChest'):SendToServer(folder)
	end)
	for _ = 1, 20 do
		if observed.Value == folder then
			return true
		end
		task.wait()
	end
	say('the server would not record the chest as open')
	return false
end

--[[
	One deposit, timed and not interfered with.

	Measures arrival to bounce so the trials have something to be read against. A window
	that never closes is worth knowing about too: it means this deposit stuck, and the
	bounce is conditional on something that was different this time.
]]
local function measure(inv, chest, items, itemType)
	local arrived, left = nil, nil
	local bin = {}

	table.insert(bin, chest.ChildAdded:Connect(function(child)
		if child.Name == itemType and not arrived then
			arrived = tick()
		end
	end))
	table.insert(bin, chest.ChildRemoved:Connect(function(child)
		if child.Name == itemType and arrived and not left then
			left = tick()
		end
	end))

	local _, tool = amountIn(items, itemType)
	if not tool then
		say('no %s to send', itemType)
		for _, c in bin do c:Disconnect() end
		return nil
	end

	pcall(function()
		return inv:Get('ChestGiveItem'):CallServer(chest, tool)
	end)

	local deadline = tick() + cfg.Settle * 2
	repeat
		task.wait()
	until (arrived and left) or tick() > deadline
	for _, c in bin do
		c:Disconnect()
	end

	if not arrived then
		say('window: the item never reached the chest at all')
		return nil
	end
	if not left then
		say('window: it arrived and STAYED - no bounce this time')
		return math.huge
	end

	--[[
		The window against your ping, which is what decides whether any of this was real.

		A deposit the server performed and then reversed would be two server decisions, and
		the gap between them would be whatever the second one waits on. A gap that matches
		one round trip instead means the arrival was never the server's doing: the client
		put the item there itself for responsiveness, and the authoritative state coming
		back a round trip later took it away. Gets fired into that window are aimed at an
		instance the server does not believe is in the chest, which is a no-op dressed up
		as a race.
	]]
	local ping = select(2, pcall(function()
		return game:GetService('Stats').Network.ServerStatsItem['Data Ping']:GetValue()
	end))
	local window = left - arrived
	if type(ping) == 'number' then
		local ratio = window * 1000 / math.max(ping, 1)
		say('window: %.1f ms in the chest (%.1f frames at 60fps) | ping %.1f ms -> %.2fx', window * 1000, window * 60, ping, ratio)
		say(ratio < 1.5 and 'that is about one round trip: the arrival was most likely local prediction, not a move the server made' or 'that is longer than a round trip, so something server side is holding the item before it goes back')
	else
		say('window: %.1f ms in the chest (%.1f frames at 60fps) | ping unavailable', window * 1000, window * 60)
	end
	return window
end

--[[
	A deposit with gets fired from the arrival itself.

	Spawned out of the signal rather than called in it: CallServer yields, and a handler
	that yields holds up the rest of the signal's listeners - including, possibly, whatever
	performs the bounce. Waiting there would change the very timing being measured.
]]
local function trial(inv, chest, items, itemType, index)
	local before = total(itemType)
	local grabbed, fired = 0, 0
	local bin = {}

	table.insert(bin, chest.ChildAdded:Connect(function(child)
		if child.Name ~= itemType or fired > 0 then
			return
		end
		fired = cfg.Grabs
		for _ = 1, cfg.Grabs do
			task.spawn(function()
				pcall(function()
					return inv:Get('ChestGetItem'):CallServer(chest, child)
				end)
				grabbed += 1
			end)
		end
	end))

	local _, tool = amountIn(items, itemType)
	if not tool then
		say('trial %d: nothing to send', index)
		for _, c in bin do c:Disconnect() end
		return nil
	end

	pcall(function()
		return inv:Get('ChestGiveItem'):CallServer(chest, tool)
	end)

	local deadline = tick() + cfg.Settle * 3
	repeat
		task.wait()
	until (fired > 0 and grabbed >= fired) or tick() > deadline

	-- Left to settle before counting, because the bounce and the gets land at different
	-- times and a sum taken between them belongs to neither.
	task.wait(cfg.Settle)
	for _, c in bin do
		c:Disconnect()
	end

	local after, held, stored = total(itemType)
	local delta = after - before
	say('trial %d: %d -> %d (delta %+d) | held %d, chest %d | %d gets fired, %d returned', index, before, after, delta, held, stored, fired, grabbed)
	return delta
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

local function run()
	if running then
		say('already running')
		return
	end
	running = true
	queueCheck()

	local itemType = cfg.Item
	local inv = remotes()
	local chest = personalFolder()
	local items = itemsFolder()
	if not inv or not chest or not items then
		say('missing something: remotes %s, chest %s, items %s', tostring(inv ~= nil), tostring(chest ~= nil), tostring(items ~= nil))
		running = false
		return
	end
	if not observe(inv, chest) then
		running = false
		return
	end

	local start, held, stored = total(itemType)
	say('%s: %d total (%d held, %d in chest) | %d grabs x %d trials', itemType, start, held, stored, cfg.Grabs, cfg.Trials)

	local window = measure(inv, chest, items, itemType)
	if not window then
		running = false
		return
	end
	task.wait(cfg.Settle)

	local sum, ran = 0, 0
	for i = 1, cfg.Trials do
		local delta = trial(inv, chest, items, itemType, i)
		if delta then
			ran += 1
			sum += delta
		end
		task.wait(cfg.Settle)
	end

	local final, finalHeld, finalStored = total(itemType)
	say('%d trials, net %+d | started %d, ended %d (%d held, %d in chest)', ran, sum, start, final, finalHeld, finalStored)
	if sum == 0 then
		say('conserved - the bounce and the get do not both count')
	elseif sum > 0 then
		say('TOTAL ROSE %+d - check the window line before believing it, then re-run to see if it repeats', sum)
	else
		say('TOTAL FELL %+d - items are being voided in the race', sum)
	end

	running = false
end

cfg.Run = run

task.spawn(run)
