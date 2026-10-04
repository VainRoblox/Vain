--[[
	Training Data.

	Writes what every player you can see was looking at and what they did about it to a
	file, ten times a second, for training a behaviour cloning model on later. One row is
	a (state, action) pair: the things a policy would be allowed to see, and the thing that
	was done while seeing them.

	Everyone in range rather than just you, because the data rate is what decides whether
	this takes a weekend or a month. Your own play gives one row a tick; a full lobby gives
	a dozen, and the good players in it are better demonstrators than most of us.

	Another player's movement, turning and jumping are all recoverable from their replicated
	state - their velocity read in their own facing, the frame to frame change in that
	facing, and leaving the floor. Attacking is not: a swing is an animation rather than a
	physical fact. So those columns are left empty for observed players rather than written
	as zero, and whatever reads this has to tell the difference. A blank that gets read as
	'did not attack' teaches a model that nobody ever swings.

	Names are not written. Each actor gets a number derived from their name, which keeps one
	player's rows together within a file without the file being a record of who you played
	with - it is meant to be shared, and that is not yours to hand over.

	Rows go to vain/training/, one file per session, as CSV with a header. Plain text so it
	can be opened, checked and thrown away by anyone who records it.
]]
local TrainingData
local Rate
local Others
local Range
local SaveEvery
local Notify
local writing = false
local flushing = false

--[[
	Rows are held in memory and written in one pass every few minutes.

	Writing as you go is what makes a recorder stutter: a file append is not free and doing
	one every tick puts a cost on the frame that the sampling itself does not. Four minutes
	of rows is a few megabytes, which costs nothing to hold and one visible moment to write.

	That moment is itself split up. A single append of several megabytes is a hitch you can
	feel in a fight, so the block goes out in pieces with a frame between them - the write
	takes a little longer in total and stops being something you notice.

	What this costs: a crash loses whatever has not been written yet, up to one interval.
	That is the trade being made, and it is the right way round for a recording that is
	meant to run in real matches.
]]
local CHUNK = 400

-- One file, appended to across every session, because the point is to be able to send it
-- to somebody. A folder of forty timestamped files is not that.
local FOLDER = 'vain/training'
local FILE = FOLDER..'/data.txt'
local COLUMNS = 't,dt,actor,is_self,health,max_health,grounded,speed,vel_y,pitch,enemy,ex,ey,ez,edist,ehealth,evisible,eclosing,held,forward,right,dyaw,dpitch,jump,attack,sprint'

-- Executors vary on which of these exist, and a missing appendfile is survivable by
-- rewriting the whole file; a missing writefile is not.
local canWrite = isfile and writefile
local appendTo = appendfile

local buffer = {}
local tracked = {}
local ready, rows, lost

local function say(text)
	if Notify and Notify.Enabled then
		notif('TrainingData', text, 3)
	end
end

--[[
	A stable number for a name, so rows from one player stay grouped without the name.

	A plain FNV walk rather than the hash library: this only has to be consistent inside a
	file and impossible to read backwards at a glance, and pulling a sha implementation in
	for it would cost more than it is worth.
]]
local function actorId(name)
	local hash = 2166136261
	for i = 1, #name do
		hash = bit32.bxor(hash, string.byte(name, i))
		hash = (hash * 16777619) % 4294967296
	end
	return hash % 100000
end

local function num(value)
	if value == nil then
		return ''
	end
	if value ~= value then
		-- NaN, which is what a direction between two characters standing in the same place
		-- comes out as. Written as nothing rather than as a number that is not one.
		return ''
	end
	return string.format('%.4f', value)
end

local function flag(value)
	if value == nil then
		return ''
	end
	return value and '1' or '0'
end

--[[
	Whether now is worth recording.

	The module is meant to be left switched on, so it decides for itself rather than asking
	anyone to remember. Three things have to hold.

	A real queue. The training room accepts transfers, answers yes and commits nothing, and
	its dummies stand still - rows from there are not demonstrations of anything and would
	teach a policy to fight statues.

	A match that is running. Once it has ended everyone mills about, and milling about is
	what a model trained on it would learn to do.

	Somebody to record. Being dead is not a reason to stop: a dead player is a spectating
	camera, and the people still alive are exactly the ones worth learning from.
]]
local function recordable()
	local queue = store.queueType
	if not queue or queue == 'training_room' or queue == 'bedwars_test' or queue:find('lobby') then
		return false
	end
	return store.matchState ~= 2
end

