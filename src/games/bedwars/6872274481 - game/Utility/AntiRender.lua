local AntiRender

-- The game's own match state for the end-of-round scoreboard, which is the moment the
-- next lobby is being set up and a kit change still takes.
local POST = 2
local NONE = 'none'

--[[
	Swaps you onto the none kit once a round is over, so the round you join next reports
	no kit at all.

	This is the same call the kit shop's Equip button makes, not a display trick: the
	server is told, and it is the server that tells everyone else what you are running.
	Which also means you really are on no kit afterwards, abilities included.
]]
local function activate(kit)
	local ok, result = pcall(function()
		return bedwars.Client:Get('BedwarsActivateKit'):CallServer({kit = kit})
	end)
	return ok and result and true or false
end

AntiRender = vain.Categories.Utility:CreateModule({
	Name = 'AntiRender',
	Function = function(callback)
		if not callback then return end

		-- Deliberately nil rather than the current state, so switching this on while a
		-- round is already over acts straight away instead of waiting for the one after.
		local last
		repeat
			local state = store.matchState

			if state ~= last then
				if state == POST then
					-- Read before the swap, since store.equippedKit is what it is being
					-- changed away from. Empty means you were already on none.
					local worn = store.equippedKit
					if worn ~= '' then
						if activate(NONE) then
							notif('AntiRender', 'Unequipped '..worn, 3)
						else
							-- Worth saying out loud rather than failing quietly: the round
							-- you join next would still be showing your kit.
							notif('AntiRender', 'Could not unequip '..worn, 3)
						end
					end
				end

				last = state
			end

			task.wait(0.5)
		until not AntiRender.Enabled
	end,
	Tooltip = 'Unequips your kit when a round ends'
})
