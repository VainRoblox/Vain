local AutoClicker
local Mode
local GUICheck
local HeldItem
local RightClick
local StartDelay
local OnlyTargeting
local CPS
local BlockCPS = {}
local PlaceBlocks
local BurstMode
local BurstLength
local BurstPause
local Thread
local heldbutton
local burstcount = 0

-- task.cancel throws on a thread that has already finished, and Thread stays non-nil
-- after the loop below dies, so every call site goes through this. Without it a single
-- failed pass would make the next click error here and leave the module permanently
-- unable to start a new loop.
local function stopThread()
	if Thread then
		pcall(task.cancel, Thread)
		Thread = nil
	end
	heldbutton = nil
end

-- A real mouse click, the same way TriggerBot and SilentAim do it. This is what lets
-- Raw mode press buttons in menus - the game-API path below can only swing swords and
-- place blocks. The window check stops it clicking while the game is not focused.
local function rawClick(button)
	local active = isrbxactive or iswindowactive
	if not active or not active() then return false end

	if button == 2 then
		if not mouse2click then return false end
		mouse2click()
		return true
	end

	if not mouse1click then return false end
	mouse1click()
	return true
end

-- Whether something is actually within sword reach, using the same region check
-- TriggerBot relies on.
local function hasTarget()
	local ok, found = pcall(function()
		local tool = store.hand.tool
		local meta = tool and bedwars.ItemMeta[tool.Name]
		local range = meta and meta.sword and meta.sword.attackRange or 14.4
		return bedwars.SwordController:getTargetInRegion(range, 0) and true or false
	end)
	return ok and found
end

-- Returns true when a click actually happened, which is what the burst counter counts -
-- a pass that was skipped (menu open, nothing in reach) must not consume a burst.
local function doClick(button)
	if button == 2 then return rawClick(2) end
	if Mode.Value == 'Raw' then return rawClick(1) end

	if GUICheck.Enabled and bedwars.AppController:isLayerOpen(bedwars.UILayers.MAIN) then return false end

	local toolType = store.hand.toolType

	if toolType == 'block' then
		if HeldItem.Value == 'Sword' or not PlaceBlocks.Enabled then return false end
		local blockPlacer = bedwars.BlockPlacementController.blockPlacer
		if not blockPlacer then return false end
		if (workspace:GetServerTimeNow() - bedwars.BlockCpsController.lastPlaceTimestamp) < ((1 / 12) * 0.5) then return false end

		local mouseinfo = blockPlacer.clientManager:getBlockSelector():getMouseInfo(0)
		-- placementPosition == itself is a NaN check: NaN is the only value that fails
		-- an equality test against itself.
		if mouseinfo and mouseinfo.placementPosition == mouseinfo.placementPosition then
			task.spawn(blockPlacer.placeBlock, blockPlacer, mouseinfo.placementPosition)
			return true
		end
		return false
	end

	if toolType == 'sword' then
		if OnlyTargeting.Enabled and not hasTarget() then return false end
		bedwars.SwordController:swingSwordAtMouse()
		return true
	end

	-- Anything that is neither a sword nor a block has no game-side action, so fall back
	-- to a real click when the filter allows it.
	if HeldItem.Value == 'Any' then return rawClick(1) end
	return false
end

local function AutoClick(button)
	stopThread()
	burstcount = 0
	button = button or 1
	heldbutton = button

	Thread = task.delay(StartDelay.Value / 1000, function()
		repeat
			-- Guarded: the block placer chain reaches several layers into the game
			-- (clientManager -> block selector -> mouse info), any of which can be missing
			-- for a frame while switching items or respawning. An error used to kill this
			-- thread outright, and since Thread stayed set, the next click could not
			-- recover either. The wait is kept outside so a repeating error cannot spin.
			local ok, clicked = pcall(doClick, button)

			local usesblockcps = Mode.Value == 'Game' and button == 1 and store.hand.toolType == 'block'
			local delay = 1 / (usesblockcps and BlockCPS or CPS).GetRandomValue()

			if BurstMode.Enabled and ok and clicked then
				burstcount += 1
				if burstcount >= BurstLength.Value then
					burstcount = 0
					delay = BurstPause.Value / 1000
				end
			end

			task.wait(delay)
		until not AutoClicker.Enabled
	end)
end

-- Game mode drives the game's own sword/block calls, so the options that shape that
-- behaviour are meaningless in Raw mode and get hidden rather than sitting there doing
-- nothing.
local function refreshVisibility()
	local gamemode = Mode and Mode.Value == 'Game'
	for _, option in {GUICheck, HeldItem, OnlyTargeting, PlaceBlocks} do
		if option and option.Object then
			option.Object.Visible = gamemode
		end
	end
	if BlockCPS and BlockCPS.Object then
		BlockCPS.Object.Visible = gamemode and PlaceBlocks and PlaceBlocks.Enabled or false
	end
	for _, option in {BurstLength, BurstPause} do
		if option and option.Object then
			option.Object.Visible = BurstMode and BurstMode.Enabled or false
		end
	end
