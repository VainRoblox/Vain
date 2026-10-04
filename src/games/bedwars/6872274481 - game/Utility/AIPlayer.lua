--[[
	AI Player.

	Runs the behaviour cloning policy trained on recorded play, either showing what it would
	do or letting it do it.

	The network is small - forty thousand weights - so it runs here rather than on the other
	end of a socket. A bridge to a Python process would put a round trip in front of every
	decision, and aiming is the one thing that cannot pay for one.

	Watch is the default and the one to start with. It builds the features, runs the policy
	and draws what it wanted to do beside what you actually did, without touching your
	character. That is not timidity: the features have to be built here exactly as the
	training script builds them, and a mismatch produces confident nonsense rather than an
	error. Watch is how you find that out. If the arrows roughly agree with your own hands
	while you fight, the two sides agree and Control is worth trying.

	What it has learned, from the validation it was trained under: where to move, well; which
	way and how fast to turn, reasonably; when to jump, slightly; when to swing, barely.
	Attack sits a point above always guessing 'no', and some of that is the policy noticing
	it was already swinging rather than deciding to. Treat movement and aim as the real
	outputs and the rest as a readout.

	The policy sees five frames of history and its own last four actions, so it needs to run
	at the rate it was recorded at - ten a second. Faster is not better here: it changes what
	a frame of history means and the weights were fitted to the old meaning.
]]
local AIPlayer
local Mode
local DoMove
local DoAim
local DoJump
local DoAttack
local AimSpeed
local Rate
local Notify

-- Where the exported weights come from, and where they are kept once fetched. Not bundled
-- with the script: it is four hundred kilobytes that most people loading Vain have no use
-- for.
local MODEL_URL = 'https://raw.githubusercontent.com/VainRoblox/Vain/main/tools/ai/model.lua'
local MODEL_FILE = 'vain/aimodel.lua'

-- Recorded at ten rows a second, so the history the policy reads means a half second. Run
-- it faster and every weight that depends on that spacing is being read wrong.
local TRAINED_RATE = 10

local model, features, history, actions
local ui, labels
local thinking = false

--[[
	What the policy decided last, applied every frame rather than every decision.

	Humanoid:Move is not a command, it is a value the engine reads each frame, and Roblox's
	own control script writes it sixty times a second from your keyboard. A call at ten
	hertz is overwritten before it is ever read, which is why Control appeared to do
	nothing at all.

	So the decision is held here and re-applied on Heartbeat, and the control script is
	switched off while Control is on - otherwise it would simply be writing zero over the
	top of this for every frame your hands are still.
]]
local function say(text)
	if Notify and Notify.Enabled then
		notif('AIPlayer', text, 3)
	end
end

local desired = {direction = Vector3.zero, jump = false, yaw = 0, pitch = 0}
local controls, controlled = nil, false

local function playerControls()
	if controls then
		return controls
	end
	local ok, module = pcall(function()
		return require(lplr.PlayerScripts:WaitForChild('PlayerModule', 5))
	end)
	controls = ok and module and module:GetControls() or nil
	return controls
end

-- Taking the keyboard away is the whole difference between the policy driving and the
-- policy suggesting, so it is explicit and it is always given back.
local function takeControl(take)
	if take == controlled then
		return
	end
	local module = playerControls()
	if not module then
		return say('Cannot reach the control module, movement will fight your keys')
	end
	controlled = take
	pcall(function()
		if take then
			module:Disable()
		else
			module:Enable()
		end
	end)
end

--[[
	The weights, from disk if they are there and from the repository if they are not.

	Cached rather than fetched every time: this is the same file for everybody until a
	better policy is trained, and a four hundred kilobyte download on every toggle is rude
	to both ends.
]]
local function loadModel()
	if model then
		return true
	end

	local source
	if isfile and isfile(MODEL_FILE) then
		source = readfile(MODEL_FILE)
	else
		local ok, body = pcall(game.HttpGet, game, MODEL_URL)
		if not ok or type(body) ~= 'string' or #body < 1000 or body:find('404') == 1 then
			say('Could not download the model')
			return false
		end
		source = body
		pcall(writefile, MODEL_FILE, body)
	end

	local chunk = loadstring(source, 'aimodel')
	if not chunk then
		say('The model file will not load')
		return false
	end

	local ok, result = pcall(chunk)
	if not ok or type(result) ~= 'table' or not result.trunk_0 then
		say('The model file is not a model')
		return false
	end

	model = result
	return true
end

