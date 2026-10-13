--[[
	Projectile Aimbot.

	Silent, like the Bedwars one: it does not move your camera. When a projectile weapon is
	drawn and a target sits inside the circle, it replaces the direction the shot is built
	from with one solved to land on where the target will be - lead, drop and the target's
	own motion all accounted for - so the shot curves onto them while your aim stays where
	you put it.

	It works because the client hands the server the direction it fires. That direction comes
	from Util.AimDirection, so this wraps that one function: when it should aim, it returns
	the solved direction; otherwise it returns exactly what the game would have. Melee asks
	the same function for its facing, but a melee weapon is never a projectile weapon, so the
	swing is left alone. Speed and gravity are read from the equipped weapon itself, so each
	bow, sling or javelin is solved at its own arc.
]]
local ProjectileAimbot
local Targets
local TargetPart
local FOV
local Range
local HitChance
local ShowFOV
local FOVColor
local CircleObject
local tribes = vain.Libraries.tribes
local prediction = tribes.prediction

-- The weapons that fire something with travel time. A melee handler has no kind here, so it
-- never matches and its facing is left untouched.
local RANGED = {
	Bow = true, Crossbow = true, Musket = true, Pistol = true, Blunderbuss = true,
	Javelin = true, Sling = true, Bomb = true, Knives = true
}

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local hooked = false

local function mousePosition()
	if inputService.TouchEnabled then
		return gameCamera.ViewportSize / 2
	end
	return inputService:GetMouseLocation()
end

-- Whichever of head or root sits closer to the cursor, for the Nearest part option.
local function nearestPart(entity)
	local best, bestMag = 'RootPart', math.huge
	for _, name in {'Head', 'RootPart'} do
		local part = entity[name]
		if part then
			local screen, visible = gameCamera:WorldToViewportPoint(part.Position)
			local mag = visible and (mousePosition() - Vector2.new(screen.X, screen.Y)).Magnitude or math.huge
			if mag < bestMag then
				best, bestMag = name, mag
			end
		end
	end
	return best
end

-- The solved direction to fire in, or nil to let the game aim itself.
local function solve(origin)
	if not (ProjectileAimbot.Enabled and entitylib.isAlive) then return nil end

	local state = tribes.handlerState()
	local handler = state and state.handler
	if not (handler and handler.tuning and state.kind and RANGED[state.kind]) then
		return nil
	end

	local target = entitylib.EntityMouse({
		Part = TargetPart.Value == 'Nearest' and 'RootPart' or TargetPart.Value,
		Range = FOV.Value,
		Players = Targets.Players.Enabled,
		NPCs = Targets.NPCs.Enabled,
		Wallcheck = Targets.Walls.Enabled,
		Origin = origin
	})
	if not target then return nil end

	local part = target[TargetPart.Value == 'Nearest' and nearestPart(target) or TargetPart.Value]
	if not part then return nil end
	if (part.Position - origin).Magnitude > Range.Value then return nil end

	-- Speed and gravity straight off the equipped weapon, so each one is solved at its own
	-- arc. ShotSpeed is the full-draw speed, which is what an aimed shot is fired at.
	local tuning = handler.tuning
	local gravity = tuning.gravity or 60
	local combat = tribes.resolveCombat().Combat
	local speed = (combat and combat.ShotSpeed and combat.ShotSpeed(tuning)) or tuning.speed or tuning.speedMax or 200

	local aimpos = part.Position
	-- Hit Chance throws a shot wide on purpose by nudging the aim off the target.
	if HitChance.Value < 100 and math.random(1, 100) > HitChance.Value then
		aimpos = aimpos + Vector3.new(math.random(-4, 4), math.random(-2, 2), math.random(-4, 4))
	end

	local velocity = part.AssemblyLinearVelocity
	rayParams.FilterDescendantsInstances = {gameCamera, entitylib.character and entitylib.character.Character or nil, target.Character}

	local calc = prediction.SolveTrajectory(
		origin, speed, gravity, aimpos, velocity,
		workspace.Gravity, target.HipHeight or 2, nil, rayParams, nil
	)
	if not calc then return nil end

	targetinfo.Targets[target] = tick() + 1
	local direction = calc - origin
	return direction.Magnitude > 0 and direction.Unit or nil
