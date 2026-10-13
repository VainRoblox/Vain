--[[
	Reach.

	A Tribes melee swing calls Detect(range, arc, maxTargets) to decide who it hit, and the
	list it returns is what the client sends the server - the server is told who was hit, it
	does not work it out. So adding to that range is the whole of reach here: the swings you
	already throw simply find targets a few studs further out, through the game's own path,
	with no extra packet and nothing the server did not already expect from a swing.

	The hook itself lives in base, shared with Killaura, so the two never fight over Detect.
]]
local Reach
local Range
local tribes = vain.Libraries.tribes

Reach = vain.Categories.Combat:CreateModule({
	Name = 'Reach',
	Function = function(callback)
		if callback then
			if not tribes.hookDetect() then
				notif('Reach', 'Combat system not found yet - try again in a match', 6, 'alert')
			end
			tribes.setReach(Range.Value)
		else
			tribes.setReach(0)
		end
	end,
	Tooltip = 'Makes your melee hits reach further'
})
Range = Reach:CreateSlider({
	Name = 'Extra Range',
	Tooltip = 'Studs added to your weapon\'s reach',
	Min = 0,
	Max = 20,
	Default = 6,
	Decimal = 10,
	Function = function(val)
		if Reach.Enabled then
			tribes.setReach(val)
		end
	end,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
