--[[
	Bedwars - state and action logger.

	Records what every player you can see was looking at and what they did about it, ten
	times a second, and posts it to a receiver on your own machine. One row is a (state,
	action) pair: everything a policy will be allowed to look at, and the thing that was
	done while looking at it. That is the dataset for behaviour cloning - train a model to
	predict the action from the state and you have a first agent, with no reinforcement
	learning anywhere.

	Every player, not just you, because the data rate is what decides whether this is a
	weekend or a month. Logging yourself gives one row per tick; logging the lobby gives
	one per player per tick, and the good players in it are better demonstrators than you
	are. This is the local version of what VPT did with YouTube, minus the part where the
	actions have to be recovered from pixels.

	How another player's actions are recovered: their movement is their own velocity read
	in their own facing frame, their turning is the frame-to-frame change in that facing,
	and their jump is leaving the floor. All of it is in the replicated state already, so
	the inverse dynamics model that VPT had to train is arithmetic here.

	What is not recoverable that way is attacking - a swing is an animation rather than a
	physical fact - so for observed players that field is null rather than false, and
	training masks it. Your own rows have it for real, from your own input, which is why
	your own play is still the part that teaches aiming.

	Features are egocentric and in the subject's own frame. A policy fed world positions
	learns the map it was recorded on; fed 'the enemy is 12 studs ahead and 3 to the right'
	it learns the game.

	    AIVain.Stop()        stop and flush
	    AIVain.Rate = 10     samples a second
	    AIVain.Others        set false to record only yourself
	    AIVain.Url           where the receiver is listening
]]

local Players = game:GetService('Players')
local UserInputService = game:GetService('UserInputService')
local HttpService = game:GetService('HttpService')
local Workspace = game:GetService('Workspace')
local lplr = Players.LocalPlayer

local cfg = getgenv().AIVain or {}
cfg.Rate = cfg.Rate or 10
cfg.Url = cfg.Url or 'http://127.0.0.1:8750/ingest'
cfg.Batch = cfg.Batch or 40
cfg.EnemyRange = cfg.EnemyRange or 80
cfg.ObserveRange = cfg.ObserveRange or 150
if cfg.Others == nil then
	cfg.Others = true
end
getgenv().AIVain = cfg

-- Executors each name this differently and none of them agree. Whichever exists is the
-- one that can POST.
local post = (syn and syn.request) or (http and http.request) or http_request or request
if not post then
	return warn('[ai] this executor has no http request function, nothing can be sent')
end

local running = true
local queue = {}
local sent, dropped, rows, selfRows = 0, 0, 0, 0
local session = HttpService:GenerateGUID(false)

-- Last frame's pose per player, which is what turns two positions into a movement and two
-- facings into a turn. Keyed by the player so a respawn starts clean.
local tracked = {}

local function say(fmt, ...)
	print(string.format('[ai] '..fmt, ...))
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

--[[
	The frame a subject's state is expressed in.

	For you it is the camera, which is the thing you actually aim with. For everybody else
	the camera is not replicated, so the head stands in for it - the game tilts heads to
	follow where a player is looking, which makes it a far better estimate of aim than the
	root, and the root is kept only as a fallback for a character still assembling.
]]
local function viewFrame(plr, root, head)
	if plr == lplr then
		local camera = Workspace.CurrentCamera
		if camera then
			return camera.CFrame
		end
	end
	return head and head.CFrame or root.CFrame
end

-- Whether anything solid sits between two points. A policy that cannot tell is a policy
-- that swings at walls.
local function visible(from, to, ignore)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	return Workspace:Raycast(from, to - from, params) == nil
end

