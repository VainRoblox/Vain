--[[
	Leave Party.

	Leaves the party you are in, once, on a press. It puts itself back off immediately so
	the keybind reads as a button rather than something left switched on - the same shape
	as the other act-on-press modules here.

	Why it is worth a module at all: leaving through the lobby UI means opening the party
	panel and finding the control, which is several clicks you do not have time for
	between queues.

	The party is read before the call rather than after. leaveParty on a player who is not
	in one is not obviously harmful, but it is a remote call that says something untrue
	about your client, and there is no reason to send it - so a press with no party says
	so instead.
]]
local LeaveParty
local Notify

local function say(text)
	if Notify.Enabled then
		notif('LeaveParty', text, 3)
	end
end

--[[
	How many people are in the party, or nil when that cannot be read.

	nil and zero are deliberately different: a state the client has not populated yet is
	not the same as an empty party, and only the second is a reason to refuse. Guessing
	the former as empty would make the module useless on the first press after joining.
]]
local function partySize()
	local ok, state = pcall(function()
		return bedwars.Store:getState().Party
	end)
	if not ok or type(state) ~= 'table' or type(state.members) ~= 'table' then
		return nil
	end
	return #state.members
end

LeaveParty = vain.Categories.Utility:CreateModule({
	Name = 'LeaveParty',
	Function = function(callback)
		if not callback then
			return
		end
		LeaveParty:Toggle()

		if not bedwars.PartyController then
			return say('Party controller is not available here')
		end

		local size = partySize()
		if size == 0 then
			return say('You are not in a party')
		end

		local ok, err = pcall(function()
			return bedwars.PartyController:leaveParty()
		end)
		if not ok then
			return say('Could not leave: '..tostring(err))
		end

		say(size and ('Left a party of '..(size + 1)) or 'Left the party')
	end,
	Tooltip = 'Leaves your current party'
})
Notify = LeaveParty:CreateToggle({
	Name = 'Notify',
	Tooltip = 'Says whether it worked',
	Default = true
})
