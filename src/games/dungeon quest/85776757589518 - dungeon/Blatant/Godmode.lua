local Godmode
local oldroot, clone, hip
local hidden = false
local warned = false

-- Where to keep the detached root. Far enough that nothing in the room reaches it, and
-- upward rather than downward - dropping it under the map risks whatever kill plane the
-- dungeon has.
local HIDE_OFFSET = Vector3.new(0, 2000, 0)

-- Damage aimed at you is worked out from where the server thinks you are, and where the
-- server thinks you are comes from the part it identifies you by - which is yours to
-- move, since you own your own character.
--
-- So the real root is taken out of the character and left in the workspace as a loose
-- part, with a clone put in its place as the PrimaryPart. Your character, camera and
-- movement all run on the clone and behave normally, while the part the game actually
-- tracks sits far above the map where nothing can reach it. This is the same approach
-- that works in bedwars.
--
-- It is not literal invulnerability: anything that damages you without checking position
-- at all - a script that hits everyone in the room, a scripted death - goes straight
-- through it.
local function hide()
	if oldroot and oldroot.Parent then return true end
	if not entitylib.isAlive then return false end

	local character = lplr.Character
	if not (character and character.Parent) then return false end

	local ok = pcall(function()
		local humanoid = character:FindFirstChildOfClass('Humanoid')
		hip = humanoid and humanoid.HipHeight
		oldroot = entitylib.character.RootPart

		-- Moved out of the workspace for the swap so the character is never seen
		-- rootless, which breaks the humanoid outright.
		character.Parent = replicatedStorage
		clone = oldroot:Clone()
		clone.Parent = character
		oldroot.Transparency = 1
		oldroot.Parent = workspace
		character.PrimaryPart = clone
		character.Parent = workspace

		-- entitylib caches the root instance and everything else reads position from it.
		-- Left pointing at the detached part, AutoFarm would be working from a point two
		-- thousand studs up.
		entitylib.character.RootPart = clone
		entitylib.character.HumanoidRootPart = clone
	end)

	if not ok then
		oldroot, clone = nil, nil
		return false
	end
	return true
end

local function restore()
	if not (oldroot and oldroot.Parent) then
		oldroot, clone = nil, nil
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
			local humanoid = lplr.Character and lplr.Character:FindFirstChildOfClass('Humanoid')
			if humanoid and hip then
				humanoid.HipHeight = hip
			end
		end
	end)

	oldroot, clone = nil, nil
	hidden = false
end

Godmode = vain.Categories.Blatant:CreateModule({
	Name = 'Godmode',
	Function = function(callback)
		if callback then
			hidden = false
			warned = false

			-- Held in place every frame, because a loose part left alone simply falls.
			Godmode:Clean(runService.PostSimulation:Connect(function()
				if not (oldroot and oldroot.Parent and clone and clone.Parent) then return end
				oldroot.AssemblyLinearVelocity = Vector3.zero
				oldroot.CFrame = CFrame.new(clone.CFrame.Position + HIDE_OFFSET)
			end))

			Godmode:Clean(entitylib.Events.LocalRemoved:Connect(restore))

			task.spawn(function()
				repeat
					local ok = pcall(function()
						if not entitylib.isAlive then
							restore()
							return
						end

						if hide() and not hidden then
							hidden = true
							if not warned then
								warned = true
								notif('Godmode', 'Hidden. Anything that damages you without checking where you are still applies.', 8, 'info')
							end
						end
					end)

					task.wait(ok and 0.2 or 0.5)
				until not Godmode.Enabled

				restore()
			end)
		else
			restore()
		end
	end,
	Tooltip = 'Moves the part the game hits you by far above the map, so attacks that check your position miss'
})
