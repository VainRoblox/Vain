local run = function(func) func() end
local cloneref = cloneref or function(obj) return obj end

local playersService = cloneref(game:GetService('Players'))
local inputService = cloneref(game:GetService('UserInputService'))
local runService = cloneref(game:GetService('RunService'))
-- Used as somewhere to park the character during a reparent, so it is never seen
-- rootless - see Godmode.
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local collectionService = cloneref(game:GetService('CollectionService'))

local gameCamera = workspace.CurrentCamera
local lplr = playersService.LocalPlayer
local vain = shared.vain
local entitylib = vain.Libraries.entity
local targetinfo = vain.Libraries.targetinfo

local function notif(...)
	return vain:CreateNotification(...)
end

-- entitylib only registers players on its own - NPCs exist in its model but nothing
-- puts them there unless a game's base does it. In a dungeon crawler the enemies are
-- the entire point, so without this every module that can target NPCs has nothing to
-- work with here.
--
-- Detection is deliberately structural rather than name based: a model holding a
-- Humanoid, with health, that is not somebody's character. Matching on names would
-- need a list of every enemy type and would break with each content update.
local tracked = {}

local function isEnemy(model)
	if not model:IsA('Model') then return false end
	if playersService:GetPlayerFromCharacter(model) then return false end
	if model == lplr.Character then return false end

	local humanoid = model:FindFirstChildOfClass('Humanoid')
	if not (humanoid and humanoid.Health > 0) then return false end

	-- Humanoid.RootPart rather than a child named HumanoidRootPart: the name is a
	-- convention for player characters, and an NPC rigged any other way has a root
	-- without carrying that name. Requiring the name rejected enemies that were
	-- perfectly usable, which left nothing to farm.
	return humanoid.RootPart ~= nil
end

local function addEnemy(model)
	if tracked[model] or not isEnemy(model) then return end
	tracked[model] = true
	-- No player and no team function, so entitylib marks it NPC and targetable.
	entitylib.addEntity(model, nil, nil)
end

local function removeEnemy(model)
	if not tracked[model] then return end
	tracked[model] = nil
	entitylib.removeEntity(model)
end

run(function()
	for _, model in workspace:GetDescendants() do
		task.spawn(addEnemy, model)
	end

	vain:Clean(workspace.DescendantAdded:Connect(function(obj)
		-- A model is usually parented before its Humanoid arrives, so react to the
		-- Humanoid rather than the model and check upward from there.
		if obj:IsA('Humanoid') and obj.Parent then
			task.spawn(addEnemy, obj.Parent)
		end
	end))

	vain:Clean(workspace.DescendantRemoving:Connect(function(obj)
		if tracked[obj] then
			removeEnemy(obj)
		end
	end))

	vain:Clean(function()
		for model in tracked do
			entitylib.removeEntity(model)
		end
		table.clear(tracked)
	end)
end)

-- Shared between Godmode and AutoFarm. Godmode hides the part the game tracks you by,
-- which also stops your own attacks landing, since the server checks that same position
-- when you swing. So AutoFarm asks for the part to be put back for a moment, waits to be
-- told it has arrived, attacks, and Godmode hides it again.

-- Shared combat helpers.
--
-- These started inside AutoFarm and moved here when a second module needed them. Keeping
-- one copy matters more than it sounds: the ability keys took several attempts to get
-- right, and a duplicated set is one that quietly drifts out of step with the other.

local candidates = {}
local nextScan = 0
local nextAbility = 0
local abilityIndex = 1

local virtualInput = cloneref(game:GetService('VirtualInputManager'))

-- The game's actual ability keys, rather than a spread of guesses. The number row is
-- Roblox's backpack hotbar, so pressing those unequips the weapon rather than casting.
local ABILITY_KEYS = {
	Enum.KeyCode.Q,
	Enum.KeyCode.E
}

local HEALTH_KEYS = {'Health', 'HP', 'CurrentHealth', 'health'}

-- Finds enemies without going through entitylib.
--
-- entitylib only builds an entity when a model has a Humanoid - addEntity waits for one
-- and gives up silently without it. The boss has one, ordinary enemies here evidently do
-- not, which is exactly why the farm worked on the boss and ignored everything else. No
-- amount of widening the base's detection fixes that, because the library itself cannot
-- represent them, so this looks for them directly.
local function rootOf(model)
	if model.PrimaryPart then return model.PrimaryPart end
	for _, name in {'HumanoidRootPart', 'Torso', 'Root', 'UpperTorso', 'Head'} do
		local part = model:FindFirstChild(name)
		if part and part:IsA('BasePart') then return part end
	end
	return model:FindFirstChildWhichIsA('BasePart')
end

