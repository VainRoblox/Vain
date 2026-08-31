local RavenTP
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

		local raven = bedwars.RuntimeLib.await(bedwars.Client:Get(remotes.SpawnRaven):CallServerAsync())
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
	end,
	Tooltip = 'Spawns a raven, flies it to the player under your mouse and detonates it'
})
Speed = RavenTP:CreateSlider({
	Name = 'Speed',
	Tooltip = 'How fast it flies in\nDefault is 150',
	Min = 20,
	Max = 500,
	Default = 150,
	Suffix = 'studs/s'
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
