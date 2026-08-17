vain.Categories.Blatant:CreateModule({
	Name = 'KeepSprint',
	Function = function(callback)
		-- Renames the key the sprint check looks up so it misses, instead of writing a
		-- hardcoded constant slot that moves whenever the game's own code shifts.
		swapConstant(bedwars.SprintController.startSprinting, callback and 'blockSprint' or 'blockSprinting', callback and 'blockSprinting' or 'blockSprint')
		bedwars.SprintController:stopSprinting()
	end,
	Tooltip = 'Lets you sprint with a speed potion.'
})