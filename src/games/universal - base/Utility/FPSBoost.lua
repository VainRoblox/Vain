--[[
	FPS Boost - strips out expensive rendering work for maximum framerate.

	Everything here is isolated with pcall on purpose. These optimizations touch engine
	settings and arbitrary game instances, any of which can throw (locked properties,
	instances destroyed mid-scan, executors without elevated identity). Without the
	isolation a single failure would kill the whole coroutine and silently take every
	later optimization down with it.

	Nothing is destroyed - everything is disabled/detached with its original value kept,
	so toggling the module off restores the world instead of leaving it wrecked until
	the player rejoins.
]]

local FPSBoost
local LowGraphics, DisableShadows, DisableLights, DisablePostFX, SimplifyLighting
local RemoveParticles, RemoveTrails, RemoveTextures, LowMeshDetail, SimplifyTerrain
local SimplifyMaterials, HideAccessories, MuteSounds, UncapFPS, DisableRendering
local instancetoggles

local originalQuality
local originalShadows
local originalTerrain = {}
local originalLighting = {}
local rendering3d
-- Instance-level originals, kept per type since each needs a different undo. Keyed by
-- instance so re-scanning can never double-store and clobber a real original value.
local disabledInstances = {} -- anything with an .Enabled bool
local hiddenDecals = {} -- [Decal/Texture] = original Transparency
local detachedInstances = {} -- [SurfaceAppearance/Atmosphere] = original Parent
local clearedTextures = {} -- [MeshPart] = original TextureID
local loweredMeshes = {} -- [MeshPart] = original RenderFidelity
local unshadowedParts = {} -- [BasePart] = true (had CastShadow on)
local flattenedParts = {} -- [BasePart] = original Material
local hiddenAccessories = {} -- [BasePart] = original Transparency
local mutedSounds = {} -- [Sound] = original Volume

local function refresh()
	if FPSBoost.Enabled then
		FPSBoost:Toggle()
		FPSBoost:Toggle()
	end
end

-- settings() and Set3dRenderingEnabled are not reachable from a normal script thread -
-- they need elevated identity, which is what ThreadFix/setthreadidentity provides.
-- Always called through pcall since not every executor allows this at all.
local function elevate()
	if vain.ThreadFix then
		setthreadidentity(8)
	end
end

-- Sets the render quality and returns whatever it was before, so the caller can put it
-- back exactly rather than guessing a default.
local function applyQuality(level)
	elevate()
	local rendering = settings().Rendering
	local previous = rendering.QualityLevel
	rendering.QualityLevel = level
	return previous
end

local function apply3dRendering(enabled)
	elevate()
	runService:Set3dRenderingEnabled(enabled)
end

local function disableInstance(v)
	if v.Enabled then
		disabledInstances[v] = true
		v.Enabled = false
	end
end

local function detachInstance(v)
	if v.Parent and detachedInstances[v] == nil then
		detachedInstances[v] = v.Parent
		v.Parent = nil
	end
end

-- Applies whichever optimizations are enabled to a single instance. Independent ifs for
-- the BasePart section, not elseif: one MeshPart can legitimately need render fidelity,
-- shadow, texture and material treatment all at once.
local function applyInstance(v)
	-- Never touch our own character. Beyond looking broken for no framerate gain, this
	-- is what keeps FPS Boost from fighting other modules that attach things to the
	-- local character - Fullbright's PointLight would otherwise get switched straight
	-- back off by the DisableLights pass.
	if lplr.Character and v:IsDescendantOf(lplr.Character) then return end

	if DisablePostFX.Enabled and v:IsA('PostEffect') then
		return disableInstance(v)
	end

	if DisableLights.Enabled and v:IsA('Light') then
		return disableInstance(v)
	end

	-- Fire/Smoke/Sparkles are the legacy effect classes - not ParticleEmitters, so they
	-- survive a naive particle pass entirely.
	if RemoveParticles.Enabled and (v:IsA('ParticleEmitter') or v:IsA('Fire') or v:IsA('Smoke') or v:IsA('Sparkles')) then
		return disableInstance(v)
	end

	if RemoveTrails.Enabled and (v:IsA('Trail') or v:IsA('Beam')) then
		return disableInstance(v)
	end

	if SimplifyLighting.Enabled and v:IsA('Clouds') then
		return disableInstance(v)
	end

	-- Atmosphere has no Enabled property, so it gets detached and put back later.
	if SimplifyLighting.Enabled and v:IsA('Atmosphere') then
		return detachInstance(v)
	end

	if RemoveTextures.Enabled then
		if v:IsA('Decal') or v:IsA('Texture') then
			if v.Transparency < 1 and hiddenDecals[v] == nil then
				hiddenDecals[v] = v.Transparency
				v.Transparency = 1
			end
			return
		end
		-- SurfaceAppearance is PBR (roughness/metalness/normal maps) and is one of the
		-- most expensive things a part can carry. It can't be disabled, only detached.
		if v:IsA('SurfaceAppearance') then
			return detachInstance(v)
		end
	end

	-- Layered clothing is deformation work every frame, per character wearing it.
	-- WrapLayer only - WrapTarget has no Enabled property to switch off.
	if HideAccessories.Enabled and v:IsA('WrapLayer') then
		return disableInstance(v)
	end

	if MuteSounds.Enabled and v:IsA('Sound') then
		if v.Volume > 0 and mutedSounds[v] == nil then
			mutedSounds[v] = v.Volume
			v.Volume = 0
		end
		return
	end

	if not v:IsA('BasePart') then return end

	if HideAccessories.Enabled and v.Parent and v.Parent:IsA('Accessory') and hiddenAccessories[v] == nil then
		hiddenAccessories[v] = v.Transparency
		v.Transparency = 1
	end

	if LowMeshDetail.Enabled and v:IsA('MeshPart') and loweredMeshes[v] == nil then
		loweredMeshes[v] = v.RenderFidelity
		v.RenderFidelity = Enum.RenderFidelity.Performance
	end

	if RemoveTextures.Enabled and v:IsA('MeshPart') and v.TextureID ~= '' and clearedTextures[v] == nil then
		clearedTextures[v] = v.TextureID
		v.TextureID = ''
	end

	if DisableShadows.Enabled and v.CastShadow then
		unshadowedParts[v] = true
		v.CastShadow = false
	end

	if SimplifyMaterials.Enabled and v.Material ~= Enum.Material.SmoothPlastic and flattenedParts[v] == nil then
		flattenedParts[v] = v.Material
		v.Material = Enum.Material.SmoothPlastic
	end
