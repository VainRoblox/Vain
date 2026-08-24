local AutoFarm
local warned = false
local nextAbility = 0
local abilityIndex = 1
local candidates = {}
local nextScan = 0

-- Where to sit relative to the enemy.
--
-- Overhead, and high enough that ground melee cannot reach you - being hit back was
-- killing runs. An earlier version blamed height for swings not landing, but attacks
-- were going through tool:Activate then, which does nothing in this game at all; height
-- was never why they missed. Now that a swing is a real click at the crosshair the limit
-- is the weapon's own range, so height is free and worth taking.
local STAND_OFF = 2
local STAND_UP = 14

-- Attacking through tool:Activate and firetouchinterest does nothing here. That works in
-- games whose damage comes off a touch or off the tool itself; this one runs combat
-- through its own input handlers, which fire its own remotes. Simulating the input lets
-- the game's own code do the rest, and whatever validation it applies is satisfied
-- because these are its own attacks.
local virtualInput = cloneref(game:GetService('VirtualInputManager'))

-- Every key an ability realistically sits on. Pressing an unbound one does nothing, so
-- covering the whole set costs nothing and means no ability is missed for being on a key
-- that was not on a shorter list.
local ABILITY_KEYS = {
	Enum.KeyCode.Q, Enum.KeyCode.E, Enum.KeyCode.R, Enum.KeyCode.F,
	Enum.KeyCode.C, Enum.KeyCode.V, Enum.KeyCode.X, Enum.KeyCode.Z,
	Enum.KeyCode.G, Enum.KeyCode.T,
	Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three,
	Enum.KeyCode.Four, Enum.KeyCode.Five, Enum.KeyCode.Six
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

local function isEnemy(model)
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
		if isEnemy(model) then
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
		if model.Parent and isEnemy(model) then
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

-- One key per pass rather than the whole set at once: a game will generally drop all but
-- the first of a burst, and spacing them lets each cooldown come back round on its own.
local function useAbility()
	if tick() < nextAbility then return end
	nextAbility = tick() + 0.4

	local key = ABILITY_KEYS[abilityIndex]
	abilityIndex = abilityIndex % #ABILITY_KEYS + 1

	pcall(function()
		virtualInput:SendKeyEvent(true, key, false, game)
		task.wait()
		virtualInput:SendKeyEvent(false, key, false, game)
	end)
end

AutoFarm = vain.Categories.Blatant:CreateModule({
	Name = 'AutoFarm',
	Function = function(callback)
		if callback then
			warned = false
			nextAbility = 0
			nextScan = 0
			table.clear(candidates)

			task.spawn(function()
				repeat
					-- Guarded, yielding outside, so one bad pass cannot spin or end the
					-- farm for the session.
					local ok = pcall(function()
						if not entitylib.isAlive then return end

						rescan()
						local enemy, root = nearestEnemy()

						-- Deliberately does nothing when there is nothing to do. An
						-- earlier version returned you to where you switched it on, every
						-- tenth of a second, which pinned you in place whenever nothing
						-- was found. Enemies also only appear once a room starts, so
						-- finding none early on is normal rather than a fault.
						if not enemy then
							if not warned then
								warned = true
								notif('AutoFarm', 'Waiting for enemies to spawn.', 6, 'info')
							end
							return
						end

						warned = false
						equipWeapon()

						local me = entitylib.character.RootPart
						local targetPos = root.Position

						-- Approached from whichever side you are already on, so it does
						-- not drag you through the target every pass.
						local away = me.Position - targetPos
						away = Vector3.new(away.X, 0, away.Z)
						if away.Magnitude < 0.1 then
							local back = me.CFrame.LookVector * -1
							away = Vector3.new(back.X, 0, back.Z)
						end

						local spot = targetPos + (away.Unit * STAND_OFF) + Vector3.new(0, STAND_UP, 0)
						me.CFrame = CFrame.new(spot, targetPos)
						-- Zeroed so hovering above the floor does not turn into a fall.
						me.AssemblyLinearVelocity = Vector3.zero

						-- The camera has to point at the enemy too, not just the
						-- character. A swing is a click at the centre of the screen, so
						-- it hits whatever the camera is looking at - aiming the body
						-- alone left the crosshair wherever the camera happened to be.
						pcall(function()
							gameCamera.CFrame = CFrame.new(gameCamera.CFrame.Position, targetPos)
						end)

						swing()
						useAbility()
					end)

					task.wait(ok and 0.15 or 0.4)
				until not AutoFarm.Enabled
			end)
		end
	end,
	Tooltip = 'Stands next to the nearest enemy, swings whatever is equipped and cycles abilities'
})
