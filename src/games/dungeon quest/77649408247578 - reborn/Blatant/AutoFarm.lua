local AutoFarm
local Distance
local Height
local Method
local ReturnHome
local homeCF

-- Attacks the way universal Killaura does, because it is the one approach that needs no
-- knowledge of the game's own combat code: activate whatever is held, and fire the touch
-- interests on the target so a touch-driven hitbox registers. If Dungeon Quest turns out
-- to deal damage through a remote instead, this is the half that will need replacing -
-- the finding, approaching and cycling around it all still hold.
local function attack(entity)
	local character = lplr.Character
	if not character then return end

	local tool = character:FindFirstChildOfClass('Tool')
	if tool then
		pcall(function()
			tool:Activate()
		end)
	end

	if not firetouchinterest then return end

	local handle = tool and tool:FindFirstChild('Handle')
	if not handle then return end

	for _, part in entity.Character:GetDescendants() do
		if part:IsA('BasePart') then
			pcall(firetouchinterest, handle, part, 0)
			pcall(firetouchinterest, handle, part, 1)
		end
	end
end

local function nearestEnemy()
	return entitylib.EntityPosition({
		Part = 'RootPart',
		Range = math.huge,
		Players = false,
		NPCs = true
		-- No Sort: the default already orders by distance, and this field expects a
		-- comparator function rather than a name.
	})
end

AutoFarm = vain.Categories.Blatant:CreateModule({
	Name = 'AutoFarm',
	Function = function(callback)
		if callback then
			homeCF = entitylib.isAlive and entitylib.character.RootPart.CFrame or nil

			task.spawn(function()
				repeat
					-- Wrapped, and yielding outside the guard, so a bad pass cannot spin
					-- and one error does not end the farm for the session.
					local ok = pcall(function()
						if not entitylib.isAlive then return end

						local entity = nearestEnemy()
						if not entity or not entity.RootPart then
							-- Nothing left in the room. Optionally sit still rather than
							-- hovering wherever the last kill happened.
							if ReturnHome.Enabled and homeCF then
								entitylib.character.RootPart.CFrame = homeCF
							end
							return
						end

						local root = entitylib.character.RootPart
						-- Held above and behind rather than inside the target: standing
						-- in the same space tends to push you around, and above keeps
						-- melee swings reaching down onto it.
						local goal = entity.RootPart.CFrame * CFrame.new(0, Height.Value, Distance.Value)

						if Method.Value == 'Teleport' then
							root.CFrame = goal
						else
							-- Walk instead, for anything that objects to being moved in
							-- one step. Slower, and it will not cross gaps.
							local direction = (goal.Position - root.Position)
							if direction.Magnitude > 1 then
								entitylib.character.Humanoid:MoveTo(goal.Position)
							end
						end

						root.AssemblyLinearVelocity = Vector3.zero
						targetinfo.Targets[entity] = tick() + 1
						attack(entity)
					end)

					task.wait(ok and 0.1 or 0.4)
				until not AutoFarm.Enabled

				if ReturnHome.Enabled and homeCF and entitylib.isAlive then
					pcall(function()
						entitylib.character.RootPart.CFrame = homeCF
					end)
				end
			end)
		end
	end,
	Tooltip = 'Finds the nearest enemy, moves to it and attacks until the room is clear'
})
Method = AutoFarm:CreateDropdown({
	Name = 'Method',
	Tooltip = 'How to get to the enemy',
	List = {'Teleport', 'Walk'},
	Tooltips = {
		Teleport = 'Moves you straight there - fast, and the more obvious of the two',
		Walk = 'Walks there instead, which will not cross gaps'
	}
})
Distance = AutoFarm:CreateSlider({
	Name = 'Distance',
	Tooltip = 'How far to sit from the enemy',
	Min = 1,
	Max = 20,
	Default = 6,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
Height = AutoFarm:CreateSlider({
	Name = 'Height',
	Tooltip = 'How far above the enemy to sit\nKeeps you out of its way while staying in melee reach',
	Min = 0,
	Max = 30,
	Default = 8,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
ReturnHome = AutoFarm:CreateToggle({
	Name = 'Return on clear',
	Tooltip = 'Goes back to where you switched this on once nothing is left',
	Default = true
})
