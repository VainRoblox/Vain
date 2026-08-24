local AutoFarm
local warned = false
local nextAbility = 0
local abilityIndex = 1

-- Held above the enemy rather than beside it: standing in the same space shoves you
-- around as it walks, and above keeps swings reaching down onto it.
local OFFSET = Vector3.new(0, 8, 0)

-- Attacking through tool:Activate and firetouchinterest does nothing here, which is why
-- the weapon never swung. That works in games whose damage comes off a touch or off the
-- tool itself; this one runs its combat through its own input handlers, which then fire
-- its own remotes. So the input is simulated instead and the game's code does the rest -
-- no knowledge of its internals needed, and whatever validation it does on its own
-- attacks is satisfied because they are its own attacks.
local virtualInput = cloneref(game:GetService('VirtualInputManager'))

-- The usual ability bindings. Pressing one that is not bound does nothing, so cycling
-- the set costs nothing and avoids needing to be told which keys this game uses.
local ABILITY_KEYS = {
	Enum.KeyCode.Q,
	Enum.KeyCode.E,
	Enum.KeyCode.R,
	Enum.KeyCode.F,
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three
}

local function swing()
	local centre = gameCamera.ViewportSize / 2
	pcall(function()
		virtualInput:SendMouseButtonEvent(centre.X, centre.Y, 0, true, game, 1)
		task.wait()
		virtualInput:SendMouseButtonEvent(centre.X, centre.Y, 0, false, game, 1)
	end)
end

-- One key per pass rather than the whole set at once: mashing everything together tends
-- to leave a game dropping all but the first, and spacing them lets each cooldown come
-- back around on its own.
local function useAbility()
	if tick() < nextAbility then return end
	nextAbility = tick() + 1

	local key = ABILITY_KEYS[abilityIndex]
	abilityIndex = abilityIndex % #ABILITY_KEYS + 1

	pcall(function()
		virtualInput:SendKeyEvent(true, key, false, game)
		task.wait()
		virtualInput:SendKeyEvent(false, key, false, game)
	end)
end

AutoFarm = vain.Categories.Blatant:CreateModule({
	Name = 'AutoFarm',
	Function = function(callback)
		if callback then
			warned = false
			nextAbility = 0

			task.spawn(function()
				repeat
					-- Guarded, yielding outside, so one bad pass cannot spin or end the
					-- farm for the session.
					local ok = pcall(function()
						if not entitylib.isAlive then return end

						local entity = entitylib.EntityPosition({
							Part = 'RootPart',
							Range = math.huge,
							Players = false,
							NPCs = true
						})

						-- Deliberately does nothing when there is nothing to do. An
						-- earlier version returned you to where you switched it on, every
						-- tenth of a second, which pinned you in place whenever detection
						-- came up empty.
						if not (entity and entity.RootPart) then
							if not warned then
								warned = true
								notif('AutoFarm', 'No enemies found. If there are some in front of you they are not being detected - tell me and I will widen it.', 12, 'alert')
							end
							return
						end

						warned = false

						local root = entitylib.character.RootPart
						root.CFrame = CFrame.new(entity.RootPart.Position + OFFSET, entity.RootPart.Position)
						root.AssemblyLinearVelocity = Vector3.zero

						targetinfo.Targets[entity] = tick() + 1
						swing()
						useAbility()
					end)

					task.wait(ok and 0.15 or 0.4)
				until not AutoFarm.Enabled
			end)
		end
	end,
	Tooltip = 'Flies to the nearest enemy, attacks it and uses abilities as they come up'
})
