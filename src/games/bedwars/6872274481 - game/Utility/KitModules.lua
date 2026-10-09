--[[
	Kit modules, ported from the older VainV6 client.

	They are registered under the Kit category rather than that client's 'Kits', and
	live in Utility/ because VainBundler walks a hardcoded folder list and skips
	anything outside it - the folder decides what gets bundled, the category a module
	appears under is the one it is created from.

	Each of these was written against an older build of the game. The shared plumbing
	they rely on - notif, getItem, collection, sortmethods, addBlur, hotbarSwitch,
	getPlacedBlock, switchItem, roundPos, targetinfo, prediction, vainEvents - all still
	exists and matches, and the store fields they read (KillauraTarget, equippedKit,
	hand, inventory, matchState, shop) are all still populated. Remotes they reach for
	by a plain name now resolve through the fallback added in base.lua.

	What is not verified is the per-kit controller APIs. A kit reworked, renamed or
	removed since will have a module here that quietly does nothing. Adetunde and Zephyr
	both turned out to be filed under internal names matching nothing you would guess
	from the kit's display name, so expect some of these to need the same treatment.
]]


-- These modules do work at definition time - bedwars.Client:Get for a remote, most
-- commonly - and those calls yield. A yield hands the thread back to the scheduler,
-- and it resumes carrying the game's identity rather than the executor's, at which
-- point CreateModule cannot parent the window it builds and the module dies with
-- "lacking capability Plugin". Worse, the failure surfaces on whichever line runs
-- next, so it reads as a fault in a module that is fine.
--
-- Raising the identity at the start of every block means one module's yield cannot
-- take out the ones after it.
-- Not defined by the base, and not by the client these came from either - so the module
-- reaching for it (Fisherman, for its auto cast) threw the moment that path ran.
local VirtualInputManager = cloneref(game:GetService('VirtualInputManager'))

local function kitRun(func)
	if setthreadidentity then
		pcall(setthreadidentity, 8)
	end
	func()
end

-- Shared helpers these modules rely on. They live at the base level in the client
-- they came from, outside the module blocks, so they had to be brought across too.

local function getTeammates(namesOnly)
	local result = {}
	local myTeam = lplr:GetAttribute('Team')
	if not myTeam then return result end
	for _, player in playersService:GetPlayers() do
		if player ~= lplr and player:GetAttribute('Team') == myTeam then
			if namesOnly then
				table.insert(result, player.Name)
			elseif player.Character and player.Character:FindFirstChild('Humanoid') and player.Character.Humanoid.Health > 0 then
				table.insert(result, player)
			end
		end
	end
	if namesOnly then
		table.sort(result)
	end
	return result
end

local function getPlayerHealth(player)
	if not player or not player.Character then return 0, 100 end
	local health = player.Character:GetAttribute('Health') or (player.Character:FindFirstChildOfClass('Humanoid') and player.Character.Humanoid.Health) or 0
	local maxHealth = player.Character:GetAttribute('MaxHealth') or (player.Character:FindFirstChildOfClass('Humanoid') and player.Character.Humanoid.MaxHealth) or 100
	return health, maxHealth
end

local function getPlayerHealthPercent(player)
	local health, maxHealth = getPlayerHealth(player)
	if maxHealth == 0 then return 0 end
	return (health / maxHealth) * 100
end

local function getAccountTier(player)
	if getgenv().getAccountTier then
		return getgenv().getAccountTier(player)
	end
	return 0
end

local function getHotbar(tool)
	for i, v in (store.inventory.hotbar or {}) do
		if v.item and v.item.tool == tool then
			return i - 1
		end
	end
	return nil
end

local function isFirstPerson()
	local char = lplr.Character
	local head = char and char:FindFirstChild('Head')
	if not head or not gameCamera then return false end
	return (gameCamera.CFrame.Position - head.Position).Magnitude < 1.5
end

local function isGUIOpen()
	return inputService.MouseBehavior == Enum.MouseBehavior.Default
end

local function isHoldingBowCrossbow()
	if not store.hand then return false end
	local tt = store.hand.toolType
	if tt == 'bow' or tt == 'crossbow' then return true end
	local name = store.hand.tool and store.hand.tool.Name
	return name ~= nil and (name:find('bow') ~= nil or name:find('crossbow') ~= nil)
end

-- getPickaxeSlot, isHoldingPickaxe and isSword are called by the ported modules but
-- were never defined in that client either, so those paths threw "attempt to call a
-- nil value" there too. Implemented here against the current store.
local function isSword()
	return store.hand ~= nil and store.hand.toolType == 'sword'
end

local function getPickaxeSlot()
	local tool = store.tools and store.tools.stone
	if not (tool and tool.itemType) then return nil end
	local _, slot = getItem(tool.itemType)
	return slot
end

local function isHoldingPickaxe()
	local tool = store.hand and store.hand.tool
	if not tool then return false end
	local meta = bedwars.ItemMeta[tool.Name]
	return meta ~= nil and meta.breakBlock ~= nil and meta.breakBlock.stone ~= nil
end


kitRun(function()
	local KaidaKillaura	
	local Targets
	local AttackRange
	local UpdateRate
	local MouseDown
	local GUICheck
	local ShowAnimation
	local AutoAbility
	local AbilityDistance
	local SwingDuringAbility
	local lastAttackTime = 0
	local lastAbilityTime = 0
	local attackCooldown = 0.55
	local abilityCooldown = 22
	local isChargingAbility = false
	manualCharging = false
	local currentTarget = nil
	local AutoStopAbility
	local SummonerKitController = nil
	local function getSummonerController()
		if SummonerKitController then return SummonerKitController end
		pcall(function()
			SummonerKitController = bedwars.SummonerKitController
		end)
		return SummonerKitController
	end

	local function isActuallyCharging()
		if isChargingAbility then return true end
		if manualCharging then return true end
		local result = false
		pcall(function()
			local btns = lplr.PlayerGui
				:FindFirstChild("ActionBarScreenGui")
				and lplr.PlayerGui.ActionBarScreenGui:FindFirstChild("ActionBar")
				and lplr.PlayerGui.ActionBarScreenGui.ActionBar:FindFirstChild("AbilityButtons")
			if btns and btns:FindFirstChild("summoner_finish_charging") then
				result = true
			end
		end)
		return result
	end

	local function getSpellLevel()
		local level = 1
		pcall(function()
			local util = require(game:GetService("ReplicatedStorage").TS.games.bedwars.kit.kits.summoner['summoner-kit-util'])
			local result = util.summoner_getPlayerSpellLevel(lplr)
			if result then level = result end
		end)
		return level
	end

	local function getCastTime(level)
		local castTime = 2
		pcall(function()
			local util = require(game:GetService("ReplicatedStorage").TS.games.bedwars.kit.kits.summoner['summoner-kit-util'])
			local result = util.summoner_getTotalCastTimeRequired(level)
			if result then castTime = result end
		end)
		return castTime
	end

	local function fireUseAbility(abilityName)
		pcall(function()
			game:GetService("ReplicatedStorage")
				:WaitForChild("events-@easy-games/game-core:shared/game-core-networking@getEvents.Events")
				:WaitForChild("useAbility"):FireServer(abilityName)
		end)
	end

	local function doAutoAbility()
		if isChargingAbility then return end
		isChargingAbility = true

		pcall(function()
			local remote = game:GetService("ReplicatedStorage")
				:WaitForChild("events-@easy-games/game-core:shared/game-core-networking@getEvents.Events")
				:WaitForChild("useAbility")

			remote:FireServer(unpack({"summoner_start_charging"}))

			if AutoStopAbility.Enabled then
				task.wait(0.5)
				remote:FireServer(unpack({"summoner_finish_charging"}))
			else
				local level = getSpellLevel()
				local castTime = getCastTime(level)
				task.wait(math.max(castTime, 0.5))
				if isChargingAbility then
					remote:FireServer(unpack({"summoner_finish_charging"}))
					if currentTarget and currentTarget.RootPart then
						local myPos = entitylib.character.RootPart.Position
						local shootDir = CFrame.lookAt(myPos, currentTarget.RootPart.Position).LookVector
						local localPosition = myPos + shootDir * math.max((myPos - currentTarget.RootPart.Position).Magnitude - 16, 0)
						bedwars.Client:Get(remotes.SummonerClawAttack):SendToServer({
							position = localPosition,
							direction = shootDir,
							clientTime = workspace:GetServerTimeNow()
						})
					end
				end
			end
		end)

		lastAbilityTime = tick()
		isChargingAbility = false
	end

	local function getPlayerClawLevel()
		local handItem = lplr.Character and lplr.Character:FindFirstChild('HandInvItem')
		if handItem and handItem.Value then
			local itemType = handItem.Value.Name
			if itemType == 'summoner_claw_1' then return 1 end
			if itemType == 'summoner_claw_2' then return 2 end
			if itemType == 'summoner_claw_3' then return 3 end
			if itemType == 'summoner_claw_4' then return 4 end
		end
		if store and store.inventory and store.inventory.hotbar then
			for _, v in pairs(store.inventory.hotbar) do
				if v.item then
					local itemType = v.item.itemType
					if itemType == 'summoner_claw_1' then return 1 end
					if itemType == 'summoner_claw_2' then return 2 end
					if itemType == 'summoner_claw_3' then return 3 end
					if itemType == 'summoner_claw_4' then return 4 end
				end
			end
		end
		return 1
	end

	KaidaKillaura = vain.Categories.Kit:CreateModule({
		Name = 'Auto Kaida',
		Tooltip = 'Automates the Kaida kit flame breath ability',
		Function = function(callback)
			if callback then
				lastAttackTime = 0
				lastAbilityTime = 0
				isChargingAbility = false
				manualCharging = false   
				pcall(function()
					local abilityButtons = lplr.PlayerGui
						:WaitForChild("ActionBarScreenGui", 10)
						:WaitForChild("ActionBar", 10)
						:WaitForChild("AbilityButtons", 10)

					KaidaKillaura:Clean(abilityButtons.ChildRemoved:Connect(function(child)
						if child.Name == "summoner_start_charging" then
							manualCharging = true
						end
						if child.Name == "summoner_finish_charging" then
							manualCharging = false
						end
					end))

					KaidaKillaura:Clean(abilityButtons.ChildAdded:Connect(function(child)
						if child.Name == "summoner_start_charging" then
							manualCharging = false
						end
					end))

					if abilityButtons:FindFirstChild("summoner_finish_charging") then
						manualCharging = true
					end
				end)

				repeat
					if not entitylib.isAlive then
						task.wait(0.1)
						continue
					end

					if GUICheck.Enabled then
						if bedwars.AppController:isLayerOpen(bedwars.UILayers.MAIN) then
							task.wait(0.1)
							continue
						end
					end

					local handItem = lplr.Character:FindFirstChild('HandInvItem')
					local hasClaw = handItem and handItem.Value and handItem.Value.Name:find('summoner_claw') ~= nil

					if MouseDown.Enabled then
						if not inputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
							task.wait(1.2)
							continue
						end
					end

					local plr = nil
					do
						local bestDot = -math.huge
						local camCF = workspace.CurrentCamera.CFrame
						local myPos = entitylib.character.RootPart.Position
						for _, ent in ipairs(entitylib.List) do
							local validType = (Targets.Players.Enabled and ent.Player) or (Targets.NPCs.Enabled and ent.NPC)
							if validType and ent.Targetable and ent.RootPart and ent.Health > 0 then
								local dist = (myPos - ent.RootPart.Position).Magnitude
								if dist <= AttackRange.Value then
									local toEnt = (ent.RootPart.Position - camCF.Position).Unit
									local dot = camCF.LookVector:Dot(toEnt)
									if dot <= 0 then continue end
									if dot > bestDot then
										bestDot = dot
										plr = ent
									end
								end
							end
						end
					end

					if plr and plr.Health > 0 then
						local localPosition = entitylib.character.RootPart.Position
						local targetDistance = (localPosition - plr.RootPart.Position).Magnitude
						local now = tick()

						if AutoAbility.Enabled and targetDistance <= AbilityDistance.Value * 1.25 then
							if not isChargingAbility and (now - lastAbilityTime) >= abilityCooldown then
								currentTarget = plr
								task.spawn(doAutoAbility)
							end
						end

						if not SwingDuringAbility.Enabled and isChargingAbility then
							task.wait(0.05)
							continue
						end

						if hasClaw then
							local charging = isActuallyCharging()

							if not SwingDuringAbility.Enabled and charging then
								task.wait(0.05)
								continue
							end

							if (now - lastAttackTime) >= attackCooldown and targetDistance <= AttackRange.Value then
								local shootDir = CFrame.lookAt(localPosition, plr.RootPart.Position).LookVector
								localPosition += shootDir * math.max((localPosition - plr.RootPart.Position).Magnitude - 16, 0)
								lastAttackTime = now

								if ShowAnimation.Enabled then
									task.spawn(function()
										pcall(function()
											local clawLevel = getPlayerClawLevel()
											bedwars.AnimationUtil:playAnimation(lplr, bedwars.GameAnimationUtil:getAssetId(bedwars.AnimationType.SUMMONER_CHARACTER_SWIPE), {
												looped = false
											})
											local clawModel = replicatedStorage.Assets.Misc.Kaida.Summoner_DragonClaw:Clone()
											local clawColors = {
												Color3.fromRGB(75, 75, 75),
												Color3.fromRGB(255, 255, 255),
												Color3.fromRGB(43, 229, 229),
												Color3.fromRGB(49, 229, 94)
											}
											local nailMesh = clawModel:FindFirstChild("dragon_claw_nail_mesh")
											if nailMesh and nailMesh:IsA("MeshPart") then
												nailMesh.Color = clawColors[clawLevel] or clawColors[1]
											end
											if bedwars.SummonerKitSkinController then
												if bedwars.SummonerKitSkinController:isPrismaticSkin(lplr) then
													bedwars.SummonerKitSkinController:applyClawRGB(clawModel)
												end
											end
											clawModel.Parent = workspace
											local camera = workspace.CurrentCamera
											if camera and (camera.CFrame.Position - entitylib.character.RootPart.Position).Magnitude < 1 then
												for _, part in clawModel:GetDescendants() do
													if part:IsA('MeshPart') then
														part.Transparency = 0.6
													end
												end
											end
											local rootPart = entitylib.character.RootPart
											local Unit = Vector3.new(shootDir.X, 0, shootDir.Z).Unit
											local startPos = rootPart.Position + Unit:Cross(Vector3.new(0, 1, 0)).Unit * -1 * 5 + Unit * 6
											local direction = (startPos + shootDir * 13 - startPos).Unit
											local cframe = CFrame.new(startPos, startPos + direction)
											clawModel:PivotTo(cframe)
											clawModel.PrimaryPart.Anchored = true
											local portalConn = nil
											if clawModel:FindFirstChild("Portal1") then
												portalConn = runService.Heartbeat:Connect(function()
													if not clawModel or not clawModel.Parent then
														portalConn:Disconnect()
														portalConn = nil
														return
													end
													local foreArmCF = clawModel.RootPart.root.fore_arm.TransformedWorldCFrame
													if clawModel.Portal1 then
														clawModel.Portal1:PivotTo(foreArmCF)
													end
													if clawModel.Portal2 then
														clawModel.Portal2:PivotTo(foreArmCF * CFrame.Angles(math.pi, 0, 0))
													end
												end)
											end
											if clawModel:FindFirstChild('AnimationController') then
												local animator = clawModel.AnimationController:FindFirstChildOfClass('Animator')
												if animator then
													bedwars.AnimationUtil:playAnimation(animator, bedwars.GameAnimationUtil:getAssetId(bedwars.AnimationType.SUMMONER_CLAW_ATTACK), {
														looped = false,
														speed = 1
													})
												end
											end
											pcall(function()
												local sounds = {
													bedwars.SoundList.SUMMONER_CLAW_ATTACK_1,
													bedwars.SoundList.SUMMONER_CLAW_ATTACK_2,
													bedwars.SoundList.SUMMONER_CLAW_ATTACK_3,
													bedwars.SoundList.SUMMONER_CLAW_ATTACK_4
												}
												bedwars.SoundManager:playSound(sounds[math.random(1, #sounds)], {
													position = rootPart.Position
												})
											end)
											task.wait(0.5)
											if portalConn then
												portalConn:Disconnect()
												portalConn = nil
											end
											clawModel:Destroy()
										end)
									end)
								end

								bedwars.Client:Get(remotes.SummonerClawAttack):SendToServer({
									position = localPosition,
									direction = shootDir,
									clientTime = workspace:GetServerTimeNow()
								})
							end
						end
					else
						if isChargingAbility then
							isChargingAbility = false
							fireUseAbility("summoner_finish_charging")
						end
					end

					task.wait(1 / UpdateRate.Value)
				until not KaidaKillaura.Enabled

				isChargingAbility = false
			end
		end,
		Tooltip = 'Auto attacks with Summoner claw'
	})

	Targets = KaidaKillaura:CreateTargets({
		Tooltip = 'Configure which types of targets to include',
		Players = true,
		NPCs = true,
		Walls = true
	})

	AttackRange = KaidaKillaura:CreateSlider({
		Name = 'Attack Range',
		Tooltip = 'Distance at which the hit packet is sent',
		Min = 1,
		Max = 32,
		Default = 22,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	UpdateRate = KaidaKillaura:CreateSlider({
		Name = 'Update Rate',
		Tooltip = 'How often to scan for targets (seconds)',
		Min = 1,
		Max = 120,
		Default = 60,
		Suffix = 'hz'
	})

	MouseDown = KaidaKillaura:CreateToggle({
		Name = 'Require Mouse Down',
		Tooltip = 'Only attacks while holding left click'
	})

	GUICheck = KaidaKillaura:CreateToggle({
		Name = 'GUI Check',
		Tooltip = 'Pauses the module when a GUI menu is open',
	})

	ShowAnimation = KaidaKillaura:CreateToggle({
		Name = 'Show Animation',
		Tooltip = 'Plays the attack animation during killaura hits',
		Default = true
	})

	SwingDuringAbility = KaidaKillaura:CreateToggle({
		Name = 'Swing During Ability',
		Default = true,
		Tooltip = 'Continue claw attacks while charging ability'
	})

	AutoAbility = KaidaKillaura:CreateToggle({
		Name = 'Auto Ability',
		Default = false,
		Tooltip = 'Automatically uses ability when enemy is within distance',
		Function = function(callback)
			if not callback then
				isChargingAbility = false
			end
			AbilityDistance.Object.Visible = callback
			AutoStopAbility.Object.Visible = callback
		end
	})

	AbilityDistance = KaidaKillaura:CreateSlider({
		Name = 'Ability Distance',
		Min = 3,
		Max = 15,
		Default = 6,
		Visible = false,
		Tooltip = 'Distance to trigger ability',
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	AutoStopAbility = KaidaKillaura:CreateToggle({
		Name = 'Auto Stop Ability',
		Default = true,
		Visible = false,
		Tooltip = 'Cancels ability early if target leaves range mid-cast'
	})

	task.defer(function()
		if AbilityDistance and AbilityDistance.Object then
			AbilityDistance.Object.Visible = false   
		end
	end)
end)

kitRun(function()
    local AutoLasso
    local Targets
    local Range
    local FOV
    local AimPart
    local PredictionMode
    local projectileRemote = {InvokeServer = function() end}
    local nextAllowedShot = 0
    local rayCheck = RaycastParams.new()
    local COOLDOWN_SECONDS = 10.5

    task.spawn(function()
        projectileRemote = bedwars.Client:Get(remotes.FireProjectile).instance
    end)

    local function getLassoSlot()
        for i, v in store.inventory.hotbar do
            if v.item and v.item.itemType == "lasso" then
                return i - 1, v.item
            end
        end
        return nil, nil
    end

    local function getLassoProjectileMeta()
        local meta = bedwars.ProjectileMeta and bedwars.ProjectileMeta["lasso"]
        if meta then
            return meta.launchVelocity or 100, meta.gravitationalAcceleration or 196.2
        end
        return 100, 196.2
    end

    local function shootLasso(targetEnt)
        if not targetEnt or not targetEnt.RootPart then return false end

        local now = tick()
        if now < nextAllowedShot then return false end

        local lassoSlot, lassoItem = getLassoSlot()
        if not lassoSlot or not lassoItem then return false end

        local selfpos = entitylib.character.RootPart.Position
        local targetPart = targetEnt.RootPart

        if AimPart.Value == "Head" and targetEnt.Head then
            targetPart = targetEnt.Head
        elseif AimPart.Value == "Torso" then
            local torso = targetEnt.Character:FindFirstChild("UpperTorso") or targetEnt.Character:FindFirstChild("Torso")
            if torso then targetPart = torso end
        end

        local projSpeed, gravity = getLassoProjectileMeta()
        local targetPos = targetPart.Position
        local targetVel = targetPart.Velocity

        local aimPos = targetPos
        if PredictionMode.Value == "On" then
            local calc = prediction.SolveTrajectory(
                selfpos, projSpeed, gravity,
                targetPos, targetVel,
                workspace.Gravity, targetEnt.HipHeight,
                targetEnt.Jumping and 42.6 or nil,
                rayCheck
            )
            local targetRoot = plr.RootPart
						if targetRoot then
							local targetRootVel = targetRoot.AssemblyLinearVelocity or targetRoot.Velocity or Vector3.zero
							local targetMovingUp = targetRootVel.Y > 3
							local heightDiff = aimTarget.Y - newlook.p.Y
							if targetMovingUp then
								aimTarget = aimTarget + Vector3.new(0, math.clamp(targetRootVel.Y * 0.08, 0.5, 3.5), 0)
							elseif heightDiff < -8 then
								aimTarget = aimTarget + Vector3.new(0, math.clamp(math.abs(heightDiff) * 0.04, 0.3, 2.5), 0)
							end
						end
						if calc then aimPos = calc end
        end

        local dir = CFrame.lookAt(selfpos, aimPos).LookVector * projSpeed
        local originalSlot = store.inventory.hotbarSlot

        if originalSlot ~= lassoSlot then
            hotbarSwitch(lassoSlot)
            task.wait(0.05)
        end

        local success = pcall(function()
            projectileRemote:InvokeServer(
                lassoItem.tool,
                "lasso", "lasso",
                selfpos, selfpos, dir,
                httpService:GenerateGUID(true),
                {drawDurationSeconds = 1, shotId = httpService:GenerateGUID(false)},
                workspace:GetServerTimeNow() - 0.045
            )
        end)

        if originalSlot ~= lassoSlot then
            hotbarSwitch(originalSlot)
        end

        if success then
            nextAllowedShot = now + COOLDOWN_SECONDS
            targetinfo.Targets[targetEnt] = now + 1
            return true
        end
        return false
    end

    AutoLasso = vain.Categories.Kit:CreateModule({
        Name = 'Auto Lasso',
        Tooltip = 'Automatically uses the lasso on nearby enemies',
        Function = function(callback)
            if callback then
                repeat
                    if entitylib.isAlive then
                        local target = entitylib.EntityPosition({
                            Range = Range.Value,
                            Part = 'RootPart',
                            Wallcheck = Targets.Walls.Enabled,
                            Players = Targets.Players.Enabled,
                            NPCs = Targets.NPCs.Enabled,
                            Sort = sortmethods.Distance
                        })

                        if target then
							if getAccountTier(target.Player) >= 1 and getAccountTier(lplr) == 0 then continue end
                            local selfpos = entitylib.character.RootPart.Position
                            -- The camera, rather than a ViewMode setting. This module
                            -- never had one: the name read here belongs to Aim Assist's
                            -- block, so out here it was a nil global and this threw on
                            -- the first target that came into range. An FOV is a cone
                            -- around where you are looking, which is the camera.
                            local localFacing = gameCamera.CFrame.LookVector * Vector3.new(1, 0, 1)
                            local delta = (target.RootPart.Position - selfpos) * Vector3.new(1, 0, 1)
                            if delta.Magnitude > 0.001 then
                                local angle = math.acos(math.clamp(localFacing:Dot(delta.Unit), -1, 1))
                                if angle <= math.rad(FOV.Value) / 2 then
                                    shootLasso(target)
                                end
                            end
                        end
                    end
                    task.wait(0.05)
                until not AutoLasso.Enabled
            else
                nextAllowedShot = 0
            end
        end,
        Tooltip = 'Switches to lasso, shoots once, then switches back. 10.5 second cooldown.'
    })

    Targets = AutoLasso:CreateTargets({
    	Tooltip = 'Configure which types of targets to include',
        Players = true,
        NPCs = true,
        Walls = false
    })

    Range = AutoLasso:CreateSlider({
        Name = 'Range',
        Tooltip = 'Maximum distance in studs',
        Min = 5,
        Max = 80,
        Default = 50,
        Suffix = function(val)
            return val == 1 and 'stud' or 'studs'
        end
    })

    FOV = AutoLasso:CreateSlider({
        Name = 'FOV',
        Tooltip = 'Field-of-view cone in degrees for target detection',
        Min = 1,
        Max = 360,
        Default = 90
    })

    AimPart = AutoLasso:CreateDropdown({
        Name = 'Aim Part',
        Tooltip = 'Which body part on the target to aim at',
        List = {'RootPart', 'Head', 'Torso'},
        Default = 'RootPart',
        ItemTooltips = {
            RootPart = 'Aims at the center of the player\'s body (HumanoidRootPart)',
            Head = 'Aims at the head — higher damage potential but smaller hitbox',
            Torso = 'Aims at the upper torso',
        }
    })

    PredictionMode = AutoLasso:CreateDropdown({
        Name = 'Prediction',
        List = {'Off', 'On'},
        Default = 'On',
        Tooltip = 'Predict target movement for better accuracy',
        ItemTooltips = {
            Off = "Aims directly at the target's current position",
            On = 'Leads the shot based on target velocity for better hit rate',
        }
    })
end)

kitRun(function()
    local Beekeeper
    local Collect
    local LimitToItem
    local EquipNet
    local CollectRange
    local CollectDelay
    local Deposit
    local DepositRange
    local DepositDelay
    local BeeLimit
    local Legit
    local HiveESP
    local ShowAmount
    local ShowOwn
    local Background
    local Color = {}
    local Reference = {}
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui

    -- Settings are created after CreateModule returns, so they can still be nil while
    -- this file is executing - and the module can be switched on inside that window when
    -- the GUI restores a saved config.
    local function on(setting)
        return setting ~= nil and setting.Enabled
    end

    local function value(setting, fallback)
        return setting ~= nil and setting.Value or fallback
    end

    --[[
        A wild bee, as opposed to one already tamed.

        Both carry the 'bee' tag: the ones worth catching, and the swarm circling a hive
        somebody has already filled. The tamed ones are handed a BeeId of -1 while a
        catchable bee carries a real id from the server - which is also the id the pickup
        has to be sent with, so one read decides both whether to bother and what to send.
    ]]
    local function beeId(v)
        local id = v:GetAttribute('BeeId')
        return type(id) == 'number' and id > 0 and id or nil
    end

    --[[
        Bees and hives are parts, not models.

        Every one of these was reached for through PrimaryPart, which is nil on a part, so
        the distance check below it never ran once and nothing was ever collected. Written
        to take either shape now.
    ]]
    local function partOf(v)
        if v:IsA('BasePart') then return v end
        return v:FindFirstChildWhichIsA('BasePart', true)
    end

    local function heldIs(itemType)
        local tool = store.hand and store.hand.tool
        return tool ~= nil and tool.Name == itemType
    end

    local function hotbarSlot(itemType)
        for i, v in store.inventory.hotbar do
            if v.item and v.item.itemType == itemType then
                return i - 1
            end
        end
    end

    --[[
        The net is what the game's own hand controller insists on before it will send a
        pickup, so the server has every reason to throw one away that arrives without it.

        Both halves of the switch are needed, which is why doing only the second did
        nothing: selecting the hotbar slot is what the game itself does, and sending the
        equip is what tells the server. A kit item like the net sits in the hotbar, so
        looking for it in the carried items alone never found it either.
    ]]
    local function equipNet()
        if heldIs('bee_net') then return true end

        local net = getItem('bee_net')
        local slot = hotbarSlot('bee_net')
        if not net and not slot then return false end

        if slot then
            hotbarSwitch(slot)
        end
        if net and net.tool then
            switchItem(net.tool)
        end
        return true
    end

    local function ownHive(hive)
        return hive:GetAttribute('PlacedByUserId') == lplr.UserId
    end

    --[[
        The colour of the team a hive belongs to.

        The queue's own team list carries it, as a plain integer rather than a Color3, and
        is keyed by an id that arrives as a string - so the list is walked and compared as
        numbers rather than indexed directly. White when the team cannot be worked out,
        which reads as no answer rather than as a wrong one.
    ]]
    --[[
        Which team a hive belongs to.

        Read off the block itself first. A hive cannot be broken by its own team, and that
        is recorded on it as a Team<N>NoBreak attribute, so the block states its own side
        without anyone having to still be in the server. Whoever placed it is the fallback,
        for the case where the attribute is absent.
    ]]
    local function hiveTeam(hive)
        local found
        for name in hive:GetAttributes() do
            local id = tonumber(name:match('^Team(%d+)NoBreak$'))
            if id and (not found or id < found) then
                found = id
            end
        end
        if found then return found end

        local placer = playersService:GetPlayerByUserId(hive:GetAttribute('PlacedByUserId') or 0)
        return placer and placer:GetAttribute('Team')
    end

    --[[
        The colour of the team a hive belongs to.

        Taken from the owner's own TeamColor, which is what the rest of Vain colours by -
        so a hive reads the same as the nametags above the players who own it. The queue's
        team list was the wrong source: its ids and a player's team are not numbered from
        the same end, so a blue team came out orange.

        Anyone still in the server on that team will do when whoever placed it has left.
    ]]
    local function hiveColor(hive)
        local placer = playersService:GetPlayerByUserId(hive:GetAttribute('PlacedByUserId') or 0)
        if placer and tostring(placer.TeamColor) ~= 'White' then
            return placer.TeamColor.Color
        end

        local team = hiveTeam(hive)
        if team then
            for _, plr in playersService:GetPlayers() do
                if plr:GetAttribute('Team') == team and tostring(plr.TeamColor) ~= 'White' then
                    return plr.TeamColor.Color
                end
            end
        end

        return Color3.new(1, 1, 1)
    end

    --[[
        Catching, one bee at a time.

        The remote is named here rather than looked up in the scraped table. That table
        works out a remote's name by finding 'Client' among a function's constants and
        taking the next one, which for this call lands on 'Get' rather than on the name
        itself - so every pickup was addressed to a remote that does not exist.
    ]]
    local function collect()
        if not entitylib.isAlive then return end

        local root = entitylib.character.RootPart
        local range = value(CollectRange, 30)

        for _, v in collectionService:GetTagged('bee') do
            if not (Beekeeper.Enabled and on(Collect)) then return end

            local id = beeId(v)
            local part = id and partOf(v)
            if not part then continue end
            if (root.Position - part.Position).Magnitude > range then continue end

            --[[
                Two stages, in this order on purpose.

                Limit to Item asks what is in your hand right now, so it has to be read
                before Equip Net has a chance to put the net there - otherwise the equip
                satisfies the very check that was meant to hold it back, and the setting
                does nothing at all.
            ]]
            if on(LimitToItem) and not heldIs('bee_net') then return end
            if on(EquipNet) and not equipNet() then return end

            --[[
                Caught the way the game catches.

                Sending the remote by hand delivers the id and nothing else - no swing
                animation, no sound, and none of whatever else the controller does on the
                way. Calling the controller runs the same path your own swing would, which
                is both likelier to be accepted and indistinguishable from playing.

                The raw send stays as a fallback for when the controller cannot be reached.
            ]]
            local sent = bedwars.BeeNetController and pcall(function()
                bedwars.BeeNetController:trigger(lplr, v)
            end)
            if not sent then
                bedwars.Client:Get('PickUpBee'):SendToServer({beeId = id})
            end

            local delay = value(CollectDelay, 0.1)
            if delay > 0 then
                task.wait(delay)
            end
        end
    end

    --[[
        Handing a caught bee to the nearest of your own hives.

        The hive's prompt is only switched on by the game while a bee is actually in your
        hand, and only on hives you placed, so both of those are checked before reaching
        for it rather than firing into nothing.
    ]]
    local function deposit()
        if not entitylib.isAlive or not heldIs('bee') then return end

        local root = entitylib.character.RootPart
        local range = value(DepositRange, 12)
        local best, closest

        -- A hive's Level is how many bees it is holding, so the cap reads straight off
        -- it. At or above the limit it is passed over and a nearer-but-full hive cannot
        -- soak up bees meant for one with room.
        local limit = value(BeeLimit, 10)

        for _, hive in collectionService:GetTagged('beehive') do
            if not ownHive(hive) then continue end
            if (hive:GetAttribute('Level') or 0) >= limit then continue end

            local part = partOf(hive)
            if not part then continue end

            local distance = (root.Position - part.Position).Magnitude
            if distance <= range and (not closest or distance < closest) then
                best, closest = hive, distance
            end
        end
        if not best then return end

        local prompt = best:FindFirstChildOfClass('ProximityPrompt')
        if not prompt then return end

        --[[
            Legit holds the prompt for as long as the game asks, which is what a player
            doing this by hand produces. It starts the moment the hive is in range - there
            is nothing to wait for before reaching for a prompt that is already there.

            Otherwise the prompt is simply fired, which is instant.
        ]]
        if on(Legit) then
            prompt:InputHoldBegin()
            local hold = prompt.HoldDuration or 0
            if hold > 0 then
                task.wait(hold)
            end
            prompt:InputHoldEnd()
        elseif fireproximityprompt then
            fireproximityprompt(prompt)
        else
            prompt:InputHoldBegin()
            prompt:InputHoldEnd()
        end

        local delay = value(DepositDelay, 0.1)
        if delay > 0 then
            task.wait(delay)
        end
    end

    local function removeHive(hive)
        local entry = Reference[hive]
        if entry then
            Reference[hive] = nil
            entry.Billboard:Destroy()
        end
    end

    -- How many bees a hive is holding, shown on it. The level is the count, and it is the
    -- one thing here worth reading at a glance - a full hive takes nothing more.
    local function addHive(hive)
        if Reference[hive] then return end

        local own = ownHive(hive)
        if own and not on(ShowOwn) then return end

        local part = partOf(hive)
        if not part then return end

        local billboard = Instance.new('BillboardGui')
        billboard.Name = 'beehive'
        billboard.Adornee = part
        billboard.StudsOffsetWorldSpace = Vector3.new(0, math.clamp(part.Size.Y * 0.5, 0.5, 4), 0)
        billboard.Size = UDim2.fromOffset(64, 34)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Parent = Folder

        local blur = addBlur(billboard)
        blur.Visible = on(Background)

        local frame = Instance.new('Frame')
        frame.Size = UDim2.fromScale(1, 1)
        frame.BackgroundColor3 = Color3.fromHSV(Color.Hue or 0, Color.Sat or 0, Color.Value or 0)
        frame.BackgroundTransparency = 1 - (on(Background) and (Color.Opacity or 0.5) or 0)
        frame.BorderSizePixel = 0
        frame.Parent = billboard

        local corner = Instance.new('UICorner')
        corner.CornerRadius = UDim.new(0, 4)
        corner.Parent = frame

        --[[
            A fixed size rather than a scaled one.

            TextScaled sizes the text to fill the box, so a single digit was blown up to a
            different size than two and drawn well outside the plate - which is why a count
            under ten looked like it was not there at all.
        ]]
        local label = Instance.new('TextLabel')
        label.Name = 'Level'
        label.Size = UDim2.fromScale(1, 1)
        label.BackgroundTransparency = 1
        label.TextColor3 = hiveColor(hive)
        label.TextStrokeTransparency = 0.4
        label.TextSize = 20
        label.FontFace = uipallet.FontSemiBold
        label.RichText = true
        label.Parent = frame

        --[[
            Redrawn from whatever the hive says right now.

            Driven from the loop as well as from the level changing, because a hive that
            was already standing when the module came on never fires that signal and its
            count would sit at whatever it happened to be when the plate was first drawn.
        ]]
        local function refresh()
            local parts = {}

            if on(ShowAmount) then
                parts[#parts + 1] = tostring(hive:GetAttribute('Level') or 0)
            end
            if not own then
                local owner = playersService:GetPlayerByUserId(hive:GetAttribute('PlacedByUserId') or 0)
                parts[#parts + 1] = '<font size="10">' .. ((owner and owner.Name) or '?') .. '</font>'
            end

            label.Text = table.concat(parts, ' ')
            label.TextColor3 = hiveColor(hive)
            billboard.Enabled = #parts > 0
        end
        refresh()

        Reference[hive] = {Billboard = billboard, Frame = frame, Blur = blur, Refresh = refresh}
        Beekeeper:Clean(hive:GetAttributeChangedSignal('Level'):Connect(refresh))
    end

    Beekeeper = vain.Categories.Kit:CreateModule({
        Name = 'Beekeeper',
        Function = function(callback)
            if callback then
                if on(HiveESP) then
                    for _, hive in collectionService:GetTagged('beehive') do
                        addHive(hive)
                    end
                    Beekeeper:Clean(collectionService:GetInstanceAddedSignal('beehive'):Connect(addHive))
                    Beekeeper:Clean(collectionService:GetInstanceRemovedSignal('beehive'):Connect(removeHive))
                end

                -- One loop for both, so a slow deposit cannot leave bees uncollected and
                -- the two never fight over what is in your hand at the same moment.
                task.spawn(function()
                    while Beekeeper.Enabled do
                        if on(Collect) then
                            pcall(collect)
                        end
                        if on(Deposit) then
                            pcall(deposit)
                        end
                        for hive, entry in Reference do
                            if hive.Parent then
                                entry.Refresh()
                            else
                                removeHive(hive)
                            end
                        end
                        task.wait(0.1)
                    end
                end)
            else
                for hive in Reference do
                    removeHive(hive)
                end
                Folder:ClearAllChildren()
                table.clear(Reference)
            end
        end,
        Tooltip = 'Catches bees and feeds them to your hives'
    })
    Collect = Beekeeper:CreateToggle({
        Name = 'Auto Collect',
        Tooltip = 'Catches wild bees around you',
        Function = function(callback)
            if LimitToItem and LimitToItem.Object then LimitToItem.Object.Visible = callback end
            if EquipNet and EquipNet.Object then EquipNet.Object.Visible = callback end
            if CollectRange and CollectRange.Object then CollectRange.Object.Visible = callback end
            if CollectDelay and CollectDelay.Object then CollectDelay.Object.Visible = callback end
        end,
        Default = true
    })
    LimitToItem = Beekeeper:CreateToggle({
        Name = 'Limit to Item',
        Tooltip = 'Only catches while the net is already in your hand',
        Darker = true
    })
    EquipNet = Beekeeper:CreateToggle({
        Name = 'Equip Net',
        Tooltip = 'Switches to the bee net first, which the catch needs',
        Darker = true,
        Default = true
    })
    -- Ten is what the game allows: a bee's own pickup prompt is built with a
    -- MaxActivationDistance of 10, so a catch sent from further out has every chance of
    -- being turned down. The slider goes past it to leave room to try, but the default is
    -- the distance the game itself works at.
    CollectRange = Beekeeper:CreateSlider({
        Name = 'Range',
        Tooltip = 'How far a bee can be to catch it (default 10)',
        Min = 1,
        Max = 30,
        Default = 10,
        Suffix = 'studs',
        Darker = true
    })
    CollectDelay = Beekeeper:CreateSlider({
        Name = 'Delay',
        Tooltip = 'Wait between catches (default 0.1)',
        Min = 0,
        Max = 1,
        Default = 0.1,
        Decimal = 100,
        Suffix = 'sec',
        Darker = true
    })
    Deposit = Beekeeper:CreateToggle({
        Name = 'Auto Deposit',
        Tooltip = 'Feeds caught bees to your nearest hive',
        Function = function(callback)
            if DepositRange and DepositRange.Object then DepositRange.Object.Visible = callback end
            if DepositDelay and DepositDelay.Object then DepositDelay.Object.Visible = callback end
            if BeeLimit and BeeLimit.Object then BeeLimit.Object.Visible = callback end
            if Legit and Legit.Object then Legit.Object.Visible = callback end
        end,
        Default = true
    })
    DepositRange = Beekeeper:CreateSlider({
        Name = 'Deposit Range',
        Tooltip = 'How far a hive can be to feed it (default 12)',
        Min = 1,
        Max = 30,
        Default = 12,
        Suffix = 'studs',
        Darker = true
    })
    DepositDelay = Beekeeper:CreateSlider({
        Name = 'Deposit Delay',
        Tooltip = 'Wait between deposits (default 0.1)',
        Min = 0,
        Max = 2,
        Default = 0.1,
        Decimal = 100,
        Suffix = 'sec',
        Darker = true
    })
    Legit = Beekeeper:CreateToggle({
        Name = 'Legit',
        Tooltip = 'Holds the prompt the way the game intends',
        Darker = true
    })
    BeeLimit = Beekeeper:CreateSlider({
        Name = 'Bee Limit',
        Tooltip = 'Stops feeding a hive once it holds this many (default 10)',
        Min = 1,
        Max = 25,
        Default = 10,
        Suffix = 'bees',
        Darker = true
    })
    HiveESP = Beekeeper:CreateToggle({
        Name = 'Beehive ESP',
        Tooltip = 'Shows how many bees each hive is holding',
        Function = function(callback)
            if ShowAmount and ShowAmount.Object then ShowAmount.Object.Visible = callback end
            if ShowOwn and ShowOwn.Object then ShowOwn.Object.Visible = callback end
            if Background and Background.Object then Background.Object.Visible = callback end
            if Color and Color.Object then Color.Object.Visible = callback and Background.Enabled end
            if Beekeeper.Enabled then
                Beekeeper:Toggle()
                Beekeeper:Toggle()
            end
        end,
        Default = true
    })
    ShowAmount = Beekeeper:CreateToggle({
        Name = 'Show Amount',
        Tooltip = 'Shows how many bees the hive is holding',
        Darker = true,
        Default = true
    })
    ShowOwn = Beekeeper:CreateToggle({
        Name = 'Show Own',
        Tooltip = 'Includes hives you placed yourself',
        Default = true,
        Function = function()
            if Beekeeper.Enabled then
                Beekeeper:Toggle()
                Beekeeper:Toggle()
            end
        end,
        Darker = true
    })
    Background = Beekeeper:CreateToggle({
        Name = 'Background',
        Tooltip = 'Draws a background behind the count',
        Function = function(callback)
            if Color.Object then Color.Object.Visible = callback end
            for _, entry in Reference do
                entry.Frame.BackgroundTransparency = 1 - (callback and (Color.Opacity or 0.5) or 0)
                entry.Blur.Visible = callback
            end
        end,
        Darker = true,
        Default = true
    })
    Color = Beekeeper:CreateColorSlider({
        Name = 'Background Color',
        Tooltip = 'Color of the background',
        -- Left out on purpose: the slider reads this as `DefaultValue or 1`, and zero is
        -- truthy in Lua, so passing 0 pinned the brightness at zero and the background
        -- came out black whatever colour was picked.
        DefaultOpacity = 0.5,
        Function = function(hue, sat, val, opacity)
            for _, entry in Reference do
                entry.Frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                entry.Frame.BackgroundTransparency = 1 - opacity
            end
        end,
        Darker = true
    })
end)

kitRun(function()
    local AutoBuilder
    local Animation
    local Blacklist
    local BedCheck
    local Limit

    local function getBedNear(pos)
    	local bed, lastmag = nil, math.huge
    	local localPosition = pos or Vector3.zero
    	for _, v in collectionService:GetTagged('bed') do
    		local mag = (localPosition - v.Position).Magnitude
    		if mag < lastmag and v:GetAttribute('Team' .. (lplr:GetAttribute('Team') or -1) .. 'NoBreak') then
    			bed = v
    			lastmag = mag
    		end
    	end
    	return bed, lastmag
    end

    AutoBuilder = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Builder',
    	Tooltip = 'Automatically builds a preset structure',
    	Function = function(callback)
    		if callback then
    			repeat
    				task.wait()
    			until store.matchState ~= 0 and store.equippedKit == 'builder' or not AutoBuilder.Enabled
    			if not AutoBuilder.Enabled then
    				return
    			end

    			local bed = getBedNear(entitylib.character.RootPart.Position)
    			local blocks = collection('block', AutoBuilder, function(tab, obj)
    				task.delay(0, function()
    					if obj and not obj:GetAttribute('NoBreak') and obj:GetAttribute('PlacedByUserId') ~= nil then
    						table.insert(tab, obj)
    					end
    				end)
    			end)
    			repeat
    				if entitylib.isAlive and (not Limit.Enabled and getItem('hammer') or Limit.Enabled and store.hand.tool and store.hand.tool.Name == 'hammer') then
    					bed = getBedNear(entitylib.character.RootPart.Position)

    					for _, v in blocks do
    						if not BedCheck.Enabled or (bed.Position - v.Position).Magnitude <= 30 then
    							local name = v.Name
    							if name:find('wool_') then
    								name = 'wool'
    							end
    							if not table.find(Blacklist.ListEnabled, name) and not v:FindFirstChild('BuilderFortify') then
    								bedwars.Client:Get('FortifyBlock'):SendToServer(({getPlacedBlock(v.Position)})[2])
    								if Animation.Enabled then
    									bedwars.GameAnimationUtil:playAnimation(lplr, bedwars.GameAnimationUtil:getAssetId(bedwars.AnimationType.BUILDER_HAMMER_HIT), {
    										fadeInTime = 0.02
    									})
                						bedwars.SoundManager:playSound(bedwars.SoundList.FORTIFY_BLOCK,lplr.Character.HumanoidRootPart.Position)
    								end
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoBuilder.Enabled
    		end
    	end
    })

    BedCheck = AutoBuilder:CreateToggle({
    	Name = 'Bed Check',
    	Tooltip = 'Checks if the block is near your bed'
    })
    Animation = AutoBuilder:CreateToggle({
    	Name = 'Animation',
    	Default = true,
    	Tooltip = 'Plays builder visuals (sfx and anim)'
    })
    Limit = AutoBuilder:CreateToggle({
    	Name = 'Limit to items',
    	Tooltip = 'Only activates when a required item is in your hand',
    	Default = true
    })
    Blacklist = AutoBuilder:CreateTextList({
    	Name = 'Blacklists',
    	Tooltip = 'Block types to skip when auto-building (one per line)',
    	Placeholder = 'block',
    	Default = {'cannon', 'wool'}
    })
end)

kitRun(function()
    local Caitlyn
    local MethodDropdown
    local LowHealthSlider
    local ExecuteRangeSlider
    local HitRangeSlider
    local ProximityRangeSlider
    local connections = {}
    local Players = playersService
    local lplr = Players.LocalPlayer
    local currentTarget = nil
    local lastHitTime = 0
    local lastContractSelect = 0

    local ContractESP, ContractColor, LegendaryColor, ContractWalls
    local ShowReward, HoverOnly, RightClickSelect
    local contractFolder = Instance.new('Folder')
    contractFolder.Parent = vain.gui
    local contractMarks, contractScan = {}, 0

    --[[
        Which upgrades are the good ones, asked two ways.

        Reading it from the game is the better answer: BloodUpgradeMeta gives every
        upgrade either a perk field or a baseValue, and that split is the distinction
        without anything hardcoded. It is resolved on use rather than added to the bedwars
        table, since that table is built in one constructor and a bad path there takes
        every bedwars module with it.

        A failure is retried rather than remembered. Caching the miss meant one unlucky
        first call - asked before the module had replicated, most likely - turned the
        colour off for the rest of the session with nothing to show for it.

        And if it stays unreachable there is still an answer: BloodUpgrade is a plain
        numbered enum, so the seven perks worth crossing the map for have fixed ids. That
        is the thing that would need revisiting if the game renumbers them, which is why
        it is the fallback rather than the answer.
    ]]
    local bloodMeta, bloodMetaTried = nil, 0

    local function upgradeMeta()
        if bloodMeta then return bloodMeta end
        if os.clock() - bloodMetaTried < 5 then return nil end
        bloodMetaTried = os.clock()

        local ok, meta = pcall(function()
            return require(replicatedStorage.TS.games.bedwars.kit.kits['blood-assassin']['blood-upgrade-meta']).BloodUpgradeMeta
        end)
        bloodMeta = (ok and type(meta) == 'table') and meta or nil
        return bloodMeta
    end

    -- ASSASSIN_INSTINCT, SERRATED_BLADE, THRILL_OF_THE_HUNT, DARK_INSIGHT, SILENCE,
    -- BOUNTY, VULNERABLE. Not ABSOLUTION (12), and not the four stat gains (1 to 4).
    local PERK_IDS = {[5] = true, [6] = true, [7] = true, [8] = true, [9] = true, [10] = true, [11] = true}

    -- The same enum written out, so a label still has something to say when the meta
    -- module cannot be reached and its display strings are unavailable.
    local UPGRADE_NAMES = {
        [1] = 'Damage', [2] = 'Armor Penetration', [3] = 'Duration', [4] = 'Target Damage',
        [5] = "Assassin's Instinct", [6] = 'Serrated Blade', [7] = 'Thrill of the Hunt',
        [8] = 'Dark Insight', [9] = 'Silence', [10] = 'Bounty', [11] = 'Vulnerable',
        [12] = 'Absolution'
    }

    --[[
        What the contract pays, in as few words as it takes.

        The meta also carries a description, and it is a whole sentence - "Decay deals
        double damage to your active target". Three of those hanging over the map is
        something to read rather than something to glance at, so the name is used
        instead, which is what you are actually choosing between.

        A stat gain is the exception: its name alone says nothing, since every contract
        offering Damage offers a different amount of it. summarize gives that amount in
        the shape the game writes it, so it comes out as "Damage 3" or "Armor Penetration
        15%". Perks have no amount and need none.
    ]]
    local function rewardText(contract)
        local upgrade = contract.rewardUpgrade
        if upgrade == nil then return nil end

        local all = upgradeMeta()
        local meta = all and all[upgrade]
        local name = (meta and meta.display) or UPGRADE_NAMES[upgrade]
        if not name then return nil end

        if meta and type(meta.summarize) == 'function' and contract.rewardValue then
            local ok, amount = pcall(meta.summarize, contract.rewardValue)
            if ok and amount ~= nil and tostring(amount) ~= '' then
                return name .. ' ' .. tostring(amount)
            end
        end
        return name
    end

    --[[
        Whoever is under the pointer, however the pointer is being held.

        Mouse.Target answers this while the cursor is free, and answers nothing at all in
        first person or shift lock, where there is no cursor to be under anything. Then
        the middle of the screen is where you are pointing, so that is what gets asked.

        Either way it walks up from whatever was actually hit: the thing in front of a
        player is usually their helmet or chestplate, not a body part.
    ]]
    --[[
        Whoever the pointer is on, decided by angle rather than by what it hit.

        Asking what part is under the cursor and walking up to its owner is the obvious
        way and it kept coming back with nothing: what is in front of a player is their
        armour, a held item, a hitbox, or a part the game has marked unqueryable, and only
        some of those lead back to the character.

        So nobody is asked what was hit. A ray is taken through the pointer and every
        player is measured against it by angle, nearest to the line winning - which is the
        same question you were answering by eye when you pointed at them, and does not
        care what happens to be in the way.
    ]]
    local POINT_TOLERANCE = math.rad(14)

    local function playerUnderMouse()
        local camera = workspace.CurrentCamera
        if not camera then return nil end

        local ok, ray = pcall(function()
            local mouse = lplr:GetMouse()
            -- No cursor in first person or shift lock, so the middle of the screen is
            -- where you are pointing.
            local x, y = mouse.X, mouse.Y
            if x == 0 and y == 0 then
                local centre = camera.ViewportSize / 2
                x, y = centre.X, centre.Y
            end
            return camera:ViewportPointToRay(x, y)
        end)
        if not (ok and ray) then return nil end

        local best, bestAngle
        for _, plr in playersService:GetPlayers() do
            if plr ~= lplr and plr.Character then
                local part = plr.Character:FindFirstChild('UpperTorso')
                    or plr.Character:FindFirstChild('HumanoidRootPart')
                if part then
                    local offset = part.Position - ray.Origin
                    if offset.Magnitude > 0.1 then
                        local angle = math.acos(math.clamp(ray.Direction.Unit:Dot(offset.Unit), -1, 1))
                        if angle <= POINT_TOLERANCE and (not bestAngle or angle < bestAngle) then
                            best, bestAngle = plr, angle
                        end
                    end
                end
            end
        end
        return best
    end

    local function clearContracts()
        for plr, entry in contractMarks do
            if entry.mark then entry.mark:Destroy() end
            if entry.tag then entry.tag:Destroy() end
            contractMarks[plr] = nil
        end
    end

    --[[
        Whoever the contracts are on, marked the moment they arrive.

        The client is handed these outright rather than having to work them out:
        BloodAssassinUpdateAvailableContracts drops them into the store under
        Kit.availableContracts, three at a time, each carrying the Player it names. The one
        you accept moves to Kit.activeContract and is marked too, since it is still the
        person to go and find.

        One colour, because there is nothing to vary it by. A contract carries its target,
        the upgrade it rewards and an explanation of that reward - no rarity and no tier
        anywhere on it, and the game's own card colours these by the target's team.
    ]]
    -- Settings are created after CreateModule returns, so a config that switches this on
    -- while they are still nil would otherwise throw once per pass for that window.
    local function on(setting)
        return setting ~= nil and setting.Enabled
    end

    -- The colour a slider is set to, or the one it will default to when it exists. These
    -- are created after CreateModule returns, so for a moment they are not there at all.
    local function sliderColour(slider, hue)
        if not slider then return Color3.fromHSV(hue, 1, 1) end
        return Color3.fromHSV(slider.Hue or hue, slider.Sat or 1, slider.Value or 1)
    end

    local function refreshContracts()
        if not on(ContractESP) then
            if next(contractMarks) then clearContracts() end
            return
        end

        -- Contracts arrive a few times a match, so this does not need the rate the rest
        -- of the loop runs at.
        if os.clock() - contractScan < 0.25 then return end
        contractScan = os.clock()

        local ok, state = pcall(function() return bedwars.Store:getState() end)
        if not (ok and state and state.Kit) then return end

        --[[
            Which contracts are worth crossing the map for.

            The reward tells you, and the game's own data splits them cleanly. A contract
            rewards a BloodUpgrade, and BloodUpgradeMeta holds two shapes: the four plain
            stat gains carry baseValue and maxValue, while the eight perks carry a perk
            field instead. That is a structural difference rather than a list of names, so
            it keeps working when the game adds another one.

            Absolution is the exception you asked for. It is the only perk that hands you
            an item rather than changing how decay behaves, and it is the only one
            carrying itemType - so it is told apart without hardcoding what it is called.
        ]]
        local function isLegendary(contract)
            local upgrade = contract.rewardUpgrade
            if upgrade == nil then return false end

            local all = upgradeMeta()
            local meta = all and all[upgrade]
            if meta then
                return meta.perk ~= nil and meta.itemType == nil
            end
            return PERK_IDS[upgrade] == true
        end

        local wanted = {}
        for _, contract in state.Kit.availableContracts or {} do
            if contract.target then
                wanted[contract.target] = {
                    legendary = isLegendary(contract),
                    reward = rewardText(contract)
                }
            end
        end
        local active = state.Kit.activeContract
        if active and active.target then
            wanted[active.target] = {
                legendary = isLegendary(active),
                reward = rewardText(active)
            }
        end

        --[[
            Dropped as soon as the contract is.

            Compared against nil rather than truth: the table holds whether each target is
            a legendary, so an ordinary contract sits in it as false, and testing for
            truth threw those marks away and rebuilt them on every pass.

            Anything no longer in the store has had its contract taken off the board -
            accepting one clears the other two - so the highlight goes with it.
        ]]
        for plr, entry in contractMarks do
            if wanted[plr] == nil or not plr.Parent or not plr.Character then
                if entry.mark then entry.mark:Destroy() end
                if entry.tag then entry.tag:Destroy() end
                contractMarks[plr] = nil
            end
        end

        local plain = sliderColour(ContractColor, 0.95)
        local rare = sliderColour(LegendaryColor, 0.14)

        local hovered = on(HoverOnly) and playerUnderMouse() or nil

        for plr, info in wanted do
            local char = plr.Character
            local head = char and (char:FindFirstChild('Head') or char:FindFirstChild('HumanoidRootPart'))
            if char then
                local entry = contractMarks[plr]
                if not entry then
                    entry = {}
                    contractMarks[plr] = entry
                end

                if not entry.mark then
                    entry.mark = Instance.new('Highlight')
                    entry.mark.Parent = contractFolder
                end

                local colour = info.legendary and rare or plain
                local slider = info.legendary and LegendaryColor or ContractColor
                entry.mark.Adornee = char
                entry.mark.DepthMode = Enum.HighlightDepthMode[ContractWalls.Enabled and 'AlwaysOnTop' or 'Occluded']
                entry.mark.FillColor = colour
                entry.mark.OutlineColor = colour
                entry.mark.FillTransparency = 1 - ((slider and slider.Opacity) or 0.5)

                -- What you get for taking it, written above them. On Hover Only keeps the
                -- three of them from covering the screen while you decide.
                local show = on(ShowReward) and info.reward and head
                    and (not on(HoverOnly) or hovered == plr)

                if show then
                    if not entry.tag then
                        local tag = Instance.new('BillboardGui')
                        tag.Size = UDim2.fromOffset(220, 26)
                        tag.StudsOffsetWorldSpace = Vector3.new(0, 3.2, 0)
                        tag.AlwaysOnTop = true
                        tag.MaxDistance = 500
                        tag.Parent = contractFolder

                        local label = Instance.new('TextLabel')
                        label.Name = 'Reward'
                        label.Size = UDim2.fromScale(1, 1)
                        label.BackgroundTransparency = 1
                        label.Font = Enum.Font.GothamBold
                        label.TextSize = 15
                        -- Solid rather than nearly: the outline is the only thing holding
                        -- the text apart from whatever colour of map is behind it.
                        label.TextStrokeTransparency = 0
                        label.TextStrokeColor3 = Color3.new()
                        label.Parent = tag

                        entry.tag = tag
                    end
                    entry.tag.Adornee = head
                    entry.tag.Enabled = true
                    local readable = Color3.fromHSV((slider and slider.Hue) or 0, ((slider and slider.Sat) or 1) * 0.45, 1)

                    local label = entry.tag:FindFirstChild('Reward')
                    if label then
                        label.Text = info.reward
                        --[[
                            Bright enough to read, still the colour it belongs to.

                            Taking the highlight's colour straight meant a fully saturated
                            red on a bright map, which is about the least legible thing
                            text can be. The hue is kept so a legendary still reads as a
                            different one at a glance, but it is lightened and taken to
                            full brightness first - a highlight is a wash over a body and
                            can be as deep as it likes, a word has to be read.
                        ]]
                        label.TextColor3 = readable
                    end
                elseif entry.tag then
                    entry.tag.Enabled = false
                end
            end
        end
    end
    
    local function selectContract(targetPlayer)
        if not entitylib.isAlive then return false end
        if tick() - lastContractSelect < 0.1 then return false end
        
        local storeState = bedwars.Store:getState()
        local activeContract = storeState.Kit.activeContract
        local availableContracts = storeState.Kit.availableContracts or {}
        
        if activeContract then return false end
        if #availableContracts == 0 then return false end
        
        for _, contract in pairs(availableContracts) do
            if contract.target and contract.target.Name == targetPlayer.Name then
                bedwars.Client:Get('BloodAssassinSelectContract'):SendToServer({
                    contractId = contract.id
                })
                lastContractSelect = tick()
                return true
            end
        end
        return false
    end
    
    local function executeOnLowHealth()
        if not currentTarget or tick() - lastHitTime > 3 then
            currentTarget = nil
            return
        end
        
        if not currentTarget.Character then return end
        
        local humanoid = currentTarget.Character:FindFirstChild("Humanoid")
        local rootPart = currentTarget.Character:FindFirstChild("HumanoidRootPart")
        
        if humanoid and rootPart and lplr.Character and lplr.Character:FindFirstChild("HumanoidRootPart") then
            local health = humanoid.Health
            local distance = (lplr.Character.HumanoidRootPart.Position - rootPart.Position).Magnitude
            
            if health > 0 and health <= LowHealthSlider.Value and distance <= ExecuteRangeSlider.Value then
                selectContract(currentTarget)
            end
        end
    end
    
    local function contractOnHit()
        if not currentTarget or tick() - lastHitTime > 0.5 then
            currentTarget = nil
            return
        end
        
        if not currentTarget.Character then return end
        
        local rootPart = currentTarget.Character:FindFirstChild("HumanoidRootPart")
        
        if rootPart and lplr.Character and lplr.Character:FindFirstChild("HumanoidRootPart") then
            local distance = (lplr.Character.HumanoidRootPart.Position - rootPart.Position).Magnitude
            
            if distance <= HitRangeSlider.Value then
                selectContract(currentTarget)
            end
        end
    end
    
    local function proximityContract()
        if not entitylib.isAlive then return end
        
        local myRoot = lplr.Character and lplr.Character:FindFirstChild("HumanoidRootPart")
        if not myRoot then return end
        
        local closestPlayer = nil
        local closestDistance = ProximityRangeSlider.Value
        
        for _, player in pairs(Players:GetPlayers()) do
            if player ~= lplr and player.Character then
                local theirRoot = player.Character:FindFirstChild("HumanoidRootPart")
                local humanoid = player.Character:FindFirstChild("Humanoid")
                
                if theirRoot and humanoid and humanoid.Health > 0 then
                    local distance = (myRoot.Position - theirRoot.Position).Magnitude
                    
                    if distance < closestDistance then
                        closestDistance = distance
                        closestPlayer = player
                    end
                end
            end
        end
        
        if closestPlayer then
            selectContract(closestPlayer)
        end
    end
    
    Caitlyn = vain.Categories.Kit:CreateModule({
        Name = 'Caitlyn',
        Function = function(callback)
            if callback then
                --[[
                    Right click takes the contract on whoever is under the cursor.

                    The cursor lands on whatever part happens to be in front - a helmet, a
                    chestplate, an accessory - so the player is found by walking up from
                    it rather than by expecting to hit a body part.

                    Only players that actually hold one of your contracts do anything:
                    selectContract looks the target up in the available list and returns
                    false when it is not there, so right clicking anyone else is ignored.
                ]]
                --[[
                    Listened for two ways, because either can be the one that arrives.

                    Right click is what turns the camera, so InputBegan reports it already
                    marked as handled and a gameProcessed check throws it away - which is
                    what was happening. Mouse.Button2Down is not filtered that way, but it
                    depends on GetMouse, which some executors replace.

                    Both are taken and neither is trusted alone. selectContract already
                    refuses a second call inside a tenth of a second, so hearing the same
                    click twice costs nothing.
                ]]
                local function pointedSelect()
                    if not on(RightClickSelect) then return end
                    local plr = playerUnderMouse()
                    if plr and plr ~= lplr then
                        pcall(selectContract, plr)
                    end
                end

                pcall(function()
                    table.insert(connections, lplr:GetMouse().Button2Down:Connect(pointedSelect))
                end)

                table.insert(connections, inputService.InputBegan:Connect(function(input)
                    if input.UserInputType == Enum.UserInputType.MouseButton2 then
                        pointedSelect()
                    end
                end))

                --[[
                    Watched as well as listened for.

                    Both events above can be taken away before they reach us - right click
                    is bound by the camera and by the game's own action handlers, and
                    whether either fires depends on what else has claimed the button. A
                    poll cannot be intercepted: it asks the button directly, and only acts
                    on the frame it goes down so holding it to turn the camera does
                    nothing.
                ]]
                task.spawn(function()
                    local held = false
                    repeat
                        local down = false
                        pcall(function()
                            down = inputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
                        end)
                        if down and not held then
                            pointedSelect()
                        end
                        held = down
                        task.wait()
                    until not Caitlyn.Enabled
                end)

                local damageConnection = vainEvents.EntityDamageEvent.Event:Connect(function(damageTable)
                    if not entitylib.isAlive then return end
                    
                    local attacker = playersService:GetPlayerFromCharacter(damageTable.fromEntity)
                    local victim = playersService:GetPlayerFromCharacter(damageTable.entityInstance)
                
                    if attacker == lplr and victim and victim ~= lplr then
                        currentTarget = victim
                        lastHitTime = tick()
                    end
                end)
                table.insert(connections, damageConnection)
                
                task.spawn(function()
                    repeat
                        --[[
                            Guarded, because this loop is not only the highlight.

                            refreshContracts reads the store and builds instances, and it
                            was called bare - so one error in it killed the loop it runs
                            in, which is the same loop that picks contracts, and the module
                            stopped dead mid-match. A bad pass costs that pass now and
                            nothing else; the next one runs as normal.
                        ]]
                        pcall(refreshContracts)

                        if entitylib.isAlive then
                            local method = MethodDropdown.Value
                            
                            if method == "Execute on Low HP" then
                                executeOnLowHealth()
                            elseif method == "Contract on Hit" then
                                contractOnHit()
                            elseif method == "Proximity Select" then
                                proximityContract()
                            end
                        end
                        task.wait(0.1)
                    until not Caitlyn.Enabled
                end)
            else
                for _, conn in pairs(connections) do
                    if typeof(conn) == "RBXScriptConnection" then
                        conn:Disconnect()
                    end
                end
                table.clear(connections)
                clearContracts()

                currentTarget = nil
                lastHitTime = 0
            end
        end,
        Tooltip = 'Auto contract selection for Caitlyn'
    })
    
    MethodDropdown = Caitlyn:CreateDropdown({
        Name = 'Method',
        List = {"Execute on Low HP", "Contract on Hit", "Proximity Select"},
        Default = "Execute on Low HP",
        Tooltip = 'Contract selection method',
        Function = function(value)
            LowHealthSlider.Object.Visible = (value == "Execute on Low HP")
            ExecuteRangeSlider.Object.Visible = (value == "Execute on Low HP")
            HitRangeSlider.Object.Visible = (value == "Contract on Hit")
            ProximityRangeSlider.Object.Visible = (value == "Proximity Select")
        end
    })
    
    LowHealthSlider = Caitlyn:CreateSlider({
        Name = 'Select HP',
        Min = 10,
        Max = 100,
        Default = 30,
        Tooltip = 'HP value to execute contract'
    })
    
    ExecuteRangeSlider = Caitlyn:CreateSlider({
        Name = 'Select Range',
        Min = 5,
        Max = 50,
        Default = 20,
        Suffix = ' studs',
        Tooltip = 'Range to select contract'
    })
    
    HitRangeSlider = Caitlyn:CreateSlider({
        Name = 'Hit Range',
        Min = 10,
        Max = 200,
        Default = 100,
        Suffix = ' studs',
        Tooltip = 'Max range to select a contract when hitting the player'
    })
    
    ProximityRangeSlider = Caitlyn:CreateSlider({
        Name = 'Proximity Range',
        Min = 10,
        Max = 200,
        Default = 50,
        Suffix = ' studs',
        Tooltip = 'Range to auto select nearby players'
    })
    
    ContractESP = Caitlyn:CreateToggle({
        Name = 'Contract ESP',
        Tooltip = 'Highlights whoever your contracts are on',
        Function = function(callback)
            for _, setting in {ContractColor, LegendaryColor, ContractWalls, ShowReward, RightClickSelect} do
                if setting and setting.Object then setting.Object.Visible = callback end
            end
            if HoverOnly and HoverOnly.Object then
                HoverOnly.Object.Visible = callback and on(ShowReward)
            end
            if not callback then clearContracts() end
        end
    })
    ContractColor = Caitlyn:CreateColorSlider({
        Name = 'Contract Color',
        Tooltip = 'Colour of the highlight',
        DefaultHue = 0.95,
        DefaultOpacity = 0.5,
        Visible = false,
        Darker = true
    })
    LegendaryColor = Caitlyn:CreateColorSlider({
        Name = 'Legendary Color',
        Tooltip = 'Colour for contracts rewarding a perk rather than a stat',
        DefaultHue = 0.14,
        DefaultOpacity = 0.5,
        Visible = false,
        Darker = true
    })
    ShowReward = Caitlyn:CreateToggle({
        Name = 'Show Reward',
        Default = true,
        Tooltip = 'Writes what the contract pays out above the target',
        Visible = false,
        Darker = true,
        Function = function(callback)
            if HoverOnly and HoverOnly.Object then
                HoverOnly.Object.Visible = callback and on(ContractESP)
            end
        end
    })
    HoverOnly = Caitlyn:CreateToggle({
        Name = 'On Hover Only',
        Default = false,
        Tooltip = 'Only writes it while you are looking at that target',
        Visible = false,
        Darker = true
    })
    RightClickSelect = Caitlyn:CreateToggle({
        Name = 'Right Click Select',
        Default = false,
        Tooltip = 'Right click a target, or their armour, to take that contract',
        Visible = false,
        Darker = true
    })
    ContractWalls = Caitlyn:CreateToggle({
        Name = 'Through Walls',
        Default = true,
        Tooltip = 'Shows the highlight through the map',
        Visible = false,
        Darker = true
    })

    LowHealthSlider.Object.Visible = true
    ExecuteRangeSlider.Object.Visible = true
    HitRangeSlider.Object.Visible = false
    ProximityRangeSlider.Object.Visible = false
end)

kitRun(function()
    --[[
    	The landing half of the Davey kit: what happens once you are already in the air.

    	Aiming lives in Davey Aim, separately, because the two are wanted at different times
    	- this one is worth leaving on all match whether the shot was aimed by hand or not,
    	and it hooks the launch itself so it does not care which.
    ]]
    local PirateDavey
    local Break, Jump, Switch, Limit, IncludeWood

    local old

    local function on(setting)
    	return setting ~= nil and setting.Enabled
    end

    local function holdingPickaxe()
    	local tool = store.hand and store.hand.tool
    	if tool == nil or tool.Name == nil or not tool.Name:find('pickaxe') then
    		return false
    	end
    	if tool.Name == 'wood_pickaxe' then
    		return on(IncludeWood)
    	end
    	return true
    end

    --[[
    	The breaking tool, taken out before the shot rather than during the landing.

    	Swapping at the moment the block breaks is the tell: a player reaches for the
    	pickaxe while they are still stood at the cannon, not in the half second between
    	touching down and swinging. Doing it here means the tool is already in hand for the
    	whole flight, which is what it looks like when somebody means to do this.

    	The swap itself is the ordinary one - pick the hotbar slot, then send the equip -
    	rather than the break loop's hurried version that dispatches and moves on.
    ]]
    local function equipBreakTool(block)
    	local meta = bedwars.ItemMeta[block.Name]
    	local breakType = meta and meta.block and meta.block.breakType
    	local tool = breakType and store.tools[breakType]
    	if not tool then return end

    	for i, v in store.inventory.hotbar do
    		if v.item and v.item.itemType == tool.itemType then
    			hotbarSwitch(i - 1)
    			break
    		end
    	end
    	if tool.tool then
    		switchItem(tool.tool)
    	end
    end

    --[[
    	Reaching for the pickaxe when you reach for the cannon.

    	Hooking the launch was still too late: by then you are already in the air, and the
    	swap happens during the flight rather than before it. The moment a player actually
    	decides to do this is when they start holding the cannon's prompt, so that is what
    	is listened for.

    	Both the hold starting and the plain trigger are taken, because a prompt with no
    	hold duration never fires the first of those - and the cannon has one of each.
    ]]
    local hooked = setmetatable({}, {__mode = 'k'})

    local function watchCannon(block)
    	if block.Name ~= 'cannon' or hooked[block] then return end
    	hooked[block] = true

    	local function reach()
    		if on(Switch) and on(Break) then
    			pcall(equipBreakTool, block)
    		end
    	end

    	local function hook(prompt)
    		if not prompt:IsA('ProximityPrompt') then return end
    		PirateDavey:Clean(prompt.PromptButtonHoldBegan:Connect(reach))
    		PirateDavey:Clean(prompt.Triggered:Connect(reach))
    	end

    	for _, child in block:GetDescendants() do
    		hook(child)
    	end

    	--[[
    		The prompts are not always there when the block is.

    		A cannon is tagged as it is placed and its prompts are parented in afterwards, so
    		looking once at the moment it appears finds nothing and hooks nothing - which is
    		why the swap kept falling through to the launch instead. Watching for them to
    		arrive catches the ones that were not there yet.
    	]]
    	PirateDavey:Clean(block.DescendantAdded:Connect(hook))
    end

    PirateDavey = vain.Categories.Kit:CreateModule({
    	Name = 'PirateDavey',
    	Tooltip = 'Breaks the block you land on and jumps as you touch down',
    	Function = function(call)
    		if call then
    			for _, block in collectionService:GetTagged('block') do
    				watchCannon(block)
    			end
    			PirateDavey:Clean(collectionService:GetInstanceAddedSignal('block'):Connect(watchCannon))

    			old = bedwars.CannonHandController.launchSelf
    			bedwars.CannonHandController.launchSelf = function(...)
    				local block = select(2, ...)

    				-- A backstop for a launch that never touched a prompt, such as the fast
    				-- aim mode calling the controller directly. Equipping something already
    				-- in hand costs nothing, so this is harmless when the prompt got there
    				-- first.
    				if on(Switch) and on(Break) and block then
    					pcall(equipBreakTool, block)
    				end

    				local res = { old(...) }

    				-- Guarded because a launch can end with you dead, and reaching for a
    				-- root part that is no longer there took the whole hook down with it.
    				pcall(function()
    					if on(Break) and (not on(Limit) or holdingPickaxe()) and entitylib.isAlive then
    						if (block.Position - entitylib.character.RootPart.Position).Magnitude <= 30 then
    							task.delay(0.05, function()
    								for _ = 1, 2 do
    									-- false: the tool was taken out before the launch, and
    									-- letting the break swap again undoes that.
    									task.spawn(bedwars.breakBlock, block, false, nil, true, false)
    								end
    							end)
    						end
    					end

    					if on(Jump) and entitylib.isAlive then
    						entitylib.character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
    					end
    				end)

    				return unpack(res)
    			end
    		elseif old then
    			bedwars.CannonHandController.launchSelf = old
    		end
    	end
    })
    Break = PirateDavey:CreateToggle({
    	Name = 'Break on impact',
    	Tooltip = 'Breaks the block you land on'
    })
    Jump = PirateDavey:CreateToggle({
    	Name = 'Jump on impact',
    	Tooltip = 'Jumps as you land'
    })
    Switch = PirateDavey:CreateToggle({
    	Name = 'Legit switch',
    	Tooltip = 'Takes the breaking tool out at the cannon, before launching, instead of swapping mid-landing',
    	Darker = true
    })
    Limit = PirateDavey:CreateToggle({
    	Name = 'Limit to Item',
    	Tooltip = 'Only breaks while a pickaxe is held',
    	Darker = true
    })
    IncludeWood = PirateDavey:CreateToggle({
    	Name = 'Include Wood Pickaxe',
    	Tooltip = 'Counts the wood pickaxe for Limit to Item',
    	Darker = true
    })
end)

kitRun(function()
    --[[
    	Davey Aim: a cannon shot that lands you where you point.

    	The cannon launches you with an impulse of its LookVector times your mass times 200 -
    	you leave at 200 studs a second along the way it faces and fall at the world's
    	gravity from there. Pointing it straight at a target, as this used to, ignores that
    	fall and lands you short every time. So the launch angle is solved instead: for a
    	fixed speed and gravity there are two arcs onto any reachable point, a low one and a
    	high one, and both are worked out exactly.

    	The low arc is quicker and less exposed, the high one gets over walls; Auto takes the
    	low one unless something is in the way of it. And because where you are standing
    	the moment you leave is what the shot starts from, it is solved once more at launch,
    	from exactly there - so it lands on point rather than a few studs off.
    ]]
    local DaveyAim
    local Activation, AimAt, Arc, AimMode, Launch, SearchRange, Delay, AvoidPowdered, OutOfRangeNotify
    local LAUNCH_SPEED = 200
    local pendingTarget, pendingCannon
    local launchHook, launchOriginal
    local lastRangeNotice = 0

    --[[
    	Powdered is the kit's own leash: "Firing yourself from a cannon will inflict
    	damage". Each launch adds a stack, a stack is twenty damage up to sixty, and the
    	whole thing lapses seven seconds after the last one. It is charged server side, so
    	the only answer is not to feed it: wait for the stacks to lapse before launching.
    ]]
    local function powderedStacks()
    	local char = lplr.Character
    	if not char then return 0 end
    	if char:GetAttribute('StatusEffect_powdered') == nil then return 0 end
    	return tonumber(char:GetAttribute('StatusEffect_powdered_stacks')) or 1
    end

    local rayCheck = RaycastParams.new()
    rayCheck.RespectCanCollide = true
    local pathCheck = RaycastParams.new()
    pathCheck.FilterType = Enum.RaycastFilterType.Exclude
    pathCheck.RespectCanCollide = true

    local function on(setting)
    	return setting ~= nil and setting.Enabled
    end

    -- The nearest cannon within reach.
    local function nearestCannon()
    	if not entitylib.isAlive then return end

    	local origin = entitylib.character.RootPart.Position
    	local best, bestDist
    	for _, v in collectionService:GetTagged('block') do
    		if v.Name == 'cannon' then
    			local mag = (origin - v.Position).Magnitude
    			if mag <= SearchRange.Value and (not bestDist or mag < bestDist) then
    				best, bestDist = v, mag
    			end
    		end
    	end
    	return best
    end

    -- Your root's height above your feet, so a surface you point at is where your feet
    -- come down rather than where your middle does.
    local function rootHeight()
    	local height = entitylib.isAlive and entitylib.character.HipHeight
    	return type(height) == 'number' and height > 0 and height or 3
    end

    --[[
    	Where to land. A surface under the cursor or camera is raised to where your root will
    	be standing on it; an enemy is aimed at root to root.
    ]]
    local function aimPoint()
    	local choice = AimAt and AimAt.Value or 'Mouse'

    	if choice == 'Nearest Enemy' then
    		local ent = entitylib.EntityPosition({
    			Range = 400,
    			Part = 'RootPart',
    			Players = true,
    			NPCs = false
    		})
    		return ent and ent.RootPart and ent.RootPart.Position or nil
    	end

    	local ray
    	if choice == 'Camera' then
    		ray = Ray.new(gameCamera.CFrame.Position, gameCamera.CFrame.LookVector)
    	else
    		ray = cloneref(lplr:GetMouse()).UnitRay
    	end

    	rayCheck.FilterDescendantsInstances = {lplr.Character, gameCamera}
    	local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000000, rayCheck)
    	return hit and (hit.Position + Vector3.new(0, rootHeight(), 0)) or nil
    end

    --[[
    	Both arcs onto a point, as unit launch directions with their flight times.

    	For speed v and gravity g, the angle onto a point dx across and dy up satisfies
    	tan(angle) = (v^2 -+ sqrt(v^4 - g(g dx^2 + 2 dy v^2))) / (g dx). Nothing under the
    	root means the point is out of reach at this speed.
    ]]
    local function solveArcs(origin, target)
    	local gravity = workspace.Gravity
    	local delta = target - origin
    	local flat = Vector3.new(delta.X, 0, delta.Z)
    	local dx, dy = flat.Magnitude, delta.Y
    	if dx < 0.5 then return nil end

    	local v2 = LAUNCH_SPEED * LAUNCH_SPEED
    	local inner = v2 * v2 - gravity * (gravity * dx * dx + 2 * dy * v2)
    	if inner < 0 then return nil end

    	local root = math.sqrt(inner)
    	local unit = flat.Unit
    	local function arc(sign)
    		local angle = math.atan((v2 + sign * root) / (gravity * dx))
    		local direction = unit * math.cos(angle) + Vector3.yAxis * math.sin(angle)
    		return direction, dx / (LAUNCH_SPEED * math.cos(angle))
    	end
    	local lowDir, lowTime = arc(-1)
    	local highDir, highTime = arc(1)
    	return lowDir, lowTime, highDir, highTime
    end

    -- Whether you would fly the whole arc without clipping a block. The last moment is
    -- left out: that is the ground you are meant to land on.
    local function clearPath(origin, direction, flight, cannon)
    	local ignore = {gameCamera}
    	for _, plr in playersService:GetPlayers() do
    		if plr.Character then ignore[#ignore + 1] = plr.Character end
    	end
    	if cannon then ignore[#ignore + 1] = cannon end
    	pathCheck.FilterDescendantsInstances = ignore

    	local gravity = workspace.Gravity
    	local velocity = direction * LAUNCH_SPEED
    	local previous = origin
    	local stopAt = math.max(flight - 0.08, 0)
    	local t = 0
    	while t < stopAt do
    		t = math.min(t + 0.04, stopAt)
    		local point = origin + velocity * t - Vector3.new(0, 0.5 * gravity * t * t, 0)
    		local ok, hit = pcall(workspace.Spherecast, workspace, previous, 1.25, point - previous, pathCheck)
    		if not ok then hit = workspace:Raycast(previous, point - previous, pathCheck) end
    		if hit then return false end
    		previous = point
    	end
    	return true
    end

    -- The launch direction onto a point, by the arc chosen - or nil when it cannot be
    -- reached at all.
    local function launchDirection(origin, target, cannon)
    	local lowDir, lowTime, highDir, highTime = solveArcs(origin, target)
    	if not lowDir then return nil end

    	local choice = Arc and Arc.Value or 'Auto'
    	if choice == 'Low' then return lowDir end
    	if choice == 'High' then return highDir end
    	if clearPath(origin, lowDir, lowTime, cannon) then return lowDir end
    	if clearPath(origin, highDir, highTime, cannon) then return highDir end
    	return lowDir
    end

    --[[
    	Aiming is 'AimCannon', named directly: the scraped remote table resolves this one to
    	'Get'. The vector is the plain unit direction the game itself sends.
    ]]
    local function sendAim(cannon, lookVector)
    	bedwars.Client:Get('AimCannon'):SendToServer({
    		cannonBlockPos = bedwars.BlockController:getBlockPosition(cannon.Position),
    		lookVector = lookVector
    	})
    end

    --[[
    	The last correction, at the moment you leave.

    	The game's launch hands you an impulse along the direction the cannon was aimed from
    	wherever you stood then. Once it has gone through - the server agreed and you are
    	moving - the shot is solved again from exactly where you are now and your velocity
    	set to it, at the same 200 studs a second. Only while one of our own shots is in
    	flight; any other launch is left exactly as the game made it.
    ]]
    local function installLaunchHook()
    	local controller = bedwars.CannonHandController
    	if launchHook or not controller then return end

    	local original = controller.launchSelf
    	if type(original) ~= 'function' then return end
    	launchOriginal = original
    	launchHook = function(self, cannon, ...)
    		local root = entitylib.isAlive and entitylib.character.RootPart
    		local before = root and root.AssemblyLinearVelocity
    		local result = original(self, cannon, ...)

    		local target = pendingTarget
    		if target and root and root.Parent and before then
    			-- Only once the game actually launched you; a refused launch changes nothing.
    			if (root.AssemblyLinearVelocity - before).Magnitude > 50 then
    				local direction = launchDirection(root.Position, target, pendingCannon or cannon)
    				if direction then
    					root.AssemblyLinearVelocity = direction * LAUNCH_SPEED
    				end
    			end
    		end
    		return result
    	end
    	controller.launchSelf = launchHook
    end

    local function removeLaunchHook()
    	local controller = bedwars.CannonHandController
    	if launchHook and controller and controller.launchSelf == launchHook then
    		controller.launchSelf = launchOriginal
    	end
    	launchHook = nil
    	pendingTarget, pendingCannon = nil, nil
    end

    local function aimAndFire()
    	-- Launching while it is still on you is what turns a free ride into sixty damage.
    	if on(AvoidPowdered) and powderedStacks() > 0 then return end

    	local cannon = nearestCannon()
    	if not cannon then return end

    	local target = aimPoint()
    	if not target then return end

    	local origin = entitylib.character.RootPart.Position
    	local direction = launchDirection(origin, target, cannon)
    	if not direction then
    		if on(OutOfRangeNotify) and os.clock() - lastRangeNotice > 3 then
    			lastRangeNotice = os.clock()
    			notif('DaveyAim', 'Out of range - the cannon reaches about 200 studs on the level', 3, 'warning')
    		end
    		return
    	end

    	if AimMode.Value == 'Legit' then
    		-- The prompts the game itself binds, held for as long as it asks, with the camera
    		-- turned along the launch - the game aims by where the camera faces.
    		local aim = cannon:FindFirstChild('AimPrompt')
    		if not aim then return end

    		aim:InputHoldBegin()
    		task.wait(aim.HoldDuration)

    		local until_ = tick() + 0.3
    		repeat
    			local position = gameCamera.CFrame.Position
    			gameCamera.CFrame = gameCamera.CFrame:Lerp(CFrame.lookAt(position, position + direction), 22 * runService.PostSimulation:Wait())
    			sendAim(cannon, gameCamera.CFrame.LookVector)
    		until tick() > until_
    		sendAim(cannon, direction)

    		local stop = cannon:FindFirstChild('StopAimingPrompt')
    		if stop then
    			stop:InputHoldBegin()
    			task.wait(stop.HoldDuration + runService.PostSimulation:Wait())
    		end

    		if on(Launch) then
    			local fire = cannon:FindFirstChild('LaunchSelfPrompt')
    			if fire then
    				pendingTarget, pendingCannon = target, cannon
    				fire:InputHoldBegin()
    				task.wait(fire.HoldDuration + runService.PostSimulation:Wait())
    				task.wait(0.5)
    				pendingTarget, pendingCannon = nil, nil
    			end
    		end
    	else
    		sendAim(cannon, direction)
    		task.wait(0.3)
    		if on(Launch) then
    			pendingTarget, pendingCannon = target, cannon
    			bedwars.CannonHandController:launchSelf(cannon)
    			pendingTarget, pendingCannon = nil, nil
    		end
    	end
    end

    DaveyAim = vain.Categories.Kit:CreateModule({
    	Name = 'DaveyAim',
    	Tooltip = 'Fires you from the nearest cannon to land exactly where you point',
    	Function = function(call)
    		if not call then
    			removeLaunchHook()
    			return
    		end
    		installLaunchHook()

    		-- Once behaves as a button: it takes the shot and then un-latches itself.
    		if Activation ~= nil and Activation.Value == 'Once' then
    			pcall(aimAndFire)
    			task.defer(function()
    				if DaveyAim.Enabled then
    					pcall(function() DaveyAim:Toggle() end)
    				end
    			end)
    			return
    		end

    		repeat
    			pcall(aimAndFire)
    			task.wait(Delay.Value)
    		until not DaveyAim.Enabled
    	end
    })
    Activation = DaveyAim:CreateDropdown({
    	Name = 'Activation',
    	Tooltip = 'Whether it keeps firing or takes a single shot',
    	List = {'Once', 'Continuous'},
    	Default = 'Once',
    	Function = function(value)
    		if Delay and Delay.Object then
    			Delay.Object.Visible = value == 'Continuous'
    		end
    	end,
    	Tooltips = {
    		Once = 'Fires a single shot when you switch it on, then switches itself back off',
    		Continuous = 'Keeps aiming and firing for as long as it is switched on',
    	}
    })
    AimAt = DaveyAim:CreateDropdown({
    	Name = 'Aim At',
    	Tooltip = 'Where to land',
    	List = {'Mouse', 'Camera', 'Nearest Enemy'},
    	Default = 'Mouse',
    	Tooltips = {
    		Mouse = 'Lands you on the spot under your cursor',
    		Camera = 'Lands you where the camera is looking',
    		['Nearest Enemy'] = 'Lands you on the nearest player',
    	}
    })
    Arc = DaveyAim:CreateDropdown({
    	Name = 'Arc',
    	Tooltip = 'Which of the two arcs onto the spot to fly',
    	List = {'Auto', 'Low', 'High'},
    	Default = 'Auto',
    	Tooltips = {
    		Auto = 'The low arc, or the high one when something is in the way',
    		Low = 'Flatter and quicker',
    		High = 'Over walls, but slower and more exposed',
    	}
    })
    AimMode = DaveyAim:CreateDropdown({
    	Name = 'Aim Mode',
    	Tooltip = 'How the cannon is aimed',
    	List = {'Fast', 'Legit'},
    	Default = 'Fast',
    	Tooltips = {
    		Fast = 'Sends the aim straight to the server and launches',
    		Legit = 'Holds the prompts and turns the camera the way a player would',
    	}
    })
    SearchRange = DaveyAim:CreateSlider({
    	Name = 'Search Range',
    	Tooltip = 'How far to look for one of your cannons',
    	Min = 1,
    	Max = 60,
    	Default = 20,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end
    })
    Delay = DaveyAim:CreateSlider({
    	Name = 'Delay',
    	Tooltip = 'Wait between shots in Continuous',
    	Min = 0.1,
    	Max = 5,
    	Default = 1,
    	Decimal = 10,
    	Suffix = 'sec',
    	Darker = true,
    	Visible = false
    })
    Launch = DaveyAim:CreateToggle({
    	Name = 'Launch',
    	Tooltip = 'Fires yourself out of the cannon once it is aimed',
    	Default = true
    })
    AvoidPowdered = DaveyAim:CreateToggle({
    	Name = 'Avoid Powdered',
    	Tooltip = 'Waits for Powdered to lapse before launching again',
    	Darker = true,
    	Default = true
    })
    OutOfRangeNotify = DaveyAim:CreateToggle({
    	Name = 'Range Warning',
    	Tooltip = 'Tells you when the spot is out of the cannon\'s reach',
    	Default = true
    })
end)

kitRun(function()
    local AutoDrill
    local AutoCollect
    local Notify
    local AutoAttack
    local Legit
    local Range
    local AttackDelay
    local CollectDelay
    local Targets
    local Sort
    local currentDrill
    local attackDebounce = {}
    local collectDebounce = {}

    local function getDrillPart(drill)
    	return drill and (drill.PrimaryPart or drill:FindFirstChild('RootPart') or drill:FindFirstChildWhichIsA('BasePart'))
    end

    local function addDrill(drills, added, drill)
    	if typeof(drill) ~= 'Instance' or added[drill] or drill:GetAttribute('PlacedByUserId') ~= lplr.UserId then
    		return
    	end
    	if getDrillPart(drill) then
    		added[drill] = true
    		table.insert(drills, drill)
    	end
    end

    local function getDrills(tagged)
    	local drills, added = {}, {}
    	for _, drill in tagged do
    		addDrill(drills, added, drill)
    	end

    	for _, drill in (bedwars.DrillTabletController and bedwars.DrillTabletController.drillList or {}) do
    		addDrill(drills, added, drill)
    	end

    	return drills
    end

    local function getResourceAmount(drill)
    	return (drill:GetAttribute('diamond') or 0) + (drill:GetAttribute('emerald') or 0)
    end

    local function collectDrill(drill)
    	local suc = pcall(function()
    		bedwars.Client:Get('ExtractFromDrill'):SendToServer({
    			drill = drill,
    		})
    	end)
    	return suc
    end

    local function useDrill(drill)
    	if currentDrill == drill then
    		return true
    	end

    	local suc, res = pcall(function()
    		return bedwars.Client:Get('PlayerUseDrillController'):CallServer({
    			drill = drill,
    		})
    	end)

    	if suc and res ~= false then
    		currentDrill = drill
    		return true
    	end

    	return false
    end

    local function attackDrill(drill, target)
    	if not useDrill(drill) then
    		return false
    	end

    	local suc = pcall(function()
    		bedwars.Client:Get('DrillAttack'):SendToServer({
    			targetPosition = target.RootPart.Position,
    		})
    	end)
    	return suc
    end

    local function getTarget(position)
    	return entitylib.EntityPosition({
    		Origin = position,
    		Range = Legit.Enabled and 10 or Range.Value,
    		Part = 'RootPart',
    		Players = Targets.Players.Enabled,
    		NPCs = Targets.NPCs.Enabled,
    		Sort = sortmethods[Sort.Value],
    	})
    end

    local function updateAttackControls()
    	pcall(function()
    		local enabled = AutoAttack.Enabled
    		Legit.Object.Visible = enabled
    		Range.Object.Visible = enabled and not Legit.Enabled
    		AttackDelay.Object.Visible = enabled
    		Targets.Object.Visible = enabled
    		Sort.Object.Visible = enabled
    	end)
    end

    AutoDrill = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Drill',
    	Tooltip = 'Automates the Drill kit — drills and collects automatically',
    	Function = function(callback)
    		if callback then
    			local tagged = collection('Drill', AutoDrill)
    			repeat
    				task.wait()
    			until store.matchState ~= 0 and store.equippedKit == 'drill' or not AutoDrill.Enabled

    			repeat
    				if entitylib.isAlive and store.equippedKit == 'drill' then
    					local now = tick()
    					for _, drill in getDrills(tagged) do
    						local part = getDrillPart(drill)
    						if not part then
    							continue
    						end

    						if
    							AutoCollect.Enabled
    							and getResourceAmount(drill) > 0
    							and now > (collectDebounce[drill] or 0)
    						then
    							if collectDrill(drill) and Notify.Enabled then
    							end
    							collectDebounce[drill] = now + CollectDelay.Value
    						end

    						if AutoAttack.Enabled and now > (attackDebounce[drill] or 0) then
    							local target = getTarget(part.Position)
    							if target then
    								targetinfo.Targets[target] = tick() + 1
    								if attackDrill(drill, target) then
    									attackDebounce[drill] = now + AttackDelay.Value
    								end
    							end
    						end
    					end
    				end

    				task.wait(0.1)
    			until not AutoDrill.Enabled
    		else
    			currentDrill = nil
    			table.clear(attackDebounce)
    			table.clear(collectDebounce)
    		end
    	end,
    	Tooltip = 'Automatically collects resources and attacks with placed drills.'
    })
    AutoCollect = AutoDrill:CreateToggle({
    	Name = 'Auto collect',
    	Tooltip = 'Automatically collects drill output',
    	Default = true,
    	Function = function(callback)
    		pcall(function()
    			Notify.Object.Visible = callback
    			CollectDelay.Object.Visible = callback
    		end)
    	end
    })
    Notify = AutoDrill:CreateToggle({
    	Name = 'Notify on collect',
    	Tooltip = 'Sends a notification when drill output is collected',
    	Darker = true
    })
    AutoAttack = AutoDrill:CreateToggle({
    	Name = 'Auto attack',
    	Tooltip = 'Automatically attacks with the kit weapon',
    	Default = true,
    	Function = updateAttackControls
    })
    Range = AutoDrill:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 10,
    	Default = 10,
    	Suffix = function(value)
    		return value == 1 and 'stud' or 'studs'
    	end
    })
    Legit = AutoDrill:CreateToggle({
    	Name = 'Legit Range',
    	Tooltip = 'Restricts range to a value indistinguishable from vanilla',
    	Default = true,
    	Function = updateAttackControls
    })
    AttackDelay = AutoDrill:CreateSlider({
    	Name = 'Attack delay',
    	Tooltip = 'Seconds between consecutive attacks',
    	Min = 0.1,
    	Max = 1,
    	Default = 0.3,
    	Decimal = 100,
    	Suffix = function(value)
    		return value == 1 and 'sec' or 'secs'
    	end
    })
    CollectDelay = AutoDrill:CreateSlider({
    	Name = 'Collect delay',
    	Tooltip = 'Seconds between collection attempts',
    	Min = 0.1,
    	Max = 3,
    	Default = 0.5,
    	Decimal = 10,
    	Suffix = function(value)
    		return value == 1 and 'sec' or 'secs'
    	end
    })
    Targets = AutoDrill:CreateTargets({
    	Tooltip = 'Configure which types of targets to include',
    	Players = true,
    	NPCs = false
    })
    local methods = {'Distance', 'Health', 'Damage'}
    for name in sortmethods do
    	if not table.find(methods, name) then
    		table.insert(methods, name)
    	end
    end
    Sort = AutoDrill:CreateDropdown({
    	Name = 'Sort',
    	Tooltip = 'Selects how targets are sorted/prioritized',
    	List = methods,
    	Default = 'Distance',
    	ItemTooltips = {
    		Distance = 'Targets the closest enemy by stud distance',
    		Health = 'Targets the enemy with the lowest remaining health',
    		Angle = 'Targets the enemy closest to your look direction',
    		Cursor = 'Targets the enemy nearest to your mouse cursor',
    		Damage = 'Targets the enemy who most recently took damage',
    		Threat = 'Targets the enemy judged to be the greatest combat threat',
    		Kit = 'Prioritizes dangerous kit users (Hannah, Spirit Assassin, etc.)',
    	}
    })
    updateAttackControls()
end)

kitRun(function()
    local AutoElder
    local Streamer
    local Range
    local Animation
    local Delay

    AutoElder = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Elder',
    	Tooltip = 'Automates the Elder kit ability',
    	Function = function(call)
    		if call then
    			AutoElder:Clean(proximityPromptService.PromptShown:Connect(function(prompt)
    				if Streamer.Enabled and prompt.Name == 'treeOrb' then
    					task.delay(0.1, prompt.InputHoldBegin, prompt)
    				end
    			end))

    			repeat
    				if not Streamer.Enabled and entitylib.isAlive then
    					local localPosition = entitylib.character.RootPart.Position
    					for i, v in collectionService:GetTagged('treeOrb') do
    						if tick() > (Delay[v] or 0) and (localPosition - v.Spirit.Position).Magnitude <= Range.Value then
    							if Delay.Value > 0 then
    								task.wait(Delay.Value)
    							end

    							if (localPosition - v.Spirit.Position).Magnitude <= Range.Value then
    								if Animation.Enabled then
    									bedwars.GameAnimationUtil:playAnimation(lplr.Character, bedwars.AnimationType.PUNCH)
    									bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_USE_ITEM)
    									bedwars.SoundManager:playSound(bedwars.SoundList.CROP_HARVEST)
    								end
    								if bedwars.Client:Get(remotes.ConsumeTreeOrb):CallServer({treeOrbSecret = v:GetAttribute('TreeOrbSecret')}) then
    									v:Destroy()
    								end
    								Delay[v] = tick() + 1
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoElder.Enabled
    		end
    	end,
    	Tooltip = 'Automatically collects tree orbs'
    })

    Streamer = AutoElder:CreateToggle({
    	Name = 'Streamer mode',
    	Tooltip = 'Hides delay, range, and animation settings from the UI — useful for streaming',
    	Function = function(call)
    		pcall(function()
    			Delay.Object.Visible = not call
    			Range.Object.Visible = not call
    			Animation.Object.Visible = not call
    		end)
    	end
    })
    Animation = AutoElder:CreateToggle({
    	Name = 'Animation',
    	Default = true,
    	Tooltip = 'Plays the collect animation'
    })
    Range = AutoElder:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 20,
    	Default = 12,
    	Suffix = function(val)
    		return val > 1 and 'studs' or 'stud'
    	end
    })
    Delay = AutoElder:CreateSlider({
    	Name = 'Delay',
    	Tooltip = 'Seconds between consecutive actions',
    	Min = 0,
    	Max = 1,
    	Suffix = function(val)
    		return val > 1 and 'secs' or 'sec'
    	end,
    	Default = 0.2,
    	Decimal = 100
    })
end)

kitRun(function()
	local AutoEmber
	local Targets
	local Range
	local SpinCooldown
	local Limit
	local old = os.clock()+ 0.00000000000000000000013
	local isCharging = false
	local chargeAnim, FpChargeAnim = nil,nil
	AutoEmber = vain.Categories.Kit:CreateModule({
		Name = 'Auto Ember',
		Tooltip = 'automatically uses the ember ability',
		Function = function(call)
			if call then
				repeat
					if entitylib.isAlive then 
						local tool = getItem('infernal_saber') 
						if tool and (not Limit.Enabled or store.hand.tool and store.hand.tool.Name == 'infernal_saber') then
							local ent = entitylib.EntityPosition({
								Range = HoldRange.Value,
								Players = Targets.Players.Enabled,
								NPCs = Targets.NPCs.Enabled,
								Part = 'RootPart'
							}) 

							if not ent then
								if isCharging then
									isCharging = false
									bedwars.HellSaberController.animationMaid:DoCleaning()
									chargeAnim = nil
									FpChargeAnim = nil
									task.wait(0.3)
									continue
								end
							end

							if ent then
								if not isCharging then
									isCharging = true
									bedwars.HellSaberController:playChargeSound(lplr)
									local animer = lplr.Character
									if animer ~= nil then
										animer = animer:FindFirstChild("Humanoid")
										if animer ~= nil then
											animer = animer:FindFirstChild("Animator")
										end
									end
									if not animer then
										return nil
									end
									chargeAnim = animer:LoadAnimation(bedwars.GameAnimationUtil:getAnimation(bedwars.AnimationType.INFERNO_SWORD_CHARGE))
									chargeAnim:Play()
									chargeAnim:AdjustSpeed(1.83)
									chargeAnim:GetMarkerReachedSignal("end"):Connect(function()
										local newChargeAnim = chargeAnim
										if newChargeAnim ~= nil then
											newChargeAnim:AdjustSpeed(0)
										end
									end)
									FpChargeAnim = bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_INFERNO_SWORD_CHARGE)
									if FpChargeAnim then
										FpChargeAnim:GetMarkerReachedSignal("end"):Connect(function()
											local newFpChargeAnim = FpChargeAnim
											if newFpChargeAnim ~= nil then
												newFpChargeAnim:AdjustSpeed(0)
											end
										end)
									end
									bedwars.HellSaberController.animationMaid:GiveTask(function()
										local MaidCA1 = chargeAnim
										if MaidCA1 ~= nil then
											MaidCA1:Stop()
										end
										local MaidCA2 = chargeAnim
										if MaidCA2 ~= nil then
											MaidCA2:Destroy()
										end
										local MaidFCA1 = FpChargeAnim
										if MaidFCA1 ~= nil then
											MaidFCA1:Stop()
										end
										local MaidFCA2 = FpChargeAnim
										if MaidFCA2 ~= nil then
											MaidFCA2:Destroy()
										end
									end)
								end
								local DeltaPos = (ent.RootPart.Position - lplr.Character.HumanoidRootPart.Position).Magnitude
								if DeltaPos <= Range.Value then
									local now = os.clock() + 0.00000000000000000000013
									if (now - old) >= SpinCooldown.Value then
										bedwars.HellSaberController.animationMaid:DoCleaning()
										if not Limit.Enabled then
											switchItem(tool)
										end
										bedwars.Client:Get('HellBladeRelease'):SendToServer({
											chargeTime = 1 + tick() - (0.045 + (math.random() - math.random())), 
											weapon = tool,
											player = lplr
										})
										old = os.clock() + 0.00000000000000000000013
										bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_INFERNO_SWORD_SPIN)										
										isCharging = false
										
									end
								end
							end
						end
					end
					task.wait(0.1)
				until not AutoEmber.Enabled 
			end
		end
	})
	Targets = AutoEmber:CreateTargets({
		Tooltip = 'Who it is used on',
		Players = true,
		NPCs = false
	})
	SpinCooldown = AutoEmber:CreateSlider({
		Name = 'Spin Cooldown',
		Min = 0,
		Max = 4,
		Default = 1.12,
		Decimal = 100,
		Tooltip = 'Anything below 0.2 will most likely get you banned if you get clipped'
	})
	Range = AutoEmber:CreateSlider({
		Name = 'Release Range',
		Tooltip = 'Distance at which the spin attack is released on a target',
		Min = 1,
		Max = 22,
		Default = 22,
		Suffix = function(val)
			return val <= 1 and 'stud' or 'studs'
		end
	})
	HoldRange = AutoEmber:CreateSlider({
		Name = 'Hold Range',
		Tooltip = 'Distance at which the spin attack starts charging',
		Min = 1,
		Max = 48,
		Default = 32,
		Suffix = function(val)
			return val <= 1 and 'stud' or 'studs'
		end
	})
	Limit = AutoEmber:CreateToggle({Name = 'Limit to item', Tooltip = 'Only works while the Ember weapon is equipped'})
end)

kitRun(function()
    local AutoGingerbread
    local Range
    local Delay
    local Break
    local Jump
    local Switch
    local OwnOnly
    local SuccessfulOnly

    local old
    local hook

    local function canUseBlock(block)
    	if not entitylib.isAlive or typeof(block) ~= 'Instance' or not block:IsA('BasePart') then
    		return false
    	end

    	if store.equippedKit ~= 'gingerbread_man' then
    		return false
    	end

    	if OwnOnly.Enabled and block:GetAttribute('PlacedByUserId') ~= lplr.UserId then
    		return false
    	end

    	return (block.Position - entitylib.character.RootPart.Position).Magnitude <= Range.Value
    end

    AutoGingerbread = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Gingerbread Man',
    	Tooltip = 'Automates Gingerbread Man kit launch pads',
    	Function = function(callback)
    		if callback then
    			old = bedwars.LaunchPadController.attemptLaunch
    			hook = function(...)
    				local controller, block = ...
    				local lastLaunch = controller and controller.lastLaunch or 0

    				if not SuccessfulOnly.Enabled or (controller and controller.lastLaunch and (controller.lastLaunch ~= lastLaunch or workspace:GetServerTimeNow() - controller.lastLaunch < 0.5)) then
    					if Break.Enabled and canUseBlock(block) then
    						task.delay(Delay.Value, bedwars.breakBlock, block, false, nil, true, nil, Switch.Enabled)
    					end

    					if Jump.Enabled and entitylib.isAlive then
    						lplr.Character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
    					end
    				end

    				return old(...)
    			end
    			bedwars.LaunchPadController.attemptLaunch = hook
    		elseif old then
    			if bedwars.LaunchPadController.attemptLaunch == hook then
    				bedwars.LaunchPadController.attemptLaunch = old
    			end
    			old = nil
    			hook = nil
    		end
    	end,
    	Tooltip = 'Automatically handles Gingerbread Man launch pads.'
    })

    Break = AutoGingerbread:CreateToggle({
    	Name = 'Break launch pad',
    	Tooltip = 'Automatically breaks used launch pads',
    	Default = true,
    	Function = function(call)
    		pcall(function()
    			Range.Object.Visible = call
    			Delay.Object.Visible = call
    			Switch.Object.Visible = call
    			OwnOnly.Object.Visible = call
    		end)
    	end
    })
    Jump = AutoGingerbread:CreateToggle({Name = 'Jump after launch', Tooltip = 'Jumps immediately after being launched by a pad'})
    Switch = AutoGingerbread:CreateToggle({
    	Name = 'Legit switch',
    	Tooltip = 'Switches to a more legit-looking mode automatically',
    	Darker = true
    })
    OwnOnly = AutoGingerbread:CreateToggle({
    	Name = 'Own pads only',
    	Tooltip = 'Only activates on launch pads you placed yourself',
    	Default = true,
    	Darker = true
    })
    SuccessfulOnly = AutoGingerbread:CreateToggle({
    	Name = 'Successful launch only',
    	Tooltip = 'Only activates after a confirmed successful launch',
    	Default = true
    })
    Range = AutoGingerbread:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 30,
    	Default = 30,
    	Darker = true,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end
    })
    Delay = AutoGingerbread:CreateSlider({
    	Name = 'Break delay',
    	Tooltip = 'Seconds between break attempts',
    	Min = 0,
    	Max = 1,
    	Default = 0.05,
    	Decimal = 100,
    	Darker = true,
    	Suffix = function(val)
    		return val == 1 and 'sec' or 'secs'
    	end
    })
end)

kitRun(function()
	local AutoHannah
	local Targets
	local Sort
	local Distance
	local Void
	local KATarget 

	AutoHannah = vain.Categories.Kit:CreateModule({
		Name = "Auto Hannah",
		Tooltip = 'auto execute players',
		Function = function(callback)
			if callback then
				task.spawn(function()
					local objs = collection('HannahExecuteInteraction', AutoHannah)

					while AutoHannah.Enabled do
						task.wait(0.1)
						if not entitylib.isAlive then continue end

						local localPosition = entitylib.character.RootPart.Position

						for _, v in objs do
							if not AutoHannah.Enabled then break end
							local part = not v:IsA('Model') and v or v.PrimaryPart
							if not part then continue end
							if (part.Position - localPosition).Magnitude > Distance.Value then continue end
							if Void.Enabled and isAboveVoid(part.Position) then continue end
							local success = bedwars.Client:Get('HannahPromptTrigger').instance:InvokeServer({
								user = lplr,
								victimEntity = v
							})
							if success then
								local icon = v:FindFirstChild('Hannah Execution Icon')
								if icon then icon:Destroy() end
							end
							task.wait(0.05)
						end
					end
				end)
			end
		end
	})

	Targets = AutoHannah:CreateTargets({
		Tooltip = 'Who it is used on',
		Players = true,
		Walls = false,
		NPCs = false
	})
	local methods = {'Damage', 'Distance'}
	for i in sortmethods do
		if not table.find(methods, i) then
			table.insert(methods, i)
		end
	end
	Sort = AutoHannah:CreateDropdown({Name = 'Sort', Tooltip = 'How to prioritize targets', List = methods})
	Distance = AutoHannah:CreateSlider({
		Name = "Distance",
		Tooltip = 'Maximum distance to execute Hannah\'s ability on a target',
		Min = 0,
		Max = 16,
		Default = 12,
		Suffix = 'studs'
	})
	Void = AutoHannah:CreateToggle({
		Name = 'Void',
		Tooltip = 'Will not execute a player if they are falling in the void',
		Default = true,
	})
	KATarget = AutoHannah:CreateToggle({
		Name = 'Use KA Target',
		Tooltip = 'Uses Killaura\'s current target instead of picking its own',
		Default = false,
	})
end)

kitRun(function()
    local Kaliyah
    local AutoPunch
    local RangeSlider
    local PunchDelay
    local DelaySlider
    local NoSlow
    local punchActive = false
    local punchDebounce = {}

    local function getKaliyahTargets()
        local targets = {}
        if not entitylib.isAlive then return targets end
        
        local localPosition = entitylib.character.RootPart.Position
        local range = RangeSlider.Value
        
        for _, v in collectionService:GetTagged('KaliyahPunchInteraction') do
            if v:IsA("Model") and v.PrimaryPart then
                local distance = (localPosition - v.PrimaryPart.Position).Magnitude
                if distance <= range then
                    table.insert(targets, v)
                end
            end
        end
        
        return targets
    end

    local function punchTarget(target)
        local targetId = target:GetAttribute('Id') or tostring(target)
        
        if punchDebounce[targetId] then return false end
        punchDebounce[targetId] = true
        
        local character = lplr.Character
        if not character or not character.PrimaryPart then 
            punchDebounce[targetId] = nil
            return false 
        end
        
        pcall(function()
            bedwars.DragonSlayerController:deleteEmblem(target)
        end)
        
        local playerPos = character:GetPrimaryPartCFrame().Position
        local targetPos = target:GetPrimaryPartCFrame().Position * Vector3.new(1, 0, 1) + Vector3.new(0, playerPos.Y, 0)
        local lookAtCFrame = CFrame.new(playerPos, targetPos)
        
        character:PivotTo(lookAtCFrame)
        
        pcall(function()
            bedwars.DragonSlayerController:playPunchAnimation(lookAtCFrame - lookAtCFrame.Position)
        end)
        
        local success = pcall(function()
            bedwars.Client:Get(remotes.KaliyahPunch):SendToServer({
                target = target
            })
        end)
        
        task.delay(3, function()
            punchDebounce[targetId] = nil
        end)
        
        return success
    end

    local function startAutoPunch()
        if punchActive then return end
        punchActive = true
        
        task.spawn(function()
            while Kaliyah.Enabled and AutoPunch.Enabled and punchActive do
                if not entitylib.isAlive then 
                    task.wait(0.5)
                    continue 
                end
                
                local targets = getKaliyahTargets()
                local punchedThisCycle = false
                
                for _, target in targets do
                    if not Kaliyah.Enabled or not AutoPunch.Enabled or not punchActive then 
                        break 
                    end
                    
                    if PunchDelay.Enabled and DelaySlider.Value > 0 then
                        task.wait(DelaySlider.Value)
                    end
                    
                    if punchTarget(target) then
                        punchedThisCycle = true
                        task.wait(0.2)
                    end
                end
                
                task.wait(punchedThisCycle and 0.5 or 0.3)
            end
            
            punchActive = false
        end)
    end

    local function stopAutoPunch()
        punchActive = false
        table.clear(punchDebounce)
    end

    local originalPlayPunchAnimation
    local function hookNoSlow()
        if not bedwars.DragonSlayerController then return end
        
        originalPlayPunchAnimation = bedwars.DragonSlayerController.playPunchAnimation
        
        bedwars.DragonSlayerController.playPunchAnimation = function(self, arg2)
            if NoSlow.Enabled then
                local any_import_result1_6_upvr = debug.getupvalue(originalPlayPunchAnimation, 1)
                local GameAnimationUtil_upvr = debug.getupvalue(originalPlayPunchAnimation, 2)
                local Players_upvr = debug.getupvalue(originalPlayPunchAnimation, 3)
                local AnimationType_upvr = debug.getupvalue(originalPlayPunchAnimation, 4)
                local KnitClient_upvr = debug.getupvalue(originalPlayPunchAnimation, 5)
                local RunService_upvr = debug.getupvalue(originalPlayPunchAnimation, 6)
                
                local any_new_result1_upvr_2 = any_import_result1_6_upvr.new()
                local any_playAnimation_result1_upvr_2 = GameAnimationUtil_upvr:playAnimation(Players_upvr.LocalPlayer, AnimationType_upvr.DRAGON_SLAYER_PUNCH)
                any_new_result1_upvr_2:GiveTask(function()
                    local var137 = any_playAnimation_result1_upvr_2
                    if var137 ~= nil then
                        var137:Stop()
                    end
                end)
                
                any_new_result1_upvr_2:GiveTask(RunService_upvr.Heartbeat:Connect(function()
                    local Character = Players_upvr.LocalPlayer.Character
                    local var141 = Character
                    if var141 ~= nil then
                        var141 = var141.PrimaryPart
                    end
                    if not var141 then
                        any_new_result1_upvr_2:DoCleaning()
                        return nil
                    end
                    Character:PivotTo(CFrame.new(Character:GetPrimaryPartCFrame().Position) * arg2)
                end))
                
                task.delay(0.46, function()
                    any_new_result1_upvr_2:DoCleaning()
                end)
                
                return any_new_result1_upvr_2
            else
                return originalPlayPunchAnimation(self, arg2)
            end
        end
    end

    local function unhookNoSlow()
        if originalPlayPunchAnimation and bedwars.DragonSlayerController then
            bedwars.DragonSlayerController.playPunchAnimation = originalPlayPunchAnimation
        end
    end

    Kaliyah = vain.Categories.Kit:CreateModule({
        Name = 'Auto Kaliyah',
        Function = function(callback)
            if callback then
                if AutoPunch.Enabled then
                    startAutoPunch()
                end
                if NoSlow.Enabled then
                    hookNoSlow()
                end
            else
                stopAutoPunch()
                unhookNoSlow()
            end
        end,
        Tooltip = 'Dragon Slayer kit features - AutoPunch and NoSlow'
    })
    
    AutoPunch = Kaliyah:CreateToggle({
        Name = 'Auto Punch',
        Default = false,
        Tooltip = 'Automatically punch dragon emblems',
        Function = function(callback)
            if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = callback end
            if PunchDelay and PunchDelay.Object then PunchDelay.Object.Visible = callback end
            if DelaySlider and DelaySlider.Object then DelaySlider.Object.Visible = (callback and PunchDelay.Enabled) end
            if not callback then
                if DelaySlider and DelaySlider.Object then
                    DelaySlider.Object.Visible = false
                end
            else
                if PunchDelay and PunchDelay.Enabled then
                    if DelaySlider and DelaySlider.Object then
                        DelaySlider.Object.Visible = true
                    end
                end
            end
            
            if Kaliyah.Enabled then
                if callback then
                    startAutoPunch()
                else
                    stopAutoPunch()
                end
            end
        end
    })
    
    RangeSlider = Kaliyah:CreateSlider({
        Name = 'Range',
        Min = 1, 
        Max = 100,
        Default = 18,
        Decimal = 1,
        Suffix = ' studs',
        Tooltip = 'Distance to auto punch emblems'
    })
    
    PunchDelay = Kaliyah:CreateToggle({
        Name = 'Punch Delay',
        Default = false,
        Tooltip = 'Add delay before punching',
        Function = function(callback)
            if DelaySlider and DelaySlider.Object then
                DelaySlider.Object.Visible = callback
            end
        end
    })
    
    DelaySlider = Kaliyah:CreateSlider({
        Name = 'Delay',
        Min = 1,
        Max = 3,
        Default = 1,
        Decimal = 10,
        Suffix = 's',
        Tooltip = 'Delay in seconds before punching'
    })
    
    NoSlow = Kaliyah:CreateToggle({
        Name = 'No Slow',
        Default = false,
        Tooltip = 'Remove movement lock when punching',
        Function = function(callback)
            if Kaliyah.Enabled then
                if callback then
                    hookNoSlow()
                else
                    unhookNoSlow()
                end
            end
        end
    })

    task.defer(function()
        if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = false end
        if PunchDelay and PunchDelay.Object then PunchDelay.Object.Visible = false end
        if DelaySlider and DelaySlider.Object then DelaySlider.Object.Visible = false end
    end)
end)

kitRun(function()
    --[[
        Auto Lani.

        How the kit works now (ScepterController): consuming the scepter summons the angel
        0.8s later and turns on the PALADIN_ABILITY; while it is up (5s) the controller
        picks the teammate nearest your aim every frame into its target field, and using
        the ability makes the game send PaladinAbilityRequest with that target - you land
        on them and drop a healing aura (8% health a second for 8s).

        So rather than sending the request itself, this picks the teammate, writes it into
        the controller's target and uses the ability in the same step - no frame between
        for the aim to overwrite it - and the game sends its own request.

        Assist does that whenever you use the scepter. Auto also uses the scepter for you:
        when a teammate drops below the health you set, or - with Escape - when you do, in
        which case it goes to the teammate with the fewest enemies round them.
    ]]
    local AutoLani
    local Mode, TargetMode, Teammate, TeammateHealth, Escape, SelfHealth
    local MinDistance, FireDelay, SkipFalling, AutoBuyScepter, RefreshButton
    local escaping = false
    local lastUse, lastBuy = 0, 0
    local wasAngel = false
    local ENEMY_RANGE = 25
    local USE_COOLDOWN = 3

    local function on(setting)
        return setting ~= nil and setting.Enabled
    end

    local function enemiesNear(position)
        local count = 0
        for _, entity in entitylib.List do
            if entity.Targetable and entity.RootPart and (entity.RootPart.Position - position).Magnitude <= ENEMY_RANGE then
                count += 1
            end
        end
        return count
    end

    -- Teammates worth landing on: alive, far enough away, and not falling into the void.
    local function candidates()
        local list = {}
        if not entitylib.isAlive then return list end
        local here = entitylib.character.RootPart.Position
        local floor = AntiFallPart and AntiFallPart.Parent and AntiFallPart.Position.Y or nil
        for _, player in getTeammates(false) do
            local root = player.Character and player.Character:FindFirstChild('HumanoidRootPart')
            if root then
                local falling = root.AssemblyLinearVelocity.Y < -60 or (floor and root.Position.Y < floor + 3)
                local distance = (root.Position - here).Magnitude
                if distance >= MinDistance.Value and not (on(SkipFalling) and falling) then
                    list[#list + 1] = {player = player, root = root, distance = distance, health = getPlayerHealthPercent(player)}
                end
            end
        end
        return list
    end

    -- The teammate picked under Priority, while alive and in the game - chosen over every
    -- filter; when they are not, the lowest on health stands in.
    local function priorityTarget()
        if TargetMode.Value ~= 'Priority' then return nil end
        local name = Teammate and Teammate.Value
        if not name or name == 'None' then return nil end
        local player = playersService:FindFirstChild(name)
        local humanoid = player and player.Character and player.Character:FindFirstChildOfClass('Humanoid')
        if player and player ~= lplr and humanoid and humanoid.Health > 0 and player.Character:FindFirstChild('HumanoidRootPart') then
            return player
        end
    end

    local function pickTarget()
        local forced = not escaping and priorityTarget()
        if forced then return forced end
        local list = candidates()
        if #list == 0 then return nil end
        local mode = escaping and 'Safest' or TargetMode.Value
        if mode == 'Priority' then mode = 'Lowest Health' end
        local best, bestScore
        for _, entry in list do
            local score
            if mode == 'Lowest Health' then
                score = entry.health
            elseif mode == 'Closest' then
                score = entry.distance
            elseif mode == 'Furthest' then
                score = -entry.distance
            elseif mode == 'Most Enemies' then
                score = -enemiesNear(entry.root.Position)
            else
                -- Safest: the fewest enemies round them, the healthier one breaking a tie.
                score = enemiesNear(entry.root.Position) * 1000 - entry.health
            end
            if not bestScore or score < bestScore then best, bestScore = entry.player, score end
        end
        return best
    end

    -- Pins the pick as the controller's target and uses the ability; the game sends the request.
    local function fire()
        local controller = bedwars.ScepterController
        if not (controller and controller.isAngel) then return end
        local target = pickTarget()
        if not (target and target.Character) then return end
        landLani(target.Character)
    end

    -- Auto: whether it is time to use the scepter, and whether that is to escape.
    local function shouldUse()
        if not entitylib.isAlive then return false end
        if on(Escape) and getPlayerHealthPercent(lplr) <= SelfHealth.Value then return true, true end
        for _, entry in candidates() do
            if entry.health <= TeammateHealth.Value then return true, false end
        end
        return false
    end

    local function useScepter()
        local scepter = getItem('scepter')
        if not (scepter and scepter.tool) then return end
        switchItem(scepter.tool, 0.1)
        pcall(function()
            bedwars.Client:Get(remotes.ConsumeItem).instance:InvokeServer({item = scepter.tool})
        end)
        lastUse = os.clock()
    end

    -- Buys one when you have none, standing at your shop.
    local function buyScepter()
        if getItem('scepter') or os.clock() - lastBuy < 2 or not entitylib.isAlive then return end
        local item = bedwars.Shop.getShopItem('scepter', lplr)
        if not item then return end
        local here = entitylib.character.RootPart.Position
        local shopId
        for _, shop in store.shop do
            if shop.Shop and shop.RootPart and (shop.RootPart.Position - here).Magnitude <= 20 then
                shopId = shop.Id
                break
            end
        end
        local currency = getItem(item.currency)
        if not (shopId and currency and currency.amount >= item.price) then return end
        lastBuy = os.clock()
        bedwars.Client:Get('BedwarsPurchaseItem'):CallServerAsync({shopItem = item, shopId = shopId})
    end

    AutoLani = vain.Categories.Kit:CreateModule({
        Name = 'Auto Lani',
        Tooltip = 'Lands your Lani scepter on the right teammate',
        Function = function(callback)
            if callback then
                local lastCheck = 0
                AutoLani:Clean(runService.Heartbeat:Connect(function()
                    if store.equippedKit ~= 'paladin' then return end
                    local controller = bedwars.ScepterController
                    local angel = controller ~= nil and controller.isAngel == true
                    -- The angel just came up: pick and land after the delay.
                    if angel and not wasAngel then
                        task.delay(FireDelay:GetRandomValue(), function()
                            pcall(fire)
                            escaping = false
                        end)
                    end
                    wasAngel = angel

                    if os.clock() - lastCheck < 0.25 then return end
                    lastCheck = os.clock()
                    if on(AutoBuyScepter) then pcall(buyScepter) end
                    if Mode.Value == 'Auto' and not angel and os.clock() - lastUse >= USE_COOLDOWN then
                        local use, isEscape = shouldUse()
                        if use and (#candidates() > 0 or priorityTarget()) then
                            escaping = isEscape
                            pcall(useScepter)
                        end
                    end
                end))
            else
                escaping, wasAngel = false, false
            end
        end
    })
    Mode = AutoLani:CreateDropdown({
        Name = 'Mode',
        List = {'Assist', 'Auto'},
        Tooltips = {
            Assist = 'Picks the teammate when you use the scepter',
            Auto = 'Also uses the scepter for you'
        },
        Function = function(val)
            for _, setting in {TeammateHealth, Escape, SelfHealth} do
                if setting and setting.Object then setting.Object.Visible = val == 'Auto' end
            end
            if val == 'Auto' and SelfHealth and SelfHealth.Object then
                SelfHealth.Object.Visible = on(Escape)
            end
        end
    })
    TargetMode = AutoLani:CreateDropdown({
        Name = 'Target',
        List = {'Lowest Health', 'Closest', 'Furthest', 'Most Enemies', 'Priority'},
        Tooltips = {
            ['Lowest Health'] = 'The teammate lowest on health',
            Closest = 'The nearest teammate',
            Furthest = 'The furthest teammate',
            ['Most Enemies'] = 'The teammate with the most enemies round them',
            Priority = 'Always the teammate you pick, while alive'
        },
        Function = function(val)
            for _, setting in {Teammate, RefreshButton} do
                if setting and setting.Object then setting.Object.Visible = val == 'Priority' end
            end
        end
    })
    local function teammateList()
        local list = getTeammates(true)
        if #list == 0 then list = {'None'} end
        return list
    end
    Teammate = AutoLani:CreateDropdown({
        Tooltip = 'The teammate Priority goes to',
        Name = 'Teammate',
        List = teammateList(),
        Darker = true,
        Visible = false
    })
    RefreshButton = AutoLani:CreateButton({
        Name = 'Refresh Teammates',
        Tooltip = 'Updates the teammate list',
        Function = function()
            pcall(function() Teammate:Change(teammateList()) end)
        end
    })
    if RefreshButton and RefreshButton.Object then RefreshButton.Object.Visible = TargetMode.Value == 'Priority' end
    TeammateHealth = AutoLani:CreateSlider({
        Name = 'Teammate Health',
        Tooltip = 'Uses it when a teammate drops below this',
        Min = 5,
        Max = 95,
        Default = 40,
        Visible = false,
        Suffix = function() return '%' end
    })
    Escape = AutoLani:CreateToggle({
        Name = 'Escape',
        Tooltip = 'Uses it to get away when you are low',
        Visible = false,
        Function = function(callback)
            if SelfHealth and SelfHealth.Object then SelfHealth.Object.Visible = callback and Mode.Value == 'Auto' end
        end
    })
    SelfHealth = AutoLani:CreateSlider({
        Name = 'Escape Health',
        Tooltip = 'Your health that counts as low',
        Min = 5,
        Max = 90,
        Default = 30,
        Darker = true,
        Visible = false,
        Suffix = function() return '%' end
    })
    MinDistance = AutoLani:CreateSlider({
        Name = 'Min Distance',
        Tooltip = 'Skips teammates closer than this',
        Min = 0,
        Max = 100,
        Default = 15,
        Suffix = function(val) return val == 1 and 'stud' or 'studs' end
    })
    FireDelay = AutoLani:CreateTwoSlider({
        Name = 'Fire Delay',
        Tooltip = 'Wait after the angel appears, random between both (seconds)',
        Min = 0,
        Max = 3,
        DefaultMin = 0.1,
        DefaultMax = 0.3,
        Decimal = 100
    })
    SkipFalling = AutoLani:CreateToggle({
        Name = 'Skip Falling',
        Tooltip = 'Never picks a teammate falling into the void',
        Default = true
    })
    AutoBuyScepter = AutoLani:CreateToggle({
        Name = 'Auto Buy Scepter',
        Tooltip = 'Buys a scepter at your shop when you have none'
    })
end)

kitRun(function()
    local AutoMarina
    local Range

    AutoMarina = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Marina',
    	Tooltip = 'Automates the Marina kit ability',
    	Function = function(call)
    		if call then
    			local jellies = collection('jellyfish', AutoMarina, function(tab, obj)
    				task.delay(0, function()
    					if obj:GetAttribute('PlacedByUserId') == lplr.UserId then
    						table.insert(tab, obj)
    					end
    				end)
    			end)
    			repeat
    				if entitylib.isAlive and bedwars.AbilityController:canUseAbility('electrify_jellyfish') then
    					for _, v in jellies do
    						if v.PrimaryPart then
    							if
    								entitylib.EntityPosition({
    									Origin = v.PrimaryPart.Position,
    									Range = Range.Value,
    									Part = 'RootPart',
    									Players = true,
    								})
    							then
    								bedwars.AbilityController:useAbility('electrify_jellyfish')
    								break
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoMarina.Enabled
    		end
    	end,
    	Tooltip = 'Automatically uses "electrify" ability when enemies are near jellies'
    })

    Range = AutoMarina:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 65,
    	Default = 50,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end,
    })
end)

kitRun(function()
    local AutoMelody
    local Range
    local SelfHeal
    local TeammateHeal

    AutoMelody = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Melody',
    	Tooltip = 'Automates the Melody kit heal',
    	Function = function(call)
    		if call then
    			repeat
    				local mag, hp, ent = Range.Value, math.huge, nil
    				if entitylib.isAlive then
    					local localPosition = entitylib.character.RootPart.Position
    					for _, v in entitylib.List do
    						if v.Player and (SelfHeal.Enabled or v.Player ~= lplr) and (TeammateHeal.Enabled and v.Player:GetAttribute('Team') == lplr:GetAttribute('Team') or not TeammateHeal.Enabled and SelfHeal.Enabled and v.Player == lplr) then
    							local newmag = (localPosition - v.RootPart.Position).Magnitude
    							if newmag <= mag and v.Health < hp and v.Health < v.MaxHealth then
    								mag, hp, ent = newmag, v.Health, v
    							end
    						end
    					end
    				end

    				if ent and getItem('guitar') then
    					bedwars.Client:Get(remotes.GuitarHeal):SendToServer({
    						healTarget = ent.Character
    					})
    				end

    				task.wait(0.1)
    			until not AutoMelody.Enabled
    		end
    	end,
    	Tooltip = 'Automatically uses the guitar to heal ur teammates/urself'
    })

    SelfHeal = AutoMelody:CreateToggle({
    	Name = 'Self Heal',
    	Tooltip = 'Heals yourself with the kit ability',
    	Default = true
    })
    TeammateHeal = AutoMelody:CreateToggle({
    	Name = 'Teammate Heal',
    	Tooltip = 'Heals nearby teammates with the kit ability',
    	Default = true
    })
    Range = AutoMelody:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 30,
    	Default = 30,
    	Decimal = 4
    })
end)

kitRun(function()
    local MetalDetector
    local CollectionToggle
    local LimitToItem
    local Animation
    local CollectionDelay
    local DelaySlider
    local RangeSlider
    local ESPToggle
    local ESPNotify
    local ESPBackground
    local ESPColor
    local HoldingCheck
    local DistanceCheck
    local DistanceLimit
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local Reference = {}
    local lastNotification = 0
    local notificationPending = false
    local spawnQueue = {}
    local notificationCooldown = 1
    local collectionActive = false
    local collectedMetals = {}
    local animationDebounce = {}

    local function isHoldingMetalDetector()
        if not store.hand or not store.hand.tool then return false end
        return store.hand.tool.Name == 'metal_detector'
    end

    local function sendNotification(count)
    end

    local function processSpawnQueue()
        if #spawnQueue == 0 then return end
        local currentTime = tick()
        local remaining = notificationCooldown - (currentTime - lastNotification)
        if remaining <= 0 then
            sendNotification(#spawnQueue)
            lastNotification = currentTime
            spawnQueue = {}
            notificationPending = false
        elseif not notificationPending then
            notificationPending = true
            task.delay(remaining, function()
                if #spawnQueue > 0 then
                    sendNotification(#spawnQueue)
                    lastNotification = tick()
                    spawnQueue = {}
                end
                notificationPending = false
            end)
        end
    end

    local function getProperImage()
        return bedwars.getIcon({itemType = 'iron'}, true)
    end

    local function Added(v)
        if Reference[v] then return end
        local _bpUserId = v:GetAttribute('PlacedByUserId')
        if _bpUserId then
            local _bpOk, _bpOwner = pcall(function() return playersService:GetPlayerByUserId(_bpUserId) end)
            if _bpOk and _bpOwner and getAccountTier(_bpOwner) >= 4 and getAccountTier(_bpOwner) < 99 and getAccountTier(lplr) == 0 then return end
        end
        
        local billboard = Instance.new('BillboardGui')
        billboard.Parent = Folder
        billboard.Name = 'hidden-metal'
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
        billboard.Size = UDim2.fromOffset(36, 36)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = v
        
        local blur = addBlur(billboard)
        blur.Visible = ESPBackground.Enabled
        
        local image = Instance.new('ImageLabel')
        image.Size = UDim2.fromOffset(36, 36)
        image.Position = UDim2.fromScale(0.5, 0.5)
        image.AnchorPoint = Vector2.new(0.5, 0.5)
        image.BackgroundColor3 = Color3.fromHSV(ESPColor.Hue, ESPColor.Sat, ESPColor.Value)
        image.BackgroundTransparency = 1 - (ESPBackground.Enabled and ESPColor.Opacity or 0)
        image.BorderSizePixel = 0
        image.Image = getProperImage()
        image.Parent = billboard
        
        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 4)
        uicorner.Parent = image
        
        Reference[v] = billboard
        
        if ESPNotify.Enabled then
            table.insert(spawnQueue, {item = 'metal', time = tick()})
            processSpawnQueue()
        end
    end

    local function Removed(v)
        if Reference[v] then
            Reference[v]:Destroy()
            Reference[v] = nil
        end
    end

    local function setupESP()
        for _, v in collectionService:GetTagged('hidden-metal') do
            if v:IsA("Model") and v.PrimaryPart then
                Added(v.PrimaryPart)
            end
        end

        MetalDetector:Clean(collectionService:GetInstanceAddedSignal('hidden-metal'):Connect(function(v)
            if v:IsA("Model") and v.PrimaryPart then
                Added(v.PrimaryPart)
            end
        end))

        MetalDetector:Clean(collectionService:GetInstanceRemovedSignal('hidden-metal'):Connect(function(v)
            if v.PrimaryPart then
                Removed(v.PrimaryPart)
            end
        end))

        local _mdLastUpdate = 0
        MetalDetector:Clean(runService.RenderStepped:Connect(function()
            if not ESPToggle.Enabled then return end
            local _now = tick()
            if _now - _mdLastUpdate < 0.1 then return end
            _mdLastUpdate = _now
            
            for v, billboard in pairs(Reference) do
                if not v or not v.Parent then
                    Removed(v)
                    continue
                end

                local shouldShow = true

                if HoldingCheck.Enabled and not isHoldingMetalDetector() then
                    shouldShow = false
                end

                if shouldShow and DistanceCheck.Enabled and entitylib.isAlive then
                    local distance = (entitylib.character.RootPart.Position - v.Position).Magnitude
                    if distance < DistanceLimit.ValueMin or distance > DistanceLimit.ValueMax then
                        shouldShow = false
                    end
                end

                billboard.Enabled = shouldShow
            end
        end))
    end

    local function collectMetal(metalModel)
        local metalId = metalModel:GetAttribute('Id')
        if not metalId then return false end
        if collectedMetals[metalId] then return false end

        collectedMetals[metalId] = true

        local success = pcall(function()
            bedwars.Client:Get('CollectCollectableEntity').instance:FireServer({ id = metalId })
        end)

        if Animation.Enabled then
            local currentTick = tick()
            if not animationDebounce[metalId] or (currentTick - animationDebounce[metalId]) >= 0.5 then
                animationDebounce[metalId] = currentTick
                pcall(function()
                    bedwars.GameAnimationUtil:playAnimation(lplr, bedwars.AnimationType.SHOVEL_DIG)
                    bedwars.SoundManager:playSound(bedwars.SoundList.SNAP_TRAP_CONSUME_MARK)
                end)
            end
        end

        task.delay(2, function()
            collectedMetals[metalId] = nil
            animationDebounce[metalId] = nil
        end)
        
        return success
    end

    local function startAutoCollect()
        if collectionActive then return end
        collectionActive = true
        
        task.spawn(function()
            while MetalDetector.Enabled and CollectionToggle.Enabled and collectionActive do
                if not entitylib.isAlive then 
                    task.wait(0.5)
                    continue 
                end
                
                if LimitToItem.Enabled and not isHoldingMetalDetector() then 
                    task.wait(0.5)
                    continue 
                end
                
                local localPosition = entitylib.character.RootPart.Position
                local range = RangeSlider.Value
                local collectedThisCycle = false
								
				for _, v in collectionService:GetTagged('hidden-metal') do
					if not MetalDetector.Enabled or not CollectionToggle.Enabled or not collectionActive then 
						break 
					end
					
					if v:IsA("Model") and v.PrimaryPart then
						local distance = (localPosition - v.PrimaryPart.Position).Magnitude
						
						if distance <= range then
							if collectMetal(v) then
								collectedThisCycle = true
								if CollectionDelay.Enabled and DelaySlider.Value > 0 then
									task.wait(DelaySlider.Value)
								else
									task.wait(0.15)
								end
							end
						end
					end
				end
                
                task.wait(collectedThisCycle and 0.3 or 0.5)
            end
            
            collectionActive = false
        end)
    end

    local function stopAutoCollect()
        collectionActive = false
        table.clear(collectedMetals)
        table.clear(animationDebounce)
    end

    MetalDetector = vain.Categories.Kit:CreateModule({
        Name = 'Auto Metal',
        Function = function(callback)
            if callback then
                if ESPToggle.Enabled then 
                    setupESP() 
                end
                if CollectionToggle.Enabled then
                    startAutoCollect()
                end
            else
                stopAutoCollect()
                Folder:ClearAllChildren()
                table.clear(Reference)
                spawnQueue = {}
                lastNotification = 0
                notificationPending = false
            end
        end,
        Tooltip = 'automatically collects hidden metal and esp'
    })
    
    CollectionToggle = MetalDetector:CreateToggle({
        Name = 'Auto Collect',
        Default = true,
        Tooltip = 'automatically collect metals',
        Function = function(callback)
            if LimitToItem and LimitToItem.Object then LimitToItem.Object.Visible = callback end
            if Animation and Animation.Object then Animation.Object.Visible = callback end
            if CollectionDelay and CollectionDelay.Object then CollectionDelay.Object.Visible = callback end
            if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = callback end
            if DelaySlider and DelaySlider.Object then
                DelaySlider.Object.Visible = callback and CollectionDelay and CollectionDelay.Enabled
            end
            
            if MetalDetector.Enabled then
                if callback then
                    startAutoCollect()
                else
                    stopAutoCollect()
                end
            end
        end
    })
    
    LimitToItem = MetalDetector:CreateToggle({
        Name = 'Limit to Items',
        Default = true,
        Tooltip = 'only works when holding metal_detector'
    })
    
    Animation = MetalDetector:CreateToggle({
        Name = 'Animation',
        Default = true,
        Tooltip = 'play shovel dig animation and sound'
    })
    
    CollectionDelay = MetalDetector:CreateToggle({
        Name = 'Collection Delay',
        Default = false,
        Tooltip = 'add delay before collecting metal',
        Function = function(callback)
            if DelaySlider and DelaySlider.Object then
                DelaySlider.Object.Visible = callback
            end
        end
    })
    
    DelaySlider = MetalDetector:CreateSlider({
        Name = 'Delay',
        Min = 0,
        Max = 2,
        Default = 0.5,
        Decimal = 10,
        Suffix = 's',
        Visible = false,
        Tooltip = 'delay in seconds before collecting'
    })
    
    RangeSlider = MetalDetector:CreateSlider({
        Name = 'Range',
        Min = 1, 
        Max = 10,
        Default = 10,
        Decimal = 1,
        Suffix = ' studs',
        Tooltip = 'control distance you want to collect metal'
    })
    
    ESPToggle = MetalDetector:CreateToggle({
        Name = 'Metal ESP',
        Default = false,
        Tooltip = 'shows metal locations',
        Function = function(callback)
            if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = callback end
            if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = callback end
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            if HoldingCheck and HoldingCheck.Object then HoldingCheck.Object.Visible = callback end
            if DistanceCheck and DistanceCheck.Object then DistanceCheck.Object.Visible = callback end
            if DistanceLimit and DistanceLimit.Object then
                DistanceLimit.Object.Visible = (callback and DistanceCheck.Enabled)
            end

            if not callback then
                if ESPColor and ESPColor.Object then
                    ESPColor.Object.Visible = false
                end
                if DistanceLimit and DistanceLimit.Object then
                    DistanceLimit.Object.Visible = false
                end
            else
                if ESPBackground and ESPBackground.Enabled then
                    if ESPColor and ESPColor.Object then
                        ESPColor.Object.Visible = true
                    end
                end
                if DistanceCheck and DistanceCheck.Enabled then
                    if DistanceLimit and DistanceLimit.Object then
                        DistanceLimit.Object.Visible = true
                    end
                end
            end
            
            if MetalDetector.Enabled then
                if callback then setupESP() else
                    Folder:ClearAllChildren()
                    table.clear(Reference)
                end
            end
        end
    })
    
    ESPNotify = MetalDetector:CreateToggle({
        Name = 'Notify',
        Default = false,
        Tooltip = 'get notifications when metals spawn'
    })
    
    ESPBackground = MetalDetector:CreateToggle({
        Name = 'Background',
        Tooltip = 'Renders a background box behind the metal ESP icon',
        Default = true,
        Function = function(callback)
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    local blur = v:FindFirstChild("BlurEffect")
                    if blur then blur.Visible = callback end
                    v.ImageLabel.BackgroundTransparency = 1 - (callback and ESPColor.Opacity or 0)
                end
            end
        end
    })
    
    ESPColor = MetalDetector:CreateColorSlider({
        Name = 'Background Color',
        Tooltip = 'Color of the background box behind the metal ESP icon',
        DefaultValue = 0,
        DefaultOpacity = 0.5,
        Function = function(hue, sat, val, opacity)
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                    v.ImageLabel.BackgroundTransparency = 1 - opacity
                end
            end
        end,
        Darker = true
    })
    
    HoldingCheck = MetalDetector:CreateToggle({
        Name = 'Holding Detector',
        Default = false,
        Tooltip = 'only show esp when holding metal detector'
    })
    
    DistanceCheck = MetalDetector:CreateToggle({
        Name = 'Distance Check',
        Default = false,
        Tooltip = 'only show metals within distance range',
        Function = function(callback)
            if DistanceLimit and DistanceLimit.Object then
                DistanceLimit.Object.Visible = callback
            end
        end
    })
    
    DistanceLimit = MetalDetector:CreateTwoSlider({
        Name = 'Metal Distance',
        Min = 0,
        Max = 256,
        DefaultMin = 0,
        DefaultMax = 64,
        Darker = true,
        Tooltip = 'distance range for showing metals'
    })

    task.defer(function()
        if DelaySlider and DelaySlider.Object then
            DelaySlider.Object.Visible = CollectionDelay.Enabled  
        end
        if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = false end
        if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = false end
        if ESPColor and ESPColor.Object then ESPColor.Object.Visible = false end
        if HoldingCheck and HoldingCheck.Object then HoldingCheck.Object.Visible = false end
        if DistanceCheck and DistanceCheck.Object then DistanceCheck.Object.Visible = false end
        if DistanceLimit and DistanceLimit.Object then DistanceLimit.Object.Visible = false end
    end)
end)

kitRun(function()
    local AutoNoelle
    local Notify
    local FrostySlime
    local HealSlime
    local StickySlime
    local VoidSlime
    local Limit

    local function getSlimes()
    	local slimes = {}
    	local folder = workspace:FindFirstChild('SlimeModelFolder')
    	for _, v in folder:GetChildren() do
    		local data = v:FindFirstChild('SlimeData')
    		data = data and data.Value or nil

    		if data and data.Tamer.Value == lplr.UserId then
    			table.insert(slimes, {
    				Data = data, 
    				RootPart = v, 
    				Name = v.Name:gsub(`_{lplr.Name}`, ''):gsub('Slime', ' Slime')
    			})
    		end
    	end
    	return slimes
    end

    local function getPlayer(name)
    	for _, v in playersService:GetPlayers() do
    		if (`{v.DisplayName} ({v.Name})`) == name then
    			return v
    		end
    	end
    	return
    end

    AutoNoelle = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Noelle',
    	Tooltip = 'Automates the Noelle kit ability',
    	Function = function(call)
    		if call then
    			repeat
    				if entitylib.isAlive and (not Limit.Enabled or store.hand.tool and store.hand.tool.Name == 'slime_tamer_flute') then
    					local slimes = getSlimes()

    					for _, v in slimes do
    						local dropdown = AutoNoelle.Options[`{v.Name} Target`]
    						if dropdown then
    							local player = getPlayer(dropdown.Value)
    							if player and v.Data.Following.Value ~= player.UserId then
    								bedwars.Client:Get('RequestMoveSlime'):CallServerAsync({
    									slimeId = v.Data:GetAttribute('Id'),
    									targetPlayerUserId = player.UserId,
    								}):andThen(function(suc)
    									if suc then
    										v.Data.Following.Value = player.UserId
    										if Notify.Enabled then
    										end
    									end
    								end)
    							end
    						end
    					end
    				end
    				task.wait(0.5)
    			until not AutoNoelle.Enabled
    		end
    	end,
    	Tooltip = 'Automatically directs the slimes to the selected player\'s'
    })

    local friends = { 'None' }

    -- guard: the dropdown or its :Change method may not exist when this fires,
    -- which threw "attempt to call missing method 'Change' of table".
    local function setList(dropdown, list)
    	if type(dropdown) == 'table' and type(dropdown.Change) == 'function' then
    		pcall(function() dropdown:Change(list) end)
    	end
    end

    local function addConnection(plr)
    	if plr:GetAttribute('Team') == lplr:GetAttribute('Team') then
    		table.insert(friends, `{plr.DisplayName} ({plr.Name})`)
    		setList(FrostySlime, friends)
    		setList(HealSlime, friends)
    		setList(StickySlime, friends)
    		setList(VoidSlime, friends)
    	end

    	vain:Clean(plr:GetAttributeChangedSignal('Team'):Connect(function()
    		if plr:GetAttribute('Team') == lplr:GetAttribute('Team') then
    			table.insert(friends, `{plr.DisplayName} ({plr.Name})`)
    			setList(FrostySlime, friends)
    			setList(HealSlime, friends)
    			setList(StickySlime, friends)
    			setList(VoidSlime, friends)
    		end
    	end))
    end

    Notify = AutoNoelle:CreateToggle({ Name = 'Notify on direct' , Tooltip = 'Sends a notification each time a slime is successfully redirected to its target'})
    Limit = AutoNoelle:CreateToggle({ Name = 'Limit to item' , Tooltip = 'Only activates when a required item is in your hand'})
    FrostySlime = AutoNoelle:CreateDropdown({
    	Name = 'Frosty Slime Target',
    	List = {},
    	Tooltip = 'Player to direct frost slimes to',
    })
    HealSlime = AutoNoelle:CreateDropdown({
    	Name = 'Heal Slime Target',
    	List = {},
    	Tooltip = 'Player to direct heal slimes to',
    })
    StickySlime = AutoNoelle:CreateDropdown({
    	Name = 'Sticky Slime Target',
    	List = {},
    	Tooltip = 'Player to direct sticky slimes to',
    })
    VoidSlime = AutoNoelle:CreateDropdown({
    	Name = 'Void Slime Target',
    	List = {},
    	Tooltip = 'Player to direct void slimes to',
    })

    for _, v in playersService:GetPlayers() do
    	addConnection(v)
    end
    vain:Clean(playersService.PlayerAdded:Connect(addConnection))
end)

kitRun(function()
    local AutoNyx
    local Targets
    local Range

    AutoNyx = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Nyx',
    	Tooltip = 'Automates the Nyx kit stealth ability',
    	Function = function(call)
    		if call then
    			AutoNyx:Clean(vainEvents.EntityDamageEvent.Event:Connect(function(damageTable)
    				if damageTable.damageType == 0 and damageTable.fromEntity and damageTable.fromEntity.Name == lplr.Name and entitylib.EntityPosition({
    					Range = Range.Value,
    					Part = 'RootPart',
    					Players = Targets.Players.Enabled,
    					NPCs = Targets.NPCs.Enabled,
    				}) and bedwars.AbilityController:canUseAbility('midnight') then
    					bedwars.AbilityController:useAbility('midnight')
    				end
    			end))
    		end
    	end,
    	Tooltip = 'Automatically uses the "midnight" ability when meleeing a target'
    })

    Targets = AutoNyx:CreateTargets({
    	Tooltip = 'Configure which types of targets to include',
    	Players = true,
    	NPCs = false
    })
    Range = AutoNyx:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs to a target before using the ability',
    	Min = 1,
    	Max = 50,
    	Default = 15,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end
    })
end)

kitRun(function()
    local AutoRaven
    local Mode
    local Range
    local Targets

    AutoRaven = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Raven',
    	Tooltip = 'Automates the Raven kit: spawns the raven and detonates it on a nearby target',
    	Function = function(call)
    		if call then
    			repeat
    				if entitylib.isAlive and store.equippedKit == 'raven' then
    					local target = entitylib.EntityPosition({
    						Part = 'RootPart',
    						Range = Range.Value,
    						Players = Targets.Players.Enabled,
    						NPCs = Targets.NPCs.Enabled,
    						Wallcheck = Targets.Walls.Enabled,
    					})
    					if target then
    						if (Mode.Value == 'Spawn & Detonate' or Mode.Value == 'Spawn Only') and bedwars.AbilityController:canUseAbility('RAVEN_SPAWN') then
    							bedwars.AbilityController:useAbility('RAVEN_SPAWN')
    							task.wait(0.2)
    						end
    						if (Mode.Value == 'Spawn & Detonate' or Mode.Value == 'Detonate Only') and bedwars.AbilityController:canUseAbility('RAVEN_DETONATE') then
    							bedwars.AbilityController:useAbility('RAVEN_DETONATE')
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoRaven.Enabled
    		end
    	end,
    	Tooltip = 'Automatically spawns and detonates the raven on nearby enemies'
    })

    Mode = AutoRaven:CreateDropdown({
    	Name = 'Mode',
    	List = {'Spawn & Detonate', 'Spawn Only', 'Detonate Only'},
    	Default = 'Spawn & Detonate',
    	Tooltip = 'Which parts of the raven ability to automate',
    	ItemTooltips = {
    		['Spawn & Detonate'] = 'Spawns the raven then detonates it on the target',
    		['Spawn Only'] = 'Only spawns the raven, you detonate manually',
    		['Detonate Only'] = 'Only detonates an already-spawned raven',
    	},
    })
    Targets = AutoRaven:CreateTargets({
    	Tooltip = 'Configure which types of targets to include',
    	Players = true,
    	NPCs = false,
    	Walls = true,
    })
    Range = AutoRaven:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs to a target',
    	Min = 1,
    	Max = 60,
    	Default = 30,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end
    })
end)

kitRun(function()
    local AutoJellyfish
    local Range

    AutoJellyfish = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Jellyfish',
    	Tooltip = 'Automatically picks up your placed jellyfish when enemies get close to them',
    	Function = function(call)
    		if call then
    			local pickupRemote = bedwars.Client:Get('RequestPickupJellyfish')
    			repeat
    				if entitylib.isAlive and store.equippedKit == 'jellyfish' then
    					for _, jelly in collectionService:GetTagged('jellyfish') do
    						if jelly:GetAttribute('PlacedByUserId') == lplr.UserId and jelly.PrimaryPart then
    							local enemy = entitylib.EntityPosition({
    								Origin = jelly.PrimaryPart.Position,
    								Part = 'RootPart',
    								Range = Range.Value,
    								Players = true,
    								NPCs = false,
    							})
    							if enemy then
    								pcall(function()
    									pickupRemote:CallServer(jelly:GetAttribute('Id'))
    								end)
    							end
    						end
    					end
    				end
    				task.wait(0.2)
    			until not AutoJellyfish.Enabled
    		end
    	end,
    	Tooltip = 'Automatically retrieves your jellyfish when an enemy approaches'
    })

    Range = AutoJellyfish:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'How close an enemy must be to a jellyfish before it is picked up',
    	Min = 1,
    	Max = 30,
    	Default = 12,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end
    })
end)

kitRun(function()
    local AutoPyro
    -- The flamethrower upgrade tiers, from the game's flamethrower-upgrade module.
    local pyroMeta
    local function pyroUpgradeMeta()
    	if pyroMeta then return pyroMeta end
    	pcall(function()
    		local module = replicatedStorage.TS:FindFirstChild('flamethrower-upgrade', true)
    		pyroMeta = module and require(module).FlamethrowerUpgradeMeta
    	end)
    	return pyroMeta
    end

    local list = {'Range', 'Heat', 'Power'}

    AutoPyro = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Pyro',
    	Tooltip = 'Automates the Pyro kit fire ability',
    	Function = function(call)
    		if call then
    			repeat
    				local flamethrower = getItem('flamethrower')
    				if flamethrower then
    					for _, v in list do
    						if not AutoPyro.Options['Buy ' .. v].Enabled then
    							table.remove(list, table.find(list, v))
    						end
    					end

    					for _, v in list do
    						v = v:lower()
    						local value = flamethrower.tool:GetAttribute(v) or -1
    						if value < 3 then
    							local meta = pyroUpgradeMeta()
    							local nextUpgrade = meta and meta[v] and meta[v].tiers[value + 2]
    							if nextUpgrade then
    								local currency = getItem(nextUpgrade.currency)
    								if currency and currency.amount >= nextUpgrade.price then
    									bedwars.Client:Get('UpgradeFlamethrower'):CallServer(v)
    									task.wait(0.1)
    								end
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoPyro.Enabled
    		end
    	end,
    	Tooltip = 'Automatically upgrades flamethrower'
    })

    for _, i in list do
    	AutoPyro:CreateToggle({
    		Name = 'Buy ' .. i,
    		Tooltip = 'Automatically upgrades this flamethrower ability when you have enough currency',
    		Default = true
    	})
    end
end)

kitRun(function()
    local AutoRamil
    local Range
    local Sorts
    local Targets
    local UseTornando
    local TonradoRange

    AutoRamil = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Ramil',
    	Tooltip = 'Automates the Ramil tornado placement',
    	Function = function(callback)
    		if callback then
    			repeat
    				if entitylib.isAlive and store.equippedKit == 'airbender' then
    					local localPosition = entitylib.character.RootPart.Position
    					local ent = entitylib.EntityPosition({
    						Origin = localPosition,
    						Range = (UseTornando.Enabled and TonradoRange.Value > Range.Value and TonradoRange.Value or Range.Value),
    						Wallcheck = Targets.Walls.Enabled,
    						Players = Targets.Players.Enabled,
    						NPCs = Targets.NPCs.Enabled,
    						Sort = sortmethods[Sorts.Value],
    					})

    					if ent then
    						if (localPosition - ent.RootPart.Position).Magnitude <= Range.Value and bedwars.AbilityController:canUseAbility('airbender_tornado') then
    							bedwars.AbilityController:useAbility('airbender_tornado')
    						end

    						if UseTornando.Enabled and (localPosition - ent.RootPart.Position).Magnitude <= TonradoRange.Value and bedwars.AbilityController:canUseAbility('airbender_moving_tornado') then
    							bedwars.AbilityController:useAbility('airbender_moving_tornado')
    						end
    					end
    				end
    				task.wait()
    			until not AutoRamil.Enabled
    		end
    	end,
    	Tooltip = 'Automatically uses the ramil kit'
    })

    Targets = AutoRamil:CreateTargets({
    	Tooltip = 'Configure which types of targets to include',
    	Players = true,
    	NPCs = false
    })
    local methods = {'Damage', 'Distance'}
    for i in sortmethods do
    	if not table.find(methods, i) then
    		table.insert(methods, i)
    	end
    end
    Sorts = AutoRamil:CreateDropdown({
    	Name = 'Target Mode',
    	Tooltip = 'Selects how targets are prioritized and selected',
    	List = methods,
    	Default = 'Distance',
    	ItemTooltips = {
    		Distance = 'Targets the closest enemy by stud distance',
    		Health = 'Targets the enemy with the lowest remaining health',
    		Angle = 'Targets the enemy closest to your look direction',
    		Cursor = 'Targets the enemy nearest to your mouse cursor',
    		Damage = 'Targets the enemy who most recently took damage',
    		Threat = 'Targets the enemy judged to be the greatest combat threat',
    		Kit = 'Prioritizes dangerous kit users (Hannah, Spirit Assassin, etc.)',
    	}
    })
    Range = AutoRamil:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 25,
    	Default = 25,
    	Suffix = function(val)
    		return val >= 1 and 'studs' or 'stud'
    	end
    })
    UseTornando = AutoRamil:CreateToggle({
    	Name = 'Use Moving Tornado',
    	Tooltip = 'Places a moving tornado instead of a static one',
    	Function = function(call)
    		pcall(function()
    			TonradoRange.Object.Visible = call
    		end)
    	end
    })
    TonradoRange = AutoRamil:CreateSlider({
    	Name = 'Tornado Range',
    	Tooltip = 'Distance in studs for tornado placement',
    	Min = 1,
    	Max = 35,
    	Default = 25,
    	Darker = true,
    	Visible = false,
    	Suffix = function(val)
    		return val >= 1 and 'studs' or 'stud'
    	end
    })
end)

kitRun(function()
    local AutoSheep
    local Delay
    local Range

    AutoSheep = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Sheep Herder',
    	Tooltip = 'Automates the Sheep Herder kit',
    	Function = function(callback)
    		if callback then
    			repeat
    				if entitylib.isAlive then
    					local localPosition = entitylib.character.RootPart.Position
    					local model = workspace:FindFirstChild('SheepModel')

    					for _, v in model:GetChildren() do
    						if v.PrimaryPart and (localPosition - v.PrimaryPart.Position).Magnitude <= Range.Value then
    							if Delay.Value > 0 then
    								task.wait(Delay.Value)
    							end
    							bedwars.Client:GetNamespace('SheepHerder'):Get('TameSheep'):SendToServer(v.SheepData.Value)
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoSheep.Enabled
    		end
    	end,
    	Tooltip = 'Automatically tames sheep at a long range'
    })

    Range = AutoSheep:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 20,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end,
    	Default = 20
    })
    Delay = AutoSheep:CreateSlider({
    	Name = 'Delay',
    	Tooltip = 'Seconds between consecutive actions',
    	Min = 0,
    	Max = 1,
    	Default = 0.1,
    	Decimal = 100
    })
end)

kitRun(function()
    local AutoStar
    local Streamer
    local Range
    local Animation
    local Delay

    AutoStar = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Star Collector',
    	Tooltip = 'Automates the Star Collector kit — collects stars automatically',
    	Function = function(callback)
    		if callback then
    			AutoStar:Clean(proximityPromptService.PromptShown:Connect(function(prompt)
    				if Streamer.Enabled then
    					if prompt.Name == 'stars_ProximityPrompt' then
    						task.wait(0.1)
    						prompt:InputHoldBegin()
    					end
    				end
    			end))

    			repeat
    				if not Streamer.Enabled and entitylib.isAlive then
    					local localPosition = entitylib.character.RootPart.Position
    					for i, v in collectionService:GetTagged('stars') do
    						if
    							tick() > (Delay[v] or 0)
    							and v.PrimaryPart
    							and (localPosition - v.PrimaryPart.Position).Magnitude <= Range.Value
    						then
    							if Delay.Value > 0 then
    								task.wait(Delay.Value)
    							end

    							if (localPosition - v.PrimaryPart.Position).Magnitude <= Range.Value then
    								if Animation.Enabled then
    									bedwars.GameAnimationUtil:playAnimation(lplr.Character, bedwars.AnimationType.PUNCH)
    									bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_USE_ITEM)
    								end
    								bedwars.StarCollectorController:collectEntity(lplr, v, v.Name)
    								Delay[v] = tick() + 1
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoStar.Enabled
    		end
    	end,
    	Tooltip = 'Automatically collects stars'
    })

    Streamer = AutoStar:CreateToggle({
    	Name = 'Streamer mode',
    	Tooltip = 'Enables or disables streamer mode',
    	Function = function(call)
    		pcall(function()
    			Delay.Object.Visible = not call
    			Range.Object.Visible = not call
    			Animation.Object.Visible = not call
    		end)
    	end,
    	Tooltip = 'Hides delay, range, and animation settings from the UI — useful for streaming'
    })
    Animation = AutoStar:CreateToggle({
    	Name = 'Animation',
    	Default = true,
    	Tooltip = 'Plays the collect animation'
    })
    Range = AutoStar:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 20,
    	Default = 12,
    	Suffix = function(val)
    		return val > 1 and 'studs' or 'stud'
    	end
    })
    Delay = AutoStar:CreateSlider({
    	Name = 'Delay',
    	Tooltip = 'Seconds between consecutive actions',
    	Min = 0,
    	Max = 1,
    	Suffix = function(val)
    		return val > 1 and 'secs' or 'sec'
    	end,
    	Default = 0.2,
    	Decimal = 100
    })
end)

kitRun(function()
    --[[
        Taliyah, as the kit actually works.

        The chicken price is two attributes on Workspace - ChickenPrice and ChickenCurrency -
        that the server moves around through the match. The currency is only ever iron or
        emerald: a price that climbs past 100 iron is usually turned into a hundredth of
        that in emeralds. The shop sells chickens back for that price (the "Sell chicken"
        entry, paid for with one deployed chicken), sells eggs for the same price, and sells
        nest upgrades.

        The old module looked the price up through a TaliyahUtil Vain never had, so it threw
        on its first pass and never did anything; it also sent a sale every tenth of a second
        whether or not you had a chicken, and had a diamond setting the game never uses.
        This reads the attributes directly, only sells chickens you actually hold, and keeps
        iron and emerald prices apart because they are on completely different scales.
    ]]
    local AutoTaliyah
    local AutoSell, SellIron, MinIron, SellEmerald, MinEmerald, Keep
    local BuyEggs, MaxEggPrice, MaxEggs, KeepIron
    local AutoNest, PriceAlert, Notify
    local EggESP, EnemyEggs, AutoCollectEggs
    local eggFolder, eggLabels = nil, {}
    local lastEggScan = 0

    --[[
        Taliyah's eggs: placed chicken_egg_block crops carrying PlacedByUserId, tagged
        HarvestableCrop once ready (crop-meta, CropController). Egg ESP labels each one in
        its owner's team colour, saying when it is ready; Auto Collect picks your own ready
        ones near you with the same CropHarvest request the game's prompt sends.
    ]]
    local function eggOwner(block)
        return playersService:GetPlayerByUserId(tonumber(block:GetAttribute('PlacedByUserId')) or 0)
    end

    local function clearEggs()
        for block, label in eggLabels do label:Destroy() end
        table.clear(eggLabels)
    end

    local function updateEggs()
        if os.clock() - lastEggScan < 1 then return end
        lastEggScan = os.clock()
        local ready = {}
        for _, block in collectionService:GetTagged('HarvestableCrop') do ready[block] = true end
        local seen = {}
        local here = entitylib.isAlive and entitylib.character.RootPart.Position
        local store = bedwars.BlockController:getStore()
        for _, position in store:getAllBlockPositions() do
            local block = store:getBlockAt(position)
            if block and block.Name == 'chicken_egg_block' then
                local owner = eggOwner(block)
                local mine = owner == lplr or (owner and tostring(owner:GetAttribute('Team')) == tostring(lplr:GetAttribute('Team')))
                if on(AutoCollectEggs) and owner == lplr and ready[block] and here and (block.Position - here).Magnitude <= 18 then
                    task.spawn(pcall, function()
                        bedwars.Client:Get('CropHarvest'):CallServer({position = position})
                    end)
                end
                if on(EggESP) and (mine or on(EnemyEggs)) then
                    seen[block] = true
                    local label = eggLabels[block]
                    if not label then
                        label = Instance.new('BillboardGui')
                        label.Adornee = block
                        label.Size = UDim2.fromOffset(90, 18)
                        label.StudsOffsetWorldSpace = Vector3.new(0, 2, 0)
                        label.AlwaysOnTop = true
                        label.Parent = eggFolder
                        local text = Instance.new('TextLabel')
                        text.Name = 'Text'
                        text.BackgroundTransparency = 1
                        text.Size = UDim2.fromScale(1, 1)
                        text.Font = Enum.Font.GothamBold
                        text.TextSize = 12
                        text.TextStrokeTransparency = 0.4
                        text.Parent = label
                        eggLabels[block] = label
                    end
                    label.Text.Text = ready[block] and 'Egg READY' or 'Egg'
                    label.Text.TextColor3 = owner and owner.Team and owner.TeamColor.Color or Color3.new(1, 1, 1)
                end
            end
        end
        for block, label in eggLabels do
            if not seen[block] then
                label:Destroy()
                eggLabels[block] = nil
            end
        end
    end
    local busyUntil = 0
    local lastAlerted

    local NESTS = {
        {itemType = 'iron_chicken_nest', currency = 'iron', price = 60, name = 'Iron Nest'},
        {itemType = 'diamond_chicken_nest', currency = 'emerald', price = 2, name = 'Diamond Nest'},
        {itemType = 'emerald_chicken_nest', currency = 'emerald', price = 4, name = 'Emerald Nest'},
        {itemType = 'void_chicken_incubator', currency = 'emerald', price = 6, name = 'Void Incubator'}
    }

    local function on(setting)
        return setting ~= nil and setting.Enabled
    end

    local function price()
        local amount = workspace:GetAttribute('ChickenPrice')
        local currency = workspace:GetAttribute('ChickenCurrency')
        return type(amount) == 'number' and amount or 30, type(currency) == 'string' and currency or 'iron'
    end

    local function count(itemType)
        local item = getItem(itemType)
        return item and item.amount or 0
    end

    local function nearShop()
        if not entitylib.isAlive then return nil end
        local here = entitylib.character.RootPart.Position
        for _, v in store.shop do
            if v.Shop and v.RootPart and (v.RootPart.Position - here).Magnitude <= 20 then
                return v.Id
            end
        end
    end

    local function purchased(itemType)
        local map = bedwars.BedwarsShopController and bedwars.BedwarsShopController.alreadyPurchasedMap
        return map ~= nil and map[itemType] == true
    end

    -- The shop's own entry when it can give one, which carries the live price; a minimal
    -- stand-in otherwise, since the server works the purchase out from the item type.
    local function shopItem(itemType, fallbackPrice, fallbackCurrency)
        local ok, item = pcall(function()
            return bedwars.Shop.getShopItem(itemType, lplr)
        end)
        if ok and type(item) == 'table' then return item end
        return {itemType = itemType, amount = 1, price = fallbackPrice, currency = fallbackCurrency}
    end

    -- One purchase at a time, waited on, so nothing is sent twice while the first is in
    -- flight.
    local function buy(shopId, item, message)
        busyUntil = os.clock() + 1
        bedwars.Client:Get('BedwarsPurchaseItem'):CallServerAsync({
            shopItem = item,
            shopId = shopId
        }):andThen(function(suc)
            busyUntil = 0
            if suc then
                bedwars.SoundManager:playSound(bedwars.SoundList.BEDWARS_PURCHASE_ITEM)
                bedwars.Store:dispatch({
                    type = 'BedwarsAddItemPurchased',
                    itemType = item.itemType
                })
                bedwars.BedwarsShopController.alreadyPurchasedMap[item.itemType] = true
                if on(Notify) and message then
                    notif('Auto Taliyah', message, 3)
                end
            end
        end)
    end

    local function sellWorth(amount, currency)
        if currency == 'emerald' then
            return on(SellEmerald) and amount >= MinEmerald.Value
        end
        return on(SellIron) and amount >= MinIron.Value
    end

    local function label(amount, currency)
        local meta = bedwars.ItemMeta[currency]
        return amount .. ' ' .. (meta and meta.displayName or currency)
    end

    local function step(shopId)
        local amount, currency = price()

        -- Sell first: a good price is the moment that does not come back.
        if on(AutoSell) and sellWorth(amount, currency) and count('chicken_deploy') > Keep.Value then
            buy(shopId, shopItem('chicken_shop_item', 1, 'chicken_deploy'), 'Sold a chicken for ' .. label(amount, currency))
            return
        end

        -- Eggs only on iron: an emerald price is the expensive end of the range by definition.
        if on(BuyEggs) and currency == 'iron' and amount <= MaxEggPrice.Value
            and count('chicken_egg') < MaxEggs.Value
            and count('iron') - amount >= KeepIron.Value then
            buy(shopId, shopItem('chicken_egg', amount, currency), 'Bought an egg for ' .. label(amount, currency))
            return
        end

        -- The next nest you do not have yet, once you can pay for it.
        if on(AutoNest) then
            for _, nest in NESTS do
                if not purchased(nest.itemType) then
                    if count(nest.currency) >= nest.price then
                        buy(shopId, shopItem(nest.itemType, nest.price, nest.currency), 'Bought the ' .. nest.name)
                    end
                    return
                end
            end
        end
    end

    AutoTaliyah = vain.Categories.Kit:CreateModule({
        Name = 'Auto Taliyah',
        Tooltip = 'Sells chickens at good prices, buys cheap eggs and nests',
        Function = function(callback)
            if callback then
                -- Told when the price moves somewhere worth selling at, whether or not you
                -- are at a shop to do it.
                AutoTaliyah:Clean(workspace:GetAttributeChangedSignal('ChickenPrice'):Connect(function()
                    if not (on(PriceAlert) and store.equippedKit == 'taliyah') then return end
                    local amount, currency = price()
                    local key = amount .. currency
                    if sellWorth(amount, currency) and key ~= lastAlerted then
                        lastAlerted = key
                        notif('Auto Taliyah', 'Chickens sell for ' .. label(amount, currency), 5)
                    end
                end))

                eggFolder = Instance.new('Folder')
                eggFolder.Name = 'TaliyahEggs'
                eggFolder.Parent = vain.gui
                AutoTaliyah:Clean(eggFolder)
                AutoTaliyah:Clean(runService.Heartbeat:Connect(function()
                    if (on(EggESP) or on(AutoCollectEggs)) then
                        pcall(updateEggs)
                    elseif next(eggLabels) then
                        clearEggs()
                    end
                end))

                repeat
                    pcall(function()
                        if store.equippedKit ~= 'taliyah' or os.clock() < busyUntil then return end
                        local shopId = nearShop()
                        if shopId then step(shopId) end
                    end)
                    task.wait(0.25)
                until not AutoTaliyah.Enabled
            else
                busyUntil, lastAlerted = 0, nil
                clearEggs()
            end
        end
    })

    AutoSell = AutoTaliyah:CreateToggle({
        Name = 'Auto Sell',
        Tooltip = 'Sells chickens at a shop when the price is right',
        Default = true,
        Function = function(callback)
            for _, setting in {SellIron, MinIron, SellEmerald, MinEmerald, Keep} do
                if setting and setting.Object then setting.Object.Visible = callback end
            end
        end
    })
    SellIron = AutoTaliyah:CreateToggle({
        Name = 'Sell For Iron',
        Tooltip = 'Sells when the price is in iron',
        Default = true,
        Darker = true
    })
    MinIron = AutoTaliyah:CreateSlider({
        Name = 'Min Iron Price',
        Tooltip = 'Lowest iron price to sell at',
        Min = 1,
        Max = 99,
        Default = 40,
        Darker = true
    })
    SellEmerald = AutoTaliyah:CreateToggle({
        Name = 'Sell For Emerald',
        Tooltip = 'Sells when the price is in emeralds',
        Default = true,
        Darker = true
    })
    MinEmerald = AutoTaliyah:CreateSlider({
        Name = 'Min Emerald Price',
        Tooltip = 'Lowest emerald price to sell at',
        Min = 1,
        Max = 12,
        Default = 2,
        Darker = true
    })
    Keep = AutoTaliyah:CreateSlider({
        Name = 'Keep Chickens',
        Tooltip = 'Never sells the last this many',
        Min = 0,
        Max = 8,
        Default = 0,
        Darker = true
    })
    BuyEggs = AutoTaliyah:CreateToggle({
        Name = 'Buy Eggs',
        Tooltip = 'Buys eggs when the price is cheap in iron',
        Function = function(callback)
            for _, setting in {MaxEggPrice, MaxEggs, KeepIron} do
                if setting and setting.Object then setting.Object.Visible = callback end
            end
        end
    })
    MaxEggPrice = AutoTaliyah:CreateSlider({
        Name = 'Max Egg Price',
        Tooltip = 'Highest iron price to buy an egg at',
        Min = 1,
        Max = 99,
        Default = 15,
        Darker = true,
        Visible = false
    })
    MaxEggs = AutoTaliyah:CreateSlider({
        Name = 'Max Eggs',
        Tooltip = 'Stops buying once you hold this many',
        Min = 1,
        Max = 16,
        Default = 4,
        Darker = true,
        Visible = false
    })
    KeepIron = AutoTaliyah:CreateSlider({
        Name = 'Keep Iron',
        Tooltip = 'Never spends iron below this',
        Min = 0,
        Max = 200,
        Default = 0,
        Darker = true,
        Visible = false
    })
    AutoNest = AutoTaliyah:CreateToggle({
        Name = 'Auto Nest',
        Tooltip = 'Buys the next nest upgrade when you can afford it'
    })
    PriceAlert = AutoTaliyah:CreateToggle({
        Name = 'Price Alert',
        Tooltip = 'Tells you when the price reaches your sell price'
    })
    Notify = AutoTaliyah:CreateToggle({
        Name = 'Notify',
        Tooltip = 'Tells you about each sale and purchase'
    })
    EggESP = AutoTaliyah:CreateToggle({
        Name = 'Egg ESP',
        Tooltip = 'Labels chicken eggs and says when they are ready',
        Default = true,
        Function = function(callback)
            if EnemyEggs and EnemyEggs.Object then EnemyEggs.Object.Visible = callback end
        end
    })
    EnemyEggs = AutoTaliyah:CreateToggle({
        Name = 'Enemy Eggs',
        Tooltip = 'Also labels other teams\' eggs',
        Default = true,
        Darker = true
    })
    AutoCollectEggs = AutoTaliyah:CreateToggle({
        Name = 'Auto Collect Eggs',
        Tooltip = 'Picks up your ready eggs when you are near them'
    })
end)

kitRun(function()
    local AutoUma
    local Range
    local Limit
    local Animation
    local AutoSummon
    local HealSpirit
    local AttackSpirit
    local TargetItemDrops
    local Diamond
    local Emerald

    local function getAttackData()
    	if Limit.Enabled then
    		local tool = (store.hand.tool and store.hand.tool.Name == 'spirit_staff') and store.hand.tool or nil
    		return tool, tool and getHotbar(tool) or nil
    	end
    	for i, v in store.inventory.inventory.items do
    		if v.itemType == 'spirit_staff' then
    			switchItem(v, 0)
    			return v, i
    		end
    	end
    	return
    end

    local function getDrops(localPosition, ItemDrops)
    	local drop, lastmag = nil, Range.Value + 1
    	for i, v in ItemDrops do
    		if v.Name == 'emerald' and Emerald.Enabled or v.Name == 'diamond' and Diamond.Enabled then
    			local magnitude = (localPosition - v.Position).Magnitude
    			if magnitude <= lastmag and not entitylib.Wallcheck(localPosition, v.Position, {gameCamera, lplr.Character, v}) then
    				drop, lastmag = v, magnitude
    			end
    		end
    	end
    	return drop
    end

    AutoUma = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Uma',
    	Tooltip = 'Automates the Uma kit spirit abilities',
    	Function = function(call)
    		if call then
    			repeat
    				local items = collection('ItemDrop', AutoUma)
    				local staff = getAttackData()
    				if staff then
    					if TargetItemDrops.Enabled then
    						local attackSpirits = (lplr:GetAttribute('ReadySummonedAttackSpirits') or 0)
    						local healSpirits = (lplr:GetAttribute('ReadySummonedHealSpirits') or 0)

    						if AutoSummon.Enabled then
    							if AttackSpirit.Enabled and attackSpirits < 1 and getItem('summon_stone') then
    								bedwars.AbilityController:useAbility('summon_attack_spirit')
    							end

    							if HealSpirit.Enabled and healSpirits < 1 and getItem('summon_stone') then
    								bedwars.AbilityController:useAbility('summon_heal_spirit')
    							end
    						end

    						if (healSpirits + attackSpirits) > 0 then
    							local localPosition = entitylib.character.RootPart.Position
    							local drop = getDrops(localPosition, items)

    							if drop then
    								local shootpos = localPosition + Vector3.new(0, 2, 0)
    								local dir = CFrame.lookAt(localPosition, drop.Position + Vector3.new(0, (localPosition - drop.Position).Magnitude / 5, 0)).LookVector * 100

    								bedwars.Client:Get(remotes.FireProjectile).instance:InvokeServer(
    									staff,
    									nil,
    									attackSpirits > 0 and 'attack_spirit' or 'heal_spirit',
    									shootpos,
    									localPosition,
    									dir,
    									httpService:GenerateGUID(),
    									{
    										drawDurationSeconds = 1,
    										shotId = httpService:GenerateGUID(false),
    									},
    									workspace:GetServerTimeNow() - 0.045
    								)

    								if Animation.Enabled then
    									bedwars.GameAnimationUtil:playAnimation(lplr.Character, bedwars.AnimationType.WIZARD_BALL_CAST)
    									bedwars.SoundManager:playSound(bedwars.SoundList.SPIRIT_SUMMONER_CHANGE_AFFINITY, {})
    								end

    								task.wait(1.5)
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoUma.Enabled
    		end
    	end,
    	Tooltip = 'Automatically uses uma kit'
    })

    Range = AutoUma:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 80,
    	Default = 50,
    	Decimal = 5,
    	Suffix = function(val)
    		return val >= 2 and 'studs' or 'stud'
    	end
    })
    Animation = AutoUma:CreateToggle({
    	Name = 'Animation',
    	Tooltip = 'Shows the kit ability animation when activated',
    	Default = true
    })
    Limit = AutoUma:CreateToggle({
    	Name = 'Limit to item',
    	Tooltip = 'Only activates when a required item is in your hand',
    	Default = true
    })
    AutoSummon = AutoUma:CreateToggle({
    	Name = 'Auto Summon',
    	Tooltip = 'Enables or disables auto summon',
    	Function = function(call)
    		pcall(function()
    			AttackSpirit.Object.Visible = call
    			HealSpirit.Object.Visible = call
    		end)
    	end,
    	Tooltip = 'Automatically summons a spirit companion to assist you in combat'
    })
    HealSpirit = AutoUma:CreateToggle({
    	Name = 'Use heal spirit',
    	Tooltip = 'Automatically deploys the healing spirit',
    	Default = true,
    	Visible = false,
    	Darker = true
    })
    AttackSpirit = AutoUma:CreateToggle({
    	Name = 'Use attack spirit',
    	Tooltip = 'Automatically deploys the attack spirit',
    	Default = true,
    	Visible = false,
    	Darker = true
    })
    TargetItemDrops = AutoUma:CreateToggle({
    	Name = 'Target item drops',
    	Tooltip = 'Targets item drops for automatic collection',
    	Default = true,
    	Function = function(call)
    		pcall(function()
    			Emerald.Object.Visible = call
    			Diamond.Object.Visible = call
    		end)
    	end
    })
    Emerald = AutoUma:CreateToggle({
    	Name = 'Emerald',
    	Tooltip = 'Includes emerald resources',
    	Darker = true,
    	Default = true
    })
    Diamond = AutoUma:CreateToggle({
    	Name = 'Diamond',
    	Tooltip = 'Includes diamond resources',
    	Darker = true,
    	Default = true
    })
end)

kitRun(function()
    local AutoWhisper
    local PlayerDropdown
    local AutoHeal
    local AutoHealSlider
    local AutoFly
    local LimitToItem
    local RefreshButton
    local running = false
    local healRunning = false
    local flyRunning = false
    local currentTarget = nil
    local currentMountedPlayer = nil
    local fallCheckTimer = 0
    local hasActivatedFly = false
    
    local function isHoldingOwlOrb()
        if not entitylib.isAlive then return false end
        
        local inventory = store.inventory
        if inventory and inventory.inventory and inventory.inventory.hand then
            local handItem = inventory.inventory.hand
            if handItem and handItem.itemType == "owl_orb" then
                return true
            end
        end
        return false
    end
    
    local function getMountedPlayer()
        local owlTarget = lplr:GetAttribute('OwlTarget')
        if owlTarget then
            return playersService:GetPlayerByUserId(owlTarget)
        end
        return nil
    end
    
    local function mountBirdToPlayer(targetPlayer)
        if not targetPlayer or not targetPlayer.Character then return false end
        
        if LimitToItem.Enabled and not isHoldingOwlOrb() then
            return false
        end
        
        local success = false
        pcall(function()
            local result = bedwars.Client:Get('SummonOwl').instance:InvokeServer(targetPlayer)
            
            if result then
            task.wait(0.05)
            
            pcall(function()
    			bedwars.Client:Get('UseAbility').instance:FireServer("SUMMON_OWL")
			end)
                
                currentMountedPlayer = targetPlayer
                success = true
            end
        end)
        
        return success
    end
    
    local function demountOwl()
        pcall(function()
            bedwars.Client:Get('UseAbility').instance:FireServer("DEACTIVE_OWL")
            
            task.wait(0.05)
            
            bedwars.Client:Get('RemoveOwl').instance:FireServer()
        end)
        
        currentMountedPlayer = nil
    end
    
    local function healTarget()
        pcall(function()
            replicatedStorage:WaitForChild("events-@easy-games/game-core:shared/game-core-networking@getEvents.Events"):WaitForChild("useAbility"):FireServer("OWL_HEAL")
        end)
    end
    
    local function isFalling(player)
        if not player or not player.Character or not player.Character.PrimaryPart then
            return false
        end
        
        local velocity = player.Character.PrimaryPart.AssemblyLinearVelocity.Y
        return velocity < -20
    end
    
	local voidRayParams = RaycastParams.new()
	voidRayParams.FilterType = Enum.RaycastFilterType.Blacklist
	voidRayParams.RespectCanCollide = true

	local function isAboveVoid(player)
		if not player or not player.Character or not player.Character.PrimaryPart then
			return false
		end
		
		local rayOrigin = player.Character.PrimaryPart.Position
		local rayDirection = Vector3.new(0, -1000, 0)
		
		voidRayParams.FilterDescendantsInstances = {player.Character, gameCamera}
		
		local rayResult = workspace:Raycast(rayOrigin, rayDirection, voidRayParams)
		
		if not rayResult then
			return true
		end
		
		return rayResult.Distance > 200
	end
    
    local function activateFly()
        pcall(function()
            replicatedStorage:WaitForChild("events-@easy-games/game-core:shared/game-core-networking@getEvents.Events"):WaitForChild("useAbility"):FireServer("OWL_LIFT")
            
            hasActivatedFly = true
            task.spawn(function()
                task.wait(85)
                hasActivatedFly = false
            end)
        end)
    end
    
    AutoWhisper = vain.Categories.Kit:CreateModule({
        Name = "Auto Whisper",
        Function = function(callback)
            running = callback
            healRunning = callback
            flyRunning = callback
            
            if callback then
                task.spawn(function()
                    while running do
                        if LimitToItem.Enabled and not isHoldingOwlOrb() then
                            task.wait(0.2)
                            continue
                        end
                        
                        local targetPlayer = playersService:FindFirstChild(PlayerDropdown.Value)
                        if targetPlayer then
                            currentTarget = targetPlayer
                            
                            local mountedTo = getMountedPlayer()
                            
                            if mountedTo ~= targetPlayer then
                                if mountedTo and mountedTo ~= targetPlayer then
                                    demountOwl()
                                    task.wait(0.3)
                                end
                                
                                if not mountedTo or mountedTo ~= targetPlayer then
                                    local success = mountBirdToPlayer(targetPlayer)
                                    if not success then
                                        task.wait(0.5)
                                    else
                                        task.wait(1)
                                    end
                                end
                            else
                                task.wait(0.5)
                            end
                        else
                            task.wait(0.5)
                        end
                    end
                end)
                
                if AutoHeal.Enabled then
                    task.spawn(function()
                        while healRunning and AutoHeal.Enabled do
                            if currentTarget then
                                local health, maxHealth = getPlayerHealth(currentTarget)
                                if health and maxHealth and maxHealth > 0 then
                                    local healthPercent = (health / maxHealth) * 100
                                    if healthPercent < AutoHealSlider.Value and healthPercent < 90 then
                                        healTarget()
                                        task.wait(8.5)
                                    end
                                end
                            end
                            
                            task.wait(0.5)
                        end
                    end)
                end
                
                if AutoFly.Enabled then
                    task.spawn(function()
                        while flyRunning and AutoFly.Enabled do
                            if currentTarget and not hasActivatedFly then
                                if isFalling(currentTarget) and isAboveVoid(currentTarget) then
                                    fallCheckTimer = fallCheckTimer + 0.1
                                    
                                    if fallCheckTimer >= 0.5 then
                                        activateFly()
                                        fallCheckTimer = 0
                                    end
                                else
                                    fallCheckTimer = 0
                                end
                            else
                                fallCheckTimer = 0
                            end
                            
                            task.wait(0.1)
                        end
                    end)
                end
                
                AutoWhisper:Clean(playersService.PlayerAdded:Connect(function()
                    task.wait(0.5)
                    local newList = getTeammates(true)
                    if PlayerDropdown then
                        PlayerDropdown:Change(newList)
                        
                        if #newList > 0 then
                            if not PlayerDropdown.Value or PlayerDropdown.Value == "" or not table.find(newList, PlayerDropdown.Value) then
                                PlayerDropdown:SetValue(newList[1])
                            end
                        end
                    end
                end))
                
                AutoWhisper:Clean(playersService.PlayerRemoving:Connect(function(player)
                    task.wait(0.5)
                    local newList = getTeammates(true)
                    if PlayerDropdown then
                        PlayerDropdown:Change(newList)
                        
                        if #newList > 0 then
                            if not PlayerDropdown.Value or PlayerDropdown.Value == "" or not table.find(newList, PlayerDropdown.Value) then
                                PlayerDropdown:SetValue(newList[1])
                            end
                        end
                    end
                    
                    if currentTarget == player then
                        currentTarget = nil
                        currentMountedPlayer = nil
                    end
                end))
                
                AutoWhisper:Clean(lplr:GetAttributeChangedSignal('Team'):Connect(function()
                    task.wait(0.5)
                    local newList = getTeammates(true)
                    if PlayerDropdown then
                        PlayerDropdown:Change(newList)
                        
                        if #newList > 0 then
                            if not PlayerDropdown.Value or PlayerDropdown.Value == "" or not table.find(newList, PlayerDropdown.Value) then
                                PlayerDropdown:SetValue(newList[1])
                            end
                        end
                    end
                    currentTarget = nil
                    currentMountedPlayer = nil
                    hasActivatedFly = false
                end))
                
            else
                running = false
                healRunning = false
                flyRunning = false
                currentTarget = nil
                currentMountedPlayer = nil
                hasActivatedFly = false
                fallCheckTimer = 0
            end
        end,
        Tooltip = "Automatically mount bird to teammate, heal them, and save from void"
    })
    
    PlayerDropdown = AutoWhisper:CreateDropdown({
        Name = "Mount Target",
        List = {},
        Function = function(val)
            if val then
                local targetPlayer = playersService:FindFirstChild(val)
                if targetPlayer then
                    currentTarget = targetPlayer
                end
            end
        end,
        Tooltip = "Select teammate to mount owl to"
    })
    RefreshButton = AutoWhisper:CreateButton({
        Name = "Refresh Teammates",
        Tooltip = "Re-scans your team for the teammate dropdown above",
        Function = function()
            task.spawn(function()
                local newList = getTeammates(true)
                
                if PlayerDropdown then
                    pcall(function()
                        PlayerDropdown:Change(newList)
                        
                        if #newList > 0 then
                            if not PlayerDropdown.Value or PlayerDropdown.Value == "" or not table.find(newList, PlayerDropdown.Value) then
                                PlayerDropdown:SetValue(newList[1])
                            else
                                PlayerDropdown:SetValue(PlayerDropdown.Value)
                            end
                        end
                    end)
                end
                
            end)
        end,
        Tooltip = "Manually refresh the teammate list"
    })
    
    LimitToItem = AutoWhisper:CreateToggle({
        Name = "Limit to Owl Orb",
        Default = true,
        Function = function(val)
        end,
        Tooltip = "Only mount owl when holding owl_orb item"
    })

    AutoFly = AutoWhisper:CreateToggle({
        Name = "Auto Fly",
        Default = true,
        Function = function(val)
            if AutoWhisper.Enabled then
                if val then
                    flyRunning = true
                    hasActivatedFly = false
                    fallCheckTimer = 0
                    
                    task.spawn(function()
                        while flyRunning and AutoFly.Enabled do
                            if currentTarget and not hasActivatedFly then
                                if isFalling(currentTarget) and isAboveVoid(currentTarget) then
                                    fallCheckTimer = fallCheckTimer + 0.1
                                    
                                    if fallCheckTimer >= 0.5 then
                                        activateFly()
                                        fallCheckTimer = 0
                                    end
                                else
                                    fallCheckTimer = 0
                                end
                            else
                                fallCheckTimer = 0
                            end
                            
                            task.wait(0.1)
                        end
                    end)
                else
                    flyRunning = false
                    hasActivatedFly = false
                    fallCheckTimer = 0
                end
            end
        end,
        Tooltip = "Automatically activate lift when target is falling into void"
    })
    
    AutoHeal = AutoWhisper:CreateToggle({
        Name = "Auto Heal",
        Default = true,
        Function = function(val)
            if AutoHealSlider and AutoHealSlider.Object then
                AutoHealSlider.Object.Visible = val
            end
            
            if AutoWhisper.Enabled then
                if val then
                    healRunning = true
                    task.spawn(function()
                        while healRunning and AutoHeal.Enabled do
                            if currentTarget then
                                local health, maxHealth = getPlayerHealth(currentTarget)
                                if not (health and maxHealth and maxHealth > 0) then task.wait(0.5) continue end
                                local healthPercent = (health / maxHealth) * 100
                                if healthPercent < AutoHealSlider.Value and healthPercent < 90 then
                                    healTarget()
                                    task.wait(8.5)
                                end
                            end
                            
                            task.wait(0.5)
                        end
                    end)
                else
                    healRunning = false
                end
            end
        end,
        Tooltip = "Automatically heal target when health drops below threshold"
    })
    
    AutoHealSlider = AutoWhisper:CreateSlider({
        Name = "Heal Threshold",
        Min = 1,
        Max = 100,
        Default = 50,
        Suffix = "%",
        Tooltip = "Heal when target's health drops below this percentage (stops at 90%)"
    })
end)

kitRun(function()
    local AutoZeno
    local Targets
    local TargetMode
    local Limit
    local AutoShockWave
    local ShockwaveRange
    local UseStrike
    local UseStorm
    local Range
    local Delay

    local function getAttackData()
    	if Limit.Enabled then
    		local tool = (store.hand.tool and store.hand.tool.Name:find('wizard_staff')) and store.hand.tool or nil
    		return tool, tool and getHotbar(tool) or nil, tool and (tonumber(tool.Name:sub(#tool.Name, #tool.Name)) or 1) or nil
    	end

    	for i, v in store.inventory.inventory.items do
    		if v.itemType:find('wizard_staff') then
    			switchItem(v, 0)
    			return v, i, tonumber(v.itemType:sub(#v.itemType, #v.itemType)) or 1
    		end
    	end

    	return
    end

    AutoZeno = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Zeno',
    	Tooltip = 'Automates the Zeno kit lightning and shockwave',
    	Function = function(call)
    		if call then
    			repeat
    				if entitylib.isAlive then
    					local staff, __, level = getAttackData()

    					if staff then
    						local localPosition = entitylib.character.RootPart.Position
    						local ent = entitylib.EntityPosition({
    							Origin = localPosition,
    							Range = (Range.Value < 6 and AutoShockWave.Enabled and 7) or Range.Value,
    							Part = 'RootPart',
    							Players = Targets.Players.Enabled,
    							NPCs = Targets.NPCs.Enabled,
    							Sort = sortmethods[TargetMode.Value],
    						})

    						if ent then
    							if AutoShockWave.Enabled and level > 2 then
    								if
    									bedwars.AbilityController:canUseAbility('SHOCKWAVE')
    									and (localPosition - ent.RootPart.Position).Magnitude <= ShockwaveRange.Value
    								then
    									bedwars.AbilityController:useAbility('SHOCKWAVE', newproxy(true), {
    										target = CFrame.lookAt(localPosition, ent.RootPart.Position).LookVector,
    									})
    									task.wait(Delay.Value)
    								end
    							end

    							if UseStrike.Enabled and bedwars.AbilityController:canUseAbility('LIGHTNING_STRIKE') then
    								bedwars.AbilityController:useAbility('LIGHTNING_STRIKE', newproxy(true), {
    									target = ent.RootPart.Position + ((ent.Humanoid.MoveDirection or Vector3.zero) * (1 + lplr:GetNetworkPing())),
    								})
    								task.wait(Delay.Value)
    							end

    							if UseStorm.Enabled and level > 1 then
    								if bedwars.AbilityController:canUseAbility('LIGHTNING_STORM') then
    									bedwars.AbilityController:useAbility('LIGHTNING_STORM', newproxy(true), {
    										target = ent.RootPart.Position + ((ent.Humanoid.MoveDirection or Vector3.zero) * (1 + lplr:GetNetworkPing())),
    									})
    									task.wait(Delay.Value)
    								end
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoZeno.Enabled
    		end
    	end,
    	Tooltip = 'Automatically uses zeno\'s staff'
    })

    Targets = AutoZeno:CreateTargets({
    	Tooltip = 'Configure which types of targets to include',
    	Players = true,
    	NPCs = false,
    })
    local methods = {'Damage', 'Distance'}
    for i in sortmethods do
    	if not table.find(methods, i) then
    		table.insert(methods, i)
    	end
    end
    TargetMode = AutoZeno:CreateDropdown({
    	Name = 'Target Mode',
    	Tooltip = 'Selects how targets are prioritized and selected',
    	List = methods,
    	Default = 'Distance',
    	ItemTooltips = {
    		Distance = 'Targets the closest enemy by stud distance',
    		Health = 'Targets the enemy with the lowest remaining health',
    		Angle = 'Targets the enemy closest to your look direction',
    		Cursor = 'Targets the enemy nearest to your mouse cursor',
    		Damage = 'Targets the enemy who most recently took damage',
    		Threat = 'Targets the enemy judged to be the greatest combat threat',
    		Kit = 'Prioritizes dangerous kit users (Hannah, Spirit Assassin, etc.)',
    	}
    })
    Limit = AutoZeno:CreateToggle({
    	Name = 'Limit to item',
    	Tooltip = 'Only activates when a required item is in your hand',
    	Default = true
    })
    UseStrike = AutoZeno:CreateToggle({
    	Name = 'Use Lightning Strike',
    	Tooltip = 'Uses the lightning strike ability automatically',
    	Default = true
    })
    UseStorm = AutoZeno:CreateToggle({Name = 'Use Lightning Storm', Tooltip = 'Automatically uses the Lightning Storm ability to hit multiple nearby enemies at once'})
    AutoShockWave = AutoZeno:CreateToggle({
    	Name = 'Auto Shockwave',
    	Tooltip = 'Enables or disables auto shockwave',
    	Function = function(call)
    		pcall(function()
    			ShockwaveRange.Object.Visible = call
    		end)
    	end,
    	Tooltip = 'Automatically uses the shockwave ability when a target is near',
    })
    ShockwaveRange = AutoZeno:CreateSlider({
    	Name = 'Shockwave Range',
    	Tooltip = 'Radius in studs of the shockwave effect',
    	Visible = false,
    	Darker = true,
    	Min = 1,
    	Max = 12,
    	Suffix = function(val)
    		return val > 1 and 'studs' or 'stud'
    	end,
    	Decimal = 5,
    	Default = 12
    })
    Range = AutoZeno:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 60,
    	Default = 35,
    	Suffix = function(val)
    		return val > 1 and 'studs' or 'stud'
    	end,
    	Decimal = 5
    })
    Delay = AutoZeno:CreateSlider({
    	Name = 'Delay',
    	Tooltip = 'Seconds between consecutive actions',
    	Min = 0,
    	Max = 10,
    	Default = 0.5,
    	Decimal = 5,
    	Suffix = function(val)
    		return val > 1 and 'secs' or 'sec'
    	end
    })
end)

kitRun(function()
    local InfiniteKrystal
    local Gradual
    local Rate
    local old

    InfiniteKrystal = vain.Categories.Kit:CreateModule({
    	Name = 'Infinite Krystal',
    	Tooltip = 'Builds momentum faster, or pins it at max',
    	Function = function(call)
    		if call then
    			--[[
    				Saved once. Toggling on twice without a disable in between would
    				otherwise store the replacement as the original, and switching off
    				would leave the hook installed with no way back to the real function.
    			]]
    			old = old or bedwars.GlacialSkaterController.updateMomentum
    			bedwars.GlacialSkaterController.updateMomentum = function(self, ...)
    				if not (Gradual and Gradual.Enabled) then
    					self.momentum = 9e9
    					self.lastMomentumReport = 9e9
    					return old(self, ...)
    				end

    				--[[
    					Multiplies what the game just earned rather than writing a value.

    					Letting the original run first and scaling the difference keeps
    					every rule it applies - the cap, the decay while not skating, the
    					reset on landing - and only changes how fast the bar fills. Writing
    					a number straight in overrides all of that, which is what pinning
    					it at max does and why it reads as obviously not a player.

    					Only gains are scaled. Amplifying a loss would make momentum drain
    					five times faster too, which is the opposite of the setting.
    				]]
    				local before = tonumber(self.momentum) or 0
    				local result = old(self, ...)
    				local after = tonumber(self.momentum) or 0
    				local gained = after - before

    				if gained > 0 then
    					self.momentum = before + gained * (Rate.Value / 100)
    				end

    				return result
    			end
    		elseif old then
    			bedwars.GlacialSkaterController.updateMomentum = old
    		end
    	end
    })
    Gradual = InfiniteKrystal:CreateToggle({
    	Name = 'Gradual',
    	Tooltip = 'Charges fast instead of sitting at max'
    })
    Rate = InfiniteKrystal:CreateSlider({
    	Name = 'Charge Rate',
    	Tooltip = 'How fast momentum builds\n100 is the normal speed',
    	Min = 0,
    	Max = 500,
    	Default = 200,
    	Suffix = '%'
    })
end)

kitRun(function()
    local SigridExploit
    local Kit, Mount = 'elk_master', bedwars.Client:Get('ElkKitMounted')

    SigridExploit = vain.Categories.Kit:CreateModule({
    	Name = 'Infinite Sigrid',
    	Tooltip = 'Lets you ride in the elk forever',
    	Function = function(call)
    		if call then
    			repeat
    				if entitylib.isAlive then
    					if store.equippedKit == Kit then
    						Mount:SendToServer()
    					end
    				end
    				task.wait()
    			until not SigridExploit.Enabled
    		end
    	end
    })
end)

--[[
    Legit
]]

kitRun(function()
    local AutoVanessa
    local oldGetChargeTime
    local lastChargeTime = 0
    
    AutoVanessa = vain.Categories.Kit:CreateModule({
        Name = 'Auto Vanessa',
        Tooltip = 'Automates the Vanessa kit ability',
        Function = function(callback)
            if callback then
                task.spawn(function()
                    repeat task.wait() until bedwars.TripleShotProjectileController
                    
                    if bedwars.TripleShotProjectileController then
                        oldGetChargeTime = bedwars.TripleShotProjectileController.getChargeTime
                        
                        bedwars.TripleShotProjectileController.getChargeTime = function(self)
                            return 0
                        end
                        
                        bedwars.TripleShotProjectileController.overchargeStartTime = tick()
                    end
                end)
            else
                if oldGetChargeTime and bedwars.TripleShotProjectileController then
                    bedwars.TripleShotProjectileController.getChargeTime = oldGetChargeTime
                end
                lastChargeTime = 0
            end
        end,
        Tooltip = 'Auto charges Vanessa triple shot'
    })
end)

kitRun(function()
	local AutoJack
	local InstantCharge
	local ChargeSpeed
	local TorchAimbot
	local TorchTarget
	local TorchRange
	local torchHookRemove
	local chargeHookRemove
	local chargeTimeConn
	local InfiniteOil
	local lastThrow = 0
	local launchThrottleConn
	local ThrowCooldown
	local AutoIgnite
	local lastIgnite = 0
	local igniteThrowAt = {}
	-- Jack was reworked into a charge-to-throw kit: holding the Oil Spitter builds a
	-- charge (full at maxStrengthChargeSec = 3s) that decides the oil blob's size /
	-- splash-blob count. Two things need to reflect the boosted charge:
	--   1. The throw itself. The charge that reaches the server is the launch payload's
	--      drawDurationSec, taken straight from the launch table's drawDurationSeconds,
	--      so chargeBoost overrides that value on the ProjectileLaunchHook at throw time
	--      (like the torch aim above) -- this guarantees a full throw even on a fast tap.
	--   2. The on-screen charge bar during the hold. The bar is driven by the game's own
	--      per-frame loop: v54 = drawDurationSeconds / maxChargeTime, and the top bar /
	--      velocityMultiplier follow v54. Writing drawDurationSeconds ourselves races
	--      that loop and doesn't stick; instead we shrink maxChargeTime (via the
	--      ProjectileMaxChargeTimeModifierCheck sync event) while the oil spitter is
	--      charging, so the game's OWN loop fills the bar faster / instantly. We also
	--      backdate startChargingTIme in the hold loop so the Oil cost bar keeps pace.
	local MAX_CHARGE = 3
	-- Oil Spitter minStrengthScalar: the throw-strength floor at zero charge. Used to
	-- rescale the launch velocity so a forced-full charge also throws at full range.
	local MIN_STRENGTH = 0.7692307692307692

	-- Force the oil charge on the outgoing throw. jack_oil_projectile only -- the hook
	-- fires for every projectile, so we gate on the projectile name (no held-item
	-- check needed). Instant Charge sends a full charge; Charge Speed multiplies the
	-- charge the player actually built. The launch velocity is rescaled to match the
	-- forced charge so the blob is both max-size and thrown at the matching strength.
	local function chargeBoost(nextLaunch, ...)
		local res = nextLaunch(...)
		if not (AutoJack and AutoJack.Enabled) then return res end
		if type(res) ~= 'table' then return res end
		local projmeta = select(2, ...)
		if not projmeta or projmeta.projectile ~= 'jack_oil_projectile' then return res end

		local instant = InstantCharge and InstantCharge.Enabled
		local speed = (ChargeSpeed and ChargeSpeed.Value) or 1
		local baseDraw = res.drawDurationSeconds or 0
		local newDraw = baseDraw
		if instant then
			newDraw = MAX_CHARGE
		elseif speed > 1 then
			newDraw = math.min(MAX_CHARGE, baseDraw * speed)
		end
		if newDraw ~= baseDraw then
			res.drawDurationSeconds = newDraw
			local iv = res.initialVelocity
			if iv and iv.Magnitude > 0 then
				local ok, meta = pcall(function() return projmeta:getProjectileMeta() end)
				local baseSpeed = (ok and meta and meta.launchVelocity) or 80
				local v54 = math.min(1, newDraw / MAX_CHARGE)
				res.initialVelocity = iv.Unit * baseSpeed * (v54 + (1 - v54) * MIN_STRENGTH)
			end
		end
		return res
	end

	-- ClientSyncEvents lives as an upvalue of ProjectileSourceController.beginHolding
	-- (inherited by OilSpitterController). Scan its upvalues for the table that owns the
	-- charge-time modifier rather than hard-coding an index, so a reorder can't break us.
	local function getClientSyncEvents()
		local fn = bedwars.OilSpitterController and bedwars.OilSpitterController.beginHolding
		if type(fn) ~= 'function' then return nil end
		for i = 1, 24 do
			local ok, up = pcall(debug.getupvalue, fn, i)
			if ok and type(up) == 'table' and up.ProjectileMaxChargeTimeModifierCheck then
				return up
			end
		end
		return nil
	end

	-- Shrink the oil spitter's max charge time so the game's own hold loop fills the
	-- charge bar (and velocityMultiplier / throw strength) faster or instantly. The check
	-- fires once per hold with only the charge seconds, so we scope it to oil by only
	-- acting while OilSpitterController is charging -- other projectiles are untouched.
	local function installChargeTimeHook()
		if chargeTimeConn then return end
		local events = getClientSyncEvents()
		if not events then return end
		-- Throw throttle: the spitter has no built-in re-fire cooldown, so drop any oil
		-- launch that comes sooner than the Throw Cooldown slider after the last one,
		-- capping how fast you can re-throw. Cancelling StartLaunchProjectile is the same
		-- drop the game's own oil<10 gate uses, so it is clean.
		if not launchThrottleConn then
			launchThrottleConn = events.StartLaunchProjectile:connect(function(event)
				if not (AutoJack and AutoJack.Enabled) then return end
				if event.projectileType ~= 'jack_oil_projectile' then return end
				local cd = (ThrowCooldown and ThrowCooldown.Value) or 0.05
				local now = os.clock()
				if now - lastThrow < cd then
					event:setCancelled(true)
				else
					lastThrow = now
				end
			end)
		end
		chargeTimeConn = events.ProjectileMaxChargeTimeModifierCheck:connect(function(p)
			if not (AutoJack and AutoJack.Enabled) then return end
			local oil = bedwars.OilSpitterController
			if not (oil and oil.isCharging) then return end
			if not (p and type(p.maxChargeTime) == 'number') then return end
			if InstantCharge and InstantCharge.Enabled then
				p.maxChargeTime = 0.01
			else
				local speed = (ChargeSpeed and ChargeSpeed.Value) or 1
				if speed > 1 then
					p.maxChargeTime = p.maxChargeTime / speed
				end
			end
		end)
	end

	local function removeChargeTimeHook()
		if chargeTimeConn then
			pcall(function() chargeTimeConn:Destroy() end)
			chargeTimeConn = nil
		end
		if launchThrottleConn then
			pcall(function() launchThrottleConn:Destroy() end)
			launchThrottleConn = nil
		end
	end

	-- Torch (Fire Match) silent aim. The Fire Match is a normal projectile thrown
	-- through ProjectileController, so hooking calculateImportantLaunchValues and
	-- gating on projmeta.projectile == 'fire_match' scopes this to the torch alone --
	-- the hook only fires when the torch itself is thrown, so no held-item check is
	-- needed. Targets come from OilBlobController.spillMap (seed -> oil part); each
	-- part's Size.X tracks the puddle radius, so Biggest/Smallest sort by that.
	local function pickOilBlob(originPos)
		local controller = bedwars.OilBlobController
		if not controller or not controller.spillMap then return nil end
		local sort = TorchTarget and TorchTarget.Value or 'Nearest'
		local range = TorchRange and TorchRange.Value or 300
		-- Cursor mode ranks by nearness to the mouse on screen, so it needs the
		-- camera and the current mouse location up front.
		local camera = workspace.CurrentCamera
		local mousePos = (sort == 'Cursor' and camera and inputService) and inputService:GetMouseLocation() or nil
		local best, bestScore
		for _, part in pairs(controller.spillMap) do
			if typeof(part) == 'Instance' and part.Parent then
				local dist = (part.Position - originPos).Magnitude
				if dist <= range then
					local score
					if sort == 'Cursor' then
						if mousePos then
							local screenPos, onScreen = camera:WorldToViewportPoint(part.Position)
							if onScreen then
								score = -(Vector2.new(screenPos.X, screenPos.Y) - mousePos).Magnitude
							end
						end
					elseif sort == 'Farthest' then
						score = dist
					elseif sort == 'Biggest' then
						score = part.Size.X
					elseif sort == 'Smallest' then
						score = -part.Size.X
					else -- Nearest
						score = -dist
					end
					-- score stays nil for a Cursor blob that is off screen: skip it.
					if score and (not bestScore or score > bestScore) then
						bestScore, best = score, part
					end
				end
			end
		end
		return best
	end

	-- An ignited oil blob gets Burn particle emitters (Rate 45) parented in by the
	-- OilFlame handler, so treat a blob that has one as already lit.
	local function isBurning(part)
		for _, d in ipairs(part:GetDescendants()) do
			if d:IsA('ParticleEmitter') and d.Rate == 45 then
				return true
			end
		end
		return false
	end

	-- Throw a Fire Match at a world point (fire_match: velocity 80, gravity 35), the
	-- same resource-throwable launch path as the other projectiles. Needs Fire Match ammo.
	local function fireMatchAt(position)
		local item = getItem('fire_match')
		if not (item and item.tool) then return end
		if not (entitylib.character and entitylib.character.RootPart) then return end
		local localPosition = entitylib.character.RootPart.Position
		local meta = bedwars.ProjectileMeta.fire_match
		if not meta then return end
		local calc = prediction.SolveTrajectory(localPosition, meta.launchVelocity, meta.gravitationalAcceleration, position, Vector3.zero, workspace.Gravity, 0, 0)
		if calc then position = calc end
		local shootPosition = (CFrame.new(localPosition, position) * CFrame.new(Vector3.new(-bedwars.BowConstantsTable.RelX, -bedwars.BowConstantsTable.RelY, -bedwars.BowConstantsTable.RelZ))).Position
		bedwars.Client:Get(remotes.FireProjectile):CallServerAsync(
			item.tool,
			'fire_match',
			'fire_match',
			shootPosition,
			localPosition,
			CFrame.lookAt(localPosition, position).LookVector * meta.launchVelocity,
			httpService:GenerateGUID(true),
			{ drawDurationSeconds = 0.25, shotId = httpService:GenerateGUID(false) },
			workspace:GetServerTimeNow() - 0.045
		)
	end

	local function torchAim(nextLaunch, ...)
		if not (TorchAimbot and TorchAimbot.Enabled) then
			return nextLaunch(...)
		end
		local self, projmeta, worldmeta, origin, shootpos = ...
		if not projmeta or projmeta.projectile ~= 'fire_match' then
			return nextLaunch(...)
		end
		local pos = shootpos or (self.getLaunchPosition and self:getLaunchPosition(origin))
		if not pos then return nextLaunch(...) end
		local offsetpos = pos + (projmeta.fromPositionOffset or Vector3.zero)

		local blob = pickOilBlob(offsetpos)
		if not blob then return nextLaunch(...) end

		local meta = projmeta:getProjectileMeta()
		local projSpeed = meta.launchVelocity or 80
		local gravity = (meta.gravitationalAcceleration or 35) * (projmeta.gravityMultiplier or 1)
		local lifetime = worldmeta and (meta.predictionLifetimeSec or meta.lifetimeSec or 3) or (meta.lifetimeSec or 3)

		-- Static ground target: zero target velocity and hipHeight/jumping 0 (mirrors
		-- the telepearl static-point solve used by MouseTPs).
		local calc = prediction.SolveTrajectory(offsetpos, projSpeed, gravity, blob.Position, Vector3.zero, workspace.Gravity, 0, 0)
		if not calc then return nextLaunch(...) end

		local aimDir = CFrame.new(offsetpos, calc).LookVector
		return {
			initialVelocity = aimDir * projSpeed,
			positionFrom = offsetpos,
			deltaT = lifetime,
			gravitationalAcceleration = gravity,
			-- fire_match caps its charge at 0.25s; 1 is well past that, so the server
			-- reads a full-strength throw consistent with the overridden velocity.
			drawDurationSeconds = 1
		}
	end

	AutoJack = vain.Categories.Kit:CreateModule({
		Name = 'Auto Jack',
		Tooltip = 'Charge assist for the Jack (Oil Spitter) kit: instantly full-charge every oil blob, or just build the charge faster.',
		Function = function(callback)
			if not callback then
				if torchHookRemove then
					torchHookRemove()
					torchHookRemove = nil
				end
				if chargeHookRemove then
					chargeHookRemove()
					chargeHookRemove = nil
				end
				removeChargeTimeHook()
				return
			end
			if bedwars.ProjectileLaunchHook then
				if not torchHookRemove then
					torchHookRemove = bedwars.ProjectileLaunchHook:Add('JackTorchAim', 5, torchAim)
				end
				if not chargeHookRemove then
					chargeHookRemove = bedwars.ProjectileLaunchHook:Add('JackCharge', 6, chargeBoost)
				end
			end
			task.spawn(function()
				repeat task.wait() until bedwars.OilSpitterController
				-- The max-charge-time hook drives the on-screen charge bar; install it
				-- once the controller (and its inherited beginHolding upvalue) exists.
				installChargeTimeHook()
				while AutoJack.Enabled do
					local dt = task.wait()
					local controller = bedwars.OilSpitterController
					if controller and controller.isCharging then
						local instant = InstantCharge.Enabled
						local speed = ChargeSpeed.Value
						-- Keep the Oil cost bar (getChargeDuration, driven by
						-- startChargingTIme) in step with the boosted charge.
						if instant then
							controller.startChargingTIme = workspace:GetServerTimeNow() - MAX_CHARGE
						elseif speed > 1 then
							controller.startChargingTIme = controller.startChargingTIme - (speed - 1) * dt
						end
					end
					-- Infinite Oil: the game blocks aiming/throwing the spitter when your OilAmount
					-- attribute is under 10 (its client StartLaunchProjectile / BeginProjectileTargeting
					-- gates). Topping the local attribute up keeps those gates open so you can aim and
					-- throw full blobs at empty, and the oil bar reads full. The server still owns the real oil.
					if InfiniteOil and InfiniteOil.Enabled and store.hand and store.hand.tool and store.hand.tool.Name == 'oil_spitter' then
						lplr:SetAttribute('OilAmount', 100)
					end
					-- Auto Ignite: lob a Fire Match at any oil blob that is not yet burning so
					-- thrown oil lights itself. Ignition is server-authoritative (only a fire
					-- source lights oil), so this just automates the torch throw and needs Fire
					-- Match ammo. Per-blob and global cooldowns keep it from wasting matches.
					if AutoIgnite and AutoIgnite.Enabled and os.clock() - lastIgnite >= 0.25 then
						local ctrl = bedwars.OilBlobController
						local root = entitylib.character and entitylib.character.RootPart
						if ctrl and ctrl.spillMap and root then
							local best, bestDist, bestSeed
							for seed, part in pairs(ctrl.spillMap) do
								if typeof(part) == 'Instance' and part.Parent and not isBurning(part) then
									local prev = igniteThrowAt[seed]
									if not (prev and os.clock() - prev < 1) then
										local d = (part.Position - root.Position).Magnitude
										if not bestDist or d < bestDist then
											bestDist, best, bestSeed = d, part, seed
										end
									end
								end
							end
							if best then
								fireMatchAt(best.Position)
								igniteThrowAt[bestSeed] = os.clock()
								lastIgnite = os.clock()
							end
						end
					end
				end
			end)
		end
	})
	InstantCharge = AutoJack:CreateToggle({
		Name = 'Instant Charge',
		Tooltip = 'Fills the oil charge to maximum immediately, so every blob is thrown full-size with no hold time',
		Default = false
	})
	ChargeSpeed = AutoJack:CreateSlider({
		Name = 'Charge Speed',
		Tooltip = 'How many times faster the oil charge builds (ignored while Instant Charge is on)',
		Min = 1,
		Max = 10,
		Default = 2,
		Decimal = 10,
		Suffix = 'x'
	})
	ThrowCooldown = AutoJack:CreateSlider({
		Name = 'Throw Cooldown',
		Tooltip = 'Minimum seconds between oil throws; a release that comes sooner than this is dropped, capping how fast you can re-throw',
		Min = 0.01,
		Max = 1,
		Default = 0.05,
		Decimal = 100,
		Suffix = 's'
	})
	InfiniteOil = AutoJack:CreateToggle({
		Name = 'Infinite Oil',
		Tooltip = 'Keeps your oil topped up on the client so you can aim and throw full-size blobs even at empty (the bar reads full). The server still decides whether an empty throw actually lands',
		Default = false
	})
	TorchAimbot = AutoJack:CreateToggle({
		Name = 'Torch Aimbot',
		Tooltip = 'While the Fire Match (torch) is thrown, silently aims it at an oil blob so it lands on the oil and ignites it every time, like Projectile Aimbot but scoped to the torch and targeting oil blobs',
		Default = false
	})
	TorchTarget = AutoJack:CreateDropdown({
		Name = 'Torch Target',
		List = {'Nearest', 'Farthest', 'Biggest', 'Smallest', 'Cursor'},
		Default = 'Nearest',
		Tooltip = 'Which oil blob the torch aims at: nearest/farthest to you, the biggest/smallest puddle, or the one closest to your cursor'
	})
	TorchRange = AutoJack:CreateSlider({
		Name = 'Torch Range',
		Tooltip = 'Only aim the torch at oil blobs within this many studs',
		Min = 10,
		Max = 2000,
		Default = 500,
		Decimal = 1,
		Suffix = ' studs'
	})
	AutoIgnite = AutoJack:CreateToggle({
		Name = 'Auto Ignite',
		Tooltip = 'Automatically lobs a Fire Match at your oil blobs to set them alight, so you do not throw the torch yourself (needs Fire Match ammo)',
		Default = false
	})
end)

kitRun(function()
    local PromptUnlock

    local savedPromptStates = {}

    PromptUnlock = vain.Categories.Kit:CreateModule({
        Name = 'Prompt Unlock',
        Tooltip = 'enables all proximity prompts in the game',
        Function = function(callback)
            if callback then
                savedPromptStates = {}
                for _, v in workspace:GetDescendants() do
                    if v:IsA('ProximityPrompt') then
                        savedPromptStates[v] = v.Enabled
                        v.Enabled = true
                    end
                end
                PromptUnlock:Clean(workspace.DescendantAdded:Connect(function(v)
                    if not PromptUnlock.Enabled then return end
                    if v:IsA('ProximityPrompt') then
                        savedPromptStates[v] = v.Enabled
                        v.Enabled = true
                    end
                end))
            else
                for prompt, state in savedPromptStates do
                    if prompt and prompt.Parent then
                        prompt.Enabled = state
                    end
                end
                savedPromptStates = {}
            end
        end
    })
end)

kitRun(function()
    local Fisherman
    local AutoMinigameToggle, CompleteDelaySlider, RandomizeToggle, RandomRange
    local CatchSpeedSlider
    local PullAnimationToggle, MinigameAnimationToggle, LegitToggle
    local BlacklistOption, Blacklist
    local AutoCast, AutoCastDelay, CastAtShoals, ShoalRange
    local SpyToggle, Teammates, GoldNotify, SharkNotify, LootWhitelist
    local FishGroupESP

    local hookOld, animOld

    local fishNames = {
        fish_iron    = 'Iron Fish',
        fish_diamond = 'Diamond Fish',
        fish_gold    = 'Gold Fish',
        fish_special = 'Special Fish',
        fish_emerald = 'Emerald Fish',
        shark        = 'Shark',
    }

    local function on(setting)
        return setting ~= nil and setting.Enabled
    end

    local function displayName(itemType)
        local meta = bedwars.ItemMeta[itemType]
        return meta and meta.displayName or itemType
    end

    --[[
        Every rod, not one name.

        The kit used to hand out a single 'fishing_rod'. It now starts on fishing_rod_1
        and upgrades through _2 and _3, and ice fishing hands out its own - so the exact
        name this matched on stopped matching the day the rework landed, and casting
        never fired again.
    ]]
    local function isFishingRod(name)
        return type(name) == 'string' and name:find('fishing_rod', 1, true) ~= nil
    end

    local function getBait()
        for _, v in workspace:GetChildren() do
            if v.Name == 'fisherman_bobber' and v:GetAttribute('ProjectileShooter') == lplr.UserId then
                return v
            end
        end
    end

    --[[
        The animations belong to the game, which is why the switches did nothing.

        The catch animation is played by the game's own callback the moment a win is
        reported, and the pull animation by its fishing controller the moment a fish is
        found - so turning ours off only ever removed a second animation layered on top of
        one that always played.

        Suppressing them means intercepting the call the game itself makes. Only our own
        character and only the fishing animations are touched; everything else passes
        through untouched.
    ]]
    local function setupAnimationControl()
        if animOld or not (bedwars and bedwars.GameAnimationUtil) then return end

        animOld = bedwars.GameAnimationUtil.playAnimation
        bedwars.GameAnimationUtil.playAnimation = function(self, player, animationType, ...)
            if player == lplr then
                local types = bedwars.AnimationType
                if types then
                    if animationType == types.FISHING_ROD_PULLING and not on(PullAnimationToggle) then
                        return
                    end
                    if (animationType == types.FISHING_ROD_CATCH_SUCCESS
                        or animationType == types.FISHING_ROD_CATCH_FAIL)
                        and not on(MinigameAnimationToggle) then
                        return
                    end
                end
            end
            return animOld(self, player, animationType, ...)
        end
    end

    local function cleanupAnimationControl()
        if animOld then
            bedwars.GameAnimationUtil.playAnimation = animOld
            animOld = nil
        end
    end

    --[[
        Filling the bar faster while you play it yourself.

        The minigame's progress bar grows by FishermanUtil.fillAmount each step for as
        long as the fish is inside the marker, and the game reads that number off the
        shared table every time rather than holding its own copy - so raising it there
        raises the fill rate, and nothing else reads it.

        The original is kept so switching the module off puts the game back exactly as it
        was, rather than leaving it a little quicker for the rest of the match.
    ]]
    local baseFill

    local function applyCatchSpeed()
        local util = bedwars and bedwars.FishermanUtil
        if not (util and CatchSpeedSlider) then return end

        baseFill = baseFill or util.fillAmount
        util.fillAmount = baseFill * (1 + CatchSpeedSlider.Value / 100)
    end

    local function restoreCatchSpeed()
        local util = bedwars and bedwars.FishermanUtil
        if util and baseFill then
            util.fillAmount = baseFill
        end
    end

    --[[
        Playing the minigame instead of skipping it.

        The game drives this off ContextActionService bound to MouseButton1 - hold to push
        the green marker right, release to let it glide left - but a synthetic click never
        moved it, so the marker sat where it started and the bar never filled.

        Moving the marker itself does work, and it is not a shortcut past the minigame:
        the game decides the outcome by measuring where the marker actually is. Its own
        heartbeat checks whether the fish sits fully inside the marker, fills the progress
        bar while it does, drains it while it does not, and reports the win itself. So the
        bar fills for the real reason, and the marker is moved at a capped speed rather
        than snapped, so it tracks the fish the way a hand on the mouse would.
    ]]
    local legitPlaying = false

    local function minigameParts()
        local playerGui = lplr:FindFirstChildOfClass('PlayerGui')
        if not playerGui then return end

        for _, v in playerGui:GetDescendants() do
            if v:IsA('GuiObject') then
                local marker, zone = v:FindFirstChild('Marker'), v:FindFirstChild('FishZone')
                if marker and zone and marker:IsA('GuiObject') and zone:IsA('GuiObject') then
                    return marker, zone
                end
            end
        end
    end

    --[[
        Named lookup first, then shape.

        The UI is React, and whether a child's key becomes the instance name is its
        business, not ours. The marker and the fish are unmistakable by size though - the
        game builds them from markerSize 0.3 and fishZoneSize 0.02 of the same parent - so
        that is the fallback when the names are not there.
    ]]
    local function minigameByShape()
        local playerGui = lplr:FindFirstChildOfClass('PlayerGui')
        if not playerGui then return end

        for _, v in playerGui:GetDescendants() do
            if v:IsA('GuiObject') then
                local marker, zone
                for _, child in v:GetChildren() do
                    if child:IsA('GuiObject') then
                        local width = child.Size.X.Scale
                        if math.abs(width - 0.3) < 0.001 then
                            marker = child
                        elseif math.abs(width - 0.02) < 0.001 then
                            zone = child
                        end
                    end
                end
                if marker and zone then return marker, zone end
            end
        end
    end

    local function playMinigame()
        task.spawn(function()
            -- The UI is mounted by the call we are wrapping, so it is not there yet.
            local marker, zone
            local deadline = os.clock() + 5
            repeat
                marker, zone = minigameParts()
                if not marker then marker, zone = minigameByShape() end
                if not marker then task.wait(0.05) end
            until marker or os.clock() > deadline

            if not marker then
                notif('Fisherman', 'Legit could not find the minigame, so it was left alone', 5, 'warning')
                return
            end

            local track = marker.Parent
            local limit = 1 - marker.Size.X.Scale
            local holding, held = false, 0

            --[[
                Playing it like a person, not a servo.

                The pace was right but it sat the fish dead centre of the marker and
                corrected the instant the fish moved, which no hand does and which is what
                gave it away.

                Three things separate a person from a controller here, and none of them is
                speed. A person does not see the fish move until a moment after it has -
                so the marker is steered towards where the fish was a beat ago, not where
                it is. A person is not aiming at the exact middle - they hold it roughly
                there, and where "roughly" sits wanders over a few seconds. And a person
                does not press and release on an exact threshold - they go a little past,
                let it fall a little far, and occasionally react late.

                All three are error, so they cost nothing: the marker is far wider than
                the fish, and the bar fills for as long as the fish is anywhere inside it.
            ]]
            local seen, seenAt = nil, 0
            local reaction = 0.07 + math.random() * 0.11
            local bias, biasAt = 0, 0
            local biasHold = 0.5 + math.random() * 1.1
            local slack = 0.01
            local fumble = 0

            while legitPlaying and marker.Parent and zone.Parent and track do
                local dt = runService.Heartbeat:Wait()
                local width = track.AbsoluteSize.X

                if width > 0 then
                    local util = bedwars.FishermanUtil or {}
                    local increment = util.markerIncrementAmount or 0.075
                    local slowest = util.startingMarkerIncrementSpeed or 0.1
                    local quickest = util.holdMinimumMarkerIncrementSpeed or 0.035
                    local decaySec = util.totalDecaySpeedSec or 1

                    local now = os.clock()
                    local current = marker.Position.X.Scale

                    -- Where the fish is, in the same scale the marker is positioned in.
                    local zoneNow = (zone.AbsolutePosition.X + zone.AbsoluteSize.X / 2
                        - track.AbsolutePosition.X) / width

                    -- Noticed a beat late, and only then.
                    if now - seenAt >= reaction then
                        seen, seenAt = zoneNow, now
                        reaction = 0.07 + math.random() * 0.11
                    end
                    local target = seen or zoneNow

                    -- Aiming near the middle rather than at it, drifting over seconds.
                    if now - biasAt >= biasHold then
                        bias = (math.random() - 0.5) * marker.Size.X.Scale * 0.5
                        biasAt, biasHold = now, 0.5 + math.random() * 1.1
                    end
                    target = target + bias

                    local centre = current + marker.Size.X.Scale / 2

                    if holding then
                        -- Carried a little past before letting go.
                        if centre >= target + slack then
                            holding, held = false, 0
                            slack = math.random() * 0.03
                            fumble = math.random() < 0.15 and 0.05 + math.random() * 0.12 or 0
                        end
                    elseif centre <= target - slack then
                        -- Sometimes a moment late off the mark.
                        if fumble > 0 then
                            fumble = fumble - dt
                        else
                            holding, held = true, 0
                            slack = math.random() * 0.03
                        end
                    end

                    local step

                    if holding then
                        held = held + dt
                        local tweenTime = math.max(slowest - 0.01 * (held / 0.05), quickest)
                        step = math.min(limit - current, (increment / tweenTime) * dt)
                    else
                        local span = current + marker.Size.X.Scale
                        local decay = span > 0 and current / (span * decaySec) or 0
                        step = -math.min(current, decay * dt)
                    end

                    -- Offset zero, matching the position the game's own hold tween writes.
                    marker.Position = UDim2.new(math.clamp(current + step, 0, limit), 0, 0.5, 0)
                end
            end
        end)
    end

    -- Ice fishing calls startMinigame with a fourth options table (range limit, custom UI
    -- placement), so everything past the callback is passed straight through.
    local function installHook()
        if hookOld or not (bedwars and bedwars.FishingMinigameController) then return end

        hookOld = bedwars.FishingMinigameController.startMinigame
        bedwars.FishingMinigameController.startMinigame = function(self, dropData, result, ...)
            if not on(AutoMinigameToggle) then
                return hookOld(self, dropData, result, ...)
            end

            if on(BlacklistOption) and dropData and dropData.fishModel then
                if table.find(Blacklist.ListEnabled, dropData.fishModel) then
                    local hum = lplr.Character and lplr.Character:FindFirstChildOfClass('Humanoid')
                    if hum and hum:GetState() ~= Enum.HumanoidStateType.Jumping then
                        hum:ChangeState(Enum.HumanoidStateType.Jumping)
                    end
                    return hookOld(self, dropData, result, ...)
                end
            end

            --[[
                Legit plays the real thing, so none of the auto-complete settings apply to
                it - no delay to wait out and nothing to finish early. The game runs its
                own minigame and reports its own result; we only work the mouse.
            ]]
            if on(LegitToggle) then
                legitPlaying = true
                playMinigame()

                return hookOld(self, dropData, function(outcome)
                    legitPlaying = false
                    if result then return result(outcome) end
                end, ...)
            end

            local waitTime = CompleteDelaySlider.Value
            if on(RandomizeToggle) then
                local min, max = RandomRange.ValueMin, RandomRange.ValueMax
                waitTime = min + (max - min) * math.random()
            end

            task.spawn(function()
                if waitTime > 0 then
                    task.wait(waitTime)
                end

                --[[
                    Nothing to report if the fishing already ended.

                    The delay is a timer set when the fish bit, and it used to fire whatever
                    happened in between. Jump away at 1.5s of a 3s delay and the catch was
                    already cancelled, but the timer still came due and reported a win - so
                    the success animation played on a fish that got away.

                    The bobber is destroyed when fishing ends, so its absence is the signal
                    that this timer belongs to a catch that is over.
                ]]
                if not getBait() then return end
                if result then pcall(result, { win = true }) end
            end)
        end
    end

    local function removeHook()
        legitPlaying = false
        if hookOld then
            bedwars.FishingMinigameController.startMinigame = hookOld
            hookOld = nil
        end
    end

    -- ── casting ───────────────────────────────────────────────────────────
    local castParams = RaycastParams.new()
    castParams.FilterType = Enum.RaycastFilterType.Exclude

    --[[
        Where a cast can go, worked out along the bobber's real path.

        You fish off the edge of the map, so a cast has to fly clear and come down over the
        void. The old test checked six studs straight out at head height and then straight
        down - but the bobber flies on an arc for twenty-odd studs, so a block past those six
        studs, or a little below head height, caught it every time. That is what cast into
        blocks.

        The bobber is a slow, light projectile (25 studs a second, falling at 30), so each
        candidate cast is simulated step by step and every step is checked for anything in
        the way. A cast that touches a block - or lands on ground rather than dropping into
        the void - is not a cast.
    ]]
    local BOBBER_SPEED, BOBBER_GRAVITY = 25, 30
    local SIM_TIME, SIM_STEP = 1.6, 0.08

    --[[
        How the rod really launches, learned from the rod itself.

        A guess at the speed and at where the bobber leaves from is what put shoal casts
        off centre: the bobber spawns at the rod, not your head, and at whatever speed the
        game works out. Every cast the rod makes is watched (in the launch hook below) and
        its real speed, gravity and launch point relative to your head kept, so the next
        cast is planned with the numbers that will actually be used.
    ]]
    local learned = {}

    local function bobberMeta()
        local meta = bedwars.ProjectileMeta and bedwars.ProjectileMeta.fisherman_bobber
        local speed = learned.speed or (meta and meta.launchVelocity) or BOBBER_SPEED
        local gravity = learned.gravity or (meta and meta.gravitationalAcceleration) or BOBBER_GRAVITY
        return speed, gravity
    end

    -- Where a cast leaves from: the learned launch point, your head until one is known.
    local function launchOrigin()
        local head = entitylib.character.Head.Position
        return learned.offset and head + learned.offset or head
    end

    -- The game spawns the bobber a little way along its launch direction from the launch
    -- point, by the bow constants - so a shot is planned from there, not from the rod.
    local function muzzle(from, direction)
        local constants = bedwars.BowConstantsTable
        if not constants or direction.Magnitude <= 0 then return from end
        local offset = Vector3.new(constants.RelX or 0, constants.RelY or 0, constants.RelZ or 0)
        return (CFrame.new(from, from + direction) * CFrame.new(offset)).Position
    end

    -- Characters and the shoal models are never what stops a bobber.
    local function refreshCastFilter(extra)
        local ignore = {}
        for _, plr in playersService:GetPlayers() do
            if plr.Character then ignore[#ignore + 1] = plr.Character end
        end
        if extra then ignore[#ignore + 1] = extra end
        castParams.FilterDescendantsInstances = ignore
        castParams.RespectCanCollide = true
    end

    -- A sphere wider than the bobber rather than a line, so a cast that would only graze a
    -- block's edge is still turned down - a stud of room all the way along.
    local CLEARANCE = 1
    local function blocked(from, to)
        local direction = to - from
        local ok, hit = pcall(workspace.Spherecast, workspace, from, CLEARANCE, direction, castParams)
        if not ok then hit = workspace:Raycast(from, direction, castParams) end
        return hit ~= nil
    end

    -- True when a bobber launched from origin at velocity flies clear and drops into the
    -- void. arrival, when given, is the flight time to a shoal: the check ends exactly
    -- there, rather than going on into the water.
    local function clearArc(origin, velocity, gravity, arrival)
        local previous = origin
        local limit = arrival or SIM_TIME
        local t = 0
        while t < limit do
            t = math.min(t + SIM_STEP, limit)
            local point = origin + velocity * t - Vector3.new(0, 0.5 * gravity * t * t, 0)
            if blocked(previous, point) then return false end
            previous = point
        end
        if arrival then return true end
        -- Nothing under where it ends up: the void, not a platform below.
        return workspace:Raycast(previous, Vector3.new(0, -200, 0), castParams) == nil
    end

    -- Of the headings that cast clear, the one closest to where you are looking.
    local function findVoid()
        if not entitylib.isAlive then return end

        local head = entitylib.character.Head.Position
        local origin = launchOrigin()
        local speed, gravity = bobberMeta()
        refreshCastFilter()

        local look = workspace.CurrentCamera and workspace.CurrentCamera.CFrame.LookVector * Vector3.new(1, 0, 1)
        look = (look and look.Magnitude > 0) and look.Unit or Vector3.new(0, 0, -1)

        local best, bestDot
        for i = 0, 23 do
            local angle = (i / 24) * math.pi * 2
            local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
            local dot = direction:Dot(look)
            if not bestDot or dot > bestDot then
                -- The same heading the launch hook will give it: from the launch point
                -- toward a point thirty studs out at head height.
                local heading = (head + direction * 30) - origin
                local start = muzzle(origin, heading)
                if clearArc(start, heading.Unit * speed, gravity) then
                    best, bestDot = direction, dot
                end
            end
        end
        return best
    end

    --[[
        A shoal within reach, aimed at properly.

        The bobber falls fast for how slowly it flies, so pointing straight at a shoal lands
        short; the launch is solved as a ballistic shot onto the shoal instead, and taken
        only if that arc is clear too. The nearest shoal is tried first.
    ]]

    --[[
        The launch velocity that lands a bobber on a point, with a clear path.

        Solved from the bobber's real spawn point - which depends on the direction, so it
        is worked out twice - and checked the whole way for blocks. A flat arc that would
        clip something is retried as a lob over it by the solver before giving up.
    ]]
    local function solveOnto(from, speed, gravity, point)
        local direction = point - from
        local start, velocity, flight
        for _ = 1, 2 do
            start = muzzle(from, direction)
            local ok, calc, _, time = pcall(prediction.SolveTrajectory, start, speed, gravity, point, Vector3.zero, workspace.Gravity, 0, 0, castParams)
            if not (ok and calc and time) then return nil end
            direction = calc - start
            velocity, flight = direction.Unit * speed, time
        end
        start = muzzle(from, direction)
        if clearArc(start, velocity, gravity, flight) then
            return velocity
        end
    end

    -- Where the game put a shoal: the point it was spawned at, which is the pond's pivot.
    local function shoalCentre(model)
        local ok, pivot = pcall(model.GetPivot, model)
        if ok then return pivot.Position end
        local part = model.PrimaryPart or model:FindFirstChildWhichIsA('BasePart', true)
        return part and part.Position or nil
    end

    -- The nearest shoal in range with a clear shot onto its centre. Returns the centre to
    -- aim for, and the shoal.
    local function findShoal()
        if not (entitylib.isAlive and on(CastAtShoals)) then return end

        local origin = launchOrigin()
        local speed, gravity = bobberMeta()
        local candidates = {}
        for _, child in workspace:GetChildren() do
            if child:IsA('Model') and child.Name:lower():find('pond', 1, true) then
                local centre = shoalCentre(child)
                if centre then
                    local flat = (centre - origin) * Vector3.new(1, 0, 1)
                    if flat.Magnitude <= ShoalRange.Value then
                        candidates[#candidates + 1] = {model = child, point = centre, distance = flat.Magnitude}
                    end
                end
            end
        end
        table.sort(candidates, function(a, b)
            return a.distance < b.distance
        end)

        for _, shoal in candidates do
            refreshCastFilter(shoal.model)
            if solveOnto(origin, speed, gravity, shoal.point) then
                return shoal.point, shoal.model
            end
        end
    end

    --[[
        Telling the rod where to go, rather than pointing the player at it.

        The game builds the launch direction in
        ProjectileController:calculateImportantLaunchValues, from
        Camera:ScreenPointToRay(Mouse.X, Mouse.Y) - the real cursor. That is why clicking
        a chosen point threw the bobber wherever the mouse already pointed, and why the
        only way to steer it from outside was to move the camera and the cursor with it.

        Taking the direction at its source is both simpler and invisible: the speed the
        game worked out is kept and only the heading is replaced. It applies to the aim
        preview as well, since that arc is drawn from the same numbers.

        It only touches a launch we asked for - castTarget is set for the moment of our
        own cast and cleared afterwards - so every other throw, and every other item, is
        left alone.
    ]]
    local aimOriginal, aimWrapper
    local castTarget
    -- The centre of the shoal being cast at, and its model, while a shoal cast is under way.
    local castShoal, castShoalModel

    --[[
        Wrapped on the controller itself, and never left dangling.

        ProjectileAimbot wraps this same method on the same object, so the two have to be
        able to sit on top of each other in either order. Two rules make that safe, and
        breaking the second of them is what put a nil call inside the game's own bow.

        The first is to patch the instance, as the aimbot does, rather than walking up to
        the class it inherits from. A class patch is wider than the object we were asked
        about and turns a shared method into ours.

        The second is that a wrapper, once installed, must work forever. Whoever wraps
        after us captures ours as their original and will keep calling it long after we
        have stepped out - so what it calls is kept, and only the pointer to our own
        wrapper is dropped. Clearing that too is what left the aimbot calling into a
        function whose insides had been taken away.

        The direction itself comes from Camera:ScreenPointToRay(Mouse.X, Mouse.Y) - the
        real cursor - unless the handler carries a targetPoint, which the game checks
        first and uses as-is. Setting that is how the game aims a throw at something, so
        it is set here and the original does the rest.
    ]]
    local function setupAim()
        local controller = bedwars and bedwars.ProjectileController
        if aimWrapper or not controller then return end

        --[[
            Each wrapper holds its own original, not a shared one.

            A single upvalue between them is what put a nil back inside the game's bow:
            the aimbot captures our wrapper as its original and keeps it forever, and the
            next time this ran it pointed that one variable somewhere else. The wrapper
            the aimbot was still calling then went through whatever the variable had
            become - or through nothing at all.

            Closed over per wrapper, an old one keeps calling exactly what it was built
            with however many times this is switched on and off.
        ]]
        local original = controller.calculateImportantLaunchValues
        if type(original) ~= 'function' then return end
        aimOriginal = original

        local wrapper
        wrapper = function(self, handler, ...)
            if type(original) ~= 'function' then return end

            local held = store.hand and store.hand.tool
            local wanted = castTarget and held and isFishingRod(held.Name) and castTarget

            if wanted and type(handler) == 'table' then
                handler.targetPoint = wanted
                handler.lockedAimPoint = nil
            end

            local values = original(self, handler, ...)

            -- Every rod launch teaches the planner the real numbers.
            if held and isFishingRod(held.Name) and values and values.initialVelocity and values.positionFrom then
                local speed = values.initialVelocity.Magnitude
                if speed > 0 then learned.speed = speed end
                if type(values.gravitationalAcceleration) == 'number' and values.gravitationalAcceleration > 0 then
                    learned.gravity = values.gravitationalAcceleration
                end
                if entitylib.isAlive then
                    learned.offset = values.positionFrom - entitylib.character.Head.Position
                end
            end

            if wanted and values and values.initialVelocity and values.positionFrom then
                local speed = values.initialVelocity.Magnitude
                local aimed = false
                -- A shoal is solved again here with exactly what the game is about to use, so
                -- the bobber comes down on its centre.
                if castShoal then
                    local _, gravity = bobberMeta()
                    refreshCastFilter(castShoalModel)
                    local velocity = solveOnto(values.positionFrom, speed, gravity, castShoal)
                    if velocity then
                        values.initialVelocity = velocity
                        aimed = true
                    end
                end
                if not aimed then
                    local heading = wanted - values.positionFrom
                    if heading.Magnitude > 0 then
                        values.initialVelocity = heading.Unit * speed
                    end
                end
            end

            return values
        end

        aimWrapper = wrapper
        controller.calculateImportantLaunchValues = wrapper
    end

    local function cleanupAim()
        castTarget, castShoal, castShoalModel = nil, nil, nil

        -- Put back only if ours is still the one installed. Something wrapped after us
        -- owns the slot now, and writing over it would throw their hook away.
        local controller = bedwars and bedwars.ProjectileController
        if controller and aimWrapper and aimOriginal
            and controller.calculateImportantLaunchValues == aimWrapper then
            controller.calculateImportantLaunchValues = aimOriginal
        end

        aimWrapper = nil
    end

    local castLoop = false
    local function setupAutoCast()
        if castLoop then return end
        castLoop = true

        task.spawn(function()
            repeat
                local camera = workspace.CurrentCamera
                if camera and entitylib.isAlive and on(AutoCast)
                    and store.hand.tool and isFishingRod(store.hand.tool.Name)
                    and not getBait() then

                    if findShoal() or findVoid() then
                        task.wait(AutoCastDelay:GetRandomValue())

                        -- Aimed at the moment of the throw, since the delay above is long
                        -- enough to have walked somewhere else. A shoal in reach wins;
                        -- otherwise the clearest edge, cast level so it flies the arc that
                        -- was checked.
                        local target, shoalModel = nil, nil
                        if entitylib.isAlive then
                            target, shoalModel = findShoal()
                        end
                        castShoal, castShoalModel = target, shoalModel
                        if not target then
                            local direction = entitylib.isAlive and findVoid()
                            target = direction and entitylib.character.Head.Position + direction * 30
                        end
                        if target then
                            castTarget = target

                            local centre = camera.ViewportSize / 2
                            for _, down in {true, false} do
                                VirtualInputManager:SendMouseButtonEvent(centre.X, centre.Y, 0, down, game, 1)
                                task.wait()
                            end

                            -- Held past the click, because the rod works out its direction
                            -- when the throw is released rather than when it is pressed.
                            task.wait(0.3)
                            castTarget, castShoal, castShoalModel = nil, nil, nil
                            task.wait(0.5)
                        end
                    end
                end
                -- Each look checks a couple of dozen arcs, so it is not repeated every frame.
                task.wait(0.4)
            until not Fisherman.Enabled
            castLoop = false
        end)
    end

    -- ── fish groups ───────────────────────────────────────────────────────
    --[[
        Where the fish are.

        The rework spawns shoals around the map, each one of four tiers, and drops a pond
        model at every one. Those models are what this looks for. The spawn event fires
        once and only once, so anything that was already there when you switched this on -
        or that arrived while the remote was still registering - would never be marked at
        all, which is why watching the event alone showed nothing.

        The event is still listened to, but only for the tier: there are two pond models
        for four tiers, so the model itself only says whether it is the big one.
    ]]
    -- Named for what they are worth rather than for their colour: the blue one is the
    -- ordinary shoal, and the purple one is the one with a shark in it.
    local TIER_NAMES = {[0] = 'Green Shoal', [1] = 'Shoal', [2] = 'Shark Shoal', [3] = 'Orange Shoal'}
    local TIER_COLORS = {
        [0] = Color3.fromRGB(120, 220, 120),
        [1] = Color3.fromRGB(110, 180, 255),
        [2] = Color3.fromRGB(200, 130, 255),
        [3] = Color3.fromRGB(255, 170, 90)
    }
    local groupFolder = Instance.new('Folder')
    groupFolder.Parent = vain.gui
    local groupMarkers, groupTiers = {}, {}
    local groupLoop = false

    --[[
        Connected once the remote is actually there.

        Get hands back what is registered at the moment it is asked and throws when the
        remote is not registered yet, which it is not while the round is still loading -
        so a connection made then was silently missing for the rest of the match. The
        game's own code waits for these. The RemoteEvent underneath carries the payload,
        so that is what is listened to when the wrapper hands back nothing connectable.
    ]]
    local liveEvents = {}

    local function connectEvent(name, handler)
        if liveEvents[name] then return end
        liveEvents[name] = true

        task.spawn(function()
            local connection
            for _ = 1, 30 do
                if not liveEvents[name] then return end

                local ok, event = pcall(function()
                    return bedwars.Client:Get(name)
                end)
                if ok and event then
                    local gotInstance, instance = pcall(function()
                        return event.instance
                    end)
                    if gotInstance and typeof(instance) == 'Instance' and instance:IsA('RemoteEvent') then
                        connection = instance.OnClientEvent:Connect(handler)
                    elseif type(event) == 'table' and type(event.Connect) == 'function' then
                        connection = event:Connect(handler)
                    end
                end
                if connection then break end
                task.wait(1)
            end

            if connection then
                liveEvents[name] = connection
                Fisherman:Clean(connection)
            else
                liveEvents[name] = nil
            end
        end)
    end

    local function disconnectEvent(name)
        local connection = liveEvents[name]
        liveEvents[name] = nil
        if typeof(connection) == 'RBXScriptConnection' then
            connection:Disconnect()
        end
    end

    local function tierNear(position)
        local bestTier, bestDistance
        for _, entry in groupTiers do
            local distance = (entry.position - position).Magnitude
            if distance < 12 and (not bestDistance or distance < bestDistance) then
                bestTier, bestDistance = entry.tier, distance
            end
        end
        return bestTier
    end

    local function clearFishGroups()
        for pond, marker in groupMarkers do
            marker:Destroy()
            groupMarkers[pond] = nil
        end
    end

    local function markPond(pond)
        if groupMarkers[pond] then return end

        local part = pond.PrimaryPart or pond:FindFirstChildWhichIsA('BasePart', true)
        if not part then return end

        local tier = tierNear(part.Position)
        local big = pond.Name:lower():find('two', 1, true) ~= nil

        local billboard = Instance.new('BillboardGui')
        billboard.Name = 'FishGroup'
        billboard.Adornee = part
        billboard.Size = UDim2.fromOffset(130, 20)
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
        billboard.AlwaysOnTop = true
        billboard.Parent = groupFolder

        local label = Instance.new('TextLabel')
        label.Size = UDim2.fromScale(1, 1)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.GothamBold
        label.TextSize = 13
        label.TextStrokeTransparency = 0.5
        label.TextColor3 = tier and TIER_COLORS[tier] or (big and TIER_COLORS[2] or TIER_COLORS[0])
        label.Text = tier and TIER_NAMES[tier] or (big and 'Shark Shoal' or 'Shoal')
        label.Parent = billboard

        groupMarkers[pond] = billboard
    end

    local function cleanupFishGroups()
        disconnectEvent('FishGroupSpawn')
        disconnectEvent('FishGroupDespawn')
        table.clear(groupTiers)
        clearFishGroups()
    end

    local function setupFishGroups()
        connectEvent('FishGroupSpawn', function(data)
            if data and typeof(data.position) == 'Vector3' then
                groupTiers[tostring(data.position)] = {position = data.position, tier = data.tier}
            end
        end)
        connectEvent('FishGroupDespawn', function(data)
            if data and typeof(data.position) == 'Vector3' then
                groupTiers[tostring(data.position)] = nil
            end
        end)

        if groupLoop then return end
        groupLoop = true

        task.spawn(function()
            repeat
                -- Guarded because it walks the workspace while the game is adding to it.
                pcall(function()
                    for pond, marker in groupMarkers do
                        if not pond.Parent then
                            marker:Destroy()
                            groupMarkers[pond] = nil
                        end
                    end

                    if on(FishGroupESP) then
                        for _, child in workspace:GetChildren() do
                            if child:IsA('Model') and child.Name:lower():find('pond', 1, true) then
                                markPond(child)
                            end
                        end
                    else
                        clearFishGroups()
                    end
                end)
                task.wait(1)
            until not Fisherman.Enabled
            groupLoop = false
            clearFishGroups()
        end)
    end

    -- ── watching everyone else ────────────────────────────────────────────
    -- Either form matches, since the list is seeded with the game's own item names but
    -- what gets reported is the display name.
    local function lootWanted(itemType, itemDisplay)
        if #LootWhitelist.ListEnabled <= 0 then return false end

        local a, b = itemType:lower(), itemDisplay:lower()
        for _, v in LootWhitelist.ListEnabled do
            local wanted = v:lower()
            if wanted == a or wanted == b then return true end
        end
        return false
    end

    --[[
        Whose catch it is.

        Bedwars keeps the team on an attribute, not in a Roblox Team object, so both
        sides of the old comparison read nil - which made every catch in the match look
        like a teammate's, and 'Ignore teammate' is on by default, so the spy reported
        nothing at all.
    ]]
    local function sameTeam(player)
        local mine, theirs = lplr:GetAttribute('Team'), player:GetAttribute('Team')
        if mine ~= nil and theirs ~= nil then return mine == theirs end
        if lplr.Team ~= nil and player.Team ~= nil then return lplr.Team == player.Team end
        return false
    end

    --[[
        A count of everything a player is holding, by item type.

        Resources are ordinary inventory items with an amount, the same the game sums for a
        shop purchase, so a catch shows up here as those amounts going up - which is how the
        exact reward is read rather than guessed from the drop table.
    ]]
    local function countsOf(plr)
        local counts = {}
        local ok, inv = pcall(function() return bedwars.getInventory(plr) end)
        if ok and inv and inv.items then
            for _, item in inv.items do
                counts[item.itemType] = (counts[item.itemType] or 0) + (tonumber(item.amount) or 0)
            end
        end
        return counts
    end

    --[[
        A snapshot per fishing player, kept fresh until the catch.

        The reward is the inventory going up, so what it was just before is needed to read
        it. A caster is picked up from their bobber - it carries the shooter's id - and their
        counts are re-read while it is out, so the snapshot is at most a moment old when the
        catch lands and a generator ticking in the meantime does not creep into the total.
    ]]
    local fishingSnaps = {}

    local function watchBobber(part)
        if part.Name ~= 'fisherman_bobber' then return end
        task.spawn(function()
            local shooter
            for _ = 1, 40 do
                shooter = part:GetAttribute('ProjectileShooter')
                if shooter or not part.Parent then break end
                task.wait(0.05)
            end
            if not shooter then return end
            local plr = playersService:GetPlayerByUserId(shooter)
            if not plr or plr == lplr then return end

            fishingSnaps[shooter] = {plr = plr, counts = countsOf(plr)}
            while part.Parent and fishingSnaps[shooter] and not fishingSnaps[shooter].frozen do
                task.wait(0.2)
                local snap = fishingSnaps[shooter]
                if snap and not snap.frozen then
                    snap.counts = countsOf(plr)
                end
            end
        end)
    end

    -- What the catcher actually gained, by diffing their inventory once the credit lands.
    -- Returns nil when there is no before-snapshot to compare against.
    local function exactGains(plr, before)
        if not before then return nil end

        local deadline = os.clock() + 1.5
        while os.clock() < deadline do
            task.wait(0.05)
            local gained, total = {}, 0
            for itemType, amount in countsOf(plr) do
                local delta = amount - (before[itemType] or 0)
                if delta > 0 then gained[itemType] = delta; total += delta end
            end
            if total > 0 then
                -- Let the rest of a multi-item credit settle, then take the final diff.
                task.wait(0.2)
                local settled, settledTotal = {}, 0
                for itemType, amount in countsOf(plr) do
                    local delta = amount - (before[itemType] or 0)
                    if delta > 0 then settled[itemType] = delta; settledTotal += delta end
                end
                return settledTotal >= total and settled or gained
            end
        end
        return nil
    end

    local function setupSpy()
        -- Casters are tracked from their bobbers so a before-snapshot exists by catch time.
        Fisherman:Clean(workspace.ChildAdded:Connect(watchBobber))
        for _, part in workspace:GetChildren() do
            watchBobber(part)
        end

        connectEvent('FishCaught', function(data)
            if not on(SpyToggle) then return end
            if not (data.dropData and data.dropData.drops and data.catchingPlayer) then return end
            local plr = data.catchingPlayer
            if on(Teammates) and sameTeam(plr) then return end

            -- Frozen and read first thing, so the credit that comes with this event does not
            -- land in the before-snapshot.
            local snap = fishingSnaps[plr.UserId]
            local before = snap and snap.counts
            if snap then snap.frozen = true end

            -- A gold fish is the one worth interrupting for, so it gets said whether or
            -- not its loot survived the whitelist.
            if on(GoldNotify) and data.dropData.fishModel == 'fish_gold' then
                notif('Fisherman Spy', `{plr.Name} has caught a <font color='#FFD75A'>Gold</font> fish`, 8, 'info')
            end
            -- The rework put sharks in the water, worth knowing for the same reason.
            if on(SharkNotify) and data.dropData.fishModel == 'shark' then
                notif('Fisherman Spy', `{plr.Name} has caught a <font color='#6FD3FF'>Shark</font>`, 8, 'info')
            end

            task.spawn(function()
                local gained = exactGains(plr, before)
                fishingSnaps[plr.UserId] = nil

                local text = {}
                if gained then
                    -- The exact reward, read from their inventory going up.
                    for itemType, amount in gained do
                        local itemDisplay = displayName(itemType)
                        if lootWanted(itemType, itemDisplay) then
                            text[#text + 1] = `{amount} {itemDisplay}`
                        end
                    end
                else
                    --[[
                        No snapshot to diff - they were already fishing when Spy came on, or
                        their inventory could not be read - so it falls back to the drop
                        table's range. The base is the top of what the drop pays; the server
                        scales it down by the drop's own multipliers, so the range is honest
                        where the exact figure is not available.
                    ]]
                    local scaling = data.dropData.weightScaling
                    local low = scaling and tonumber(scaling.lowScaleMultiplier) or 1
                    local high = scaling and tonumber(scaling.highScaleMultiplier) or 1
                    if low > high then low, high = high, low end
                    for _, v in data.dropData.drops do
                        local itemDisplay = displayName(v.itemType)
                        if lootWanted(v.itemType, itemDisplay) then
                            local base = tonumber(v.amount) or 0
                            local lo = math.max(0, math.floor(base * low + 0.5))
                            local hi = math.max(0, math.floor(base * high + 0.5))
                            text[#text + 1] = lo ~= hi and `{lo}-{hi} {itemDisplay}` or `~{hi} {itemDisplay}`
                        end
                    end
                end
                if #text == 0 then return end

                local fish = fishNames[data.dropData.fishModel] or data.dropData.fishModel
                notif('Fisherman Spy', `{plr.Name} caught a {fish}: {table.concat(text, ', ')}`, 8, 'info')
            end)
        end)
    end

    --[[
        Which minigame settings are on screen.

        Legit plays the real minigame, so the auto-complete timing settings do not apply
        to it and are taken off screen rather than left there doing nothing. Three
        settings can each change this, so they all call the one function instead of each
        trying to work out the others' state.
    ]]
    local function refreshMinigame()
        local auto, legit = on(AutoMinigameToggle), on(LegitToggle)

        for _, setting in {LegitToggle, PullAnimationToggle, MinigameAnimationToggle} do
            if setting and setting.Object then setting.Object.Visible = auto end
        end
        if RandomizeToggle and RandomizeToggle.Object then
            RandomizeToggle.Object.Visible = auto and not legit
        end
        if CompleteDelaySlider and CompleteDelaySlider.Object then
            CompleteDelaySlider.Object.Visible = auto and not legit and not on(RandomizeToggle)
        end
        if RandomRange and RandomRange.Object then
            RandomRange.Object.Visible = auto and not legit and on(RandomizeToggle)
        end
    end

    Fisherman = vain.Categories.Kit:CreateModule({
        Name = 'Fisherman',
        Tooltip = 'Fishes on its own and reports what everyone else lands',
        Function = function(callback)
            if callback then
                setupAnimationControl()
                applyCatchSpeed()
                installHook()
                setupAim()
                setupAutoCast()
                setupSpy()
                setupFishGroups()
            else
                removeHook()
                cleanupAim()
                restoreCatchSpeed()
                cleanupAnimationControl()
                cleanupFishGroups()
                disconnectEvent('FishCaught')
            end
        end
    })
    AutoMinigameToggle = Fisherman:CreateToggle({
        Name = 'Auto Minigame',
        Default = false,
        Tooltip = 'Completes the fishing minigame for you',
        Function = refreshMinigame
    })
    LegitToggle = Fisherman:CreateToggle({
        Name = 'Legit',
        Default = false,
        Visible = false,
        Darker = true,
        Tooltip = 'Actually plays the minigame, steering the marker onto the fish',
        Function = refreshMinigame
    })
    CompleteDelaySlider = Fisherman:CreateSlider({
        Name = 'Complete Delay',
        Min = 0,
        Max = 5,
        Default = 1,
        Decimal = 10,
        Suffix = 's',
        Visible = false,
        Darker = true,
        Tooltip = 'How long to let the minigame run before finishing it'
    })
    RandomizeToggle = Fisherman:CreateToggle({
        Name = 'Randomize Timing',
        Default = false,
        Visible = false,
        Darker = true,
        Tooltip = 'Varies the delay instead of using the same one every time',
        Function = refreshMinigame
    })
    RandomRange = Fisherman:CreateTwoSlider({
        Name = 'Random Delay Range',
        Min = 0.1,
        Max = 5,
        DefaultMin = 0.5,
        DefaultMax = 2,
        Decimal = 10,
        Visible = false,
        Darker = true,
        Tooltip = 'The range the delay is picked from'
    })
    PullAnimationToggle = Fisherman:CreateToggle({
        Name = 'Pull Animation',
        Default = true,
        Visible = false,
        Darker = true,
        Tooltip = 'Plays the rod-pulling animation. Off suppresses the one the game plays itself'
    })
    MinigameAnimationToggle = Fisherman:CreateToggle({
        Name = 'Success Animation',
        Default = true,
        Visible = false,
        Darker = true,
        Tooltip = 'Plays the catch animation. Off suppresses the one the game plays itself'
    })
    CatchSpeedSlider = Fisherman:CreateSlider({
        Name = 'Catch Speed Increase',
        Min = 0,
        Max = 20,
        Default = 0,
        Decimal = 1,
        Suffix = '%',
        Tooltip = 'Fills the catch bar faster, including when you play the minigame yourself',
        Function = function()
            if Fisherman.Enabled then applyCatchSpeed() end
        end
    })
    BlacklistOption = Fisherman:CreateToggle({
        Name = 'Blacklist',
        Default = false,
        Tooltip = 'Skips catching certain fish',
        Function = function(cv)
            if Blacklist and Blacklist.Object then Blacklist.Object.Visible = cv end
        end
    })
    Blacklist = Fisherman:CreateTextList({
        Name = 'Blacklist Fish',
        Visible = false,
        Darker = true,
        Tooltip = 'Fish to skip, one per line',
        Default = { 'fish_iron' }
    })
    AutoCast = Fisherman:CreateToggle({
        Name = 'AutoCast',
        Default = false,
        Tooltip = 'Casts over a clear edge, or into a nearby shoal',
        Function = function(cv)
            for _, setting in {AutoCastDelay, CastAtShoals} do
                if setting and setting.Object then setting.Object.Visible = cv end
            end
            if ShoalRange and ShoalRange.Object then ShoalRange.Object.Visible = cv and on(CastAtShoals) end
            if Fisherman.Enabled and cv then setupAutoCast() end
        end
    })
    AutoCastDelay = Fisherman:CreateTwoSlider({
        Name = 'Cast Delay',
        Min = 0,
        Max = 5,
        Decimal = 5,
        DefaultMin = 0.3,
        DefaultMax = 1.2,
        Visible = false,
        Darker = true,
        Tooltip = 'How long to wait before each cast'
    })
    CastAtShoals = Fisherman:CreateToggle({
        Name = 'Cast At Shoals',
        Default = true,
        Visible = false,
        Darker = true,
        Tooltip = 'Aims into a shoal in reach - shark shoals first',
        Function = function(cv)
            if ShoalRange and ShoalRange.Object then ShoalRange.Object.Visible = cv and on(AutoCast) end
        end
    })
    ShoalRange = Fisherman:CreateSlider({
        Name = 'Shoal Range',
        Min = 5,
        Max = 40,
        Default = 35,
        Visible = false,
        Darker = true,
        Tooltip = 'How far away a shoal can be\nThe bobber reaches about 21 studs on the level',
        Suffix = function(val)
            return val == 1 and 'stud' or 'studs'
        end
    })
    FishGroupESP = Fisherman:CreateToggle({
        Name = 'Fish Group ESP',
        Default = false,
        Tooltip = 'Marks each shoal the rework spawns, named by tier',
        Function = function(cv)
            if not cv then
                cleanupFishGroups()
            elseif Fisherman.Enabled then
                setupFishGroups()
            end
        end
    })
    SpyToggle = Fisherman:CreateToggle({
        Name = 'Spy',
        Default = false,
        Tooltip = 'Reports what everyone else catches',
        Function = function(cv)
            for _, s in {Teammates, GoldNotify, SharkNotify, LootWhitelist} do
                if s and s.Object then s.Object.Visible = cv end
            end
            if Fisherman.Enabled and cv then setupSpy() end
        end
    })
    Teammates = Fisherman:CreateToggle({
        Name = 'Ignore teammate',
        Default = true,
        Visible = false,
        Darker = true,
        Tooltip = 'Ignores players on your own team'
    })
    GoldNotify = Fisherman:CreateToggle({
        Name = 'Notify on Gold',
        Default = false,
        Visible = false,
        Darker = true,
        Tooltip = 'A line of its own whenever anyone lands a Gold Fish'
    })
    SharkNotify = Fisherman:CreateToggle({
        Name = 'Notify on Shark',
        Default = true,
        Visible = false,
        Darker = true,
        Tooltip = 'A line of its own whenever anyone lands a Shark'
    })
    LootWhitelist = Fisherman:CreateTextList({
        Name = 'Loot Whitelist',
        Visible = false,
        Darker = true,
        Tooltip = 'Only report catches of these items. Starts with everything catchable',
        Placeholder = 'item name (e.g. diamond)',
        -- Every item the fisherman drop tables can pay out, so trimming the list down is
        -- all there is to do.
        Default = {
            'iron',
            'diamond',
            'emerald',
            'obsidian',
            'tnt',
            'siege_tnt',
            'fireball',
            'charge_shield',
            'rocket_launcher',
            'rocket_launcher_missile',
            'blastproof_ceramic',
            'glue_projectile',
            'fisherman_coral'
        }
    })
end)

kitRun(function()
    local StarCollector
    local CollectionToggle
    local Animation
    local RangeSlider
    local ESPToggle
    local ESPNotify
    local ESPBackground
    local ESPColor
    local SwordCheck
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local Reference = {}
    local starCooldowns = {}
    local COOLDOWN_TIME = 0.5
    local lastNotification = 0
    local spawnQueue = {}
    local notificationCooldown = 1
    local collectionRunning = false

    local function sendNotification(count)
    end

    local function processSpawnQueue()
        if #spawnQueue > 0 then
            local currentTime = tick()
            if currentTime - lastNotification >= notificationCooldown then
                sendNotification(#spawnQueue)
                lastNotification = currentTime
                spawnQueue = {}
            else
                task.delay(notificationCooldown - (currentTime - lastNotification), function()
                    if #spawnQueue > 0 then
                        sendNotification(#spawnQueue)
                        spawnQueue = {}
                    end
                end)
            end
        end
    end

    local function getProperImage(v)
        local parent = v.Parent
        if parent and parent:IsA("Model") then
            local modelName = parent.Name
            if modelName == "CritStar" then
                return bedwars.getIcon({itemType = 'crit_star'}, true)
            elseif modelName == "VitalityStar" then
                return bedwars.getIcon({itemType = 'vitality_star'}, true)
            elseif modelName:find("vitality") or modelName:lower():find("vitality") then
                return bedwars.getIcon({itemType = 'vitality_star'}, true)
            elseif modelName:find("crit") or modelName:lower():find("crit") then
                return bedwars.getIcon({itemType = 'crit_star'}, true)
            end
        end
        return bedwars.getIcon({itemType = 'crit_star'}, true)
    end

    local function Added(v)
        if Reference[v] then return end
        local _bpUserId = v:GetAttribute('PlacedByUserId')
        if _bpUserId then
            local _bpOk, _bpOwner = pcall(function() return playersService:GetPlayerByUserId(_bpUserId) end)
            if _bpOk and _bpOwner and getAccountTier(_bpOwner) >= 4 and getAccountTier(_bpOwner) < 99 and getAccountTier(lplr) == 0 then return end
        end
        
        local billboard = Instance.new('BillboardGui')
        billboard.Parent = Folder
        billboard.Name = 'stars'
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
        billboard.Size = UDim2.fromOffset(36, 36)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = v
        
        local blur = addBlur(billboard)
        blur.Visible = ESPBackground.Enabled
        
        local image = Instance.new('ImageLabel')
        image.Size = UDim2.fromOffset(36, 36)
        image.Position = UDim2.fromScale(0.5, 0.5)
        image.AnchorPoint = Vector2.new(0.5, 0.5)
        image.BackgroundColor3 = Color3.fromHSV(ESPColor.Hue, ESPColor.Sat, ESPColor.Value)
        image.BackgroundTransparency = 1 - (ESPBackground.Enabled and ESPColor.Opacity or 0)
        image.BorderSizePixel = 0
        image.Image = getProperImage(v)
        image.Parent = billboard
        
        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 4)
        uicorner.Parent = image
        
        Reference[v] = billboard
        
        if ESPNotify.Enabled then
            table.insert(spawnQueue, {item = 'star', time = tick()})
            processSpawnQueue()
        end
    end

    local function Removed(v)
        if Reference[v] then
            Reference[v]:Destroy()
            Reference[v] = nil
        end
        starCooldowns[v] = nil
    end

    local function setupESP()
        for _, v in collectionService:GetTagged('stars') do
            if v:IsA("Model") and v.PrimaryPart then
                Added(v.PrimaryPart)
            end
        end

        StarCollector:Clean(collectionService:GetInstanceAddedSignal('stars'):Connect(function(v)
            if v:IsA("Model") and v.PrimaryPart then
                task.wait(0.1)
                Added(v.PrimaryPart)
            end
        end))

        StarCollector:Clean(collectionService:GetInstanceRemovedSignal('stars'):Connect(function(v)
            if v.PrimaryPart then
                Removed(v.PrimaryPart)
            end
        end))
        
        local _scLastUpdate = 0
        StarCollector:Clean(runService.RenderStepped:Connect(function()
            if not ESPToggle.Enabled then return end
            local _now = tick()
            if _now - _scLastUpdate < 0.1 then return end
            _scLastUpdate = _now
            
            for v, billboard in pairs(Reference) do
                if not v or not v.Parent then
                    Removed(v)
                    continue
                end

                local shouldShow = true

                if SwordCheck.Enabled and isSword() then
                    shouldShow = false
                end

                billboard.Enabled = shouldShow
            end
        end))
    end

    local function collectStar(star)
        if not star or not star.Parent then return end
        
        if Animation.Enabled and entitylib.isAlive then
            bedwars.GameAnimationUtil:playAnimation(lplr, bedwars.AnimationType.PUNCH)
            bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_USE_ITEM)
        end
        
        bedwars.StarCollectorController:collectEntity(lplr, star, star.Name)
    end

	local function startCollection()
		collectionRunning = true
		task.spawn(function()
			while collectionRunning and StarCollector.Enabled and CollectionToggle.Enabled do
				if not entitylib.isAlive then
					task.wait(0.1)
					continue
				end

				local localPosition = entitylib.character.RootPart.Position
				local range = RangeSlider.Value
				local collected = false

				for _, v in collectionService:GetTagged('stars') do
					if not collectionRunning or not StarCollector.Enabled or not CollectionToggle.Enabled then
						break
					end

					if v:IsA("Model") and v.PrimaryPart then
						local starPos = v.PrimaryPart.Position
						local distance = (localPosition - starPos).Magnitude

						if distance <= range then
							local lastAttempt = starCooldowns[v]
							if lastAttempt and tick() - lastAttempt < COOLDOWN_TIME then
								continue
							end
							starCooldowns[v] = tick()
							collectStar(v)
							collected = true
							break
						end
					end
				end

				task.wait(collected and 0.1 or 0.2)
			end
			collectionRunning = false
		end)
	end

    StarCollector = vain.Categories.Kit:CreateModule({
        Name = 'Auto Star',
        Tooltip = 'Automatically collects falling stars',
        Function = function(callback)
            if callback then
                if ESPToggle.Enabled then 
                    setupESP() 
                end
                
                if CollectionToggle.Enabled then
                    startCollection()
                end
            else
                collectionRunning = false
                Folder:ClearAllChildren()
                table.clear(Reference)
                table.clear(spawnQueue)
                table.clear(starCooldowns)
                lastNotification = 0
            end
        end,
        Tooltip = 'automatically collects stars and esp'
    })
    
    CollectionToggle = StarCollector:CreateToggle({
        Name = 'Auto Collect',
        Default = true,
        Tooltip = 'automatically collect stars',
        Function = function(callback)
            if Animation and Animation.Object then Animation.Object.Visible = callback end
            if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = callback end
            
            if callback and StarCollector.Enabled then
                startCollection()
            else
                collectionRunning = false
            end
        end
    })
    
    Animation = StarCollector:CreateToggle({
        Name = 'Animation',
        Default = true,
        Tooltip = 'play collection animation and sound'
    })
    
    RangeSlider = StarCollector:CreateSlider({
        Name = 'Range',
        Min = 1, 
        Max = 18,
        Default = 10,
        Decimal = 1,
        Suffix = ' studs',
        Tooltip = 'control distance you want to collect stars'
    })
    
    ESPToggle = StarCollector:CreateToggle({
        Name = 'Star ESP',
        Default = false,
        Tooltip = 'shows star locations',
        Function = function(callback)
            if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = callback end
            if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = callback end
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            if SwordCheck and SwordCheck.Object then SwordCheck.Object.Visible = callback end
            
            if StarCollector.Enabled then
                if callback then 
                    setupESP() 
                else
                    Folder:ClearAllChildren()
                    table.clear(Reference)
                end
            end
        end
    })
    
    ESPNotify = StarCollector:CreateToggle({
        Name = 'Notify',
        Default = false,
        Tooltip = 'get notifications when stars spawn'
    })
    
    ESPBackground = StarCollector:CreateToggle({
        Name = 'Background',
        Tooltip = 'Renders a background box behind this ESP element',
        Default = true,
        Function = function(callback)
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundTransparency = 1 - (callback and ESPColor.Opacity or 0)
                    if v:FindFirstChild("Blur") then
                        v.Blur.Visible = callback
                    end
                end
            end
        end
    })
    
    ESPColor = StarCollector:CreateColorSlider({
        Name = 'Background Color',
        Tooltip = 'Color of the background box behind this ESP element',
        DefaultValue = 0,
        DefaultOpacity = 0.5,
        Function = function(hue, sat, val, opacity)
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                    v.ImageLabel.BackgroundTransparency = 1 - opacity
                end
            end
        end,
        Darker = true
    })
    SwordCheck = StarCollector:CreateToggle({
        Name = 'Sword Check',
        Default = false,
        Tooltip = 'only show esp when holding a sword'
    })

    task.defer(function()
        local espOn = ESPToggle and ESPToggle.Enabled
        if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = espOn end
        if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = espOn end
        if ESPColor and ESPColor.Object then ESPColor.Object.Visible = espOn end
        if SwordCheck and SwordCheck.Object then SwordCheck.Object.Visible = espOn end
    end)
end)

kitRun(function()
    local Gingerbread
    local LimitToItem
    local BreakDelay
    local BreakDelaySlider
    local AutoSwitch
    local SwitchMode
    
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local lastBreakTime = 0
    local lastPlaceTime = 0
    local placeCheckConnection
    local justPlacedGumdrop = false
    local lastPlacedPosition = nil
    
    _G.gingerLock = _G.gingerLock or false
    
    local function getGumdropSlot()
        for i, v in store.inventory.hotbar do
            if v.item and v.item.itemType == "gumdrop_bounce_pad" then
                return i - 1
            end
        end
        return nil
    end
    
    local function getPredictedPosition()
        if not (lplr.Character and lplr.Character.PrimaryPart) then return nil end
        local root = lplr.Character.PrimaryPart
        local velocity = root.AssemblyLinearVelocity
        local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
        local speed = horizontalVelocity.Magnitude
        if speed < 1 then return root.Position end
        local predictionTime = math.clamp(speed / 40, 0.15, 0.35)
        return root.Position + (horizontalVelocity * predictionTime)
    end
    
    local function tryPlaceGumdrop()
        if not AutoSwitch.Enabled or _G.gingerLock then return end
        if not (lplr.Character and lplr.Character.PrimaryPart) then return end
        
        local inFirstPerson = isFirstPerson()
        if SwitchMode.Value == 'First Person' and not inFirstPerson then return end
        if SwitchMode.Value == 'Third Person' and inFirstPerson then return end
        
        local velocity = lplr.Character.PrimaryPart.AssemblyLinearVelocity.Y
        if velocity >= -5 then return end
        
        local gumdropSlot = getGumdropSlot()
        if not gumdropSlot then return end
        
        local root = lplr.Character.PrimaryPart
        local targetPos = getPredictedPosition() or root.Position
        local checkPos = targetPos - Vector3.new(0, 3, 0)
        local groundBlockPos = nil
        
        for i = 1, 16 do
            local testPos = checkPos - Vector3.new(0, 3 * (i - 1), 0)
            local block, blockpos = getPlacedBlock(roundPos(testPos))
            if block then
                groundBlockPos = blockpos * 3
                break
            end
        end
        
        if not groundBlockPos then return end
        
        local distanceToGround = root.Position.Y - groundBlockPos.Y
        if distanceToGround < 9 or distanceToGround > 18 then return end
        
        local placePos = groundBlockPos + Vector3.new(0, 3, 0)
        if lastPlacedPosition and (lastPlacedPosition - placePos).Magnitude < 1 then return end
        if getPlacedBlock(placePos) then return end
        
        _G.gingerLock = true
        
        if hotbarSwitch(gumdropSlot) then
            task.wait(0.03)
            local success = pcall(function()
                bedwars.placeBlock(placePos, "gumdrop_bounce_pad", false)
            end)
            
            if success then
                lastPlaceTime = tick()
                justPlacedGumdrop = true
                lastPlacedPosition = placePos
                
                task.wait(0.03)
                local pickaxeSlot = getPickaxeSlot()
                if pickaxeSlot then
                    hotbarSwitch(pickaxeSlot)
                    task.wait(0.08)
                    local placedBlock = getPlacedBlock(placePos)
                    if placedBlock and placedBlock.Name == "gumdrop_bounce_pad" then
                        task.spawn(bedwars.breakBlock, placedBlock, false, nil, true)
                        lastBreakTime = tick()
                    end
                end
            end
        end
        
        _G.gingerLock = false
    end
    
    Gingerbread = vain.Categories.Kit:CreateModule({
        Name = 'Auto Ginger',
        Tooltip = 'Automates Gingerbread Man kit launch pad usage',
        Function = function(callback)
            if callback then
                local old = bedwars.LaunchPadController.attemptLaunch
                bedwars.LaunchPadController.attemptLaunch = function(...)
                    local res = {old(...)}
                    local self, block = ...
                    
                    if block:GetAttribute('PlacedByUserId') == lplr.UserId and
                       (block.Position - entitylib.character.RootPart.Position).Magnitude < 30 then

                        if LimitToItem.Enabled and not isHoldingPickaxe() then
                            return unpack(res)
                        end

                        local inFP = isFirstPerson()
					local cameraAllowed = not AutoSwitch.Enabled or (SwitchMode.Value ~= 'First Person' or inFP) and (SwitchMode.Value ~= 'Third Person' or not inFP)
					local shouldAutoSwitch = AutoSwitch.Enabled and not isHoldingPickaxe() and cameraAllowed and not _G.gingerLock

                        if shouldAutoSwitch then
                            local pickaxeSlot = getPickaxeSlot()
                            if pickaxeSlot then
                                _G.gingerLock = true
                                task.spawn(function()
                                    if hotbarSwitch(pickaxeSlot) then
                                        task.wait(0.03)
                                        task.spawn(bedwars.breakBlock, block, false, nil, true)
                                        task.spawn(bedwars.breakBlock, block, false, nil, true)
                                        lastBreakTime = tick()
                                        justPlacedGumdrop = false
                                    end
                                    _G.gingerLock = false
                                end)
                            end
                        else
                            local currentTime = tick()
                            local shouldBreak = true
                            if not AutoSwitch.Enabled and BreakDelay.Enabled and not justPlacedGumdrop then
                                if (currentTime - lastBreakTime) < BreakDelaySlider.Value then
                                    shouldBreak = false
                                end
                            end
                            if shouldBreak then
                                task.spawn(bedwars.breakBlock, block, false, nil, true)
                                task.spawn(bedwars.breakBlock, block, false, nil, true)
                                lastBreakTime = currentTime
                                justPlacedGumdrop = false
                            end
                        end

                        local cameraAllowed = true
                        if AutoSwitch.Enabled then
                            local inFirstPerson = isFirstPerson()
                            if SwitchMode.Value == 'First Person' and not inFirstPerson then
                                cameraAllowed = false
                            elseif SwitchMode.Value == 'Third Person' and inFirstPerson then
                                cameraAllowed = false
                            end
                        end

                        if isHoldingPickaxe() then
                            local currentTime = tick()
                            local shouldBreak = true
                            
                            if not AutoSwitch.Enabled and BreakDelay.Enabled and not justPlacedGumdrop then
                                if (currentTime - lastBreakTime) < BreakDelaySlider.Value then
                                    shouldBreak = false
                                end
                            end
                            
                            if shouldBreak then
                                task.spawn(bedwars.breakBlock, block, false, nil, true)
                                task.spawn(bedwars.breakBlock, block, false, nil, true)
                                lastBreakTime = currentTime
                                justPlacedGumdrop = false
                            end
                        elseif AutoSwitch.Enabled and cameraAllowed and not _G.gingerLock then
                            local pickaxeSlot = getPickaxeSlot()
                            if pickaxeSlot then
                                _G.gingerLock = true
                                task.spawn(function()
                                    if hotbarSwitch(pickaxeSlot) then
                                        task.wait(0.03)
                                        task.spawn(bedwars.breakBlock, block, false, nil, true)
                                        task.spawn(bedwars.breakBlock, block, false, nil, true)
                                        lastBreakTime = tick()
                                        justPlacedGumdrop = false
                                    end
                                    _G.gingerLock = false
                                end)
                            end
                        end
                    end
                    
                    return unpack(res)
                end
                
				if AutoSwitch.Enabled then
                    if placeCheckConnection then
                        placeCheckConnection:Disconnect()
                        placeCheckConnection = nil
                    end
                    placeCheckConnection = runService.RenderStepped:Connect(function()
                        if not _G.gingerLock and entitylib.isAlive and tick() - lastPlaceTime > 0.15 then
                            tryPlaceGumdrop()
                        end
                    end)
                end
                
                Gingerbread:Clean(function()
                    bedwars.LaunchPadController.attemptLaunch = old
                    if placeCheckConnection then
                        placeCheckConnection:Disconnect()
                        placeCheckConnection = nil
                    end
                end)
            else
                lastBreakTime = 0
                lastPlaceTime = 0
                justPlacedGumdrop = false
                lastPlacedPosition = nil
                _G.gingerLock = false
                if placeCheckConnection then
                    placeCheckConnection:Disconnect()
                    placeCheckConnection = nil
                end
            end
        end,
        Tooltip = 'Advanced gumdrop loop with movement prediction'
    })

    LimitToItem = Gingerbread:CreateToggle({
        Name = 'Limit to Pickaxe',
        Default = true,
        Tooltip = 'only breaks gumdrop when holding a pickaxe'
    })
    
    BreakDelay = Gingerbread:CreateToggle({
        Name = 'Break Delay',
        Tooltip = 'Enables or disables break delay',
        Default = false,
        Function = function(callback)
            if BreakDelaySlider and BreakDelaySlider.Object then
                BreakDelaySlider.Object.Visible = callback and not AutoSwitch.Enabled
            end
        end,
        Tooltip = 'Add delay before breaking gumdrops'
    })
    
    BreakDelaySlider = Gingerbread:CreateSlider({
        Name = 'Delay',
        Min = 0,
        Max = 2,
        Default = 0.5,
        Decimal = 10,
        Suffix = 's',
        Visible = false,
        Tooltip = 'Delay in seconds before breaking'
    })
    
	AutoSwitch = Gingerbread:CreateToggle({
        Name = 'Auto-Switch',
        Tooltip = 'Automatically switches to the required item',
        Default = false,
        Function = function(callback)
            if SwitchMode and SwitchMode.Object then SwitchMode.Object.Visible = callback end
            if BreakDelay and BreakDelay.Object then BreakDelay.Object.Visible = not callback end
            if BreakDelaySlider and BreakDelaySlider.Object then
                BreakDelaySlider.Object.Visible = (not callback) and BreakDelay.Enabled
            end
            if LimitToItem and LimitToItem.Object then LimitToItem.Object.Visible = not callback end

            if placeCheckConnection then
                placeCheckConnection:Disconnect()
                placeCheckConnection = nil
            end

            if callback and Gingerbread.Enabled then
                placeCheckConnection = runService.RenderStepped:Connect(function()
                    if not _G.gingerLock and entitylib.isAlive and tick() - lastPlaceTime > 0.15 then
                        tryPlaceGumdrop()
                    end
                end)
            end
        end,
        Tooltip = 'Autoswitch, break, and place with smart movement prediction'
    })
    
    SwitchMode = Gingerbread:CreateDropdown({
        Name = 'View Mode',
        List = {'Both', 'First Person', 'Third Person'},
        Default = 'Both',
        Visible = false,
        Tooltips = {
            Both = 'Works in either view',
            ['First Person'] = 'Only while the camera is in your head',
            ['Third Person'] = 'Only while the camera is behind you'
        },
        Tooltip = 'Which camera view this works in'
    })
end)

kitRun(function()
    local Grove
    local NoSlow
    local NoSlowOnAbility
    local AutoWater
    local AutoWaterRange
    local AutoCollect
    local CollectRange
    local SpiritESP
    local ESPNotify
    local ESPBackground
    local ESPColor
    local DistanceCheck
    local DistanceLimit
    
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local Reference = {}
    local lastNotification = 0
    local spawnQueue = {}
    local notificationCooldown = 1
    local noSlowActive = false
    local autoWaterActive = false
    local autoCollectActive = false
    local originalDisableActionsOnCharge
    local originalCheckForPickup
    
    local function sendNotification(count)
    end

    local function processSpawnQueue()
        if #spawnQueue > 0 then
            local currentTime = tick()
            if currentTime - lastNotification >= notificationCooldown then
                sendNotification(#spawnQueue)
                lastNotification = currentTime
                spawnQueue = {}
            else
                task.delay(notificationCooldown - (currentTime - lastNotification), function()
                    if #spawnQueue > 0 then
                        sendNotification(#spawnQueue)
                        spawnQueue = {}
                    end
                end)
            end
        end
    end

    local function getProperImage()
        return bedwars.getIcon({itemType = 'spirit'}, true)
    end

    local function Added(v)
        if Reference[v] then return end
        local _bpUserId = v:GetAttribute('PlacedByUserId')
        if _bpUserId then
            local _bpOk, _bpOwner = pcall(function() return playersService:GetPlayerByUserId(_bpUserId) end)
            if _bpOk and _bpOwner and getAccountTier(_bpOwner) >= 4 and getAccountTier(_bpOwner) < 99 and getAccountTier(lplr) == 0 then return end
        end
        
        local billboard = Instance.new('BillboardGui')
        billboard.Parent = Folder
        billboard.Name = 'spirit-energy'
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
        billboard.Size = UDim2.fromOffset(36, 36)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = v
        
        local blur = addBlur(billboard)
        blur.Visible = ESPBackground.Enabled
        
        local image = Instance.new('ImageLabel')
        image.Size = UDim2.fromOffset(36, 36)
        image.Position = UDim2.fromScale(0.5, 0.5)
        image.AnchorPoint = Vector2.new(0.5, 0.5)
        image.BackgroundColor3 = Color3.fromHSV(ESPColor.Hue, ESPColor.Sat, ESPColor.Value)
        image.BackgroundTransparency = 1 - (ESPBackground.Enabled and ESPColor.Opacity or 0)
        image.BorderSizePixel = 0
        image.Image = getProperImage()
        image.Parent = billboard
        
        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 4)
        uicorner.Parent = image
        
        Reference[v] = billboard
        
        if ESPNotify.Enabled then
            table.insert(spawnQueue, {item = 'spirit', time = tick()})
            processSpawnQueue()
        end
    end

    local function Removed(v)
        if Reference[v] then
            Reference[v]:Destroy()
            Reference[v] = nil
        end
    end

    local function setupESP()
        for _, v in workspace:GetChildren() do
            if v.Name == "SpiritGardenerEnergy" and v:IsA("Model") and v.PrimaryPart then
                Added(v.PrimaryPart)
            end
        end

        Grove:Clean(workspace.ChildAdded:Connect(function(v)
            if v.Name == "SpiritGardenerEnergy" and v:IsA("Model") then
                task.wait(0.1)
                if v.PrimaryPart then
                    Added(v.PrimaryPart)
                end
            end
        end))

        Grove:Clean(workspace.ChildRemoved:Connect(function(v)
            if v.Name == "SpiritGardenerEnergy" and v.PrimaryPart then
                Removed(v.PrimaryPart)
            end
        end))

        Grove:Clean(runService.RenderStepped:Connect(function()
            if not SpiritESP.Enabled then return end
            
            for v, billboard in pairs(Reference) do
                if not v or not v.Parent then
                    Removed(v)
                    continue
                end

                local shouldShow = true

                if shouldShow and DistanceCheck.Enabled and entitylib.isAlive then
                    local distance = (entitylib.character.RootPart.Position - v.Position).Magnitude
                    if distance < DistanceLimit.ValueMin or distance > DistanceLimit.ValueMax then
                        shouldShow = false
                    end
                end

                billboard.Enabled = shouldShow
            end
        end))
    end

    local function getNearbyFlowers()
        local flowers = {}
        if not entitylib.isAlive then return flowers end
        
        local localPosition = entitylib.character.RootPart.Position
        local range = AutoWaterRange.Value
        
        for _, v in collectionService:GetTagged('SpiritGardenerFlower') do
            if v:IsA("Model") and v.PrimaryPart then
                if v:GetAttribute("PlacedByUserId") == lplr.UserId then
                    local needsEnergy = not v:GetAttribute("HasFullyGrown")
                    if needsEnergy then
                        local distance = (localPosition - v.PrimaryPart.Position).Magnitude
                        if distance <= range then
                            table.insert(flowers, v)
                        end
                    end
                end
            end
        end
        
        return flowers
    end

    local function useWaterAbility()
        local success = pcall(function()
            game:GetService("ReplicatedStorage"):WaitForChild("events-@easy-games/game-core:shared/game-core-networking@getEvents.Events"):WaitForChild("useAbility"):FireServer("spirit_gardener_water")
        end)
        return success
    end

    local function startAutoWater()
        if autoWaterActive then return end
        autoWaterActive = true
        
        task.spawn(function()
            while Grove.Enabled and AutoWater.Enabled and autoWaterActive do
                if not entitylib.isAlive then 
                    task.wait(0.5)
                    continue 
                end
                
                local flowers = getNearbyFlowers()
                
                if #flowers > 0 then
                    if useWaterAbility() then
                        task.wait(0.6) 
                    else
                        task.wait(0.3)
                    end
                else
                    task.wait(0.5)
                end
            end
            
            autoWaterActive = false
        end)
    end

    local function stopAutoWater()
        autoWaterActive = false
    end

    local function hookAutoCollect()
        if not bedwars.SpiritGardenerSeedController then return end
        
        originalCheckForPickup = bedwars.SpiritGardenerSeedController.checkForPickup
        
        bedwars.SpiritGardenerSeedController.checkForPickup = function(self)
            if not AutoCollect.Enabled then
                return originalCheckForPickup(self)
            end
            
            local Players = playersService
            local CollectionService = collectionService
            local Workspace = game:GetService("Workspace")
            
            local Character = Players.LocalPlayer.Character
            if not Character or not Character.PrimaryPart then
                return nil
            end
            
            local localPosition = Character.PrimaryPart.Position
            local range = CollectRange.Value
            
            local validTypes = self:validCollectableEntityTypes()
            
            for _, collectableType in validTypes do
                local tagged = CollectionService:GetTagged(collectableType)
                
                for _, orb in tagged do
                    local spawnTime = orb:GetAttribute("SpawnTime")
                    if spawnTime and (Workspace:GetServerTimeNow() - spawnTime) >= 1 then
                        local orbPosition = orb:GetPivot().Position
                        local distance = (localPosition - orbPosition).Magnitude
                        
                        if distance <= range then
                            self:collectEntity(Players.LocalPlayer, orb, collectableType)
                        end
                    end
                end
            end
        end
    end

    local function unhookAutoCollect()
        if originalCheckForPickup and bedwars.SpiritGardenerSeedController then
            bedwars.SpiritGardenerSeedController.checkForPickup = originalCheckForPickup
        end
    end

    local function startAutoCollect()
        if autoCollectActive then return end
        autoCollectActive = true
        
        hookAutoCollect()
        
        if bedwars.SpiritGardenerSeedController then
            pcall(function()
                bedwars.SpiritGardenerSeedController:listenToPickup()
            end)
        end
    end

    local function stopAutoCollect()
        autoCollectActive = false
        unhookAutoCollect()
    end

    local function hookNoSlow()
        if not bedwars.SpiritGardenerController then return end
        
        originalDisableActionsOnCharge = bedwars.SpiritGardenerController.disableActionsOnCharge
        
        bedwars.SpiritGardenerController.disableActionsOnCharge = function(self, maid, character)
            if not NoSlow.Enabled then
                return originalDisableActionsOnCharge(self, maid, character)
            end
            
            if NoSlowOnAbility.Enabled then
                local isLocalPlayer = character == lplr.Character
                if not isLocalPlayer then
                    return originalDisableActionsOnCharge(self, maid, character)
                end
            end
            
            if character == lplr.Character then
                -- The game's controllers by name, through the bedwars table's own fallback.
                local KnitClient = {Controllers = setmetatable({}, {__index = function(_, name) return bedwars[name] end})}
                
                KnitClient.Controllers.SwordController:toggleSwordSwing(true)
                KnitClient.Controllers.BlockPlacementController:disableBlockPlacer()
                
                local ClientSyncEvents = debug.getupvalue(originalDisableActionsOnCharge, 3)
                local projectileConnection = ClientSyncEvents.BeginProjectileTargeting:connect(function(event)
                    event:setCancelled(true)
                    return nil
                end)
                
                local jumpModifier = KnitClient.Controllers.JumpHeightController:getJumpModifier():addModifier({
                    jumpHeightMultiplier = 0;
                })
                
                maid:GiveTask(function()
                    KnitClient.Controllers.SwordController:toggleSwordSwing(false)
                    KnitClient.Controllers.BlockPlacementController:enableBlockPlacer()
                    projectileConnection:Destroy()
                    jumpModifier.Destroy()
                end)
            end
        end
    end

    local function unhookNoSlow()
        if originalDisableActionsOnCharge and bedwars.SpiritGardenerController then
            bedwars.SpiritGardenerController.disableActionsOnCharge = originalDisableActionsOnCharge
        end
    end

    Grove = vain.Categories.Kit:CreateModule({
        Name = 'Auto Grove',
        Tooltip = 'Automates the Grove kit ability',
        Function = function(callback)
            if callback then
                if SpiritESP.Enabled then 
                    setupESP() 
                end
                
                if NoSlow.Enabled then
                    hookNoSlow()
                end
                
                if AutoWater.Enabled then
                    startAutoWater()
                end
                
                if AutoCollect.Enabled then
                    startAutoCollect()
                end
            else
                stopAutoWater()
                stopAutoCollect()
                unhookNoSlow()
                Folder:ClearAllChildren()
                table.clear(Reference)
                table.clear(spawnQueue)
                lastNotification = 0
            end
        end,
        Tooltip = 'Spirit Gardener kit features - NoSlow, Auto Water, Auto Collect, and Spirit ESP'
    })
    
    NoSlow = Grove:CreateToggle({
        Name = 'No Slow',
        Default = false,
        Tooltip = 'Remove movement lock when using water ability',
        Function = function(callback)
            if NoSlowOnAbility and NoSlowOnAbility.Object then 
                NoSlowOnAbility.Object.Visible = callback 
            end
            
            if Grove.Enabled then
                if callback then
                    hookNoSlow()
                else
                    unhookNoSlow()
                end
            end
        end
    })
    
    NoSlowOnAbility = Grove:CreateToggle({
        Name = 'Only On Ability Use',
        Default = false,
        Tooltip = 'NoSlow only works when you manually use the ability'
    })
    
    AutoWater = Grove:CreateToggle({
        Name = 'Auto Water',
        Default = false,
        Tooltip = 'Automatically water nearby flowers that need energy',
        Function = function(callback)
            if AutoWaterRange and AutoWaterRange.Object then 
                AutoWaterRange.Object.Visible = callback 
            end
            
            if Grove.Enabled then
                if callback then
                    startAutoWater()
                else
                    stopAutoWater()
                end
            end
        end
    })
    
    AutoWaterRange = Grove:CreateSlider({
        Name = 'Water Range',
        Min = 1, 
        Max = 30,
        Default = 20,
        Decimal = 1,
        Suffix = ' studs',
        Tooltip = 'Distance to auto water flowers'
    })
    
    AutoCollect = Grove:CreateToggle({
        Name = 'Auto Collect',
        Default = false,
        Tooltip = 'Automatically collect spirit energy orbs from extended range',
        Function = function(callback)
            if CollectRange and CollectRange.Object then 
                CollectRange.Object.Visible = callback 
            end
            
            if Grove.Enabled then
                if callback then
                    startAutoCollect()
                else
                    stopAutoCollect()
                end
            end
        end
    })
    
    CollectRange = Grove:CreateSlider({
        Name = 'Collect Range',
        Min = 5, 
        Max = 12,
        Default = 12,
        Decimal = 10,
        Suffix = ' studs',
        Tooltip = 'Distance to auto collect spirit orbs (default: 5.5)'
    })
    
    SpiritESP = Grove:CreateToggle({
        Name = 'Spirit ESP',
        Default = false,
        Tooltip = 'Shows spirit energy orb locations',
        Function = function(callback)
            if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = callback end
            if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = callback end
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            if DistanceCheck and DistanceCheck.Object then DistanceCheck.Object.Visible = callback end
            if DistanceLimit and DistanceLimit.Object then
                DistanceLimit.Object.Visible = (callback and DistanceCheck.Enabled)
            end

            if not callback then
                if ESPColor and ESPColor.Object then
                    ESPColor.Object.Visible = false
                end
                if DistanceLimit and DistanceLimit.Object then
                    DistanceLimit.Object.Visible = false
                end
            else
                if ESPBackground and ESPBackground.Enabled then
                    if ESPColor and ESPColor.Object then
                        ESPColor.Object.Visible = true
                    end
                end
                if DistanceCheck and DistanceCheck.Enabled then
                    if DistanceLimit and DistanceLimit.Object then
                        DistanceLimit.Object.Visible = true
                    end
                end
            end
            
            if Grove.Enabled then
                if callback then 
                    setupESP() 
                else
                    Folder:ClearAllChildren()
                    table.clear(Reference)
                end
            end
        end
    })
    
    ESPNotify = Grove:CreateToggle({
        Name = 'Notify',
        Default = false,
        Tooltip = 'Get notifications when spirit orbs spawn'
    })
    
    ESPBackground = Grove:CreateToggle({
        Name = 'Background',
        Tooltip = 'Renders a background box behind this ESP element',
        Default = true,
        Function = function(callback)
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    local blur = v:FindFirstChild("BlurEffect")
                    if blur then blur.Visible = callback end
                    v.ImageLabel.BackgroundTransparency = 1 - (callback and ESPColor.Opacity or 0)
                end
            end
        end
    })
    
    ESPColor = Grove:CreateColorSlider({
        Name = 'Background Color',
        Tooltip = 'Color of the background box behind this ESP element',
        DefaultValue = 0.5,
        DefaultOpacity = 0.5,
        Function = function(hue, sat, val, opacity)
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                    v.ImageLabel.BackgroundTransparency = 1 - opacity
                end
            end
        end,
        Darker = true
    })
    
    DistanceCheck = Grove:CreateToggle({
        Name = 'Distance Check',
        Default = false,
        Tooltip = 'Only show spirit orbs within distance range',
        Function = function(callback)
            if DistanceLimit and DistanceLimit.Object then
                DistanceLimit.Object.Visible = callback
            end
        end
    })
    
    DistanceLimit = Grove:CreateTwoSlider({
        Name = 'Spirit Distance',
        Min = 0,
        Max = 256,
        DefaultMin = 0,
        DefaultMax = 64,
        Darker = true,
        Tooltip = 'Distance range for showing spirit orbs'
    })

    task.defer(function()
        if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = false end
        if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = false end
        if ESPColor and ESPColor.Object then ESPColor.Object.Visible = false end
        if DistanceCheck and DistanceCheck.Object then DistanceCheck.Object.Visible = false end
        if DistanceLimit and DistanceLimit.Object then DistanceLimit.Object.Visible = false end
        if AutoWaterRange and AutoWaterRange.Object then
            AutoWaterRange.Object.Visible = false
        end
        if CollectRange and CollectRange.Object then
            CollectRange.Object.Visible = false
        end
        if NoSlowOnAbility and NoSlowOnAbility.Object then
            NoSlowOnAbility.Object.Visible = false
        end
    end)
end)

kitRun(function()
    local Lucia
    local AutoDepositToggle
    local RangeSlider
    local DelayToggle
    local DelaySlider
    local LuciaESPToggle
    local CandyESPToggle
    local IgnoreTeammatesESP
    local ESPBackground
    local ESPColor = {}
    local LuciaSpyToggle
    local IgnoreTeammatesSpy
    local DisplayNameToggle
    local CollectionService = collectionService
    local RunService = runService
    local Players = playersService
    local lplr = Players.LocalPlayer
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local Reference = {}
    local collectedPinatas = {}
    local trackedPinatas = {}

    local function kitCollection(id, func, range, specific)
        repeat
            if entitylib.isAlive then
                local objs = type(id) == 'table' and id or collection(id, Lucia)
                local localPosition = entitylib.character.RootPart.Position
                for _, v in objs do
                    if not Lucia.Enabled then break end
                    local part = not v:IsA('Model') and v or v.PrimaryPart
                    if part and (part.Position - localPosition).Magnitude <= range then
                        local success, err = pcall(func, v)
                        if not success then
                            warn("lucia deposit error:", err)
                        end
                        if DelayToggle.Enabled then
                            task.wait(DelaySlider.Value)
                        else
                            task.wait(0.05)
                        end
                    end
                end
            end
            task.wait(0.1)
        until not Lucia.Enabled
    end

    local function isTeammateESP(pinataPart)
        if not IgnoreTeammatesESP.Enabled then return false end

        local placerId = pinataPart:GetAttribute("PlacedByUserId") or pinataPart:GetAttribute("PlacerId")
        if not placerId then
            local parent = pinataPart.Parent
            if parent then
                placerId = parent:GetAttribute("PlacedByUserId") or parent:GetAttribute("PlacerId")
            end
        end

        if placerId then
            if placerId == lplr.UserId then
                return true
            end

            local placer = Players:GetPlayerByUserId(placerId)
            if placer and placer.Team == lplr.Team then
                return true
            end
        end

        return false
    end

    local function isTeammateSpy(pinataPart)
        if not IgnoreTeammatesSpy.Enabled then return false end

        local placerId = pinataPart:GetAttribute("PlacedByUserId") or pinataPart:GetAttribute("PlacerId")
        if not placerId then
            local parent = pinataPart.Parent
            if parent then
                placerId = parent:GetAttribute("PlacedByUserId") or parent:GetAttribute("PlacerId")
            end
        end

        if placerId then
            if placerId == lplr.UserId then
                return true
            end

            local placer = Players:GetPlayerByUserId(placerId)
            if placer and placer.Team == lplr.Team then
                return true
            end
        end

        return false
    end

    local function getCandyAmount(pinataPart)
        local coins = pinataPart:GetAttribute("Coin")
        return coins or 0
    end

    local function getProperIcon(iconType)
        local icon = bedwars.getIcon({itemType = iconType}, true)
        if not icon or icon == "" then
            return nil
        end
        return icon
    end

    local function Added(pinataPart)
        if isTeammateESP(pinataPart) then
            return
        end

        if Reference[pinataPart] then return end

        local billboard = Instance.new('BillboardGui')
        billboard.Parent = Folder
        billboard.Name = 'pinata'
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
        billboard.Size = UDim2.fromOffset(CandyESPToggle.Enabled and 80 or 36, 36)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = pinataPart

        local blur = addBlur(billboard)
        blur.Visible = ESPBackground.Enabled

        local frame = Instance.new('Frame')
        frame.Size = UDim2.fromScale(1, 1)
        frame.BackgroundColor3 = Color3.fromHSV(ESPColor.Hue, ESPColor.Sat, ESPColor.Value)
        frame.BackgroundTransparency = 1 - (ESPBackground.Enabled and ESPColor.Opacity or 0)
        frame.BorderSizePixel = 0
        frame.Parent = billboard

        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 4)
        uicorner.Parent = frame

        local pinataIcon = getProperIcon('pinata')
        if pinataIcon then
            local image = Instance.new('ImageLabel')
            image.Name = 'PinataIcon'
            image.Size = UDim2.fromOffset(36, 36)
            image.Position = UDim2.new(0, 0, 0.5, 0)
            image.AnchorPoint = Vector2.new(0, 0.5)
            image.BackgroundTransparency = 1
            image.Image = pinataIcon
            image.Parent = frame
        end

        local candyAmount = nil
        local candyIcon = nil

        if CandyESPToggle.Enabled then
            candyAmount = Instance.new('TextLabel')
            candyAmount.Name = 'CandyAmount'
            candyAmount.Size = UDim2.fromOffset(25, 20)
            candyAmount.Position = UDim2.new(0, 40, 0.5, 0)
            candyAmount.AnchorPoint = Vector2.new(0, 0.5)
            candyAmount.BackgroundTransparency = 1
            candyAmount.Text = tostring(getCandyAmount(pinataPart))
            candyAmount.TextColor3 = Color3.fromRGB(255, 255, 255)
            candyAmount.TextSize = 16
            candyAmount.Font = Enum.Font.GothamBold
            candyAmount.TextStrokeTransparency = 0.5
            candyAmount.TextStrokeColor3 = Color3.new(0, 0, 0)
            candyAmount.Parent = frame

            local candyIconImage = getProperIcon('candy')
            if candyIconImage then
                candyIcon = Instance.new('ImageLabel')
                candyIcon.Name = 'CandyIcon'
                candyIcon.Size = UDim2.fromOffset(18, 18)
                candyIcon.Position = UDim2.new(0, 65, 0.5, 0)
                candyIcon.AnchorPoint = Vector2.new(0, 0.5)
                candyIcon.BackgroundTransparency = 1
                candyIcon.Image = candyIconImage
                candyIcon.Parent = frame
            end
        end

        Reference[pinataPart] = {
            billboard = billboard,
            frame = frame,
            candyAmount = candyAmount,
            candyIcon = candyIcon
        }
    end

    local function Removed(pinataPart)
        if Reference[pinataPart] then
            Reference[pinataPart].billboard:Destroy()
            Reference[pinataPart] = nil
        end
    end

    local function updateCandyDisplay(pinataPart)
        local ref = Reference[pinataPart]
        if not ref then return end

        if CandyESPToggle.Enabled then
            if not ref.candyAmount then
                ref.candyAmount = Instance.new('TextLabel')
                ref.candyAmount.Name = 'CandyAmount'
                ref.candyAmount.Size = UDim2.fromOffset(25, 20)
                ref.candyAmount.Position = UDim2.new(0, 40, 0.5, 0)
                ref.candyAmount.AnchorPoint = Vector2.new(0, 0.5)
                ref.candyAmount.BackgroundTransparency = 1
                ref.candyAmount.TextColor3 = Color3.fromRGB(255, 255, 255)
                ref.candyAmount.TextSize = 16
                ref.candyAmount.Font = Enum.Font.GothamBold
                ref.candyAmount.TextStrokeTransparency = 0.5
                ref.candyAmount.TextStrokeColor3 = Color3.new(0, 0, 0)
                ref.candyAmount.Parent = ref.frame

                local candyIconImage = getProperIcon('candy')
                if candyIconImage and not ref.candyIcon then
                    ref.candyIcon = Instance.new('ImageLabel')
                    ref.candyIcon.Name = 'CandyIcon'
                    ref.candyIcon.Size = UDim2.fromOffset(18, 18)
                    ref.candyIcon.Position = UDim2.new(0, 65, 0.5, 0)
                    ref.candyIcon.AnchorPoint = Vector2.new(0, 0.5)
                    ref.candyIcon.BackgroundTransparency = 1
                    ref.candyIcon.Image = candyIconImage
                    ref.candyIcon.Parent = ref.frame
                end

                ref.billboard.Size = UDim2.fromOffset(80, 36)
            end

            if ref.candyAmount then
                ref.candyAmount.Text = tostring(getCandyAmount(pinataPart))
            end
        else
            if ref.candyAmount then
                ref.candyAmount:Destroy()
                ref.candyAmount = nil
            end
            if ref.candyIcon then
                ref.candyIcon:Destroy()
                ref.candyIcon = nil
            end
            ref.billboard.Size = UDim2.fromOffset(36, 36)
        end
    end

    local function findExistingPinatas()
        for _, obj in pairs(workspace:GetDescendants()) do
            if obj:IsA("BasePart") and obj.Name == "pinata" then
                if not Reference[obj] and not isTeammateESP(obj) then
                    Added(obj)
                end
            end
        end
    end

    local function refreshESP()
        Folder:ClearAllChildren()
        table.clear(Reference)
        findExistingPinatas()
    end

    local function getPlayerName(player)
        if DisplayNameToggle.Enabled then
            return player.DisplayName ~= "" and player.DisplayName or player.Name
        else
            return player.Name
        end
    end

    local function getTeamName(player)
        if player.Team then
            return player.Team.Name
        end
        return "Unknown"
    end

    local function setupLuciaSpy()
        local util = require(game:GetService("ReplicatedStorage").TS.games.bedwars.kit.kits['piggy-bank']['piggy-bank-util']).PiggyBankUtil

        for _, obj in pairs(workspace:GetDescendants()) do
            if obj:IsA("BasePart") and obj.Name == "pinata" then
                if not isTeammateSpy(obj) then
                    local placerId = obj:GetAttribute("PlacedByUserId") or obj:GetAttribute("PlacerId")

                    if placerId then
                        local placer = Players:GetPlayerByUserId(placerId)
                        local initialCandy = getCandyAmount(obj)

                        trackedPinatas[obj] = {
                            player = placer,
                            lastCandy = initialCandy,
                            exists = true,
                            placedTime = tick()
                        }
                    end
                end
            end
        end

        Lucia:Clean(workspace.DescendantAdded:Connect(function(obj)
            if not LuciaSpyToggle.Enabled then return end

            if obj:IsA("BasePart") and obj.Name == "pinata" then
                task.wait(0.2)

                if not isTeammateSpy(obj) then
                    local placerId = obj:GetAttribute("PlacedByUserId") or obj:GetAttribute("PlacerId")

                    if placerId then
                        local placer = Players:GetPlayerByUserId(placerId)
                        local initialCandy = getCandyAmount(obj)

                        trackedPinatas[obj] = {
                            player = placer,
                            lastCandy = initialCandy,
                            exists = true,
                            placedTime = tick()
                        }
                    end
                end
            end
        end))

        Lucia:Clean(bedwars.Client:Get("PiggyBankPop"):Connect(function(self)
            if not LuciaSpyToggle.Enabled then return end
            local plr = self.awardedPlayer
            if not plr then return end
            if IgnoreTeammatesSpy.Enabled then
                if plr == lplr or (plr.Team and plr.Team == lplr.Team) then
                    return
                end
            end

            local rewards = util:getRewardsFromCoins(self.coins)
            local I, D, E = 0, 0, 0
            for _, reward in ipairs(rewards) do
                if reward.itemType == "iron" then
                    I = I + (reward.amount or 0)
                elseif reward.itemType == "diamond" then
                    D = D + (reward.amount or 0)
                elseif reward.itemType == "emerald" then
                    E = E + (reward.amount or 0)
                end
            end

            if getAccountTier(plr) >= 1 and getAccountTier(lplr) == 0 then return end
            local playerName = getPlayerName(plr)
            local teamName = getTeamName(plr)
            local loot = string.format("%d irons, %d diamonds, %d emeralds", I, D, E)

            vain:CreateNotification(
                "Lucia Spy",
                string.format("%s (%s) opened their pinata and got %s", playerName, teamName, loot),
                8
            )

            for pinataPart, data in pairs(trackedPinatas) do
                if data.player and data.player.UserId == plr.UserId then
                    trackedPinatas[pinataPart] = nil
                end
            end
        end))

        local luciaSpyCounter = 0
        Lucia:Clean(RunService.Heartbeat:Connect(function()
            if not LuciaSpyToggle.Enabled then return end
            luciaSpyCounter = luciaSpyCounter + 1
            if luciaSpyCounter % 6 ~= 0 then return end
            local toRemove = {}
            for pinataPart, data in pairs(trackedPinatas) do
                if pinataPart and pinataPart.Parent then
                    local currentCandy = getCandyAmount(pinataPart)

                    if currentCandy ~= data.lastCandy then
                        local difference = currentCandy - data.lastCandy

                        if difference > 0 and data.player then
                            if not (getAccountTier(data.player) >= 1 and getAccountTier(data.player) < 99 and getAccountTier(lplr) == 0) then
                                local playerName = getPlayerName(data.player)
                                local teamName = getTeamName(data.player)

                                vain:CreateNotification(
                                    "Lucia Spy",
                                    string.format("%s (%s) has just deposited %d candy and now has %d candy",
                                        playerName, teamName, difference, currentCandy),
                                    5
                                )
                            end
                            data.lastCandy = currentCandy
                        end
                    end
                else
                    if data.exists and data.player then
                        local timeSincePlaced = tick() - (data.placedTime or tick())

                        if timeSincePlaced > 2 then
                            if not (getAccountTier(data.player) >= 1 and getAccountTier(data.player) < 99 and getAccountTier(lplr) == 0) then
                                local playerName = getPlayerName(data.player)
                                local teamName = getTeamName(data.player)

                                vain:CreateNotification(
                                    "Lucia Spy",
                                    string.format("%s (%s) has just broken their pinata with %d candy",
                                        playerName, teamName, data.lastCandy),
                                    5
                                )
                            end
                        end
                    end

                    table.insert(toRemove, pinataPart)
                end
            end

            for _, pinataPart in ipairs(toRemove) do
                trackedPinatas[pinataPart] = nil
            end
        end))
    end

    Lucia = vain.Categories.Kit:CreateModule({
        Name = 'Auto Lucia',
        Tooltip = 'Automates the Lucia kit ability',
        Function = function(callback)
            if callback then
                if LuciaESPToggle.Enabled then
                    findExistingPinatas()

                    Lucia:Clean(workspace.DescendantAdded:Connect(function(obj)
                        if Lucia.Enabled and obj:IsA("BasePart") and obj.Name == "pinata" then
                            task.wait(0.1)
                            if not isTeammateESP(obj) then
                                Added(obj)
                            end
                        end
                    end))

                    Lucia:Clean(workspace.DescendantRemoving:Connect(function(obj)
                        if obj:IsA("BasePart") and obj.Name == "pinata" and Reference[obj] then
                            Removed(obj)
                        end
                    end))

                    local luciaESPCounter = 0
                    Lucia:Clean(RunService.Heartbeat:Connect(function()
                        if not Lucia.Enabled or not LuciaESPToggle.Enabled then return end
                        luciaESPCounter = luciaESPCounter + 1
                        if luciaESPCounter % 6 ~= 0 then return end
                        for pinataPart, ref in pairs(Reference) do
                            if pinataPart and pinataPart.Parent then
                                updateCandyDisplay(pinataPart)
                            else
                                if ref.billboard then
                                    ref.billboard:Destroy()
                                end
                                Reference[pinataPart] = nil
                            end
                        end
                    end))
                end

                if AutoDepositToggle.Enabled then
                    task.spawn(function()
                        local r = RangeSlider.Value
                        kitCollection(lplr.Name .. ':pinata', function(v)
                            if getItem('candy') then
                                bedwars.Client:Get('DepositCoins'):CallServer(v)
                            end
                        end, r, true)
                    end)
                end

                if LuciaSpyToggle.Enabled then
                    setupLuciaSpy()
                end
            else
                Folder:ClearAllChildren()
                table.clear(Reference)
                table.clear(collectedPinatas)
                table.clear(trackedPinatas)
            end
        end,
        Tooltip = 'Lucia (Pinata) Kit Module'
    })

    AutoDepositToggle = Lucia:CreateToggle({
        Name = 'Auto Deposit',
        Default = false,
        Tooltip = 'Automatically deposit candies into your pinata',
        Function = function(callback)
            if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = callback end
            if DelayToggle and DelayToggle.Object then DelayToggle.Object.Visible = callback end
            if DelaySlider and DelaySlider.Object then DelaySlider.Object.Visible = (callback and DelayToggle.Enabled) end

            if not callback then
                if DelaySlider and DelaySlider.Object then
                    DelaySlider.Object.Visible = false
                end
            else
                if DelayToggle and DelayToggle.Enabled then
                    if DelaySlider and DelaySlider.Object then
                        DelaySlider.Object.Visible = true
                    end
                end
            end
        end
    })

    RangeSlider = Lucia:CreateSlider({
        Name = 'Range',
        Tooltip = 'Maximum distance in studs',
        Min = 1,
        Max = 18,
        Default = 8,
        Suffix = ' studs',
        Visible = false
    })

    DelayToggle = Lucia:CreateToggle({
        Name = 'Delay',
        Tooltip = 'Seconds between consecutive actions',
        Default = false,
        Visible = false,
        Function = function(callback)
            if DelaySlider and DelaySlider.Object then
                DelaySlider.Object.Visible = callback
            end
        end
    })

    DelaySlider = Lucia:CreateSlider({
        Name = 'Delay Amount',
        Tooltip = 'Adjusts the delay amount value',
        Min = 0,
        Max = 2,
        Default = 0.5,
        Decimal = 10,
        Suffix = 's',
        Visible = false
    })

    LuciaESPToggle = Lucia:CreateToggle({
        Name = 'Pinata ESP',
        Tooltip = 'Shows pinata locations',
        Function = function(callback)
            if CandyESPToggle and CandyESPToggle.Object then
                CandyESPToggle.Object.Visible = callback
            end
            if IgnoreTeammatesESP and IgnoreTeammatesESP.Object then
                IgnoreTeammatesESP.Object.Visible = callback
            end
            if ESPBackground and ESPBackground.Object then
                ESPBackground.Object.Visible = callback
            end
            if ESPColor and ESPColor.Object then
                ESPColor.Object.Visible = callback
            end

            if not callback then
                if ESPColor and ESPColor.Object then
                    ESPColor.Object.Visible = false
                end
            else
                if ESPBackground and ESPBackground.Enabled then
                    if ESPColor and ESPColor.Object then
                        ESPColor.Object.Visible = true
                    end
                end
            end

            if Lucia.Enabled then
                if callback then
                    findExistingPinatas()
                else
                    Folder:ClearAllChildren()
                    table.clear(Reference)
                end
            end
        end
    })

    CandyESPToggle = Lucia:CreateToggle({
        Name = 'Candy ESP',
        Visible = false,
        Tooltip = 'Shows candy amount in pinatas',
        Function = function(callback)
            for pinataPart in pairs(Reference) do
                updateCandyDisplay(pinataPart)
            end
        end
    })

    IgnoreTeammatesESP = Lucia:CreateToggle({
        Name = 'Ignore Teammates',
        Visible = false,
        Tooltip = 'Hide ESP for teammates',
        Function = function(callback)
            if Lucia.Enabled and LuciaESPToggle.Enabled then
                refreshESP()
            end
        end
    })

    ESPBackground = Lucia:CreateToggle({
        Name = 'Background',
        Tooltip = 'Renders a background box behind this ESP element',
        Visible = false,
        Function = function(callback)
            if ESPColor and ESPColor.Object then
                ESPColor.Object.Visible = callback
            end
            for _, ref in pairs(Reference) do
                if ref.frame then
                    ref.frame.BackgroundTransparency = 1 - (callback and ESPColor.Opacity or 0)
                    if ref.billboard.Blur then
                        ref.billboard.Blur.Visible = callback
                    end
                end
            end
        end
    })

    ESPColor = Lucia:CreateColorSlider({
        Name = 'Background Color',
        Tooltip = 'Color of the background box behind this ESP element',
        DefaultValue = 0,
        DefaultOpacity = 0.5,
        Visible = false,
        Function = function(hue, sat, val, opacity)
            ESPColor.Hue = hue
            ESPColor.Sat = sat
            ESPColor.Value = val
            ESPColor.Opacity = opacity

            for _, ref in pairs(Reference) do
                if ref.frame then
                    ref.frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                    ref.frame.BackgroundTransparency = 1 - opacity
                end
            end
        end,
        Darker = true
    })

    LuciaSpyToggle = Lucia:CreateToggle({
        Name = 'Lucia Spy',
        Default = false,
        Tooltip = 'Notifies when players deposit, break, or open pinatas',
        Function = function(callback)
            if IgnoreTeammatesSpy and IgnoreTeammatesSpy.Object then
                IgnoreTeammatesSpy.Object.Visible = callback
            end
            if DisplayNameToggle and DisplayNameToggle.Object then
                DisplayNameToggle.Object.Visible = callback
            end

            if Lucia.Enabled and callback then
                setupLuciaSpy()
            else
                table.clear(trackedPinatas)
            end
        end
    })

    IgnoreTeammatesSpy = Lucia:CreateToggle({
        Name = 'Ignore Teammates',
        Tooltip = 'Ignores players on your own team',
        Default = true,
        Visible = false
    })

    DisplayNameToggle = Lucia:CreateToggle({
        Name = 'Display Name',
        Default = false,
        Visible = false,
        Tooltip = 'Show display names instead of usernames'
    })

    task.defer(function()
        if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = false end
        if DelayToggle and DelayToggle.Object then DelayToggle.Object.Visible = false end
        if DelaySlider and DelaySlider.Object then DelaySlider.Object.Visible = false end
        if CandyESPToggle and CandyESPToggle.Object then CandyESPToggle.Object.Visible = false end
        if IgnoreTeammatesESP and IgnoreTeammatesESP.Object then IgnoreTeammatesESP.Object.Visible = false end
        if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = false end
        if ESPColor and ESPColor.Object then ESPColor.Object.Visible = false end
        if IgnoreTeammatesSpy and IgnoreTeammatesSpy.Object then IgnoreTeammatesSpy.Object.Visible = false end
        if DisplayNameToggle and DisplayNameToggle.Object then DisplayNameToggle.Object.Visible = false end
    end)
end)

kitRun(function()
	local AutoWarden
	local Range
	local Delay
	local FOV

	AutoWarden = vain.Categories.Kit:CreateModule({
		Name = "Auto Warden",
		Tooltip = "Automatically collects souls",
		Function = function(callback)
			if callback then
				local lastManualClick = 0
				local swingOnlyConn = inputService.InputBegan:Connect(function(input, gameProcessed)
					if gameProcessed then return end
					if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
					lastManualClick = tick()
				end)
				AutoWarden:Clean(swingOnlyConn)

				repeat
					if not entitylib.isAlive then
						task.wait(0.1)
						continue
					end

					local localPosition = entitylib.character.RootPart.Position
					local fovRadius = math.tan(math.rad(FOV.Value / 2))

					for _, v in collection('jailor_soul', AutoWarden) do
						if not AutoWarden.Enabled then break end
						local part = not v:IsA('Model') and v or v.PrimaryPart
						if not part then continue end

						local dist = (part.Position - localPosition).Magnitude
						if dist > Range.Value then continue end

						local camera = workspace.CurrentCamera
						local screenPos, onScreen = camera:WorldToViewportPoint(part.Position)
						if onScreen then
							local centerX = camera.ViewportSize.X / 2
							local centerY = camera.ViewportSize.Y / 2
							local dx = (screenPos.X - centerX) / camera.ViewportSize.X
							local dy = (screenPos.Y - centerY) / camera.ViewportSize.Y
							local screenDist = math.sqrt(dx * dx + dy * dy)
							if screenDist > fovRadius then continue end
						else
							continue
						end

						task.wait(Delay.Value)
						pcall(function()
							bedwars.JailorController:collectEntity(lplr, v, 'JailorSoul')
						end)
						task.wait(0.05)
					end

					task.wait(0.1)
				until not AutoWarden.Enabled
			end
		end
	})

	Range = AutoWarden:CreateSlider({
		Name = "Range",
		Tooltip = 'Maximum distance in studs',
		Min = 1,
		Max = 50,
		Default = 20,
	})

	Delay = AutoWarden:CreateSlider({
		Name = "Delay",
		Tooltip = 'Seconds between consecutive actions',
		Min = 0,
		Max = 2,
		Default = 0,
		Decimal = 10,
	})

	FOV = AutoWarden:CreateSlider({
		Name = "FOV",
		Tooltip = 'Field-of-view cone in degrees for target detection',
		Min = 1,
		Max = 360,
		Default = 360,
	})
end)

kitRun(function()
    local LuciaSpy
    local IgnoreTeammatesSpy
    local DisplayNameToggle

    local runService     = game:GetService('RunService')
    local playersService = game:GetService('Players')
    local lplr           = playersService.LocalPlayer

    local vain    = shared.vain
    local bedwars = shared.bedwars or getgenv().bedwars

    local trackedPinatas = {}

    local function getPlayerName(player)
        if DisplayNameToggle and DisplayNameToggle.Enabled then
            return player.DisplayName ~= "" and player.DisplayName or player.Name
        end
        return player.Name
    end

    local function getTeamName(player)
        if player.Team then return player.Team.Name end
        return "Unknown"
    end

    local function getCandyAmount(pinataPart)
        return pinataPart:GetAttribute("Coin") or 0
    end

    local function isTeammateSpy(pinataPart)
        if not IgnoreTeammatesSpy or not IgnoreTeammatesSpy.Enabled then return false end
        local placerId = pinataPart:GetAttribute("PlacedByUserId") or pinataPart:GetAttribute("PlacerId")
        if not placerId then
            local parent = pinataPart.Parent
            if parent then
                placerId = parent:GetAttribute("PlacedByUserId") or parent:GetAttribute("PlacerId")
            end
        end
        if placerId then
            if placerId == lplr.UserId then return true end
            local placer = playersService:GetPlayerByUserId(placerId)
            if placer and placer.Team == lplr.Team then return true end
        end
        return false
    end

    local function setupLuciaSpy()
        local util = require(game:GetService("ReplicatedStorage").TS.games.bedwars.kit.kits['piggy-bank']['piggy-bank-util']).PiggyBankUtil
        for _, obj in pairs(workspace:GetDescendants()) do
            if obj:IsA("BasePart") and obj.Name == "pinata" then
                if not isTeammateSpy(obj) then
                    local placerId = obj:GetAttribute("PlacedByUserId") or obj:GetAttribute("PlacerId")
                    if placerId then
                        local placer = playersService:GetPlayerByUserId(placerId)
                        local initialCandy = getCandyAmount(obj)
                        trackedPinatas[obj] = {
                            player      = placer,
                            lastCandy   = initialCandy,
                            exists      = true,
                            placedTime  = tick()
                        }
                    end
                end
            end
        end

        LuciaSpy:Clean(workspace.DescendantAdded:Connect(function(obj)
            if not LuciaSpy.Enabled then return end
            if obj:IsA("BasePart") and obj.Name == "pinata" then
                task.wait(0.2)
                if not isTeammateSpy(obj) then
                    local placerId = obj:GetAttribute("PlacedByUserId") or obj:GetAttribute("PlacerId")
                    if placerId then
                        local placer = playersService:GetPlayerByUserId(placerId)
                        trackedPinatas[obj] = {
                            player      = placer,
                            lastCandy   = getCandyAmount(obj),
                            exists      = true,
                            placedTime  = tick()
                        }
                    end
                end
            end
        end))

        LuciaSpy:Clean(bedwars.Client:Get("PiggyBankPop"):Connect(function(self)
            if not LuciaSpy.Enabled then return end
            local plr = self.awardedPlayer
            if not plr then return end
            if IgnoreTeammatesSpy and IgnoreTeammatesSpy.Enabled then
                if plr == lplr or (plr.Team and plr.Team == lplr.Team) then return end
            end

            local rewards = util:getRewardsFromCoins(self.coins)
            local I, D, E = 0, 0, 0
            for _, reward in ipairs(rewards) do
                if reward.itemType == "iron" then
                    I = I + (reward.amount or 0)
                elseif reward.itemType == "diamond" then
                    D = D + (reward.amount or 0)
                elseif reward.itemType == "emerald" then
                    E = E + (reward.amount or 0)
                end
            end

            if getAccountTier(plr) >= 1 and getAccountTier(lplr) == 0 then return end
            local playerName = getPlayerName(plr)
            local teamName   = getTeamName(plr)
            local loot = string.format("%d irons, %d diamonds, %d emeralds", I, D, E)

            vain:CreateNotification(
                "Lucia Spy",
                string.format("%s (%s) opened their pinata and got %s", playerName, teamName, loot),
                8
            )

            for pinataPart, data in pairs(trackedPinatas) do
                if data.player and data.player.UserId == plr.UserId then
                    trackedPinatas[pinataPart] = nil
                end
            end
        end))

        local counter = 0
        LuciaSpy:Clean(runService.Heartbeat:Connect(function()
            if not LuciaSpy.Enabled then return end
            counter = counter + 1
            if counter % 6 ~= 0 then return end

            local toRemove = {}
            for pinataPart, data in pairs(trackedPinatas) do
                if pinataPart and pinataPart.Parent then
                    local currentCandy = getCandyAmount(pinataPart)
                    if currentCandy ~= data.lastCandy then
                        local difference = currentCandy - data.lastCandy
                        if difference > 0 and data.player then
                            if getAccountTier(data.player) >= 1 and getAccountTier(lplr) == 0 then
                                data.lastCandy = currentCandy
                            else
                            local playerName = getPlayerName(data.player)
                            local teamName   = getTeamName(data.player)
                            vain:CreateNotification(
                                "Lucia Spy",
                                string.format("%s (%s) deposited %d candy (now %d)", playerName, teamName, difference, currentCandy),
                                5
                            )
                        end
                        data.lastCandy = currentCandy
                            end
                            end
                else
                    if data.exists and data.player then
                        local timeSincePlaced = tick() - (data.placedTime or tick())
                        if timeSincePlaced > 2 then
                            if not (getAccountTier(data.player) >= 1 and getAccountTier(data.player) < 99 and getAccountTier(lplr) == 0) then
                            local playerName = getPlayerName(data.player)
                            local teamName   = getTeamName(data.player)
                            vain:CreateNotification(
                                "Lucia Spy",
                                string.format("%s (%s) broke their pinata (had %d candy)", playerName, teamName, data.lastCandy),
                                5
                            )
                            end
                        end
                    end
                    table.insert(toRemove, pinataPart)
                end
            end

            for _, pinataPart in ipairs(toRemove) do
                trackedPinatas[pinataPart] = nil
            end
        end))
    end

    LuciaSpy = vain.Categories.Kit:CreateModule({
        Name    = "Lucia Spy",
        Tooltip = "Notifies when players deposit, break, or open pinatas",
        Function = function(callback)
            if callback then
                setupLuciaSpy()
            else
                table.clear(trackedPinatas)
            end
        end
    })

    IgnoreTeammatesSpy = LuciaSpy:CreateToggle({
        Name    = "Ignore Teammates",
        Default = true,
        Tooltip = "Don't notify for teammates"
    })

    DisplayNameToggle = LuciaSpy:CreateToggle({
        Name    = "Display Name",
        Default = false,
        Tooltip = "Show display names instead of usernames"
    })
end)

kitRun(function()
    local YuziDasher
    local ImpulseSlider
    local JumpHeightSlider
    local CurrentKeybind = Enum.KeyCode.Q

    local canDash = true

    local function PerformDash()
        if not canDash then return end
        if not entitylib.isAlive then return end

        local heldItem = store.hand.tool
        if not heldItem or not (heldItem.Name:find("dao") or heldItem.Name:find("yuzi")) then return end

        local character = lplr.Character
        if not (character and character.PrimaryPart) then return end

        canDash = false

        task.spawn(function()
            local originalJumpHeight = character.Humanoid.JumpHeight

            pcall(function() character:SetAttribute('CanDash', 0) end)

            local lookVector = gameCamera.CFrame.LookVector
            local origin = character.PrimaryPart.Position

            pcall(function()
                local n = game:GetService("ReplicatedStorage"):FindFirstChild("rbxts_include")
                if n then n = n:FindFirstChild("node_modules") end
                if n then n = n:FindFirstChild("@rbxts") end
                if n then n = n:FindFirstChild("net") end
                if n then n = n:FindFirstChild("out") end
                if n then n = n:FindFirstChild("_NetManaged") end
                if n then n = n:FindFirstChild("SwordSwingMiss") end
                if n then n:FireServer({ weapon = heldItem, chargeRatio = 0 }) end
            end)

            task.wait(0.05)

            if bedwars.AbilityController:canUseAbility('dash') then
                bedwars.AbilityController:useAbility('dash', nil, {
                    direction = lookVector,
                    origin = origin,
                    weapon = heldItem.Name
                })

                pcall(function()
                    bedwars.GameAnimationUtil:playAnimation(lplr, bedwars.AnimationType.DAO_DASH)
                end)

                pcall(function()
                    local hrp = character.HumanoidRootPart
                    local mass = hrp.AssemblyMass or 5
                    hrp:ApplyImpulse(lookVector.Unit * Vector3.new(1, 0, 1) * mass * ImpulseSlider.Value)
                    character.Humanoid.JumpHeight = JumpHeightSlider.Value
                    character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
                end)

                task.delay(0.5, function()
                    if character and character.Humanoid then
                        pcall(function()
                            character.Humanoid.JumpHeight = originalJumpHeight
                            if bedwars.JumpHeightController then
                                bedwars.JumpHeightController:setJumpHeight(game:GetService("StarterPlayer").CharacterJumpHeight)
                            end
                        end)
                    end
                end)
            end

            task.wait(0.3)
            canDash = true
        end)
    end

    YuziDasher = vain.Categories.Kit:CreateModule({
        Name = 'Yuzi Dasher',
        Tooltip = 'Enables the YuziDasher module',
        Function = function(callback)
            if callback then
                YuziDasher:Clean(inputService.InputBegan:Connect(function(input, gameProcessed)
                    if gameProcessed then return end
                    if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == CurrentKeybind then
                        PerformDash()
                    end
                end))
            else
                canDash = true
            end
        end,
        Tooltip = 'Yuzi Dasher with custom keybind'
    })

    local keybindOptions = {
        "Q", "E", "R", "F", "G", "X", "Z", "V", "B",
        "LeftAlt", "LeftControl", "LeftShift", "RightAlt", "RightControl", "RightShift",
        "Space", "CapsLock", "Tab"
    }

    YuziDasher:CreateDropdown({
        Name = 'Keybind',
        Tooltip = 'Key used to activate this ability',
        List = keybindOptions,
        Default = "Q",
        Function = function(value)
            CurrentKeybind = Enum.KeyCode[value]
        end
    })

    ImpulseSlider = YuziDasher:CreateSlider({
        Name = 'Impulse Multiplier',
        Min = 10,
        Max = 500,
        Default = 100,
        Tooltip = 'Controls dash speed'
    })

    JumpHeightSlider = YuziDasher:CreateSlider({
        Name = 'Jump Height',
        Min = 0,
        Max = 50,
        Default = 10,
        Tooltip = 'Controls jump height during dash'
    })
end)

kitRun(function()
	local AutoPotion
	local BrewSleep
	local BrewShield
	local BrewPoison
	local BrewHeal

	local ingredientAbility = {
		wild_flower = 'alchemist_add_flower',
		mushrooms = 'alchemist_add_mushrooms',
		thorns = 'alchemist_add_thorns',
	}

	local function getRecipes()
		local ok, recipeMeta = pcall(function()
			return require(replicatedStorage:WaitForChild('TS'):WaitForChild('recipe'):WaitForChild('recipe-meta')).recipes
		end)
		return ok and recipeMeta or nil
	end

	local function hasIngredients(ingredients)
		for _, ing in ingredients do
			if not getItem(ing) then return false end
		end
		return true
	end

	local potionMap = {
		['Sleep Potion'] = 'sleep_splash_potion',
		['Shield'] = 'big_shield',
		['Poison Potion'] = 'poison_splash_potion',
		['Heal Potion'] = 'heal_splash_potion',
	}

	local function brewPotion(itemType)
		local recipes = getRecipes()
		if not recipes then return end
		local recipe = recipes[itemType]
		if not recipe or #recipe.ingredients ~= 3 then return end
		if not hasIngredients(recipe.ingredients) then return end
		local handTool = store.hand and store.hand.tool
		if not handTool or not handTool.Name:lower():find('alchemist_flask') then return end
		for _, ing in recipe.ingredients do
			local ability = ingredientAbility[ing]
			if ability then
				bedwars.AbilityController:useAbility(ability)
				task.wait(0.05)
			end
		end
	end

	AutoPotion = vain.Categories.Kit:CreateModule({
		Name = 'Auto Potion',
		Tooltip = 'Automatically brews the selected alchemist potion when you have the materials',
		Function = function(callback)
			if callback then
				repeat
					task.wait(0.1)
					if not entitylib.isAlive then continue end
					local selected = BrewSelect and BrewSelect.Value
					local itemType = selected and potionMap[selected]
					if itemType then brewPotion(itemType) end
				until not AutoPotion.Enabled
			end
		end
	})
	BrewSelect = AutoPotion:CreateDropdown({
		Name = 'Potion',
		List = {'Sleep Potion', 'Shield', 'Poison Potion', 'Heal Potion'},
		Default = 'Sleep Potion',
		Tooltip = 'Select which potion to auto brew',
		ItemTooltips = {
			['Sleep Potion'] = 'Brews a sleep potion that puts nearby enemies to sleep on contact',
			Shield = 'Brews a shield potion that grants temporary damage reduction',
			['Poison Potion'] = 'Brews a poison potion that deals damage over time',
			['Heal Potion'] = 'Brews a heal potion that restores health on use',
		}
	})
end)

kitRun(function()
    local FarmerCletus
    local CollectionToggle
    local Animation
    local RangeSlider
    local ESPToggle
    local ESPNotify
    local ESPBackground
    local ESPColor
    
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local Reference = {}
    local lastNotification = 0
    local spawnQueue = {}
    local notificationCooldown = 1

	local function kitCollection(id, func, range, specific)
		repeat
			if entitylib.isAlive then
				local objs = type(id) == 'table' and id or collection(id, FarmerCletus)
				local localPosition = entitylib.character.RootPart.Position
				for _, v in objs do
					if not FarmerCletus.Enabled then break end
					local part = not v:IsA('Model') and v or v.PrimaryPart
					if part and (part.Position - localPosition).Magnitude <= range then
						pcall(func, v)
						task.wait(0.05)
					end
				end
			end
			task.wait(0.1)
		until not FarmerCletus.Enabled
	end

    local function sendNotification(count)
    end

    local function processSpawnQueue()
        if #spawnQueue > 0 then
            local currentTime = tick()
            if currentTime - lastNotification >= notificationCooldown then
                sendNotification(#spawnQueue)
                lastNotification = currentTime
                spawnQueue = {}
            else
                task.delay(notificationCooldown - (currentTime - lastNotification), function()
                    if #spawnQueue > 0 then
                        sendNotification(#spawnQueue)
                        spawnQueue = {}
                    end
                end)
            end
        end
    end

    local function getProperImage(v)
        if v.Name == "carrot" then
            return bedwars.getIcon({itemType = 'carrot_seeds'}, true)
        elseif v.Name == "melon" then
            return bedwars.getIcon({itemType = 'melon_seeds'}, true)
        elseif v.Name == "pumpkin" then
            return bedwars.getIcon({itemType = 'pumpkin_seeds'}, true)
        end
        return bedwars.getIcon({itemType = 'carrot_seeds'}, true)
    end

    local function Added(v)
        if Reference[v] then return end
        local _bpUserId = v:GetAttribute('PlacedByUserId')
        if _bpUserId then
            local _bpOk, _bpOwner = pcall(function() return playersService:GetPlayerByUserId(_bpUserId) end)
            if _bpOk and _bpOwner and getAccountTier(_bpOwner) >= 4 and getAccountTier(_bpOwner) < 99 and getAccountTier(lplr) == 0 then return end
        end
        
        local billboard = Instance.new('BillboardGui')
        billboard.Parent = Folder
        billboard.Name = 'crop'
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
        billboard.Size = UDim2.fromOffset(36, 36)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = v
        
        local blur = addBlur(billboard)
        blur.Visible = ESPBackground.Enabled
        
        local image = Instance.new('ImageLabel')
        image.Size = UDim2.fromOffset(36, 36)
        image.Position = UDim2.fromScale(0.5, 0.5)
        image.AnchorPoint = Vector2.new(0.5, 0.5)
        image.BackgroundColor3 = Color3.fromHSV(ESPColor.Hue, ESPColor.Sat, ESPColor.Value)
        image.BackgroundTransparency = 1 - (ESPBackground.Enabled and ESPColor.Opacity or 0)
        image.BorderSizePixel = 0
        image.Image = getProperImage(v)
        image.Parent = billboard
        
        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 4)
        uicorner.Parent = image
        
        Reference[v] = billboard
        
        if ESPNotify.Enabled then
            table.insert(spawnQueue, {item = 'crop', time = tick()})
            processSpawnQueue()
        end
    end

    local function Removed(v)
        if Reference[v] then
            Reference[v]:Destroy()
            Reference[v] = nil
        end
    end

    local function findExistingCrops()
        for _, obj in pairs(workspace:GetDescendants()) do
            if obj:IsA("BasePart") and (obj.Name == "carrot" or obj.Name == "melon" or obj.Name == "pumpkin") then
                if obj.Parent == workspace or obj.Parent.Parent == workspace then
                    task.wait(0.1)
                    Added(obj)
                end
            end
        end
    end

    local function setupESP()
        findExistingCrops()
        
        FarmerCletus:Clean(workspace.DescendantAdded:Connect(function(obj)
            if obj:IsA("BasePart") and (obj.Name == "carrot" or obj.Name == "melon" or obj.Name == "pumpkin") then
                if obj.Parent == workspace or obj.Parent.Parent == workspace then
                    task.wait(0.1)
                    Added(obj)
                end
            end
        end))
        
        FarmerCletus:Clean(workspace.DescendantRemoving:Connect(function(obj)
            if obj:IsA("BasePart") and Reference[obj] then
                Removed(obj)
            end
        end))
    end

    FarmerCletus = vain.Categories.Kit:CreateModule({
        Name = 'Auto Farmer',
        Tooltip = 'Automatically farms resources from generators',
        Function = function(callback)
            if callback then
                if ESPToggle.Enabled then
                    setupESP()
                end
                
                if CollectionToggle.Enabled then
                    task.spawn(function()
                        kitCollection('HarvestableCrop', function(v)
                            bedwars.Client:Get(remotes.HarvestCrop):CallServer({position = bedwars.BlockController:getBlockPosition(v.Position)})
                            
                            if Animation.Enabled then
                                bedwars.GameAnimationUtil:playAnimation(lplr.Character, bedwars.AnimationType.PUNCH)
                                bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_USE_ITEM)
                                
                                if tostring(lplr.Character:GetAttribute('CropKitSkin') or ''):lower():find('valentine') ~= nil then
                                    bedwars.SoundManager:playSound(bedwars.SoundList.VALETINE_CROP_HARVEST)
                                else
                                    bedwars.SoundManager:playSound(bedwars.SoundList.CROP_HARVEST)
                                end
                            end
                        end, RangeSlider.Value, false)
                    end)
                end
            else
                Folder:ClearAllChildren()
                table.clear(Reference)
                table.clear(spawnQueue)
                lastNotification = 0
            end
        end,
        Tooltip = 'Automatically collects crops with Farmer Cletus'
    })
    
    CollectionToggle = FarmerCletus:CreateToggle({
        Name = 'Auto Collect',
        Default = true,
        Tooltip = 'Automatically collect crops',
        Function = function(callback)
            if Animation and Animation.Object then Animation.Object.Visible = callback end
            if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = callback end
            
            if callback and FarmerCletus.Enabled then
                task.spawn(function()
                    kitCollection('HarvestableCrop', function(v)
                        bedwars.Client:Get(remotes.HarvestCrop):CallServer({position = bedwars.BlockController:getBlockPosition(v.Position)})
                        
                        if Animation.Enabled then
                            bedwars.GameAnimationUtil:playAnimation(lplr.Character, bedwars.AnimationType.PUNCH)
                            bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_USE_ITEM)
                            
                            if tostring(lplr.Character:GetAttribute('CropKitSkin') or ''):lower():find('valentine') ~= nil then
                                bedwars.SoundManager:playSound(bedwars.SoundList.VALETINE_CROP_HARVEST)
                            else
                                bedwars.SoundManager:playSound(bedwars.SoundList.CROP_HARVEST)
                            end
                        end
                    end, RangeSlider.Value, false)
                end)
            end
        end
    })
    
    Animation = FarmerCletus:CreateToggle({
        Name = 'Animation',
        Default = true,
        Tooltip = 'Play animation and sound when collecting'
    })
    
    RangeSlider = FarmerCletus:CreateSlider({
        Name = 'Range',
        Min = 1,
        Max = 10,
        Default = 10,
        Decimal = 1,
        Suffix = ' studs',
        Tooltip = 'Control distance to collect crops'
    })
    
    ESPToggle = FarmerCletus:CreateToggle({
        Name = 'Crop ESP',
        Default = false,
        Tooltip = 'Shows your crop locations',
        Function = function(callback)
            if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = callback end
            if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = callback end
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end

            if not callback then
                if ESPColor and ESPColor.Object then
                    ESPColor.Object.Visible = false
                end
            else
                if ESPBackground and ESPBackground.Enabled then
                    if ESPColor and ESPColor.Object then
                        ESPColor.Object.Visible = true
                    end
                end
            end
            
            if FarmerCletus.Enabled then
                if callback then
                    setupESP()
                else
                    Folder:ClearAllChildren()
                    table.clear(Reference)
                end
            end
        end
    })
    
    ESPNotify = FarmerCletus:CreateToggle({
        Name = 'Notify',
        Default = false,
        Tooltip = 'Get notifications when crops spawn'
    })
    
    ESPBackground = FarmerCletus:CreateToggle({
        Name = 'Background',
        Tooltip = 'Renders a background box behind this ESP element',
        Default = true,
        Function = function(callback)
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundTransparency = 1 - (callback and ESPColor.Opacity or 0)
                    if v:FindFirstChild("Blur") then
                        v.Blur.Visible = callback
                    end
                end
            end
        end
    })
    
    ESPColor = FarmerCletus:CreateColorSlider({
        Name = 'Background Color',
        Tooltip = 'Color of the background box behind this ESP element',
        DefaultValue = 0,
        DefaultOpacity = 0.5,
        Function = function(hue, sat, val, opacity)
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                    v.ImageLabel.BackgroundTransparency = 1 - opacity
                end
            end
        end,
        Darker = true
    })

    task.defer(function()
        if Animation and Animation.Object then Animation.Object.Visible = true end
        if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = true end
        if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = false end
        if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = false end
        if ESPColor and ESPColor.Object then ESPColor.Object.Visible = false end
    end)
end)

kitRun(function()
    --[[
        Trapper, as the rework left it.

        The kit throws three traps - snap, venom and explosive - switching between them
        with one ability and detonating every armed explosive with another. Every thrown
        trap is tagged 'trapper_trap' and carries who placed it, which team they are on
        and when it arms, so all of this is read off the trap itself rather than guessed.

        The ESP is deliberately not limited to playing the kit: a snap trap you walk into
        is worth seeing whoever you are.
    ]]
    local Trapper
    local TrapESP, OwnTraps
    local WarnToggle, WarnRange
    local AutoDetonate, DetonateRange, DetonateTargets
    local PreferredTrap
    local Reference, espConns, warnedAt = {}, {}, {}
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui

    -- Everything the kit throws carries the first tag. The other two are placed by other
    -- kits and are worth seeing for exactly the same reason.
    local TAGS = {'trapper_trap', 'GlueTrap', 'tesla-trap'}
    local KINDS = {
        snap = 'Snap Trap',
        venom = 'Venom Trap',
        explosive = 'Explosive Trap',
        glue = 'Glue Trap',
        tesla = 'Tesla Trap'
    }
    local WANTED = {
        ['Snap'] = 'snap_trap',
        ['Venom'] = 'venom_trap',
        ['Explosive'] = 'explosive_trap'
    }
    local OWN_COLOR = Color3.fromRGB(120, 220, 140)
    local ENEMY_COLOR = Color3.fromRGB(255, 95, 95)

    local function on(setting)
        return setting ~= nil and setting.Enabled
    end

    -- A trap carries no item type of its own, so the model's name is what says which one
    -- it is. Anything unrecognised is still shown, as a trap.
    local function trapKind(trap)
        local name = trap.Name:lower()
        for key in KINDS do
            if name:find(key, 1, true) then return key end
        end
        return nil
    end

    local function trapPart(trap)
        if trap:IsA('BasePart') then return trap end
        return trap:FindFirstChildWhichIsA('BasePart', true)
    end

    local function isMine(trap)
        return trap:GetAttribute('PlacedByUserId') == lplr.UserId
    end

    -- Their team id and yours are written by different parts of the game, so they are
    -- compared as text; anything that does not match is treated as an enemy's, which is
    -- the safe way round for something you are trying not to stand on.
    local function isFriendly(trap)
        if isMine(trap) then return true end
        local team = trap:GetAttribute('TrapperTeamId')
        return team ~= nil and tostring(team) == tostring(lplr:GetAttribute('Team'))
    end

    -- Thrown traps only catch anyone once they arm, and the trap says when that is.
    local function isArmed(trap)
        local armAt = trap:GetAttribute('TrapperArmAt')
        return armAt == nil or workspace:GetServerTimeNow() >= armAt
    end

    local function espRemove(trap)
        local billboard = Reference[trap]
        if billboard then
            billboard:Destroy()
            Reference[trap] = nil
        end
    end

    local function espAdd(trap)
        if Reference[trap] or not on(TrapESP) then return end

        local mine = isMine(trap)
        if mine and not on(OwnTraps) then return end

        local adornee = trapPart(trap)
        if not adornee then return end

        local kind = trapKind(trap)
        local billboard = Instance.new('BillboardGui')
        billboard.Name = 'TrapESP'
        billboard.Adornee = adornee
        billboard.Size = UDim2.fromOffset(120, 20)
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 2.5, 0)
        billboard.AlwaysOnTop = true
        billboard.Parent = Folder

        local label = Instance.new('TextLabel')
        label.Size = UDim2.fromScale(1, 1)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.GothamBold
        label.TextSize = 13
        label.TextStrokeTransparency = 0.5
        label.TextColor3 = isFriendly(trap) and OWN_COLOR or ENEMY_COLOR
        label.Text = KINDS[kind] or 'Trap'
        label.Parent = billboard

        Reference[trap] = billboard
    end

    local function clearESP()
        for trap in Reference do
            espRemove(trap)
        end
        for _, conn in espConns do
            pcall(function() conn:Disconnect() end)
        end
        table.clear(espConns)
    end

    local function setupESP()
        if #espConns > 0 then return end

        for _, tag in TAGS do
            table.insert(espConns, collectionService:GetInstanceAddedSignal(tag):Connect(espAdd))
            table.insert(espConns, collectionService:GetInstanceRemovedSignal(tag):Connect(espRemove))
            for _, trap in collectionService:GetTagged(tag) do
                espAdd(trap)
            end
        end
        for _, conn in espConns do
            Trapper:Clean(conn)
        end
    end

    local function eachTrap(handler)
        for _, tag in TAGS do
            for _, trap in collectionService:GetTagged(tag) do
                handler(trap)
            end
        end
    end

    -- Someone else's armed trap within reach of you, said once rather than every frame.
    local function warnNearby()
        if not (on(WarnToggle) and entitylib.isAlive) then return end

        local here = entitylib.character.RootPart.Position
        eachTrap(function(trap)
            if isFriendly(trap) then return end

            local part = trapPart(trap)
            if not part or (part.Position - here).Magnitude > WarnRange.Value then return end
            if tick() - (warnedAt[trap] or 0) < 8 then return end

            warnedAt[trap] = tick()
            notif('Trapper', (KINDS[trapKind(trap)] or 'Trap') .. ' next to you', 4, 'warning')
        end)
    end

    -- One press blows every armed explosive you have out, so it is worth spending on the
    -- first one with somebody standing on it rather than on the first one at all.
    local function detonateReady()
        if not (on(AutoDetonate) and store.equippedKit == 'trapper') then return false end
        if not bedwars.AbilityController:canUseAbility('trapper_detonate') then return false end

        local found = false
        eachTrap(function(trap)
            if found or not isMine(trap) or trapKind(trap) ~= 'explosive' or not isArmed(trap) then return end

            local part = trapPart(trap)
            if not part then return end

            for _, ent in entitylib.List do
                local root = ent.RootPart
                if root and ent.Targetable
                    and (ent.Player and DetonateTargets.Players.Enabled or (not ent.Player) and DetonateTargets.NPCs.Enabled)
                    and (root.Position - part.Position).Magnitude <= DetonateRange.Value
                then
                    found = true
                    break
                end
            end
        end)
        return found
    end

    -- The kit cycles through its traps one press at a time, so this presses until the one
    -- you asked for is the one selected, and leaves it alone once it is.
    local function keepSelected()
        local wanted = WANTED[PreferredTrap.Value]
        if not (wanted and store.equippedKit == 'trapper') then return end
        if lplr:GetAttribute('TrapperSelectedTrap') == wanted then return end
        if not bedwars.AbilityController:canUseAbility('trapper_switch') then return end

        bedwars.AbilityController:useAbility('trapper_switch')
    end

    Trapper = vain.Categories.Kit:CreateModule({
        Name = 'Trapper',
        Tooltip = 'Shows traps on the map and works the Trapper kit',
        Function = function(callback)
            if callback then
                setupESP()
                repeat
                    -- Guarded because it reads traps the game is adding and removing
                    -- underneath it; one bad frame should not switch the module off.
                    pcall(function()
                        warnNearby()
                        if detonateReady() then
                            bedwars.AbilityController:useAbility('trapper_detonate')
                        end
                        keepSelected()
                    end)
                    task.wait(0.2)
                until not Trapper.Enabled
                clearESP()
                table.clear(warnedAt)
            else
                clearESP()
                table.clear(warnedAt)
            end
        end
    })
    TrapESP = Trapper:CreateToggle({
        Name = 'Trap ESP',
        Default = true,
        Tooltip = 'Names every trap on the map, red when it is not your own',
        Function = function(callback)
            if OwnTraps and OwnTraps.Object then OwnTraps.Object.Visible = callback end
            if not callback then
                for trap in Reference do
                    espRemove(trap)
                end
            elseif Trapper.Enabled then
                setupESP()
                for _, tag in TAGS do
                    for _, trap in collectionService:GetTagged(tag) do
                        espAdd(trap)
                    end
                end
            end
        end
    })
    OwnTraps = Trapper:CreateToggle({
        Name = 'Show Own',
        Default = true,
        Darker = true,
        Tooltip = 'Also shows the traps you and your team placed'
    })
    WarnToggle = Trapper:CreateToggle({
        Name = 'Warn',
        Tooltip = 'Says when you walk up to an enemy trap',
        Function = function(callback)
            if WarnRange and WarnRange.Object then WarnRange.Object.Visible = callback end
        end
    })
    WarnRange = Trapper:CreateSlider({
        Name = 'Warn Range',
        Tooltip = 'How close a trap has to be to be called out',
        Min = 5,
        Max = 60,
        Default = 20,
        Visible = false,
        Darker = true,
        Suffix = function(val)
            return val == 1 and 'stud' or 'studs'
        end
    })
    AutoDetonate = Trapper:CreateToggle({
        Name = 'Auto Detonate',
        Tooltip = 'Sets off your explosive traps when somebody stands on one',
        Function = function(callback)
            for _, setting in {DetonateRange, DetonateTargets} do
                if setting and setting.Object then setting.Object.Visible = callback end
            end
        end
    })
    DetonateRange = Trapper:CreateSlider({
        Name = 'Detonate Range',
        Tooltip = 'How close an enemy has to be to the trap',
        Min = 1,
        Max = 30,
        Default = 8,
        Visible = false,
        Darker = true,
        Suffix = function(val)
            return val == 1 and 'stud' or 'studs'
        end
    })
    DetonateTargets = Trapper:CreateTargets({
        Players = true,
        NPCs = false,
        Visible = false,
        Tooltip = 'Who is worth setting a trap off for'
    })
    PreferredTrap = Trapper:CreateDropdown({
        Name = 'Hold Trap',
        Tooltip = 'Keeps this trap selected',
        List = {'Off', 'Snap', 'Venom', 'Explosive'},
        Default = 'Off',
        Tooltips = {
            Off = 'Leaves whichever trap you picked',
            Snap = 'Roots whoever steps on it',
            Venom = 'Poisons whoever steps on it',
            Explosive = 'Detonated by you, and breaks blocks'
        }
    })
end)


kitRun(function()
    --[[
        Auto Miner.

        A Miner kill leaves a petrified statue of the victim, tagged 'petrified-player' and
        carrying a PetrifyId. Digging one is the "Gather" prompt: held for 2.5 seconds
        within 6 studs, then sent as DestroyPetrifiedPlayer with that id. Your own team's
        statues cannot be mined - the game refuses before the hold even starts - so they are
        never tried here either.

        How the hold is done is up to you: Legit holds it for as long as the game does,
        Custom for whatever time you set, Instant not at all. Whether the server checks the
        hold is not known, so Legit is the default.
    ]]
    local AutoMiner
    local Mode, HoldTime, Range, Target, Animation, StayInRange
    local PauseInCombat, CombatRange, Cooldown, Notify
    local StatueESP, ESPColor, ShowDistance
    local GAME_HOLD = 2.5
    local GAME_RANGE = 6
    local attempted = {}
    local Reference = {}
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local digRemote

    local function on(setting)
        return setting ~= nil and setting.Enabled
    end

    local function myTeam()
        local team = lplr:GetAttribute('Team')
        return team ~= nil and tostring(team) or nil
    end

    local function statueTeam(statue)
        local team = statue:GetAttribute('Team')
        if team == nil and statue.PrimaryPart then team = statue.PrimaryPart:GetAttribute('Team') end
        return team ~= nil and tostring(team) or nil
    end

    local function ownTeams(statue)
        local mine = myTeam()
        return mine ~= nil and statueTeam(statue) == mine
    end

    local function statuePosition(statue)
        local part = statue.PrimaryPart or statue:FindFirstChildWhichIsA('BasePart', true)
        return part and part.Position or nil
    end

    -- The dig remote, by the name the game sends it under. The name resolved from the
    -- prompt at load is kept as the fallback in case it is ever renamed again.
    local function getDigRemote()
        if digRemote then return digRemote end
        local ok, remote = pcall(function()
            return bedwars.Client:Get('DestroyPetrifiedPlayer')
        end)
        if not (ok and remote) then
            ok, remote = pcall(function()
                return bedwars.Client:Get(remotes.MinerDig)
            end)
        end
        digRemote = ok and remote or nil
        return digRemote
    end

    -- An enemy close enough that standing still to dig would be a mistake.
    local function inCombat(here)
        if not on(PauseInCombat) then return false end
        for _, ent in entitylib.List do
            if ent.Targetable and ent.Player and ent.RootPart
                and (ent.RootPart.Position - here).Magnitude <= CombatRange.Value then
                return true
            end
        end
        return false
    end

    local function teamLabel(statue)
        local team = statueTeam(statue)
        return team and itemAlerts.teamName(team) or 'A'
    end

    --[[
        The statue to dig next.

        Only statues in range, not your team's, and not one already being dug or just
        tried - a statue that survives a dig is retried after a few seconds rather than
        spammed every frame.
    ]]
    local function pickStatue(here)
        local best, bestScore
        local now = os.clock()
        for _, statue in collectionService:GetTagged('petrified-player') do
            if statue.Parent and statue:GetAttribute('PetrifyId') ~= nil and not ownTeams(statue) then
                local tried = attempted[statue]
                if not tried or now - tried > 3 then
                    local position = statuePosition(statue)
                    local distance = position and (position - here).Magnitude
                    if distance and distance <= Range.Value then
                        local score = Target.Value == 'Farthest' and -distance or distance
                        if not bestScore or score < bestScore then
                            best, bestScore = statue, score
                        end
                    end
                end
            end
        end
        return best
    end

    local function holdFor()
        if Mode.Value == 'Legit' then return GAME_HOLD end
        if Mode.Value == 'Custom' then return HoldTime.Value end
        return 0
    end

    local function dig(statue)
        local remote = getDigRemote()
        if not remote then return false end

        attempted[statue] = os.clock()
        local hold = holdFor()
        local track
        if on(Animation) and hold > 0 then
            pcall(function()
                track = bedwars.GameAnimationUtil:playAnimation(lplr, bedwars.AnimationType.MINER_MINE_STONE)
            end)
        end

        -- Held the way the prompt holds: given up if the statue goes or, when asked, if
        -- you walk out of reach before the time is up. Guarded, because the dig
        -- animation loops: anything throwing in here used to skip the stop below and
        -- leave it playing for good.
        local finished = true
        local started = os.clock()
        local ok = pcall(function()
            while os.clock() - started < hold do
                task.wait()
                if not (AutoMiner.Enabled and statue.Parent and entitylib.isAlive) then
                    finished = false
                    break
                end
                if on(StayInRange) then
                    local position = statuePosition(statue)
                    if not position or (position - entitylib.character.RootPart.Position).Magnitude > Range.Value then
                        finished = false
                        break
                    end
                end
            end
        end)
        if not ok then finished = false end

        if track then pcall(function() track:Stop(0.15) end) end
        if not finished then
            attempted[statue] = nil
            return false
        end

        local label = teamLabel(statue)
        local ok = pcall(function()
            remote:SendToServer({petrifyId = statue:GetAttribute('PetrifyId')})
        end)
        if ok and on(Notify) then
        end
        return ok
    end

    -- ── statue ESP ─────────────────────────────────────────────────────────
    local function espColor()
        return Color3.fromHSV(ESPColor and ESPColor.Hue or 0.08, ESPColor and ESPColor.Sat or 0.3, ESPColor and ESPColor.Value or 0.85)
    end

    local function espRemove(statue)
        local billboard = Reference[statue]
        if billboard then
            billboard:Destroy()
            Reference[statue] = nil
        end
    end

    local function espAdd(statue)
        if Reference[statue] or not on(StatueESP) then return end
        local part = statue.PrimaryPart or statue:FindFirstChildWhichIsA('BasePart', true)
        if not part then return end

        local billboard = Instance.new('BillboardGui')
        billboard.Name = 'Statue'
        billboard.Adornee = part
        billboard.Size = UDim2.fromOffset(160, 20)
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
        billboard.AlwaysOnTop = true
        billboard.Parent = Folder

        local label = Instance.new('TextLabel')
        label.Name = 'Label'
        label.Size = UDim2.fromScale(1, 1)
        label.BackgroundTransparency = 1
        label.RichText = true
        label.Font = Enum.Font.GothamBold
        label.TextSize = 13
        label.TextStrokeTransparency = 0.5
        label.TextColor3 = espColor()
        label.Parent = billboard

        Reference[statue] = billboard
    end

    -- Labels kept current: who it belongs to, and how far off it is when that is asked for.
    local function espUpdate()
        if not on(StatueESP) then return end
        local here = entitylib.isAlive and entitylib.character.RootPart.Position
        for statue, billboard in Reference do
            if not statue.Parent then
                espRemove(statue)
            else
                local label = billboard:FindFirstChild('Label')
                if label then
                    local text = ownTeams(statue) and 'Your team' or teamLabel(statue)
                    text = text .. ' statue'
                    if on(ShowDistance) and here then
                        local position = statuePosition(statue)
                        if position then
                            text = text .. ' [' .. math.floor((position - here).Magnitude) .. ']'
                        end
                    end
                    label.Text = text
                    label.TextColor3 = espColor()
                end
            end
        end
    end

    local function setupESP()
        AutoMiner:Clean(collectionService:GetInstanceAddedSignal('petrified-player'):Connect(function(statue)
            task.defer(espAdd, statue)
        end))
        AutoMiner:Clean(collectionService:GetInstanceRemovedSignal('petrified-player'):Connect(espRemove))
        for _, statue in collectionService:GetTagged('petrified-player') do
            espAdd(statue)
        end
    end

    local function clearESP()
        for statue in Reference do
            espRemove(statue)
        end
    end

    AutoMiner = vain.Categories.Kit:CreateModule({
        Name = 'Auto Miner',
        Tooltip = 'Digs up petrified statues for you as Miner',
        Function = function(callback)
            if callback then
                setupESP()
                task.spawn(function()
                    repeat
                        local waited = false
                        -- Guarded: one statue that cannot be read must not stop the module.
                        pcall(function()
                            espUpdate()
                            if store.equippedKit ~= 'miner' or not entitylib.isAlive then return end
                            local here = entitylib.character.RootPart.Position
                            if inCombat(here) then return end

                            local statue = pickStatue(here)
                            if statue and dig(statue) then
                                waited = true
                                task.wait(Cooldown.Value)
                            end
                        end)
                        if not waited then task.wait(0.1) end
                    until not AutoMiner.Enabled
                end)
            else
                clearESP()
                table.clear(attempted)
            end
        end
    })
    Mode = AutoMiner:CreateDropdown({
        Name = 'Mode',
        Tooltip = 'How the dig prompt is held',
        List = {'Legit', 'Custom', 'Instant'},
        Tooltips = {
            Legit = 'Holds it for the full 2.5 seconds, like the prompt',
            Custom = 'Holds it for the time set below',
            Instant = 'Digs straight away - may be rejected'
        },
        Function = function(value)
            if HoldTime and HoldTime.Object then HoldTime.Object.Visible = value == 'Custom' end
            if StayInRange and StayInRange.Object then StayInRange.Object.Visible = value ~= 'Instant' end
            if Animation and Animation.Object then Animation.Object.Visible = value ~= 'Instant' end
        end
    })
    HoldTime = AutoMiner:CreateSlider({
        Name = 'Hold Time',
        Tooltip = 'How long to hold the dig in Custom',
        Min = 0,
        Max = 2.5,
        Default = 1.5,
        Decimal = 10,
        Darker = true,
        Visible = false,
        Suffix = function()
            return 's'
        end
    })
    Range = AutoMiner:CreateSlider({
        Name = 'Range',
        Tooltip = 'How close a statue has to be\nThe game allows 6',
        Min = 1,
        Max = GAME_RANGE,
        Default = GAME_RANGE,
        Decimal = 10,
        Suffix = function(val)
            return val == 1 and 'stud' or 'studs'
        end
    })
    Target = AutoMiner:CreateDropdown({
        Name = 'Target',
        Tooltip = 'Which statue to dig first when there are several',
        List = {'Nearest', 'Farthest'}
    })
    Animation = AutoMiner:CreateToggle({
        Name = 'Animation',
        Tooltip = 'Plays the mining animation while holding',
        Default = true
    })
    StayInRange = AutoMiner:CreateToggle({
        Name = 'Stay In Range',
        Tooltip = 'Gives up the dig if you walk out of range',
        Default = true
    })
    Cooldown = AutoMiner:CreateSlider({
        Name = 'Cooldown',
        Tooltip = 'Wait between digs',
        Min = 0,
        Max = 3,
        Default = 0.2,
        Decimal = 10,
        Suffix = function()
            return 's'
        end
    })
    PauseInCombat = AutoMiner:CreateToggle({
        Name = 'Pause In Combat',
        Tooltip = 'Waits while an enemy is close',
        Function = function(callback)
            if CombatRange and CombatRange.Object then CombatRange.Object.Visible = callback end
        end
    })
    CombatRange = AutoMiner:CreateSlider({
        Name = 'Combat Range',
        Tooltip = 'How close an enemy has to be to pause',
        Min = 5,
        Max = 40,
        Default = 15,
        Darker = true,
        Visible = false,
        Suffix = function(val)
            return val == 1 and 'stud' or 'studs'
        end
    })
    Notify = AutoMiner:CreateToggle({
        Name = 'Notify',
        Tooltip = 'Tells you each time a statue is dug'
    })
    StatueESP = AutoMiner:CreateToggle({
        Name = 'Statue ESP',
        Tooltip = 'Names every petrified statue on the map',
        Function = function(callback)
            for _, setting in {ESPColor, ShowDistance} do
                if setting and setting.Object then setting.Object.Visible = callback end
            end
            if not callback then
                clearESP()
            elseif AutoMiner.Enabled then
                for _, statue in collectionService:GetTagged('petrified-player') do
                    espAdd(statue)
                end
            end
        end
    })
    ESPColor = AutoMiner:CreateColorSlider({
        Name = 'ESP Color',
        Tooltip = 'Colour of the statue labels',
        DefaultHue = 0.08,
        DefaultSat = 0.3,
        DefaultValue = 0.85,
        Darker = true,
        Visible = false
    })
    ShowDistance = AutoMiner:CreateToggle({
        Name = 'Show Distance',
        Tooltip = 'Adds how far away each statue is',
        Default = true,
        Darker = true,
        Visible = false
    })
end)

kitRun(function()
    --[[
        Milo.

        How the kit works now (MimicController): using the MIMIC_BLOCK ability sends
        MimicBlock with the block you picked - a block type and the position of a real
        block of it, from the block under your aim or under your feet - and the server
        answers ValidatedMimicBlock and turns you into that block. Standing still snaps you
        to the grid; moving or being hit reveals you (MimicBlockRevealed). While disguised,
        MimicBlockPickPocketReady says when you can pickpocket a player within 25 studs
        (MimicBlockPickPocketPlayer).

        To choose the block, the controller's getSelectedBlockFromPlayer is briefly swapped
        for one that returns the pick and the ability is used normally, so the game sends
        a request of its own with a real block behind it.
    ]]
    local Milo
    local BlockMode, BlockType, AutoDisguise, StillTime, AutoPickpocket, SearchRange
    local disguised, pickpocketReady = false, false
    local stillSince

    local function on(setting)
        return setting ~= nil and setting.Enabled
    end

    -- The block under your feet, the way the game finds it.
    local function blockBelow()
        if not entitylib.isAlive then return nil end
        local root = entitylib.character.RootPart
        local below = root.Position - Vector3.new(0, root.Size.Y / 2 + entitylib.character.HipHeight + 0.75, 0)
        local block, position = getPlacedBlock(below)
        if block and bedwars.ItemMeta[block.Name] then
            return {blockType = block.Name, blockPosition = position}
        end
    end

    -- The nearest placed block of the chosen type within range.
    local function nearestOfType(itemType)
        if not (entitylib.isAlive and itemType and itemType ~= '') then return nil end
        local here = bedwars.BlockController:getBlockPosition(entitylib.character.RootPart.Position)
        local store = bedwars.BlockController:getStore()
        local best, bestDistance
        for _, position in store:getAllBlockPositions() do
            local distance = (position - here).Magnitude
            if distance <= SearchRange.Value and (not bestDistance or distance < bestDistance) then
                local block = store:getBlockAt(position)
                if block and block.Name == itemType then
                    best, bestDistance = position, distance
                end
            end
        end
        return best and {blockType = itemType, blockPosition = best} or nil
    end

    local function choose()
        if BlockMode.Value == 'Below You' then return blockBelow() end
        if BlockMode.Value == 'Chosen Block' then return nearestOfType(BlockType.Value) end
        return nil
    end

    -- Uses the ability through the game, with the pick swapped in for the moment it reads it.
    local function disguise()
        local controller = bedwars.MimicController
        if not (controller and bedwars.AbilityController:canUseAbility('MIMIC_BLOCK')) then return false end
        if BlockMode.Value == 'Aim' then
            bedwars.AbilityController:useAbility('MIMIC_BLOCK')
            return true
        end
        local pick = choose()
        if not pick then return false end
        local original = controller.getSelectedBlockFromPlayer
        local swapped = function() return pick end
        controller.getSelectedBlockFromPlayer = swapped
        bedwars.AbilityController:useAbility('MIMIC_BLOCK')
        task.delay(0.5, function()
            if controller.getSelectedBlockFromPlayer == swapped then
                controller.getSelectedBlockFromPlayer = original
            end
        end)
        return true
    end

    -- Pickpockets the nearest enemy in reach once the game says it is ready.
    local function pickpocket()
        if not (entitylib.isAlive and pickpocketReady) then return end
        local here = entitylib.character.RootPart.Position
        local best, bestDistance
        for _, entity in entitylib.List do
            if entity.Player and entity.Targetable and entity.RootPart then
                local distance = (entity.RootPart.Position - here).Magnitude
                if distance <= 24 and (not bestDistance or distance < bestDistance) then
                    best, bestDistance = entity.Player, distance
                end
            end
        end
        if best then
            pickpocketReady = false
            task.spawn(function()
                pcall(function()
                    bedwars.Client:Get('MimicBlockPickPocketPlayer'):CallServer(best)
                end)
            end)
        end
    end

    Milo = vain.Categories.Kit:CreateModule({
        Name = 'Milo',
        Tooltip = 'Disguises you as the block you choose',
        Function = function(callback)
            if callback then
                disguised, pickpocketReady, stillSince = false, false, nil
                Milo:Clean(bedwars.Client:Get('ValidatedMimicBlock'):Connect(function(data)
                    if type(data) == 'table' and data.player == lplr then
                        disguised = data.blockType ~= nil
                    end
                end))
                Milo:Clean(bedwars.Client:Get('MimicBlockRevealed'):Connect(function()
                    disguised, pickpocketReady = false, false
                end))
                Milo:Clean(bedwars.Client:Get('MimicBlockPickPocketReady'):Connect(function(data)
                    if type(data) == 'table' and data.player == lplr then
                        pickpocketReady = data.ready == true
                    end
                end))

                local lastCheck = 0
                Milo:Clean(runService.Heartbeat:Connect(function()
                    if store.equippedKit ~= 'mimic' or not entitylib.isAlive then return end
                    if os.clock() - lastCheck < 0.2 then return end
                    lastCheck = os.clock()

                    if on(AutoPickpocket) and disguised then pcall(pickpocket) end

                    -- Standing still long enough, and not already a block: disguise.
                    local humanoid = entitylib.character.Humanoid
                    local still = humanoid and humanoid.MoveDirection.Magnitude == 0 and humanoid.FloorMaterial ~= Enum.Material.Air
                    if not still then
                        stillSince = nil
                    elseif not stillSince then
                        stillSince = os.clock()
                    end
                    if on(AutoDisguise) and not disguised and stillSince and os.clock() - stillSince >= StillTime.Value then
                        pcall(disguise)
                        stillSince = os.clock()
                    end
                end))
            else
                disguised, pickpocketReady = false, false
            end
        end
    })
    BlockMode = Milo:CreateDropdown({
        Name = 'Block',
        List = {'Below You', 'Chosen Block', 'Aim'},
        Tooltips = {
            ['Below You'] = 'The block you stand on, so you blend in',
            ['Chosen Block'] = 'The nearest block of the type below',
            Aim = 'Whatever you aim at, as the game does'
        },
        Function = function(val)
            for _, setting in {BlockType, SearchRange} do
                if setting and setting.Object then setting.Object.Visible = val == 'Chosen Block' end
            end
        end
    })
    BlockType = Milo:CreateTextBox({
        Name = 'Block Type',
        Placeholder = 'item name (wool_white)',
        Default = 'wool_white',
        Tooltip = 'Item name of the block to become',
        Visible = false
    })
    SearchRange = Milo:CreateSlider({
        Name = 'Search Range',
        Tooltip = 'How far to look for that block, in blocks',
        Min = 5,
        Max = 100,
        Default = 40,
        Darker = true,
        Visible = false
    })
    Milo:CreateButton({
        Name = 'Disguise Now',
        Tooltip = 'Becomes the block straight away',
        Function = function()
            pcall(disguise)
        end
    })
    AutoDisguise = Milo:CreateToggle({
        Name = 'Auto Disguise',
        Tooltip = 'Disguises whenever you stand still',
        Default = true,
        Function = function(callback)
            if StillTime and StillTime.Object then StillTime.Object.Visible = callback end
        end
    })
    StillTime = Milo:CreateSlider({
        Name = 'Still Time',
        Tooltip = 'How long to stand still first',
        Min = 0,
        Max = 3,
        Default = 0.6,
        Decimal = 10,
        Darker = true,
        Suffix = function() return 's' end
    })
    AutoPickpocket = Milo:CreateToggle({
        Name = 'Auto Pickpocket',
        Tooltip = 'Pickpockets the nearest enemy when ready',
        Default = true
    })
end)
