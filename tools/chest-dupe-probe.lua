--[[
	Bedwars - chest conservation probe.

	Answers one question: can a chest transfer end with more of an item in existence than
	it started with? Dupes are counting bugs, so this counts. It sums an item type across
	your inventory and your personal chest, fires a batch of transfers, waits for the
	count to stop moving, and sums again. Conserved means the total did not change.

	What it is actually testing is a race. The give and get remotes resolve the item by
	instance reference, and if the server checks "is this item here" and then moves it
	without holding anything across the two steps, several calls can pass the same check
	before the first one lands. So the calls go out together rather than one at a time -
	that is the whole difference between this and chest-roundtrip.lua.

	    Mode = 'get'   stack goes into the chest, then N gets fire at the same entry
	    Mode = 'give'  N gives fire at the same inventory tool
	    Mode = 'both'  one give and one get at once, so ownership is ambiguous mid-transfer
	                   (needs some of the item in BOTH places before you start)

	Read the calibration line before believing anything else. It is a plain sequential
	round trip, one call at a time, each awaited - a total that fails to balance there is
	a measurement problem and every number under it is noise. Amounts replicate a frame or
	two behind the transfer, which is exactly how a probe like this invents a dupe that is
	not there, so a trial is only recorded once the sum has held still for Settle seconds.

	A delta of zero across every trial is the expected result and the useful one: it says
	this particular race is handled. A negative delta is worth as much as a positive one -
	that is the server voiding items, which is a bug in the other direction.

	Not automated, and worth doing by hand: dying with a transfer in flight. Death drops
	your inventory while the chest folder lives on independently, and a character replaced
	mid-move is the other classic place for a count to go wrong.

	Settings, changeable live:
	    DupeProbe.Item        = 'iron'
	    DupeProbe.Mode        = 'get'   -- 'get' | 'give' | 'both'
	    DupeProbe.Concurrency = 4       -- calls fired together per trial
	    DupeProbe.Trials      = 5
	    DupeProbe.Range       = 7.5
	    DupeProbe.Settle      = 0.75    -- the sum must hold still this long to count
	    DupeProbe.Timeout     = 4
	    DupeProbe.Run()                 -- run the suite again
]]

local CollectionService = game:GetService('CollectionService')
local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local lplr = Players.LocalPlayer

local cfg = getgenv().DupeProbe or {}
cfg.Item = cfg.Item or 'iron'
cfg.Mode = cfg.Mode or 'get'
cfg.Concurrency = cfg.Concurrency or 4
cfg.Trials = cfg.Trials or 5
cfg.Range = cfg.Range or 7.5
cfg.Settle = cfg.Settle or 0.75
cfg.Timeout = cfg.Timeout or 4
getgenv().DupeProbe = cfg

local running = false

local function say(fmt, ...)
	print(string.format('[probe] '..fmt, ...))
end

local function resolve()
	local okRemotes, remotes = pcall(function()
		return require(ReplicatedStorage.TS.remotes).default.Client:GetNamespace('Inventory')
	end)
	if not okRemotes or not remotes then
		say('cannot reach the Inventory remotes: %s', tostring(remotes))
		return nil
	end

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

--[[
	How much of an item type you are holding, and one tool instance for it.

	Summed across entries rather than taken from the first match. One entry per resource
	with an amount on it is the normal shape, but a count that silently ignored a second
	entry would read as items vanishing the moment the inventory split one.
]]
local function heldAmount(store, itemType)
	local total, tool = 0, nil
	for _, item in inventoryItems(store) do
		if item.itemType == itemType then
			total += item.amount or 1
			tool = tool or item.tool
		end
	end
	return total, tool
end

-- Chest entries are named by item type with the count on an Amount attribute. An item
-- that does not stack carries no attribute, so a missing one is a single item.
local function chestAmount(folder, itemType)
	local entry = folder:FindFirstChild(itemType)
	if not entry then
		return 0, nil
	end
	return entry:GetAttribute('Amount') or 1, entry
end

local function sum(store, folder, itemType)
	local held = heldAmount(store, itemType)
	local stored = chestAmount(folder, itemType)
	return held + stored, held, stored
end

