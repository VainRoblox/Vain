local AutoSkillPoints
local Stat

-- Spends skill points as they are earned.
--
-- All three pieces are taken from the place dump rather than guessed: the points sit on
-- LocalPlayer.skillPoints, the remote is remotes.spendSkillPoint, and it takes the stat
-- name as its only argument - one of physicalPower, spellPower or stamina, which are the
-- only three the game ever sends.
local STATS = {
	['Physical Power'] = 'physicalPower',
	['Spell Power'] = 'spellPower',
	Stamina = 'stamina'
}

AutoSkillPoints = vain.Categories.Utility:CreateModule({
	Name = 'Auto Skill Points',
	Tooltip = 'Spends skill points into your chosen stat as soon as you earn them',
	Function = function(callback)
		if not callback then return end

		repeat
			pcall(function()
				local points = lplr:FindFirstChild('skillPoints')
				-- Nothing to spend, or the value is not there yet on a fresh join.
				if not (points and tonumber(points.Value) and points.Value > 0) then return end

				local spend = remote('spendSkillPoint')
				if not spend then return end

				-- One per pass rather than a loop draining them all at once: the value
				-- only drops when the server has actually applied the point, so spending
				-- against a stale count would fire more than were ever available.
				spend:FireServer(STATS[Stat.Value] or 'physicalPower')
			end)

			task.wait(0.5)
		until not AutoSkillPoints.Enabled
	end
})
Stat = AutoSkillPoints:CreateDropdown({
	Name = 'Stat',
	Tooltip = 'Which stat the points go into',
	List = {'Physical Power', 'Spell Power', 'Stamina'},
	Tooltips = {
		['Physical Power'] = 'Weapon damage',
		['Spell Power'] = 'Ability damage',
		Stamina = 'Health'
	}
})
