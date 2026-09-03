local run = function(func)
	func()
end
local cloneref = cloneref or function(obj)
	return obj
end
local vainEvents = setmetatable({}, {
	__index = function(self, index)
		self[index] = Instance.new('BindableEvent')
		return self[index]
	end
})

local playersService = cloneref(game:GetService('Players'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local runService = cloneref(game:GetService('RunService'))
local inputService = cloneref(game:GetService('UserInputService'))
local tweenService = cloneref(game:GetService('TweenService'))
local httpService = cloneref(game:GetService('HttpService'))
local textChatService = cloneref(game:GetService('TextChatService'))
local collectionService = cloneref(game:GetService('CollectionService'))
local contextActionService = cloneref(game:GetService('ContextActionService'))
local guiService = cloneref(game:GetService('GuiService'))
local coreGui = cloneref(game:GetService('CoreGui'))
local starterGui = cloneref(game:GetService('StarterGui'))

local isnetworkowner = identifyexecutor and table.find({'AWP', 'Nihon'}, ({identifyexecutor()})[1]) and isnetworkowner or function()
	return true
end
local gameCamera = workspace.CurrentCamera
local lplr = playersService.LocalPlayer
local assetfunction = getcustomasset

local vain = shared.vain

-- Profiles key everything by name, so a rename would otherwise silently reset whatever
-- was saved under the old one. These are consulted only when the saved name matches
-- nothing, so a name still in use by another game is never redirected.
vain.Renames = vain.Renames or {Modules = {}, Options = {}}
for old, new in {
	Breaker = 'Nuker',
	['Better Spectating'] = 'BetterSpectating',
	AutoAdetunde = 'Adetunde',
	-- Davey Aim and Auto Davey were merged into one module, so a config saved under either
	-- old name carries its settings across rather than resetting them.
	-- The Davey modules were reshuffled and then renamed to match the spacing every other
	-- module uses, so a config saved under any of the older names still loads.
	['Auto Davey'] = 'PirateDavey',
	['Pirate Davey'] = 'PirateDavey',
	['Davey Aim'] = 'DaveyAim'
} do
	vain.Renames.Modules[old] = new
end
for old, new in {
	['Break range'] = 'Break Range',
	['Break speed'] = 'Break Speed',
	['Update rate'] = 'Update Rate',
	['Limit to items'] = 'Limit to Items',
	Quantity = 'Show Amount',
	['Full Layers'] = 'Highlight Full Layers',
	Camera = 'View Mode',
	['Camera Mode'] = 'View Mode'
} do
	vain.Renames.Options[old] = new
end

local entitylib = vain.Libraries.entity
local targetinfo = vain.Libraries.targetinfo
local sessioninfo = vain.Libraries.sessioninfo
local uipallet = vain.Libraries.uipallet
local tween = vain.Libraries.tween
local color = vain.Libraries.color
local whitelist = vain.Libraries.whitelist
local prediction = vain.Libraries.prediction
local getfontsize = vain.Libraries.getfontsize
local getcustomasset = vain.Libraries.getcustomasset

-- Kit modules are bedwars-only, so the category is created here rather than in the
-- shared GUI file - creating it there put an empty Kit tab in front of every other
-- game. The icon is borrowed from the combat one and is wrapped because asset paths
-- are per-GUI: a GUI without that file should cost us the icon, not the category.
if not vain.Categories.Kit then
	local icon = select(2, pcall(getcustomasset, 'vain/assets/new/combaticon.png'))
	vain:CreateCategory({
		Name = 'Kit',
		Icon = type(icon) == 'string' and icon or nil,
		Size = UDim2.fromOffset(13, 14)
	})
end

local store = {
	attackReach = 0,
	attackReachUpdate = tick(),
	damageBlockFail = tick(),
	hand = {},
	inventory = {
		inventory = {
			items = {},
			armor = {}
		},
		hotbar = {}
	},
	inventories = {},
	matchState = 0,
	queueType = 'bedwars_test',
	tools = {}
}
local Reach = {}
local HitBoxes = {}
local InfiniteFly = {}
local TrapDisabler
local AntiFallPart
local bedwars, remotes, sides, oldinvrender, oldSwing = {}, {}, {}

local function addBlur(parent)
	local blur = Instance.new('ImageLabel')
	blur.Name = 'Blur'
	blur.Size = UDim2.new(1, 89, 1, 52)
	blur.Position = UDim2.fromOffset(-48, -31)
	blur.BackgroundTransparency = 1
	blur.Image = getcustomasset('vain/assets/new/blur.png')
	blur.ScaleType = Enum.ScaleType.Slice
	blur.SliceCenter = Rect.new(52, 31, 261, 502)
	blur.Parent = parent
	return blur
end

local function collection(tags, module, customadd, customremove)
	tags = typeof(tags) ~= 'table' and {tags} or tags
	local objs, connections = {}, {}

	for _, tag in tags do
		table.insert(connections, collectionService:GetInstanceAddedSignal(tag):Connect(function(v)
			if customadd then
				customadd(objs, v, tag)
				return
			end
			table.insert(objs, v)
		end))
		table.insert(connections, collectionService:GetInstanceRemovedSignal(tag):Connect(function(v)
			if customremove then
				customremove(objs, v, tag)
				return
			end
			v = table.find(objs, v)
			if v then
				table.remove(objs, v)
			end
		end))

		for _, v in collectionService:GetTagged(tag) do
			if customadd then
				customadd(objs, v, tag)
				continue
			end
			table.insert(objs, v)
		end
	end

	local cleanFunc = function(self)
		for _, v in connections do
			v:Disconnect()
		end
		table.clear(connections)
		table.clear(objs)
		table.clear(self)
	end
	if module then
		module:Clean(cleanFunc)
	end
	return objs, cleanFunc
end

local function getBestArmor(slot)
	local closest, mag = nil, 0

	for _, item in store.inventory.inventory.items do
		local meta = item and bedwars.ItemMeta[item.itemType] or {}

		if meta.armor and meta.armor.slot == slot then
			local newmag = (meta.armor.damageReductionMultiplier or 0)

			if newmag > mag then
				closest, mag = item, newmag
			end
		end
	end

	return closest
end

local function getBow()
	local bestBow, bestBowSlot, bestBowDamage = nil, nil, 0
	for slot, item in store.inventory.inventory.items do
		local bowMeta = bedwars.ItemMeta[item.itemType].projectileSource
		if bowMeta and table.find(bowMeta.ammoItemTypes, 'arrow') then
			local bowDamage = bedwars.ProjectileMeta[bowMeta.projectileType('arrow')].combat.damage or 0
			if bowDamage > bestBowDamage then
				bestBow, bestBowSlot, bestBowDamage = item, slot, bowDamage
			end
		end
	end
	return bestBow, bestBowSlot
end

local function getItem(itemName, inv)
	for slot, item in (inv or store.inventory.inventory.items) do
		if item.itemType == itemName then
			return item, slot
		end
	end
	return nil
end

local function getRoactRender(func)
	return debug.getupvalue(debug.getupvalue(debug.getupvalue(func, 3).render, 2).render, 1)
end

local function getSword()
	local bestSword, bestSwordSlot, bestSwordDamage = nil, nil, 0
	for slot, item in store.inventory.inventory.items do
		local swordMeta = bedwars.ItemMeta[item.itemType].sword
		if swordMeta then
			local swordDamage = swordMeta.damage or 0
			if swordDamage > bestSwordDamage then
				bestSword, bestSwordSlot, bestSwordDamage = item, slot, swordDamage
			end
		end
	end
	return bestSword, bestSwordSlot
end

local function getTool(breakType)
	local bestTool, bestToolSlot, bestToolDamage = nil, nil, 0
	for slot, item in store.inventory.inventory.items do
		local toolMeta = bedwars.ItemMeta[item.itemType].breakBlock
		if toolMeta then
			local toolDamage = toolMeta[breakType] or 0
			if toolDamage > bestToolDamage then
				bestTool, bestToolSlot, bestToolDamage = item, slot, toolDamage
			end
		end
	end
	return bestTool, bestToolSlot
end

local function getWool()
	for _, wool in (inv or store.inventory.inventory.items) do
		if wool.itemType:find('wool') then
			return wool and wool.itemType, wool and wool.amount
		end
	end
end

-- Finds the index of the upvalue holding `value` in `func`, instead of hardcoding one.
-- Upvalue positions shift whenever the game adds or removes a local in the enclosing
-- scope, which silently turns a hooking module into one that corrupts an unrelated
-- upvalue - e.g. writing over the game's Players reference instead of KnitClient.
-- Returns nil when it isn't there, so callers can skip rather than clobber.
local function findUpvalue(func, value)
	if type(func) ~= 'function' then return nil end
	for i = 1, 40 do
		local suc, up = pcall(debug.getupvalue, func, i)
		if not suc then break end
		if up == value then return i end
	end
	return nil
end

-- Same idea for constants.
local function findConstant(func, value)
	if type(func) ~= 'function' then return nil end
	local suc, constants = pcall(debug.getconstants, func)
	if not suc or not constants then return nil end
	for i, v in constants do
		if v == value then return i end
	end
	return nil
end

-- Swaps a constant by value rather than by position. Modules use this to neuter a
-- specific check inside a game function (e.g. renaming the key it looks up so the
-- lookup misses) and to put it back afterwards. Returns false when the value isn't
-- there, which is the signal that the game changed and the hook should be skipped
-- instead of writing over whatever happens to sit at a hardcoded index.
local function swapConstant(func, from, to)
	local ind = findConstant(func, from)
	if not ind then return false end
	local suc = pcall(debug.setconstant, func, ind, to)
	return suc
end

local function getStrength(plr)
	if not plr.Player then
		return 0
	end

	local strength = 0
	for _, v in (store.inventories[plr.Player] or {items = {}}).items do
		local itemmeta = bedwars.ItemMeta[v.itemType]
		if itemmeta and itemmeta.sword and itemmeta.sword.damage > strength then
			strength = itemmeta.sword.damage
		end
	end

	return strength
end

local function getPlacedBlock(pos)
	if not pos then
		return
	end
	local roundedPosition = bedwars.BlockController:getBlockPosition(pos)
	return bedwars.BlockController:getStore():getBlockAt(roundedPosition), roundedPosition
end

local function getBlocksInPoints(s, e)
	local blocks, list = bedwars.BlockController:getStore(), {}
	for x = s.X, e.X do
		for y = s.Y, e.Y do
			for z = s.Z, e.Z do
				local vec = Vector3.new(x, y, z)
				if blocks:getBlockAt(vec) then
					table.insert(list, vec * 3)
				end
			end
		end
	end
	return list
end

local function getNearGround(range)
	range = Vector3.new(3, 3, 3) * (range or 10)
	local localPosition, mag, closest = entitylib.character.RootPart.Position, 60
	local blocks = getBlocksInPoints(bedwars.BlockController:getBlockPosition(localPosition - range), bedwars.BlockController:getBlockPosition(localPosition + range))

	for _, v in blocks do
		if not getPlacedBlock(v + Vector3.new(0, 3, 0)) then
			local newmag = (localPosition - v).Magnitude
			if newmag < mag then
				mag, closest = newmag, v + Vector3.new(0, 3, 0)
			end
		end
	end

	table.clear(blocks)
	return closest
end

local function getShieldAttribute(char)
	local returned = 0
	for name, val in char:GetAttributes() do
		if name:find('Shield') and type(val) == 'number' and val > 0 then
			returned += val
		end
	end
	return returned
end

local function getSpeed()
	local multi, increase, modifiers = 0, true, bedwars.SprintController:getMovementStatusModifier():getModifiers()

	for v in modifiers do
		local val = v.constantSpeedMultiplier and v.constantSpeedMultiplier or 0
		if val and val > math.max(multi, 1) then
			increase = false
			multi = val - (0.06 * math.round(val))
		end
	end

	for v in modifiers do
		multi += math.max((v.moveSpeedMultiplier or 0) - 1, 0)
	end

	if multi > 0 and increase then
		multi += 0.16 + (0.02 * math.round(multi))
	end

	return 20 * (multi + 1)
end

local function getTableSize(tab)
	local ind = 0
	for _ in tab do
		ind += 1
	end
	return ind
end

local function hotbarSwitch(slot)
	if slot and store.inventory.hotbarSlot ~= slot then
		bedwars.Store:dispatch({
			type = 'InventorySelectHotbarSlot',
			slot = slot
		})
		vainEvents.InventoryChanged.Event:Wait()
		return true
	end
	return false
end

local function isFriend(plr, recolor)
	if vain.Categories.Friends.Options['Use friends'].Enabled then
		local friend = table.find(vain.Categories.Friends.ListEnabled, plr.Name) and true
		if recolor then
			friend = friend and vain.Categories.Friends.Options['Recolor visuals'].Enabled
		end
		return friend
	end
	return nil
end

local function isTarget(plr)
	return table.find(vain.Categories.Targets.ListEnabled, plr.Name) and true
end

local function notif(...) return
	vain:CreateNotification(...)
end

local function removeTags(str)
	str = str:gsub('<br%s*/>', '\n')
	return (str:gsub('<[^<>]->', ''))
end

local function roundPos(vec)
	return Vector3.new(math.round(vec.X / 3) * 3, math.round(vec.Y / 3) * 3, math.round(vec.Z / 3) * 3)
end

local function switchItem(tool, delayTime)
	delayTime = delayTime or 0.05
	local check = lplr.Character and lplr.Character:FindFirstChild('HandInvItem') or nil
	if check and check.Value ~= tool and tool.Parent ~= nil then
		task.spawn(function()
			bedwars.Client:Get(remotes.EquipItem):CallServerAsync({hand = tool})
		end)
		check.Value = tool
		if delayTime > 0 then
			task.wait(delayTime)
		end
		return true
	end
end

local function waitForChildOfType(obj, name, timeout, prop)
	local check, returned = tick() + timeout
	repeat
		returned = prop and obj[name] or obj:FindFirstChildOfClass(name)
		if returned and returned.Name ~= 'UpperTorso' or check < tick() then
			break
		end
		task.wait()
	until false
	return returned
end

local frictionTable, oldfrict = {}, {}
local frictionConnection
local frictionState

local function modifyVelocity(v)
	if v:IsA('BasePart') and v.Name ~= 'HumanoidRootPart' and not oldfrict[v] then
		oldfrict[v] = v.CustomPhysicalProperties or 'none'
		v.CustomPhysicalProperties = PhysicalProperties.new(0.0001, 0.2, 0.5, 1, 1)
	end
end

local function updateVelocity(force)
	local newState = getTableSize(frictionTable) > 0
	if frictionState ~= newState or force then
		if frictionConnection then
			frictionConnection:Disconnect()
		end
		if newState then
			if entitylib.isAlive then
				for _, v in entitylib.character.Character:GetDescendants() do
					modifyVelocity(v)
				end
				frictionConnection = entitylib.character.Character.DescendantAdded:Connect(modifyVelocity)
			end
		else
			for i, v in oldfrict do
				i.CustomPhysicalProperties = v ~= 'none' and v or nil
			end
			table.clear(oldfrict)
		end
	end
	frictionState = newState
end

local kitorder = {
	hannah = 5,
	spirit_assassin = 4,
	dasher = 3,
	jade = 2,
	regent = 1
}

-- Team ids whose bed has been destroyed this match, so the 'Final Kill' target mode can
-- tell who respawns from who is gone for good. Filled from the BedwarsBedBreak event
-- (see the event wiring below) and cleared when a match ends.
local brokenbeds = {}

-- Total damage reduction from everything the player is wearing. Mirrors getStrength,
-- but reads the armor list instead of held swords, so it answers "who dies fastest".
local function getArmor(plr)
	if not plr.Player then
		return 0
	end

	local armor = 0
	for _, v in (store.inventories[plr.Player] or {armor = {}}).armor do
		local itemmeta = bedwars.ItemMeta[v.itemType]
		if itemmeta and itemmeta.armor then
			armor += itemmeta.armor.damageReductionMultiplier or 0
		end
	end

	return armor
end

-- Screen-space distance from the cursor. Entities behind the camera get pushed to the
-- back rather than wrapping around to the front - WorldToViewportPoint still returns
-- coordinates for those, so without the visibility check someone directly behind you
-- could out-rank the player you are actually looking at.
local function getCursorDistance(ent)
	local position, visible = gameCamera:WorldToViewportPoint(ent.RootPart.Position)
	if not visible then
		return math.huge
	end

	local mouse = inputService.TouchEnabled and gameCamera.ViewportSize / 2 or inputService:GetMouseLocation()
	return (mouse - Vector2.new(position.X, position.Y)).Magnitude
end

-- Shown when hovering an individual Target Mode option. Keys match sortmethods plus
-- 'Distance', which is not in that table because it is the default magnitude ordering.
local sortmethodtips = {
	Distance = 'Whoever is physically closest to you',
	Damage = 'Whoever damaged you most recently',
	Angle = 'Whoever is nearest the direction you are already facing',
	Cursor = 'Whoever is nearest your crosshair on screen',
	Armor = 'Whoever is wearing the weakest armor',
	Health = 'Whoever has the lowest health',
	Threat = 'Whoever is holding the strongest sword',
	Kit = 'Whoever is playing the most dangerous kit',
	['Final Kill'] = 'Players whose bed is already broken'
}

local sortmethods = {
	Damage = function(a, b)
		return a.Entity.Character:GetAttribute('LastDamageTakenTime') < b.Entity.Character:GetAttribute('LastDamageTakenTime')
	end,
	Cursor = function(a, b)
		return getCursorDistance(a.Entity) < getCursorDistance(b.Entity)
	end,
	Armor = function(a, b)
		return getArmor(a.Entity) < getArmor(b.Entity)
	end,
	-- A player whose bed is gone dies for good, so they are worth committing to over
	-- someone who would just respawn. brokenbeds is filled from the BedwarsBedBreak
	-- event further down, keyed the same way the game keys a player's Team attribute.
	['Final Kill'] = function(a, b)
		local abroken = a.Entity.Player and brokenbeds[a.Entity.Player:GetAttribute('Team')]
		local bbroken = b.Entity.Player and brokenbeds[b.Entity.Player:GetAttribute('Team')]
		return (abroken and 1 or 0) > (bbroken and 1 or 0)
	end,
	Threat = function(a, b)
		return getStrength(a.Entity) > getStrength(b.Entity)
	end,
	Kit = function(a, b)
		return (a.Entity.Player and kitorder[a.Entity.Player:GetAttribute('PlayingAsKit')] or 0) > (b.Entity.Player and kitorder[b.Entity.Player:GetAttribute('PlayingAsKit')] or 0)
	end,
	Health = function(a, b)
		return a.Entity.Health < b.Entity.Health
	end,
	Angle = function(a, b)
		local selfrootpos = entitylib.character.RootPart.Position
		local localfacing = entitylib.character.RootPart.CFrame.LookVector * Vector3.new(1, 0, 1)
		local angle = math.acos(localfacing:Dot(((a.Entity.RootPart.Position - selfrootpos) * Vector3.new(1, 0, 1)).Unit))
		local angle2 = math.acos(localfacing:Dot(((b.Entity.RootPart.Position - selfrootpos) * Vector3.new(1, 0, 1)).Unit))
		return angle < angle2
	end
}

run(function()
	local oldstart = entitylib.start
	local function customEntity(ent)
		if ent:HasTag('inventory-entity') and not ent:HasTag('Monster') then
			return
		end

		entitylib.addEntity(ent, nil, ent:HasTag('Drone') and function(self)
			local droneplr = playersService:GetPlayerByUserId(self.Character:GetAttribute('PlayerUserId'))
			return not droneplr or lplr:GetAttribute('Team') ~= droneplr:GetAttribute('Team')
		end or function(self)
			return lplr:GetAttribute('Team') ~= self.Character:GetAttribute('Team')
		end)
	end

	entitylib.start = function()
		oldstart()
		if entitylib.Running then
			for _, ent in collectionService:GetTagged('entity') do
				customEntity(ent)
			end
			table.insert(entitylib.Connections, collectionService:GetInstanceAddedSignal('entity'):Connect(customEntity))
			table.insert(entitylib.Connections, collectionService:GetInstanceRemovedSignal('entity'):Connect(function(ent)
				entitylib.removeEntity(ent)
			end))
		end
	end

	entitylib.addPlayer = function(plr)
		if plr.Character then
			entitylib.refreshEntity(plr.Character, plr)
		end
		entitylib.PlayerConnections[plr] = {
			plr.CharacterAdded:Connect(function(char)
				entitylib.refreshEntity(char, plr)
			end),
			plr.CharacterRemoving:Connect(function(char)
				entitylib.removeEntity(char, plr == lplr)
			end),
			plr:GetAttributeChangedSignal('Team'):Connect(function()
				for _, v in entitylib.List do
					if v.Targetable ~= entitylib.targetCheck(v) then
						entitylib.refreshEntity(v.Character, v.Player)
					end
				end

				if plr == lplr then
					entitylib.start()
				else
					entitylib.refreshEntity(plr.Character, plr)
				end
			end)
		}
	end

	entitylib.addEntity = function(char, plr, teamfunc)
		if not char then return end
		entitylib.EntityThreads[char] = task.spawn(function()
			local hum, humrootpart, head
			if plr then
				hum = waitForChildOfType(char, 'Humanoid', 10)
				humrootpart = hum and waitForChildOfType(hum, 'RootPart', workspace.StreamingEnabled and 9e9 or 10, true)
				head = char:WaitForChild('Head', 10) or humrootpart
			else
				hum = {HipHeight = 0.5}
				humrootpart = waitForChildOfType(char, 'PrimaryPart', 10, true)
				head = humrootpart
			end
			local updateobjects = plr and plr ~= lplr and {
				char:WaitForChild('ArmorInvItem_0', 5),
				char:WaitForChild('ArmorInvItem_1', 5),
				char:WaitForChild('ArmorInvItem_2', 5),
				char:WaitForChild('HandInvItem', 5)
			} or {}

			if hum and humrootpart then
				local entity = {
					Connections = {},
					Character = char,
					Health = (char:GetAttribute('Health') or 100) + getShieldAttribute(char),
					Head = head,
					Humanoid = hum,
					HumanoidRootPart = humrootpart,
					HipHeight = hum.HipHeight + (humrootpart.Size.Y / 2) + (hum.RigType == Enum.HumanoidRigType.R6 and 2 or 0),
					Jumps = 0,
					JumpTick = tick(),
					Jumping = false,
					LandTick = tick(),
					MaxHealth = char:GetAttribute('MaxHealth') or 100,
					NPC = plr == nil,
					Player = plr,
					RootPart = humrootpart,
					TeamCheck = teamfunc
				}

				if plr == lplr then
					entity.AirTime = tick()
					entitylib.character = entity
					entitylib.isAlive = true
					entitylib.Events.LocalAdded:Fire(entity)
					table.insert(entitylib.Connections, char.AttributeChanged:Connect(function(attr)
						vainEvents.AttributeChanged:Fire(attr)
					end))
				else
					entity.Targetable = entitylib.targetCheck(entity)

					for _, v in entitylib.getUpdateConnections(entity) do
						table.insert(entity.Connections, v:Connect(function()
							entity.Health = (char:GetAttribute('Health') or 100) + getShieldAttribute(char)
							entity.MaxHealth = char:GetAttribute('MaxHealth') or 100
							entitylib.Events.EntityUpdated:Fire(entity)
						end))
					end

					for _, v in updateobjects do
						table.insert(entity.Connections, v:GetPropertyChangedSignal('Value'):Connect(function()
							task.delay(0.1, function()
								if bedwars.getInventory then
									store.inventories[plr] = bedwars.getInventory(plr)
									entitylib.Events.EntityUpdated:Fire(entity)
								end
							end)
						end))
					end

					if plr then
						local anim = char:FindFirstChild('Animate')
						if anim then
							pcall(function()
								anim = anim.jump:FindFirstChildWhichIsA('Animation').AnimationId
								table.insert(entity.Connections, hum.Animator.AnimationPlayed:Connect(function(playedanim)
									if playedanim.Animation.AnimationId == anim then
										entity.JumpTick = tick()
										entity.Jumps += 1
										entity.LandTick = tick() + 1
										entity.Jumping = entity.Jumps > 1
									end
								end))
							end)
						end

						task.delay(0.1, function()
							if bedwars.getInventory then
								store.inventories[plr] = bedwars.getInventory(plr)
							end
						end)
					end
					table.insert(entitylib.List, entity)
					entitylib.Events.EntityAdded:Fire(entity)
				end

				table.insert(entity.Connections, char.ChildRemoved:Connect(function(part)
					if part == humrootpart or part == hum or part == head then
						if part == humrootpart and hum.RootPart then
							humrootpart = hum.RootPart
							entity.RootPart = hum.RootPart
							entity.HumanoidRootPart = hum.RootPart
							return
						end
						entitylib.removeEntity(char, plr == lplr)
					end
				end))
			end
			entitylib.EntityThreads[char] = nil
		end)
	end

	entitylib.getUpdateConnections = function(ent)
		local char = ent.Character
		local tab = {
			char:GetAttributeChangedSignal('Health'),
			char:GetAttributeChangedSignal('MaxHealth'),
			{
				Connect = function()
					ent.Friend = ent.Player and isFriend(ent.Player) or nil
					ent.Target = ent.Player and isTarget(ent.Player) or nil
					return {Disconnect = function() end}
				end
			}
		}

		if ent.Player then
			table.insert(tab, ent.Player:GetAttributeChangedSignal('PlayingAsKit'))
		end

		for name, val in char:GetAttributes() do
			if name:find('Shield') and type(val) == 'number' then
				table.insert(tab, char:GetAttributeChangedSignal(name))
			end
		end

		return tab
	end

	--[[
		Bedwars differs from everywhere else: rank only shields somebody you are against.

		A player who outranks you and is on your own team is treated as any other
		teammate, so nothing about being ranked gets in the way of a game you are playing
		together. On any other team they are untouchable - no aim, no aura, no esp, and
		none of their base either, see isBlockBreakable below.

		Every other game applies the plain rule from the universal base, where team makes
		no difference at all.
	]]
	--[[
		Whether a player may be acted on, asked safely.

		whitelist:get is defined inside one of the universal base's deferred blocks, so for
		the first moments of a round the table exists but the method does not - and calling
		it then threw straight through the block breaker, which is where the wall of
		"attempt to call a nil value" came from.

		Unanswerable is treated as attackable. Refusing to break anything until the list has
		loaded would be a worse failure than briefly not protecting somebody, and the answer
		corrects itself within the same second.
	]]
	local function attackable(plr)
		if not (whitelist and type(whitelist.get) == 'function') then return true end
		local ok, _, allowed = pcall(whitelist.get, whitelist, plr)
		if not ok then return true end
		return allowed
	end

	local function sameTeam(plr)
		local mine = lplr:GetAttribute('Team')
		return mine ~= nil and mine == plr:GetAttribute('Team')
	end
	bedwars.sameTeam = sameTeam

	entitylib.protectionCheck = function(ent)
		if not ent.Player or sameTeam(ent.Player) then return true end
		return attackable(ent.Player)
	end

	entitylib.targetCheck = function(ent)
		if ent.NPC then return true end
		if isFriend(ent.Player) then return false end
		if ent.TeamCheck then
			return ent:TeamCheck()
		end
		return lplr:GetAttribute('Team') ~= ent.Player:GetAttribute('Team')
	end
	vain:Clean(entitylib.Events.LocalAdded:Connect(updateVelocity))
end)
entitylib.start()

run(function()
	local KnitInit, Knit
	repeat
		KnitInit, Knit = pcall(function()
			return debug.getupvalue(require(lplr.PlayerScripts.TS.knit).setup, 9)
		end)
		if KnitInit then break end
		task.wait()
	until KnitInit

	if not debug.getupvalue(Knit.Start, 1) then
		repeat task.wait() until debug.getupvalue(Knit.Start, 1)
	end

	local Flamework = require(replicatedStorage['rbxts_include']['node_modules']['@flamework'].core.out).Flamework
	local InventoryUtil = require(replicatedStorage.TS.inventory['inventory-util']).InventoryUtil
	local Client = require(replicatedStorage.TS.remotes).default.Client
	local OldGet, OldBreak = Client.Get

	-- Which team upgrades are on offer, at what cost, for the queue you are actually in -
	-- mine wars, survival and hyper gen each run a different set.
	--
	-- Asked of the module's own export rather than read out of a fixed upvalue slot. Slot
	-- 6 is getQueueMeta on the current client - a function, not the meta table - so
	-- iterating it threw, and that took out every AutoBuy setting declared after the
	-- upgrade toggles and left Buy Upgrades with nothing at all to buy. The upvalue route
	-- is kept as a fallback for older clients, but it looks for a table that is shaped
	-- like the meta instead of trusting an index that has already moved once.
	local upgrademeta = require(replicatedStorage.TS.games.bedwars['team-upgrade']['team-upgrade-meta'])

	local function isUpgradeMeta(tab)
		if type(tab) ~= 'table' then return false end
		local _, entry = next(tab)
		return type(entry) == 'table' and type(entry.tiers) == 'table'
	end

	local function teamUpgradeMeta()
		local ok, queuemeta = pcall(upgrademeta.getTeamUpgradeMetaForQueue)
		if ok and isUpgradeMeta(queuemeta) then return queuemeta end

		for i = 1, 16 do
			local found, value = pcall(debug.getupvalue, upgrademeta.getTeamUpgradeMetaForQueue, i)
			if found and isUpgradeMeta(value) then return value end
		end

		return {}
	end

	bedwars = setmetatable({
		AbilityController = Flamework.resolveDependency('@easy-games/game-core:client/controllers/ability/ability-controller@AbilityController'),
		-- Holds registeredActions, keyed by the id an action was bound under. That is how
		-- a module can call the same function a keypress would, rather than reimplementing
		-- what the game does behind it.
		ActionBinder = Flamework.resolveDependency('@easy-games/game-core:client/controllers/keybind/action-binder-controller@ActionBinderController'),
		AbilityId = require(replicatedStorage.TS.ability['ability-id']).AbilityId,
		AudioCategory = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).AudioCategory,
		AudioManager = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).AudioManager,
		AnimationType = require(replicatedStorage.TS.animation['animation-type']).AnimationType,
		AnimationUtil = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out['shared'].util['animation-util']).AnimationUtil,
		AppController = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out.client.controllers['app-controller']).AppController,
		BedBreakEffectMeta = require(replicatedStorage.TS.locker['bed-break-effect']['bed-break-effect-meta']).BedBreakEffectMeta,
		BedwarsKitMeta = require(replicatedStorage.TS.games.bedwars.kit['bedwars-kit-meta']).BedwarsKitMeta,
		BeeNetController = Knit.Controllers.BeeNetController,
		BlockBreaker = Knit.Controllers.BlockBreakController.blockBreaker,
		BlockController = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['block-engine'].out).BlockEngine,
		BlockEngine = require(lplr.PlayerScripts.TS.lib['block-engine']['client-block-engine']).ClientBlockEngine,
		BlockPlacer = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['block-engine'].out.client.placement['block-placer']).BlockPlacer,
		BowConstantsTable = debug.getupvalue(Knit.Controllers.ProjectileController.enableBeam, 8),
		ClickHold = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out.client.ui.lib.util['click-hold']).ClickHold,
		Client = Client,
		ClientConstructor = require(replicatedStorage['rbxts_include']['node_modules']['@rbxts'].net.out.client),
		ClientDamageBlock = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['block-engine'].out.shared.remotes).BlockEngineRemotes.Client,
		CombatConstant = require(replicatedStorage.TS.combat['combat-constant']).CombatConstant,
		DamageIndicator = Knit.Controllers.DamageIndicatorController.spawnDamageIndicator,
		EmoteType = require(replicatedStorage.TS.locker.emote['emote-type']).EmoteType,
		GameAnimationUtil = require(replicatedStorage.TS.animation['animation-util']).GameAnimationUtil,
		getIcon = function(item, showinv)
			local itemmeta = bedwars.ItemMeta[item.itemType]
			return itemmeta and showinv and itemmeta.image or ''
		end,
		getInventory = function(plr)
			local suc, res = pcall(function()
				return InventoryUtil.getInventory(plr)
			end)
			return suc and res or {
				items = {},
				armor = {}
			}
		end,
		HudAliveCount = require(lplr.PlayerScripts.TS.controllers.global['top-bar'].ui.game['hud-alive-player-counts']).HudAlivePlayerCounts,
		-- item-meta now exports the table directly as `items`; the getupvalue path is kept
		-- as a fallback since it is the only route on older client builds. Reading the
		-- export first means a future change to getItemMeta's locals can't silently hand
		-- back the wrong upvalue - ItemMeta backs 23 usages across the modules.
		ItemMeta = (function()
			local itemmeta = require(replicatedStorage.TS.item['item-meta'])
			return itemmeta.items or debug.getupvalue(itemmeta.getItemMeta, 1)
		end)(),
		KillEffectMeta = require(replicatedStorage.TS.locker['kill-effect']['kill-effect-meta']).KillEffectMeta,
		KillFeedController = Flamework.resolveDependency('client/controllers/game/kill-feed/kill-feed-controller@KillFeedController'),
		Knit = Knit,
		KnockbackUtil = require(replicatedStorage.TS.damage['knockback-util']).KnockbackUtil,
		MageKitUtil = require(replicatedStorage.TS.games.bedwars.kit.kits.mage['mage-kit-util']).MageKitUtil,
		NametagController = Knit.Controllers.NametagController,
		PartyController = Flamework.resolveDependency('@easy-games/lobby:client/controllers/party-controller@PartyController'),
		ProjectileMeta = require(replicatedStorage.TS.projectile['projectile-meta']).ProjectileMeta,
		QueryUtil = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).GameQueryUtil,
		QueueCard = require(lplr.PlayerScripts.TS.controllers.global.queue.ui['queue-card']).QueueCard,
		QueueMeta = require(replicatedStorage.TS.game['queue-meta']).QueueMeta,
		RankController = Knit.Controllers.RankController,
		RankMeta = require(replicatedStorage.TS.rank['rank-meta']).RankMeta,
		Roact = require(replicatedStorage['rbxts_include']['node_modules']['@rbxts']['roact'].src),
		RuntimeLib = require(replicatedStorage['rbxts_include'].RuntimeLib),
		SoundList = require(replicatedStorage.TS.sound['game-sound']).GameSound,
		StatusEffectMeta = require(replicatedStorage.TS['status-effect']['status-effect-meta']).StatusEffectMeta,
		StatusEffectType = require(replicatedStorage.TS['status-effect']['status-effect-type']).StatusEffectType,
		SoundManager = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).SoundManager,
		Store = require(lplr.PlayerScripts.TS.ui.store).ClientStore,
		TeamUpgradeMeta = teamUpgradeMeta(),
		UILayers = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).UILayers,
		VisualizerUtils = require(lplr.PlayerScripts.TS.lib.visualizer['visualizer-utils']).VisualizerUtils,
		WeldTable = require(replicatedStorage.TS.util['weld-util']).WeldUtil,
		WinEffectMeta = require(replicatedStorage.TS.locker['win-effect']['win-effect-meta']).WinEffectMeta,
		ZapNetworking = require(lplr.PlayerScripts.TS.lib.network)
	}, {
		__index = function(self, ind)
			rawset(self, ind, Knit.Controllers[ind])
			return rawget(self, ind)
		end
	})

	-- The game dropped SoundManager for AudioManager:playAudio(sound, config), so
	-- bedwars.SoundManager resolved to nil and every module that plays a sound threw on
	-- it. Shimming the old method keeps all of those call sites working instead of
	-- spreading the rename across each one, and it stays quiet rather than throwing if
	-- the audio side moves again.
	if not rawget(bedwars, 'SoundManager') then
		rawset(bedwars, 'SoundManager', {
			playSound = function(_, sound, config)
				local manager = bedwars.AudioManager
				if not manager then return end

				local settings = {category = bedwars.AudioCategory and bedwars.AudioCategory.GAMEPLAY}
				for index, value in (config or {}) do
					settings[index] = value
				end
				return manager:playAudio(sound, settings)
			end
		})
	end

	-- The settings list is built once at load, but which upgrades exist and what they cost
	-- follows the queue, so the buying side asks again each time rather than trusting what
	-- was true when the menu was drawn.
	rawset(bedwars, 'getTeamUpgradeMeta', teamUpgradeMeta)

	local remoteNames = {
		AfkStatus = debug.getproto(Knit.Controllers.AfkController.KnitStart, 1),
		AttackEntity = Knit.Controllers.SwordController.sendServerRequest,
		BeePickup = Knit.Controllers.BeeNetController.trigger,
		CannonLaunch = Knit.Controllers.CannonHandController.launchSelf,
		ConsumeBattery = debug.getproto(Knit.Controllers.BatteryController.onKitLocalActivated, 1),
		ConsumeItem = debug.getproto(Knit.Controllers.ConsumeController.onEnable, 1),
		ConsumeSoul = Knit.Controllers.GrimReaperController.consumeSoul,
		ConsumeTreeOrb = debug.getproto(Knit.Controllers.EldertreeController.createTreeOrbInteraction, 1),
		DepositPinata = debug.getproto(debug.getproto(Knit.Controllers.PiggyBankController.KnitStart, 2), 5),
		DragonBreath = debug.getproto(Knit.Controllers.VoidDragonController.onKitLocalActivated, 5),
		DragonEndFly = debug.getproto(Knit.Controllers.VoidDragonController.flapWings, 1),
		DragonFly = Knit.Controllers.VoidDragonController.flapWings,
		DropItem = Knit.Controllers.ItemDropController.dropItemInHand,
		EquipItem = debug.getproto(require(replicatedStorage.TS.entity.entities['inventory-entity']).InventoryEntity.equipItem, 4),
		FireProjectile = debug.getupvalue(Knit.Controllers.ProjectileController.launchProjectileWithValues, 2),
		GroundHit = Knit.Controllers.FallDamageController.KnitStart,
		GuitarHeal = Knit.Controllers.GuitarController.performHeal,
		HannahKill = debug.getproto(Knit.Controllers.HannahController.registerExecuteInteractions, 1),
		HarvestCrop = debug.getproto(debug.getproto(Knit.Controllers.CropController.KnitStart, 4), 1),
		KaliyahPunch = debug.getproto(Knit.Controllers.DragonSlayerController.onKitLocalActivated, 1),
		MageSelect = debug.getproto(Knit.Controllers.MageController.registerTomeInteraction, 1),
		MinerDig = debug.getproto(Knit.Controllers.MinerController.setupMinerPrompts, 1),
		PickupItem = Knit.Controllers.ItemDropController.checkForPickup,
		PickupMetal = debug.getproto(Knit.Controllers.HiddenMetalController.onKitLocalActivated, 4),
		ReportPlayer = require(lplr.PlayerScripts.TS.controllers.global.report['report-controller']).default.reportPlayer,
		ResetCharacter = debug.getproto(Knit.Controllers.ResetController.createBindable, 1),
		SpawnRaven = debug.getproto(Knit.Controllers.RavenController.KnitStart, 1),
		SummonerClawAttack = Knit.Controllers.SummonerClawHandController.attack,
		WarlockTarget = debug.getproto(Knit.Controllers.WarlockStaffController.KnitStart, 2)
	}

	local function dumpRemote(tab)
		local ind
		for i, v in tab do
			if v == 'Client' then
				ind = i
				break
			end
		end
		return ind and tab[ind + 1] or ''
	end

	for i, v in remoteNames do
		local remote = dumpRemote(debug.getconstants(v))
		if remote == '' then
			notif('Vain', 'Failed to grab remote ('..i..')', 10, 'alert')
		end
		remotes[i] = remote
	end

	-- The names above are scraped out of the game's bytecode because they are not what
	-- they are called in source. Plenty of remotes are registered under their plain name
	-- though - BedwarsPurchaseItem and UseAbility among them - and modules referring to
	-- those got nil, because only the scraped set was ever populated. Falling back to the
	-- key means an unlisted remote resolves to its own name, which is right whenever the
	-- game did not rename it and no worse than nil when it did.
	setmetatable(remotes, {
		__index = function(_, key)
			return key
		end
	})

	OldBreak = bedwars.BlockController.isBlockBreakable

	Client.Get = function(self, remoteName)
		-- Get yields while it waits on the remote, and a yield hands the thread back to
		-- the scheduler, which resumes it carrying the game's identity rather than the
		-- executor's. Anything the caller does afterwards that needs the executor's
		-- identity then fails - a module calling this while it is being defined would
		-- lose the ability to parent an Instance, so the CreateModule on the next line
		-- died with "lacking capability Plugin". Restoring it here fixes every caller
		-- rather than each one working around it.
		local identity = getthreadidentity and getthreadidentity() or nil
		local call = OldGet(self, remoteName)
		if identity and setthreadidentity then
			pcall(setthreadidentity, identity)
		end

		if remoteName == remotes.AttackEntity then
			return {
				instance = call.instance,
				SendToServer = function(_, attackTable, ...)
					local suc, plr = pcall(function()
						return playersService:GetPlayerFromCharacter(attackTable.entityInstance)
					end)

					local selfpos = attackTable.validate.selfPosition.value
					local targetpos = attackTable.validate.targetPosition.value
					store.attackReach = ((selfpos - targetpos).Magnitude * 100) // 1 / 100
					store.attackReachUpdate = tick() + 1

					if Reach.Enabled or HitBoxes.Enabled then
						attackTable.validate.raycast = attackTable.validate.raycast or {}
						attackTable.validate.selfPosition.value += CFrame.lookAt(selfpos, targetpos).LookVector * math.max((selfpos - targetpos).Magnitude - 14.399, 0)
					end

					if suc and plr then
						if not attackable(plr) then return end
					end

					return call:SendToServer(attackTable, ...)
				end
			}
		elseif remoteName == 'StepOnSnapTrap' and TrapDisabler.Enabled then
			return {SendToServer = function() end}
		end

		return call
	end

	--[[
		Whether a team is one you must leave alone: somebody on it outranks you, and it is
		not your own.

		Answered by walking the players rather than by team id alone, since a team is only
		worth shielding while a protected player is actually on it.
	]]
	local function protectedTeam(teamId)
		if teamId == nil then return false end
		if lplr:GetAttribute('Team') == teamId then return false end

		for _, other in playersService:GetPlayers() do
			if other:GetAttribute('Team') == teamId and not attackable(other) then
				return true
			end
		end
		return false
	end
	bedwars.protectedTeam = protectedTeam

	--[[
		Their base is part of them.

		Protecting the player and leaving their bed open would miss the point entirely -
		the bed is the thing worth attacking. Two ways a block can belong to a shielded
		team: a bed carries a NoBreak attribute naming the team it belongs to, and any
		block somebody placed carries the id of whoever placed it, which is what covers
		the defence stacked around it.
	]]
	bedwars.BlockController.isBlockBreakable = function(self, breakTable, breaker)
		local obj = bedwars.BlockController:getStore():getBlockAt(breakTable.blockPosition)

		if obj then
			if obj.Name == 'bed' then
				for _, other in playersService:GetPlayers() do
					local teamId = other:GetAttribute('Team')
					if teamId and obj:GetAttribute('Team'..teamId..'NoBreak') and protectedTeam(teamId) then
						return false
					end
				end
			end

			local placer = obj:GetAttribute('PlacedByUserId')
			if placer and placer ~= 0 then
				local owner = playersService:GetPlayerByUserId(placer)
				if owner and not sameTeam(owner) and not attackable(owner) then
					return false
				end
			end
		end

		return OldBreak(self, breakTable, breaker)
	end

	local cache, blockhealthbar = {}, {blockHealth = -1, breakingBlockPosition = Vector3.zero}
	store.blockPlacer = bedwars.BlockPlacer.new(bedwars.BlockEngine, 'wool_white')

	local function getBlockHealth(block, blockpos)
		local blockdata = bedwars.BlockController:getStore():getBlockData(blockpos)
		return (blockdata and (blockdata:GetAttribute('1') or blockdata:GetAttribute('Health')) or block:GetAttribute('Health'))
	end

	local function getBlockHits(block, blockpos)
		if not block then return 0 end
		local breaktype = bedwars.ItemMeta[block.Name].block.breakType
		local tool = store.tools[breaktype]
		tool = tool and bedwars.ItemMeta[tool.itemType].breakBlock[breaktype] or 2
		return getBlockHealth(block, bedwars.BlockController:getBlockPosition(blockpos)) / tool
	end

	--[[
		Pathfinding using a luau version of dijkstra's algorithm
		Source: https://stackoverflow.com/questions/39355587/speeding-up-dijkstras-algorithm-to-solve-a-3d-maze
	]]
	-- The queue was being read with next() and shifted off the front, which is first in
	-- first out - it never took the cheapest block, so this was breadth first search
	-- wearing Dijkstra's name. Blocks are kept in cost order instead, so the one coming
	-- off the front really is the cheapest and marking it visited is safe.
	--
	-- A route costs one per block. It used to cost the hits needed to break each one,
	-- which optimises for damage rather than digging: four soft blocks beat one tough
	-- one, so routes wandered off diagonally through whatever was cheapest instead of
	-- going in. Toughness is kept only to separate routes of the same length, weighted
	-- and capped so that however many blocks a route crosses it can never add up to a
	-- whole extra one.
	local HIT_WEIGHT = 0.0001
	local HIT_CAP = 100
	-- Changing direction costs a touch more than carrying straight on. Routes of the
	-- same length tie constantly and the winner was whichever got queued first, so a dig
	-- would step up a block, run along, and step back down for no reason at all. Small
	-- enough that a route can never turn into a longer one to avoid a corner.
	local TURN_COST = 0.01

	-- How many blocks longer than the shortest way in a target mode may still choose.
	-- Zero, so the dig is always as short as it can be and the mode decides between the
	-- ways in that are equally short - a way in that is even one block worse is one whose
	-- route has to bend to get there, which is what makes a dig step up and over for no
	-- visible reason. Compared on whole blocks, since the weights below put a fraction on
	-- top of every route and no two are ever exactly equal.
	local ENTRY_TOLERANCE = 0

	local function enqueue(queue, dist, node)
		local low, high = 1, #queue + 1
		while low < high do
			local mid = (low + high) // 2
			if queue[mid][1] > dist then
				high = mid
			else
				low = mid + 1
			end
		end
		table.insert(queue, low, {dist, node})
	end

	-- Air only counts as a way in when it leads back out of the build. Air walled in on
	-- every side is a pocket: breaking into one opens nothing, because the layers around
	-- it are all still standing, so it just looks like blocks going missing out of the
	-- middle of a wall.
	--
	-- Outside is the structure's own extent rather than a number of cells. The flood
	-- below has already touched every block hanging off the bed, so air that gets past
	-- the edge of that has left the build by definition. Counting cells could never say
	-- that: a pocket sitting against the tunnel being dug joins air that does reach out,
	-- so past a few cells the count says "escaped" about a pocket and the test quietly
	-- stops meaning anything.
	--
	-- The cap is only there so a hopeless case cannot stall the break loop, and it fails
	-- open - refusing every opening would leave the nuker doing nothing at all.
	local POCKET_LIMIT = 4096

	local function reachesOutside(start, memo, low, high)
		local cached = memo[start]
		if cached ~= nil then return cached end

		local seen, frontier, count, escaped = {[start] = true}, {start}, 1, false

		while #frontier > 0 and not escaped do
			local nextfrontier = {}
			for _, pos in frontier do
				if pos.X < low.X or pos.Y < low.Y or pos.Z < low.Z
					or pos.X > high.X or pos.Y > high.Y or pos.Z > high.Z then
					escaped = true
					break
				end

				for _, side in sides do
					local at = pos + side
					if seen[at] or getPlacedBlock(at) then continue end
					-- Running into air already known to get out settles this body too,
					-- rather than walking the whole of the outside again for every face
					-- of every opening along it.
					if memo[at] then
						escaped = true
						break
					end
					seen[at] = true

					count += 1
					if count >= POCKET_LIMIT then
						escaped = true
						break
					end
					table.insert(nextfrontier, at)
				end
				if escaped then break end
			end
			frontier = nextfrontier
		end

		-- One verdict for the whole body of air, since every cell reached is part of it.
		for pos in seen do
			memo[pos] = escaped
		end
		return escaped
	end

	-- Which opening you can actually reach depends on where you stand, so it is chosen
	-- per call rather than baked into the cache. Picking purely on cost was wrong twice
	-- over: the cheapest opening could sit on the far side of a build, out of range, and
	-- the walls of a box are usually the same thickness anyway - so with every opening
	-- tied the winner came down to whichever the hash table happened to yield first, and
	-- it would just as soon mine the far wall as the one you are standing at.
	local NEAR_COST_TOLERANCE = 2
	local NEAR_COST_MARGIN = 2

	-- score lets the caller decide which opening to take - it is the block that actually
	-- gets broken, so this is what a target mode has to steer. Without one, the near side
	-- wins unless it would cost substantially more to get through, which is the
	-- difference between reaching around a thin wall and mining through a thick one.
	local function pickEntry(exposed, maxRange, score, prefer, maxAngle)
		local origin = entitylib.isAlive and entitylib.character.RootPart.Position
		-- The setting is the width of the cone, so half of it is the most a block may sit
		-- off the way you are looking. A full turn takes in everything and is not worth
		-- resolving the camera for.
		local halfAngle = maxAngle and (maxAngle / 2)
		local camera = halfAngle and halfAngle < 180 and workspace.CurrentCamera or nil

		-- Both limits on where a dig may start: how far you can reach, and how far off
		-- the way you are looking it is allowed to be.
		local function allowed(node, reach)
			if maxRange and origin and reach > maxRange then return false end
			if camera then
				local dir = node - camera.CFrame.Position
				if dir.Magnitude > 0 then
					local facing = camera.CFrame.LookVector:Dot(dir.Unit)
					if math.deg(math.acos(math.clamp(facing, -1, 1))) > halfAngle then return false end
				end
			end
			return true
		end

		-- Carry on down the hole already started instead of shaving another block off the
		-- outer face. prefer is the whole remaining route, nearest end first, and the
		-- first block of it still standing wins outright. Only naming the next block was
		-- not enough: while that one is being broken the one after it is still buried, so
		-- there was nothing to prefer and the scoring below picked whatever sat closest on
		-- the outer face - which is never the block at the back of the hole.
		--
		-- None of that applies until the route's first block has actually come down. While
		-- it is still standing nothing has been committed to yet, so the mode gets to pick
		-- again every pass and walking round a build moves the dig to whatever is nearest
		-- from where you now are. Past that point the route has to be seen through, or the
		-- tunnel would keep restarting at the surface and never reach the bed.
		if prefer and prefer[1] and not exposed[prefer[1]] then
			for _, node in prefer do
				if exposed[node] and allowed(node, origin and (node - origin).Magnitude or 0) then
					return node, exposed[node], -math.huge
				end
			end
		end

		-- A target mode chooses where on the outer defence layer to start, so that is all
		-- it may choose from. The flood reaches every opening in whatever the bed happens
		-- to be attached to, and on a large build the one nearest you can sit eight blocks
		-- of tunnelling from the bed while another is one block away - picking that is how
		-- a dig ended up running the length of a wall to get anywhere. Only the ways in
		-- that are about as short as the shortest are offered up.
		local mincost = math.huge
		for node, cost in exposed do
			if cost < mincost and allowed(node, origin and (node - origin).Magnitude or 0) then
				mincost = cost
			end
		end
		local costlimit = math.floor(mincost) + ENTRY_TOLERANCE

		local best, bestkey, bestcost = nil, math.huge, math.huge
		local near, nearreach, nearcost = nil, math.huge, math.huge
		local cheap, cheapcost = nil, math.huge

		for node, cost in exposed do
			local reach = origin and (node - origin).Magnitude or 0
			if math.floor(cost) > costlimit or not allowed(node, reach) then continue end

			if score then
				local key = score(node, cost, reach)
				if key and key < bestkey then
					best, bestkey, bestcost = node, key, cost
				end
			else
				if cost < cheapcost then
					cheap, cheapcost = node, cost
				end
				if reach < nearreach then
					near, nearreach, nearcost = node, reach, cost
				end
			end
		end

		if score then
			return best, bestcost, bestkey
		end
		if near and nearcost <= (cheapcost * NEAR_COST_TOLERANCE) + NEAR_COST_MARGIN then
			return near, nearcost, nearcost
		end
		return cheap, cheapcost, cheapcost
	end

	-- avoidOwn routes the tunnel around blocks you placed yourself. The path is what
	-- actually gets broken - breakBlock digs along it rather than hitting the target
	-- directly - so a Self Break check on the target alone never prevented your own
	-- blocks being destroyed on the way there. The flag is part of the cache entry
	-- because the same target has two different cheapest routes depending on it.
	local function calculatePath(target, blockpos, avoidOwn, maxRange, score, prefer, maxAngle)
		avoidOwn = avoidOwn == true
		local cached = cache[blockpos]
		if cached and cached[4] == avoidOwn then
			local pos, cost, key = pickEntry(cached[5], maxRange, score, prefer, maxAngle)
			if pos then
				return pos, cost, cached[3], key
			end
			return
		end
		local visited, unvisited, distances, air, path = {}, {{0, blockpos}}, {[blockpos] = 0}, {}, {}
		-- Which way each block was reached from, so carrying on that way can be preferred.
		local heading = {}
		-- The corners of everything the flood touches, which is what air is measured
		-- against afterwards to tell a way out from a sealed pocket.
		local low, high = blockpos, blockpos

		for _ = 1, 10000 do
			local node = unvisited[1]
			if not node then break end
			table.remove(unvisited, 1)
			-- Relaxing a block queues it again rather than moving it, so the same one can
			-- come up twice; the first time is the cheap one.
			if visited[node[2]] then continue end
			visited[node[2]] = true
			low, high = low:Min(node[2]), high:Max(node[2])

			for _, side in sides do
				side = node[2] + side
				if visited[side] then continue end

				local block = getPlacedBlock(side)
				if not block or block:GetAttribute('NoBreak') or block == target
					or (avoidOwn and block:GetAttribute('PlacedByUserId') == lplr.UserId) then
					if not block then
						air[node[2]] = true
					end
					continue
				end

				local facing = side - node[2]
				local turn = (heading[node[2]] and heading[node[2]] ~= facing) and TURN_COST or 0
				local curdist = node[1] + 1 + turn + (math.min(getBlockHits(block, side), HIT_CAP) * HIT_WEIGHT)
				if curdist < (distances[side] or math.huge) then
					enqueue(unvisited, curdist, side)
					distances[side] = curdist
					path[side] = node[2]
					heading[side] = facing
				end
			end
		end

		-- Only the openings are kept, not the whole distance map, so a cached route
		-- stays small enough to hold one per target.
		local pockets = {}
		local exposed = {}
		for node in air do
			for _, side in sides do
				local at = node + side
				if not getPlacedBlock(at) and reachesOutside(at, pockets, low, high) then
					exposed[node] = distances[node]
					break
				end
			end
		end
		if not next(exposed) then return end

		-- Cached even when nothing is reachable from where you stand right now, keyed on
		-- the target's own position for invalidation. Walking the route again on every
		-- pass just to rediscover that it is still out of reach costs far more than
		-- holding on to it until a block nearby actually changes.
		cache[blockpos] = {
			blockpos,
			0,
			path,
			avoidOwn,
			exposed
		}

		local pos, cost, key = pickEntry(exposed, maxRange, score, prefer, maxAngle)
		if pos then
			return pos, cost, path, key
		end
	end

	bedwars.placeBlock = function(pos, item)
		if getItem(item) then
			store.blockPlacer.blockType = item
			return store.blockPlacer:placeBlock(bedwars.BlockController:getBlockPosition(pos))
		end
	end

	-- Every position a block occupies, so multi-part blocks are pathed to correctly.
	local function containedPositions(block)
		local handler = bedwars.BlockController:getHandlerRegistry():getHandler(block.Name)
		return handler and handler:getContainedPositions(block) or {block.Position / 3}
	end

	bedwars.getBlockHealth = getBlockHealth
	bedwars.getPlacedBlock = getPlacedBlock
	bedwars.getContainedPositions = containedPositions

	-- First person puts the camera inside your own head. The head is looked up live and
	-- the gap is given a little room: a cached head goes stale across a respawn and then
	-- reports a huge gap forever, and the walk animation moves the head enough that too
	-- tight a threshold reads as third person mid-stride - which is what let a
	-- third-person-only module run while you were in first and walking.
	bedwars.isFirstPerson = function()
		local char = lplr.Character
		local head = char and char:FindFirstChild('Head')
		local camera = workspace.CurrentCamera or gameCamera
		if not head or not camera then return false end
		return (camera.CFrame.Position - head.Position).Magnitude < 1.5
	end
	bedwars.getBlockHits = getBlockHits

	-- Mirrors what the AutoTool module does for a manual break: select the hotbar slot
	-- holding the best tool for this block so it is genuinely held, rather than only
	-- swapping the hand underneath the UI.
	local function equipBreakTool(block)
		local blockmeta = bedwars.ItemMeta[block.Name]
		local breaktype = blockmeta and blockmeta.block and blockmeta.block.breakType
		local tool = breaktype and store.tools[breaktype]
		if not tool then return end

		for i, v in store.inventory.hotbar do
			if v.item and v.item.itemType == tool.itemType then
				if store.inventory.hotbarSlot ~= i - 1 then
					-- Dispatched without waiting on the inventory event, unlike the module's
					-- own switch - this runs inside the break loop and cannot afford to
					-- block it on an event that may never arrive.
					pcall(function()
						bedwars.Store:dispatch({type = 'InventorySelectHotbarSlot', slot = i - 1})
					end)
				end
				break
			end
		end

		-- An inventory item only carries a tool instance while it is materialised, and
		-- switchItem indexes it either way. The best tool for a block is often one sitting
		-- in the inventory without one, so this threw and took the whole break down with
		-- it - which is why turning Auto Tool on stopped the nuker breaking anything.
		if tool.tool then
			switchItem(tool.tool)
		end
	end

	-- autoTool: nil keeps the old behaviour of only swapping while no sword swing is in
	-- flight, true always swaps to the right tool, false leaves your hand alone.
	-- The swing currently playing on your character, so the next one replaces it rather
	-- than stacking another track on top of one still running.
	local swingtrack

	-- How long to leave a swing running when the track itself cannot say, and how long to
	-- fade it out over.
	local SWING_FALLBACK = 0.3
	local SWING_FADE = 0.1

	--[[
		Ends a swing once it has had its time.

		Scheduled rather than waited on. Waiting blocked the promise this is called from
		and, at any break speed shorter than the wait, started the next swing on top of one
		still playing. Leaving it to be stopped by the next swing instead was worse: the
		last one of a dig had no next swing to replace it, so it simply never stopped.

		Length is zero until the asset has loaded, which is usually the case immediately
		after asking for it, so there is a fallback to fall back on.
	]]
	local function endSwing(track)
		task.delay(track.Length > 0 and track.Length or SWING_FALLBACK, function()
			if swingtrack == track then
				swingtrack = nil
			end
			pcall(function()
				track:Stop(SWING_FADE)
				track:Destroy()
			end)
		end)
	end

	-- The remaining blocks between an opening and the target, nearest end first.
	local ROUTE_LIMIT = 32

	local function routeFrom(pos, path, into)
		table.clear(into)
		local node = pos
		for _ = 1, ROUTE_LIMIT do
			if not node then break end
			table.insert(into, node)
			node = path[node]
		end
		return into
	end

	-- options: Range caps how far the block being broken may be, Angle how far off your
	-- view it may sit, Score ranks the ways in, Prefer is a route to carry on down, and
	-- Route is filled in with the one taken.
	bedwars.breakBlock = function(block, effects, anim, customHealthbar, avoidOwn, autoTool, options)
		if lplr:GetAttribute('DenyBlockBreak') or not entitylib.isAlive or InfiniteFly.Enabled then return end
		options = options or {}
		local maxRange = math.min(options.Range or 30, 30)
		local entryScore, prefer, maxAngle = options.Score, options.Prefer, options.Angle
		local cost, pos, target, path = math.huge
		-- A bed covers several block positions, each with its own way in. They are
		-- compared on whatever the target mode is ranking by, so the mode's pick is not
		-- quietly overridden by a cheaper tunnel into the bed's other half.
		local bestkey = math.huge

		for _, v in containedPositions(block) do
			local dpos, dcost, dpath, dkey = calculatePath(block, v * 3, avoidOwn, maxRange, entryScore, prefer, maxAngle)
			dkey = dkey or dcost
			if dpos and dkey < bestkey then
				bestkey, cost, pos, target, path = dkey, dcost, dpos, v * 3, dpath
			end
		end

		if pos then
			if (entitylib.character.RootPart.Position - pos).Magnitude > maxRange then return end
			local dblock, dpos = getPlacedBlock(pos)
			if not dblock then return end
			-- The route is meant to avoid these already; this catches the case where the
			-- target itself is one of your own blocks.
			if avoidOwn and dblock:GetAttribute('PlacedByUserId') == lplr.UserId then return end

			if autoTool ~= false and (autoTool or (workspace:GetServerTimeNow() - bedwars.SwordController.lastAttack) > 0.4) then
				equipBreakTool(dblock)
			end

			if blockhealthbar.blockHealth == -1 or dpos ~= blockhealthbar.breakingBlockPosition then
				blockhealthbar.blockHealth = getBlockHealth(dblock, dpos)
				blockhealthbar.breakingBlockPosition = dpos
			end

			bedwars.ClientDamageBlock:Get('DamageBlock'):CallServerAsync({
				blockRef = {blockPosition = dpos},
				hitPosition = pos,
				hitNormal = Vector3.FromNormalId(Enum.NormalId.Top)
			}):andThen(function(result)
				if result then
					if result == 'cancelled' then
						store.damageBlockFail = tick() + 1
						return
					end

					if effects then
						-- BlockBreakController builds a fresh blockBreaker (and with it the
						-- BlockHealthbar that actually draws the bar) when it re-enables, so
						-- the reference captured at load goes stale and the game's own
						-- healthbar quietly stops appearing. Resolve it live instead.
						local breaker = bedwars.Knit.Controllers.BlockBreakController.blockBreaker or bedwars.BlockBreaker
						local meta = bedwars.ItemMeta[dblock.Name]
						-- BlockHealthbar:show compares maxHealth against 0, so a nil one
						-- throws inside the promise and takes the whole break down with it.
						local maxhealth = dblock:GetAttribute('MaxHealth') or (meta and meta.block and meta.block.health) or 10
						local prehealth = blockhealthbar.blockHealth or maxhealth
						local blockdmg = prehealth - (result == 'destroyed' and 0 or (getBlockHealth(dblock, dpos) or 0))
						pcall(customHealthbar or breaker.updateHealthbar, breaker, {blockPosition = dpos}, prehealth, maxhealth, blockdmg, dblock)
						blockhealthbar.blockHealth = math.max(prehealth - blockdmg, 0)

						if blockhealthbar.blockHealth <= 0 then
							breaker.breakEffect:playBreak(dblock.Name, dpos, lplr)
							-- The maid moved onto the BlockHealthbar object; destroy() is what
							-- cleans it there. Throwing here rejects the DamageBlock promise
							-- and aborts the break, so both routes are guarded.
							pcall(function()
								if breaker.blockHealthbar then
									breaker.blockHealthbar:destroy()
								elseif breaker.healthbarMaid then
									breaker.healthbarMaid:DoCleaning()
								end
							end)
							blockhealthbar.breakingBlockPosition = Vector3.zero
						else
							breaker.breakEffect:playHit(dblock.Name, dpos, lplr)
						end
					end

					--[[
						Matched to what the game plays when you break a block by hand.

						The viewmodel animation asked for here was 15, FP_SWING_SWORD, when
						breaking plays 14, FP_USE_ITEM - so a pickaxe has been swinging like
						a sword all along, which is most of why it never looked right. Items
						may override that, which is how the odd tool gets its own swing.

						Nothing is cut off on a timer any more either. Waiting a fixed 0.3s
						and then stopping the track meant every break speed under that
						started the next swing on top of one still playing, and blocked the
						promise this runs inside for the same 0.3s. The game does not stop
						this animation by hand at all - it is left to finish.
					]]
					if anim then
						pcall(function()
							local held = store.hand.tool and bedwars.ItemMeta[store.hand.tool.Name]
							local swing = (held and held.breakBlockSwingAnimationOverride) or bedwars.AnimationType.FP_USE_ITEM
							bedwars.ViewmodelController:playAnimation(swing)
						end)

						-- The character swing is the half other players can see, so it stays
						-- - one at a time, replaced rather than layered.
						pcall(function()
							if swingtrack then
								swingtrack:Stop(SWING_FADE)
								swingtrack:Destroy()
								swingtrack = nil
							end

							local track = bedwars.AnimationUtil:playAnimation(lplr, bedwars.BlockController:getAnimationController():getAssetId(bedwars.AnimationType.SWORD_SWING))
							swingtrack = track
							endSwing(track)
						end)
					end
				end
			end)

			-- Replaced only when the dig moves to a different first block. Following an
			-- established route leaves it alone, and so does hitting the same block again:
			-- routes of the same length tie all the time and each recompute can hand back a
			-- different one of them, so rebuilding on every hit made a straight dig bend
			-- partway through for no reason anyone could see.
			--
			-- Built here rather than by the caller because breakBlock yields above, and by
			-- the time it returns the route may have been dropped from the cache.
			local followed = bestkey == -math.huge
			if options.Route and not followed and options.Route[1] ~= pos then
				routeFrom(pos, path, options.Route)
			end

			-- Returned whether or not effects are on. Without this a target that could not
			-- be reached was indistinguishable from a hit that landed, so the caller kept
			-- picking the same unreachable block instead of moving to the next one.
			return pos, path, target
		end
	end

	for _, v in Enum.NormalId:GetEnumItems() do
		table.insert(sides, Vector3.FromNormalId(v) * 3)
	end

	local function updateStore(new, old)
		if new.Bedwars ~= old.Bedwars then
			store.equippedKit = new.Bedwars.kit ~= 'none' and new.Bedwars.kit or ''
		end

		if new.Game ~= old.Game then
			store.matchState = new.Game.matchState
			store.queueType = new.Game.queueType or 'bedwars_test'
		end

		if new.Inventory ~= old.Inventory then
			local newinv = (new.Inventory and new.Inventory.observedInventory or {inventory = {}})
			local oldinv = (old.Inventory and old.Inventory.observedInventory or {inventory = {}})
			store.inventory = newinv

			if newinv ~= oldinv then
				vainEvents.InventoryChanged:Fire()
			end

			if newinv.inventory.items ~= oldinv.inventory.items then
				vainEvents.InventoryAmountChanged:Fire()
				store.tools.sword = getSword()
				for _, v in {'stone', 'wood', 'wool'} do
					store.tools[v] = getTool(v)
				end
			end

			if newinv.inventory.hand ~= oldinv.inventory.hand then
				local currentHand, toolType = new.Inventory.observedInventory.inventory.hand, ''
				if currentHand then
					local handData = bedwars.ItemMeta[currentHand.itemType]
					toolType = handData.sword and 'sword' or handData.block and 'block' or currentHand.itemType:find('bow') and 'bow'
				end

				store.hand = {
					tool = currentHand and currentHand.tool,
					amount = currentHand and currentHand.amount or 0,
					toolType = toolType
				}
			end
		end
	end

	local storeChanged = bedwars.Store.changed:connect(updateStore)
	updateStore(bedwars.Store:getState(), {})

	for _, event in {'MatchEndEvent', 'EntityDeathEvent', 'BedwarsBedBreak', 'BalloonPopped', 'AngelProgress', 'GrapplingHookFunctions'} do
		if not vain.Connections then return end
		bedwars.Client:WaitFor(event):andThen(function(connection)
			vain:Clean(connection:Connect(function(...)
				vainEvents[event]:Fire(...)
			end))
		end)
	end

	-- Backs the 'Final Kill' target mode. brokenBedTeam.id is keyed the same way as a
	-- player's Team attribute, so it can be compared directly when sorting targets.
	vain:Clean(vainEvents.BedwarsBedBreak.Event:Connect(function(bedTable)
		if bedTable and bedTable.brokenBedTeam then
			brokenbeds[bedTable.brokenBedTeam.id] = true
		end
	end))
	vain:Clean(vainEvents.MatchEndEvent.Event:Connect(function()
		table.clear(brokenbeds)
	end))

	vain:Clean(bedwars.ZapNetworking.EntityDamageEventZap.On(function(...)
		vainEvents.EntityDamageEvent:Fire({
			entityInstance = ...,
			damage = select(2, ...),
			damageType = select(3, ...),
			fromPosition = select(4, ...),
			fromEntity = select(5, ...),
			knockbackMultiplier = select(6, ...),
			knockbackId = select(7, ...),
			disableDamageHighlight = select(13, ...)
		})
	end))

	for _, event in {'PlaceBlockEvent', 'BreakBlockEvent'} do
		vain:Clean(bedwars.ZapNetworking[event..'Zap'].On(function(...)
			local data = {
				blockRef = {
					blockPosition = ...,
				},
				player = select(5, ...)
			}
			for i, v in cache do
				if ((data.blockRef.blockPosition * 3) - v[1]).Magnitude <= 30 then
					-- The route table is handed out by breakBlock, which yields before it
					-- returns - emptying it here left the caller holding an empty route and
					-- no way to carry on down the hole it had started.
					table.clear(v)
					cache[i] = nil
				end
			end
			vainEvents[event]:Fire(data)
		end))
	end

	store.blocks = collection('block', gui)
	store.shop = collection({'BedwarsItemShop', 'TeamUpgradeShopkeeper'}, gui, function(tab, obj)
		table.insert(tab, {
			Id = obj.Name,
			RootPart = obj,
			Shop = obj:HasTag('BedwarsItemShop'),
			Upgrades = obj:HasTag('TeamUpgradeShopkeeper')
		})
	end)
	store.enchant = collection({'enchant-table', 'broken-enchant-table'}, gui, nil, function(tab, obj, tag)
		if obj:HasTag('enchant-table') and tag == 'broken-enchant-table' then return end
		obj = table.find(tab, obj)
		if obj then
			table.remove(tab, obj)
		end
	end)

	local kills = sessioninfo:AddItem('Kills')
	local beds = sessioninfo:AddItem('Beds')
	local wins = sessioninfo:AddItem('Wins')
	local games = sessioninfo:AddItem('Games')

	local mapname = 'Unknown'
	sessioninfo:AddItem('Map', 0, function()
		return mapname
	end, false)

	task.delay(1, function()
		games:Increment()
	end)

	task.spawn(function()
		pcall(function()
			repeat task.wait() until store.matchState ~= 0 or vain.Loaded == nil
			if vain.Loaded == nil then return end
			mapname = workspace:WaitForChild('Map', 5):WaitForChild('Worlds', 5):GetChildren()[1].Name
			mapname = string.gsub(string.split(mapname, '_')[2] or mapname, '-', '') or 'Blank'
		end)
	end)

	vain:Clean(vainEvents.BedwarsBedBreak.Event:Connect(function(bedTable)
		if bedTable.player and bedTable.player.UserId == lplr.UserId then
			beds:Increment()
		end
	end))

	vain:Clean(vainEvents.MatchEndEvent.Event:Connect(function(winTable)
		if (bedwars.Store:getState().Game.myTeam or {}).id == winTable.winningTeamId or lplr.Neutral then
			wins:Increment()
		end
	end))

	vain:Clean(vainEvents.EntityDeathEvent.Event:Connect(function(deathTable)
		local killer = playersService:GetPlayerFromCharacter(deathTable.fromEntity)
		local killed = playersService:GetPlayerFromCharacter(deathTable.entityInstance)
		if not killed or not killer then return end

		if killed ~= lplr and killer == lplr then
			kills:Increment()
		end
	end))

	task.spawn(function()
		repeat
			if entitylib.isAlive then
				entitylib.character.AirTime = entitylib.character.Humanoid.FloorMaterial ~= Enum.Material.Air and tick() or entitylib.character.AirTime
			end

			for _, v in entitylib.List do
				v.LandTick = math.abs(v.RootPart.Velocity.Y) < 0.1 and v.LandTick or tick()
				if (tick() - v.LandTick) > 0.2 and v.Jumps ~= 0 then
					v.Jumps = 0
					v.Jumping = false
				end
			end
			task.wait()
		until vain.Loaded == nil
	end)

	pcall(function()
		if getthreadidentity and setthreadidentity then
			local old = getthreadidentity()
			setthreadidentity(2)

			-- The restore has to happen whether or not the shop loads. It used to sit at
			-- the end of this block, so anything throwing above it - the require, or
			-- getShopItem against a changed shop - left the thread at identity 2 for good.
			-- Every module file loads after this point, and at identity 2 they cannot
			-- parent an Instance, so module creation failed with "lacking capability
			-- Plugin" and the failure looked like it came from whichever module happened
			-- to be next.
			local ok = pcall(function()
				bedwars.Shop = require(replicatedStorage.TS.games.bedwars.shop['bedwars-shop']).BedwarsShop
				bedwars.ShopItems = debug.getupvalue(debug.getupvalue(bedwars.Shop.getShopItem, 1), 2)
				bedwars.Shop.getShopItem('iron_sword', lplr)
			end)

			setthreadidentity(old)
			store.shopLoaded = ok
		else
			task.spawn(function()
				repeat
					task.wait(0.1)
				until vain.Loaded == nil or bedwars.AppController:isAppOpen('BedwarsItemShopApp')

				bedwars.Shop = require(replicatedStorage.TS.games.bedwars.shop['bedwars-shop']).BedwarsShop
				bedwars.ShopItems = debug.getupvalue(debug.getupvalue(bedwars.Shop.getShopItem, 1), 2)
				store.shopLoaded = true
			end)
		end
	end)

	vain:Clean(function()
		Client.Get = OldGet
		bedwars.BlockController.isBlockBreakable = OldBreak
		store.blockPlacer:disable()
		for _, v in vainEvents do
			v:Destroy()
		end
		for _, v in cache do
			table.clear(v[3])
			table.clear(v)
		end
		table.clear(store.blockPlacer)
		table.clear(vainEvents)
		table.clear(bedwars)
		table.clear(store)
		table.clear(cache)
		table.clear(sides)
		table.clear(remotes)
		storeChanged:disconnect()
		storeChanged = nil
	end)
end)

for _, v in {'AntiRagdoll', 'TriggerBot', 'SilentAim', 'AutoRejoin', 'Rejoin', 'Disabler', 'Timer', 'ServerHop', 'MouseTP', 'MurderMystery'} do
	vain:Remove(v)
end