--[[
	The nearest living enemy of a given subject, from that subject's point of view.

	Worked out per subject rather than once for you, because a row recorded for another
	player is only a demonstration if the enemy in it is the one they were dealing with.
]]
local function nearestEnemy(subject, root)
	local mine = teamOf(subject)
	local best, bestDist, bestParts = nil, cfg.EnemyRange, nil

	for _, plr in Players:GetPlayers() do
		if plr ~= subject and (mine == nil or teamOf(plr) ~= mine) then
			local char, theirRoot, humanoid = parts(plr)
			if char then
				local dist = (theirRoot.Position - root.Position).Magnitude
				if dist < bestDist then
					best, bestDist, bestParts = plr, dist, {Root = theirRoot, Humanoid = humanoid, Character = char}
				end
			end
		end
	end

	return best, bestParts, bestDist
end

local function inventoryOf(plr)
	local char = plr.Character
	local value = char and char:FindFirstChild('InventoryFolder')
	local folder = value and value.Value
	local items = {}
	if not folder then
		return items
	end
	for _, child in folder:GetChildren() do
		items[child.Name] = (items[child.Name] or 0) + (child:GetAttribute('Amount') or 1)
	end
	return items
end

local function heldOf(plr, char)
	local tool = char:FindFirstChildOfClass('Tool')
	if tool then
		return tool.Name
	end
	if plr ~= lplr then
		return nil
	end
	-- Items are carried as accessories rather than tools, so your own hand is read off the
	-- store. Other players' hands are not replicated that way and stay unknown.
	local ok, hand = pcall(function()
		return require(lplr.PlayerScripts.TS.ui.store).ClientStore:getState().Inventory.observedInventory.inventory.hand
	end)
	return (ok and hand and hand.itemType) or nil
end

-- Wrapped into [-pi, pi], so turning past the back of a character is a small movement
-- rather than a jump of nearly two pi that would dominate every loss.
local function wrap(angle)
	if angle > math.pi then
		return angle - math.pi * 2
	end
	if angle < -math.pi then
		return angle + math.pi * 2
	end
	return angle
end

local function observe(plr, now)
	local char, root, humanoid, head = parts(plr)
	if not char then
		-- Death breaks the continuity of the deltas, so the pose is forgotten rather than
		-- carrying a jump across the respawn into the next row.
		tracked[plr] = nil
		return nil
	end

	local isSelf = plr == lplr
	local frame = viewFrame(plr, root, head)
	local pitch, yaw = frame:ToOrientation()
	local velocity = root.AssemblyLinearVelocity
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air

	local last = tracked[plr]
	tracked[plr] = {yaw = yaw, pitch = pitch, t = now, grounded = grounded}

	-- A subject seen for the first time has no deltas, so it is tracked and skipped rather
	-- than written with zeros that would teach the policy to stand still.
	if not last then
		return nil
	end

	local dt = now - last.t
	if dt <= 0 then
		return nil
	end

	local row = {
		t = now,
		dt = dt,
		player = plr.Name,
		isSelf = isSelf,
		health = humanoid.Health,
		maxHealth = humanoid.MaxHealth,
		grounded = grounded,
		speed = velocity.Magnitude,
		velY = velocity.Y,
		pitch = pitch,
		posY = root.Position.Y,
		held = heldOf(plr, char),
		items = isSelf and inventoryOf(plr) or nil
	}

	local enemy, enemyParts, dist = nearestEnemy(plr, root)
	-- Two characters occupying the same point are not a fight, they are a pair that has not
	-- finished spawning, and the direction between them is a zero vector whose Unit is NaN.
	-- Treated as nobody there rather than written out as a target at zero range.
	if enemy and dist < 0.5 then
		enemy = nil
	end
	if enemy and enemyParts then
		local rel = frame:PointToObjectSpace(enemyParts.Root.Position)
		local offset = enemyParts.Root.Position - root.Position
		row.enemy = {
			-- Right, up and ahead in the subject's own frame. Object space puts forward on
			-- negative Z, so it is flipped to read as 'ahead is positive'.
			x = rel.X,
			y = rel.Y,
			z = -rel.Z,
			dist = dist,
			health = enemyParts.Humanoid.Health,
			visible = visible(frame.Position, enemyParts.Root.Position, {char, enemyParts.Character, Workspace.CurrentCamera}),
			closing = offset.Magnitude > 0 and (enemyParts.Root.AssemblyLinearVelocity - velocity):Dot(offset.Unit) or 0
		}
	end

	--[[
		The action.

		Yours is read from your own input and is ground truth. Everyone else's is inferred
		from what their body did, which covers movement, turning and jumping exactly, and
		cannot cover attacking at all - so that field is null for them rather than false,
		and the training mask has to respect the difference. A null read as 'did not
		attack' would teach the policy that nobody ever swings.
	]]
	local flat = Vector3.new(velocity.X, 0, velocity.Z)
	local forward, right = 0, 0
	if flat.Magnitude > 1 then
		local direction = flat.Unit
		local look = frame.LookVector * Vector3.new(1, 0, 1)
		if look.Magnitude > 0 then
			look = look.Unit
			forward = direction:Dot(look)
			right = direction:Dot(frame.RightVector)
		end
	end

	--[[
		Written with explicit branches rather than 'a and b or c'.

		That idiom cannot carry a false: `isSelf and pressed or nil` collapses to nil the
		moment pressed is false, so the first recording stored the frames where the mouse
		was down and nothing at all for the frames where it was not. A label that only
		exists when it is true teaches a policy to always swing.
	]]
	local jump, attack, sprint
	if isSelf then
		jump = UserInputService:IsKeyDown(Enum.KeyCode.Space)
		attack = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
		sprint = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
	else
		-- Leaving the floor with upward speed, which is a jump whoever did it. Attacking
		-- and sprinting stay nil: neither is a physical fact that can be read off a body.
		jump = (not grounded) and last.grounded and velocity.Y > 1
	end

	row.action = {
		forward = forward,
		right = right,
		dYaw = wrap(yaw - last.yaw),
		dPitch = pitch - last.pitch,
		jump = jump,
		attack = attack,
		sprint = sprint,
		inferred = not isSelf
	}

	return row
