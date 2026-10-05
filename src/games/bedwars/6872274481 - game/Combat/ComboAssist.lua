--[[
	Combo Assist.

	Keeps the crosshair on somebody you are already fighting, so the clicks you make land.
	It never swings for you and never decides who to fight: every attack is still yours,
	made at your own rate, and what this changes is only where you were pointing when you
	made it.

	That is the whole difference from Killaura. Killaura is obvious because it attacks -
	it picks targets, fires on its own schedule and connects from angles nobody could hold.
	A client that only ever moves the camera, slowly, toward a target already in front of
	it, is doing something a good player does.

	Why aiming is worth assisting at all: a melee hit is resolved from where the camera
	points, so a crosshair that stays on a target reaches further and connects more often
	than one that trails behind. During a combo the target is flying backwards under
	knockback, which is exactly when a crosshair trails - so this leads them by their own
	velocity rather than chasing the position they have already left.

	Two limits are what keep it looking like a hand rather than a script:

	    the cone      it never engages a target that is not already roughly in front of you,
	                  so it cannot swing the camera round behind you
	    the turn cap  corrections are limited to a degrees-per-second ceiling, so closing on
	                  a target takes time the way a wrist does, rather than snapping

	Not included, deliberately: a swing timing gate. The game already refuses a swing made
	before the sword has recharged - SwordController.isClickingTooFast is what NoClickDelay
	exists to stub out - so holding your clicks back would be enforcing a rule the server
	enforces anyway, for nothing.
]]
local ComboAssist
local Targets
local Window
local Lead
local Range
local AngleSlider
local MaxTurn
local Smoothness
local RequireMouse

-- How long after a swing you still count as mid fight. Long enough to cover the gap
-- between hits in a combo, short enough that walking away ends it.
local DEFAULT_WINDOW = 700

local function heldSword()
	local hand = store.hand
	return hand ~= nil and hand.toolType == 'sword'
end

--[[
	Whether you are in a fight right now, rather than merely near somebody.

	Either hand on the mouse or a swing in the last fraction of a second. Without this the
	camera would be quietly corrected every time an enemy wandered into the cone, including
	while you were building or running away, which is both useless and the kind of thing
	that looks wrong from the outside.
]]
local function fighting()
	if RequireMouse.Enabled and inputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
		return true
	end

	local last = bedwars.SwordController and bedwars.SwordController.lastSwing
	return last ~= nil and (tick() - last) <= (Window.Value / 1000)
end

-- The middle of them rather than the hips: RootPart on an R15 rig sits at the waist, so
-- aiming there points low and a hit that should have landed goes under them.
local function aimPart(ent)
	local char = ent.Character
	local torso = char and (char:FindFirstChild('UpperTorso') or char:FindFirstChild('Torso'))
	return torso or ent.RootPart
end

--[[
	Where they will be, not where they are.

	A target under knockback is moving away at speed, and a correction computed against
	their current position is already a round trip out of date by the time the server reads
	it. Leading by their own velocity is what keeps the crosshair on them through the part
	of a combo where it otherwise slides off.

	Zero lead is an honest setting, not a broken one: against someone standing still it is
	the same thing, and it is what to use if the lead ever overshoots.
]]
local function leadPosition(part)
	local lead = Lead.Value / 1000
	if lead <= 0 then
		return part.Position
	end
	return part.Position + part.AssemblyLinearVelocity * lead
end

local function pickTarget()
	return entitylib.EntityPosition({
		Range = Range.Value,
		Part = 'RootPart',
		Wallcheck = Targets.Walls.Enabled,
		Players = Targets.Players.Enabled,
		NPCs = Targets.NPCs.Enabled,
		Preference = Targets.Preference.Value
	})
end

ComboAssist = vain.Categories.Combat:CreateModule({
	Name = 'ComboAssist',
	Function = function(callback)
		if not callback then
			return
		end

		ComboAssist:Clean(runService.RenderStepped:Connect(function(dt)
			--[[
				Guarded whole, the way AimAssist is: this reads state that can vanish
				between frames - an entity dying mid-correction, the held item changing
				during a swing - and a throw in a render step is a console line every
				frame rather than once.
			]]
			pcall(function()
				if not entitylib.isAlive then return end
				if not heldSword() then return end
				if not fighting() then return end

				local ent = pickTarget()
				if not ent or not ent.RootPart then return end

				local part = aimPart(ent)
				if not part then return end

				local camera = gameCamera.CFrame
				local target = leadPosition(part)
				local delta = target - camera.Position
				if delta.Magnitude <= 0 then return end

				-- Outside the cone it does nothing at all. A target behind you is one you
				-- have not seen, and turning to face it is the single most obvious thing a
				-- client can do.
				local offBy = math.acos(math.clamp(camera.LookVector:Dot(delta.Unit), -1, 1))
				if offBy > math.rad(AngleSlider.Value / 2) then return end

				--[[
					The correction, capped twice.

					Smoothness decides what fraction of the remaining error to take this
					frame, which on its own still snaps when the error is large. The turn
					cap is the ceiling that makes it a wrist: a hard limit in degrees a
					second, applied after, so no single frame can move further than a hand
					could have.
				]]
				local step = offBy * math.clamp(dt * Smoothness.Value, 0, 1)
				local ceiling = math.rad(MaxTurn.Value) * dt
				if step > ceiling then
					step = ceiling
				end
				if step <= 0 then return end

				gameCamera.CFrame = camera:Lerp(
					CFrame.lookAt(camera.Position, target),
					math.clamp(step / offBy, 0, 1)
				)
			end)
		end))
	end,
	Tooltip = 'Helps your crosshair track who you are fighting'
})
Targets = ComboAssist:CreateTargets({
	Players = true,
	Walls = true,
	Tooltip = 'Which entities this may help you track'
})
RequireMouse = ComboAssist:CreateToggle({
	Name = 'Hold To Aim',
	Tooltip = 'Also assists while you hold left click',
	Default = true
})
Window = ComboAssist:CreateSlider({
	Name = 'Window',
	Tooltip = 'How long after a swing it keeps helping\nDefault is 700',
	Min = 100,
	Max = 2000,
	Default = DEFAULT_WINDOW,
	Suffix = 'ms'
})
Lead = ComboAssist:CreateSlider({
	Name = 'Lead',
	Tooltip = 'Aims ahead of a target being knocked back\nAbout your ping',
	Min = 0,
	Max = 300,
	Default = 80,
	Suffix = 'ms'
})
Range = ComboAssist:CreateSlider({
	Name = 'Range',
	Tooltip = 'How far a target can be\nDefault is 18',
	Min = 5,
	Max = 40,
	Default = 18,
	Decimal = 10,
	Suffix = 'studs'
})
AngleSlider = ComboAssist:CreateSlider({
	Name = 'Max Angle',
	Tooltip = 'Cone it will help inside\nWider is more obvious',
	Min = 10,
	Max = 180,
	Default = 70,
	Suffix = 'degrees'
})
MaxTurn = ComboAssist:CreateSlider({
	Name = 'Max Turn',
	Tooltip = 'Fastest it may move your camera\nDefault is 220',
	Min = 30,
	Max = 720,
	Default = 220,
	Suffix = 'deg/s'
})
Smoothness = ComboAssist:CreateSlider({
	Name = 'Smoothness',
	Tooltip = 'How hard it pulls toward the target\nLower is gentler',
	Min = 1,
	Max = 20,
	Default = 6,
	Decimal = 10
})
