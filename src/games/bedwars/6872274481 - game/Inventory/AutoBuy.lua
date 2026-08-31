local AutoBuy
local Armor
local Upgrades
local Preferred
local BedwarsCheck
local GUI
local SmartCheck
local Custom = {}
local CustomPost = {}
local UpgradeToggles = {}
-- Both directions of the preferred-upgrade dropdown: the toggle that governs an upgrade,
-- and the upgrade behind the display name the dropdown shows.
local UpgradeToggle = {}
local UpgradeByName = {}
local Functions, id = {}
local Callbacks = {Custom, Functions, CustomPost}
local npctick = tick()

local swords = {
	'wood_sword',
	'stone_sword',
	'iron_sword',
	'diamond_sword',
	'emerald_sword'
}

local armors = {
	'none',
	'leather_chestplate',
	'iron_chestplate',
	'diamond_chestplate',
	'emerald_chestplate'
}

local axes = {
	'none',
	'wood_axe',
	'stone_axe',
	'iron_axe',
	'diamond_axe'
}

local pickaxes = {
	'none',
	'wood_pickaxe',
	'stone_pickaxe',
	'iron_pickaxe',
	'diamond_pickaxe'
}

-- Where iron armor sits on the ladder, which is as far as smart check waits.
local IRON_ARMOR = 3

-- What you are wearing, as a rung on the armors ladder, or nil for armor that is not on
-- it at all - a kit chestplate, say. Worked out in one place because the two that did it
-- separately disagreed: one fell back to getBestArmor and the other did not, so smart
-- check and the armor buying could each think you were wearing something different.
local function armorTier()
	local worn = store.inventory.inventory.armor[2]
	worn = (worn and worn ~= 'empty') and worn or getBestArmor(1)
	return table.find(armors, worn and worn.itemType or 'none')
end

--[[
	Smart check keeps everything in reserve until iron armor is on. Nothing else is worth
	spending on while you are still in leather, and it is the same iron either way, so a
	pickaxe bought now is iron armor you cannot afford later.

	Team upgrades are deliberately not held back: they are bought with diamonds and never
	compete for the iron this is saving.

	Without Buy Armor there is nothing to wait for - the armor it is holding out for would
	never be bought - so it would block every purchase for the whole game. It stands down
	instead.
]]
local function savingForArmor()
	if not (SmartCheck.Enabled and Armor.Enabled) then return false end
	-- Armor that is not on the ladder cannot be compared against iron, and holding every
	-- purchase back on something that can never be resolved would stall the whole module.
	local tier = armorTier()
	return tier ~= nil and tier < IRON_ARMOR
end

local function getShopNPC()
	local shop, items, upgrades, newid = nil, false, false, nil
	if entitylib.isAlive then
		local localPosition = entitylib.character.RootPart.Position
		for _, v in store.shop do
			if (v.RootPart.Position - localPosition).Magnitude <= 20 then
				shop = v.Upgrades or v.Shop or nil
				upgrades = upgrades or v.Upgrades
				items = items or v.Shop
				newid = v.Shop and v.Id or newid
			end
		end
	end
	return shop, items, upgrades, newid
end

local function canBuy(item, currencytable, amount)
	amount = amount or 1
	if not currencytable[item.currency] then
		local currency = getItem(item.currency)
		currencytable[item.currency] = currency and currency.amount or 0
	end
	if item.ignoredByKit and table.find(item.ignoredByKit, store.equippedKit or '') then return false end
	if item.lockedByForge or item.disabled then return false end
	if item.require and item.require.teamUpgrade then
		-- teamUpgrades is keyed by team and holds a table per team; your own tiers are
		-- the flat map in myTeamUpgrades. Indexing the outer one by an upgrade id only
		-- ever came back nil, so this read as "tier -1" and refused the item outright.
		local mine = bedwars.Store:getState().Bedwars.myTeamUpgrades or {}
		if (mine[item.require.teamUpgrade.upgradeId] or -1) < item.require.teamUpgrade.lowestTierIndex then
			return false
		end
	end
	return currencytable[item.currency] >= (item.price * amount)
end

