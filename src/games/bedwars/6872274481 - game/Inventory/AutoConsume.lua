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

--[[
	Blatant sends the consume straight off without the item ever being in your hand.

	Legit does what the game does: the item is equipped, held for exactly as long as that
	item takes to consume, and only then does the consume go out. Nothing about the timing
	is skipped, and whatever you were holding comes back afterwards.
]]
local function consumeTime(item)
	local meta = bedwars.ItemMeta[item.itemType]
	local consumable = meta and meta.consumable
	return (consumable and consumable.consumeTime) or 1
end

local function legitConsume(item)
	if consuming then return end
	consuming = true

	task.spawn(function()
		local previous = store.hand.tool
		pcall(function()
			switchItem(item.tool)
			task.wait(consumeTime(item))
			-- Checked again on the far side of the wait: a second is long enough to die,
			-- drop the item, or no longer need it.
			if entitylib.isAlive and item.tool and item.tool.Parent then
				bedwars.Client:Get(remotes.ConsumeItem):CallServer({item = item.tool})
			end
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

local function consumeCheck(attribute)
	if not entitylib.isAlive then return end

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

	if Apple.Enabled and (not attribute or attribute:find('Health')) then
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
