local FOV
local Value
local oldfov

FOV = vain.Legit:CreateModule({
	Name = 'FOV',
	Function = function(callback)
		if callback then
			oldfov = gameCamera.FieldOfView
			repeat
				gameCamera.FieldOfView = Value.Value
				task.wait()
			until not FOV.Enabled
		else
			gameCamera.FieldOfView = oldfov
		end
	end,
	Tooltip = 'Adjusts camera vision'
})
Value = FOV:CreateSlider({
	Tooltip = 'Field of view, in degrees',
	Name = 'FOV',
	Min = 30,
	Max = 120
})