local function buyItem(item, currencytable)
	if not id then return end
	notif('AutoBuy', 'Bought '..bedwars.ItemMeta[item.itemType].displayName, 3)
	bedwars.Client:Get('BedwarsPurchaseItem'):CallServerAsync({
		shopItem = item,
		shopId = id
	}):andThen(function(suc)
		if suc then
			bedwars.SoundManager:playSound(bedwars.SoundList.BEDWARS_PURCHASE_ITEM)
			bedwars.Store:dispatch({
				type = 'BedwarsAddItemPurchased',
				itemType = item.itemType
			})
			bedwars.BedwarsShopController.alreadyPurchasedMap[item.itemType] = true
		end
	end)
	currencytable[item.currency] -= item.price
end

-- Which tier of an upgrade your team is on. The store keeps your own tiers in the flat
-- myTeamUpgrades map; teamUpgrades is keyed by team, and it starts empty and only fills
-- once somebody has actually bought something, so reading tiers out of it reported tier
-- zero for the whole match.
local function upgradeTier(upgradeType)
	local mine = bedwars.Store:getState().Bedwars.myTeamUpgrades or {}
	return mine[upgradeType] or 0
end

--[[
	The upgrade everything else is waiting on, if any.

	It only counts while there is something to wait for. An upgrade whose own toggle is
	off is never going to be bought, and one this queue does not offer cannot be bought at
	all - waiting on either would stall every other upgrade for the rest of the game.
]]
local function pendingPreferred(meta)
	local want = Preferred and Preferred.Value
	if not want or want == 'None' then return nil end

	local upgradeType = UpgradeByName[want]
	local upgrade = upgradeType and meta[upgradeType]
	if not upgrade then return nil end

	local toggle = UpgradeToggle[upgradeType]
	if not (toggle and toggle.Enabled) then return nil end
	if upgradeTier(upgradeType) >= #upgrade.tiers then return nil end

	return upgradeType
end

local function buyUpgrade(upgradeType, currencytable)
	if not Upgrades.Enabled then return end

	local meta = (bedwars.getTeamUpgradeMeta and bedwars.getTeamUpgradeMeta()) or bedwars.TeamUpgradeMeta
	local upgrade = meta[upgradeType]
	-- This queue does not run this upgrade at all.
	if not upgrade then return false end

	-- Everything else stands aside until the preferred upgrade has no tiers left, so the
	-- diamonds finish it off rather than being spread a tier at a time across all of them.
	local pending = pendingPreferred(meta)
	if pending and pending ~= upgradeType then return false end

	local currentTier = upgradeTier(upgradeType) + 1

	if currentTier <= #upgrade.tiers then
		local tier = upgrade.tiers[currentTier]
		if tier.availableOnlyInQueue and not table.find(tier.availableOnlyInQueue, store.queueType) then return false end

		if canBuy({currency = 'diamond', price = tier.cost}, currencytable) then
			notif('AutoBuy', 'Bought '..(upgrade.name == 'Armor' and 'Protection' or upgrade.name)..' '..currentTier, 3)
			bedwars.Client:Get('RequestPurchaseTeamUpgrade'):CallServerAsync(upgradeType)
			currencytable.diamond -= tier.cost
			return true
		end
	end

	return false
end

--[[
	Buys the one tier above whatever you are holding, and nothing else.

	The shop only ever sells the step immediately after what you own - iron armor is not
	on sale until leather is on your back - so scanning up the ladder for the first tier
	you could afford was never right. With enough of the wrong currency it would settle on
	a later tier, hand the server a purchase that could not be made, and buy nothing at
	all. That is what the tier check was papering over, so the check is gone and the
	one-step rule is simply always applied.

	One tier a pass still climbs quickly, since the buying loop comes round again 0.4s
	later with the new tier as the starting point.
]]
local function buyTool(tool, tools, currencytable)
	-- No tool at all starts below the ladder, so the first rung is what gets bought.
	-- Lists that carry a 'none' rung of their own pass it in instead.
	local tier = 0
	if tool then
		tier = table.find(tools, tool.itemType)
		-- Holding something that is not on this ladder - a kit weapon, say. There is no
		-- next step to work out from it, so it is left alone.
		if not tier then return false end
	end

	local upgrade = tools[tier + 1]
	if not upgrade then return false end

	local v = bedwars.Shop.getShopItem(upgrade, lplr)
	if not (v and canBuy(v, currencytable)) then return false end

	buyItem(v, currencytable)
	return true