-- Something has to say "this is a thing with health", or every crate and door in the
-- dungeon becomes a target.
local function healthOf(model)
	local humanoid = model:FindFirstChildOfClass('Humanoid')
	if humanoid then return humanoid.Health end

	for _, key in HEALTH_KEYS do
		local attr = model:GetAttribute(key)
		if type(attr) == 'number' then return attr end

		local value = model:FindFirstChild(key)
		if value and value:IsA('ValueBase') and type(value.Value) == 'number' then
			return value.Value
		end
	end

	return nil
end

-- Distinct from isEnemy above, which decides what gets registered with entitylib and so
-- insists on a Humanoid. This one decides what is worth attacking, and most enemies here
-- have no Humanoid at all - that difference is the whole reason the farm looks for them
-- itself.
local function isFarmable(model)
	if not model:IsA('Model') then return false end
	if playersService:GetPlayerFromCharacter(model) then return false end
	if model == lplr.Character then return false end

	local health = healthOf(model)
	return health ~= nil and health > 0 and rootOf(model) ~= nil
end

-- Rebuilt on a timer rather than every pass: walking every descendant is far too much to
-- do several times a second, and enemies spawn once a room starts rather than
-- continuously, so a second-old list is fine.
local function rescan()
	if tick() < nextScan then return end
	nextScan = tick() + 1

	table.clear(candidates)
	for _, model in workspace:GetDescendants() do
		if isFarmable(model) then
			table.insert(candidates, model)
		end
	end
end

local function nearestEnemy()
	if not entitylib.isAlive then return nil end
	local origin = entitylib.character.RootPart.Position
	local best, bestRoot, bestDist

	for _, model in candidates do
		-- Re-checked rather than trusted: the list is up to a second old, and most of
		-- what is on it is in the middle of being killed.
		if model.Parent and isFarmable(model) then
			local root = rootOf(model)
			if root then
				local dist = (root.Position - origin).Magnitude
				if not bestDist or dist < bestDist then
					best, bestRoot, bestDist = model, root, dist
				end
			end
		end
	end

	return best, bestRoot
end

-- Nothing swings without something equipped, whatever the weapon is.
local function equipWeapon()
	local character = lplr.Character
	if not character then return end
	if character:FindFirstChildOfClass('Tool') then return end

	local backpack = lplr:FindFirstChildOfClass('Backpack')
	local spare = backpack and backpack:FindFirstChildOfClass('Tool')
	local humanoid = character:FindFirstChildOfClass('Humanoid')
	if spare and humanoid then
		pcall(function()
			humanoid:EquipTool(spare)
		end)
	end
end

local function swing()
	local centre = gameCamera.ViewportSize / 2
	pcall(function()
		virtualInput:SendMouseButtonEvent(centre.X, centre.Y, 0, true, game, 1)
		task.wait()
		virtualInput:SendMouseButtonEvent(centre.X, centre.Y, 0, false, game, 1)
	end)
end

-- Still one key per pass rather than both at once: a game will generally drop all but the
-- first of a burst. With only two keys each comes round twice a second, which is faster
-- than either cooldown, so nothing is held up waiting its turn.
-- Pressed every pass, with no rate limit of its own.
--
-- There is no reading a cooldown from here, but there is no need to: pressing an ability
-- that is still cooling does nothing at all. So the way to cast the moment one comes back
-- is simply to keep asking, and the old quarter second gate only meant an ability could
-- sit ready for a quarter second doing nothing.
--
-- The two keys are still separated by a frame rather than sent together, because a game
-- will generally act on the first of a burst and drop the rest.
local function useAbility()
	for _, key in ABILITY_KEYS do
		pcall(function()
			virtualInput:SendKeyEvent(true, key, false, game)
			task.wait()
			virtualInput:SendKeyEvent(false, key, false, game)
		end)
	end
end


-- Every live enemy, not just the closest. AutoKill uses this to find where several are
-- stood together, so one swing can catch more than one of them.
local function allEnemies()
	local list = {}
	for _, model in candidates do
		-- Re-checked rather than trusted: the list is up to a second old and most of what
		-- is on it is in the middle of being killed.
		if model.Parent and isFarmable(model) then
			local root = rootOf(model)
			if root then
				table.insert(list, root)
			end
		end
	end
	return list
end

-- Re-exported so the modules can share one implementation of each.
vain.Libraries.dungeonquest = {
	isEnemy = isEnemy,
	isFarmable = isFarmable,
	tracked = tracked,
	equipWeapon = equipWeapon,
	swing = swing,
	useAbility = useAbility,
	findEnemy = nearestEnemy,
	allEnemies = allEnemies,
	rescan = rescan,
	rootOf = rootOf,
	combat = {
		hidden = false,
		-- Set by AutoFarm when it wants to attack.
		wantAttack = 0,
		-- Set by Godmode once the surfaced position has had time to replicate.
		attackReady = false,
		-- Set by AutoFarm the moment it sees something on course to hit you, so Godmode
		-- can hide before it lands rather than after. AutoFarm already works this out for
		-- dodging, so it costs nothing to share.
		threat = 0
	}
}
