--[[
	Fast Tesla.

	Puts a tesla coil and a block into the same cell, two cells above whatever you are
	standing on or looking at, in a single frame. The cell below it is left empty, so the
	pair sits in the air out of casual melee range with a gap underneath, and the tesla is
	inside the block rather than on top of it.

	Both halves have to leave on the same frame for that to happen: whichever one the
	server registers first owns the cell, and the second is only accepted while it is
	still being treated as empty. That is what the two placers below are for - a
	BlockPlacer drops anything handed to it inside half of its own interval, so firing a
	block and a tesla through one placer loses the second every time. Each gets its own.

	The block engine will not place into a cell with nothing beside it, so the target cell
	needs a neighbour. Two cells up from flat open ground has none, and the gap cell that
	would give it one is where your own legs are - so this works off a wall, a tower or any
	standing structure, and reports the cell as unsupported rather than silently placing
	nothing when it is out in the open.
]]
local FastTesla
local Target
local Height
local Block
local Order
local Attempts
local Range
local Notify

-- A placer drops anything sent inside half of the game's own 12-per-second interval, so
-- a retry has to wait out at least that much to be looked at at all.
local PLACE_CPS = 12
local MIN_SPEED = 1 / PLACE_CPS

-- How long to give the server to tell us what ended up in the cell. Long enough for a
-- round trip on a bad connection, short enough that a failed attempt is not a visible
-- pause before the next one.
local SETTLE = 0.35

-- Cells are 3 studs, so half a cell is the step from a cell's own position to the face
-- between it and the next one along.
local CELL = 3
local HALF = CELL / 2

-- Body height used to decide whether a cell is inside your own character. Taken from the
-- root rather than measured off the parts, since this only decides which of two messages
-- an unsupported cell gets.
local BODY = 5

local BLOCKS = {
	{Name = 'Wool', Match = 'wool'},
	{Name = 'Wood', Match = 'wood_plank_oak'},
	{Name = 'Stone', Match = 'stone_brick'},
	{Name = 'Ceramic', Match = 'ceramic'},
	{Name = 'Obsidian', Match = 'obsidian'}
}

-- The tesla has gone by both of these as an item type; the one you are carrying decides.
local TESLA_TYPES = {'tesla_trap', 'tesla'}

local neighbours = {}
for x = -CELL, CELL, CELL do
	for y = -CELL, CELL, CELL do
		for z = -CELL, CELL, CELL do
			local vec = Vector3.new(x, y, z)
			if vec ~= Vector3.zero then
				table.insert(neighbours, vec)
			end
		end
	end
end

-- Two placers of our own rather than store.blockPlacer, which BedProtector and Scaffold
-- also write their block type into: a placement fired from here while one of those is
-- running would otherwise go out as whatever block that module had just asked for.
local placers = {}

local function getPlacer(index)
	local placer = placers[index]
	if not placer then
		placer = bedwars.BlockPlacer.new(bedwars.BlockEngine, 'wool_white')
		placers[index] = placer
	end
	return placer
end

vain:Clean(function()
	for i, placer in placers do
		pcall(placer.disable, placer)
		table.clear(placer)
		placers[i] = nil
	end
end)

local function up(cells)
	return Vector3.new(0, CELL * cells, 0)
end

local function teslaType()
	for _, itemType in TESLA_TYPES do
		local item = getItem(itemType)
		if item then
			return item.itemType
		end
	end
end

--[[
	TNT carries block metadata and the tesla may well carry it too, so neither can be
	picked up by a toughest-or-softest sweep: one stacks explosives against whatever this
	is defending, and the other would hand back the tesla as its own support block and
	place it twice.
]]
local function supportable(itemType)
	if itemType:find('tnt') then
		return false
	end
	for _, tesla in TESLA_TYPES do
		if itemType == tesla then
			return false
		end
	end
	return bedwars.ItemMeta[itemType] ~= nil and bedwars.ItemMeta[itemType].block ~= nil
end

-- Everything placeable you are carrying that is safe to build with, toughest first.
local function heldBlocks()
	local blocks = {}
	for _, item in store.inventory.inventory.items do
		local itemType = item.itemType
		if supportable(itemType) then
			local meta = bedwars.ItemMeta[itemType].block
			table.insert(blocks, {Type = itemType, Health = meta.health or 0})
		end
	end
	table.sort(blocks, function(a, b)
		return a.Health > b.Health
	end)
	return blocks