end

AutoBuy = vain.Categories.Inventory:CreateModule({
	Name = 'AutoBuy',
	Function = function(callback)
		if callback then
			repeat task.wait() until store.queueType ~= 'bedwars_test'
			if BedwarsCheck.Enabled and not store.queueType:find('bedwars') then return end

			local lastupgrades
			AutoBuy:Clean(vainEvents.InventoryAmountChanged.Event:Connect(function()
				if (npctick - tick()) > 1 then npctick = tick() end
			end))

			repeat
				local npc, shop, upgrades, newid = getShopNPC()
				id = newid
				if GUI.Enabled then
					if not (bedwars.AppController:isAppOpen('BedwarsItemShopApp') or bedwars.AppController:isAppOpen('TeamUpgradeApp')) then
						npc = nil
					end
				end

				if npc and lastupgrades ~= upgrades then
					if (npctick - tick()) > 1 then npctick = tick() end
					lastupgrades = upgrades
				end

				if npc and npctick <= tick() and store.matchState ~= 2 and store.shopLoaded then
					local currencytable = {}
					local waitcheck
					for _, tab in Callbacks do
						for _, callback in tab do
							if callback(currencytable, shop, upgrades) then
								waitcheck = true
							end
						end
					end
					npctick = tick() + (waitcheck and 0.4 or math.huge)
				end

				task.wait(0.1)
			until not AutoBuy.Enabled
		else
			npctick = tick()
		end
	end,
	Tooltip = 'Automatically buys items when you go near the shop'
})
AutoBuy:CreateToggle({
	Name = 'Buy Sword',
	Tooltip = 'Automatically buys a sword upgrade',
	Function = function(callback)
		npctick = tick()
		Functions[2] = callback and function(currencytable, shop)
			if not shop then return end

			if store.equippedKit == 'dasher' then
				swords = {
					[1] = 'wood_dao',
					[2] = 'stone_dao',
					[3] = 'iron_dao',
					[4] = 'diamond_dao',
					[5] = 'emerald_dao'
				}
			elseif store.equippedKit == 'ice_queen' then
				swords[5] = 'ice_sword'
			elseif store.equippedKit == 'ember' then
				swords[5] = 'infernal_saber'
			elseif store.equippedKit == 'lumen' then
				swords[5] = 'light_sword'
			end

			if savingForArmor() then return end
			return buyTool(store.tools.sword, swords, currencytable)
		end or nil
	end
})
Armor = AutoBuy:CreateToggle({
	Name = 'Buy Armor',
	Tooltip = 'Automatically buys armor',
	Function = function(callback)
		npctick = tick()
		Functions[1] = callback and function(currencytable, shop)
			if not shop then return end
			-- Never held back by smart check: this is the purchase it is saving for.
			local tier = armorTier()
			return tier ~= nil and buyTool({itemType = armors[tier]}, armors, currencytable)
		end or nil
	end,
	Default = true
})
AutoBuy:CreateToggle({
	Name = 'Buy Axe',
	Tooltip = 'Automatically buys an axe',
	Function = function(callback)
		npctick = tick()
		Functions[3] = callback and function(currencytable, shop)
			if not shop then return end
			if savingForArmor() then return end
			return buyTool(store.tools.wood or {itemType = 'none'}, axes, currencytable)
		end or nil
	end
})
AutoBuy:CreateToggle({
	Name = 'Buy Pickaxe',
	Tooltip = 'Automatically buys a pickaxe',
	Function = function(callback)
		npctick = tick()
		Functions[4] = callback and function(currencytable, shop)
			if not shop then return end
			if savingForArmor() then return end
			-- Owning no pickaxe at all used to start the search past the end of the
			-- ladder, so the very first one was never bought. The axe side already passes
			-- the 'none' rung in; this now does the same.
			return buyTool(store.tools.stone or {itemType = 'none'}, pickaxes, currencytable)
		end or nil
	end
})
Upgrades = AutoBuy:CreateToggle({
	Name = 'Buy Upgrades',
	Tooltip = 'Automatically buys team upgrades',
	Function = function(callback)
		for _, v in UpgradeToggles do
			v.Object.Visible = callback
		end
	end,
	Default = true
})
local count = 0
-- 'None' first so the dropdown opens on it and nothing is held back by default.
local upgradeNames = {'None'}
for i, v in bedwars.TeamUpgradeMeta do
	local toggleCount = count
	local displayName = (v.name == 'Armor' and 'Protection' or v.name)
	local toggle = AutoBuy:CreateToggle({
		Name = 'Buy '..displayName,
		Function = function(callback)
			npctick = tick()
			Functions[5 + toggleCount + (v.name == 'Armor' and 20 or 0)] = callback and function(currencytable, shop, upgrades)
				if not upgrades then return end
				if v.disabledInQueue and table.find(v.disabledInQueue, store.queueType) then return end
				return buyUpgrade(i, currencytable)
			end or nil
		end,
		Darker = true,
		Default = (i == 'ARMOR' or i == 'DAMAGE')
	})
	table.insert(UpgradeToggles, toggle)
	-- Both directions are kept: the upgrade behind a display name, so the dropdown can
	-- name one, and the toggle that decides whether it is ever bought.
	UpgradeToggle[i] = toggle
	UpgradeByName[displayName] = i
	table.insert(upgradeNames, displayName)
	count += 1
