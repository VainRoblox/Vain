local AutoFarm
local warned = false

-- Held above the enemy rather than beside it: standing in the same space shoves you
-- around as it walks, and above keeps swings reaching down onto it.
local OFFSET = Vector3.new(0, 8, 0)

-- Attacks the way universal Killaura does, because it is the one approach that needs no
-- knowledge of the game's own combat code: activate whatever is held, and fire the touch
-- interests on the target so a touch driven hitbox registers.
local function attack(entity)
	local character = lplr.Character
	if not character then return end

	local tool = character:FindFirstChildOfClass('Tool')
	if not tool then return end

	pcall(function()
		tool:Activate()
	end)

	if not firetouchinterest then return end
	local handle = tool:FindFirstChild('Handle')
	if not handle then return end

	for _, part in entity.Character:GetDescendants() do
		if part:IsA('BasePart') then
			pcall(firetouchinterest, handle, part, 0)
			pcall(firetouchinterest, handle, part, 1)
		end
	end
end

AutoFarm = vain.Categories.Blatant:CreateModule({
	Name = 'AutoFarm',
	Function = function(callback)
		if callback then
			warned = false

			task.spawn(function()
				repeat
					-- Guarded, yielding outside, so one bad pass cannot spin or end the
					-- farm for the session.
					local ok = pcall(function()
						if not entitylib.isAlive then return end

						local entity = entitylib.EntityPosition({
							Part = 'RootPart',
							Range = math.huge,
							Players = false,
							NPCs = true
						})

						-- Nothing to do. Deliberately does nothing at all rather than
						-- moving you anywhere: an earlier version returned you to where
						-- you switched it on, which meant that whenever no enemy was
						-- found it teleported you back every tenth of a second and you
						-- could not move at all. Being idle has to look like being idle.
						if not (entity and entity.RootPart) then
							if not warned then
								warned = true
								notif('AutoFarm', 'No enemies found. If there are some in front of you, they are not being detected - send me what the enemy models look like.', 12, 'alert')
							end
							return
						end

						warned = false

						local root = entitylib.character.RootPart
						root.CFrame = CFrame.new(entity.RootPart.Position + OFFSET)
						root.AssemblyLinearVelocity = Vector3.zero

						targetinfo.Targets[entity] = tick() + 1
						attack(entity)
					end)

					task.wait(ok and 0.1 or 0.4)
				until not AutoFarm.Enabled
			end)
		end
	end,
	Tooltip = 'Flies to the nearest enemy and attacks it until the room is clear'
})
