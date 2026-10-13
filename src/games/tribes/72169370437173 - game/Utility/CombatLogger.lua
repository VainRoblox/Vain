--[[
	Combat Logger.

	Tribes ships no Roblox Tools and no TouchTransmitters - its weapons are a custom combat
	system that talks to the server over its own remotes - so the universal Killaura, which
	swings a Tool and fires a Touched interest, lands nothing here. A Tribes Killaura has to
	fire the real remote instead, and the place file keeps its scripts as stripped bytecode,
	so the only way to learn that remote is to watch the live client send it.

	This is that watch. While it is on it hooks the one method every remote call goes
	through and prints the combat-looking ones - name, how it was called, and a readable dump
	of the arguments - once each, so a single swing of each weapon reveals exactly what to
	replay. Turn it on, hit a dummy or an enemy with each weapon, then send the console
	output and the Killaura can be built against it.
]]
local CombatLogger
local Everything
local Clear

-- One line per unique remote+method, so a weapon swung fifty times is logged once rather
-- than flooding the console. Cleared by the Clear button and on enable.
local seen = {}

-- Names worth printing. A live game fires movement and replication remotes constantly, and
-- drowning the hit call in those is the opposite of useful, so by default only the combat
-- ones come through. Everything turns the filter off when a weapon's remote is named
-- something unexpected.
local COMBAT_WORDS = {
	'hit', 'combat', 'melee', 'damage', 'attack', 'swing', 'strike',
	'axe', 'club', 'dagger', 'harpoon', 'bow', 'arrow', 'spear', 'projectile', 'throw'
}

local function interesting(name)
	if Everything.Enabled then return true end
	local lower = name:lower()
	for _, word in COMBAT_WORDS do
		if lower:find(word, 1, true) then return true end
	end
	return false
end

-- A short, readable form of one argument. The hit remote's payload is the whole point, so
-- this spells out the things a hit carries - who, where, which part - rather than just
-- their types.
local function describe(value, depth)
	local kind = typeof(value)
	if kind == 'Instance' then
		return value.ClassName..'('..value.Name..')'
	elseif kind == 'Vector3' then
		return ('Vector3(%.1f, %.1f, %.1f)'):format(value.X, value.Y, value.Z)
	elseif kind == 'CFrame' then
		local p = value.Position
		return ('CFrame@(%.1f, %.1f, %.1f)'):format(p.X, p.Y, p.Z)
	elseif kind == 'table' then
		if depth and depth > 1 then return 'table' end
		local parts = {}
		for k, v in value do
			table.insert(parts, tostring(k)..'='..describe(v, (depth or 0) + 1))
			if #parts >= 8 then
				table.insert(parts, '...')
				break
			end
		end
		return '{'..table.concat(parts, ', ')..'}'
	elseif kind == 'string' then
		return '"'..value..'"'
	end
	return tostring(value)
end

local function dumpArgs(args)
	local parts = {}
	for i = 1, args.n do
		parts[i] = describe(args[i])
	end
	return table.concat(parts, ', ')
end

local function log(method, remote, args)
	local ok, name = pcall(function()
		return remote.Name
	end)
	name = ok and name or '?'
	if not interesting(name) then return end

	local key = method..':'..name
	if seen[key] then return end
	seen[key] = true

	local line = ('[Tribes] %s %s(%s)'):format(method, name, dumpArgs(args))
	print(line)
	-- Each new remote is announced, so you know the swing registered without watching the
	-- console - and the full detail is there when you go to copy it.
	notif('Combat Logger', name..' logged', 4)
end

CombatLogger = vain.Categories.Utility:CreateModule({
	Name = 'Combat Logger',
	Function = function(callback)
		if not callback then
			return
		end
		table.clear(seen)

		-- hookmetamethod on __namecall catches every FireServer / InvokeServer in one place,
		-- which is where a custom combat system sends its hits. The original is kept and
		-- called so the game plays normally while this watches.
		local ok = pcall(function()
			local mt = getrawmetatable(game)
			local old
			old = hookmetamethod(game, '__namecall', function(self, ...)
				local method = getnamecallmethod()
				if method == 'FireServer' or method == 'InvokeServer' then
					local args = table.pack(...)
					-- Logging must not throw into the game's call path, and must not run with
					-- the game's identity, so it is guarded and the identity is reset first.
					pcall(function()
						if vain.ThreadFix then
							setthreadidentity(8)
						end
						log(method, self, args)
					end)
				end
				return old(self, ...)
			end)
			-- Undo the hook when the module is switched off, so it does not keep logging or
			-- leave a dead hook behind.
			CombatLogger:Clean(function()
				pcall(function()
					hookmetamethod(game, '__namecall', old)
				end)
			end)
		end)

		if not ok then
			notif('Combat Logger', 'Could not hook remotes on this executor', 8, 'alert')
			CombatLogger:Toggle()
		else
			notif('Combat Logger', 'Watching. Hit an enemy with each weapon, then send the console output.', 10)
		end
	end,
	Tooltip = 'Prints the combat remotes the game fires'
})
Everything = CombatLogger:CreateToggle({
	Name = 'Log Everything',
	Tooltip = 'Logs every remote, not just combat ones'
})
Clear = CombatLogger:CreateButton({
	Name = 'Clear Seen',
	Tooltip = 'Logs each remote once more',
	Function = function()
		table.clear(seen)
		notif('Combat Logger', 'Cleared', 3)
	end
})
