local PartyFinder
local Mode, Player, Dungeons
local Difficulty, Hardcore, WaveDefence, Players
local IgnoreLevel, PartyLevel, IncludeRaids, SweepDelay, Notify

--[[
	Finding a party on another server.

	The lobby's Global tab is backed by four remotes, all read off the lobby place dump:

	  listGlobalParties(dungeonName) -> { {jobId, ownerName, ownerDisplayName, dungeon,
	                                      difficulty, waveDefence, hardcore, private,
	                                      playerCount, minLevelReq}, ... }
	  joinGlobalParty(jobId, ownerName) -> true when it took
	  listGlobalRaids()               -> { {jobId, ownerName, ownerDisplayName, tier,
	                                        tierReq, private, playerCount}, ... }
	  joinGlobalRaid(jobId, ownerName) -> true when it took

	Every field worth filtering on is already in the listing, so a sweep is one call per
	dungeon and the matching costs nothing beyond it. The catch is that there is no call
	that lists everything: listGlobalParties wants a dungeon name, and the game's own UI
	refuses to open the Global tab until you pick one. So watching for a particular
	player means asking about each dungeon in turn.

	Private parties are skipped outright. The global path does not check permission
	client-side the way the lobby-local one does - it just calls and lets the server
	refuse - so trying them would only produce failed joins.
]]

-- Every dungeon MapPlaces has marked released, minus the tutorial.
local DUNGEONS = {
	'Desert Temple', 'Winter Outpost', 'Pirate Island', "King's Castle",
	'The Underworld', 'Samurai Palace', 'The Canals', 'Ghastly Harbor',
	'Steampunk Sewers', 'Orbital Outpost', 'Volcanic Chambers', 'Aquatic Temple',
	'Enchanted Forest', 'Northern Lands', 'Egg Island', 'Wave Defence', 'Boss Raid'
}

local function notify(text, kind)
	if Notify and not Notify.Enabled and kind ~= 'alert' then return end
	if vain and vain.CreateNotification then
		vain:CreateNotification('Party Finder', text, 6, kind or 'info')
	end
end

-- 'Any' means the setting is not being used; otherwise Yes/No read as the booleans the
-- listing carries.
local function triState(setting, value)
	if setting.Value == 'Any' then return true end
	return (setting.Value == 'Yes') == (value == true)
end

local function named(party)
	local target = tostring(Player.Value):lower():gsub('^%s+', ''):gsub('%s+$', '')
	if target == '' then return false end
	return tostring(party.ownerName):lower() == target
		or tostring(party.ownerDisplayName):lower() == target
end

local function levelOk(requirement)
	if IgnoreLevel.Enabled then return true end
	return playerLevel() >= (tonumber(requirement) or 0)
end

--[[
	Only parties carrying players of a level.

	A global listing says nothing about who is in a party - no members, no levels, only
	how many. The one piece of level information it does carry is minLevelReq, the bar
	the host set on the party, and everyone inside had to clear it to get in. So a party
	requiring the level asked for is a party whose players are all at least that level.

	It reads one way only. A party that happens to contain a high level without demanding
	one looks the same as an empty lobby from out here, so those are passed over rather
	than joined on a guess.
]]
local function partyLevelOk(requirement)
	if PartyLevel.Value <= 0 then return true end
	return (tonumber(requirement) or 0) >= PartyLevel.Value
end

local function countOk(count)
	count = tonumber(count) or 0
	return count >= Players.ValueMin and count <= Players.ValueMax
end

local function wanted(party)
	if party.private == true then return false end
	if not countOk(party.playerCount) then return false end
	if not levelOk(party.minLevelReq) then return false end
	if not partyLevelOk(party.minLevelReq) then return false end

	if Mode.Value == 'Player' then return named(party) end

	if Difficulty.Value ~= 'Any' and party.difficulty ~= Difficulty.Value then return false end
	if not triState(Hardcore, party.hardcore) then return false end
	if not triState(WaveDefence, party.waveDefence) then return false end
	return true
end

-- The dungeons to ask about. An empty list is read as "all of them" rather than as
-- "none", since an empty box is what someone clearing it out means by it.
local function searchList()
	local chosen = Dungeons.ListEnabled
	if #chosen <= 0 then return DUNGEONS end
	return chosen
end

--[[
	Joining, and then getting out of the way.

	A successful join puts you in someone's party, so there is nothing left to look for -
	carrying on sweeping would at best waste calls and at worst pull you out of the party
	it just found. So the module switches itself off, which also stops the loop.
]]
local function tryJoin(remoteName, party, what)
	local join = remote(remoteName)
	if not join then return false end

	local ok, joined = pcall(function()
		return join:InvokeServer(party.jobId, party.ownerName)
	end)

	if ok and joined == true then
		notify(`Joined {party.ownerDisplayName or party.ownerName}'s {what}`)
		PartyFinder:Toggle()
		return true
	end
	return false
end

local function sweepParties()
	local list = remote('listGlobalParties')
	if not list then return false end

	for _, dungeon in searchList() do
		if not PartyFinder.Enabled then return false end

		local ok, result = pcall(function() return list:InvokeServer(dungeon) end)
		if ok and type(result) == 'table' then
			for _, party in result do
				if type(party) == 'table' and party.jobId and wanted(party) then
					if tryJoin('joinGlobalParty', party, `{party.dungeon} party`) then
						return true
					end
				end
			end
		end
	end
	return false
