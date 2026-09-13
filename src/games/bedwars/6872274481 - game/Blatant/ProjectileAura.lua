local ProjectileAura
local Targets
local Range
local List
local OtherProjectiles
local ViewMode
local rayCheck = RaycastParams.new()
rayCheck.FilterType = Enum.RaycastFilterType.Include
local mapfolder
local FireDelays = {}
local ProjectileStub = {InvokeServer = function() end}
local projectileRemote = ProjectileStub

-- Resolving this once at load meant a single early failure - injecting before the
-- remotes are registered - left the stub in place for the whole session, so every shot
-- silently went nowhere. It runs again on enable while the stub is still there.
local function resolveProjectileRemote()
	if projectileRemote ~= ProjectileStub then return end
	local ok, remote = pcall(function()
		return bedwars.Client:Get(remotes.FireProjectile).instance
	end)
	if ok and remote then
		projectileRemote = remote
	end
end
task.spawn(resolveProjectileRemote)

-- The map is looked up rather than indexed. workspace.Map throws outright when it is
-- not there yet, which is the whole pre-match lobby - and this loop had no error
-- handling, so enabling the module before the round started killed it for good.
local function refreshMapFilter()
	local map = workspace:FindFirstChild('Map')
	if map ~= mapfolder then
		mapfolder = map
		rayCheck.FilterDescendantsInstances = map and {map} or {}
	end
end

-- What a character can stand on: anything collidable that is not a character. The map
-- filter above is what the arrow itself collides with; a floor has to include placed
-- blocks and everything else people stand on, wherever the game keeps them.
local floorCheck = RaycastParams.new()
floorCheck.FilterType = Enum.RaycastFilterType.Exclude
floorCheck.RespectCanCollide = true
local floorRefreshed = 0
local function refreshFloorFilter()
	if os.clock() - floorRefreshed < 0.5 then return end
	floorRefreshed = os.clock()
	local ignore = {gameCamera}
	if lplr.Character then
		table.insert(ignore, lplr.Character)
	end
	for _, ent in entitylib.List do
		if ent.Character then
			table.insert(ignore, ent.Character)
		end
	end
	floorCheck.FilterDescendantsInstances = ignore
end

-- First person puts the camera inside your own head, so the gap between the camera and
-- the head is what separates the two views. Shiftlock still counts as third person here,
-- which matches what you see on screen.
local function viewAllowed()
	if ViewMode.Value == 'Both' then return true end
	return bedwars.isFirstPerson() == (ViewMode.Value == 'First Person')
end

local function getAmmo(check)
	for _, item in store.inventory.inventory.items do
		if check.ammoItemTypes and table.find(check.ammoItemTypes, item.itemType) then
			return item.itemType
		end
	end
end

local function getProjectiles()
	local items = {}
	for _, item in store.inventory.inventory.items do
		-- An item the metadata does not know about used to throw here, and one unknown
		-- item anywhere in your inventory was enough to take the whole module down.
		local itemmeta = bedwars.ItemMeta[item.itemType]
		local proj = itemmeta and itemmeta.projectileSource
		local ammo = proj and getAmmo(proj)
		if ammo and (OtherProjectiles.Enabled or table.find(List.ListEnabled, ammo)) then
			table.insert(items, {
				item,
				ammo,
				proj.projectileType(ammo),
				proj
			})
		end
	end
	return items
end

