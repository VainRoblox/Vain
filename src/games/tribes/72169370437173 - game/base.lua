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

local function notif(...)
	return vain:CreateNotification(...)
end

-- Tribes 3v3 (place 72169370437173, universe 10768498581, by Snick Co). It is a single
-- round-based place - the lobby and the match run in the same place, which is why the
-- game file is keyed to one id rather than a lobby/match pair.
--
-- The game does not use Roblox Teams: the match file carries zero Team objects, and sides
-- are tracked by the game's own Team1/Team2 system over remotes instead. So the universal
-- aim modules, which fall back to Player.Team, would see lplr.Team nil and return every
-- player as a valid target - teammates included. This override replaces that check with
-- one that looks where this game realistically keeps the side.
--
-- Where it lives is not something to assume, so this reads the places a Roblox game keeps
-- it and uses the first that answers. If none do, it says so rather than guessing:
-- returning "unknown" leaves targeting exactly as it is today instead of silently deciding
-- half the server is friendly. The probe below is there to find the real source fast.
local TEAM_KEYS = {'Team', 'TeamName', 'TeamId', 'Side', 'Tribe', 'TribeId', 'Squad', 'squadra'}

local function valueOf(container)
	if not container then return nil end
	for _, key in TEAM_KEYS do
		local attr = container:GetAttribute(key)
		if attr ~= nil then return tostring(attr) end
	end
	for _, key in TEAM_KEYS do
		local child = container:FindFirstChild(key)
		if child and child:IsA('ValueBase') and child.Value ~= nil then
			return tostring(child.Value)
		end
	end
	return nil
end

local function teamOf(player)
	if not player then return nil end

	-- Roblox Teams, in case a mode does use them.
	if player.Team then return tostring(player.Team) end

	local fromPlayer = valueOf(player)
	if fromPlayer then return fromPlayer end

	local fromCharacter = valueOf(player.Character)
	if fromCharacter then return fromCharacter end

	return valueOf(player:FindFirstChild('leaderstats'))
end

-- Replaces the library's check for this game only. Overriding this one function is enough:
-- entitylib calls it when an entity is added and again whenever it re-evaluates Targetable,
-- so every module that filters on Targetable picks this up for free.
entitylib.targetCheck = function(entity)
	if not entity.Player then
		return true
	end

	-- Ranked players stay protected here too - without this half they would be as
	-- targetable as anybody else in this game alone.
	if not select(2, whitelist:get(entity.Player)) then
		return false
	end

	if entity.TeamCheck then
		return entity:TeamCheck()
	end

	local mine, theirs = teamOf(lplr), teamOf(entity.Player)
	if mine == nil or theirs == nil then
		-- Side could not be determined for one of us. Left targetable, which is the
		-- behaviour without this file at all - better than hiding real enemies.
		return true
	end

	return mine ~= theirs
end

-- A one-shot probe, so the real side source can be found from a live match rather than
-- guessed from a static place file. It dumps, for a couple of other players, every
-- attribute and named value on the player, character and leaderstats, which is where a
-- side assignment realistically sits. Run it in a match and send the output.
vain.Libraries.tribes = {
	teamOf = teamOf,
	teamKeys = TEAM_KEYS,
	probe = function()
		local lines = {}
		for _, player in playersService:GetPlayers() do
			if player == lplr then continue end
			table.insert(lines, '== '..player.Name..' ==')
			for _, where in {{'player', player}, {'character', player.Character}, {'leaderstats', player:FindFirstChild('leaderstats')}} do
				local label, container = where[1], where[2]
				if not container then continue end
				local ok, attrs = pcall(function() return container:GetAttributes() end)
				if ok then
					for key, value in attrs do
						table.insert(lines, label..' attr '..tostring(key)..' = '..tostring(value))
					end
				end
				for _, child in container:GetChildren() do
					if child:IsA('ValueBase') then
						table.insert(lines, label..' value '..child.Name..' = '..tostring(child.Value))
					end
				end
			end
			if #lines > 120 then break end
		end
		local text = table.concat(lines, '\n')
		print('[Vain] Tribes side probe:\n'..text)
		pcall(function() setclipboard(text) end)
		notif('Vain', 'Tribes probe copied to clipboard and printed to console', 10, 'check')
		return text
	end
}

-- Said once, because silently aiming at teammates is worse than being told the side source
-- needs finding. If the probe helper exists, point at it.
task.spawn(function()
	task.wait(10)
	if teamOf(lplr) == nil then
		notif('Vain', 'Tribes: could not work out your side, so teammates are not filtered. In a match, run vain.Libraries.tribes.probe() and send the output.', 15, 'alert')
	end
end)