--[[
	Writes what is held, a few hundred rows at a time.

	Split up and spawned rather than written in one call: several megabytes in a single
	append is a hitch you feel, and the whole point of buffering was to not be felt. The
	buffer is taken first so that sampling can carry on filling a fresh one while this
	works through the old.
]]
local function flush()
	if flushing or #buffer == 0 then
		return
	end

	local block = buffer
	buffer = {}
	flushing = true

	task.spawn(function()
		for start = 1, #block, CHUNK do
			local piece = table.concat(block, '\n', start, math.min(start + CHUNK - 1, #block))..'\n'
			local ok = pcall(function()
				if appendTo then
					appendTo(FILE, piece)
				else
					writefile(FILE, (isfile(FILE) and readfile(FILE) or '')..piece)
				end
			end)
			if not ok then
				lost += 1
			end
			task.wait()
		end
		flushing = false
	end)
end

local function parts(plr)
	local char = plr.Character
	if not char then
		return nil
	end
	local root = char:FindFirstChild('HumanoidRootPart')
	local humanoid = char:FindFirstChildOfClass('Humanoid')
	if not root or not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return char, root, humanoid, char:FindFirstChild('Head')
end

local function teamOf(plr)
	local team = plr:GetAttribute('Team')
	return team ~= nil and tostring(team) or nil
end

-- For you the camera is the thing you aim with. For anyone else it is not replicated, so
-- the head stands in - the game tilts heads to follow where a player looks, which makes it
-- a far better estimate than the root.
local function viewFrame(plr, root, head)
	if plr == lplr then
		local camera = gameCamera
		if camera then
			return camera.CFrame
		end
	end
	return head and head.CFrame or root.CFrame
end

local function nearestEnemy(subject, root)
	local mine = teamOf(subject)
	local best, bestDist, bestParts = nil, Range.Value, nil

	for _, plr in playersService:GetPlayers() do
		if plr ~= subject and (mine == nil or teamOf(plr) ~= mine) then
			local char, theirRoot, humanoid = parts(plr)
			-- Characters sharing a point have not finished spawning; the direction between
			-- them is a zero vector and everything derived from it is NaN.
			if char then
				local dist = (theirRoot.Position - root.Position).Magnitude
				if dist < bestDist and dist > 0.5 then
					best, bestDist, bestParts = plr, dist, {Root = theirRoot, Humanoid = humanoid, Character = char}
				end
			end
		end
	end

	return best, bestParts, bestDist
end

local function heldOf(plr, char)
	local tool = char:FindFirstChildOfClass('Tool')
	if tool then
		return tool.Name
	end
	if plr ~= lplr then
		return ''
	end
	local hand = store.hand
	return (hand and hand.tool and hand.tool.Name) or ''
end

local function wrap(angle)
	if angle > math.pi then
		return angle - math.pi * 2
	end
	if angle < -math.pi then
		return angle + math.pi * 2
	end
	return angle
end

local function record(plr, now)
	local char, root, humanoid, head = parts(plr)
	if not char then
		-- A death breaks the continuity of the deltas, so the pose is forgotten rather than
		-- carrying a jump across the respawn into the next row.
		tracked[plr] = nil
		return
	end

	local isSelf = plr == lplr
	local frame = viewFrame(plr, root, head)
	local pitch, yaw = frame:ToOrientation()
	local velocity = root.AssemblyLinearVelocity
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air

	local last = tracked[plr]
	tracked[plr] = {yaw = yaw, pitch = pitch, t = now, grounded = grounded}
	-- First sighting has no deltas, so it is tracked and skipped rather than written with
	-- zeros that would read as somebody standing perfectly still.
	if not last then
		return
	end

	local dt = now - last.t
	if dt <= 0 then
		return
	end

	local enemy, enemyParts, dist = nearestEnemy(plr, root)
	local ex, ey, ez, ehealth, evisible, eclosing = nil, nil, nil, nil, nil, nil
	if enemy and enemyParts then
		local rel = frame:PointToObjectSpace(enemyParts.Root.Position)
		local offset = enemyParts.Root.Position - root.Position
		ex, ey, ez = rel.X, rel.Y, -rel.Z
		ehealth = enemyParts.Humanoid.Health
		eclosing = offset.Magnitude > 0 and (enemyParts.Root.AssemblyLinearVelocity - velocity):Dot(offset.Unit) or 0

		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = {char, enemyParts.Character, gameCamera}
		evisible = workspace:Raycast(frame.Position, offset, params) == nil
	end

	-- Movement in the subject's own facing, so the same key press is the same pair of
	-- numbers wherever they stand and whichever way they look.
	local flat = Vector3.new(velocity.X, 0, velocity.Z)
	local forward, right = 0, 0
	if flat.Magnitude > 1 then
		local look = frame.LookVector * Vector3.new(1, 0, 1)
		if look.Magnitude > 0 then
			local direction = flat.Unit
			forward = direction:Dot(look.Unit)
			right = direction:Dot(frame.RightVector)
		end
	end

	local jump, attack, sprint
	if isSelf then
		jump = inputService:IsKeyDown(Enum.KeyCode.Space)
		attack = inputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
		sprint = inputService:IsKeyDown(Enum.KeyCode.LeftShift)
	else
		-- Leaving the floor with upward speed is a jump whoever did it. The other two stay
		-- nil, and nil is written as an empty column rather than as a zero.
		jump = (not grounded) and last.grounded and velocity.Y > 1
	end

	table.insert(buffer, table.concat({
		num(now), num(dt), actorId(plr.Name), flag(isSelf),
		num(humanoid.Health), num(humanoid.MaxHealth), flag(grounded),
		num(velocity.Magnitude), num(velocity.Y), num(pitch),
		flag(enemy ~= nil), num(ex), num(ey), num(ez), num(dist), num(ehealth), flag(evisible), num(eclosing),
		heldOf(plr, char),
		num(forward), num(right), num(wrap(yaw - last.yaw)), num(pitch - last.pitch),
		flag(jump), flag(attack), flag(sprint)
	}, ','))
	rows += 1
end

local function pass()
	-- Measured from your character, or from the camera once you are dead. Falling back to
	-- the camera is what keeps a spectated fight worth recording: the players in it are
	-- still playing, and they are usually the last two alive.
	local root = lplr.Character and lplr.Character:FindFirstChild('HumanoidRootPart')
	local from = root and root.Position or (gameCamera and gameCamera.CFrame.Position)
	if not from then
		return
	end

	local now = tick()
	for _, plr in playersService:GetPlayers() do
		local take = plr == lplr
		if not take and Others.Enabled then
			local theirRoot = plr.Character and plr.Character:FindFirstChild('HumanoidRootPart')
			-- Distance limited: a player across the map replicates coarsely, and a
			-- demonstration built from stale positions is worse than none.
			take = theirRoot ~= nil and (theirRoot.Position - from).Magnitude <= 150
		end

		if take then
			record(plr, now)
		end
	end
end

TrainingData = vain.Categories.Utility:CreateModule({
	Name = 'TrainingData',
	Function = function(callback)
		if callback then
			if not canWrite then
				TrainingData:Toggle()
				return say('This executor cannot write files')
			end

			if makefolder and not (isfolder and isfolder(FOLDER)) then
				pcall(makefolder, 'vain')
				pcall(makefolder, FOLDER)
			end

			rows, lost = 0, 0
			table.clear(buffer)
			table.clear(tracked)

			-- The header belongs to the file, not to the session: this appends to the same
			-- file for as long as it is installed, so it is written once and only when the
			-- file is not already there.
			if not (isfile and isfile(FILE)) then
				local ok = pcall(writefile, FILE, COLUMNS..'\n')
				if not ok then
					TrainingData:Toggle()
					return say('Could not open a file to write')
				end
			end

			ready = true
			local active, lastSave = false, tick()

			repeat
				local now = recordable()

				--[[
					Switched on once and left alone, so the module decides when a match is
					worth recording and says so rather than silently filling or not filling
					a file.

					A match ending is also the moment to write: nobody is fighting, so the
					one pause this costs lands where it cannot be felt.
				]]
				if now ~= active then
					active = now
					table.clear(tracked)
					if now then
						say('Recording')
					else
						say('Paused, waiting for a match')
						flush()
						lastSave = tick()
					end
				end

				if now and not writing then
					writing = true
					pcall(pass)
					writing = false
				end

				if tick() - lastSave > SaveEvery.Value * 60 then
					lastSave = tick()
					flush()
				end

				task.wait(1 / Rate.Value)
			until not TrainingData.Enabled
		else
			writing = false
			-- Whatever is still in hand goes to the file, otherwise the last interval is
			-- lost every time this is switched off.
			if ready then
				pcall(flush)
				say(rows..' rows saved'..(lost > 0 and ', '..lost..' blocks lost' or ''))
			end
			ready = false
			table.clear(tracked)
		end
	end,
	Tooltip = 'Records play to a file for training an AI'
})
Rate = TrainingData:CreateSlider({
	Name = 'Rate',
	Tooltip = 'Rows per second\nDefault is 10',
	Min = 1,
	Max = 20,
	Default = 10,
	Suffix = 'hz'
})
Others = TrainingData:CreateToggle({
	Name = 'Everyone',
	Tooltip = 'Records every player in range, not just you',
	Default = true
})
Range = TrainingData:CreateSlider({
	Name = 'Enemy Range',
	Tooltip = 'How far an enemy counts as the one being faced',
	Min = 10,
	Max = 150,
	Default = 80,
	Suffix = 'studs'
})
SaveEvery = TrainingData:CreateSlider({
	Name = 'Save Every',
	Tooltip = 'How often rows are written to the file\nDefault is 4',
	Min = 1,
	Max = 10,
	Default = 4,
	Suffix = function(val)
		return val == 1 and 'minute' or 'minutes'
	end
})
Notify = TrainingData:CreateToggle({
	Name = 'Notify',
	Tooltip = 'Says when a recording starts and stops',
	Default = true
})
