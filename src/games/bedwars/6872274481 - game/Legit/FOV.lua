local FOV
local Value
local old, old2, setHook, getHook

FOV = vain.Legit:CreateModule({
	Name = 'FOV',
	Function = function(callback)
		local controller = bedwars.FovController
		if callback then
			local originalSet, originalGet = controller.setFOV, controller.getFOV
			old, old2 = originalSet, originalGet
			-- Left in place under another wrapper after turning off, these pass straight through.
			setHook = function(self, value, ...)
				if not FOV.Enabled then return originalSet(self, value, ...) end
				return originalSet(self, Value.Value)
			end
			getHook = function(self, ...)
				if not FOV.Enabled then return originalGet(self, ...) end
				return Value.Value
			end
			controller.setFOV = setHook
			controller.getFOV = getHook
		else
			-- Only put back if nothing (Static FOV) wrapped them since.
			if controller.setFOV == setHook then controller.setFOV = old end
			if controller.getFOV == getHook then controller.getFOV = old2 end
			setHook, getHook = nil, nil
		end
		
		bedwars.FovController:setFOV(bedwars.Store:getState().Settings.fov)
	end,
	Tooltip = 'Adjusts camera vision'
})
Value = FOV:CreateSlider({
	Name = 'FOV',
	Tooltip = 'Field of view, in degrees',
	Min = 30,
	Max = 120
})