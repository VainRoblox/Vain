-- Registered under the Kit category but kept in Utility/ because VainBundler walks a
-- hardcoded folder list and skips anything else - same reason as AutoAdetunde.
--
-- Zephyr is 'wind_walker' internally, which is why nothing in the game files matches
-- the kit's display name. The server drives the speed: it fires WindWalkerSpeedUpdate
-- with {orbCount, multiplier} and the controller turns that into a moveSpeedMultiplier
-- on the SprintController's movement modifier, growing with the orb count. Hooking
-- updateSpeed scales that multiplier on the way through, so the boost stays inside the
-- game's own modifier system instead of writing WalkSpeed behind its back - and when
-- the orbs reset the server sends a multiplier of 1, which passes straight through and
-- drops you back to default speed on its own.
-- How sharply the slider's effect tapers off as the kit's own bonus grows. Higher
-- means high stacks get proportionally less of the extra speed.
local FALLOFF = 2

local ZephyrSpeed
local Multiplier
local oldUpdateSpeed
local lastMultiplier = 1

local function getController()
	-- Resolves through the bedwars metatable, which falls back to Knit.Controllers.
	-- Nil until the kit controller loads, so it is re-checked rather than cached.
	return bedwars.WindWalkerController
end

-- Re-runs the current multiplier through the hook so toggling the module or moving the
-- slider takes effect immediately rather than waiting for the next orb update. With the
-- module off the hook passes the original value through untouched, which restores the
-- game's own speed, so this doubles as the disable path.
local function reapply()
	local controller = getController()
	if not (controller and oldUpdateSpeed) then return end
	pcall(controller.updateSpeed, controller, lastMultiplier)
end

ZephyrSpeed = vain.Categories.Kit:CreateModule({
	Name = 'ZephyrSpeed',
	Function = function(callback)
		local controller = getController()
		if not controller then return end

		if callback and not oldUpdateSpeed then
			oldUpdateSpeed = controller.updateSpeed
			controller.updateSpeed = function(self, multiplier, ...)
				-- Kept unscaled so toggling off can hand the real value back.
				lastMultiplier = multiplier or 1
				if ZephyrSpeed.Enabled and lastMultiplier ~= 1 then
					-- Scales the bonus rather than the multiplier, so a server value of
					-- 1.3 with the slider at 3 gives 1.9 and not 3.9, and a multiplier
					-- of 1 (orbs reset) is left alone so speed returns to default.
					--
					-- The slider's effect is then tapered by how large the server's own
					-- bonus already is. Applying it flat meant the extra speed grew in
					-- step with the orb count and ran away at high stacks; this keeps
					-- most of the slider at low orb counts and progressively less of it
					-- as the kit's own bonus climbs.
					local bonus = lastMultiplier - 1
					local falloff = 1 / (1 + (bonus * FALLOFF))
					multiplier = 1 + (bonus * (1 + ((Multiplier.Value - 1) * falloff)))
				end
				return oldUpdateSpeed(self, multiplier, ...)
			end
		end

		reapply()
	end,
	ExtraText = function()
		return Multiplier.Value .. 'x'
	end,
	Tooltip = 'Scales the speed Zephyr gains from orbs'
})
Multiplier = ZephyrSpeed:CreateSlider({
	Name = 'Multiplier',
	Tooltip = 'How much to scale the speed bonus from orbs\n1 leaves it untouched',
	Min = 1,
	Max = 4,
	Default = 2,
	Decimal = 10,
	Suffix = 'x',
	Function = reapply
})
