local UnhiddenMetal

UnhiddenMetal = vain.Categories.Utility:CreateModule({
	Name = 'Unhidden Metal',
	Function = function(callback)
		if callback then
			UnhiddenMetal:Clean(runService.Heartbeat:Connect(function()
				-- Metal Detector enables ProximityPrompts on hidden-metal tagged parts so you
				-- can interact with them. We do the same thing regardless of the kit.
				for _, model in collectionService:GetTagged('hidden-metal') do
					for _, child in model:GetChildren() do
						if child:IsA('ProximityPrompt') then
							child.Enabled = true
						end
					end
				end
			end))
		end
	end,
	Tooltip = 'Pick up metal without the Metal Detector kit'
})
