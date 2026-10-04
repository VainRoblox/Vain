--[[
	Bedwars - shop purchase race.

	A purchase is a conversion: the server checks you can afford something, then takes the
	currency and gives you the item. Two checks that both pass before either deduction
	lands is the oldest counting bug there is, and a shop has something a chest does not -
	an affordability test that has to read, decide and write.

	Nothing is reconstructed here. The payload BedwarsPurchaseItem takes is a nested table
	built from the shop's own item meta and the id of the shopkeeper you are standing at,
	and guessing at either is how you end up testing your own typo. So this captures the
	real one: buy something by hand, the hook keeps exactly what the game sent, and the
	replay fires that same table back N times at once.

	The count is currency against goods. One purchase should cost one price and yield one
	item, so N purchases should cost N prices. Fewer prices than items is the bug, and the
	report says which way it came out rather than leaving it to be eyeballed.

	    1. run this, then buy one cheap item at the shop with your mouse
	    2. ShopRace.Fire()          replays it, by default 4 at once
	    3. ShopRace.Stop()          unhooks when you are done

	Have roughly one item's worth of currency when firing, not twenty: the interesting
	answer is N items for one price, and that only shows when you cannot afford N.

	Settings:
	    ShopRace.Shots = 4
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local lplr = Players.LocalPlayer

local cfg = getgenv().ShopRace or {}
cfg.Shots = cfg.Shots or 4
getgenv().ShopRace = cfg

local captured = nil

local function say(fmt, ...)
	print(string.format('[shop] '..fmt, ...))
end

local function itemsFolder()
	local char = lplr.Character
	local value = char and char:FindFirstChild('InventoryFolder')
	return value and value.Value
end

-- Counts come off the Accessory attributes, the same instances the game moves. A type
-- that does not stack has no Amount, so its entries are counted instead.
local function countOf(name)
	local folder = itemsFolder()
	if not folder then
		return 0
	end
	local total = 0
	for _, child in folder:GetChildren() do
		if child.Name == name then
			total += child:GetAttribute('Amount') or 1
		end
	end
	return total
end

local function client()
	local ok, net = pcall(function()
		return require(ReplicatedStorage.TS.remotes).default.Client
	end)
	return ok and net or nil
end

--[[
	Fires the captured purchase several times without yielding in between.

	CallServerAsync hands back a promise rather than waiting, which is what the game's own
	shop uses and what makes this a race at all: the calls leave together instead of one
	resolving before the next is sent.
]]
local function fire(shots)
	if not captured then
		return say('nothing captured yet - buy something at the shop first')
	end

	local net = client()
	if not net then
		return say('cannot reach the remotes')
	end

	shots = shots or cfg.Shots
	local item = captured.shopItem or {}
	local itemType = item.itemType or '?'
	local currency = item.currency or 'iron'
	local price = item.price or 0

	local payBefore, gotBefore = countOf(currency), countOf(itemType)
	say('firing %d x %s at %d %s each | holding %d %s, %d %s', shots, itemType, price, currency, payBefore, currency, gotBefore, itemType)
	if price > 0 and payBefore < price * shots then
		say('you cannot afford all %d, which is the point - anything above %d received is unpaid for', shots, math.floor(payBefore / price))
	end

	local sent = 0
	for _ = 1, shots do
		local ok = pcall(function()
			return net:Get('BedwarsPurchaseItem'):CallServerAsync(captured)
		end)
		if ok then
			sent += 1
		end
	end

	task.wait(2)

	local payAfter, gotAfter = countOf(currency), countOf(itemType)
	local spent, gained = payBefore - payAfter, gotAfter - gotBefore
	local paidFor = price > 0 and (spent / price) or 0
	say('spent %d %s (%.2f purchases worth), received %d %s, from %d calls', spent, currency, paidFor, gained, itemType, sent)

	if price <= 0 then
		say('this item is free, so there is nothing to conserve - capture a priced one')
	elseif gained > paidFor + 0.01 then
		say('UNPAID: %d received for %.2f purchases worth of %s - re-run to see if it repeats', gained, paidFor, currency)
	elseif gained < paidFor - 0.01 then
		say('OVERCHARGED: paid for %.2f, received %d - currency going somewhere, the other kind of bug', paidFor, gained)
	else
		say('conserved - every item was paid for')
	end
end

local restore = getgenv().__shopRaceRestore
if restore then
	say('replacing the previous hook')
	pcall(restore)
end

local mt = getrawmetatable(game)
local wasReadonly = isreadonly and isreadonly(mt)
if setreadonly and wasReadonly then
	setreadonly(mt, false)
end

local original = mt.__namecall
local wrap = newcclosure or function(f)
	return f
end

mt.__namecall = wrap(function(self, ...)
	local method = getnamecallmethod and getnamecallmethod() or nil

	if method and (method == 'FireServer' or method == 'InvokeServer') and (not checkcaller or not checkcaller()) then
		local ok, name = pcall(function()
			return self.Name
		end)
		if ok and name:find('PurchaseItem') then
			local payload = (select(1, ...))
			if type(payload) == 'table' and payload.shopItem then
				captured = payload
				local item = payload.shopItem
				say('captured: %s at %s %s (shopId %s)', tostring(item.itemType), tostring(item.price), tostring(item.currency), tostring(payload.shopId))
				say('ShopRace.Fire() to replay it %d times at once', cfg.Shots)
			end
		end
	end

	return original(self, ...)
end)

local function stop()
	mt.__namecall = original
	if setreadonly and wasReadonly then
		setreadonly(mt, true)
	end
	getgenv().__shopRaceRestore = nil
	say('unhooked')
end

cfg.Fire = fire
cfg.Stop = stop
getgenv().__shopRaceRestore = stop

say('watching for a purchase. buy one cheap item at the shop with your mouse')
