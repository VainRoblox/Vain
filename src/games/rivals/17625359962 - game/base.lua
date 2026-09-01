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

-- Rivals does not put players on Roblox Teams, which is the whole problem the universal
-- aim modules have here: entitylib.targetCheck falls back to Player.Team, and with
-- lplr.Team nil it returns true for everybody - so every module treats teammates as
-- valid targets.
--
-- Where the team actually lives is not something that can be assumed, so this reads the
-- places a Roblox game realistically keeps it and uses the first that answers. If none
-- do, it says so rather than guessing: returning "unknown" leaves targeting exactly as
-- it is today instead of silently deciding half the lobby is friendly.
local TEAM_KEYS = {'Team', 'TeamName', 'TeamId', 'Side', 'Squad'}

local function teamOf(player)
	if not player then return nil end

	-- Roblox Teams, in case some modes do use them.
	if player.Team then return tostring(player.Team) end

	for _, key in TEAM_KEYS do
		local value = player:GetAttribute(key)
		if value ~= nil then return tostring(value) end
	end

	local character = player.Character
	if character then
		for _, key in TEAM_KEYS do
			local value = character:GetAttribute(key)
			if value ~= nil then return tostring(value) end
		end
	end

	local stats = player:FindFirstChild('leaderstats')
	if stats then
		for _, key in TEAM_KEYS do
			local value = stats:FindFirstChild(key)
			if value and value.Value ~= nil then return tostring(value.Value) end
		end
	end

	return nil
end

-- Replaces the library's check for this game only. Overriding this one function is
-- enough: entitylib calls it when an entity is added and again whenever it re-evaluates
-- Targetable, so every module that filters on Targetable picks this up for free.
entitylib.targetCheck = function(entity)
	if not entity.Player then
		return true
	end

	-- Replacing the library's check means replacing all of it, and this half was missing:
	-- ranked players were protected everywhere except here, so an Owner was as targetable
	-- as anybody else in this game alone.
	if not select(2, whitelist:get(entity.Player)) then
		return false
	end

	if entity.TeamCheck then
		return entity:TeamCheck()
	end

	local mine, theirs = teamOf(lplr), teamOf(entity.Player)
	if mine == nil or theirs == nil then
		-- Team could not be determined for one of us. Left targetable, which is the
		-- behaviour without this file at all - better than hiding real enemies.
		return true
	end

	return mine ~= theirs
end

-- Said once, because silently aiming at teammates is worse than being told the team
-- source needs finding.
task.spawn(function()
	task.wait(10)
	if teamOf(lplr) == nil then
		notif('Vain', 'Rivals: could not work out which team you are on, so teammates are not being filtered. Run the team probe and send the output.', 15, 'alert')
	end
end)

vain.Libraries.rivals = {
	teamOf = teamOf,
	teamKeys = TEAM_KEYS
}
