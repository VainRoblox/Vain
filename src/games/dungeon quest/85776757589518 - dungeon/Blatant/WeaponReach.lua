local WeaponReach
local oldnamecall

-- How far a swing should reach once extended, and how close to you a check has to start
-- before it is treated as yours.
local REACH = 60
local ORIGIN_RADIUS = 12
-- Only short checks are stretched. A long one is the game doing something else - line of
-- sight, a camera check, a projectile - and lengthening those breaks more than it helps.
local MELEE_LIMIT = 40

-- Extends the hit check the weapon performs, rather than the weapon itself.
--
-- There is no reading this game's weapon code from here, so instead of guessing at its
-- internals this works on what any melee hit check has to do regardless of how it is
-- written: cast from about where you are, over a short distance. Anything matching that
-- shape gets stretched, and everything else is passed through untouched.
--
-- If the hit is decided on the server, none of this reaches it - the client's own check
-- is then only for show, and extending it changes nothing. That is the case this cannot
-- cover and cannot detect from the outside.
local function nearMe(position)
	if not entitylib.isAlive then return false end
	return (position - entitylib.character.RootPart.Position).Magnitude <= ORIGIN_RADIUS
end

WeaponReach = vain.Categories.Blatant:CreateModule({
	Name = 'WeaponReach',
	Function = function(callback)
		if callback then
			if not (hookmetamethod and getnamecallmethod) then
				notif('WeaponReach', 'Your executor cannot hook namecalls, so this cannot work here.', 10, 'alert')
				return
			end

			oldnamecall = hookmetamethod(game, '__namecall', function(...)
				local method = getnamecallmethod()

				-- Left alone unless it is a spatial query, and never for calls this
				-- client makes itself - that would catch Vain's own raycasts.
				if checkcaller() or (method ~= 'Raycast' and method ~= 'GetPartBoundsInRadius') then
					return oldnamecall(...)
				end

				local self, args = ..., {select(2, ...)}

				if method == 'Raycast' then
					local origin, direction = args[1], args[2]
					if typeof(origin) == 'Vector3' and typeof(direction) == 'Vector3'
						and direction.Magnitude <= MELEE_LIMIT and nearMe(origin) then
						-- Same direction, longer. Changing the direction as well would
						-- aim it somewhere the game did not intend.
						args[2] = direction.Unit * REACH
						return oldnamecall(self, unpack(args))
					end
				elseif method == 'GetPartBoundsInRadius' then
					local position, radius = args[1], args[2]
					if typeof(position) == 'Vector3' and type(radius) == 'number'
						and radius <= MELEE_LIMIT and nearMe(position) then
						args[2] = REACH
						return oldnamecall(self, unpack(args))
					end
				end

				return oldnamecall(...)
			end)

			WeaponReach:Clean(function()
				if oldnamecall and hookmetamethod then
					-- Put back by re-hooking with the original, since there is no
					-- unhook - leaving ours in place would keep stretching after the
					-- module is off.
					pcall(hookmetamethod, game, '__namecall', oldnamecall)
					oldnamecall = nil
				end
			end)
		end
	end,
	Tooltip = 'Stretches the hit check your weapon performs, so swings connect from further away'
})
