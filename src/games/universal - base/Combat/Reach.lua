local Reach
local Targets
local Mode
local Value
local Chance
local Overlay = OverlapParams.new()
Overlay.FilterType = Enum.RaycastFilterType.Include
local modified = {}

--[[
	NPCs are found by looking, because nothing registers them.

	entitylib only ever learns about players - it watches PlayerAdded and walks the player
	list, and there is no equivalent for anything else. So the NPC option here matched an
	empty set in every game whose enemies are NPCs, which is most of them: the module looked
	switched on and did nothing at all.

	Rather than have entitylib track every humanoid in the world - expensive, and wrong in
	games with hundreds of them - the parts already being swept for are asked what they
	belong to. A body with a Humanoid that no player owns is an NPC, which costs two lookups
	per part and needs no scanning.
]]
local NPCOverlay = OverlapParams.new()
NPCOverlay.FilterType = Enum.RaycastFilterType.Exclude

local function ownerOf(part)
	local model = part:FindFirstAncestorWhichIsA('Model')
	while model do
		if model:FindFirstChildOfClass('Humanoid') then return model end
		model = model:FindFirstAncestorWhichIsA('Model')
	end
	return nil
end

Reach = vain.Categories.Combat:CreateModule({
	Name = 'Reach',
	Function = function(callback)
		if callback then
			repeat
				local tool = getTool()
				tool = tool and tool:FindFirstChildWhichIsA('TouchTransmitter', true)
				if tool then
					if Mode.Value == 'TouchInterest' then
						local entites = {}
						for _, v in entitylib.List do
							if v.Targetable then
								if not Targets.Players.Enabled and v.Player then continue end
								if not Targets.NPCs.Enabled and v.NPC then continue end
								table.insert(entites, v.Character)
							end
						end

						local reachCF = tool.Parent.CFrame * CFrame.new(0, 0, Value.Value / 2)
						local reachSize = tool.Parent.Size + Vector3.new(0, 0, Value.Value)

						Overlay.FilterDescendantsInstances = entites
						local parts = workspace:GetPartBoundsInBox(reachCF, reachSize, Overlay)

						--[[
							Anything with a Humanoid that entitylib never heard of.

							Swept separately from the entity list so the team checks and
							targeting rules above still decide who counts among players, while
							the bodies nothing registers - mobs, bosses, summons - are picked
							up by what is physically in reach.
						]]
						if Targets.NPCs.Enabled then
							local own = entitylib.character and entitylib.character.Character or lplr.Character
							NPCOverlay.FilterDescendantsInstances = { own }

							local seen = {}
							for _, part in parts do seen[part] = true end

							for _, part in workspace:GetPartBoundsInBox(reachCF, reachSize, NPCOverlay) do
								if not seen[part] then
									local body = ownerOf(part)
									if body and not playersService:GetPlayerFromCharacter(body) then
										local humanoid = body:FindFirstChildOfClass('Humanoid')
										if humanoid and humanoid.Health > 0 then
											seen[part] = true
											table.insert(parts, part)
										end
									end
								end
							end
						end

						for _, v in parts do
							if Random.new().NextNumber(Random.new(), 0, 100) > Chance.Value then
								task.wait(0.2)
								break
							end

							firetouchinterest(tool.Parent, v, 1)
							firetouchinterest(tool.Parent, v, 0)
						end
					else
						if not modified[tool.Parent] then
							modified[tool.Parent] = tool.Parent.Size
						end

						tool.Parent.Size = modified[tool.Parent] + Vector3.new(0, 0, Value.Value)
						tool.Parent.Massless = true
					end
				end

				task.wait()
			until not Reach.Enabled
		else
			for i, v in modified do
				i.Size = v
				i.Massless = false
			end
			table.clear(modified)
		end
	end,
	Tooltip = 'Extends tool attack reach'
})
-- NPCs on by default: in most games with them, they are what you are hitting.
Targets = Reach:CreateTargets({Players = true, NPCs = true})
Mode = Reach:CreateDropdown({
	Name = 'Mode',
	List = {'TouchInterest', 'Resize'},
	Function = function(val)
		Chance.Object.Visible = val == 'TouchInterest'
	end,
	Tooltip = 'TouchInterest - Reports fake collision events to the server\nResize - Physically modifies the tools size'
})
Value = Reach:CreateSlider({
	Name = 'Range',
	Min = 0,
	Max = 2,
	Decimal = 10,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
Chance = Reach:CreateSlider({
	Name = 'Chance',
	Min = 0,
	Max = 100,
	Default = 100,
	Suffix = '%'
})