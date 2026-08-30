local Nuker
local Range
local BreakSpeed
local UpdateRate
local Angle
local TargetMode
local ViewMode
local Custom
local Bed
local LuckyBlock
local IronOre
local Tesla
local Effect
local CustomHealth = {}
local Animation
local SelfBreak
local InstantBreak
local LimitItem
local AutoTool
local customlist, parts, candidates = {}, {}, {}

-- The route into each thing being dug towards, nearest end first, so a started hole is
-- carried on down rather than abandoned for whatever the mode ranks best on the outer
-- face. One table per target, handed straight to breakBlock and refilled by it.
local tunnel = {}
local breakOptions = {}

-- Ranks used by the Priority target mode, in the order the categories were tried
-- before target modes existed.
local RANK_BED = 1
local RANK_CUSTOM = 2
local RANK_ORE = 3
local RANK_LUCKY = 4
local RANK_TESLA = 5

-- Random has to stay put once it has chosen, or every pass reshuffles and the nuker
-- hops between blocks without ever finishing one. Hashing the position gives an order
-- that is arbitrary but stable, and the salt makes it a different one each time the
-- module is switched on.
local randomSalt = 0

local function randomKey(pos)
	local n = math.sin((pos.X * 12.9898) + (pos.Y * 78.233) + (pos.Z * 37.719) + randomSalt) * 43758.5453
	return n - math.floor(n)
end

local function blockMeta(name)
	local meta = bedwars.ItemMeta[name]
	return meta and meta.block
end

-- Only 4 of the 14 lucky block types carry the 'LuckyBlock' collection tag - purple,
-- halloween, flying, glitched and the rest never get it - so collecting by that tag
-- found nothing in most modes and the toggle looked dead. Every one of them does have
-- a luckyBlock table on its block meta, which is what the game itself tests.
local function isLuckyBlock(name)
	local meta = blockMeta(name)
	return (meta and meta.luckyBlock) ~= nil
end

-- iron_ore is the item you collect; the thing standing in the world is
-- iron_ore_mesh_block. Both are accepted in case a mode places either.
local function isIronOre(name)
	return name == 'iron_ore' or name == 'iron_ore_mesh_block'
end

-- Every setting here is created after CreateModule returns, so all of them can still be
-- nil while this file is executing, and the module can be switched on inside that
-- window when the GUI restores a saved config.
local function wantedBlock(name)
	if Custom and Custom.ListEnabled and table.find(Custom.ListEnabled, name) then return true end
	if IronOre and IronOre.Enabled and isIronOre(name) then return true end
	if LuckyBlock and LuckyBlock.Enabled and isLuckyBlock(name) then return true end
	return false
end

-- The collection is filtered as it is built, so anything that changes what counts has
-- to rebuild it from the block store rather than just flipping a flag.
local function rebuildList()
	if not customlist then return end
	table.clear(customlist)
	for _, obj in store.blocks do
		if wantedBlock(obj.Name) then
			table.insert(customlist, obj)
		end
	end
end

local function customRank(name)
	if Custom and Custom.ListEnabled and table.find(Custom.ListEnabled, name) then return RANK_CUSTOM end
	if isLuckyBlock(name) then return RANK_LUCKY end
	return RANK_ORE
end

-- First person puts the camera inside your own head, so the gap between the camera and
-- the head is what separates the two views. Shiftlock still counts as third person here,
-- which matches what you see on screen.
local function viewAllowed()
	if not ViewMode or ViewMode.Value == 'Both' then return true end
	return bedwars.isFirstPerson() == (ViewMode.Value == 'First Person')
end

--[[
	The healthbar owns everything it draws. It used to borrow BlockBreaker's
	healthbarMaid and healthbarProgressRef, which current builds moved onto a separate
	BlockHealthbar object - so the nil check at the top returned early every single
	time and the custom bar never appeared at all.
]]
local healthbar = {token = 0}