end

local function flush()
	if #queue == 0 then
		return
	end

	local batch = queue
	queue = {}

	task.spawn(function()
		local ok = pcall(function()
			return post({
				Url = cfg.Url,
				Method = 'POST',
				Headers = {['Content-Type'] = 'application/json'},
				Body = HttpService:JSONEncode({session = session, samples = batch})
			})
		end)
		if ok then
			sent += #batch
		else
			dropped += #batch
		end
	end)
end

local function pass()
	local me = lplr.Character and lplr.Character:FindFirstChild('HumanoidRootPart')
	local now = tick()

	for _, plr in Players:GetPlayers() do
		local take = plr == lplr
		if not take and cfg.Others and me then
			local theirRoot = plr.Character and plr.Character:FindFirstChild('HumanoidRootPart')
			-- Distance limited, because a player across the map is replicated coarsely and
			-- a demonstration built from stale positions is worse than no demonstration.
			take = theirRoot ~= nil and (theirRoot.Position - me.Position).Magnitude <= cfg.ObserveRange
		end

		if take then
			local row = observe(plr, now)
			if row then
				table.insert(queue, row)
				rows += 1
				if row.isSelf then
					selfRows += 1
				end
			end
		end
	end

	if #queue >= cfg.Batch then
		flush()
	end
end

cfg.Stop = function()
	running = false
end

say('logging to %s at %d hz, session %s', cfg.Url, cfg.Rate, session)
say('recording %s. AIVain.Stop() when you are done', cfg.Others and 'everyone in range' or 'yourself only')

task.spawn(function()
	local reported = tick()
	while running do
		pcall(pass)

		if tick() - reported > 15 then
			reported = tick()
			say('%d rows (%d yours), %d sent, %d dropped', rows, selfRows, sent, dropped)
		end

		task.wait(1 / cfg.Rate)
	end

	flush()
	say('stopped: %d rows (%d yours), %d sent, %d dropped', rows, selfRows, sent, dropped)
end)
