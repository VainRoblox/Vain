local AutoConsume
local Legit
local Health
local SpeedPotion
local SpeedPie
local JumpPotion
local Invisibility
local Apple
local GoldenApple
local ShieldPotion
local potions
local consuming = false
local lastHealth

--[[
	Blatant sends the consume straight off without the item ever being in your hand.

	Legit hands the job back to the game. Equipping a consumable turns on that item's own
	handler, which binds an action called 'consume-item' - the one your mouse button runs.
	Calling that same bound function is what plays the animation, starts the hold, and
	consumes when the hold finishes, cooldown checks and all. Nothing here reimplements
	any of it, and no consume is sent by hand, so nothing can be double-consumed either.

	Equipping only through switchItem was why this looked broken before: that sets the
	held item without the hotbar following, so the game never turned the item's handler
	on, there was no animation, and all that happened was a flicker before something else
	took the hand back.
]]
local function consumeTime(item)
	local meta = bedwars.ItemMeta[item.itemType]
	local consumable = meta and meta.consumable
	return (consumable and consumable.consumeTime) or 1
end

local function hotbarSlot(itemType)
	for i, v in store.inventory.hotbar do
		if v.item and v.item.itemType == itemType then
			return i - 1
		end
	end
end

local function boundConsume()
	local binder = bedwars.ActionBinder
	local action = binder and binder.registeredActions and binder.registeredActions['consume-item']
	return action and action.boundFunction or nil
end

local function legitConsume(item)
	if consuming then return end
	consuming = true

	task.spawn(function()
		local previous = store.hand.tool
		pcall(function()
			local slot = hotbarSlot(item.itemType)
			if slot then
				hotbarSwitch(slot)
			end
			switchItem(item.tool)

			-- The handler binds itself once the item is actually in hand, so wait for it
			-- rather than assuming it is already there.
			local run
			for _ = 1, 20 do
				run = boundConsume()
				if run then break end
				task.wait()
			end
			if not run then return end

			run('consume-item', Enum.UserInputState.Begin, newproxy(true))
			-- The hold finishes on its own and consumes; this only releases afterwards,
			-- the same as letting go of the button.
			task.wait(consumeTime(item) + 0.1)
			run('consume-item', Enum.UserInputState.End, newproxy(true))
		end)

		if previous and previous.Parent then
			pcall(switchItem, previous)
		end
		consuming = false
	end)
end

-- retry is for the potions, which are sometimes refused outright on the first call. The
-- food and shield paths never did this and are left alone.
local function consume(item, retry)
	if not (item and item.tool) then return end

	if Legit and Legit.Enabled then
		legitConsume(item)
		return
	end

	if retry then
		for _ = 1, 4 do
			if bedwars.Client:Get(remotes.ConsumeItem):CallServer({item = item.tool}) then break end
		end
		return
	end

	bedwars.Client:Get(remotes.ConsumeItem):CallServerAsync({item = item.tool})
end

local function hasEffect(effect)
	return lplr.Character and lplr.Character:GetAttribute('StatusEffect_'..effect)
end

--[[
	Food is only for the moment your health actually drops.

	Anything else that runs this check would otherwise reach for an apple purely because
	your health happened to be low at the time. Health ticking back up is a change, so
	regenerating ate the rest of the stack part way through the apple already working; and
	placing a block is an inventory change, so building while hurt started a consume on
	every single block and left you unable to build at all.

	The first look is allowed through, so switching this on while already hurt heals you
	rather than waiting for the next hit.
]]
local function healthDropped()
	local current = lplr.Character and lplr.Character:GetAttribute('Health')
	if not current then return false end

	local previous = lastHealth
	lastHealth = current
	return previous == nil or current < previous
end

