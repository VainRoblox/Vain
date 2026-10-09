-- Lives in Utility/ rather than a Kit/ folder because VainBundler enumerates a
-- hardcoded category list and a Kit/ folder never reaches the compiled bundle. The
-- folder only decides what gets bundled; the category is the one it is created from,
-- which is Kit below.
--[[
	Auto Equip Kit.

	Equips a kit the moment a round ends, so the next one starts with it already chosen
	rather than you racing the lobby timer through the kit menu.

	It fires on the transition into the end state, not on the state itself. Equipping
	repeatedly for as long as the match sits in that state would be one call every pass,
	and the server has no reason to hear the same request forty times.

	The kit list and the call are built here rather than shared with EquipKit: game files
	load in name order, so AutoEquipKit runs first and anything EquipKit published would
	not exist yet.
]]
local AutoEquipKit
local Kit
local Notify

local ids = {}

local function kitList()
	local names = {}
	local ok = pcall(function()
		for id, meta in bedwars.BedwarsKitMeta do
			local name = type(meta) == 'table' and meta.name
			if type(name) == 'string' and name ~= '' then
				ids[name] = id
				table.insert(names, name)
			end
		end
	end)
	-- Sorted because BedwarsKitMeta is a hash: its order moves between injections and
	-- the dropdown would reshuffle every time.
	table.sort(names)
	if not ok or #names == 0 then
		return {'None'}
	end
	table.insert(names, 1, 'None')
	return names
end

local function say(text)
	if Notify.Enabled then
		notif('AutoEquipKit', text, 6)
	end
end

AutoEquipKit = vain.Categories.Kit:CreateModule({
	Name = 'AutoEquipKit',
	Function = function(callback)
		if not callback then
			return
		end

		-- Seeded with the state as it is now, so switching the module on during an
		-- already finished match does not read as a transition and fire immediately.
		local last = store.matchState

		repeat
			local now = store.matchState
			if now == 2 and last ~= 2 and Kit.Value ~= 'None' then
				local id = ids[Kit.Value]
				if id then
					local ok, result = pcall(function()
						return bedwars.Client:Get('BedwarsActivateKit'):CallServer({kit = id})
					end)
					say((ok and result ~= false) and (Kit.Value..' equipped for the next round')
						or ('Could not equip '..Kit.Value))
				end
			end
			last = now
			task.wait(0.5)
		until not AutoEquipKit.Enabled
	end,
	Tooltip = 'Equips a kit when the round ends'
})
Kit = AutoEquipKit:CreateDropdown({
	Name = 'Kit',
	Tooltip = 'Which kit to equip for next round',
	List = kitList()
})
Notify = AutoEquipKit:CreateToggle({
	Name = 'Notify',
	Tooltip = 'Says when it equips',
	Default = true
})
