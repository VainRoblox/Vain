vain.Legit:CreateModule({
	Name = 'HitFix',
	Function = function(callback)
		-- Lowercasing the method name makes the engine-side lookup miss, which is the
		-- whole trick here. Found by value so it survives the game shifting constants.
		swapConstant(bedwars.SwordController.swingSwordAtMouse, callback and 'Raycast' or 'raycast', callback and 'raycast' or 'Raycast')
		debug.setupvalue(bedwars.SwordController.swingSwordAtMouse, 4, callback and bedwars.QueryUtil or workspace)
	end,
	Tooltip = 'Changes the raycast function to the correct one'
})