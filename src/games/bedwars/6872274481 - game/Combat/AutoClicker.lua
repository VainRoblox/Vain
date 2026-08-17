local AutoClicker
local CPS
local BlockCPS = {}
local PlaceBlocks
local Thread

-- task.cancel throws on a thread that has already finished, and Thread stays non-nil
-- after the loop below dies, so every call site goes through this. Without it a single
-- failed pass would make the next click error here and leave the module permanently
-- unable to start a new loop.
local function stopThread()
	if Thread then
		pcall(task.cancel, Thread)
		Thread = nil
	end
end

local function AutoClick()
	stopThread()

	Thread = task.delay(1 / 7, function()
		repeat
			-- Guarded: the block placer chain below reaches several layers into the game
			-- (clientManager -> block selector -> mouse info), any of which can be missing
			-- for a frame while switching items or respawning. An error used to kill this
			-- thread outright, and since Thread stayed set, the next click could not
			-- recover either. The wait is kept outside so a repeating error cannot spin.
			pcall(function()
				if bedwars.AppController:isLayerOpen(bedwars.UILayers.MAIN) then return end

				local blockPlacer = bedwars.BlockPlacementController.blockPlacer
				if store.hand.toolType == 'block' and blockPlacer then
					if not PlaceBlocks.Enabled then return end
					if (workspace:GetServerTimeNow() - bedwars.BlockCpsController.lastPlaceTimestamp) >= ((1 / 12) * 0.5) then
						local mouseinfo = blockPlacer.clientManager:getBlockSelector():getMouseInfo(0)
						-- placementPosition == itself is a NaN check: NaN is the only value
						-- that fails an equality test against itself.
						if mouseinfo and mouseinfo.placementPosition == mouseinfo.placementPosition then
							task.spawn(blockPlacer.placeBlock, blockPlacer, mouseinfo.placementPosition)
						end
					end
				elseif store.hand.toolType == 'sword' then
					bedwars.SwordController:swingSwordAtMouse()
				end
			end)

			task.wait(1 / (store.hand.toolType == 'block' and BlockCPS or CPS).GetRandomValue())
		until not AutoClicker.Enabled
	end)
end

AutoClicker = vain.Categories.Combat:CreateModule({
	Name = 'AutoClicker',
	Function = function(callback)
		if callback then
			-- gameProcessed is honoured so clicking the Vain menu, the chat box or any
			-- game UI does not start the clicker. Previously the second argument was
			-- ignored, so interacting with any interface began auto clicking underneath it.
			AutoClicker:Clean(inputService.InputBegan:Connect(function(input, gameProcessed)
				if gameProcessed then return end
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					AutoClick()
				end
			end))

			AutoClicker:Clean(inputService.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					stopThread()
				end
			end))

			if inputService.TouchEnabled then
				pcall(function()
					AutoClicker:Clean(lplr.PlayerGui.MobileUI['2'].MouseButton1Down:Connect(AutoClick))
					AutoClicker:Clean(lplr.PlayerGui.MobileUI['2'].MouseButton1Up:Connect(stopThread))
				end)
			end
		else
			stopThread()
		end
	end,
	Tooltip = 'Hold attack button to automatically click'
})
CPS = AutoClicker:CreateTwoSlider({
	Name = 'CPS',
	Tooltip = 'Clicks per second, picked at random between both values',
	Min = 1,
	Max = 9,
	DefaultMin = 7,
	DefaultMax = 7
})
PlaceBlocks = AutoClicker:CreateToggle({
	Name = 'Place Blocks',
	Tooltip = 'Also auto clicks while holding blocks',
	Default = true,
	Function = function(callback)
		if BlockCPS.Object then
			BlockCPS.Object.Visible = callback
		end
	end
})
BlockCPS = AutoClicker:CreateTwoSlider({
	Name = 'Block CPS',
	Tooltip = 'Block places per second, picked at random between both values',
	Min = 1,
	Max = 12,
	DefaultMin = 12,
	DefaultMax = 12,
	Darker = true
})
