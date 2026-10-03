--[[
	Mine Through Players.

	The game finds the block you are mining by casting a ray from your cursor that ignores
	only your own character - so another player standing in the way catches the ray, there
	is no block under it, and you cannot mine. That is the body block.

	The ray already steps past anything the game marks as query-ignored and carries on to
	whatever is behind it. So for exactly as long as the block selector is casting, the
	players you choose count as query-ignored, and your cursor reaches the block behind them.
	Nothing else that asks the same question - projectiles, hits - is affected, because the
	answer only changes inside that one cast.
]]
local MineThrough
local Through, Placing, Mobs
local SELECT, PLACE = 1, 0
local selecting = false
local selectorClass, oldMouseInfo, mouseHook
local queryUtil, oldIgnored, ignoredHook

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function sameTeam(plr)
	local mine, theirs = lplr:GetAttribute('Team'), plr:GetAttribute('Team')
	return mine ~= nil and theirs ~= nil and tostring(mine) == tostring(theirs)
end

-- Whether this part belongs to something that should not stop the cursor.
local function seeThrough(part)
	for _, plr in playersService:GetPlayers() do
		local char = plr.Character
		if plr ~= lplr and char and part:IsDescendantOf(char) then
			local mode = Through and Through.Value or 'Everyone'
			if mode == 'Enemies' then return not sameTeam(plr) end
			if mode == 'Teammates' then return sameTeam(plr) end
			return true
		end
	end
	if on(Mobs) then
		local model = part:FindFirstAncestorOfClass('Model')
		while model do
			if collectionService:HasTag(model, 'entity') then return true end
			model = model.Parent and model.Parent:FindFirstAncestorOfClass('Model')
		end
	end
	return false
end

local function getSelector()
	local ok, selector = pcall(function()
		if bedwars.BlockBreaker and bedwars.BlockBreaker.clientManager then
			return bedwars.BlockBreaker.clientManager:getBlockSelector()
		end
		return bedwars.BlockEngine:getBlockSelector()
	end)
	return ok and selector or nil
end

local function install()
	if mouseHook then return true end
	local selector = getSelector()
	local class = selector and getmetatable(selector)
	local query = bedwars.QueryUtil
	if not (class and type(class.getMouseInfo) == 'function' and query and type(query.isQueryIgnored) == 'function') then
		return false
	end

	selectorClass, oldMouseInfo = class, class.getMouseInfo
	queryUtil, oldIgnored = query, query.isQueryIgnored

	local original = oldMouseInfo
	mouseHook = function(self, mode, ...)
		if MineThrough.Enabled and (mode ~= PLACE or on(Placing)) then
			selecting = true
			local results = table.pack(pcall(original, self, mode, ...))
			selecting = false
			if results[1] then
				return table.unpack(results, 2, results.n)
			end
			return nil
		end
		return original(self, mode, ...)
	end

	local ignored = oldIgnored
	ignoredHook = function(self, instance, ...)
		if selecting and typeof(instance) == 'Instance' and seeThrough(instance) then
			return true
		end
		return ignored(self, instance, ...)
	end

	class.getMouseInfo = mouseHook
	query.isQueryIgnored = ignoredHook
	return true
end

-- Put back only while ours are the ones installed, so anything wrapped after them keeps
-- working.
local function uninstall()
	if selectorClass and mouseHook and selectorClass.getMouseInfo == mouseHook then
		selectorClass.getMouseInfo = oldMouseInfo
	end
	if queryUtil and ignoredHook and queryUtil.isQueryIgnored == ignoredHook then
		queryUtil.isQueryIgnored = oldIgnored
	end
	mouseHook, ignoredHook = nil, nil
	selecting = false
end

MineThrough = vain.Categories.World:CreateModule({
	Name = 'Mine Through Players',
	Tooltip = 'Lets you mine blocks with players standing in the way',
	Function = function(callback)
		if callback then
			-- The block engine starts with the match, so it is waited for rather than
			-- assumed.
			task.spawn(function()
				for _ = 1, 40 do
					if not MineThrough.Enabled or install() then return end
					task.wait(0.5)
				end
			end)
		else
			uninstall()
		end
	end
})
Through = MineThrough:CreateDropdown({
	Name = 'Through',
	Tooltip = 'Whose bodies the cursor goes through',
	List = {'Everyone', 'Enemies', 'Teammates'},
	Default = 'Everyone',
	Tooltips = {
		Everyone = 'Any player in the way',
		Enemies = 'Only players on other teams',
		Teammates = 'Only players on your team'
	}
})
Mobs = MineThrough:CreateToggle({
	Name = 'Mobs Too',
	Tooltip = 'Also goes through golems and other creatures'
})
Placing = MineThrough:CreateToggle({
	Name = 'Placing Too',
	Tooltip = 'Also lets you place blocks past players'
})
