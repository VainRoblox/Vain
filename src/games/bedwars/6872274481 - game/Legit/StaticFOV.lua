--[[
	Static FOV.

	Stops the game changing the field of view in the first place, at the three places it
	does:

	- SprintController:tweenCameraFOV - most of the zoom when eating, drinking or drawing a
	  bow is the sprint ending: it tweens to FovController:getFOV() * RUN_FOV_MULT when the
	  sprint starts and back to getFOV() when it stops, which those items do.
	- FovController:setFOV - puts FovController.fovMultiplier on, which is where the
	  modifiers items and kits add end up.
	- FovController:playUIOpenFOVTween / playUICloseFOVTween - the zoom when menus open.

	Each wrapper keeps the original it was built with and is only taken off if nothing
	wrapped the method after it, as the FOV module wraps setFOV too.
]]
local StaticFOV
local SprintFOV
local hooks = {}

local RUN_FOV_MULT = 1.1

-- Something the sprint code can tidy up, standing in for the tween's maid.
local dummyMaid = {
	GiveTask = function() end,
	DoCleaning = function() end,
	Destroy = function() end
}

local function hook(object, method, make)
	local original = object and object[method]
	if type(original) ~= 'function' then return end
	local wrapper = make(original)
	object[method] = wrapper
	table.insert(hooks, {object = object, method = method, original = original, wrapper = wrapper})
end

local function unhookAll()
	for i = #hooks, 1, -1 do
		local entry = hooks[i]
		if entry.object[entry.method] == entry.wrapper then
			entry.object[entry.method] = entry.original
		end
	end
	table.clear(hooks)
end

local function sprintScale()
	return SprintFOV.Enabled and RUN_FOV_MULT or 1
end

-- Puts the FOV back through the game's own setFOV, now that it ignores the multiplier.
local function reapply()
	pcall(function()
		bedwars.FovController:setFOV(bedwars.Store:getState().Settings.fov)
	end)
end

StaticFOV = vain.Legit:CreateModule({
	Name = 'Static FOV',
	Function = function(callback)
		if callback then
			local fov = bedwars.FovController
			local sprint = bedwars.SprintController

			-- The FOV with no item multiplier, plus the sprint widening if kept.
			hook(fov, 'setFOV', function(original)
				return function(self, value, ...)
					local multiplier = self.fovMultiplier
					self.fovMultiplier = sprintScale()
					local results = table.pack(pcall(original, self, value, ...))
					self.fovMultiplier = multiplier
					-- getFOV is read as the plain FOV by the sprint code, so it is kept so.
					if typeof(self.fov) == 'number' then
						self.fov /= sprintScale()
					end
					if not results[1] then error(results[2], 0) end
					return table.unpack(results, 2, results.n)
				end
			end)

			-- No sprint tween: the camera already sits where it should.
			hook(sprint, 'tweenCameraFOV', function()
				return function()
					return dummyMaid
				end
			end)

			-- Menus get a tween that is never played.
			for _, method in {'playUIOpenFOVTween', 'playUICloseFOVTween'} do
				hook(fov, method, function()
					return function()
						return tweenService:Create(gameCamera, TweenInfo.new(0), {FieldOfView = gameCamera.FieldOfView})
					end
				end)
			end

			reapply()
		else
			unhookAll()
			reapply()
			pcall(function()
				if bedwars.SprintController.sprinting then
					gameCamera.FieldOfView = bedwars.FovController:getFOV() * RUN_FOV_MULT
				end
			end)
		end
	end,
	Tooltip = 'Stops the zoom when eating or drawing a bow'
})
SprintFOV = StaticFOV:CreateToggle({
	Name = 'Sprint FOV',
	Tooltip = 'Keeps the wider sprinting FOV',
	Default = true,
	Function = function()
		if StaticFOV.Enabled then reapply() end
	end
})