end

--[[
	Which block to hide the tesla in.

	A named choice is matched against what you are carrying and falls back to the toughest
	thing you have when it is not there, so asking for obsidian you have run out of still
	gets the tesla buried rather than stopping the module dead. Wool is matched loosely,
	since it is handed out in your team's colour rather than the white it is listed under.
]]
local function chooseBlock()
	local blocks = heldBlocks()
	if #blocks == 0 then
		return nil
	end

	local wanted = Block.Value
	if wanted == 'Weakest' then
		return blocks[#blocks].Type
	end

	if wanted ~= 'Strongest' then
		local match
		for _, v in BLOCKS do
			if v.Name == wanted then
				match = v.Match
				break
			end
		end
		if match then
			for _, v in blocks do
				if v.Type:find(match) then
					return v.Type
				end
			end
		end
	end

	return blocks[1].Type
end

-- Whether the block engine has anything to attach a placement in this cell to.
local function supported(cell)
	for _, side in neighbours do
		if getPlacedBlock(cell + side) then
			return true
		end
	end
	return false
end

--[[
	Whether a cell is inside your own character, which cannot be built into.

	This is what rules out propping the target cell up from below on open ground: the only
	cell that would give it a neighbour is the one your legs are standing in.
]]
local function insideSelf(cell)
	local character = entitylib.character
	local root = character.RootPart
	local feet = root.Position.Y - (character.HipHeight or 2)
	local flat = ((cell - root.Position) * Vector3.new(1, 0, 1)).Magnitude
	return flat < CELL and (cell.Y + HALF) > feet and (cell.Y - HALF) < (feet + BODY)
end

-- Where to build from: the cell you are standing on, or the one you are looking at.
local function baseCell()
	local character = entitylib.character
	local root = character.RootPart

	if Target.Value == 'Aim' then
		local ray = cloneref(lplr:GetMouse()).UnitRay
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = {lplr.Character, gameCamera, vain.gui}
		local hit = workspace:Raycast(ray.Origin, ray.Direction * (Range.Value + CELL), params)
		if not hit then
			return nil
		end
		-- Stepped back along the face that was hit, so this lands in the cell the surface
		-- belongs to rather than the empty one in front of it.
		return roundPos(hit.Position - hit.Normal * HALF)
	end

	return roundPos(root.Position - Vector3.new(0, (character.HipHeight or 2) + HALF, 0))
end

--[[
	The tesla standing in a cell, if there is one.

	Compared as block positions rather than by distance in studs: a tesla is a model's worth
	of parts and the one carrying the tag does not have to sit on the cell's centre, so a
	radius either misses it or reaches into the cell next door. The engine's own rounding
	cannot do either.
]]
local function teslaAt(cell)
	local wanted = bedwars.BlockController:getBlockPosition(cell)
	for _, trap in collectionService:GetTagged('tesla-trap') do
		if trap:IsA('BasePart') and bedwars.BlockController:getBlockPosition(trap.Position) == wanted then
			return trap
		end
	end
end

-- Hands a cell to a placer of its own. Spawned rather than called, so neither half of the
-- pair can be held up by the other yielding on its way out.
local function fire(index, itemType, cell)
	local placer = getPlacer(index)
	placer.blockType = itemType
	task.spawn(placer.placeBlock, placer, bedwars.BlockController:getBlockPosition(cell))
end

local function say(text)
	if Notify.Enabled then
		notif('FastTesla', text, 3)
	end
end

local function deploy()
	if not entitylib.isAlive then
		return say('You are dead')
	end

	local tesla = teslaType()
	if not tesla then
		return say('No tesla')
	end

	local support = chooseBlock()
	if not support then
		return say('No blocks to hide it in')
	end

	local base = baseCell()
	if not base then
		return say('Nothing under your cursor')
	end

	local cell = base + up(Height.Value)
	-- Re-read after baseCell, which raycasts and can yield; the character may be gone.
	if not entitylib.isAlive then
		return say('You are dead')
	end
	if (entitylib.character.RootPart.Position - cell).Magnitude > Range.Value then
		return say('Out of range')
	end
	if getPlacedBlock(cell) then
		return say('Cell is already taken')
	end
	if not supported(cell) then
		return say(insideSelf(cell - up(1)) and 'Nothing to build off, stand on a wall' or 'Nothing to build off')
	end

	local teslaFirst = Order.Value == 'Tesla First'
	for attempt = 1, Attempts.Value do
		-- Re-checked every pass rather than once up front: the wait below is long enough to
		-- die across, and placing from a dead character is how this used to go quiet.
		if not entitylib.isAlive then
			return say('You are dead')
		end

		if teslaFirst then
			fire(1, tesla, cell)
			fire(2, support, cell)
		else
			fire(1, support, cell)
			fire(2, tesla, cell)
		end

		task.wait(SETTLE)
		if teslaAt(cell) then
			-- A tesla that won the cell on its own is the occupant of it, so the block store
			-- having something there is not on its own proof the support block landed. The
			-- two outcomes look different in game - one is a wool cube, the other a coil in
			-- plain sight - so they are not worth reporting as the same thing.
			local occupant = getPlacedBlock(cell)
			local hidden = occupant ~= nil and occupant.Name ~= tesla
			return say(hidden and 'Tesla hidden in a block' or 'Tesla placed, block lost the cell')
		end

		-- Something got there and it was not the tesla, so the cell is gone and firing at
		-- it again can only fail. Worth saying, because the setup looks finished from the
		-- outside - there is a block in the air with nothing inside it.
		if getPlacedBlock(cell) then
			return say('Block won the cell, tesla not placed')
		end

		if attempt < Attempts.Value then
			task.wait(MIN_SPEED)
		end
	end

	say('Nothing was placed')
end

FastTesla = vain.Categories.Utility:CreateModule({
	Name = 'FastTesla',
	Function = function(callback)
		if not callback then
			return
		end
		-- A one off, like the other deploy-on-press modules here: it puts itself away so
		-- the keybind reads as a press rather than something left switched on.
		FastTesla:Toggle()
		deploy()
	end,
	Tooltip = 'Places a tesla inside a block two cells up'
})
Target = FastTesla:CreateDropdown({
	Name = 'Target',
	Tooltip = 'Where to build from',
	List = {'Self', 'Aim'},
	Tooltips = {
		Self = 'The cell you are standing on',
		Aim = 'The cell under your cursor'
	}
})
Height = FastTesla:CreateSlider({
	Name = 'Height',
	Tooltip = 'Cells above the target to place at\nDefault is 2',
	Min = 1,
	Max = 4,
	Default = 2,
	Suffix = function(val)
		return val == 1 and 'cell' or 'cells'
	end
})
Block = FastTesla:CreateDropdown({
	Name = 'Block',
	Tooltip = 'Which block to hide the tesla in',
	List = {'Strongest', 'Weakest', 'Wool', 'Wood', 'Stone', 'Ceramic', 'Obsidian'},
	Tooltips = {
		Strongest = 'Toughest block you are carrying',
		Weakest = 'Softest block you are carrying'
	}
})
Order = FastTesla:CreateDropdown({
	Name = 'Order',
	Tooltip = 'Which half is sent first',
	-- Dropdowns take their starting value from the head of the list rather than a Default,
	-- so the tesla going first is first here: it is the half worth landing, and the block
	-- is only there to cover it.
	List = {'Tesla First', 'Block First'},
	Tooltips = {
		['Tesla First'] = 'Tesla claims the cell, block covers it',
		['Block First'] = 'Block claims the cell, tesla slips in behind it'
	}
})
Attempts = FastTesla:CreateSlider({
	Name = 'Attempts',
	Tooltip = 'How many times to try the pair\nDefault is 3',
	Min = 1,
	Max = 5,
	Default = 3
})
Range = FastTesla:CreateSlider({
	Name = 'Range',
	Tooltip = 'How far this reaches, in studs\nDefault is 18',
	Min = 1,
	Max = 30,
	Default = 18,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
Notify = FastTesla:CreateToggle({
	Name = 'Notify',
	Tooltip = 'Says what happened to each attempt',
	Default = true
})
