--[[
	Dex Explorer, as a one-shot rather than a toggle.

	The GUI's Button flag is only honoured by the new skin; on the others it renders as an
	ordinary toggle and would sit there latched on. So it un-latches itself the moment it
	is pressed, which reads as a button on every skin.

	Three things had it opening more than once, and opening without being asked at all.

	It un-latched on the next frame rather than at once, so a config saved in between
	recorded it as switched on - and restoring a config switches on everything recorded
	that way, which loaded Dex on injection with nobody touching it. It now un-latches
	before anything else, so nothing records it as on, and ignores a switch-on in the
	first seconds after it is built: that is a config being restored, never a press.

	And the guard against loading twice was only set once the download had finished, which
	is a good half second of a second press being waved through. It is claimed before the
	download starts instead, and never released: one Dex per session is the whole point.
]]
local RESTORE_WINDOW = 3
local built = os.clock()
local starting = false
local DexExplorer

DexExplorer = vain.Categories.Utility:CreateModule({
	Name = 'Dex Explorer',
	Button = true,
	Function = function(callback)
		-- Only the switch-on edge matters where it renders as a toggle.
		if callback == false then return end

		if DexExplorer.Enabled and DexExplorer.Toggle then
			pcall(function() DexExplorer:Toggle() end)
		end

		-- A config restored from an older build can still have this recorded as switched
		-- on, and that restore happens moments after the module is built. Nobody presses
		-- a button they have not seen yet, so anything this early is not a press.
		if os.clock() - built < RESTORE_WINDOW then return end

		if starting then
			notif('Dex Explorer', 'Dex is already open', 4)
			return
		end
		starting = true

		local suc, err = pcall(function()
			return loadstring(game:HttpGet('https://raw.githubusercontent.com/infyiff/backup/main/dex.lua'))()
		end)

		if not suc then
			-- It never opened, so the next press should be allowed to try again.
			starting = false
			notif('Dex Explorer', 'Failed to load: '..tostring(err), 6, 'alert')
		end
	end,
	Tooltip = 'Opens the Dex explorer for browsing the game in its own window'
})
