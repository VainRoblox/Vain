local old

vain.Categories.Combat:CreateModule({
	Name = 'NoClickDelay',
	Function = function(callback)
		if callback then
			old = bedwars.SwordController.isClickingTooFast
			bedwars.SwordController.isClickingTooFast = function(self)
				-- tick(), because that is what the game writes here and what everything
				-- reading it compares against. os.clock() counts from process start, so
				-- stamping it left lastSwing about 1.7 billion seconds in the past: every
				-- "did they swing recently" test then answered no forever, which switched
				-- off Click Aim in AimAssist and Legit Aura in Killaura for as long as
				-- this module was on.
				self.lastSwing = tick()
				return false
			end
		else
			bedwars.SwordController.isClickingTooFast = old
		end
	end,
	Tooltip = 'Remove the CPS cap'
})