local function clearHealthbar()
	healthbar.token += 1
	if healthbar.mounted then
		pcall(bedwars.Roact.unmount, healthbar.mounted)
	end
	if healthbar.part then
		pcall(function()
			healthbar.part:Destroy()
		end)
	end
	healthbar.mounted, healthbar.part, healthbar.progress, healthbar.position = nil, nil, nil, nil
end

local function mountHealthbar(blockRef, health, maxHealth, block)
	local create = bedwars.Roact.createElement
	local percent = math.clamp(health / maxHealth, 0, 1)
	local meta = bedwars.ItemMeta[block.Name]
	local name = (meta and meta.displayName) or block.Name

	local part = Instance.new('Part')
	part.Size = Vector3.one
	part.CFrame = CFrame.new(bedwars.BlockController:getWorldPosition(blockRef.blockPosition))
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.Parent = workspace
	pcall(function()
		bedwars.QueryUtil:setQueryIgnored(part, true)
	end)

	healthbar.part = part
	healthbar.position = blockRef.blockPosition
	healthbar.progress = bedwars.Roact.createRef()

	healthbar.mounted = bedwars.Roact.mount(create('BillboardGui', {
		Size = UDim2.fromOffset(249, 102),
		StudsOffset = Vector3.new(0, 2.5, 0),
		Adornee = part,
		MaxDistance = 40,
		AlwaysOnTop = true
	}, {
		create('Frame', {
			Size = UDim2.fromOffset(160, 50),
			Position = UDim2.fromOffset(44, 32),
			BackgroundColor3 = Color3.new(),
			BackgroundTransparency = 0.5
		}, {
			create('UICorner', {CornerRadius = UDim.new(0, 5)}),
			create('ImageLabel', {
				Size = UDim2.new(1, 89, 1, 52),
				Position = UDim2.fromOffset(-48, -31),
				BackgroundTransparency = 1,
				Image = getcustomasset('vain/assets/new/blur.png'),
				ScaleType = Enum.ScaleType.Slice,
				SliceCenter = Rect.new(52, 31, 261, 502)
			}),
			create('TextLabel', {
				Size = UDim2.fromOffset(145, 14),
				Position = UDim2.fromOffset(13, 12),
				BackgroundTransparency = 1,
				Text = name,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextColor3 = Color3.new(),
				TextScaled = true,
				Font = Enum.Font.Arial
			}),
			create('TextLabel', {
				Size = UDim2.fromOffset(145, 14),
				Position = UDim2.fromOffset(12, 11),
				BackgroundTransparency = 1,
				Text = name,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextColor3 = color.Dark(uipallet.Text, 0.16),
				TextScaled = true,
				Font = Enum.Font.Arial
			}),
			create('Frame', {
				Size = UDim2.fromOffset(138, 4),
				Position = UDim2.fromOffset(12, 32),
				BackgroundColor3 = uipallet.Main
			}, {
				create('UICorner', {CornerRadius = UDim.new(1, 0)}),
				create('Frame', {
					[bedwars.Roact.Ref] = healthbar.progress,
					Size = UDim2.fromScale(percent, 1),
					BackgroundColor3 = Color3.fromHSV(math.clamp(percent / 2.5, 0, 1), 0.89, 0.75)
				}, {create('UICorner', {CornerRadius = UDim.new(1, 0)})})
			})
		})
	}), part)
end

local function customHealthbar(_, blockRef, health, maxHealth, changeHealth, block)
	if block:GetAttribute('NoHealthbar') or not maxHealth or maxHealth <= 0 then return end

	if not healthbar.part or healthbar.position ~= blockRef.blockPosition then
		clearHealthbar()
		mountHealthbar(blockRef, health, maxHealth, block)
	end

	local progress = healthbar.progress and healthbar.progress:getValue()
	if not progress then return end

	local newpercent = math.clamp((health - changeHealth) / maxHealth, 0, 1)
	tweenService:Create(progress, TweenInfo.new(0.3), {
		Size = UDim2.fromScale(newpercent, 1), BackgroundColor3 = Color3.fromHSV(math.clamp(newpercent / 2.5, 0, 1), 0.89, 0.75)
	}):Play()

	-- The token makes the delayed cleanup drop itself when a newer hit has already
	-- claimed the bar, so it can never take down the bar for the block you moved on to.
	healthbar.token += 1
	local token = healthbar.token
	task.delay(5, function()
		if healthbar.token == token then
			clearHealthbar()
		end
	end)