local function consumeCheck(attribute)
	if not entitylib.isAlive then return end

	-- Worked out up front rather than inside the food branch, so the reading stays current
	-- even while food is switched off and there is no stale one to compare against later.
	local healthEvent = (not attribute) or attribute:find('Health') ~= nil
	local dropped = healthEvent and healthDropped()

	if potions then
		for _, potion in potions do
			if not potion.Toggle.Enabled then continue end
			if attribute and attribute ~= 'StatusEffect_'..potion.Effect then continue end
			if hasEffect(potion.Effect) then continue end

			local item = getItem(potion.Item)
			if item then
				consume(item, true)
			end
		end
	end

	if Apple.Enabled and healthEvent and dropped then
		if (lplr.Character:GetAttribute('Health') / lplr.Character:GetAttribute('MaxHealth')) <= (Health.Value / 100) then
			-- Golden apples come before plain ones, and only while their buff is not
			-- already running - eating a second one on top of the first is wasted.
			local apple = getItem('orange')
				or (GoldenApple.Enabled and not hasEffect('golden_apple') and getItem('golden_apple'))
				or getItem('apple')

			if apple then
				consume(apple)
			end
		end
	end

	if ShieldPotion.Enabled and (not attribute or attribute:find('Shield')) then
		if (lplr.Character:GetAttribute('Shield_POTION') or 0) == 0 then
			consume(getItem('big_shield') or getItem('mini_shield'))
		end
	end
end

AutoConsume = vain.Categories.Inventory:CreateModule({
	Name = 'AutoConsume',
	Function = function(callback)
		if callback then
			AutoConsume:Clean(vainEvents.InventoryAmountChanged.Event:Connect(consumeCheck))
			AutoConsume:Clean(vainEvents.AttributeChanged.Event:Connect(function(attribute)
				if attribute:find('Shield') or attribute:find('Health') or attribute:find('StatusEffect_') then
					consumeCheck(attribute)
				end
			end))
			consumeCheck()
		else
			consuming = false
			lastHealth = nil
		end
	end,
	Tooltip = 'Automatically heals for you when health or shield is under threshold.'
})
Legit = AutoConsume:CreateToggle({
	Name = 'Legit',
	Tooltip = 'Equips and uses items the way the game does'
})
Health = AutoConsume:CreateSlider({
	Name = 'Health Percent',
	Tooltip = 'Triggers once your health drops below this percentage',
	Min = 1,
	Max = 99,
	Default = 70,
	Suffix = '%'
})
SpeedPotion = AutoConsume:CreateToggle({
	Name = 'Speed Potions',
	Tooltip = 'Uses speed potions',
	Default = true
})
SpeedPie = AutoConsume:CreateToggle({
	Name = 'Speed Pie',
	Tooltip = 'Eats speed pies',
	Default = true
})
JumpPotion = AutoConsume:CreateToggle({
	Name = 'Jump Potions',
	Tooltip = 'Uses jump potions',
	Default = true
})
Invisibility = AutoConsume:CreateToggle({
	Name = 'Invisibility Potions',
	Tooltip = 'Uses invisibility potions',
	Default = true
})
Apple = AutoConsume:CreateToggle({
	Name = 'Apple',
	Tooltip = 'Eats apples',
	Default = true
})
GoldenApple = AutoConsume:CreateToggle({
	Name = 'Golden Apple',
	Tooltip = 'Eats golden apples before plain ones',
	Default = true,
	Darker = true
})
ShieldPotion = AutoConsume:CreateToggle({
	Name = 'Shield Potions',
	Tooltip = 'Uses shield potions',
	Default = true
})

-- Built once the toggles exist. Each is used whenever its effect is not already running.
potions = {
	{Toggle = SpeedPotion, Item = 'speed_potion', Effect = 'speed'},
	{Toggle = SpeedPie, Item = 'pie', Effect = 'speed_pie'},
	{Toggle = JumpPotion, Item = 'jump_potion', Effect = 'jump'},
	{Toggle = Invisibility, Item = 'invisibility_potion', Effect = 'invisibility'}
}
