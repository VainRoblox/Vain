local Attacking
run(function()
	-- Resolved at hook time rather than hardcoded: these hold the index of the KnitClient
	-- upvalue inside the game's own functions, which moves whenever the game shifts a
	-- local around. Looking it up by value means a shift can't make us overwrite an
	-- unrelated upvalue, and remembering the index keeps the restore path symmetric.
	local swingknitindex, scytheknitindex
	local Killaura
	local Targets
	local Sort
	local SwingRange
	local AttackRange
	local UpdateRate
	local AngleSlider
	local MaxTargets
	local Mouse
	local Swing
	local GUI
	local BoxSwingColor
	local BoxAttackColor
	local ParticleTexture
	local ParticleColor1
	local ParticleColor2
	local ParticleSize
	local Face
	local Animation
	local AnimationMode
	local AnimationSpeed
	local AnimationTween
	local Limit
	local LegitAura
	local Particles, Boxes = {}, {}
	local anims, AnimDelay, AnimTween, armC0, armWrist = vain.Libraries.auraanims, tick()
	local AttackStub = {FireServer = function() end}
	local AttackRemote = AttackStub
	-- Falls back to the no-op stub if the remote cannot be resolved, so a failure here
	-- degrades Killaura to "does nothing" instead of throwing on every attack. Resolving
	-- only once at load meant a single early failure - injecting before the remotes are
	-- registered - left every later attack silently going nowhere for the rest of the
	-- session, so this runs again on enable while the stub is still in place.
	local function resolveAttackRemote()
		if AttackRemote ~= AttackStub then return end
		local ok, remote = pcall(function()
			return bedwars.Client:Get(remotes.AttackEntity).instance
		end)
		if ok and remote then
			AttackRemote = remote
		end
	end
	task.spawn(resolveAttackRemote)

	local function getAttackData()
		if Mouse.Enabled then
			if not inputService:IsMouseButtonPressed(0) then return false end
		end

		if GUI.Enabled then
			if bedwars.AppController:isLayerOpen(bedwars.UILayers.MAIN) then return false end
		end

		local sword = Limit.Enabled and store.hand or store.tools.sword
		if not sword or not sword.tool then return false end

		-- store.hand carries no itemType, so the tool instance name is the fallback key.
		-- An item the metadata does not know about leaves meta nil, and the attack path
		-- reads meta.sword.attackSpeed and meta.displayName straight off it - that threw,
		-- and because it throws on every pass Killaura sat enabled doing nothing at all.
		local meta = bedwars.ItemMeta[sword.itemType or sword.tool.Name]
		if not meta or not meta.sword then return false end

		if Limit.Enabled then
			if store.hand.toolType ~= 'sword' or (bedwars.DaoController and bedwars.DaoController.chargingMaid) then return false end
		end

		if LegitAura.Enabled then
			if (tick() - bedwars.SwordController.lastSwing) > 0.2 then return false end
		end

		return sword, meta
	end

	Killaura = vain.Categories.Blatant:CreateModule({
		Name = 'Killaura',
		Function = function(callback)
			if callback then
				task.spawn(resolveAttackRemote)

				if inputService.TouchEnabled then
					pcall(function()
						lplr.PlayerGui.MobileUI['2'].Visible = Limit.Enabled
					end)
				end

				pcall(function()
					if Animation.Enabled and not (identifyexecutor and table.find({'Argon', 'Delta'}, ({identifyexecutor()})[1])) then
						local fake = {
							Controllers = {
								ViewmodelController = {
									isVisible = function()
										return not Attacking
									end,
									playAnimation = function(...)
										if not Attacking then
											bedwars.ViewmodelController:playAnimation(select(2, ...))
										end
									end
								}
							}
						}
						local swingfunc = oldSwing or bedwars.SwordController.playSwordEffect
						swingknitindex = findUpvalue(swingfunc, bedwars.Knit)
						if swingknitindex then
							debug.setupvalue(swingfunc, swingknitindex, fake)
						end
						scytheknitindex = findUpvalue(bedwars.ScytheController.playLocalAnimation, bedwars.Knit)
						if scytheknitindex then
							debug.setupvalue(bedwars.ScytheController.playLocalAnimation, scytheknitindex, fake)
						end

						task.spawn(function()
						local started = false
						repeat
							-- Guarded: this touches gameCamera.Viewmodel, which does not exist while
							-- respawning or with an empty hand. An error here used to kill the
							-- animation thread for the rest of the session.
							local ok = pcall(function()
								if Attacking then
									-- The viewmodel is rebuilt whenever you switch items, so the wrist the
									-- resting C0 was taken from can be a destroyed instance by now. Caching it
									-- once left the animation offsetting from a stale base, and the restore
									-- below putting the arm back to the wrong place.
									local wrist = gameCamera.Viewmodel.RightHand.RightWrist
									if armWrist ~= wrist then
										armWrist, armC0 = wrist, wrist.C0
									end
									local first = not started
									started = true

									if AnimationMode.Value == 'Random' then
										anims.Random = {{CFrame = CFrame.Angles(math.rad(math.random(1, 360)), math.rad(math.random(1, 360)), math.rad(math.random(1, 360))), Time = 0.12}}
									end

									for _, v in anims[AnimationMode.Value] do
										AnimTween = tweenService:Create(wrist, TweenInfo.new(first and (AnimationTween.Enabled and 0.001 or 0.1) or v.Time / AnimationSpeed.Value, Enum.EasingStyle.Linear), {
											C0 = armC0 * v.CFrame
										})
										AnimTween:Play()
										AnimTween.Completed:Wait()
										first = false
										if (not Killaura.Enabled) or (not Attacking) then break end
									end
								elseif started then
									started = false
									AnimTween = tweenService:Create(armWrist, TweenInfo.new(AnimationTween.Enabled and 0.001 or 0.3, Enum.EasingStyle.Exponential), {
										C0 = armC0
									})
									AnimTween:Play()
								end
							end)

							-- Always yield on failure, otherwise a repeating error spins the CPU:
							-- the normal path only skips the wait because the tween Wait() above
							-- provides the yield, and that never ran if we errored.
							if (not ok) or (not started) then
								started = started and ok
								task.wait(1 / UpdateRate.Value)
							end
						until (not Killaura.Enabled) or (not Animation.Enabled)
						end)
					end
				end)

				repeat
					local attacked = {}
					-- The whole pass is wrapped because this is a long-lived loop that
					-- touches game state which can vanish mid-iteration (entities dying,
					-- item metadata changing as you switch weapons). An uncaught error
					-- here used to kill the coroutine outright, leaving Killaura toggled
					-- on but permanently dead. The wait is deliberately kept outside the
					-- pcall so a repeating error cannot turn into a busy spin.
					local ok = pcall(function()
						local sword, meta = getAttackData()
						Attacking = false
						store.KillauraTarget = nil
						if sword then
							-- Deliberately unlimited: AllPosition applies Limit *after* sorting,
							-- so passing MaxTargets here truncates the list before Killaura has
							-- had a chance to check attack range or the angle cone. A target that
							-- sits inside swing range but outside attack range - or behind you -
							-- would eat the only slot and starve a closer, hittable one, which
							-- looked like Killaura swinging endlessly for no damage. MaxTargets is
							-- about how many entities to *hit*, so it is enforced below instead.
							local plrs = entitylib.AllPosition({
								Range = SwingRange.Value,
								Wallcheck = Targets.Walls.Enabled or nil,
								Part = 'RootPart',
								Players = Targets.Players.Enabled,
								NPCs = Targets.NPCs.Enabled,
								Preference = Targets.Preference.Value,
								Sort = sortmethods[Sort.Value]
							})

							if #plrs > 0 then
								switchItem(sword.tool, 0)
								local hits = 0
								local selfpos = entitylib.character.RootPart.Position
								local localfacing = entitylib.character.RootPart.CFrame.LookVector * Vector3.new(1, 0, 1)

								for _, v in plrs do
									-- Entities can be torn down between selection and use (NPCs
									-- despawning), so re-check rather than indexing blind.
									if not v.RootPart or not v.Character then continue end
									local delta = (v.RootPart.Position - selfpos)
									-- Flatten first, then reject a zero-length horizontal delta.
									-- A target directly overhead - a diamond guardian sitting on
									-- top of the generator you are standing under - makes this a
									-- zero vector, whose .Unit is NaN. Every comparison against
									-- NaN is false, so the angle check silently passed and the
									-- NaN flowed into the attack maths below.
									local flat = delta * Vector3.new(1, 0, 1)
									if flat.Magnitude <= 0 then continue end
									local angle = math.acos(math.clamp(localfacing:Dot(flat.Unit), -1, 1))
									if angle > (math.rad(AngleSlider.Value) / 2) then continue end

									local inrange = delta.Magnitude <= AttackRange.Value

									table.insert(attacked, {
										Entity = v,
										Check = inrange and BoxAttackColor or BoxSwingColor
									})
									targetinfo.Targets[v] = tick() + 1

									if not Attacking then
										Attacking = true
										store.KillauraTarget = v
										if not Swing.Enabled and AnimDelay < tick() and not LegitAura.Enabled then
											AnimDelay = tick() + (meta.sword.respectAttackSpeedForEffects and meta.sword.attackSpeed or 0.11)
											bedwars.SwordController:playSwordEffect(meta, false)
											if meta.displayName and meta.displayName:find(' Scythe') then
												bedwars.ScytheController:playLocalAnimation()
											end

											if vain.ThreadFix then
												setthreadidentity(8)
											end
										end
									end

									-- Out-of-reach targets still get a box and a swing, they just do
									-- not consume one of the MaxTargets attack slots.
									if not inrange then continue end
									if hits >= MaxTargets.Value then continue end
									hits += 1

									local actualRoot = v.Character.PrimaryPart
									if actualRoot then
										local dir = CFrame.lookAt(selfpos, actualRoot.Position).LookVector
										local pos = selfpos + dir * math.max(delta.Magnitude - 14.399, 0)
										bedwars.SwordController.lastAttack = workspace:GetServerTimeNow()
										store.attackReach = (delta.Magnitude * 100) // 1 / 100
										store.attackReachUpdate = tick() + 1

										AttackRemote:FireServer({
											weapon = sword.tool,
											chargedAttack = {chargeRatio = 0},
											entityInstance = v.Character,
											validate = {
												raycast = {
													cameraPosition = {value = pos},
													cursorDirection = {value = dir}
												},
												targetPosition = {value = actualRoot.Position},
												selfPosition = {value = pos}
											}
										})
									end
								end
							end
						end

						for i, v in Boxes do
							v.Adornee = attacked[i] and attacked[i].Entity.RootPart or nil
							if v.Adornee then
								v.Color3 = Color3.fromHSV(attacked[i].Check.Hue, attacked[i].Check.Sat, attacked[i].Check.Value)
								v.Transparency = 1 - attacked[i].Check.Opacity
							end
						end

						-- RootPart is read through a local rather than indexed straight off the
						-- entity: a target that leaves range and comes back (NPCs especially,
						-- since they despawn and respawn) can have its RootPart torn down
						-- between being picked above and being drawn here. Indexing .Position
						-- on that nil threw, and since this whole thing is a bare repeat loop
						-- with no error handling, the throw killed the loop outright and
						-- Killaura stayed dead until you rejoined.
						for i, v in Particles do
							local root = attacked[i] and attacked[i].Entity.RootPart
							v.Position = root and root.Position or Vector3.new(9e9, 9e9, 9e9)
							v.Parent = root and gameCamera or nil
						end

						local faceroot = attacked[1] and attacked[1].Entity.RootPart
						if Face.Enabled and faceroot and entitylib.isAlive then
							local vec = faceroot.Position * Vector3.new(1, 0, 1)
							entitylib.character.RootPart.CFrame = CFrame.lookAt(entitylib.character.RootPart.Position, Vector3.new(vec.X, entitylib.character.RootPart.Position.Y + 0.001, vec.Z))
						end

					end)

					if not ok then
						-- Drop out of the attacking state so the animation thread and the
						-- viewmodel do not stay stuck mid-swing after a failed pass.
						Attacking = false
						store.KillauraTarget = nil
					end
					task.wait(#attacked > 0 and #attacked * 0.02 or 1 / UpdateRate.Value)
				until not Killaura.Enabled
			else
				store.KillauraTarget = nil
				for _, v in Boxes do
					v.Adornee = nil
				end
				for _, v in Particles do
					v.Parent = nil
				end
				if inputService.TouchEnabled then
					pcall(function()
						lplr.PlayerGui.MobileUI['2'].Visible = true
					end)
				end
				-- Restores run under pcall so that a failure to put one upvalue back cannot
				-- skip the ones after it - leaving the game's functions permanently holding
				-- our fake table would break swords even with Killaura off.
				if swingknitindex then
					pcall(debug.setupvalue, oldSwing or bedwars.SwordController.playSwordEffect, swingknitindex, bedwars.Knit)
					swingknitindex = nil
				end
				if scytheknitindex then
					pcall(debug.setupvalue, bedwars.ScytheController.playLocalAnimation, scytheknitindex, bedwars.Knit)
					scytheknitindex = nil
				end
				Attacking = false
				if armC0 and armWrist then
					-- The viewmodel is gone while dead or respawning, which is exactly when
					-- someone is likely to toggle this off.
					pcall(function()
						AnimTween = tweenService:Create(armWrist, TweenInfo.new(AnimationTween.Enabled and 0.001 or 0.3, Enum.EasingStyle.Exponential), {
							C0 = armC0
						})
						AnimTween:Play()
					end)
				end
			end
		end,
		Tooltip = 'Attack players around you\nwithout aiming at them.'
	})
	Targets = Killaura:CreateTargets({
		Players = true,
		NPCs = true,
		Tooltip = 'Which entities this module is allowed to target'
	})
	-- Damage/Distance stay pinned to the front (Damage is the default), the rest are
	-- sorted so the dropdown order stays stable - iterating sortmethods directly is
	-- hash order, which reshuffles the list between injections.
	local methods, extramethods = {'Damage', 'Distance'}, {}
	for i in sortmethods do
		if not table.find(methods, i) then
			table.insert(extramethods, i)
		end
	end
	table.sort(extramethods)
	for _, v in extramethods do
		table.insert(methods, v)
	end
	SwingRange = Killaura:CreateSlider({
		Name = 'Swing range',
		Tooltip = 'How far your swing reaches, in studs',
		Min = 1,
		Max = 28,
		Default = 28,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	AttackRange = Killaura:CreateSlider({
		Name = 'Attack range',
		Tooltip = 'How far a target can be and still be hit',
		Min = 1,
		Max = 20,
		Default = 20,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	AngleSlider = Killaura:CreateSlider({
		Name = 'Max angle',
		Tooltip = 'Widest angle from the way your character faces a target may be at',
		Min = 1,
		Max = 360,
		Default = 360
	})
	UpdateRate = Killaura:CreateSlider({
		Name = 'Update rate',
		Tooltip = 'How many times per second targets are re-checked\nLower costs less performance',
		Min = 1,
		Max = 120,
		Default = 60,
		Suffix = 'hz'
	})
	MaxTargets = Killaura:CreateSlider({
		Name = 'Max targets',
		Tooltip = 'How many targets to hit per swing',
		Min = 1,
		Max = 5,
		Default = 5
	})
	Sort = Killaura:CreateDropdown({
		Name = 'Target Mode',
		Tooltip = 'How targets are ranked when several are valid at once',
		List = methods,
		Tooltips = sortmethodtips
	})
	Mouse = Killaura:CreateToggle({Name = 'Require mouse down', Tooltip = 'Only acts while you hold left click'})
	Swing = Killaura:CreateToggle({Name = 'No Swing', Tooltip = 'Attacks without playing the swing animation'})
	GUI = Killaura:CreateToggle({Name = 'GUI check', Tooltip = 'Stops acting while a game menu is open'})
	Killaura:CreateToggle({
		Name = 'Show target',
		Tooltip = 'Draws a box around the target you are attacking',
		Function = function(callback)
			BoxSwingColor.Object.Visible = callback
			BoxAttackColor.Object.Visible = callback
			if callback then
				for i = 1, 10 do
					local box = Instance.new('BoxHandleAdornment')
					box.Adornee = nil
					box.AlwaysOnTop = true
					box.Size = Vector3.new(3, 5, 3)
					box.CFrame = CFrame.new(0, -0.5, 0)
					box.ZIndex = 0
					box.Parent = vain.gui
					Boxes[i] = box
				end
			else
				for _, v in Boxes do
					v:Destroy()
				end
				table.clear(Boxes)
			end
		end
	})
	BoxSwingColor = Killaura:CreateColorSlider({
		Name = 'Target Color',
		Tooltip = 'Box color while a target is in swing range',
		Darker = true,
		DefaultHue = 0.6,
		DefaultOpacity = 0.5,
		Visible = false
	})
	BoxAttackColor = Killaura:CreateColorSlider({
		Name = 'Attack Color',
		Tooltip = 'Box color while a target is being attacked',
		Darker = true,
		DefaultOpacity = 0.5,
		Visible = false
	})
	Killaura:CreateToggle({
		Name = 'Target particles',
		Tooltip = 'Spawns particles on the target you hit',
		Function = function(callback)
			ParticleTexture.Object.Visible = callback
			ParticleColor1.Object.Visible = callback
			ParticleColor2.Object.Visible = callback
			ParticleSize.Object.Visible = callback
			if callback then
				for i = 1, 10 do
					local part = Instance.new('Part')
					part.Size = Vector3.new(2, 4, 2)
					part.Anchored = true
					part.CanCollide = false
					part.Transparency = 1
					part.CanQuery = false
					part.Parent = Killaura.Enabled and gameCamera or nil
					local particles = Instance.new('ParticleEmitter')
					particles.Brightness = 1.5
					particles.Size = NumberSequence.new(ParticleSize.Value)
					particles.Shape = Enum.ParticleEmitterShape.Sphere
					particles.Texture = ParticleTexture.Value
					particles.Transparency = NumberSequence.new(0)
					particles.Lifetime = NumberRange.new(0.4)
					particles.Speed = NumberRange.new(16)
					particles.Rate = 128
					particles.Drag = 16
					particles.ShapePartial = 1
					particles.Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, Color3.fromHSV(ParticleColor1.Hue, ParticleColor1.Sat, ParticleColor1.Value)),
						ColorSequenceKeypoint.new(1, Color3.fromHSV(ParticleColor2.Hue, ParticleColor2.Sat, ParticleColor2.Value))
					})
					particles.Parent = part
					Particles[i] = part
				end
			else
				for _, v in Particles do
					v:Destroy()
				end
				table.clear(Particles)
			end
		end
	})
	ParticleTexture = Killaura:CreateTextBox({
		Name = 'Texture',
		Tooltip = 'Particle image asset id',
		Default = 'rbxassetid://14736249347',
		Function = function()
			for _, v in Particles do
				v.ParticleEmitter.Texture = ParticleTexture.Value
			end
		end,
		Darker = true,
		Visible = false
	})
	ParticleColor1 = Killaura:CreateColorSlider({
		Name = 'Color Begin',
		Tooltip = 'Particle color when it spawns',
		Function = function(hue, sat, val)
			for _, v in Particles do
				v.ParticleEmitter.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromHSV(hue, sat, val)),
					ColorSequenceKeypoint.new(1, Color3.fromHSV(ParticleColor2.Hue, ParticleColor2.Sat, ParticleColor2.Value))
				})
			end
		end,
		Darker = true,
		Visible = false
	})
	ParticleColor2 = Killaura:CreateColorSlider({
		Name = 'Color End',
		Tooltip = 'Particle color as it fades out',
		Function = function(hue, sat, val)
			for _, v in Particles do
				v.ParticleEmitter.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromHSV(ParticleColor1.Hue, ParticleColor1.Sat, ParticleColor1.Value)),
					ColorSequenceKeypoint.new(1, Color3.fromHSV(hue, sat, val))
				})
			end
		end,
		Darker = true,
		Visible = false
	})
	ParticleSize = Killaura:CreateSlider({
		Name = 'Size',
		Tooltip = 'Size of the effect',
		Min = 0,
		Max = 1,
		Default = 0.2,
		Decimal = 100,
		Function = function(val)
			for _, v in Particles do
				v.ParticleEmitter.Size = NumberSequence.new(val)
			end
		end,
		Darker = true,
		Visible = false
	})
	Face = Killaura:CreateToggle({Name = 'Face target', Tooltip = 'Turns your character toward the target'})
	Animation = Killaura:CreateToggle({
		Name = 'Custom Animation',
		Tooltip = '[DISABLED - causes errors]',
		Function = function(callback)
		end
	})
	local animnames = {}
	for i in anims do
		table.insert(animnames, i)
	end
	AnimationMode = Killaura:CreateDropdown({
		Name = 'Animation Mode',
		Tooltip = 'Which custom swing animation to play',
		List = animnames,
		Darker = true,
		Visible = false
	})
	AnimationSpeed = Killaura:CreateSlider({
		Name = 'Animation Speed',
		Tooltip = 'How fast the custom animation plays',
		Min = 0,
		Max = 2,
		Default = 1,
		Decimal = 10,
		Darker = true,
		Visible = false
	})
	AnimationTween = Killaura:CreateToggle({
		Name = 'No Tween',
		Tooltip = 'Snaps the animation instead of smoothing it',
		Darker = true,
		Visible = false
	})
	Limit = Killaura:CreateToggle({
		Name = 'Limit to items',
		Function = function(callback)
			if inputService.TouchEnabled and Killaura.Enabled then
				pcall(function()
					lplr.PlayerGui.MobileUI['2'].Visible = callback
				end)
			end
		end,
		Tooltip = 'Only attacks when the sword is held'
	})
	LegitAura = Killaura:CreateToggle({
		Name = 'Swing only',
		Tooltip = 'Only attacks while swinging manually'
	})
end)