local BedProtector
local Mode
local Block
local Speed
local Layers
local Range
local Angle
local AutoPatch
local AutoBlock
local LimitItems

-- The game cancels any placement sent inside half of its own interval, so anything
-- quicker than this is thrown away rather than built. That is what made this stop after
-- a handful of blocks: it placed in a tight loop with no wait at all.
local PLACE_CPS = 12
local MIN_SPEED = 1 / PLACE_CPS

-- How many of a cell's six faces must be solid before it counts as a hole in something
-- rather than open air. A gap in a wall keeps its four side neighbours; a cell sitting
-- against the outside of a defence has one.
local MIN_SOLID = 3

local BLOCKS = {
	{Name = 'Wool', Type = 'wool_white'},
	{Name = 'Wood', Type = 'wood_plank_oak'},
	{Name = 'Stone', Type = 'stone_brick'},
	{Name = 'Ceramic', Type = 'ceramic'},
	{Name = 'Obsidian', Type = 'obsidian'}
}

local function getBedNear()
	local localPosition = entitylib.isAlive and entitylib.character.RootPart.Position or Vector3.zero
	for _, v in collectionService:GetTagged('bed') do
		if (localPosition - v.Position).Magnitude < Range.Value and v:GetAttribute('Team'..(lplr:GetAttribute('Team') or -1)..'NoBreak') then
			return v
		end
	end
end

-- Wool is handed out in your team's colour, so the shop's own lookup decides which one
-- that is rather than assuming the white it is listed under.
local function itemTypeFor(name)
	for _, v in BLOCKS do
		if v.Name ~= name then continue end
		if v.Type ~= 'wool_white' then return v.Type end

		local ok, wool = pcall(bedwars.Shop.getTeamWoolById, lplr:GetAttribute('Team'))
		return (ok and wool) or v.Type
	end
end

--[[
	TNT counts as a placeable block as far as the metadata goes, and a soft one at that,
	so it would be reached for first by the weakest-first choice and fallen back to by the
	strongest-first choice once everything else ran out - either way stacking explosives
	against the bed this is supposed to be protecting.

	Matched on the name rather than a list of item types, so the siege and balloon variants
	are covered by the same rule.
]]
local function explosive(itemType)
	return itemType:find('tnt') ~= nil
end

-- Everything placeable you are carrying, toughest first.
local function heldBlocks()
	local blocks = {}
	for _, item in store.inventory.inventory.items do
		local meta = bedwars.ItemMeta[item.itemType]
		if meta and meta.block and not explosive(item.itemType) then
			table.insert(blocks, {Item = item, Health = meta.block.health or 0})
		end
	end
	table.sort(blocks, function(a, b)
		return a.Health > b.Health
	end)
	return blocks
end