-- out = W x + b, with W stored flat and row major. Written out rather than built from
-- tables of tables: this runs ten times a second and an inner table index per weight is the
-- whole cost of it.
local function forward(layer, input)
	local w, b, cols = layer.w, layer.b, layer.cols
	local out = table.create(layer.rows)
	for r = 1, layer.rows do
		local sum = b[r]
		local base = (r - 1) * cols
		for c = 1, cols do
			sum += w[base + c] * input[c]
		end
		out[r] = sum
	end
	return out
end

local function relu(values)
	for i, v in values do
		if v < 0 then
			values[i] = 0
		end
	end
	return values
end

local function sigmoid(x)
	return 1 / (1 + math.exp(-x))
end

local function parts(plr)
	local char = plr.Character
	if not char then return nil end
	local root = char:FindFirstChild('HumanoidRootPart')
	local humanoid = char:FindFirstChildOfClass('Humanoid')
	if not root or not humanoid or humanoid.Health <= 0 then return nil end
	return char, root, humanoid
end

local function teamOf(plr)
	local team = plr:GetAttribute('Team')
	return team ~= nil and tostring(team) or nil
end

local function nearestEnemy(root)
	local mine = teamOf(lplr)
	local best, bestDist, bestParts = nil, 80, nil
	for _, plr in playersService:GetPlayers() do
		if plr ~= lplr and (mine == nil or teamOf(plr) ~= mine) then
			local char, theirRoot, humanoid = parts(plr)
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

--[[
	One frame of state, in exactly the order train.py writes it.

	Fifteen numbers, then a slot per held item type, then a one for being yourself - which
	is always true here, since the thing being driven is you. The order is not arbitrary and
	is not negotiable: every weight was fitted against these positions.
]]
local function stateVector(root, humanoid)
	local frame = gameCamera.CFrame
	local pitch = select(1, frame:ToOrientation())
	local velocity = root.AssemblyLinearVelocity
	local enemy, enemyParts, dist = nearestEnemy(root)

	local v = table.create(model.numeric + model.heldSlots + 1, 0)
	v[1] = humanoid.Health / math.max(humanoid.MaxHealth, 1)
	v[2] = humanoid.FloorMaterial ~= Enum.Material.Air and 1 or 0
	v[3] = velocity.Magnitude
	v[4] = velocity.Y
	v[5] = pitch
	v[6] = enemy and 1 or 0

	if enemy then
		local rel = frame:PointToObjectSpace(enemyParts.Root.Position)
		local ex, ey, ez = rel.X, rel.Y, -rel.Z
		local offset = enemyParts.Root.Position - root.Position

		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = {lplr.Character, enemyParts.Character, gameCamera}

		v[7] = ex
		v[8] = ey
		v[9] = ez
		v[10] = dist
		v[11] = enemyParts.Humanoid.Health / 100
		v[12] = workspace:Raycast(frame.Position, offset, params) == nil and 1 or 0
		v[13] = offset.Magnitude > 0 and (enemyParts.Root.AssemblyLinearVelocity - velocity):Dot(offset.Unit) or 0
		v[14] = math.atan2(ex, math.max(ez, 1e-3))
		v[15] = math.atan2(ey, math.max(math.sqrt(ex * ex + ez * ez), 1e-3))
	end

	local hand = store.hand
	local held = hand and hand.tool and hand.tool.Name
	local slot = (held and model.vocab[held]) or model.heldSlots
	v[model.numeric + slot] = 1
	v[model.numeric + model.heldSlots + 1] = 1

	return v, enemy ~= nil
end

