local FastDrop

--[[
	The key the game itself drops on, which the player can rebind in settings. H is only
	the default - the tooltip claimed Q, which was neither the default nor what this
	listened for, so it was wrong however the game was set up.

	Read live rather than once at load, because a rebind takes effect immediately and
	both what this listens for and what the tooltip says have to follow it.
]]
local function dropKey()
	local ok, keybinds = pcall(function()
		return bedwars.Knit.Controllers.KeybindLoadController:getKeybinds()
	end)

	local actions = ok and keybinds and keybinds.keyboard and keybinds.keyboard.controlActions
	local key = actions and actions.DropItem
	-- Bindable actions are not all keyboard keys - Attack is a mouse button - so anything
	-- IsKeyDown cannot be asked about falls back to the default.
	if typeof(key) == 'EnumItem' and key.EnumType == Enum.KeyCode then
		return key
	end
	return Enum.KeyCode.H
end

FastDrop = vain.Categories.Inventory:CreateModule({
	Name = 'FastDrop',
	Function = function(callback)
		if callback then
			repeat
				if entitylib.isAlive and (not store.inventory.opened) and (inputService:IsKeyDown(dropKey()) or inputService:IsKeyDown(Enum.KeyCode.Backspace)) and inputService:GetFocusedTextBox() == nil then
					task.spawn(bedwars.ItemDropController.dropItemInHand)
					task.wait()
				else
					task.wait(0.1)
				end
			until not FastDrop.Enabled
		end
	end,
	Tooltip = function()
		return 'Drops items fast when you hold '..dropKey().Name
	end
})
