local run = function(func) func() end
local cloneref = cloneref or function(obj) return obj end

local playersService = cloneref(game:GetService('Players'))
local inputService = cloneref(game:GetService('UserInputService'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local runService = cloneref(game:GetService('RunService'))
local collectionService = cloneref(game:GetService('CollectionService'))
local lightingService = cloneref(game:GetService('Lighting'))

local gameCamera = workspace.CurrentCamera
local lplr = playersService.LocalPlayer
local vain = shared.vain
local entitylib = vain.Libraries.entity
local targetinfo = vain.Libraries.targetinfo
local whitelist = vain.Libraries.whitelist
local prediction = vain.Libraries.prediction

local function notif(...)
	return vain:CreateNotification(...)
end

--[[
	Tribes 3v3 (place 72169370437173, universe 10768498581, by Snick Co). A single
	round-based place - the lobby and the match run in the same place.

	The combat is custom: no Roblox Tools held in hand, no TouchTransmitters, no Teams. A
	swing is the client calling the game's own Controller, which runs a Detect pass and sends
	the hit list to the server over a WeaponAction remote - the client chooses who it hit.
	This file finds those modules so the combat modules can drive them directly, which is the
	only way to land a hit here and the only honest source of who is a teammate.
]]

-- The combat modules, found once and cached. require returns the same table the game's own
-- scripts hold, so a hook here is a hook on what the game actually runs.
local combat = {}

--[[
	Finds the combat folder and requires its modules.

	The folder is the one holding a Controller module beside a Handlers folder with a Melee
	module and a Util module - the shape the game's own bootstrap relies on. Searched under
	the player's scripts and ReplicatedStorage rather than the whole game, because those are
	where client modules live and walking everything each call is far too much.
]]
local function resolveCombat()
	if combat.Controller then
		return combat
	end

	local roots = {lplr:FindFirstChild('PlayerScripts'), replicatedStorage}
	for _, place in roots do
		if not place then continue end
		for _, d in place:GetDescendants() do
			if d:IsA('ModuleScript') and d.Name == 'Controller' then
				local parent = d.Parent
				local handlers = parent and parent:FindFirstChild('Handlers')
				if handlers and handlers:FindFirstChild('Melee') and parent:FindFirstChild('Util') then
					combat.root = parent
					pcall(function() combat.Util = require(parent.Util) end)
					pcall(function() combat.Melee = require(handlers.Melee) end)
					pcall(function() combat.Controller = require(parent.Controller) end)
					if combat.Controller then
						return combat
					end
				end
			end
		end
	end
	return combat
end

--[[
	A single hook on Melee.Detect, shared by Reach and Killaura.

	Detect is the function every melee swing calls to pick who it hit, from a range, a cone
	angle and a cap - and the client's choice is what the server is told. Widening its
	arguments is therefore the whole of Reach and the targeting half of Killaura, and both
	done in one place so they compose instead of fighting over the same function.

	Installed once and left in. When nothing has set anything it adds zero to the range and
	changes neither the arc nor the cap, so an idle hook is a plain passthrough rather than
	something to tear back out and race over.
]]
local detect = {reach = 0, arc = nil, minTargets = nil}
local detectHooked = false

local function hookDetect()
	if detectHooked then return true end
	local c = resolveCombat()
	if not (c.Melee and type(c.Melee.Detect) == 'function') then
		return false
	end
	local real = c.Melee.Detect
	c.Melee.Detect = function(self, range, arc, maxTargets)
		range = (range or 8) + detect.reach
		if detect.arc then arc = detect.arc end
		if detect.minTargets then maxTargets = math.max(maxTargets or 1, detect.minTargets) end
		return real(self, range, arc, maxTargets)
	end
	detectHooked = true
	return true
end

--[[
	Whether a character is on your team, asked of the game itself.

	Util.IsTeammate is the exact test the game runs before it will let a swing hit someone,
	so using it means Vain draws the line in precisely the same place the game does, with
	none of the attribute guessing a custom team system would otherwise need.
]]
local function isTeammate(character)
	local c = resolveCombat()
	if c.Util and type(c.Util.IsTeammate) == 'function' then
		local ok, mate = pcall(c.Util.IsTeammate, character)
		if ok then
			return mate == true, true
		end
	end
	return false, false
end

-- Replaces the library's check for this game only. entitylib calls it when an entity is
-- added and whenever it re-evaluates Targetable, so every module that filters on Targetable
-- filters teammates here for free.
entitylib.targetCheck = function(entity)
	if not entity.Player then
		return true
	end

	-- Ranked players stay protected here too.
	if not select(2, whitelist:get(entity.Player)) then
		return false
	end

	if entity.TeamCheck then
		return entity:TeamCheck()
	end

	local character = entity.Character
	if character then
		local mate, known = isTeammate(character)
		if known then
			return not mate
		end
	end

	-- The game's own check could not be reached yet. Left targetable, which is the
	-- behaviour without this file - better than hiding real enemies.
	return true
end

vain.Libraries.tribes = {
	prediction = prediction,
	resolveCombat = resolveCombat,
	isTeammate = isTeammate,

	-- Reach and Killaura reach the shared Detect hook through these rather than touching the
	-- game's modules themselves, so neither has to know the other exists.
	hookDetect = hookDetect,
	setReach = function(extra)
		hookDetect()
		detect.reach = extra or 0
	end,
	setSwingDetect = function(arc, minTargets)
		hookDetect()
		detect.arc = arc
		detect.minTargets = minTargets
	end,
	clearSwingDetect = function()
		detect.arc = nil
		detect.minTargets = nil
	end,

	--[[
		A one-shot dump of the other players, for anything the source does not already answer
		- a side source the game's own check somehow misses, or the loadout a player carries.
		It walks the player, character, backpack and leaderstats and lists every attribute,
		value and child model, because a loadout here is Tools in the backpack keyed by a
		SlotIndex attribute. Run it near an enemy and send the output.
	]]
	probe = function()
		local lines = {}

		local function dump(label, container, deep)
			if not container then return end
			local ok, attrs = pcall(function() return container:GetAttributes() end)
			if ok then
				for key, value in attrs do
					table.insert(lines, label..' attr '..tostring(key)..' = '..tostring(value)..' ('..typeof(value)..')')
				end
			end
			for _, child in container:GetChildren() do
				if child:IsA('ValueBase') then
					table.insert(lines, label..' value '..child.Name..' = '..tostring(child.Value))
				elseif deep and (child:IsA('Model') or child:IsA('Folder') or child:IsA('Tool')) then
					local slot = child:GetAttribute('SlotIndex')
					table.insert(lines, label..' child '..child.ClassName..' "'..child.Name..'"'..(slot and (' slot '..tostring(slot)) or ''))
				end
			end
		end

		for _, player in playersService:GetPlayers() do
			if player == lplr then continue end
			table.insert(lines, '== '..player.Name..' ==')
			dump('player', player, false)
			dump('character', player.Character, true)
			dump('backpack', player:FindFirstChildOfClass('Backpack'), true)
			dump('leaderstats', player:FindFirstChild('leaderstats'), false)
			if #lines > 200 then break end
		end

		local text = table.concat(lines, '\n')
		print('[Vain] Tribes probe:\n'..text)
		pcall(function() setclipboard(text) end)
		notif('Vain', 'Tribes probe copied to clipboard and printed to console', 10, 'check')
		return text
	end
}

-- Said once, because silently aiming at teammates is worse than being told the game's check
-- could not be reached.
task.spawn(function()
	task.wait(12)
	if not select(2, isTeammate(lplr.Character)) and not resolveCombat().Util then
		notif('Vain', 'Tribes: could not reach the game\'s team check, so teammates are not being filtered.', 15, 'alert')
	end
end)
