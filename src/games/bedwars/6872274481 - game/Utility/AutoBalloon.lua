local AutoBalloon
local Legit
local inflating = false

local function hotbarSlot(itemType)
	for i, v in store.inventory.hotbar do
		if v.item and v.item.itemType == itemType then
			return i - 1
		end
	end
end

-- The action the game binds while a balloon is in your hand. It only exists once the
-- balloon is actually held, which is the whole point of equipping first.
local function boundInflate()
	local binder = bedwars.ActionBinder
	local action = binder and binder.registeredActions and binder.registeredActions['inflate-balloon']
	return action and action.boundFunction or nil
end

--[[
	Blatant sends the inflate straight off without the balloon ever being in your hand.

	Legit equips it first and then runs the same bound action your mouse button would.
	Equipping is what turns the balloon's own handler on, so the animation plays and the
	cooldown is respected rather than being reimplemented here; nothing is sent by hand.

	Falls back to the controller call when the action has not appeared, so a slow equip
	still gets you out of the void rather than doing nothing at all.
]]
local function legitInflate()
	local balloon = getItem('balloon')
	if not balloon or not balloon.tool then return end

	local previous = store.hand.tool
	local slot = hotbarSlot('balloon')
	if slot then
		hotbarSwitch(slot)
	end
	switchItem(balloon.tool)

	local run
	for _ = 1, 20 do
		run = boundInflate()
		if run then break end
		task.wait()
	end

	for _ = 1, 3 do
		if (lplr.Character:GetAttribute('InflatedBalloons') or 0) >= 3 then break end

		if run then
			run('inflate-balloon', Enum.UserInputState.Begin, newproxy(true))
		else
			bedwars.BalloonController:inflateBalloon()
		end
		task.wait(0.1)
	end

	-- Put back whatever was in your hand, the same as AutoConsume does, so being saved
	-- does not also disarm you.
	if previous and previous.Parent then
		pcall(switchItem, previous)
	end
end

AutoBalloon = vain.Categories.Utility:CreateModule({
	Name = 'AutoBalloon',
	Function = function(callback)
		if callback then
			repeat task.wait() until store.matchState ~= 0 or (not AutoBalloon.Enabled)
			if not AutoBalloon.Enabled then return end

			local lowestpoint = math.huge
			for _, v in store.blocks do
				local point = (v.Position.Y - (v.Size.Y / 2)) - 50
				if point < lowestpoint then 
					lowestpoint = point 
				end
			end

			repeat
				if entitylib.isAlive then
					if entitylib.character.RootPart.Position.Y < lowestpoint and (lplr.Character:GetAttribute('InflatedBalloons') or 0) < 3 then
						local balloon = getItem('balloon')
						if balloon then
							if Legit.Enabled then
								-- Guarded because this one yields, on the equip and between
								-- inflates, so a pass could otherwise start on top of itself.
								if not inflating then
									inflating = true
									pcall(legitInflate)
									inflating = false
								end
							else
								for _ = 1, 3 do 
									bedwars.BalloonController:inflateBalloon() 
								end
							end
						end
						task.wait(0.1)
					end
				end
				task.wait(0.1)
			until not AutoBalloon.Enabled
		else
			inflating = false
		end
	end,
	Tooltip = 'Inflates when you fall into the void'
})
Legit = AutoBalloon:CreateToggle({
	Name = 'Legit',
	Tooltip = 'Holds the balloon before inflating it'
})
