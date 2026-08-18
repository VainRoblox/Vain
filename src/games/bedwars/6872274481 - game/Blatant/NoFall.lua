local NoFall
local Mode
local FallSpeed
local ReportLanding
local rayParams = RaycastParams.new()

-- Stutter fights whatever these are doing to your vertical movement, so it stands down
-- while one of them is driving.
local function movementActive()
	for _, name in {'Fly', 'InfiniteFly', 'LongJump'} do
		local module = vain.Modules[name]
		if module and module.Enabled then return true end
	end
	return false
end

local groundHit
task.spawn(function()
	groundHit = bedwars.Client:Get(remotes.GroundHit).instance
end)

NoFall = vain.Categories.Blatant:CreateModule({
	Name = 'NoFall',
	Function = function(callback)
		if callback then
			local tracked = 0
			if Mode.Value == 'Stutter' then
				-- Fall damage here is client reported: FallDamageController samples your
				-- velocity every frame while the humanoid is in Freefall, and on the
				-- Freefall -> Landed transition fires the GroundHit remote with it. It
				-- never accumulates a distance. Cutting one long fall into a series of
				-- short ones therefore keeps whatever gets reported small, and keeps the
				-- replicated descent short for anything measuring it from the outside.
				local pending = false
				NoFall:Clean(runService.PreSimulation:Connect(function()
					if not entitylib.isAlive or movementActive() then
						pending = false
						return
					end

					local humanoid = entitylib.character.Humanoid
					local root = entitylib.character.RootPart
					local velocity = root.AssemblyLinearVelocity

					if humanoid.FloorMaterial == Enum.Material.Air and velocity.Y < -FallSpeed.Value then
						-- Kill the descent, then re-assert the CFrame so the position we are
						-- already at is what replicates out, rather than a continuous drop.
						root.AssemblyLinearVelocity = Vector3.new(velocity.X, 0, velocity.Z)
						root.CFrame = root.CFrame
						pending = ReportLanding.Enabled
					elseif pending then
						-- Deliberately a frame later than the reset above. The velocity the
						-- controller reports is sampled during rendering, which happens
						-- before this step, so by now it has resampled at near zero and the
						-- landing this announces carries no fall with it. Roblox puts the
						-- humanoid straight back into Freefall on the next physics step.
						pending = false
						humanoid:ChangeState(Enum.HumanoidStateType.Landed)
					end
				end))
			elseif Mode.Value == 'Gravity' then
				local extraGravity = 0
				NoFall:Clean(runService.PreSimulation:Connect(function(dt)
					if entitylib.isAlive then
						local root = entitylib.character.RootPart
						if root.AssemblyLinearVelocity.Y < -85 then
							rayParams.FilterDescendantsInstances = {lplr.Character, gameCamera}
							rayParams.CollisionGroup = root.CollisionGroup

							local rootSize = root.Size.Y / 2 + entitylib.character.HipHeight
							local ray = workspace:Blockcast(root.CFrame, Vector3.new(3, 3, 3), Vector3.new(0, (tracked * 0.1) - rootSize, 0), rayParams)
							if not ray then
								root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, -86, root.AssemblyLinearVelocity.Z)
								root.CFrame += Vector3.new(0, extraGravity * dt, 0)
								extraGravity += -workspace.Gravity * dt
							end
						else
							extraGravity = 0
						end
					end
				end))
			else
				repeat
					if entitylib.isAlive then
						local root = entitylib.character.RootPart
						tracked = entitylib.character.Humanoid.FloorMaterial == Enum.Material.Air and math.min(tracked, root.AssemblyLinearVelocity.Y) or 0

						if tracked < -85 then
							if Mode.Value == 'Packet' then
								groundHit:FireServer(nil, Vector3.new(0, tracked, 0), workspace:GetServerTimeNow())
							else
								rayParams.FilterDescendantsInstances = {lplr.Character, gameCamera}
								rayParams.CollisionGroup = root.CollisionGroup

								local rootSize = root.Size.Y / 2 + entitylib.character.HipHeight
								if Mode.Value == 'Teleport' then
									local ray = workspace:Blockcast(root.CFrame, Vector3.new(3, 3, 3), Vector3.new(0, -1000, 0), rayParams)
									if ray then
										root.CFrame -= Vector3.new(0, root.Position.Y - (ray.Position.Y + rootSize), 0)
									end
								else
									local ray = workspace:Blockcast(root.CFrame, Vector3.new(3, 3, 3), Vector3.new(0, (tracked * 0.1) - rootSize, 0), rayParams)
									if ray then
										tracked = 0
										root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, -80, root.AssemblyLinearVelocity.Z)
									end
								end
							end
						end
					end

					task.wait(0.03)
				until not NoFall.Enabled
			end
		end
	end,
	Tooltip = 'Prevents taking fall damage.'
})
local function refreshVisibility()
	for _, option in {FallSpeed, ReportLanding} do
		if option and option.Object then
			option.Object.Visible = Mode and Mode.Value == 'Stutter'
		end
	end
end

Mode = NoFall:CreateDropdown({
	Name = 'Mode',
	Tooltip = 'Which method this module uses',
	List = {'Packet', 'Gravity', 'Teleport', 'Bounce', 'Stutter'},
	Tooltips = {
		Packet = 'Reports hitting the ground while you are still in the air',
		Gravity = 'Caps your falling speed and moves you down by hand instead',
		Teleport = 'Drops you to the ground once you are falling fast',
		Bounce = 'Cuts your falling speed just before you land',
		Stutter = 'Breaks the fall into short drops by stopping you over and over'
	},
	Function = function()
		refreshVisibility()
		if NoFall.Enabled then
			NoFall:Toggle()
			NoFall:Toggle()
		end
	end
})
FallSpeed = NoFall:CreateSlider({
	Name = 'Fall Speed',
	Tooltip = 'Downward speed that triggers a stop',
	Min = 5,
	Max = 150,
	Default = 60,
	Darker = true,
	Visible = false,
	Suffix = function()
		return 'studs/s'
	end
})
ReportLanding = NoFall:CreateToggle({
	Name = 'Report Landing',
	Tooltip = 'Tells the server you landed each time the fall is stopped',
	Default = true,
	Darker = true,
	Visible = false
})
refreshVisibility()