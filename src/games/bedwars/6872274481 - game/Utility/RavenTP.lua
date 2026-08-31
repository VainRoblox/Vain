local RavenTP
local Legit
local Speed
local Hold

-- Giving up rather than following a target who is never going to be reached.
local ARRIVE = 3
local TIMEOUT = 3

--[[
	Flies the raven towards a position by giving it velocity, and turns it to face the way
	it is going.

	Writing a position was the whole problem. Nothing about the raven is sent to the
	server - the controller has no remote for it - so its position on the server comes
	from physics and physics alone. A position written here therefore moved the raven on
	your screen and nowhere else, the server carried on simulating its own, and the
	detonation, which the server places, went off back where the raven started. Next to
	you.

	Velocity is the same handle the game itself flies the raven with, and it is physics
	the server follows rather than a claim it has no reason to accept. Facing is set from
	the current position, so turning it cannot move it.
]]
local function steer(raven, target)
	local part = raven.PrimaryPart
	if not part or not part.Parent then return nil end

	local delta = target - part.Position
	local distance = delta.Magnitude
	if distance < 0.1 then return distance end

	part.AssemblyLinearVelocity = delta.Unit * Speed.Value
	part.CFrame = CFrame.lookAlong(part.Position, delta.Unit)
	return distance
end

--[[
	Spawns the raven the way the game does, and hands back the model it made.

	Blatant asks the SpawnRaven remote itself. The game never does that - it fires the
	RAVEN_SPAWN ability and lets its own controller make the call, which is what plays the
	throw animation and what the server is expecting to see. Asking the remote on its own
	is refused for reasons this module can only report as a cooldown.

	The controller's handleRaven is borrowed to catch the model on its way past, and
	deliberately not run: it owns a RenderStepped loop that writes the raven's velocity
	from your camera every frame, which would fight the steering below for control of the
	same property. Skipping it means none of the state it sets up exists to clean, so the
	only thing left to put back is the flag that stops you spawning another raven.
]]
local function legitSpawn()
	local controller = bedwars.RavenController
	local caught, old = nil, controller.handleRaven

	controller.handleRaven = function(_, model)
		caught = model
	end

	local ok = pcall(function()
		bedwars.AbilityController:useAbility(bedwars.AbilityId.RAVEN_SPAWN)
	end)

	if ok then
		for _ = 1, 120 do
			if caught then break end
			task.wait()
		end
	end

	controller.handleRaven = old
	if not caught and controller.activeRaven then
		-- The ability set this on the way in and nothing is going to clear it now.
		controller.activeRaven.Value = false
	end
	return caught
end

local function blatantSpawn()
	return bedwars.RuntimeLib.await(bedwars.Client:Get(remotes.SpawnRaven):CallServerAsync())
end

RavenTP = vain.Categories.Utility:CreateModule({
	Name = 'RavenTP',
	Function = function(callback)
		if not callback then return end
		RavenTP:Toggle()

		local plr = entitylib.EntityMouse({
			Range = 1000,
			Players = true,
			Part = 'RootPart'
		})

		if not getItem('raven') then
			notif('RavenTP', 'No raven', 3)
			return
		end
		if not plr then
			notif('RavenTP', 'No player under your mouse', 3)
			return
		end

		local raven = Legit.Enabled and legitSpawn() or blatantSpawn()
		if not raven then
			notif('RavenTP', 'Raven on cooldown', 3)
			return
		end

		if not raven.PrimaryPart then
			raven:GetPropertyChangedSignal('PrimaryPart'):Wait()
		end

		local bodyforce = Instance.new('BodyForce')
		bodyforce.Force = Vector3.new(0, raven.PrimaryPart.AssemblyMass * workspace.Gravity, 0)
		bodyforce.Parent = raven.PrimaryPart

		-- Flown in, then held on target. Detonating used to be fired on a fixed timer while
		-- the raven was still on its way, so even once it did move the server blew it up
		-- wherever it had got to by then.
		local deadline = tick() + TIMEOUT
		local distance
		repeat
			local root = plr.Character and plr.RootPart
			if not root then break end

			distance = steer(raven, root.Position)
			if not distance then break end
			task.wait()
		until distance <= ARRIVE or tick() > deadline

		-- Held still on top of the target rather than flying through it, and long enough
		-- for where it ended up to have reached the server before it is asked to explode.
		local holding = tick() + Hold.Value
		repeat
			local root = plr.Character and plr.RootPart
			local part = raven.PrimaryPart
			if not root or not part or not part.Parent then break end

			part.AssemblyLinearVelocity = Vector3.zero
			part.CFrame = CFrame.lookAlong(root.Position, gameCamera.CFrame.LookVector)
			task.wait()
		until tick() > holding

		bedwars.RavenController:detonateRaven()

		-- Nothing else is going to clear this, since the controller's own cleanup was
		-- never set up, and leaving it set refuses every raven after this one.
		if Legit.Enabled and bedwars.RavenController.activeRaven then
			task.delay(1, function()
				bedwars.RavenController.activeRaven.Value = false
			end)
		end
	end,
	Tooltip = 'Spawns a raven, flies it to the player under your mouse and detonates it'
})
Speed = RavenTP:CreateSlider({
	Name = 'Speed',
	Tooltip = 'How fast it flies in\nDefault is 150',
	Min = 20,
	Max = 108,
	Default = 108,
	Suffix = 'studs/s'
})
Legit = RavenTP:CreateToggle({
	Name = 'Legit',
	Tooltip = 'Throws the raven the way the game does'
})
Hold = RavenTP:CreateSlider({
	Name = 'Hold',
	Tooltip = 'Time on target before detonating\nDefault is 0.3',
	Min = 0,
	Max = 2,
	Default = 0.3,
	Decimal = 100,
	Suffix = 'seconds'
})
