--[[
	Dex Explorer, as a one-shot rather than a toggle.

	The GUI's Button flag is only honoured by the new skin; on the others it renders as an
	ordinary toggle and would sit there latched on. So it un-latches itself the moment it
	is pressed, which reads as a button on every skin, and a guard stops a second press
	loading a second copy over the first.
]]
local loaded = false
local DexExplorer

DexExplorer = vain.Categories.Utility:CreateModule({
	Name = 'Dex Explorer',
	Button = true,
	Function = function(callback)
		-- Only the enable edge matters where it renders as a toggle.
		if callback == false then return end

		task.defer(function()
			if DexExplorer.Enabled and DexExplorer.Toggle then
				pcall(function() DexExplorer:Toggle() end)
			end
		end)

		if loaded then
			notif('Dex Explorer', 'Dex is already open', 4)
			return
		end

		local suc, err = pcall(function()
			return loadstring(game:HttpGet('https://raw.githubusercontent.com/infyiff/backup/main/dex.lua'))()
		end)

		if suc then
			loaded = true
		else
			notif('Dex Explorer', 'Failed to load: '..tostring(err), 6, 'alert')
		end
	end,
	Tooltip = 'Opens the Dex explorer for browsing the game in its own window'
})