end

-- Chunked so a large map can't freeze the client mid-scan. Bails out if the module is
-- switched off while the scan is still running, otherwise the restore pass would race
-- against this and leave instances stuck in their optimized state.
local function scan(root)
	local processed = 0
	for _, v in root:GetDescendants() do
		if not FPSBoost.Enabled then return end
		pcall(applyInstance, v)
		processed += 1
		if processed % 2000 == 0 then
			task.wait()
		end
	end
end

local function needsScan()
	for _, v in instancetoggles do
		if v.Enabled then return true end
	end
	return false
end

FPSBoost = vain.Categories.Utility:CreateModule({
	Name = 'FPS Boost',
	Function = function(callback)
		if callback then
			if LowGraphics.Enabled then
				local suc, previous = pcall(applyQuality, Enum.QualityLevel.Level01)
				if suc then
					originalQuality = previous
				end
			end

			if DisableShadows.Enabled then
				pcall(function()
					originalShadows = lightingService.GlobalShadows
					lightingService.GlobalShadows = false
				end)
			end

			if SimplifyLighting.Enabled then
				pcall(function()
					originalLighting.EnvironmentDiffuseScale = lightingService.EnvironmentDiffuseScale
					originalLighting.EnvironmentSpecularScale = lightingService.EnvironmentSpecularScale
					lightingService.EnvironmentDiffuseScale = 0
					lightingService.EnvironmentSpecularScale = 0
				end)
			end

			if SimplifyTerrain.Enabled then
				pcall(function()
					local terrain = workspace.Terrain
					originalTerrain.WaterWaveSize = terrain.WaterWaveSize
					originalTerrain.WaterWaveSpeed = terrain.WaterWaveSpeed
					originalTerrain.WaterReflectance = terrain.WaterReflectance
					originalTerrain.Decoration = terrain.Decoration
					terrain.WaterWaveSize = 0
					terrain.WaterWaveSpeed = 0
					terrain.WaterReflectance = 0
					terrain.Decoration = false
				end)
			end

			if UncapFPS.Enabled and setfpscap then
				pcall(setfpscap, 9999)
			end

			if DisableRendering.Enabled then
				if pcall(apply3dRendering, false) then
					rendering3d = true
				end
			end

			-- Only hook/scan when something actually operates on instances, so leaving
			-- just the engine-level options on costs nothing per-instance.
			if needsScan() then
				FPSBoost:Clean(workspace.DescendantAdded:Connect(function(v)
					pcall(applyInstance, v)
				end))
				FPSBoost:Clean(lightingService.DescendantAdded:Connect(function(v)
					pcall(applyInstance, v)
				end))
				task.spawn(scan, workspace)
				task.spawn(scan, lightingService)
			end
		else
			if originalQuality then
				pcall(applyQuality, originalQuality)
				originalQuality = nil
			end

			if rendering3d then
				pcall(apply3dRendering, true)
				rendering3d = nil
			end

			if originalShadows ~= nil then
				pcall(function()
					lightingService.GlobalShadows = originalShadows
				end)
				originalShadows = nil
			end

			for prop, val in originalLighting do
				pcall(function()
					lightingService[prop] = val
				end)
			end
			table.clear(originalLighting)

			for prop, val in originalTerrain do
				pcall(function()
					workspace.Terrain[prop] = val
				end)
			end
			table.clear(originalTerrain)

			if UncapFPS.Enabled and setfpscap then
				pcall(setfpscap, 60)
			end

			for v in disabledInstances do
				pcall(function()
					v.Enabled = true
				end)
			end
			table.clear(disabledInstances)

			for v, parent in detachedInstances do
				pcall(function()
					v.Parent = parent
				end)
			end
			table.clear(detachedInstances)

			for v, transparency in hiddenDecals do
				pcall(function()
					v.Transparency = transparency
				end)
			end
			table.clear(hiddenDecals)

			for v, textureid in clearedTextures do
				pcall(function()
					v.TextureID = textureid
				end)
			end
			table.clear(clearedTextures)

			for v, fidelity in loweredMeshes do
				pcall(function()
					v.RenderFidelity = fidelity
				end)
			end
			table.clear(loweredMeshes)

			for v in unshadowedParts do
				pcall(function()
					v.CastShadow = true
				end)
			end
			table.clear(unshadowedParts)

			for v, material in flattenedParts do
				pcall(function()
					v.Material = material
				end)
			end
			table.clear(flattenedParts)

			for v, transparency in hiddenAccessories do
				pcall(function()
					v.Transparency = transparency
				end)
			end
			table.clear(hiddenAccessories)

			for v, volume in mutedSounds do
				pcall(function()
					v.Volume = volume
				end)
			end
			table.clear(mutedSounds)
		end
	end,
	Tooltip = 'Applies the optimizations selected below to boost your framerate'
})
LowGraphics = FPSBoost:CreateToggle({
	Name = 'Low Graphics Quality',
	Function = refresh,
	Default = true,
	Tooltip = "Forces Roblox's lowest graphics quality level"
})
DisableShadows = FPSBoost:CreateToggle({
	Name = 'Disable Shadows',
	Function = refresh,
	Default = true,
	Tooltip = 'Turns off global shadows and stops every part in the world from casting one'
})
DisableLights = FPSBoost:CreateToggle({
	Name = 'Disable Dynamic Lights',
	Function = refresh,
	Default = true,
	Tooltip = 'Disables point, spot and surface lights'
})
DisablePostFX = FPSBoost:CreateToggle({
	Name = 'Disable Post-Processing',
	Function = refresh,
	Default = true,
	Tooltip = 'Disables blur, bloom, color correction, sun rays and depth of field'
})
SimplifyLighting = FPSBoost:CreateToggle({
	Name = 'Simplify Lighting',
	Function = refresh,
	Default = true,
	Tooltip = 'Removes atmosphere and clouds, and drops ambient environment lighting'
})
RemoveParticles = FPSBoost:CreateToggle({
	Name = 'Remove Particles',
	Function = refresh,
	Default = true,
	Tooltip = 'Disables particle emitters plus fire, smoke and sparkles'
})
RemoveTrails = FPSBoost:CreateToggle({
	Name = 'Remove Trails & Beams',
	Function = refresh,
	Default = true,
	Tooltip = 'Disables trail and beam effects, e.g. weapon swing trails'
})
RemoveTextures = FPSBoost:CreateToggle({
	Name = 'Remove Textures',
	Function = refresh,
	Default = true,
	Tooltip = 'Strips decals, textures, mesh textures and PBR surface appearances'
})
LowMeshDetail = FPSBoost:CreateToggle({
	Name = 'Low Mesh Detail',
	Function = refresh,
	Default = true,
	Tooltip = 'Renders meshes at their lowest detail level'
})
SimplifyTerrain = FPSBoost:CreateToggle({
	Name = 'Simplify Terrain',
	Function = refresh,
	Default = true,
	Tooltip = 'Removes water waves/reflections and terrain decoration (grass, rocks)'
})
SimplifyMaterials = FPSBoost:CreateToggle({
	Name = 'Flatten Materials',
	Function = refresh,
	Tooltip = 'Replaces every material with SmoothPlastic'
})
HideAccessories = FPSBoost:CreateToggle({
	Name = 'Hide Accessories',
	Function = refresh,
	Tooltip = 'Hides other players\' hats and disables layered clothing deformation'
})
MuteSounds = FPSBoost:CreateToggle({
	Name = 'Mute Game Sounds',
	Function = refresh,
	Tooltip = 'Silences game audio'
})
UncapFPS = FPSBoost:CreateToggle({
	Name = 'Uncap Framerate',
	Function = refresh,
	Tooltip = 'Removes the framerate cap while enabled, and sets it back to 60 when disabled'
})
DisableRendering = FPSBoost:CreateToggle({
	Name = 'Disable 3D Rendering',
	Function = refresh,
	Tooltip = 'Stops the world from being drawn at all.\nYour screen goes blank while the game keeps running.'
})
instancetoggles = {
	DisableShadows, DisableLights, DisablePostFX, SimplifyLighting, RemoveParticles,
	RemoveTrails, RemoveTextures, LowMeshDetail, SimplifyMaterials, HideAccessories,
	MuteSounds
}
