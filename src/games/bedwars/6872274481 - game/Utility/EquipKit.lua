-- Lives in Utility/ rather than a Kit/ folder because VainBundler enumerates a
-- hardcoded category list and a Kit/ folder never reaches the compiled bundle. The
-- folder only decides what gets bundled; the category is the one it is created from,
-- which is Kit below.
--[[
	Equip Kit.

	Switches your kit on a press, without opening the kit menu. Useful between rounds,
	where the menu costs several clicks and the lobby is about to take the choice away
	from you.

	The list is built from the game's own BedwarsKitMeta rather than written out here, so
	a kit added by an update appears without this file changing. Names are sorted because
	that table is a hash and its order moves between injections, which would reshuffle the
	dropdown every time.
]]
local EquipKit
local Kit
local Notify

-- name -> kit id, filled alongside the sorted list below.
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
	table.sort(names)
	if not ok or #names == 0 then
		-- A dropdown with nothing in it cannot be opened, so it says why instead.
		return {'None'}
	end
	table.insert(names, 1, 'None')
	return names
end

local function say(text)
	if Notify.Enabled then
		notif('EquipKit', text, 4)
	end
end

--[[
	Asks the server to equip a kit.

	Shared with AutoEquipKit through the module table rather than duplicated, since both
	need the same call and the same failure handling.
]]
local function equip(name)
	local id = ids[name]
	if not id then
		return false, 'unknown kit'
	end

	local ok, result = pcall(function()
		return bedwars.Client:Get('BedwarsActivateKit'):CallServer({kit = id})
	end)
	if not ok then
		return false, tostring(result)
	end
	-- The server answers with whether it took; false is a refusal, not an error.
	return result ~= false, nil
end

EquipKit = vain.Categories.Kit:CreateModule({
	Name = 'EquipKit',
	Function = function(callback)
		if not callback then
			return
		end
		-- A one off, like the other act-on-press modules: it puts itself away so the
		-- keybind reads as a button.
		EquipKit:Toggle()

		if Kit.Value == 'None' then
			return say('Pick a kit first')
		end

		local done, err = equip(Kit.Value)
		say(done and ('Equipped '..Kit.Value) or ('Could not equip '..Kit.Value..(err and (': '..err) or '')))
	end,
	Tooltip = 'Equips the chosen kit'
})
Kit = EquipKit:CreateDropdown({
	Name = 'Kit',
	Tooltip = 'Which kit to equip',
	List = kitList()
})
Notify = EquipKit:CreateToggle({
	Name = 'Notify',
	Tooltip = 'Says whether it worked',
	Default = true
})