end
-- The meta is a hash, so it comes out in a different order every session. Only the names
-- after 'None' are sorted, since 'None' has to stay first: the dropdown ignores Default
-- and always opens on the first entry.
table.sort(upgradeNames, function(a, b)
	if a == 'None' or b == 'None' then return a == 'None' end
	return a < b
end)
Preferred = AutoBuy:CreateDropdown({
	Name = 'Preferred Upgrade',
	Tooltip = 'Maxes this one before any other',
	Function = function()
		npctick = tick()
	end,
	List = upgradeNames,
	Darker = true
})
-- Hidden and shown with the rest of the upgrade settings.
table.insert(UpgradeToggles, Preferred)
BedwarsCheck = AutoBuy:CreateToggle({
	Name = 'Only Bedwars',
	Tooltip = 'Only runs while in a bedwars queue',
	Function = function()
		if AutoBuy.Enabled then
			AutoBuy:Toggle()
			AutoBuy:Toggle()
		end
	end,
	Default = true
})
GUI = AutoBuy:CreateToggle({Name = 'GUI check', Tooltip = 'Stops acting while a game menu is open'})
SmartCheck = AutoBuy:CreateToggle({
	Name = 'Smart check',
	Default = true,
	Tooltip = 'Saves everything for iron armor first\nNeeds Buy Armor on'
})
AutoBuy:CreateTextList({
	Name = 'Item',
	Tooltip = 'Which items this applies to',
	Placeholder = 'priority/item/amount/after',
	Function = function(list)
		table.clear(Custom)
		table.clear(CustomPost)
		for _, entry in list do
			local tab = entry:split('/')
			local ind = tonumber(tab[1])
			if ind then
				(tab[4] and CustomPost or Custom)[ind] = function(currencytable, shop)
					if not shop then return end
					-- Held back too: these are bought with the same iron the armor needs,
					-- so buying them first is why there was none left for it.
					if savingForArmor() then return end

					local v = bedwars.Shop.getShopItem(tab[2], lplr)
					if v then
						-- getTeamWool was renamed getTeamWoolById upstream; same signature
						-- (team id in, wool ItemType out).
						local item = getItem(tab[2] == 'wool_white' and bedwars.Shop.getTeamWoolById(lplr:GetAttribute('Team')) or tab[2])
						item = (item and tonumber(tab[3]) - item.amount or tonumber(tab[3])) // v.amount
						if item > 0 and canBuy(v, currencytable, item) then
							for _ = 1, item do
								buyItem(v, currencytable)
							end
							return true
						end
					end
				end
			end
		end
	end
})