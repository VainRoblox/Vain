local InfiniteJump

InfiniteJump = vain.Categories.Blatant:CreateModule({
	Name = 'InfiniteJump',
	Function = function(callback)
		if callback then
			InfiniteJump:Clean(inputService.InputBegan:Connect(function(input, gameProcessed)
				if gameProcessed or input.KeyCode ~= Enum.KeyCode.Space then return end
				if entitylib.isAlive and entitylib.character then
					local humanoid = entitylib.character:FindFirstChild('Humanoid')
					if humanoid then
						humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
					end
				end
			end))
		end
	end,
	Tooltip = 'Jump infinitely without needing to touch the ground'
})
