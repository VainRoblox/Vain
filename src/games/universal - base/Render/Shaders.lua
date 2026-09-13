local Shaders
local Preset
local Brightness
local Saturation
local created, hidden = {}, {}
local correction

--[[
	Shaders.

	An executor cannot run real shaders, so this is the closest Roblox gets: a stack of
	Lighting post-processing - atmosphere, colour correction, bloom, sun rays and depth of
	field - tuned into presets. Everything added is removed on disable and the game's own
	Atmosphere is put back, so its lighting ends up exactly as it was.
]]
local PRESETS = {
	Realistic = {
		Atmosphere = {Density = 0.35, Offset = 0.25, Color = Color3.fromRGB(199, 170, 107), Decay = Color3.fromRGB(106, 112, 125), Glare = 0.2, Haze = 1.8},
		ColorCorrectionEffect = {Brightness = 0.02, Contrast = 0.12, Saturation = 0.08, TintColor = Color3.fromRGB(255, 250, 240)},
		BloomEffect = {Intensity = 0.5, Size = 24, Threshold = 0.9},
		SunRaysEffect = {Intensity = 0.12, Spread = 0.8},
		DepthOfFieldEffect = {FarIntensity = 0.05, FocusDistance = 60, InFocusRadius = 90, NearIntensity = 0.1}
	},
	Vibrant = {
		Atmosphere = {Density = 0.3, Offset = 0.4, Color = Color3.fromRGB(220, 210, 255), Decay = Color3.fromRGB(120, 130, 160), Glare = 0.4, Haze = 1.2},
		ColorCorrectionEffect = {Brightness = 0.05, Contrast = 0.18, Saturation = 0.28, TintColor = Color3.fromRGB(255, 245, 255)},
		BloomEffect = {Intensity = 0.9, Size = 30, Threshold = 0.8},
		SunRaysEffect = {Intensity = 0.2, Spread = 1},
		DepthOfFieldEffect = {FarIntensity = 0, FocusDistance = 70, InFocusRadius = 120, NearIntensity = 0}
	},
	Cinematic = {
		Atmosphere = {Density = 0.42, Offset = 0.1, Color = Color3.fromRGB(180, 160, 150), Decay = Color3.fromRGB(70, 80, 100), Glare = 0.15, Haze = 2.4},
		ColorCorrectionEffect = {Brightness = -0.02, Contrast = 0.22, Saturation = -0.05, TintColor = Color3.fromRGB(235, 240, 255)},
		BloomEffect = {Intensity = 0.7, Size = 28, Threshold = 0.85},
		SunRaysEffect = {Intensity = 0.18, Spread = 0.9},
		DepthOfFieldEffect = {FarIntensity = 0.15, FocusDistance = 45, InFocusRadius = 60, NearIntensity = 0.2}
	},
	Night = {
		Atmosphere = {Density = 0.5, Offset = 0, Color = Color3.fromRGB(90, 100, 140), Decay = Color3.fromRGB(30, 35, 55), Glare = 0.05, Haze = 2},
		ColorCorrectionEffect = {Brightness = -0.05, Contrast = 0.15, Saturation = -0.1, TintColor = Color3.fromRGB(180, 200, 255)},
		BloomEffect = {Intensity = 0.6, Size = 26, Threshold = 0.95},
		SunRaysEffect = {Intensity = 0.05, Spread = 0.6},
		DepthOfFieldEffect = {FarIntensity = 0.1, FocusDistance = 55, InFocusRadius = 80, NearIntensity = 0.1}
	}
}
-- Created in this order, so the colour correction the sliders adjust always exists by
-- the time they are applied.
local ORDER = {'Atmosphere', 'ColorCorrectionEffect', 'BloomEffect', 'SunRaysEffect', 'DepthOfFieldEffect'}

local function currentPreset()
	return PRESETS[Preset and Preset.Value] or PRESETS.Realistic
end

--[[
	Only one Atmosphere renders at a time, and it has to sit directly in Lighting. The game's
	own is taken out while this is on - including one it adds later, on a map load say, which
	would otherwise quietly take over from ours.
]]
local function hide(child)
	if child:IsA('Atmosphere') and not table.find(created, child) and not table.find(hidden, child) then
		table.insert(hidden, child)
		pcall(function()
			child.Parent = nil
		end)
	end
end

-- The sliders only move the colour correction, so they adjust it rather than rebuilding
-- the whole stack on every step of a drag.
local function tune()
	if not correction then return end
	local base = currentPreset().ColorCorrectionEffect
	correction.Brightness = base.Brightness + (Brightness and Brightness.Value or 0) / 100
	correction.Saturation = base.Saturation + (Saturation and Saturation.Value or 0) / 100
end

local function clear()
	for _, instance in created do
		pcall(function()
			instance:Destroy()
		end)
	end
	table.clear(created)
	correction = nil
end

local function build()
	clear()
	for _, child in lightingService:GetChildren() do
		hide(child)
	end

	local preset = currentPreset()
	for _, class in ORDER do
		local instance = Instance.new(class)
		instance.Name = 'VainShaders'
		for property, value in preset[class] do
			pcall(function()
				instance[property] = value
			end)
		end
		table.insert(created, instance)
		instance.Parent = lightingService
		if class == 'ColorCorrectionEffect' then
			correction = instance
		end
	end
	tune()
end

Shaders = vain.Categories.Render:CreateModule({
	Name = 'Shaders',
	Function = function(callback)
		if callback then
			build()
			Shaders:Clean(lightingService.ChildAdded:Connect(function(child)
				task.defer(hide, child)
			end))
		else
			clear()
			for _, atmosphere in hidden do
				if atmosphere.Parent == nil then
					pcall(function()
						atmosphere.Parent = lightingService
					end)
				end
			end
			table.clear(hidden)
		end
	end,
	Tooltip = 'Lighting presets that make any game look better'
})
Preset = Shaders:CreateDropdown({
	Name = 'Preset',
	Tooltip = 'Which look to apply',
	List = {'Realistic', 'Vibrant', 'Cinematic', 'Night'},
	Tooltips = {
		Realistic = 'Warm haze and soft bloom',
		Vibrant = 'Bright, saturated colours',
		Cinematic = 'Contrast, fog and depth of field',
		Night = 'Dark, cool blue light'
	},
	Function = function()
		if Shaders.Enabled then
			build()
		end
	end
})
Brightness = Shaders:CreateSlider({
	Name = 'Brightness',
	Tooltip = 'Extra brightness on top of the preset',
	Min = -20,
	Max = 20,
	Default = 0,
	Function = tune,
	Suffix = function()
		return '%'
	end
})
Saturation = Shaders:CreateSlider({
	Name = 'Saturation',
	Tooltip = 'Extra colour on top of the preset',
	Min = -30,
	Max = 50,
	Default = 0,
	Function = tune,
	Suffix = function()
		return '%'
	end
})
