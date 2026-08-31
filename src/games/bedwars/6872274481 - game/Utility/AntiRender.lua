local AntiRender
local OnlyRanked

-- The game's own match state for the end-of-round scoreboard, which is the moment the
-- next lobby is being set up and a kit change still takes.
local POST = 2
local NONE = 'none'

--[[
	Swaps you onto the none kit, so the round you join next reports no kit at all.

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

--[[
	Ranked is the only mode that calls a round off for want of players, and the only one
	where what kit you are on is worth hiding in the first place.

	Matched on the queue's name rather than a list of queue types, the same way the other
	modules pick a mode out, so a ranked playlist that does not exist yet is covered
	without a list to keep up to date.
]]
local function ranked()
	return (store.queueType or ''):find('ranked') ~= nil
end

-- Says which way the swap went either way. Silence would be worse than a notification
-- here: a failed swap looks exactly like a successful one right up until the next round
-- starts and your kit is on show.
local function unequip()
	if OnlyRanked.Enabled and not ranked() then return end

	-- Read before the swap, since this is what is being changed away from. Empty means
	-- you are already on none and there is nothing to do - which is also what makes it
	-- safe for the event and the state below to both fire.
	local worn = store.equippedKit
	if worn == '' then return end

	if activate(NONE) then
		notif('AntiRender', 'Unequipped '..worn, 3)
	else
		notif('AntiRender', 'Could not unequip '..worn, 3)
	end
end

AntiRender = vain.Categories.Utility:CreateModule({
	Name = 'AntiRender',
	Function = function(callback)
		if not callback then return end

		--[[
			The round ending is announced by this before the state catches up, and the
			announcement carries whether it was called off rather than played out - which
			ranked does when too few players load in.

			Watched as well as the state below, not instead of it. A cancelled round is
			over in a hurry and the client can be on its way back to the lobby inside the
			half second the poll waits, so the poll alone could miss the only chance to
			swap. Swapping twice costs nothing, since the second one finds you already on
			no kit and stops.
		]]
		AntiRender:Clean(vainEvents.MatchEndEvent.Event:Connect(function()
			task.spawn(unequip)
		end))

		-- Deliberately nil rather than the current state, so switching this on while a
		-- round is already over acts straight away instead of waiting for the one after.
		local last
		repeat
			local state = store.matchState

			if state ~= last then
				if state == POST then
					unequip()
				end

				last = state
			end

			task.wait(0.5)
		until not AntiRender.Enabled
	end,
	Tooltip = 'Unequips your kit when a round ends'
})
OnlyRanked = AntiRender:CreateToggle({
	Name = 'Only Ranked',
	Tooltip = 'Only runs while in a ranked queue',
	Default = true
})
