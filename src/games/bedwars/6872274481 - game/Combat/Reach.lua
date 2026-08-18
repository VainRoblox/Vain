local Value

-- The slider value that produces the game's own reach. The game defines
-- RAYCAST_SWORD_CHARACTER_DISTANCE as 4.8 * BLOCK_SIZE, and BLOCK_SIZE is 3, so vanilla
-- reach is 14.4 - which is also what the disable path below restores. The slider adds 2
-- on top of whatever it is set to, so 12.4 is the value that lands exactly on vanilla.
local DEFAULTRANGE = 12.4

Reach = vain.Categories.Combat:CreateModule({
	Name = 'Reach',
	Function = function(callback)
		bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE = callback and Value.Value + 2 or 14.4
	end,
	Tooltip = 'Extends attack reach'
})
Value = Reach:CreateSlider({
	Name = 'Range',
	Tooltip = 'How far this reaches, in studs',
	Min = 0,
	Max = 18,
	Default = 18,
	Function = function(val)
		if Reach.Enabled then
			bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE = val + 2
		end
	end,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
Reach:CreateButton({
	Name = 'Reset to Default',
	Tooltip = 'Sets Range back to 12.4 studs, matching the reach you have without this module',
	Function = function()
		-- final = true so the slider fires its callback even when the value already
		-- matches, which reapplies the constant if something else has changed it.
		Value:SetValue(DEFAULTRANGE, nil, true)
	end
})
