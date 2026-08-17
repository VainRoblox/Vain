local FPSBoost
local LowGraphics, DisableShadows, DisablePostFX, RemoveParticles, RemoveTrails, RemoveDecals, SimplifyTerrain, UncapFPS

local originalQuality
local originalShadows
local originalTerrain = {}
local disabledEffects = {}
local disabledParticles = {}
local disabledTrails = {}
local disabledBeams = {}
local hiddenDecals = {}

-- Applies whichever optimizations are currently enabled to a single instance - called
-- once per existing descendant on enable, and hooked to DescendantAdded so anything
-- spawned later (other players' particles, a game script adding a new PostEffect, etc.)
-- gets caught too, not just what already existed when the module was toggled on.
local function applyInstance(v)
	if DisablePostFX.Enabled and v:IsA('PostEffect') and v.Enabled then
		disabledEffects[v] = true
		v.Enabled = false
	elseif RemoveParticles.Enabled and v:IsA('ParticleEmitter') and v.Enabled then
		disabledParticles[v] = true
		v.Enabled = false
	elseif RemoveTrails.Enabled and v:IsA('Trail') and v.Enabled then
		disabledTrails[v] = true
		v.Enabled = false
	elseif RemoveTrails.Enabled and v:IsA('Beam') and v.Enabled then
		disabledBeams[v] = true
		v.Enabled = false
	elseif RemoveDecals.Enabled and (v:IsA('Decal') or v:IsA('Texture')) and v.Transparency < 1 then
		hiddenDecals[v] = v.Transparency
		v.Transparency = 1
	end
end

FPSBoost = vain.Categories.Utility:CreateModule({
	Name = 'FPS Boost',
	Function = function(callback)
		if callback then
			if LowGraphics.Enabled then
				originalQuality = settings().Rendering.QualityLevel
				settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
			end
			if DisableShadows.Enabled then
				originalShadows = lightingService.GlobalShadows
				lightingService.GlobalShadows = false
			end
			if SimplifyTerrain.Enabled then
				local terrain = workspace.Terrain
				originalTerrain.WaterWaveSize = terrain.WaterWaveSize
				originalTerrain.WaterWaveSpeed = terrain.WaterWaveSpeed
				originalTerrain.WaterReflectance = terrain.WaterReflectance
				originalTerrain.Decoration = terrain.Decoration
				terrain.WaterWaveSize = 0
				terrain.WaterWaveSpeed = 0
				terrain.WaterReflectance = 0
				terrain.Decoration = false
			end
			if UncapFPS.Enabled and setfpscap then
				setfpscap(9999)
			end
			if DisablePostFX.Enabled or RemoveParticles.Enabled or RemoveTrails.Enabled or RemoveDecals.Enabled then
				FPSBoost:Clean(workspace.DescendantAdded:Connect(applyInstance))
				FPSBoost:Clean(lightingService.DescendantAdded:Connect(applyInstance))
				for _, v in workspace:GetDescendants() do
					applyInstance(v)
				end
				for _, v in lightingService:GetDescendants() do
					applyInstance(v)
				end
			end
		else
			if originalQuality then
				settings().Rendering.QualityLevel = originalQuality
				originalQuality = nil
			end
			if originalShadows ~= nil then
				lightingService.GlobalShadows = originalShadows
				originalShadows = nil
			end
			for prop, val in originalTerrain do
				workspace.Terrain[prop] = val
			end
			table.clear(originalTerrain)
			if UncapFPS.Enabled and setfpscap then
				setfpscap(60)
			end
			for v in disabledEffects do
				if v and v.Parent then
					v.Enabled = true
				end
			end
			table.clear(disabledEffects)
			for v in disabledParticles do
				if v and v.Parent then
					v.Enabled = true
				end
			end
			table.clear(disabledParticles)
			for v in disabledTrails do
				if v and v.Parent then
					v.Enabled = true
				end
			end
			table.clear(disabledTrails)
			for v in disabledBeams do
				if v and v.Parent then
					v.Enabled = true
				end
			end
			table.clear(disabledBeams)
			for v, transparency in hiddenDecals do
				if v and v.Parent then
					v.Transparency = transparency
				end
			end
			table.clear(hiddenDecals)
		end
	end,
	Tooltip = 'Applies performance optimizations to boost your framerate. Enable individual optimizations below.'
})
LowGraphics = FPSBoost:CreateToggle({
	Name = 'Low Graphics Quality',
	Function = function()
		if FPSBoost.Enabled then
			FPSBoost:Toggle()
			FPSBoost:Toggle()
		end
	end,
	Tooltip = "Forces the game to render at Roblox's lowest graphics quality level"
})
DisableShadows = FPSBoost:CreateToggle({
	Name = 'Disable Shadows',
	Function = function()
		if FPSBoost.Enabled then
			FPSBoost:Toggle()
			FPSBoost:Toggle()
		end
	end,
	Tooltip = 'Turns off dynamic shadows'
})
DisablePostFX = FPSBoost:CreateToggle({
	Name = 'Disable Post-Processing',
	Function = function()
		if FPSBoost.Enabled then
			FPSBoost:Toggle()
			FPSBoost:Toggle()
		end
	end,
	Tooltip = 'Disables blur, bloom, color correction, sun rays, and depth of field effects'
})
RemoveParticles = FPSBoost:CreateToggle({
	Name = 'Remove Particles',
	Function = function()
		if FPSBoost.Enabled then
			FPSBoost:Toggle()
			FPSBoost:Toggle()
		end
	end,
	Tooltip = 'Disables particle emitters in the world (explosions, weather, other effects)'
})
RemoveTrails = FPSBoost:CreateToggle({
	Name = 'Remove Trails & Beams',
	Function = function()
		if FPSBoost.Enabled then
			FPSBoost:Toggle()
			FPSBoost:Toggle()
		end
	end,
	Tooltip = 'Disables trail and beam effects, e.g. weapon swing trails'
})
RemoveDecals = FPSBoost:CreateToggle({
	Name = 'Remove Decals & Textures',
	Function = function()
		if FPSBoost.Enabled then
			FPSBoost:Toggle()
			FPSBoost:Toggle()
		end
	end,
	Tooltip = 'Hides decals and textures applied to parts in the world'
})
SimplifyTerrain = FPSBoost:CreateToggle({
	Name = 'Simplify Terrain',
	Function = function()
		if FPSBoost.Enabled then
			FPSBoost:Toggle()
			FPSBoost:Toggle()
		end
	end,
	Tooltip = 'Removes water waves/reflections and terrain decoration (grass, rocks, etc.)'
})
UncapFPS = FPSBoost:CreateToggle({
	Name = 'Uncap Framerate',
	Function = function()
		if FPSBoost.Enabled then
			FPSBoost:Toggle()
			FPSBoost:Toggle()
		end
	end,
	Tooltip = "Removes the client's framerate cap while enabled (resets to 60 when disabled). Requires executor support."
})
