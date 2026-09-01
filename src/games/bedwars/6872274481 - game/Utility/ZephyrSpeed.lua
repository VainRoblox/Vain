-- Registered under the Kit category but kept in Utility/ because VainBundler walks a
-- hardcoded folder list and skips anything else - same reason as AutoAdetunde.
--
-- Zephyr is 'wind_walker' internally, which is why nothing in the game files matches
-- the kit's display name. The server fires WindWalkerSpeedUpdate with
-- {orbCount, multiplier}; the controller turns the multiplier into a
-- moveSpeedMultiplier on the SprintController's movement modifier, and sends a
-- multiplier of 1 once the orbs reset. Hooking updateSpeed is therefore the cleanest
-- signal for "does the player currently have stacks", which is all this needs.
local ZephyrSpeed
local Speed
local oldUpdateSpeed
local hasStacks = false

-- The setting is created after CreateModule returns, so it can still be nil while this
-- file is executing and while a saved config is being restored. Sprinting normally sits
-- at 26, which is what the fallback is measured against.
local function speed()
	return Speed and Speed.Value or 40
end

local function getController()
	-- Resolves through the bedwars metatable, which falls back to Knit.Controllers.
	-- Nil until the kit controller loads, so it is re-checked rather than cached.
	return bedwars.WindWalkerController
end

local function hookController()
	local controller = getController()
	if not controller or oldUpdateSpeed then return end

	oldUpdateSpeed = controller.updateSpeed
	controller.updateSpeed = function(self, multiplier, ...)
		-- A multiplier of exactly 1 is what the server sends once the orbs are gone.
		hasStacks = (multiplier or 1) ~= 1
		return oldUpdateSpeed(self, multiplier, ...)
	end
end

ZephyrSpeed = vain.Categories.Kit:CreateModule({
	Name = 'ZephyrSpeed',
	Function = function(callback)
		if callback then
			hookController()

			ZephyrSpeed:Clean(runService.RenderStepped:Connect(function()
				-- Re-hooked here too, because the kit controller may not have existed
				-- when the module was switched on - joining before the round starts, or
				-- switching to Zephyr mid-game.
				if not oldUpdateSpeed then hookController() end
				if not (hasStacks and entitylib.isAlive) then
					store.zephyrSpeed = nil
					return
				end

				-- Written every frame rather than once, because the game recalculates
				-- WalkSpeed from its own modifiers whenever they change - sprinting
				-- toggling on and off rewrites it constantly. Once the orbs reset,
				-- hasStacks goes false and the game is left to set the speed itself,
				-- which is what returns you to default.
				entitylib.character.Humanoid.WalkSpeed = speed()
				-- Published for Fly, which tops your natural speed up to its own target
				-- rather than replacing it, and works that out from getSpeed() - which
				-- reads the game's movement modifiers and so cannot see a WalkSpeed
				-- written directly. Without this it would keep flying at its own slower
				-- cap while you sprinted faster on the ground.
				store.zephyrSpeed = speed()
			end))
		else
			hasStacks = false
			store.zephyrSpeed = nil
		end
	end,
	ExtraText = function()
		return speed() .. ''
	end,
	Tooltip = 'Increase Zephyr speed'
})
Speed = ZephyrSpeed:CreateSlider({
	Name = 'Speed',
	Tooltip = 'How fast the orbs carry you (default 40, sprinting is 26)',
	Min = 26,
	Max = 100,
	Default = 40,
	Suffix = 'studs'
})
