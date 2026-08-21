-- Stops melee landing on you by moving the part the server tracks you by, rather than
-- by trying to spoof where your character is.
--
-- Spoofing position cannot work: replication is one channel, so an offset moves the
-- server's copy of you and every attacker's copy together - their sword query finds you
-- at the offset, they swing there, the server agrees. And an offset large enough to
-- clear sword reach is large enough for the character movement checks to correct, which
-- is the lagback.
--
-- This sidesteps both. The real HumanoidRootPart is taken out of the character and left
-- in the workspace as a loose part you still own, with a clone put in its place as the
-- character's PrimaryPart. Your character, camera and movement all run on the clone and
-- behave completely normally, while the real root - which is the instance the entity
-- system and hit detection identify you by - is dragged below the map. Character
-- movement validation does not apply to it, because as far as the game is concerned it
-- is no longer part of your character.
--
-- Derived from the Anti Hit module in the older VainV6 client.
local AntiMelee
local Targets
local Range
local oldroot, clone, hip
local dodging = false
local lowestPoint = -math.huge
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include
rayParams.RespectCanCollide = true

-- Your own attacks are validated against the server's copy of you, which is the root
-- being held below the map - so a swing sent while dodging is rejected. The original
-- ran a blind 0.2s on / 0.4s off cycle to leave gaps for its own hits. Keying it to
-- actual swings instead means far more dodge uptime and the gap lands exactly when it
-- is needed.
local ATTACK_GRACE = 0.25

local function swinging()
	local controller = bedwars.SwordController
	if not controller then return false end
	if tick() - (controller.lastSwing or 0) < ATTACK_GRACE then return true end
	return workspace:GetServerTimeNow() - (controller.lastAttack or 0) < ATTACK_GRACE
end

local function detach()
	if oldroot and oldroot.Parent then return true end
	if not entitylib.isAlive then return false end

	local character = lplr.Character
	if not (character and character.Parent) then return false end

	local ok = pcall(function()
		hip = entitylib.character.Humanoid.HipHeight
		oldroot = entitylib.character.RootPart

		-- Reparented out of the workspace for the swap so the character is never seen
		-- rootless, which would otherwise break the humanoid outright.
		character.Parent = replicatedStorage
		clone = oldroot:Clone()
		clone.Parent = character
		oldroot.Transparency = 1
		oldroot.Parent = workspace
		character.PrimaryPart = clone
		character.Parent = workspace

		pcall(function()
			bedwars.QueryUtil:setQueryIgnored(clone, true)
			bedwars.QueryUtil:setQueryIgnored(oldroot, true)
		end)

		-- entitylib caches the root instance, and every other module reads position from
		-- it. Left pointing at the detached part they would all be working from a point
		-- under the map, so they are repointed at the clone - which is where you are.
		entitylib.character.RootPart = clone
		entitylib.character.HumanoidRootPart = clone
		store.rootpart = oldroot
	end)

	if not ok then
		oldroot, clone = nil, nil
		return false
	end
	return true
end

local function reattach()
	if not (oldroot and oldroot.Parent) then
		oldroot, clone, store.rootpart = nil, nil, nil
		return
	end

	pcall(function()
		local character = lplr.Character
		if character and character.Parent then
			character.Parent = replicatedStorage
			oldroot.Parent = character
			if clone then
				oldroot.CFrame = clone.CFrame
				oldroot.Velocity = clone.Velocity
				clone:Destroy()
			end
			character.PrimaryPart = oldroot
			character.Parent = workspace
		end

		oldroot.CanCollide = true
		oldroot.Transparency = 1

		if entitylib.isAlive then
			entitylib.character.RootPart = oldroot
			entitylib.character.HumanoidRootPart = oldroot
			entitylib.character.Humanoid.HipHeight = hip or 2.6
		end
	end)

	oldroot, clone, store.rootpart = nil, nil, nil
	dodging = false
end