end

local function gather(list, rank, localPosition)
	if not list then return end
	for _, v in list do
		if not v or not v.Parent then continue end
		-- A block that is a model rather than a part has no Position at all, and one
		-- bad entry used to abort the whole pass before anything got broken.
		local ok, pos = pcall(function()
			return v.Position
		end)
		if not ok or not pos then continue end

		local dist = (pos - localPosition).Magnitude
		if dist >= Range.Value then continue end

		table.insert(candidates, {
			Block = v,
			Position = pos,
			Distance = dist,
			Rank = rank or customRank(v.Name)
		})
	end
end

-- Health scores every opening of a structure, which is a store lookup each, so the
-- answers are held for the length of one pass and dropped with the candidates.
local hitsCache = {}

local function blockHitsAt(node)
	local cached = hitsCache[node]
	if cached then return cached end

	local ok, hits = pcall(function()
		local block = bedwars.getPlacedBlock(node)
		return block and bedwars.getBlockHits(block, node) or nil
	end)
	hits = (ok and hits) or math.huge
	hitsCache[node] = hits
	return hits
end

--[[
	A target mode picks the block that actually gets broken, measured from your
	character - the defences in front of a bed, not the bed sitting behind them. These
	score the openings breakBlock can start at; ranking only the beds and ore left the
	choice of which wall to mine to whichever the pathfinder happened to reach first,
	so standing at one side of a build was no reason for it to break that side.
	node is a world position, cost is the hits to tunnel from there to the target, and
	reach is the distance from your character.
]]
local entryScorers = {
	Nearest = function(_, _, reach)
		return reach
	end,
	Farthest = function(_, _, reach)
		return -reach
	end,
	Health = function(node)
		return blockHitsAt(node)
	end,
	Shortest = function(_, cost)
		return cost
	end,
	Lowest = function(node)
		return node.Y
	end,
	Highest = function(node)
		return -node.Y
	end,
	Random = function(node)
		return randomKey(node)
	end
}

-- What to go for is fixed: beds first, then whatever else is switched on, nearest of
-- each. Which block gets broken on the way in is the target mode's job, and that is
-- decided per opening in entryScorers rather than here.
local function rankCandidates()
	if #candidates < 2 then return end

	table.sort(candidates, function(a, b)
		if a.Rank == b.Rank then return a.Distance < b.Distance end
		return a.Rank < b.Rank
	end)
end

