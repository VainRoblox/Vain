local Velocity
local Horizontal
local Vertical
local Chance
local TargetCheck
local rand, old = Random.new()

Velocity = vain.Categories.Combat:CreateModule({
	Name = 'Velocity',
	Function = function(callback)
		if callback then
			old = bedwars.KnockbackUtil.applyKnockback
			bedwars.KnockbackUtil.applyKnockback = function(root, mass, dir, knockback, ...)
				if rand:NextNumber(0, 100) > Chance.Value then return end
				local check = (not TargetCheck.Enabled) or entitylib.EntityPosition({
					Range = 50,
					Part = 'RootPart',
					Players = true
				})

				if check then
					knockback = knockback or {}
					if Horizontal.Value == 0 and Vertical.Value == 0 then return end
					knockback.horizontal = (knockback.horizontal or 1) * (Horizontal.Value / 100)
					knockback.vertical = (knockback.vertical or 1) * (Vertical.Value / 100)
				end
				
				return old(root, mass, dir, knockback, ...)
			end
		else
			bedwars.KnockbackUtil.applyKnockback = old
		end
	end,
	Tooltip = 'Changes how much knockback you take\nOver 100% throws you out of reach after a hit, which breaks combos'
})
Horizontal = Velocity:CreateSlider({
	Name = 'Horizontal',
	-- Above 100 the knockback is amplified rather than reduced, which is how this stops
	-- a combo: the first hit throws you out of sword reach, so the follow-ups have
	-- nothing to connect with. Unlike hiding your position this is movement the server
	-- applies itself, so there is nothing for it to reject or correct.
	Tooltip = 'How much horizontal knockback you take\nUnder 100 takes less, over 100 takes more - which throws you out of reach and breaks combos',
	Min = 0,
	Max = 400,
	Default = 0,
	Suffix = '%'
})
Vertical = Velocity:CreateSlider({
	Name = 'Vertical',
	Tooltip = 'How much vertical knockback you take\nUnder 100 takes less, over 100 takes more',
	Min = 0,
	Max = 400,
	Default = 0,
	Suffix = '%'
})
Chance = Velocity:CreateSlider({
	Name = 'Chance',
	Tooltip = 'Percent chance this happens',
	Min = 0,
	Max = 100,
	Default = 100,
	Suffix = '%'
})
TargetCheck = Velocity:CreateToggle({Name = 'Only when targeting', Tooltip = 'Only runs while you have a target'})