--[[
	The total once it has stopped moving.

	Both sides replicate a frame or two behind the transfer and they do not have to land
	together, so a sum taken too early catches the item in neither place and reports a
	loss, or in both and reports a dupe. Waiting for the number to hold still is what makes
	a nonzero delta worth looking at.
]]
local function settled(store, folder, itemType)
	local deadline = tick() + cfg.Timeout
	local last, since = sum(store, folder, itemType), tick()
	repeat
		task.wait()
		local total = sum(store, folder, itemType)
		if total ~= last then
			last, since = total, tick()
		end
	until (tick() - since) >= cfg.Settle or tick() > deadline

	local total, held, stored = sum(store, folder, itemType)
	return total, held, stored, (tick() - since) < cfg.Settle
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

local function chestInRange()
	local part = root()
	if not part then
		say('no character')
		return false
	end
	local pos = part.Position
	for _, block in CollectionService:GetTagged('personal-chest') do
		if block:IsA('BasePart') and (block.Position - pos).Magnitude <= cfg.Range then
			return true
		end
	end
	say('no personal chest within %.1f studs - stand at yours', cfg.Range)
	return false
end

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

	-- Two seconds rather than twenty frames. The short wait failed on the first attempt of
	-- a session and worked on the retry, which is a wait that is too short, not a server
	-- that refused.
	local deadline = tick() + 2
	repeat
		if observed.Value == folder then
			return true
		end
		task.wait()
	until tick() > deadline
	say('the server would not record the chest as open')
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

-- One call, awaited, reporting only whether the remote itself threw. A transfer the server
-- declines comes back as an ordinary return, so this says nothing about whether it worked -
-- the counts do.
local function call(remotes, name, folder, object)
	local ok, err = pcall(function()
		return remotes:Get(name):CallServer(folder, object)
	end)
	return ok, err
end

--[[
	Fires the same call several times at once and waits for all of them.

	Spawned rather than called in a loop: CallServer yields until the server answers, so a
	sequential loop is the thing this is trying not to be. Each one reports back so a
	server that rejects the extras can be told from one that accepts them.
]]
local function burst(remotes, name, folder, object, count)
	local done, failed = 0, 0
	for _ = 1, count do
		task.spawn(function()
			local ok = call(remotes, name, folder, object)
			if not ok then
				failed += 1
			end
			done += 1
		end)
	end

	local deadline = tick() + cfg.Timeout
	repeat
		task.wait()
	until done >= count or tick() > deadline

	return done, failed
end

--[[
	The sequential round trip, one call at a time.

	Run before the trials and its delta reported first. If a plain give-then-get does not
	balance, nothing the concurrent trials report means anything: the counting is wrong,
	not the server.
]]
local function calibrate(remotes, store, folder, itemType)
	local before = settled(store, folder, itemType)

	local held, tool = heldAmount(store, itemType)
	if held <= 0 or not tool then
		-- Worth being loud about: a skipped calibration means nothing below it has been
		-- checked against a transfer known to balance.
		say('calibration SKIPPED - you are not carrying %s, so nothing below is validated (take it out of the chest first)', itemType)
		return nil
	end

	call(remotes, 'ChestGiveItem', folder, tool)
	local _, _, stored = settled(store, folder, itemType)
	if stored <= 0 then
		say('calibration failed - the deposit never arrived, so the server is refusing transfers here')
		return false
	end

	local _, entry = chestAmount(folder, itemType)
	call(remotes, 'ChestGetItem', folder, entry)
	local after = settled(store, folder, itemType)

	local delta = after - before
	say('calibration: %d -> %d (delta %+d) %s', before, after, delta, delta == 0 and 'balanced' or 'NOT BALANCED - treat the trials below as noise')
	return delta == 0
end

