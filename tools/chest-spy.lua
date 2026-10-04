--[[
	Bedwars - chest remote spy.

	Logs what the game itself sends. Open a chest by hand, move an item in and out with the
	mouse, and every chest or inventory remote the client fires is printed with its
	arguments and, for a RemoteFunction, what came back.

	This exists because everything up to now has been guesswork about the call shape. A
	deposit that bounces after one round trip is a deposit the server did not accept, and
	rather than keep trying argument orders against it, this watches the one caller known
	to get it right - the game's own UI.

	What to compare, once you have a log of a real deposit:

	    the remote name           ChestGiveItem may not be what the UI calls any more
	    the argument list         folder and tool may not be the whole of it, or the order
	    what comes first          an open or session call before the transfer would explain
	                              why announcing the folder is not enough on its own

	Hooking is on __namecall, which is where FireServer and InvokeServer go, because the
	game captured its own remote references at startup and nothing wrapped afterwards would
	see them. Calls made by scripts rather than by the game are skipped, so this does not
	log the probes back at itself.

	    ChestSpy.Stop()    put the metamethod back
	    ChestSpy.All = true   log every remote, not just chest and inventory ones
]]

local cfg = getgenv().ChestSpy or {}
cfg.All = cfg.All or false
getgenv().ChestSpy = cfg

local function say(fmt, ...)
	print(string.format('[spy] '..fmt, ...))
end

local function describe(value, depth)
	depth = depth or 0
	local kind = typeof(value)
	if kind == 'Instance' then
		return string.format('%s"%s"', value.ClassName, value.Name)
	end
	if kind ~= 'table' then
		return kind == 'string' and string.format('%q', value) or tostring(value)
	end
	if depth > 2 then
		return '{...}'
	end

	local parts = {}
	for k, v in value do
		table.insert(parts, string.format('%s=%s', tostring(k), describe(v, depth + 1)))
	end
	if #parts == 0 then
		return '{}'
	end
	return '{'..table.concat(parts, ', ')..'}'
end

local function argsOf(...)
	local count = select('#', ...)
	local parts = {}
	for i = 1, count do
		table.insert(parts, describe((select(i, ...))))
	end
	return table.concat(parts, ', ')
end

-- Only the ones worth reading, unless asked otherwise. Remote names in this game carry
-- their namespace, so an inventory call is 'Inventory/ChestGiveItem'.
local function interesting(name)
	if cfg.All then
		return true
	end
	local lower = name:lower()
	return lower:find('chest') ~= nil or lower:find('inventory') ~= nil or lower:find('item') ~= nil
end

local hooked = getgenv().__chestSpyRestore
if hooked then
	say('a spy was already running, replacing it')
	pcall(hooked)
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

	-- checkcaller is true for calls made by this script and the other tools, which are
	-- exactly the ones not worth logging - the point is what the game sends.
	if method and (method == 'FireServer' or method == 'InvokeServer') and (not checkcaller or not checkcaller()) then
		local ok, name = pcall(function()
			return self.Name
		end)
		if ok and interesting(name) then
			say('%s %s(%s)', method, name, argsOf(...))
			if method == 'InvokeServer' then
				local results = table.pack(original(self, ...))
				say('    %s returned: %s', name, results.n > 0 and argsOf(table.unpack(results, 1, results.n)) or 'nothing')
				return table.unpack(results, 1, results.n)
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
	getgenv().__chestSpyRestore = nil
	say('stopped')
end

cfg.Stop = stop
getgenv().__chestSpyRestore = stop

say('watching. open a chest with F and move an item in, then out. ChestSpy.Stop() when done')