--[[
	Which block to build with.

	A named choice is used when you are carrying it and quietly falls back to the toughest
	thing you have when you are not, so running out of obsidian mid patch keeps the hole
	being filled rather than stopping the module dead.
]]
local function chooseBlock()
	local blocks = heldBlocks()
	if #blocks == 0 then return nil end

	if Block.Value == 'Weakest' then return blocks[#blocks].Item end
	if Block.Value ~= 'Strongest' then
		local wanted = itemTypeFor(Block.Value)
		local item = wanted and getItem(wanted)
		if item then return item end
	end

	return blocks[1].Item
end

local function equip(item)
	if not item.tool then return end

	for i, v in store.inventory.hotbar do
		if v.item and v.item.itemType == item.itemType then
			if store.inventory.hotbarSlot ~= i - 1 then
				hotbarSwitch(i - 1)
			end
			break
		end
	end
	switchItem(item.tool)
end

local function holdingBlock()
	local held = store.hand.tool and bedwars.ItemMeta[store.hand.tool.Name]
	return (held and held.block) ~= nil
end

--[[
	Every cell out to `layers` around the bed, nearest first.

	Walked outwards over the six faces from each cell the bed occupies, so a bed lying
	across two positions is wrapped from both halves and the innermost ring is always
	offered before the one outside it.
]]
local function shell(bed, layers)
	local seen, frontier, order = {}, {}, {}
	for _, v in bedwars.getContainedPositions(bed) do
		local pos = v * 3
		seen[pos] = true
		table.insert(frontier, pos)
	end

	for _ = 1, layers do
		local nextfrontier = {}
		for _, pos in frontier do
			for _, side in sides do
				local at = pos + side
				if not seen[at] then
					seen[at] = true
					table.insert(order, at)
					table.insert(nextfrontier, at)
				end
			end
		end
		frontier = nextfrontier
	end
	return order
end

--[[
	A hole in the defence rather than a place to start one.

	This is what makes patching a different job from building. Building fills every empty
	cell around the bed, which out in the open means walling the bed in from scratch.
	Patching only wants the cells that something has been taken out of, so a cell counts
	only when enough of what surrounds it is still standing - the blocks either side of a
	hole somebody has just mined through.
]]
local function isGap(pos)
	local solid = 0
	for _, side in sides do
		if getPlacedBlock(pos + side) then
			solid += 1
			if solid >= MIN_SOLID then return true end
		end
	end
	return false
end

local function inReach(pos)
	if not entitylib.isAlive then return false end
	return (entitylib.character.RootPart.Position - pos).Magnitude <= Range.Value
end

--[[
	Whether a cell sits within the cone you are looking down.

	The setting is the width of that cone, so half of it is the furthest off your view a
	block may sit. A full turn takes in everything, and is not worth resolving the camera
	for at all.
]]
local function inView(pos)
	local half = Angle.Value / 2
	if half >= 180 then return true end

	local camera = workspace.CurrentCamera
	if not camera then return true end

	local dir = pos - camera.CFrame.Position
	if dir.Magnitude == 0 then return true end

	local facing = camera.CFrame.LookVector:Dot(dir.Unit)
	return math.deg(math.acos(math.clamp(facing, -1, 1))) <= half
end

-- One sweep of the bed. Returns whether anything was built, so the caller can tell a
-- finished defence from one it never got near.
local function protect(bed)
	local built = false

	for _, pos in shell(bed, Layers.Value) do
		if not BedProtector.Enabled then break end
		if getPlacedBlock(pos) then continue end
		if not inReach(pos) then continue end
		if not inView(pos) then continue end
		if AutoPatch.Enabled and not isGap(pos) then continue end

		local item = chooseBlock()
		if not item then break end

		if AutoBlock.Enabled then
			equip(item)
		end
		if LimitItems.Enabled and not holdingBlock() then continue end

		bedwars.placeBlock(pos, item.itemType)
		built = true
		task.wait(Speed.Value)
	end

	return built
end

BedProtector = vain.Categories.World:CreateModule({
	Name = 'BedProtector',
	Function = function(callback)
		if not callback then return end

		local once = Mode.Value == 'On Toggle'
		repeat
			local bed = getBedNear()
			if bed then
				-- Only worth saying on a one off run, where nothing happening looks
				-- identical to the module not working.
				if not protect(bed) and once then
					notif('BedProtector', AutoPatch.Enabled and 'No gaps to patch' or 'Nothing to build', 5)
				end
			elseif once then
				notif('BedProtector', 'Unable to locate bed', 5)
			end

			if once then break end
			task.wait(0.1)
		until not BedProtector.Enabled

		-- On Toggle is a one off, so it puts itself away again the way it always did.
		if once and BedProtector.Enabled then
			BedProtector:Toggle()
		end
	end,
	Tooltip = 'Builds blocks around your bed'
})
Mode = BedProtector:CreateDropdown({
	Name = 'Mode',
	Tooltip = 'Whether it keeps going or runs once',
	List = {'Always', 'On Toggle'},
	Tooltips = {
		Always = 'Keeps building while enabled',
		['On Toggle'] = 'Builds once, then turns itself off'
	},
	Function = function()
		if BedProtector.Enabled then
			BedProtector:Toggle()
		end
	end
})
Block = BedProtector:CreateDropdown({
	Name = 'Preferred Block',
	Tooltip = 'Which block to build with',
	List = {'Strongest', 'Weakest', 'Wool', 'Wood', 'Stone', 'Ceramic', 'Obsidian'},
	Tooltips = {
		Strongest = 'Toughest block you are carrying',
		Weakest = 'Softest block you are carrying'
	}
})
Speed = BedProtector:CreateSlider({
	Name = 'Speed',
	Tooltip = 'Delay between blocks, lower is faster\nGame limit is 12 a second',
	Min = MIN_SPEED,
	Max = 1,
	Default = 0.1,
	Decimal = 100,
	Suffix = 'seconds'
})
Layers = BedProtector:CreateSlider({
	Name = 'Layers',
	Tooltip = 'How thick to build\nDefault is 2',
	Min = 1,
	Max = 5,
	Default = 2
})
Range = BedProtector:CreateSlider({
	Name = 'Range',
	Tooltip = 'How far this reaches, in studs\nDefault is 18',
	Min = 1,
	Max = 30,
	Default = 18,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
Angle = BedProtector:CreateSlider({
	Name = 'Angle',
	Tooltip = 'How wide a cone in front of you blocks place in\n360 places behind you too',
	Min = 1,
	Max = 360,
	Default = 360,
	Suffix = 'degrees'
})
AutoPatch = BedProtector:CreateToggle({
	Name = 'Auto Patch',
	Tooltip = 'Only fills holes in the defence'
})
AutoBlock = BedProtector:CreateToggle({
	Name = 'Auto Block',
	Tooltip = 'Holds the block before placing it',
	Default = true
})
LimitItems = BedProtector:CreateToggle({
	Name = 'Limit to Items',
	Tooltip = 'Only builds while holding a block'
})