ProjectileAura = vain.Categories.Blatant:CreateModule({
	Name = 'ProjectileAura',
	Function = function(callback)
		if callback then
			task.spawn(resolveProjectileRemote)
			-- Strafes, hops and knockback are read from what a target has been doing, so
			-- that is recorded every frame rather than only when a shot goes out.
			ProjectileAura:Clean(runService.Heartbeat:Connect(function()
				if not entitylib.isAlive then return end
				local here = entitylib.character.RootPart.Position
				for _, ent in entitylib.List do
					local root = ent.RootPart
					if root and ent.Targetable and (root.Position - here).Magnitude <= Range.Value + 20 then
						prediction.observe(root)
					end
				end
			end))
			repeat
				-- Guarded because this is a long-lived loop reaching into inventory and
				-- projectile metadata that changes underneath it. An error used to kill the
				-- coroutine outright, leaving the module switched on but permanently dead.
				-- The wait stays outside so a repeating error cannot spin the CPU.
				local ok = pcall(function()
					if (workspace:GetServerTimeNow() - bedwars.SwordController.lastAttack) > 0.5 and viewAllowed() then
						local ent = entitylib.EntityPosition({
							Part = 'RootPart',
							Range = Range.Value,
							Players = Targets.Players.Enabled,
							NPCs = Targets.NPCs.Enabled,
							Preference = Targets.Preference.Value,
							Wallcheck = Targets.Walls.Enabled
						})

						if ent then
							local pos = entitylib.character.RootPart.Position
							for _, data in getProjectiles() do
								local item, ammo, projectile, itemMeta = unpack(data)
								if (FireDelays[item.itemType] or 0) < tick() and item.tool then
									refreshMapFilter()
									refreshFloorFilter()
									local meta = bedwars.ProjectileMeta[projectile]
									local projSpeed = meta and meta.launchVelocity
									if not projSpeed then continue end
									local gravity = meta.gravitationalAcceleration or 196.2
									-- No latency lead. The server re-runs the shot with lag
									-- compensation, rewinding targets to where you saw them, so
									-- leading a round trip on top pushed every shot ahead of its
									-- target by ping times their speed.
									-- Their velocity as it stands. Strafes, hops and knockback are
									-- read from the history recorded above.
									local motion = ent.RootPart.AssemblyLinearVelocity
									local aimAt = ent.RootPart.Position

									-- How hard they take off on their next hop. Jumping stays set
									-- for a whole chain of hops, so this is never their speed now.
									local jumpSpeed
									if ent.Jumping then
										local hum = ent.Humanoid
										if hum then
											if hum.UseJumpPower then
												jumpSpeed = hum.JumpPower
											elseif hum.JumpHeight and hum.JumpHeight > 0 then
												jumpSpeed = math.sqrt(2 * math.max(workspace.Gravity, 1) * hum.JumpHeight)
											end
										end
										jumpSpeed = jumpSpeed or 42.6
									end

									local calc = prediction.SolveTrajectory(pos, projSpeed, gravity, aimAt, motion, workspace.Gravity, ent.HipHeight, jumpSpeed, rayCheck, {
										root = ent.RootPart,
										rootPosition = ent.RootPart.Position,
										lifetime = meta.lifetimeSec,
										floorParams = floorCheck,
									})
									if calc then
										targetinfo.Targets[ent] = tick() + 1
										local switched = switchItem(item.tool)

										task.spawn(function()
											local dir, id = CFrame.lookAt(pos, calc).LookVector, httpService:GenerateGUID(true)
											local shootPosition = (CFrame.new(pos, calc) * CFrame.new(Vector3.new(-bedwars.BowConstantsTable.RelX, -bedwars.BowConstantsTable.RelY, -bedwars.BowConstantsTable.RelZ))).Position
											bedwars.ProjectileController:createLocalProjectile(meta, ammo, projectile, shootPosition, id, dir * projSpeed, {drawDurationSeconds = 1})
											local res = projectileRemote:InvokeServer(item.tool, ammo, projectile, shootPosition, pos, dir * projSpeed, id, {drawDurationSeconds = 1, shotId = httpService:GenerateGUID(false)}, workspace:GetServerTimeNow() - 0.045)
											if not res then
												FireDelays[item.itemType] = tick()
											else
												local shoot = itemMeta.launchSound
												shoot = shoot and shoot[math.random(1, #shoot)] or nil
												if shoot then
													bedwars.SoundManager:playSound(shoot)
												end
											end
										end)

										FireDelays[item.itemType] = tick() + (itemMeta.fireDelaySec or 0.5)
										if switched then
											task.wait(0.05)
										end
									end
								end
							end
						end
					end
				end)

				task.wait(ok and 0.1 or 0.25)
			until not ProjectileAura.Enabled
		end
	end,
	Tooltip = 'Shoots people around you'
})
Targets = ProjectileAura:CreateTargets({
	Players = true,
	Walls = true,
	Tooltip = 'Which entities this module is allowed to target'
})
ViewMode = ProjectileAura:CreateDropdown({
	Name = 'View Mode',
	Tooltip = 'Which camera view this shoots in',
	List = {'Both', 'First Person', 'Third Person'},
	Tooltips = {
		Both = 'Shoots in either view',
		['First Person'] = 'Only while the camera is in your head',
		['Third Person'] = 'Only while the camera is behind you'
	}
})
List = ProjectileAura:CreateTextList({
	Name = 'Projectiles',
	Tooltip = 'Which projectiles this applies to',
	Default = {'arrow', 'snowball'}
})
OtherProjectiles = ProjectileAura:CreateToggle({
	Name = 'Other Projectiles',
	Tooltip = 'Uses every projectile you are holding instead of only the listed ones'
})
Range = ProjectileAura:CreateSlider({
	Name = 'Range',
	Tooltip = 'How far this reaches, in studs',
	Min = 1,
	Max = 50,
	Default = 50,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})