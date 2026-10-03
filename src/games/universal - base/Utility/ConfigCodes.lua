--[[
	Config Codes.

	Turns your profile, or a single module, into a code you can paste to a friend, and
	takes one back. A code is the same JSON the profile file holds, base64'd behind a
	VAIN1: marker, so anything the profile saves travels with it. Keybinds stay behind
	unless Include Binds is on - they are personal, and an import keeps yours.

	It lives in the Profiles window's settings (the gear) where the GUI allows options there,
	and as a Utility module where it does not.

	Importing writes the settings into the profile file and reloads it, so it goes through
	the exact path a normal profile load does. With a New Profile name it becomes a profile
	of its own and is switched to; otherwise it is merged into the one you are on, and only
	the modules the code carries change.
]]
local ConfigCodes
local Scope, ModuleName, IncludeBinds, PasteCode, NewProfile, host
local PREFIX = 'VAIN1:'
local SELF = 'Config Codes'

local ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local DECODE = {}
for i = 1, #ALPHABET do DECODE[ALPHABET:byte(i)] = i - 1 end

local function encode64(data)
	local out = {}
	for i = 1, #data, 3 do
		local a, b, c = data:byte(i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local s1, s2 = bit32.extract(n, 18, 6), bit32.extract(n, 12, 6)
		local s3, s4 = bit32.extract(n, 6, 6), bit32.extract(n, 0, 6)
		out[#out + 1] = ALPHABET:sub(s1 + 1, s1 + 1) .. ALPHABET:sub(s2 + 1, s2 + 1)
			.. (b and ALPHABET:sub(s3 + 1, s3 + 1) or '=') .. (c and ALPHABET:sub(s4 + 1, s4 + 1) or '=')
	end
	return table.concat(out)
end

local function decode64(data)
	data = data:gsub('[^%w%+/]', '')
	local out = {}
	for i = 1, #data, 4 do
		local n, count = 0, 0
		for j = i, i + 3 do
			local value = DECODE[data:byte(j) or 0]
			if value then
				n = n * 64 + value
				count += 1
			else
				n *= 64
			end
		end
		local bytes = string.char(bit32.extract(n, 16, 8), bit32.extract(n, 8, 8), bit32.extract(n, 0, 8))
		out[#out + 1] = bytes:sub(1, math.max(count - 1, 0))
	end
	return table.concat(out)
end

local function profilePath(name)
	return 'vain/profiles/' .. name .. vain.Place .. '.txt'
end

local function readProfile(name)
	local path = profilePath(name)
	if not isfile(path) then return nil end
	local ok, data = pcall(function() return httpService:JSONDecode(readfile(path)) end)
	return ok and type(data) == 'table' and data or nil
end

local function stripBinds(entries)
	for _, entry in entries do
		if type(entry) == 'table' then entry.Bind = nil end
	end
end

-- The code for the current profile, or for the one module named, or nil and why not.
local function buildCode()
	vain:Save()
	local data = readProfile(vain.Profile)
	if not data then return nil, 'Could not read your profile' end
	local payload = {Vain = 1, Place = vain.Place}

	if Scope.Value == 'One Module' then
		local wanted = ModuleName.Value:lower():gsub('^%s+', ''):gsub('%s+$', '')
		for _, group in {'Modules', 'Legit'} do
			for name, entry in data[group] or {} do
				if name:lower() == wanted then
					payload[group] = {[name] = entry}
				end
			end
		end
		if not (payload.Modules or payload.Legit) then return nil, 'No module called ' .. ModuleName.Value end
	else
		payload.Whole = true
		payload.Modules = data.Modules or {}
		payload.Legit = data.Legit or {}
		payload.Categories = data.Categories or {}
		payload.Modules[SELF] = nil
		-- The Profiles window holds the paste box itself; a code is not worth carrying.
		payload.Categories.Profiles = nil
	end

	if not IncludeBinds.Enabled then
		stripBinds(payload.Modules or {})
	end
	return PREFIX .. encode64(httpService:JSONEncode(payload))
end

local function readCode(code)
	code = (code or ''):gsub('%s', '')
	if code:sub(1, #PREFIX) ~= PREFIX then return nil, 'That is not a Vain code' end
	local ok, payload = pcall(function() return httpService:JSONDecode(decode64(code:sub(#PREFIX + 1))) end)
	if not ok or type(payload) ~= 'table' or payload.Vain ~= 1 then return nil, 'That code is broken or cut off' end
	return payload
end

local function importCode(code, profileName)
	local payload, err = readCode(code)
	if not payload then return false, err end
	vain:Save()

	profileName = (profileName or ''):gsub('^%s+', ''):gsub('%s+$', '')
	local target
	if profileName ~= '' then
		-- A profile of its own: the code is the whole of it.
		target = {Modules = payload.Modules or {}, Legit = payload.Legit or {}, Categories = payload.Categories or {}}
		for _, entry in target.Modules do entry.Bind = entry.Bind or {} end
	else
		-- Merged into this one: what the code carries replaces, the rest stays, and your
		-- binds are kept where the code brought none.
		target = readProfile(vain.Profile) or {}
		target.Modules = target.Modules or {}
		target.Legit = target.Legit or {}
		target.Categories = target.Categories or {}
		for name, entry in payload.Modules or {} do
			local current = target.Modules[name]
			entry.Bind = entry.Bind or (current and current.Bind) or {}
			target.Modules[name] = entry
		end
		for name, entry in payload.Legit or {} do target.Legit[name] = entry end
		for name, entry in payload.Categories or {} do
			if name ~= 'Profiles' then target.Categories[name] = entry end
		end
	end

	local name = profileName ~= '' and profileName or vain.Profile
	writefile(profilePath(name), httpService:JSONEncode(target))
	if profileName ~= '' then
		local exists = false
		for _, profile in vain.Profiles do
			if profile.Name == profileName then exists = true end
		end
		if not exists then table.insert(vain.Profiles, {Name = profileName, Bind = {}}) end
		vain:Save(profileName)
	end
	vain:Load(true)
	return true
end

local function exportCode()
	local code, err = buildCode()
	if not code then
		notif('Config Codes', err, 4, 'alert')
		return
	end
	if setclipboard then
		setclipboard(code)
		notif('Config Codes', 'Code copied', 3)
	else
		notif('Config Codes', 'Your executor cannot copy to the clipboard', 5, 'alert')
	end
end

local function runImport(code)
	if not code or code == '' then return end
	local ok, result, err = pcall(importCode, code, NewProfile.Value)
	if ok and result then
		notif('Config Codes', 'Imported', 3)
	else
		notif('Config Codes', ok and err or 'Import failed', 5, 'alert')
	end
end

local function importClipboard()
	local read = getclipboard or (syn and syn.read_clipboard)
	if not read then
		notif('Config Codes', 'Your executor cannot read the clipboard - paste into Paste Code', 5, 'alert')
		return
	end
	local ok, code = pcall(read)
	if not ok or type(code) ~= 'string' or code == '' then
		notif('Config Codes', 'Your clipboard is empty', 4, 'alert')
		return
	end
	runImport(code)
end

-- The Profiles window's settings when the GUI gives it options; a Utility module otherwise.
local profiles = vain.Categories.Profiles
if profiles and type(profiles.CreateButton) == 'function' and type(profiles.CreateTextBox) == 'function' then
	host = profiles
else
	ConfigCodes = vain.Categories.Utility:CreateModule({
		Name = SELF,
		Function = function(callback)
			if callback then
				ConfigCodes:Toggle()
				exportCode()
			end
		end,
		Tooltip = 'Share or import profiles as a code; clicking copies one'
	})
	host = ConfigCodes
end

host:CreateButton({
	Name = 'Export To Clipboard',
	Tooltip = 'Copies your profile as a code',
	Function = exportCode
})
host:CreateButton({
	Name = 'Import From Clipboard',
	Tooltip = 'Applies the code on your clipboard',
	Function = importClipboard
})
NewProfile = host:CreateTextBox({
	Name = 'Import As',
	Placeholder = 'Empty applies it here',
	Tooltip = 'Imports a whole-profile code as a new profile with this name'
})
PasteCode = host:CreateTextBox({
	Name = 'Paste Code',
	Placeholder = 'Paste a code, press Enter',
	Tooltip = 'For executors that cannot read the clipboard',
	Function = function(enter)
		if not enter then return end
		local code = PasteCode.Value
		-- Cleared first, so the code is not saved into the profile it is about to load.
		PasteCode:SetValue('')
		runImport(code)
	end
})
Scope = host:CreateDropdown({
	Name = 'Share',
	List = {'Whole Profile', 'One Module'},
	Tooltips = {
		['Whole Profile'] = 'Every module, card and setting',
		['One Module'] = 'Just the module named below'
	},
	Function = function(val)
		if ModuleName and ModuleName.Object then ModuleName.Object.Visible = val == 'One Module' end
	end
})
ModuleName = host:CreateTextBox({
	Name = 'Module',
	Placeholder = 'Module name',
	Tooltip = 'The module to share, as named in the GUI',
	Darker = true,
	Visible = false
})
IncludeBinds = host:CreateToggle({
	Name = 'Include Binds',
	Tooltip = 'Sends your keybinds along too'
})
