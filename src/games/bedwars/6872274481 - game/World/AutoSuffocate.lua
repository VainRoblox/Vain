local AutoSuffocate
local Targets
local Range
local Walls
local Speed
local LimitItem

-- The game throws away any placement sent inside half its own interval, so nothing
-- quicker than this is worth sending.
local PLACE_CPS = 12
local MIN_SPEED = 1 / PLACE_CPS

-- The four ways out at head height, in block units rather than studs.
local SIDES = {
	Vector3.new(1, 0, 0),
	Vector3.new(-1, 0, 0),
	Vector3.new(0, 0, 1),
	Vector3.new(0, 0, -1)
}
local DOWN = Vector3.new(0, 1, 0)

--[[
	Which block cell a world position sits in, and the middle of a cell in world terms.

	Kept apart on purpose. Stepping to a neighbour by adding studs to a world position and
	snapping afterwards does not work: a block is three studs, so adding two lands back
	inside the cell you started from about a third of the time. Every one of those reads
	as an open side, because the cell the target is standing in is of course empty - which
	is why a boxed in player kept coming back as not boxed in and nothing was ever placed.

	Stepping in cells and converting once at the end cannot land anywhere but the
	neighbour.
]]
local function cellOf(pos)
	return bedwars.BlockController:getBlockPosition(pos)
end

local function worldOf(cell)
	return cell * 3
end

local function heldBlock()
	if store.hand.toolType == 'block' and store.hand.tool then
		return store.hand.tool.Name
	end
	return (not LimitItem.Enabled) and getWool() or nil
end

-- The cells around an entity that are still open, and how boxed in it is.
local function openSides(ent)
	local cell = cellOf(ent.RootPart.Position)
	local open = {}

	for _, side in SIDES do
		local at = worldOf(cell + side)
		if not getPlacedBlock(at) then
			table.insert(open, at)
		end
	end

	return open, cell
end

local function suffocate(ent, item)
	local open, cell = openSides(ent)
	-- Walls is how many sides have to be shut for this to be worth doing, so the rest
	-- are what may still be open.
	if #open > (#SIDES - Walls.Value) then return false end

	-- The head first, since that is the one that actually does it. The remaining ways out
	-- come after, so a target one wall short of boxed in gets shut in rather than ignored.
	local targets = {worldOf(cellOf(ent.Head.Position))}
	for _, v in open do
		table.insert(targets, v)
	end
	table.insert(targets, worldOf(cell - DOWN))

	for _, pos in targets do
		if not getPlacedBlock(pos) then
			bedwars.placeBlock(pos, item)
			return true
		end
	end

	return false
end

AutoSuffocate = vain.Categories.World:CreateModule({
	Name = 'AutoSuffocate',
	Function = function(callback)
		if not callback then return end

		repeat
			local item = heldBlock()
			if item then
				for _, ent in entitylib.AllPosition({
					Part = 'RootPart',
					Range = Range.Value,
					Players = Targets.Players.Enabled,
					NPCs = Targets.NPCs.Enabled,
					Wallcheck = Targets.Walls.Enabled
				}) do
					if not AutoSuffocate.Enabled then break end

					-- Placed one at a time and paced, rather than a spawned call per
					-- target every pass. Several targets at once used to send several
					-- placements in the same frame, and everything past the first was
					-- thrown away for coming in under the game's own rate.
					if suffocate(ent, item) then
						task.wait(Speed.Value)
						item = heldBlock()
						if not item then break end
					end
				end
			end

			task.wait(Speed.Value)
		until not AutoSuffocate.Enabled
	end,
	Tooltip = 'Traps nearby players by placing blocks on them'
})
Targets = AutoSuffocate:CreateTargets({
	Players = true,
	NPCs = true,
	Tooltip = 'Which entities this module is allowed to target'
})
Range = AutoSuffocate:CreateSlider({
	Name = 'Range',
	Tooltip = 'How far this reaches, in studs\nDefault is 20',
	Min = 1,
	Max = 20,
	Default = 20,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
Walls = AutoSuffocate:CreateSlider({
	Name = 'Walls',
	Tooltip = 'Sides that must be shut before acting\nDefault is 3',
	Min = 1,
	Max = 4,
	Default = 3
})
Speed = AutoSuffocate:CreateSlider({
	Name = 'Speed',
	Tooltip = 'Delay between blocks, lower is faster\nGame limit is 12 a second',
	Min = MIN_SPEED,
	Max = 1,
	Default = 0.1,
	Decimal = 100,
	Suffix = 'seconds'
})
LimitItem = AutoSuffocate:CreateToggle({
	Name = 'Limit to Items',
	Tooltip = 'Only acts while holding a block',
	Default = true
})
