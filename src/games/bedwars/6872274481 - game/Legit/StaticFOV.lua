--[[
	Static FOV.

	Most of the zoom when eating, drinking or drawing a bow is the sprint ending: the
	SprintController tweens the camera to FovController:getFOV() * RUN_FOV_MULT while
	sprinting and back to getFOV() when it stops, which those items do. Items and kits also
	push modifiers into FovController.fovMultiplier, and menus tween the camera out and back.

	So the camera is held at one field of view every frame instead - your FOV setting (or
	the FOV module's), widened by the sprint multiplier if Sprint FOV is on. Scripted
	cameras (cutscenes, drones, the satellite) are left alone.
]]
local StaticFOV
local SprintFOV

local RUN_FOV_MULT = 1.1

-- The FOV with no multiplier on it. getFOV is the controller's stored fov, which already
-- has the item multiplier in it - unless the FOV module replaced getFOV, which then
-- returns its plain value.
local function baseFOV()
	local controller = bedwars.FovController
	local fov = controller:getFOV()
	if fov == controller.fov then
		fov /= (controller.fovMultiplier or 1)
	end
	return fov
end

StaticFOV = vain.Legit:CreateModule({
	Name = 'Static FOV',
	Function = function(callback)
		if callback then
			StaticFOV:Clean(runService.RenderStepped:Connect(function()
				if gameCamera.CameraType ~= Enum.CameraType.Custom then return end
				local ok, fov = pcall(baseFOV)
				if not ok or type(fov) ~= 'number' then return end
				gameCamera.FieldOfView = fov * (SprintFOV.Enabled and RUN_FOV_MULT or 1)
			end))
		else
			pcall(function()
				local controller = bedwars.FovController
				local sprinting = bedwars.SprintController and bedwars.SprintController.sprinting
				gameCamera.FieldOfView = controller:getFOV() * (sprinting and RUN_FOV_MULT or 1)
			end)
		end
	end,
	Tooltip = 'Stops the zoom when eating or drawing a bow'
})
SprintFOV = StaticFOV:CreateToggle({
	Name = 'Sprint FOV',
	Tooltip = 'Keeps the wider sprinting FOV',
	Default = true
})