end

ProjectileAimbot = vain.Categories.Blatant:CreateModule({
	Name = 'ProjectileAimbot',
	Function = function(callback)
		if CircleObject then
			CircleObject.Visible = callback and ShowFOV.Enabled
		end

		if not callback then
			return
		end

		-- Installed once and left in: a passthrough while off, guarded by Enabled. Tearing
		-- a function hook out and in races with every shot that reads it.
		if not hooked then
			local c = tribes.resolveCombat()
			if not (c.Util and type(c.Util.AimDirection) == 'function') then
				notif('ProjectileAimbot', 'Combat system not found yet - try again in a match', 6, 'alert')
			else
				local real = c.Util.AimDirection
				c.Util.AimDirection = function(origin)
					local ok, dir = pcall(solve, origin)
					if ok and dir then
						return dir
					end
					return real(origin)
				end
				hooked = true
			end
		end

		-- The circle follows the cursor; targets are picked from inside it.
		ProjectileAimbot:Clean(runService.RenderStepped:Connect(function()
			if CircleObject then
				CircleObject.Position = mousePosition()
				CircleObject.Radius = FOV.Value
				CircleObject.Visible = ProjectileAimbot.Enabled and ShowFOV.Enabled
			end
		end))
	end,
	Tooltip = 'Silently curves your projectiles onto the enemy'
})
Targets = ProjectileAimbot:CreateTargets({
	Players = true,
	Walls = true,
	Tooltip = 'Which entities it may aim at'
})
TargetPart = ProjectileAimbot:CreateDropdown({
	Name = 'Part',
	Tooltip = 'Which body part to aim the shot at',
	List = {'RootPart', 'Head', 'Nearest'},
	Tooltips = {
		RootPart = 'Aims at the middle of the body',
		Head = 'Aims at the head',
		Nearest = 'Whichever part is closer to your cursor'
	}
})
FOV = ProjectileAimbot:CreateSlider({
	Name = 'FOV',
	Tooltip = 'How far from your cursor a target may be on screen',
	Min = 10,
	Max = 1000,
	Default = 400,
	Function = function(val)
		if CircleObject then
			CircleObject.Radius = val
		end
	end,
	Suffix = 'px'
})
Range = ProjectileAimbot:CreateSlider({
	Name = 'Range',
	Tooltip = 'How far a target may be, in studs',
	Min = 10,
	Max = 800,
	Default = 500,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
HitChance = ProjectileAimbot:CreateSlider({
	Name = 'Hit Chance',
	Tooltip = 'How often a shot is aimed at the target instead of beside it',
	Min = 0,
	Max = 100,
	Default = 100,
	Suffix = '%'
})
ShowFOV = ProjectileAimbot:CreateToggle({
	Name = 'Show FOV',
	Tooltip = 'Draws the circle targets are picked from',
	Function = function(callback)
		if FOVColor and FOVColor.Object then
			FOVColor.Object.Visible = callback
		end
		if CircleObject then
			CircleObject.Visible = callback and ProjectileAimbot.Enabled
		end
	end,
	Default = true
})
FOVColor = ProjectileAimbot:CreateColorSlider({
	Name = 'FOV Color',
	Tooltip = 'Colour of the circle',
	Function = function(hue, sat, val, opacity)
		if CircleObject then
			CircleObject.Color = Color3.fromHSV(hue, sat, val)
			CircleObject.Transparency = opacity
		end
	end,
	Darker = true
})

run(function()
	CircleObject = Drawing.new('Circle')
	CircleObject.Thickness = 2
	CircleObject.Filled = false
	CircleObject.Radius = FOV.Value
	CircleObject.Color = Color3.fromHSV(FOVColor.Hue, FOVColor.Sat, FOVColor.Value)
	CircleObject.Transparency = FOVColor.Opacity
	CircleObject.Visible = false

	vain:Clean(function()
		CircleObject:Remove()
	end)
end)
