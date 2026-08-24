local AutoRestart
local nextPress = 0

-- Rather than trying to work out when a run has ended - which would mean knowing how
-- this game tracks its own state - this watches for the button that offers the restart.
-- That button is only on screen once the dungeon is over, whether it was cleared or
-- everybody died, so its appearing is the signal. No knowledge of the game's internals
-- is needed, and it cannot fire mid-run because the button is not there to find.
-- Whole phrases only.
--
-- 'play' and 'again' were in here on their own, and since the search also looks at the
-- labels inside a button, those matched almost any interface carrying the word - Play,
-- Replay, PlayerList - and fired a restart in the middle of a run.
local RESTART_WORDS = {
	'restart', 'play again', 'try again', 'start over', 'new run', 'next run', 'replay', 'requeue'
}

-- Starting a run puts up a confirmation, and nothing was answering it - so the restart
-- got as far as the popup and stopped there. These are the words on the button that
-- accepts it. 'start' is included because the dialog often repeats the action's name,
-- and it is only ever looked for in the couple of seconds after a restart has been asked
-- for, so it cannot pick up a stray Start button at any other time.
local CONFIRM_WORDS = {'yes', 'confirm', 'accept', 'ok', 'start', 'sure'}

-- How long to keep looking for the confirmation after asking for the restart.
local CONFIRM_WINDOW = 4

local virtualInput = cloneref(game:GetService('VirtualInputManager'))

-- A run is over when everyone is dead, or when the final boss has been beaten. A restart
-- button being on screen is not that: it turned out to be visible at other times too, so
-- pressing on sight restarted runs that were still going.
--
-- Both conditions are only meaningful once a run has actually started, which is what
-- seeing enemies establishes - otherwise sitting in the lobby, where nobody has a
-- character and there is nothing to fight, reads as a finished run.
local CLEARED_FOR = 3
local sawEnemies = false
local emptySince = 0

local function everyoneDead()
	local anyAlive = false
	for _, player in playersService:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass('Humanoid')
		if humanoid and humanoid.Health > 0 then
			anyAlive = true
			break
		end
	end
	return not anyAlive
end

local function runOver()
	local dq = vain.Libraries.dungeonquest
	dq.rescan()
	local enemy = dq.findEnemy()

	if enemy then
		sawEnemies = true
		emptySince = 0
		-- Enemies are up, so whatever is on screen, this run is still going.
		return false
	end

	if not sawEnemies then return false end

	if everyoneDead() then return true end

	-- Nothing left to fight for a few seconds running: the boss is down. Held for a
	-- moment rather than acted on instantly, since a gap between waves also looks empty.
	if emptySince == 0 then
		emptySince = tick()
	end
	return (tick() - emptySince) >= CLEARED_FOR
end

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

local function matches(text, words)
	if not text or text == '' then return false end
	text = text:lower()
	for _, word in words do
		if text:find(word, 1, true) then return true end
	end
	return false
end

-- Checks the labels inside the button as well as the button itself.
--
-- A Roblox button usually carries no text of its own - the wording sits on a TextLabel
-- parented inside it - so matching only the button's own Text and Name found nothing at
-- all here, however right the word list was.
local function looksLike(button, words)
	if matches(button.Name, words) then return true end
	if button:IsA('TextButton') and matches(button.Text, words) then return true end

	for _, child in button:GetDescendants() do
		if (child:IsA('TextLabel') or child:IsA('TextButton')) and matches(child.Text, words) then
			return true
		end
	end
	return false
end

local function findButton(words)
	local gui = lplr:FindFirstChildOfClass('PlayerGui')
	if not gui then return nil end

	for _, object in gui:GetDescendants() do
		if object:IsA('GuiButton') and looksLike(object, words) and onScreen(object) then
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

						-- The gate, not the button. A button appearing is not proof a run
						-- has ended, and acting on it alone restarted runs mid fight.
						if not runOver() then return end

						local button = findButton(RESTART_WORDS)

						nextPress = tick() + 3

						-- Both: the remote is the reliable half, the press covers a build
						-- where the remote is named something else or expects arguments
						-- this does not send.
						local viaRemote = startRemote()
						-- The button is optional now: the remote is the reliable path, and
						-- a build that names it differently still has the button to fall
						-- back on.
						if button then
							press(button)
						end

						if viaRemote or button then
							sawEnemies = false
							emptySince = 0
							notif('AutoRestart', 'Dungeon over - starting again.', 4, 'info')

							-- Answer the confirmation. It does not appear in the same frame
							-- as the request, so this waits for it rather than looking once
							-- and giving up - which is where the restart was stopping,
							-- leaving the popup sat on screen.
							task.spawn(function()
								local until_ = tick() + CONFIRM_WINDOW
								repeat
									local confirm = findButton(CONFIRM_WORDS)
									if confirm then
										press(confirm)
										return
									end
									task.wait(0.15)
								until tick() > until_
							end)
						end
					end)

					task.wait(ok and 0.5 or 1)
				until not AutoRestart.Enabled
			end)
		end
	end,
	Tooltip = 'Starts the dungeon over once it has ended, whether it was cleared or everyone died'
})
