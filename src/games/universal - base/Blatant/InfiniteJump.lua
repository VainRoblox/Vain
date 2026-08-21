local InfiniteJump
local Delay
local nextjump = 0

InfiniteJump = vain.Categories.Blatant:CreateModule({
	Name = 'InfiniteJump',
	Function = function(callback)
		if callback then
			nextjump = 0
			-- Polled rather than driven off InputBegan so that holding the key keeps
			-- jumping instead of firing once per press.
			InfiniteJump:Clean(runService.RenderStepped:Connect(function()
				if not inputService:IsKeyDown(Enum.KeyCode.Space) then return end
				-- Typing in chat still reports the key as down, so this uses the same
				-- guard HighJump does rather than trusting gameProcessedEvent, which
				-- is not reliably set for the jump binding.
				if inputService:GetFocusedTextBox() then return end
				if not entitylib.isAlive then return end
				if tick() < nextjump then return end
				nextjump = tick() + Delay.Value

				-- entitylib.character is a plain table describing the entity, not the
				-- character Instance - Humanoid is a field on it.
				entitylib.character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
			end))
		end
	end,
	Tooltip = 'Lets you keep jumping in mid-air while jump is held'
})
Delay = InfiniteJump:CreateSlider({
	Name = 'Delay',
	Tooltip = 'How long to wait between jumps while held\n0 jumps every frame, which climbs very fast',
	Min = 0,
	Max = 0.5,
	Default = 0.1,
	Decimal = 100,
	Suffix = 'seconds'
})