end

AutoClicker = vain.Categories.Combat:CreateModule({
	Name = 'AutoClicker',
	Function = function(callback)
		if callback then
			-- Deliberately NOT gated on gameProcessed. Bedwars covers the screen with an
			-- active HUD, so the engine reports practically every click as processed and
			-- gating on it stopped the clicker from ever starting. Menus are handled by
			-- the GUI check inside doClick instead, which tests the game's own UI layer.
			AutoClicker:Clean(inputService.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					AutoClick(1)
				elseif RightClick.Enabled and input.UserInputType == Enum.UserInputType.MouseButton2 then
					AutoClick(2)
				end
			end))

			-- Only the button that started the loop stops it, so tapping the other one
			-- mid-hold cannot cancel a click you are still holding.
			AutoClicker:Clean(inputService.InputEnded:Connect(function(input)
				if (heldbutton == 1 and input.UserInputType == Enum.UserInputType.MouseButton1)
					or (heldbutton == 2 and input.UserInputType == Enum.UserInputType.MouseButton2) then
					stopThread()
				end
			end))

			if inputService.TouchEnabled then
				pcall(function()
					AutoClicker:Clean(lplr.PlayerGui.MobileUI['2'].MouseButton1Down:Connect(function()
						AutoClick(1)
					end))
					AutoClicker:Clean(lplr.PlayerGui.MobileUI['2'].MouseButton1Up:Connect(stopThread))
				end)
			end
		else
			stopThread()
		end
	end,
	Tooltip = 'Hold attack button to automatically click'
})
Mode = AutoClicker:CreateDropdown({
	Name = 'Mode',
	Tooltip = 'How the clicks are sent',
	List = {'Game', 'Raw'},
	Tooltips = {
		Game = 'Calls the game directly to swing swords and place blocks',
		Raw = 'Sends real mouse clicks, so it also works on menus, GUIs and any item'
	},
	Function = refreshVisibility
})
CPS = AutoClicker:CreateTwoSlider({
	Name = 'CPS',
	Tooltip = 'Clicks per second, picked at random between both values',
	Min = 1,
	Max = 9,
	DefaultMin = 7,
	DefaultMax = 7
})
StartDelay = AutoClicker:CreateSlider({
	Name = 'Start Delay',
	Tooltip = 'Wait after pressing the button before the first automatic click',
	Min = 0,
	Max = 500,
	Default = 143,
	Suffix = function()
		return 'ms'
	end
})
HeldItem = AutoClicker:CreateDropdown({
	Name = 'Acts On',
	Tooltip = 'Which held items the clicker acts on',
	List = {'Sword & Blocks', 'Sword', 'Any'},
	Tooltips = {
		['Sword & Blocks'] = 'Swings with swords and places with blocks',
		Sword = 'Only swings with swords',
		Any = 'Also sends a real click while holding anything else'
	}
})
GUICheck = AutoClicker:CreateToggle({
	Name = 'GUI check',
	Tooltip = 'Stops clicking while a game menu is open',
	Default = true
})
OnlyTargeting = AutoClicker:CreateToggle({
	Name = 'Only While Targeting',
	Tooltip = 'Only swings when something is within sword reach'
})
RightClick = AutoClicker:CreateToggle({
	Name = 'Right Click',
	Tooltip = 'Also auto clicks when you hold the right mouse button'
})
PlaceBlocks = AutoClicker:CreateToggle({
	Name = 'Place Blocks',
	Tooltip = 'Also auto clicks while holding blocks',
	Default = true,
	Function = refreshVisibility
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
BurstMode = AutoClicker:CreateToggle({
	Name = 'Burst Mode',
	Tooltip = 'Clicks in bursts with a pause between them',
	Function = refreshVisibility
})
BurstLength = AutoClicker:CreateSlider({
	Name = 'Burst Length',
	Tooltip = 'How many clicks each burst fires before pausing',
	Min = 2,
	Max = 30,
	Default = 8,
	Darker = true,
	Visible = false
})
BurstPause = AutoClicker:CreateSlider({
	Name = 'Burst Pause',
	Tooltip = 'How long to wait between bursts',
	Min = 50,
	Max = 2000,
	Default = 250,
	Darker = true,
	Visible = false,
	Suffix = function()
		return 'ms'
	end
})
refreshVisibility()
