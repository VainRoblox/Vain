--[[
	Bedwars - chest transfer diagnosis.

	For when the transfer is accepted and nothing moves. ChestGiveItem answering 'true'
	while the inventory, the chest folder and the item count all sit unchanged is what this
	is built to explain, and it rules out the three things that look identical from in game.

	    1. The tool instance is stale. What the store hands back as item.tool came out with
	       no parent, and an instance the server cannot resolve is an instance it can
	       report success on without moving anything. The character's InventoryFolder holds
	       the same items by name, so both are tried and the two instances compared.
	    2. The contents are not children. Alongside the transfer remotes the game ships
	       GetAccumulatedResourcesFromPersonalChest and ClearAccumulatedResourcesFrom-
	       PersonalChest, which is not the shape of a folder you put item instances into -
	       a personal chest that accumulates resources is likely counting them somewhere
	       other than as children. So the folder's own attributes are dumped too, and
	       anything that changes anywhere under it is logged as it happens.
	    3. The server is gating on the chest being open. ChestApp sits separately from the
	       ObservedChestFolder value, and the modules that work carry a 'GUI Check' option
	       that skips announcing the folder entirely - which reads like the hand-opened
	       path being the one that was known to work. This prints the app state; press F
	       and run it again to compare.

	Everything is watched rather than sampled twice, because a change that lands and is
	reverted a frame later does not show up in a before and after.

	Settings:
	    ChestDiag.Item = 'iron'
	    ChestDiag.Run()
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local lplr = Players.LocalPlayer

local cfg = getgenv().ChestDiag or {}
cfg.Item = cfg.Item or 'iron'
getgenv().ChestDiag = cfg

local function say(fmt, ...)
	print(string.format('[diag] '..fmt, ...))
end

-- Values come back as tables as often as not, so one level is unrolled rather than
-- printed as 'table: 0x...'. A declined transfer that answers with a reason is the whole
-- point of running this.
local function describe(value, depth)
	depth = depth or 0
	local kind = typeof(value)
	if kind ~= 'table' then
		return kind == 'Instance' and string.format('%s(%s)', value.ClassName, value.Name) or string.format('%s %s', kind, tostring(value))
	end
	if depth > 1 then
		return 'table{...}'
	end

	local parts = {}
	for k, v in value do
		table.insert(parts, string.format('%s = %s', tostring(k), describe(v, depth + 1)))
	end
	if #parts == 0 then
		return 'table{}'
	end
	return 'table{ '..table.concat(parts, ', ')..' }'
end

local function attributeList(inst)
	local attrs = {}
	for name, value in inst:GetAttributes() do
		table.insert(attrs, string.format('%s=%s', name, tostring(value)))
	end
	if #attrs == 0 then
		return 'no attributes'
	end
	return table.concat(attrs, ' ')
end

--[[
	The folder itself as well as its children.

	The counts do not have to live on children at all - the accumulated-resource remotes
	say the personal chest is tallied rather than filled - and a reader that only walks
	GetChildren reports an empty chest either way.
]]
local function dumpFolder(folder, label)
	local children = folder:GetChildren()
	say('%s: %s (%s) has %d children | own attributes: %s', label, folder.Name, folder.ClassName, #children, attributeList(folder))
	for _, child in children do
		local value = child:IsA('ValueBase') and (' value='..tostring((child :: any).Value)) or ''
		say('    %s "%s" [%s]%s', child.ClassName, child.Name, attributeList(child), value)
	end
end

-- The same items, reached the way the game's own UI reaches them: an ObjectValue on the
-- character pointing at a folder whose children are named by item type.
local function inventoryFolder()
	local char = lplr.Character
	local value = char and char:FindFirstChild('InventoryFolder')
	return value and value.Value
end

--[[
	Logs anything that moves, rather than comparing two snapshots.

	A transfer the server applies and rolls back lands between samples and leaves no trace
	in a before and after, which is indistinguishable from one that never happened.
]]
local function watch(folder, label, bin)
	table.insert(bin, folder.ChildAdded:Connect(function(child)
		say('WATCH %s: + %s "%s"', label, child.ClassName, child.Name)
	end))
	table.insert(bin, folder.ChildRemoved:Connect(function(child)
		say('WATCH %s: - %s "%s"', label, child.ClassName, child.Name)
	end))
	table.insert(bin, folder.AttributeChanged:Connect(function(name)
		say('WATCH %s: attribute %s = %s', label, name, tostring(folder:GetAttribute(name)))
	end))
	table.insert(bin, folder.DescendantAdded:Connect(function(desc)
		say('WATCH %s: descendant + %s "%s"', label, desc.ClassName, desc.Name)
	end))
end

local function dumpInventory(store, itemType, label)
	local ok, items = pcall(function()
		return store:getState().Inventory.observedInventory.inventory.items
	end)
	if not ok then
		say('%s: cannot read the inventory: %s', label, tostring(items))
		return
	end

	local found = 0
	for slot, item in items do
		if item.itemType == itemType then
			found += 1
			say('%s: slot %s = %s x%s, tool %s', label, tostring(slot), item.itemType, tostring(item.amount), item.tool and (item.tool.ClassName..' "'..item.tool.Name..'"') or 'nil')
		end
	end
	if found == 0 then
		say('%s: no %s in your inventory', label, itemType)
	end
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
	queueCheck()
	local okRemotes, remotes = pcall(function()
		return require(ReplicatedStorage.TS.remotes).default.Client:GetNamespace('Inventory')
	end)
	if not okRemotes then
		say('cannot reach the Inventory remotes: %s', tostring(remotes))
		return
	end

	local okStore, store = pcall(function()
		return require(lplr.PlayerScripts.TS.ui.store).ClientStore
	end)
	if not okStore then
		say('cannot reach the client store: %s', tostring(store))
		return
	end

	local itemType = cfg.Item

	-- Every chest remote the game ships, by name. If the one being called is not the one
	-- the server is listening on any more, the call still returns cleanly and does nothing -
	-- which is exactly the symptom.
	local names = {}
	for _, v in ReplicatedStorage:GetDescendants() do
		if (v:IsA('RemoteFunction') or v:IsA('RemoteEvent') or v:IsA('UnreliableRemoteEvent')) and v.Name:lower():find('chest') then
			table.insert(names, string.format('%s (%s)', v:GetFullName(), v.ClassName))
		end
	end
	say('chest remotes found: %s', #names > 0 and table.concat(names, ', ') or 'none by that name')

	-- Whether the game thinks you have the chest open, which is a different thing to the
	-- folder being announced and may well be what the server is actually gating on.
	local okApp, appOpen = pcall(function()
		local AppController = require(ReplicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out.client.controllers['app-controller']).AppController
		return AppController:isAppOpen('ChestApp')
	end)
	say('ChestApp open: %s', okApp and tostring(appOpen) or 'could not tell ('..tostring(appOpen)..')')

	local char = lplr.Character
	local observed = char and char:FindFirstChild('ObservedChestFolder')
	say('ObservedChestFolder: %s', observed and (observed.Value and observed.Value:GetFullName() or 'nil') or 'the value does not exist')

	local inventories = ReplicatedStorage:FindFirstChild('Inventories')
	local folder = inventories and inventories:FindFirstChild(lplr.Name..'_personal')
	if not folder then
		say('no personal chest folder')
		return
	end

	-- Announced only if something else has not already done it, so a chest opened by hand
	-- is left exactly as the game set it.
	if observed and observed.Value ~= folder then
		local okSet, setErr = pcall(function()
			return remotes:Get('SetObservedChest'):SendToServer(folder)
		end)
		say('SetObservedChest sent: %s%s', tostring(okSet), okSet and '' or ' ('..tostring(setErr)..')')
		for _ = 1, 20 do
			if observed.Value == folder then
				break
			end
			task.wait()
		end
		say('ObservedChestFolder now: %s', observed.Value and observed.Value:GetFullName() or 'nil')
	end

	local tool
	local okItems, items = pcall(function()
		return store:getState().Inventory.observedInventory.inventory.items
	end)
	if okItems then
		for _, item in items do
			if item.itemType == itemType and item.tool then
				tool = item.tool
				break
			end
		end
	end

	--[[
		The same item from the other side.

		The store's tool came back parented to nil, and an orphan is exactly what a server
		would fail to resolve while still answering true. The character's InventoryFolder
		is where the game's own UI reads items from, so if these are two different
		instances the one the UI uses is worth sending on its own.
	]]
	local invFolder = inventoryFolder()
	local live = invFolder and invFolder:FindFirstChild(itemType)
	say('store tool: %s | InventoryFolder: %s', tool and string.format('%s "%s" parent %s', tool.ClassName, tool.Name, tool.Parent and tool.Parent:GetFullName() or 'nil') or 'nil', invFolder and (live and string.format('%s "%s" parent %s', live.ClassName, live.Name, live.Parent and live.Parent:GetFullName() or 'nil') or 'no '..itemType..' child') or 'no InventoryFolder on your character')
	if tool and live then
		say('same instance: %s', tostring(tool == live))
	end

	if not tool and not live then
		say('no %s instance anywhere, nothing to send', itemType)
		return
	end

	say('--- before ---')
	dumpInventory(store, itemType, 'inventory')
	dumpFolder(folder, 'chest')
	if invFolder then
		dumpFolder(invFolder, 'your items')
	end

	local bin = {}
	watch(folder, 'chest', bin)
	if invFolder then
		watch(invFolder, 'items', bin)
	end

	-- Both candidates, in order, each given a second to land. The second is skipped when
	-- the store handed back the very instance the UI is using, since that is the same send.
	local attempts = {{Label = 'store tool', Object = tool}}
	if live and live ~= tool then
		table.insert(attempts, {Label = 'InventoryFolder child', Object = live})
	end

	for _, attempt in attempts do
		local object = attempt.Object
		say('sending %s as the %s (%s "%s")', itemType, attempt.Label, object.ClassName, object.Name)
		local okGive, result = pcall(function()
			return remotes:Get('ChestGiveItem'):CallServer(folder, object)
		end)
		say('ChestGiveItem returned: %s%s', okGive and 'ok -> ' or 'THREW -> ', describe(result))
		task.wait(1)
		say('after the %s: chest has %d children, attributes: %s', attempt.Label, #folder:GetChildren(), attributeList(folder))
		dumpInventory(store, itemType, 'inventory')
	end

	--[[
		What the game itself uses to read the personal chest.

		Fired last and only listened to: if the contents come back over this rather than as
		children of the folder, the reply is the thing every count so far has been missing,
		and the watchers above will show whatever it changes.
	]]
	local okAcc, accErr = pcall(function()
		return remotes:Get('GetAccumulatedResourcesFromPersonalChest'):SendToServer()
	end)
	say('GetAccumulatedResourcesFromPersonalChest fired: %s%s', tostring(okAcc), okAcc and '' or ' ('..tostring(accErr)..')')
	task.wait(1.5)

	say('--- after ---')
	dumpInventory(store, itemType, 'inventory')
	dumpFolder(folder, 'chest')
	if invFolder then
		dumpFolder(invFolder, 'your items')
	end

	for _, connection in bin do
		connection:Disconnect()
	end
end

cfg.Run = run

task.spawn(run)