AntiMelee = vain.Categories.Utility:CreateModule({
	Name = 'AntiMelee',
	Function = function(callback)
		if callback then
			dodging = false

			-- Far enough under the lowest block that nothing can reach it. Recomputed on
			-- enable rather than cached across rounds, since the map changes.
			lowestPoint = -math.huge
			pcall(function()
				for _, v in store.blocks do
					local point = (v.Position.Y - (v.Size.Y / 2)) - 50
					if point < lowestPoint or lowestPoint == -math.huge then
						lowestPoint = point
					end
				end
			end)
			if lowestPoint == -math.huge then lowestPoint = -200 end

			-- Looked up rather than indexed, and refreshed in the loop below: workspace.Map
			-- does not exist yet in the lobby, and without it the raycast has nothing to
			-- hit, which would leave the module permanently unable to find a safe spot.
			local function refreshMap()
				local map = workspace:FindFirstChild('Map')
				rayParams.FilterDescendantsInstances = map and {map} or {}
				return map ~= nil
			end
			refreshMap()

			-- PostSimulation, so the position is written after the engine has finished
			-- moving things and is what actually gets replicated.
			AntiMelee:Clean(runService.PostSimulation:Connect(function()
				if not (oldroot and oldroot.Parent and clone and clone.Parent) then return end

				if dodging then
					-- Parking the root at a fixed depth buries it inside whatever geometry
					-- happens to be there, and the game damages you for having your tracked
					-- position inside a block - that is the suffocation. Casting up from
					-- below the map finds the underside of the nearest thing above, and
					-- sitting just beneath that keeps the root in open air. If nothing is
					-- found there is no known-safe spot, so it stops dodging rather than
					-- guessing and killing you.
					local basePos = Vector3.new(clone.CFrame.X, lowestPoint - 6, clone.CFrame.Z)
					local hit = workspace:Raycast(basePos, Vector3.new(0, 1000, 0), rayParams)
					if not hit then
						oldroot.Velocity = Vector3.zero
						oldroot.CFrame = clone.CFrame
						return
					end

					oldroot.Velocity = Vector3.zero
					oldroot.CFrame = CFrame.new(basePos.X, hit.Position.Y - 6, basePos.Z)
						* CFrame.Angles(math.rad(90), 0, 0)
				else
					-- Parked on the clone while not dodging, so your own hits and anything
					-- else reading the root line up with where you actually are.
					oldroot.Velocity = Vector3.zero
					oldroot.CFrame = clone.CFrame
				end
			end))

			AntiMelee:Clean(entitylib.Events.LocalRemoved:Connect(reattach))

			repeat
				local ok = pcall(function()
					if not entitylib.isAlive then
						reattach()
						return
					end

					-- Only meaningful where the executor actually implements it; it is
					-- stubbed to true elsewhere in this client. When it does report a loss
					-- the part is no longer ours to move, so put it back.
					if oldroot and not isnetworkowner(oldroot) then
						reattach()
						return
					end

					refreshMap()

					local near = entitylib.EntityPosition({
						Range = Range.Value,
						Players = Targets.Players.Enabled,
						NPCs = Targets.NPCs.Enabled,
						Wallcheck = Targets.Walls.Enabled or nil,
						Sort = sortmethods.Distance,
						Part = 'RootPart'
					})

					if near and detach() then
						dodging = not swinging()
					else
						reattach()
					end
				end)

				task.wait(ok and 0.03 or 0.25)
			until not AntiMelee.Enabled

			reattach()
		else
			reattach()
		end
	end,
	Tooltip = 'Moves the part the server hits you by out of your character\nStands down for a moment around your own swings so your hits still land'
})
Targets = AntiMelee:CreateTargets({
	Players = true,
	Tooltip = 'Which entities this reacts to'
})
Range = AntiMelee:CreateSlider({
	Name = 'Range',
	Tooltip = 'How close someone has to be before this engages',
	Min = 1,
	Max = 30,
	Default = 20,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
