local AntiRender
local Restore
local previous

-- The game's own match states. Post is the scoreboard at the end of a round, which is
-- the moment the next lobby is being set up and a kit change still takes.
local RUNNING, POST = 1, 2
local NONE = 'none'

--[[
	Swaps you onto the none kit once a round is over, so the round you join next reports
	no kit at all.

	This is the same call the kit shop's Equip button makes, not a display trick: the
	server is told, and it is the server that tells everyone else what you are running.
	Which also means you really are on no kit afterwards, abilities included - turn on
	Restore if you want your own kit put back once the next round starts.
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
		if not callback then
			previous = nil
			return
		end

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
						previous = worn
						if activate(NONE) then
							notif('AntiRender', 'Unequipped '..worn, 3)
						else
							-- Worth saying out loud rather than failing quietly: the round
							-- you join next would still be showing your kit.
							notif('AntiRender', 'Could not unequip '..worn, 3)
							previous = nil
						end
					end
				elseif state == RUNNING and Restore.Enabled and previous then
					-- Whether the server lets a kit be equipped once a round is under way
					-- is its call, not something that can be checked from here, so both
					-- outcomes are reported rather than assumed.
					notif('AntiRender', (activate(previous) and 'Restored ' or 'Could not restore ')..previous, 3)
					previous = nil
				end

				last = state
			end

			task.wait(0.5)
		until not AntiRender.Enabled
	end,
	Tooltip = 'Unequips your kit when a round ends'
})
Restore = AntiRender:CreateToggle({
	Name = 'Restore',
	Tooltip = 'Puts your kit back once the next round starts'
})