local function trial(remotes, store, folder, itemType, index)
	local before, held, stored, unstable = settled(store, folder, itemType)
	if unstable then
		say('trial %d: the count never settled, skipping', index)
		return nil
	end

	local done, failed

	if cfg.Mode == 'both' then
		-- Both halves at once, so the item is leaving one place as something of the same
		-- type is arriving. Nothing is set up first: this mode is about the server holding
		-- two moves in flight, which needs some of the item in each place already.
		local _, tool = heldAmount(store, itemType)
		local _, entry = chestAmount(folder, itemType)
		if not tool or not entry then
			say('trial %d: this mode needs %s in your inventory AND in the chest to start', index, itemType)
			return nil
		end

		done, failed = 0, 0
		task.spawn(function()
			local ok = call(remotes, 'ChestGiveItem', folder, tool)
			done += 1
			failed += (ok and 0 or 1)
		end)
		local ok = call(remotes, 'ChestGetItem', folder, entry)
		done += 1
		failed += (ok and 0 or 1)

		local deadline = tick() + cfg.Timeout
		repeat
			task.wait()
		until done >= 2 or tick() > deadline
	elseif cfg.Mode == 'give' then
		local _, tool = heldAmount(store, itemType)
		if not tool then
			say('trial %d: nothing in your inventory to give', index)
			return nil
		end
		done, failed = burst(remotes, 'ChestGiveItem', folder, tool, cfg.Concurrency)
	else
		-- The stack goes in first, one call and awaited, so there is an entry for the
		-- burst to race on. A trial that starts with the chest already holding some skips
		-- straight to the race.
		if stored <= 0 then
			local _, tool = heldAmount(store, itemType)
			if not tool then
				say('trial %d: nothing to put in the chest', index)
				return nil
			end
			call(remotes, 'ChestGiveItem', folder, tool)
			settled(store, folder, itemType)
			stored = select(3, sum(store, folder, itemType))
			if stored <= 0 then
				say('trial %d: the deposit never arrived', index)
				return nil
			end
		end

		local _, entry = chestAmount(folder, itemType)
		if not entry then
			say('trial %d: no %s in the chest to take', index, itemType)
			return nil
		end
		done, failed = burst(remotes, 'ChestGetItem', folder, entry, cfg.Concurrency)
	end

	local after, afterHeld, afterStored = settled(store, folder, itemType)
	local delta = after - before
	say('trial %d: %d -> %d (delta %+d) | held %d->%d chest %d->%d | %d calls, %d threw',
		index, before, after, delta, held, afterHeld, stored, afterStored, done, failed)

	--[[
		Put the stack back where the next trial needs it.

		A give leaves everything in the chest, so without this the run measures one trial
		and then reports four refusals - which is what it did. Done after the delta is
		recorded, so this transfer is never part of what is being counted, and sequential
		because it is setup rather than part of the race.
	]]
	if cfg.Mode == 'give' and afterStored > 0 then
		local _, entry = chestAmount(folder, itemType)
		if entry then
			call(remotes, 'ChestGetItem', folder, entry)
			settled(store, folder, itemType)
		end
	end

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
	local remotes, store = resolve()
	if not remotes then
		running = false
		return
	end

	local folder = personalFolder()
	if not folder then
		say('your personal chest folder does not exist yet')
		running = false
		return
	end
	if not chestInRange() then
		running = false
		return
	end
	if not observe(remotes, folder) then
		running = false
		return
	end

	local _, held, stored = sum(store, folder, itemType)
	say('%s: holding %d, chest has %d | mode %s, %d calls x %d trials', itemType, held, stored, cfg.Mode, cfg.Concurrency, cfg.Trials)

	local balanced = calibrate(remotes, store, folder, itemType)
	if balanced == false then
		release(remotes, folder)
		running = false
		return
	end

	local worst, gained, ran = 0, 0, 0
	for i = 1, cfg.Trials do
		local delta = trial(remotes, store, folder, itemType, i)
		if not delta then
			-- A trial that cannot start will not start on the next pass either: the thing
			-- it needed is set up beforehand, not by the trial before it. Repeating the
			-- same refusal four more times only buries the reason.
			say('stopping - the setup for mode %s is not met', cfg.Mode)
			if cfg.Mode == 'both' then
				say('put some %s in the chest, then collect more from a generator so you hold some too, then run again', itemType)
			end
			break
		end
		ran += 1
		gained += delta
		if math.abs(delta) > math.abs(worst) then
			worst = delta
		end
	end

	release(remotes, folder)

	local final, finalHeld, finalStored = settled(store, folder, itemType)
	if ran == 0 then
		say('no trials ran')
	elseif gained == 0 and worst == 0 then
		say('conserved across %d trials - this race is handled', ran)
	elseif gained > 0 or worst > 0 then
		say('TOTAL ROSE: %+d over %d trials, worst single trial %+d', gained, ran, worst)
	else
		say('TOTAL FELL: %+d over %d trials, worst single trial %+d - items being voided, not duped', gained, ran, worst)
	end
	say('ending with %d (%d held, %d in chest)%s', final, finalHeld, finalStored, finalStored > 0 and ' - some is still in the chest' or '')

	running = false
end

cfg.Run = run

task.spawn(run)
