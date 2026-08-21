local InfiniteJump
local jumpCount

InfiniteJump = vain.Categories.Blatant:CreateModule({
	Name = 'InfiniteJump',
	Function = function(callback)
		if callback then
			jumpCount = 0
			InfiniteJump:Clean(inputService.InputBegan:Connect(function(input, gameProcessed)
				if gameProcessed then return end
				if input.KeyCode == Enum.KeyCode.Space then
					if entitylib.character and entitylib.character:FindFirstChild('Humanoid') then
						entitylib.character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
						jumpCount = jumpCount + 1
					end
				end
			end))
		else
			jumpCount = 0
		end
	end,
	Tooltip = 'Jump infinitely without needing to touch the ground'
})
