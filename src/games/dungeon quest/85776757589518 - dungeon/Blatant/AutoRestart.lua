local AutoRestart
local nextPress = 0

-- Rather than trying to work out when a run has ended - which would mean knowing how
-- this game tracks its own state - this watches for the button that offers the restart.
-- That button is only on screen once the dungeon is over, whether it was cleared or
-- everybody died, so its appearing is the signal. No knowledge of the game's internals
-- is needed, and it cannot fire mid-run because the button is not there to find.
local RESTART_WORDS = {
	'restart', 'play again', 'try again', 'retry', 'start over', 'again', 'replay',
	'new run', 'requeue', 'rejoin', 'next run', 'play'
}

local virtualInput = cloneref(game:GetService('VirtualInputManager'))

-- The game keeps its own remote for this, under ReplicatedStorage.remotes, so the
-- restart can be asked for directly instead of being mimed through the interface.
-- Hunting for a button meant guessing at its label, and a guess that is close but wrong
-- looks exactly like the module being broken.
--
-- The button is still used as a fallback: firing the remote is only right once a run has
-- actually ended, and the button appearing is what says so.
local function startRemote()
	local remotes = replicatedStorage:FindFirstChild('remotes')
	local remote = remotes and remotes:FindFirstChild('startDungeon')
	if not remote then return false end

	local ok = pcall(function()
		if remote:IsA('RemoteFunction') then
			remote:InvokeServer()
		else
			remote:FireServer()
		end
	end)
	return ok
end

-- A button is only really on screen if every frame above it is visible too, so this
-- walks up rather than trusting the button's own Visible.
local function onScreen(object)
	local current = object
	while current and current ~= lplr.PlayerGui do
		if current:IsA('GuiObject') and not current.Visible then return false end
		if current:IsA('ScreenGui') and not current.Enabled then return false end
		current = current.Parent
	end
	return true
end

local function matches(text)
	if not text or text == '' then return false end
	text = text:lower()
	for _, word in RESTART_WORDS do
		if text:find(word, 1, true) then return true end
	end
	return false
end

-- Checks the labels inside the button as well as the button itself.
--
-- A Roblox button usually carries no text of its own - the wording sits on a TextLabel
-- parented inside it - so matching only the button's own Text and Name found nothing at
-- all here, however right the word list was.
local function looksLikeRestart(button)
	if matches(button.Name) then return true end
	if button:IsA('TextButton') and matches(button.Text) then return true end

	for _, child in button:GetDescendants() do
		if child:IsA('TextLabel') and matches(child.Text) then return true end
		if child:IsA('TextButton') and matches(child.Text) then return true end
	end
	return false
end

local function findRestartButton()
	local gui = lplr:FindFirstChildOfClass('PlayerGui')
	if not gui then return nil end

	for _, object in gui:GetDescendants() do
		if object:IsA('GuiButton') and looksLikeRestart(object) and onScreen(object) then
			-- Zero sized buttons are usually templates parked off to one side rather
			-- than anything a player could press.
			if object.AbsoluteSize.X > 0 and object.AbsoluteSize.Y > 0 then
				return object
			end
		end
	end
	return nil
end

local function press(button)
	-- The button's own handlers first: that is the same path a real press takes, and it
	-- does not care where the button sits on screen.
	local fired = false
	if getconnections then
		for _, signal in {button.Activated, button.MouseButton1Click} do
			local ok, connections = pcall(getconnections, signal)
			if ok and connections then
				for _, connection in connections do
					pcall(function()
						connection:Fire()
					end)
					fired = true
				end
			end
		end
	end
	if fired then return end

	-- Otherwise click where it actually is, which works whatever the button is wired to.
	local centre = button.AbsolutePosition + (button.AbsoluteSize / 2)
	pcall(function()
		virtualInput:SendMouseButtonEvent(centre.X, centre.Y, 0, true, game, 1)
		task.wait()
		virtualInput:SendMouseButtonEvent(centre.X, centre.Y, 0, false, game, 1)
	end)
end

AutoRestart = vain.Categories.Blatant:CreateModule({
	Name = 'AutoRestart',
	Function = function(callback)
		if callback then
			nextPress = 0

			task.spawn(function()
				repeat
					local ok = pcall(function()
						-- Spaced out so a screen that takes a moment to change is not
						-- pressed repeatedly - on a menu that reuses the same button that
						-- can end up undoing itself.
						if tick() < nextPress then return end

						local button = findRestartButton()
						if not button then return end

						nextPress = tick() + 3

						-- Both: the remote is the reliable half, the press covers a build
						-- where the remote is named something else or expects arguments
						-- this does not send.
						local viaRemote = startRemote()
						press(button)
						notif('AutoRestart', viaRemote and 'Starting the dungeon over.' or 'Starting over (button only).', 4, 'info')
					end)

					task.wait(ok and 0.5 or 1)
				until not AutoRestart.Enabled
			end)
		end
	end,
	Tooltip = 'Starts the dungeon over once it has ended, whether it was cleared or everyone died'
})
