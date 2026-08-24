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
vain.Libraries.dungeonquest = {
	isEnemy = isEnemy,
	tracked = tracked,
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
