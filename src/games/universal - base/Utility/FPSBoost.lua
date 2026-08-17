--[[
	FPS Boost - strips out expensive rendering work for maximum framerate.

	Everything here is isolated with pcall on purpose. These optimizations touch engine
	settings and arbitrary game instances, any of which can throw (locked properties,
	instances destroyed mid-scan, executors without elevated identity). Without the
	isolation a single failure would kill the whole coroutine and silently take every
	later optimization down with it.
]]

local FPSBoost
local LowGraphics, DisableShadows, DisablePostFX, RemoveParticles, RemoveTrails
local RemoveDecals, SimplifyTerrain, SimplifyMaterials, LowMeshDetail, UncapFPS

local originalQuality
local originalShadows
local originalTerrain = {}
-- Instance-level originals, kept per type since each needs a different undo. Keyed by
-- instance so re-scanning can never double-store and clobber a real original value.
local disabledInstances = {} -- [PostEffect/ParticleEmitter/Trail/Beam] = true
local hiddenDecals = {} -- [Decal/Texture] = original Transparency
local loweredMeshes = {} -- [MeshPart] = original RenderFidelity
local unshadowedParts = {} -- [BasePart] = true (had CastShadow on)
local flattenedParts = {} -- [BasePart] = original Material

local function refresh()
	if FPSBoost.Enabled then
		FPSBoost:Toggle()
		FPSBoost:Toggle()
	end
end

-- Sets the render quality and returns whatever it was before, so the caller can put it
-- back exactly rather than guessing a default. settings() is not reachable from a normal
-- script thread - it needs elevated identity, which is what ThreadFix/setthreadidentity
-- provides. Always called through pcall since not every executor allows this at all.
local function applyQuality(level)
	if vain.ThreadFix then
		setthreadidentity(8)
	end
	local rendering = settings().Rendering
	local previous = rendering.QualityLevel
	rendering.QualityLevel = level
	return previous
end

-- Applies whichever optimizations are enabled to a single instance. Independent ifs,
-- not elseif: one MeshPart can legitimately need render fidelity, shadow and material
-- treatment all at once.
local function applyInstance(v)
	if DisablePostFX.Enabled and v:IsA('PostEffect') then
		if v.Enabled then
			disabledInstances[v] = true
			v.Enabled = false
		end
		return
	end

	if RemoveParticles.Enabled and v:IsA('ParticleEmitter') then
		if v.Enabled then
			disabledInstances[v] = true
			v.Enabled = false
		end
		return
	end

	if RemoveTrails.Enabled and (v:IsA('Trail') or v:IsA('Beam')) then
		if v.Enabled then
			disabledInstances[v] = true
			v.Enabled = false
		end
		return
	end

	if RemoveDecals.Enabled and (v:IsA('Decal') or v:IsA('Texture')) then
		if v.Transparency < 1 and hiddenDecals[v] == nil then
			hiddenDecals[v] = v.Transparency
			v.Transparency = 1
		end
		return
	end

	if not v:IsA('BasePart') then return end
	-- Never touch the local character - flattening its materials or dropping its mesh
	-- detail makes your own player look broken for zero framerate gain.
	if lplr.Character and v:IsDescendantOf(lplr.Character) then return end

	if LowMeshDetail.Enabled and v:IsA('MeshPart') and loweredMeshes[v] == nil then
		loweredMeshes[v] = v.RenderFidelity
		v.RenderFidelity = Enum.RenderFidelity.Performance
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

			-- Only hook/scan when something actually operates on instances, so leaving
			-- just the engine-level options on costs nothing per-instance.
			if
				DisablePostFX.Enabled or RemoveParticles.Enabled or RemoveTrails.Enabled
				or RemoveDecals.Enabled or LowMeshDetail.Enabled or DisableShadows.Enabled
				or SimplifyMaterials.Enabled
			then
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

			if originalShadows ~= nil then
				pcall(function()
					lightingService.GlobalShadows = originalShadows
				end)
				originalShadows = nil
			end

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

			for v, transparency in hiddenDecals do
				pcall(function()
					v.Transparency = transparency
				end)
			end
			table.clear(hiddenDecals)

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
		end
	end,
	Tooltip = 'Strips out expensive rendering work to boost your framerate.\nToggle individual optimizations below.'
})
LowGraphics = FPSBoost:CreateToggle({
	Name = 'Low Graphics Quality',
	Function = refresh,
	Default = true,
	Tooltip = "Forces Roblox's lowest graphics quality level.\nRequires an executor that allows elevated thread identity."
})
DisableShadows = FPSBoost:CreateToggle({
	Name = 'Disable Shadows',
	Function = refresh,
	Default = true,
	Tooltip = 'Turns off global shadows and stops every part in the world from casting one'
})
DisablePostFX = FPSBoost:CreateToggle({
	Name = 'Disable Post-Processing',
	Function = refresh,
	Default = true,
	Tooltip = 'Disables blur, bloom, color correction, sun rays and depth of field'
})
RemoveParticles = FPSBoost:CreateToggle({
	Name = 'Remove Particles',
	Function = refresh,
	Default = true,
	Tooltip = 'Disables particle emitters - explosions, weather, ability effects'
})
RemoveTrails = FPSBoost:CreateToggle({
	Name = 'Remove Trails & Beams',
	Function = refresh,
	Default = true,
	Tooltip = 'Disables trail and beam effects, e.g. weapon swing trails'
})
RemoveDecals = FPSBoost:CreateToggle({
	Name = 'Remove Decals & Textures',
	Function = refresh,
	Default = true,
	Tooltip = 'Hides decals and textures layered onto parts in the world'
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
	Tooltip = 'Replaces every material with SmoothPlastic.\nBig gain on material-heavy maps, but makes the world look plain.'
})
UncapFPS = FPSBoost:CreateToggle({
	Name = 'Uncap Framerate',
	Function = refresh,
	Tooltip = 'Removes the framerate cap while enabled, and sets it back to 60 when disabled.\nRequires executor support.'
})