end

--[[
	Raids are listed whole rather than per dungeon, and their records carry a tier where a
	party carries a dungeon and a difficulty - so the settings filters have nothing to
	match on. That is why they are only swept when looking for a named player.
]]
local function sweepRaids()
	local list = remote('listGlobalRaids')
	if not list then return false end

	local ok, result = pcall(function() return list:InvokeServer() end)
	if not (ok and type(result) == 'table') then return false end

	-- No level check here: a raid records a tierReq, which is a raid tier and not a
	-- player level, so there is nothing to compare it against.
	for _, raid in result do
		if type(raid) == 'table' and raid.jobId and raid.private ~= true
			and countOk(raid.playerCount) and named(raid) then
			if tryJoin('joinGlobalRaid', raid, 'raid') then return true end
		end
	end
	return false
end

PartyFinder = vain.Categories.Utility:CreateModule({
	Name = 'Party Finder',
	Tooltip = 'Watches parties on other servers and joins the first one that matches',
	Function = function(callback)
		if not callback then return end

		if not remote('listGlobalParties') then
			notify('This server has no listGlobalParties remote, so there is nothing to search', 'alert')
			PartyFinder:Toggle()
			return
		end

		if Mode.Value == 'Player' and tostring(Player.Value):gsub('%s', '') == '' then
			notify('Set a player name to look for first', 'alert')
			PartyFinder:Toggle()
			return
		end

		notify(Mode.Value == 'Player'
			and `Looking for {Player.Value}`
			or 'Looking for a party')

		repeat
			local joined = sweepParties()
			if not joined and Mode.Value == 'Player' and IncludeRaids.Enabled then
				joined = sweepRaids()
			end
			if joined then return end
			task.wait(SweepDelay.Value)
		until not PartyFinder.Enabled
	end
})
Mode = PartyFinder:CreateDropdown({
	Name = 'Mode',
	List = {'Settings', 'Player'},
	Default = 'Settings',
	Tooltip = 'Match on the party settings, or wait for one hosted by a named player',
	Tooltips = {
		Settings = 'Joins the first party matching the filters below',
		Player = 'Joins the first party hosted by the name you set'
	},
	Function = function(value)
		local player = value == 'Player'
		for _, setting in {Difficulty, Hardcore, WaveDefence} do
			if setting and setting.Object then setting.Object.Visible = not player end
		end
		for _, setting in {Player, IncludeRaids} do
			if setting and setting.Object then setting.Object.Visible = player end
		end
	end
})
Player = PartyFinder:CreateTextBox({
	Name = 'Player',
	Visible = false,
	Placeholder = 'username or display name',
	Tooltip = 'Whose party to wait for. Matches either their username or their display name'
})
Dungeons = PartyFinder:CreateTextList({
	Name = 'Dungeons',
	Tooltip = 'Which dungeons to ask about, one per line. Empty searches all of them',
	Default = DUNGEONS
})
Difficulty = PartyFinder:CreateDropdown({
	Name = 'Difficulty',
	List = {'Any', 'Easy', 'Medium', 'Hard', 'Insane', 'Nightmare'},
	Default = 'Any',
	Tooltip = 'The difficulty the party is set to'
})
Hardcore = PartyFinder:CreateDropdown({
	Name = 'Hardcore',
	List = {'Any', 'Yes', 'No'},
	Default = 'Any',
	Tooltip = 'Whether the party is hardcore'
})
WaveDefence = PartyFinder:CreateDropdown({
	Name = 'Wave Defence',
	List = {'Any', 'Yes', 'No'},
	Default = 'Any',
	Tooltip = 'Whether the party is a wave defence run'
})
Players = PartyFinder:CreateTwoSlider({
	Name = 'Players',
	Min = 1,
	Max = 8,
	DefaultMin = 1,
	DefaultMax = 3,
	Tooltip = 'How many are already in it. Leave room for yourself'
})
IgnoreLevel = PartyFinder:CreateToggle({
	Name = 'Ignore Level',
	Default = false,
	Tooltip = 'Also try parties above your level. The server still decides'
})
PartyLevel = PartyFinder:CreateSlider({
	Name = 'Party Level',
	Min = 0,
	Max = 250,
	Default = 0,
	Tooltip = 'Only join parties requiring at least this level, so everyone in them is at least it. 0 is off'
})
IncludeRaids = PartyFinder:CreateToggle({
	Name = 'Include Raids',
	Default = false,
	Visible = false,
	Tooltip = 'Also watch boss raids for that player. Raids carry a tier rather than a dungeon, so the filters above do not apply to them'
})
SweepDelay = PartyFinder:CreateSlider({
	Name = 'Sweep Delay',
	Min = 1,
	Max = 30,
	Default = 5,
	Suffix = 's',
	Tooltip = 'How long to wait between passes through the dungeon list'
})
Notify = PartyFinder:CreateToggle({
	Name = 'Notify',
	Default = true,
	Tooltip = 'Says what it is looking for and what it joined'
})
