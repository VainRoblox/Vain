local InfiniteJump

InfiniteJump = vain.Categories.Blatant:CreateModule({
	Name = 'InfiniteJump',
	Function = function(callback)
		if callback then
			InfiniteJump:Clean(inputService.InputBegan:Connect(function(input)
				if input.KeyCode ~= Enum.KeyCode.Space then return end
				-- Typing in chat still delivers the keypress, so this uses the same
				-- guard HighJump does rather than trusting gameProcessedEvent, which
				-- is not reliably set for the jump binding.
				if inputService:GetFocusedTextBox() then return end
				if not entitylib.isAlive then return end

				-- entitylib.character is a plain table describing the entity, not the
				-- character Instance - Humanoid is a field on it. Reaching for it with
				-- FindFirstChild threw on every single keypress.
				entitylib.character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
			end))
		end
	end,
	Tooltip = 'Lets you jump again while already in the air'
})
