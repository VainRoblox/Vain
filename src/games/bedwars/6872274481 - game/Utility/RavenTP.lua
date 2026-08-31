local RavenTP
local Step
local Hold

-- Giving up rather than following a target who is never going to be reached.
local ARRIVE = 3
local TIMEOUT = 3

--[[
	Moves the raven a step towards a position and points it the way you are looking.

	A step at a time rather than one jump. The raven is yours to move - the game flies it
	from the client the same way - but a single enormous displacement is not something
	Roblox will carry across to the server, so the server kept its own idea of where the
	raven was. Close up the jump was small enough to survive, which is exactly why this
	only ever worked nearby.

	The velocity is cleared as well, or the throw the raven was launched with keeps
	dragging it off the position being written every frame.
]]
local function moveTowards(raven, target)
	local part = raven.PrimaryPart
	if not part or not part.Parent then return nil end

	part.AssemblyLinearVelocity = Vector3.zero

	local delta = target - part.Position
	local distance = delta.Magnitude
	local goal = distance > Step.Value and (part.Position + delta.Unit * Step.Value) or target

	raven:PivotTo(CFrame.lookAlong(goal, gameCamera.CFrame.LookVector))
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

		-- Flown in, then held. Detonating was previously fired on a timer while the raven
		-- was still on its way, so the server blew it up wherever it had got to - which
		-- over any distance was still next to you.
		local deadline = tick() + TIMEOUT
		local distance
		repeat
			local root = plr.Character and plr.RootPart
			if not root then break end

			distance = moveTowards(raven, root.Position)
			if not distance then break end
			task.wait()
		until distance <= ARRIVE or tick() > deadline

		local holding = tick() + Hold.Value
		repeat
			local root = plr.Character and plr.RootPart
			if not root or not moveTowards(raven, root.Position) then break end
			task.wait()
		until tick() > holding

		bedwars.RavenController:detonateRaven()
	end,
	Tooltip = 'Spawns a raven, flies it to the player under your mouse and detonates it'
})
Step = RavenTP:CreateSlider({
	Name = 'Step',
	Tooltip = 'How far it moves each frame\nSmaller carries further reliably',
	Min = 1,
	Max = 100,
	Default = 30,
	Suffix = 'studs'
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