--[[
	The full input: five frames of state oldest first, then the four previous actions.

	The current frame's own action is deliberately absent. During training it was the answer
	being asked for, and handing it back as a question would have scored perfectly and
	taught nothing.
]]
local function buildInput(current)
	table.insert(history, current)
	while #history > model.history do
		table.remove(history, 1)
	end
	-- A fresh character has no past, so the oldest frames repeat the newest rather than
	-- being zeros, which would claim it had been standing still.
	while #history < model.history do
		table.insert(history, 1, current)
	end

	local width = model.numeric + model.heldSlots + 1
	local input = table.create(width * model.history + 7 * (model.history - 1), 0)

	for step = 1, model.history do
		local frame = history[step]
		local base = (step - 1) * width
		for i = 1, width do
			input[base + i] = frame[i]
		end
	end

	-- Past actions run most recent first, matching the training layout.
	for step = 1, model.history - 1 do
		local past = actions[#actions - step + 1]
		if past then
			local base = width * model.history + (step - 1) * 7
			for i = 1, 7 do
				input[base + i] = past[i]
			end
		end
	end

	return input
end

local function think(input)
	local mean, std = model.mean, model.std
	local normalised = table.create(#input)
	for i = 1, #input do
		normalised[i] = (input[i] - mean[i]) / std[i]
	end

	local h = relu(forward(model.trunk_0, normalised))
	h = relu(forward(model.trunk_3, h))

	local move = forward(model.move_0, h)
	local look = forward(model.look, h)
	local jump = forward(model.jump, h)
	local attack = forward(model.attack, h)

	return {
		-- The move head was trained through a tanh, so it is applied here too.
		forward = math.tanh(move[1]),
		right = math.tanh(move[2]),
		-- Look was learned standardised and in radians a second, so it is put back into
		-- both before it means anything.
		dYaw = look[1] * model.lookStd[1] + model.lookMean[1],
		dPitch = look[2] * model.lookStd[2] + model.lookMean[2],
		jump = sigmoid(jump[1]),
		attack = sigmoid(attack[1])
	}
end

-- What was actually done this frame, which is what the next frame reads as its history. In
-- Watch that is your hands; in Control it is the policy's own output, because that is what
-- happened.
local function remember(decision, controlling)
	local action
	if controlling then
		action = {decision.forward, decision.right, decision.dYaw, decision.dPitch, decision.jump > 0.5 and 1 or 0, decision.attack > 0.5 and 1 or 0, 1}
	else
		local velocity = entitylib.isAlive and entitylib.character.RootPart.AssemblyLinearVelocity or Vector3.zero
		local flat = Vector3.new(velocity.X, 0, velocity.Z)
		local f, r = 0, 0
		if flat.Magnitude > 1 then
			local frame = gameCamera.CFrame
			local look = frame.LookVector * Vector3.new(1, 0, 1)
			if look.Magnitude > 0 then
				f = flat.Unit:Dot(look.Unit)
				r = flat.Unit:Dot(frame.RightVector)
			end
		end
		action = {
			f, r, 0, 0,
			inputService:IsKeyDown(Enum.KeyCode.Space) and 1 or 0,
			inputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) and 1 or 0,
			1
		}
	end

	table.insert(actions, action)
	while #actions > model.history do
		table.remove(actions, 1)
	end
end

-- Records the decision for the per frame applier below. Nothing is written to the
-- character here: at ten hertz anything written is stale for five frames out of six.
local function apply(decision)
	local frame = gameCamera.CFrame
	local look = frame.LookVector * Vector3.new(1, 0, 1)
	if look.Magnitude > 0 and (math.abs(decision.forward) > 0.1 or math.abs(decision.right) > 0.1) then
		desired.direction = (look.Unit * decision.forward + frame.RightVector * decision.right)
	else
		desired.direction = Vector3.zero
	end

	desired.jump = decision.jump > 0.5
	-- Rates, kept as rates: the applier multiplies by its own frame time so a turn is the
	-- same speed whatever the framerate.
	desired.yaw = decision.dYaw
	desired.pitch = decision.dPitch

	if DoAttack.Enabled and decision.attack > 0.5 then
		pcall(function()
			bedwars.SwordController:swingSwordAtMouse()
		end)
	end
end

local function drive(dt)
	if not entitylib.isAlive then
		return
	end
	local humanoid = entitylib.character.Humanoid
	if not humanoid then
		return
	end

	if DoMove.Enabled and desired.direction.Magnitude > 0.1 then
		humanoid:Move(desired.direction.Unit, false)
	end

	if DoJump.Enabled and desired.jump then
		humanoid.Jump = true
	end

	if DoAim.Enabled and (desired.yaw ~= 0 or desired.pitch ~= 0) then
		local cf = gameCamera.CFrame
		local pitch, yaw = cf:ToOrientation()
		gameCamera.CFrame = CFrame.new(cf.Position)
			* CFrame.Angles(0, yaw + desired.yaw * dt * AimSpeed.Value, 0)
			* CFrame.Angles(math.clamp(pitch + desired.pitch * dt * AimSpeed.Value, -1.4, 1.4), 0, 0)
	end
end

local function drawUI(decision, hasEnemy)
	if not ui then return end
	labels.Move.Text = string.format('move  %+.2f fwd  %+.2f right', decision.forward, decision.right)
	labels.Look.Text = string.format('turn  %+.2f rad/s  %+.2f pitch', decision.dYaw, decision.dPitch)
	labels.Jump.Text = string.format('jump  %.0f%%   attack  %.0f%%', decision.jump * 100, decision.attack * 100)
	labels.Enemy.Text = hasEnemy and 'enemy in range' or 'no enemy - outputs are guesses'
	labels.Enemy.TextColor3 = hasEnemy and Color3.fromRGB(150, 255, 150) or Color3.fromRGB(255, 180, 120)
end

local function buildUI()
	ui = Instance.new('Frame')
	ui.Size = UDim2.fromOffset(300, 86)
	ui.Position = UDim2.new(0, 12, 0.5, -43)
	ui.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
	ui.BackgroundTransparency = 0.35
	ui.BorderSizePixel = 0
	ui.Parent = vain.gui
	AIPlayer:Clean(ui)

	local layout = Instance.new('UIListLayout')
	layout.Padding = UDim.new(0, 2)
	layout.Parent = ui

	local padding = Instance.new('UIPadding')
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingTop = UDim.new(0, 6)
	padding.Parent = ui

	labels = {}
	for _, name in {'Enemy', 'Move', 'Look', 'Jump'} do
		local label = Instance.new('TextLabel')
		label.Size = UDim2.new(1, -8, 0, 18)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.Code
		label.TextSize = 14
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Text = ''
		label.Parent = ui
		labels[name] = label
	end
end

AIPlayer = vain.Categories.Utility:CreateModule({
	Name = 'AIPlayer',
	Function = function(callback)
		if callback then
			if not loadModel() then
				return AIPlayer:Toggle()
			end

			history, actions = {}, {}
			desired = {direction = Vector3.zero, jump = false, yaw = 0, pitch = 0}
			buildUI()

			-- Every frame, because this is what the engine and the control script both
			-- work at, and a mover that runs slower than them loses.
			AIPlayer:Clean(runService.Heartbeat:Connect(function(dt)
				if Mode.Value == 'Control' then
					pcall(drive, dt)
				end
			end))
			say('Model loaded, '..model.width..' wide')

			local last = tick()
			repeat
				local now = tick()
				local dt = now - last

				if entitylib.isAlive and not thinking then
					thinking = true
					local ok = pcall(function()
						local root = entitylib.character.RootPart
						local humanoid = entitylib.character.Humanoid
						if not humanoid then return end

						local state, hasEnemy = stateVector(root, humanoid)
						local decision = think(buildInput(state))

						local controlling = Mode.Value == 'Control'
						takeControl(controlling and DoMove.Enabled)
						if controlling then
							apply(decision)
						end
						remember(decision, controlling)
						drawUI(decision, hasEnemy)
					end)
					if not ok then
						-- A character replaced mid decision is the usual cause, and the
						-- history it was reading belongs to a body that no longer exists.
						history, actions = {}, {}
					end
					thinking = false
				else
					if not entitylib.isAlive then
						history, actions = {}, {}
					end
				end

				last = now
				task.wait(1 / Rate.Value)
			until not AIPlayer.Enabled
		else
			thinking = false
			-- Handed back whatever happened, including an error on the way out: leaving
			-- somebody unable to walk is the worst thing this module could do.
			takeControl(false)
			ui, labels = nil, nil
			history, actions = nil, nil
		end
	end,
	Tooltip = 'Runs the trained policy, watching or playing'
})
Mode = AIPlayer:CreateDropdown({
	Name = 'Mode',
	Tooltip = 'Whether it plays or only shows what it would do',
	List = {'Watch', 'Control'},
	Tooltips = {
		Watch = 'Shows its decisions, touches nothing',
		Control = 'Lets it drive your character'
	}
})
DoMove = AIPlayer:CreateToggle({
	Name = 'Move',
	Tooltip = 'Lets it walk you around',
	Default = true
})
DoAim = AIPlayer:CreateToggle({
	Name = 'Aim',
	Tooltip = 'Lets it turn your camera'
})
DoJump = AIPlayer:CreateToggle({
	Name = 'Jump',
	Tooltip = 'Lets it jump',
	Default = true
})
DoAttack = AIPlayer:CreateToggle({
	Name = 'Attack',
	Tooltip = 'Lets it swing\nWeakest of the four outputs'
})
AimSpeed = AIPlayer:CreateSlider({
	Name = 'Aim Speed',
	Tooltip = 'Scales how hard it turns\nDefault is 1',
	Min = 0,
	Max = 3,
	Default = 1,
	Decimal = 100
})
Rate = AIPlayer:CreateSlider({
	Name = 'Rate',
	Tooltip = 'Decisions per second\nTrained at 10, do not change',
	Min = 5,
	Max = 20,
	Default = TRAINED_RATE,
	Suffix = 'hz'
})
Notify = AIPlayer:CreateToggle({
	Name = 'Notify',
	Tooltip = 'Says when the model loads',
	Default = true
})
