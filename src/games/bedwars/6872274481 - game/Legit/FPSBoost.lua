local FPSBoost
local Kill
local Visualizer
local effects, util = {}, {}

--[[
	Named apart from the universal FPS Boost on purpose.

	Creating a module removes any existing module with the same name, and this file loads
	after the universal one - so while both were called FPS Boost, joining a match quietly
	deleted the real FPS Boost from Utility and put this smaller effects toggle in the Legit
	window in its place. That is why FPS Boost only ever appeared in the lobby: the lobby is
	the one place this file does not load.
]]
FPSBoost = vain.Legit:CreateModule({
	Name = 'Effect Remover',
	Function = function(callback)
		if callback then
			if Kill.Enabled then
				for i, v in bedwars.KillEffectController.killEffects do
					if not i:find('Custom') then
						effects[i] = v
						bedwars.KillEffectController.killEffects[i] = {
							new = function() 
								return {
									onKill = function() end, 
									isPlayDefaultKillEffect = function() 
										return true 
									end
								} 
							end
						}
					end
				end
			end

			if Visualizer.Enabled then
				for i, v in bedwars.VisualizerUtils do
					util[i] = v
					bedwars.VisualizerUtils[i] = function() end
				end
			end

			repeat task.wait() until store.matchState ~= 0
			if not bedwars.AppController then return end
			bedwars.NametagController.addGameNametag = function() end
			for _, v in bedwars.AppController:getOpenApps() do
				if tostring(v):find('Nametag') then
					bedwars.AppController:closeApp(tostring(v))
				end
			end
		else
			for i, v in effects do 
				bedwars.KillEffectController.killEffects[i] = v 
			end
			for i, v in util do 
				bedwars.VisualizerUtils[i] = v 
			end
			table.clear(effects)
			table.clear(util)
		end
	end,
	Tooltip = 'Turns off kill effects, the audio visualizer and match nametags for framerate'
})
Kill = FPSBoost:CreateToggle({
	Name = 'Kill Effects',
	Tooltip = 'Plays your equipped kill effect',
	Function = function()
		if FPSBoost.Enabled then
			FPSBoost:Toggle()
			FPSBoost:Toggle()
		end
	end,
	Default = true
})
Visualizer = FPSBoost:CreateToggle({
	Name = 'Visualizer',
	Tooltip = 'Shows a visualizer for the audio',
	Function = function()
		if FPSBoost.Enabled then
			FPSBoost:Toggle()
			FPSBoost:Toggle()
		end
	end,
	Default = true
})