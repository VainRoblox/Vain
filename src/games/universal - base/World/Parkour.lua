local Parkour
local AutoJump
local rayCheck = RaycastParams.new()
rayCheck.RespectCanCollide = true

-- How far ahead to look for something in the way, and how high it may be and still be
-- worth jumping onto. Anything with clear air above that height is a step up; anything
-- solid there is a wall, and jumping at a wall only looks like jumping at a wall.
local REACH = 2.5
local STEP = 4

--[[
	Whether there is a step in front of you that a jump would get you onto.

	Two rays along the way you are moving: one at your feet, one a step above it. Something
	at the lower one with nothing at the upper one is a ledge worth jumping. Both clear
	means open ground, and both blocked means a wall.

	Other players are filtered out along with your own character, so walking into somebody
	is not mistaken for walking into terrain.
]]
local function needsJump()
	local char = entitylib.character
	local root, humanoid = char.RootPart, char.Humanoid

	-- Nothing to climb onto while already in the air, and nothing to walk into while
	-- standing still.
	if humanoid.FloorMaterial == Enum.Material.Air then return false end
	local move = humanoid.MoveDirection
	if move.Magnitude < 0.1 then return false end

	local chars = {gameCamera, lplr.Character}
	for _, v in entitylib.List do
		table.insert(chars, v.Character)
	end
	rayCheck.FilterDescendantsInstances = chars
	rayCheck.CollisionGroup = root.CollisionGroup

	local feet = root.Position - Vector3.new(0, char.HipHeight - 0.5, 0)
	local vec = move.Unit * REACH

	return workspace:Raycast(feet, vec, rayCheck) ~= nil
		and workspace:Raycast(feet + Vector3.new(0, STEP, 0), vec, rayCheck) == nil
end

Parkour = vain.Categories.World:CreateModule({
	Name = 'Parkour',
	Function = function(callback)
		if callback then 
			local oldfloor
			Parkour:Clean(runService.RenderStepped:Connect(function()
				if entitylib.isAlive then 
					local material = entitylib.character.Humanoid.FloorMaterial
					if material == Enum.Material.Air and oldfloor ~= Enum.Material.Air then 
						entitylib.character.Humanoid.Jump = true
					elseif AutoJump.Enabled then
						-- Only worth asking while still on the ground, which the branch
						-- above has already ruled out.
						local ok, jump = pcall(needsJump)
						if ok and jump then
							entitylib.character.Humanoid.Jump = true
						end
					end
					oldfloor = material
				end
			end))
		end
	end,
	Tooltip = 'Automatically jumps after reaching the edge'
})
AutoJump = Parkour:CreateToggle({
	Name = 'Auto Jump',
	Tooltip = 'Also jumps up steps you walk into'
})