local function attemptBreak()
	for _, entry in candidates do
		local v = entry.Block
		if not v or not v.Parent then continue end

		local ok, isBreakable = pcall(function()
			return bedwars.BlockController:isBlockBreakable({blockPosition = entry.Position / 3}, lplr)
		end)
		if not ok or not isBreakable then continue end

		if not SelfBreak.Enabled and v:GetAttribute('PlacedByUserId') == lplr.UserId then continue end
		if (v:GetAttribute('BedShieldEndTime') or 0) > workspace:GetServerTimeNow() then continue end
		if LimitItem.Enabled then
			local held = store.hand.tool and bedwars.ItemMeta[store.hand.tool.Name]
			if not (held and held.breakBlock) then continue end
		end

		-- pcall succeeding only means nothing threw. breakBlock returns quietly when the
		-- target is out of reach, has no route left, or is one of your own - all of which
		-- used to read as a successful hit, so the pass stopped here and the same
		-- unreachable block was picked again every time. Only a returned block counts.
		local broke = false
		local ok2 = pcall(function()
			-- Self Break has to reach the dig route, not just the target: breakBlock
			-- tunnels towards a block rather than hitting it directly, so with the check
			-- on the target alone every block on the way there got broken regardless.
			local route = tunnel[v]
			if not route then
				route = {}
				tunnel[v] = route
			end

			breakOptions.Range = Range.Value
			breakOptions.Angle = Angle.Value
			breakOptions.Score = entryScorers[TargetMode.Value]
			-- Read on the way in and refilled on the way out, so the route carries from
			-- one hit to the next. A break that never went out leaves it untouched.
			breakOptions.Prefer = route
			breakOptions.Route = route

			local target, path, endpos = bedwars.breakBlock(v, Effect.Enabled, Animation.Enabled, CustomHealth.Enabled and customHealthbar or nil, not SelfBreak.Enabled, AutoTool.Enabled, breakOptions)
			if not target then return end
			broke = true

			if Effect.Enabled and path then
				local currentnode = target
				for _, part in parts do
					part.Position = currentnode or Vector3.zero
					if currentnode then
						part.BoxHandleAdornment.Color3 = currentnode == endpos and Color3.new(1, 0.2, 0.2) or currentnode == target and Color3.new(0.2, 0.2, 1) or Color3.new(0.2, 1, 0.2)
					end
					currentnode = path[currentnode]
				end
			end
		end)
		if ok2 and broke then
			task.wait(InstantBreak.Enabled and (store.damageBlockFail > tick() and 4.5 or 0) or BreakSpeed.Value)
			return true
		end
	end

	return false
end

