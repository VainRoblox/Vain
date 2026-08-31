local ArmorSwitch
local Mode
local Targets
local Range
local Speed

ArmorSwitch = vain.Categories.Inventory:CreateModule({
	Name = 'ArmorSwitch',
	Function = function(callback)
		if callback then
			if Mode.Value == 'Toggle' then
				repeat
					local state = entitylib.EntityPosition({
						Part = 'RootPart',
						Range = Range.Value,
						Players = Targets.Players.Enabled,
						NPCs = Targets.NPCs.Enabled,
						Wallcheck = Targets.Walls.Enabled
					}) and true or false

					for i = 0, 2 do
						if (store.inventory.inventory.armor[i + 1] ~= 'empty') ~= state and ArmorSwitch.Enabled then
							bedwars.Store:dispatch({
								type = 'InventorySetArmorItem',
								item = store.inventory.inventory.armor[i + 1] == 'empty' and state and getBestArmor(i) or nil,
								armorSlot = i
							})
							vainEvents.InventoryChanged.Event:Wait()
							-- A piece at a time. All three landing in the same frame is not
							-- something anyone could do by hand.
							if Speed.Value > 0 then
								task.wait(Speed.Value)
							end
						end
					end
					task.wait(0.1)
				until not ArmorSwitch.Enabled
			else
				ArmorSwitch:Toggle()
				for i = 0, 2 do
					bedwars.Store:dispatch({
						type = 'InventorySetArmorItem',
						item = store.inventory.inventory.armor[i + 1] == 'empty' and getBestArmor(i) or nil,
						armorSlot = i
					})
					vainEvents.InventoryChanged.Event:Wait()
					if Speed.Value > 0 then
						task.wait(Speed.Value)
					end
				end
			end
		end
	end,
	Tooltip = 'Puts on / takes off armor when toggled for baiting.'
})
Mode = ArmorSwitch:CreateDropdown({
	Name = 'Mode',
	Tooltip = 'Which method this module uses',
	List = {'Toggle', 'On Key'}
})
Targets = ArmorSwitch:CreateTargets({
	Players = true,
	NPCs = true,
	Tooltip = 'Which entities this module is allowed to target'
})
Speed = ArmorSwitch:CreateSlider({
	Name = 'Speed',
	Tooltip = 'Delay between each piece, lower is faster\nDefault is 0.1',
	Min = 0,
	Max = 1,
	Default = 0.1,
	Decimal = 100,
	Suffix = 'seconds'
})
Range = ArmorSwitch:CreateSlider({
	Name = 'Range',
	Tooltip = 'How far this reaches, in studs\nDefault is 30',
	Min = 1,
	Max = 30,
	Default = 30,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})