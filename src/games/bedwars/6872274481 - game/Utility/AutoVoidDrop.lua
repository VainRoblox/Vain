local AutoVoidDrop
local OwlCheck
local Delay

AutoVoidDrop = vain.Categories.Utility:CreateModule({
	Name = 'AutoVoidDrop',
	Function = function(callback)
		if callback then
			repeat task.wait() until store.matchState ~= 0 or (not AutoVoidDrop.Enabled)
			if not AutoVoidDrop.Enabled then return end

			local lowestpoint = math.huge
			for _, v in store.blocks do
				local point = (v.Position.Y - (v.Size.Y / 2)) - 50
				if point < lowestpoint then
					lowestpoint = point
				end
			end

			repeat
				if entitylib.isAlive then
					local root = entitylib.character.RootPart
					if root.Position.Y < lowestpoint and (lplr.Character:GetAttribute('InflatedBalloons') or 0) <= 0 and not getItem('balloon') then
						if not OwlCheck.Enabled or not root:FindFirstChild('OwlLiftForce') then
							local dropped = false
							for _, item in {'iron', 'diamond', 'emerald', 'gold'} do
								item = getItem(item)
								if item then
									--[[
										A pause between kinds, not between stacks.

										Only paid once something has actually gone out, and only
										before the next kind - so a void fall with just iron on
										you drops immediately, and one carrying iron and gold
										waits the delay in between.
									]]
									if dropped and Delay and Delay.Value > 0 then
										task.wait(Delay.Value)
										if not (AutoVoidDrop.Enabled and entitylib.isAlive) then break end
									end

									local result = bedwars.Client:Get(remotes.DropItem):CallServer({
										item = item.tool,
										amount = item.amount
									})

									if result then
										result:SetAttribute('ClientDropTime', tick() + 100)
									end
									dropped = true
								end
							end
						end
					end
				end

				task.wait(0.1)
			until not AutoVoidDrop.Enabled
		end
	end,
	Tooltip = 'Drops resources when you fall into the void'
})
OwlCheck = AutoVoidDrop:CreateToggle({
	Name = 'Owl check',
	Default = true,
	Tooltip = 'Refuses to drop items if being picked up by an owl'
})
Delay = AutoVoidDrop:CreateSlider({
	Name = 'Delay',
	Min = 0,
	Max = 3,
	Default = 0,
	Decimal = 10,
	Suffix = 's',
	Tooltip = 'Wait this long between dropping each kind of item, e.g. iron then gold'
})