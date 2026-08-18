local Timer
local Value

-- Roblox retires fast flags without warning and setfflag throws outright once the name
-- is gone, so every call goes through this. A missing flag becomes a no-op instead of an
-- error raised on the same line every frame.
local function trySetFFlag(flag, value)
	return setfflag ~= nil and (pcall(setfflag, flag, value))
end

Timer = vain.Categories.Blatant:CreateModule({
	Name = 'Timer',
	Function = function(callback)
		if callback then
			trySetFFlag('SimEnableStepPhysics', 'True')
			trySetFFlag('SimEnableStepPhysicsSelective', 'True')

			Timer:Clean(runService.RenderStepped:Connect(function(dt)
				if Value.Value > 1 then
					runService:Pause()
					workspace:StepPhysics(dt * (Value.Value - 1), {entitylib.character.RootPart})
					runService:Run()
				end
			end))
		end
	end,
	Tooltip = 'Change the game speed.'
})
Value = Timer:CreateSlider({
	Name = 'Value',
	Min = 1,
	Max = 3,
	Decimal = 10
})