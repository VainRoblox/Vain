--[[
	Hitbox.

	Grows the hit part on enemy bodies so shots are easier to land. It helps the ranged
	weapons - bow, gun, thrown - because those hit-test against the body a projectile passes
	through, so a bigger body is a bigger thing to hit. Melee does not gain from it: a melee
	swing picks targets by distance, not by overlap, so Reach is what widens melee - this is
	its ranged counterpart.

	Only enemies are touched, through the same Targetable check the rest of the client uses,
	and every part is put back exactly as it was the moment the module goes off or the body
	leaves range, so nothing is left altered behind you.
]]
local Hitbox
local Targets
local Size

-- part -> its real size, so it can be restored to the stud for stud. Keyed by the part so
-- a respawned body with a fresh part is grown on its own terms.
local original = {}

local function restore(part)
	if part and original[part] then
		pcall(function()
			part.Size = original[part]
		end)
		original[part] = nil
	end
end

local function restoreAll()
	for part in original do
		restore(part)
	end
end

local function partsOf(entity)
	-- The root carries the body's position; the head is the other thing shots are aimed at.
	return {entity.RootPart, entity.Head}
end

Hitbox = vain.Categories.Blatant:CreateModule({
	Name = 'Hitbox',
	Function = function(callback)
		if callback then
			Hitbox:Clean(runService.Heartbeat:Connect(function()
				local wanted = {}

				for _, entity in entitylib.List do
					local allow = entity.Targetable
						and (entity.Player and Targets.Players.Enabled or (entity.NPC and Targets.NPCs.Enabled))
					if not allow then continue end

					for _, part in partsOf(entity) do
						if part then
							wanted[part] = true
							if not original[part] then
								original[part] = part.Size
							end
							local size = Size.Value
							part.Size = Vector3.new(size, size, size)
						end
					end
				end

				-- Anything grown last pass that is no longer a wanted enemy part - died,
				-- left range, changed team - is handed back its real size at once.
				for part in original do
					if not wanted[part] then
						restore(part)
					end
				end
			end))

			Hitbox:Clean(restoreAll)
		else
			restoreAll()
		end
	end,
	Tooltip = 'Grows enemy hitboxes so ranged shots land easier\nUse Reach for melee'
})
Targets = Hitbox:CreateTargets({
	Players = true,
	Tooltip = 'Whose hitboxes to grow'
})
Size = Hitbox:CreateSlider({
	Name = 'Size',
	Tooltip = 'How large to make each hit part',
	Min = 2,
	Max = 30,
	Default = 10,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
