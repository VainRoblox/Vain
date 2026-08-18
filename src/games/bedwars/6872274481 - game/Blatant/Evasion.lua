local Evasion
local Chance

run(function()
	local oldTakeDamage

	Evasion = vain.Categories.Blatant:CreateModule({
		Name = 'Evasion',
		Function = function(callback)
			if callback then
				if not entitylib.isAlive then return end

				local humanoid = entitylib.character.Humanoid
				if not humanoid then return end

				-- Hook Humanoid.TakeDamage to intercept all incoming damage. If a dodge roll
				-- succeeds, we call nothing and the damage is prevented. This works for melee,
				-- projectiles, fall damage, and any other source since they all go through
				-- TakeDamage eventually. The hook is recreated on respawn because run()
				-- re-executes this whole block when the character changes.
				oldTakeDamage = humanoid.TakeDamage
				humanoid.TakeDamage = function(self, damage)
					if math.random(1, 100) <= Chance.Value then
						-- Dodge roll succeeded - consume the damage without applying it.
						return
					end

					-- Roll failed - apply damage normally.
					return oldTakeDamage(self, damage)
				end
			end
		end,
		Tooltip = 'Dodge a percentage of incoming hits'
	})

	Chance = Evasion:CreateSlider({
		Name = 'Dodge Chance',
		Tooltip = 'Percentage of hits that are dodged',
		Min = 0,
		Max = 100,
		Default = 25,
		Suffix = function()
			return '%'
		end
	})
end)