Nuker = vain.Categories.Minigames:CreateModule({
	Name = 'Nuker',
	Function = function(callback)
		if callback then
			randomSalt = math.random() * 1000

			for _ = 1, 30 do
				local part = Instance.new('Part')
				part.Anchored = true
				part.CanQuery = false
				part.CanCollide = false
				part.Transparency = 1
				part.Parent = gameCamera
				local highlight = Instance.new('BoxHandleAdornment')
				highlight.Size = Vector3.one
				highlight.AlwaysOnTop = true
				highlight.ZIndex = 1
				highlight.Transparency = 0.5
				highlight.Adornee = part
				highlight.Parent = part
				table.insert(parts, part)
			end

			local beds = collection('bed', Nuker)
			-- Teslas carry a real tag, so they are collected rather than name matched.
			-- 'tesla' and 'tesla_trap' are ItemType values, not tags.
			local teslas = collection('tesla-trap', Nuker)
			-- Ore, lucky blocks and anything you list are ordinary blocks named by their
			-- item type, so they come out of the one 'block' collection.
			customlist = collection('block', Nuker, function(tab, obj)
				if wantedBlock(obj.Name) then
					table.insert(tab, obj)
				end
			end)

			repeat
				local ok = pcall(function()
					if not entitylib.isAlive then return end

					if not viewAllowed() then
						for _, v in parts do
							v.Position = Vector3.zero
						end
						return
					end

					local localPosition = entitylib.character.RootPart.Position
					table.clear(candidates)
					table.clear(hitsCache)
					gather(Bed.Enabled and beds, RANK_BED, localPosition)
					gather(customlist, nil, localPosition)
					gather(Tesla.Enabled and teslas, RANK_TESLA, localPosition)
					rankCandidates()

					if attemptBreak() then return end

					for _, v in parts do
						v.Position = Vector3.zero
					end
				end)
				if not ok then
					task.wait(0.5)
				else
					task.wait(1 / UpdateRate.Value)
				end
			until not Nuker.Enabled
		else
			clearHealthbar()
			table.clear(candidates)
			table.clear(hitsCache)
			table.clear(tunnel)
			for _, v in parts do
				v:ClearAllChildren()
				v:Destroy()
			end
			table.clear(parts)
		end
	end,
	Tooltip = 'Breaks blocks around you automatically'
})
TargetMode = Nuker:CreateDropdown({
	Name = 'Target Mode',
	Tooltip = 'Where the way in starts, measured from you',
	Function = function()
		table.clear(tunnel)
	end,
	List = {'Smart', 'Nearest', 'Farthest', 'Health', 'Shortest', 'Lowest', 'Highest', 'Random'},
	Tooltips = {
		Smart = 'Nearest side in, unless it is much thicker',
		Nearest = 'Closest block to you',
		Farthest = 'Furthest block still in range',
		Health = 'Weakest block, your tool counted',
		Shortest = 'Fewest blocks through to the bed',
		Lowest = 'Lowest block first, cuts supports',
		Highest = 'Highest block first',
		Random = 'No fixed order'
	}
})
ViewMode = Nuker:CreateDropdown({
	Name = 'View Mode',
	Tooltip = 'Which camera view this breaks in',
	List = {'Both', 'First Person', 'Third Person'},
	Tooltips = {
		Both = 'Breaks in either view',
		['First Person'] = 'Only while the camera is in your head',
		['Third Person'] = 'Only while the camera is behind you'
	}
})
Range = Nuker:CreateSlider({
	Name = 'Break Range',
	Tooltip = 'How far you can break blocks from\nGame default is 18',
	Min = 1,
	Max = 30,
	Default = 30,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
BreakSpeed = Nuker:CreateSlider({
	Name = 'Break Speed',
	Tooltip = 'Delay between blocks, lower is faster\nGame default is 0.3',
	Min = 0,
	Max = 0.3,
	Default = 0.25,
	Decimal = 100,
	Suffix = 'seconds'
})
Angle = Nuker:CreateSlider({
	Name = 'Angle',
	Tooltip = 'How far from where you are looking a block may be\n180 breaks behind you too',
	Min = 1,
	Max = 180,
	Default = 180,
	Suffix = 'degrees'
})
UpdateRate = Nuker:CreateSlider({
	Name = 'Update Rate',
	Tooltip = 'How often blocks are re-checked\nLower costs less performance',
	Min = 1,
	Max = 120,
	Default = 60,
	Suffix = 'hz'
})
Custom = Nuker:CreateTextList({
	Name = 'Custom',
	Tooltip = 'Extra block names to break',
	Function = rebuildList
})
Bed = Nuker:CreateToggle({
	Name = 'Break Bed',
	Tooltip = 'Breaks beds',
	Default = true
})
LuckyBlock = Nuker:CreateToggle({
	Name = 'Break Lucky Block',
	Tooltip = 'Breaks every lucky block type',
	Default = true,
	Function = rebuildList
})
IronOre = Nuker:CreateToggle({
	Name = 'Break Iron Ore',
	Tooltip = 'Breaks iron ore',
	Default = true,
	Function = rebuildList
})
Tesla = Nuker:CreateToggle({
	Name = 'Break Tesla',
	Tooltip = 'Breaks tesla traps',
	Default = true
})
Effect = Nuker:CreateToggle({
	Name = 'Show Healthbar & Effects',
	Tooltip = 'Shows break progress and particles',
	Function = function(callback)
		if CustomHealth.Object then
			CustomHealth.Object.Visible = callback
		end
		if not callback then
			clearHealthbar()
		end
	end,
	Default = true
})
CustomHealth = Nuker:CreateToggle({
	Name = 'Custom Healthbar',
	Tooltip = 'Uses the Vain healthbar instead of the game one',
	Function = function()
		clearHealthbar()
	end,
	Default = true,
	Darker = true
})
Animation = Nuker:CreateToggle({Name = 'Animation', Tooltip = 'Plays the break animation'})
SelfBreak = Nuker:CreateToggle({Name = 'Self Break', Tooltip = 'Also breaks blocks you placed yourself'})
InstantBreak = Nuker:CreateToggle({Name = 'Instant Break', Tooltip = 'Breaks blocks in a single hit'})
AutoTool = Nuker:CreateToggle({
	Name = 'Auto Tool',
	Tooltip = 'Swaps to the best tool for each block',
	Default = true
})
LimitItem = Nuker:CreateToggle({
	Name = 'Limit to Items',
	Tooltip = 'Only breaks when tools are held'
})
