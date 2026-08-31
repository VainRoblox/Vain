local AutoShoot
local Startup
local Speed
local Return
local shooting, old = false

local function getCrossbows()
	local crossbows = {}
	for i, v in store.inventory.hotbar do
		if v.item and v.item.itemType:find('crossbow') and i ~= (store.inventory.hotbarSlot + 1) then table.insert(crossbows, i - 1) end
	end
	return crossbows
end

--[[
	Whether a shot you just took is one worth following up on.

	The arguments are the ones the game calls this with, self included - it is invoked as
	a method, so the first of them is the controller rather than the projectile source.
	Reading them one across is why the source check here was really testing the controller,
	which is never nil.

	Matched loosely on purpose: the ammo you loaded and the projectile it turned into do
	not share a name once a crossbow is involved, and iron, firework and volley arrows are
	all arrows as far as this is concerned.
]]
local function isShot(ammoType, projectileType)
	for _, v in {ammoType, projectileType} do
		if type(v) == 'string' and (v:find('arrow') or v:find('fireball')) then
			return true
		end
	end
	return false
end

local function fireCrossbows()
	local selected = store.inventory.hotbarSlot

	for _, v in getCrossbows() do
		if not AutoShoot.Enabled or not entitylib.isAlive then break end

		if hotbarSwitch(v) then
			task.wait(Speed.Value)
			-- Guarded the way every other clicking module guards it. Called bare, this
			-- threw on any executor without it and, with nothing to catch it, left the
			-- shooting flag stuck on - after which the macro never ran again.
			if mouse1click and (isrbxactive or iswindowactive)() then
				mouse1click()
			end
			task.wait(Speed.Value)
		end
	end

	if Return.Enabled then
		hotbarSwitch(selected)
	end
end

AutoShoot = vain.Categories.Utility:CreateModule({
	Name = 'AutoShoot',
	Function = function(callback)
		if callback then
			old = bedwars.ProjectileController.createLocalProjectile
			bedwars.ProjectileController.createLocalProjectile = function(...)
				local _, _, ammoType, projectileType = ...
				if isShot(ammoType, projectileType) and not shooting and #getCrossbows() > 0 then
					task.spawn(function()
						shooting = true
						-- Wrapped so a throw anywhere in here cannot leave the flag set and
						-- kill the module for the rest of the round.
						pcall(function()
							task.wait(Startup.Value)
							fireCrossbows()
						end)
						shooting = false
					end)
				end
				return old(...)
			end
		else
			shooting = false
			if old then
				bedwars.ProjectileController.createLocalProjectile = old
			end
		end
	end,
	Tooltip = 'Fires your other crossbows after a shot'
})
Startup = AutoShoot:CreateSlider({
	Name = 'Startup',
	Tooltip = 'Wait before the macro begins\nDefault is 0.15',
	Min = 0,
	Max = 1,
	Default = 0.15,
	Decimal = 100,
	Suffix = 'seconds'
})
Speed = AutoShoot:CreateSlider({
	Name = 'Speed',
	Tooltip = 'Wait around each shot, lower is faster\nDefault is 0.05',
	Min = 0,
	Max = 0.5,
	Default = 0.05,
	Decimal = 100,
	Suffix = 'seconds'
})
Return = AutoShoot:CreateToggle({
	Name = 'Return',
	Tooltip = 'Switches back to the slot you were on',
	Default = true
})
