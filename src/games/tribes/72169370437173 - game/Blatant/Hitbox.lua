--[[
	Hitbox.

	Grows the hit part on enemy bodies so shots are easier to land. It helps the ranged
	weapons - bow, gun, thrown - because those hit-test against the body a projectile passes
	through, so a bigger body is a bigger thing to hit. Melee does not gain from it: a melee
	swing picks targets by distance, not by overlap, so Reach is what widens melee - this is
	its ranged counterpart.

	Only the root part is grown, never the head. The root is invisible, so the hit area gets
	bigger without a giant head filling your screen - that was the head part, which is drawn,
	being resized. Show Hitbox then makes the grown root faintly visible when you want to see
	where it reaches, at a transparency you set.

	Only enemies are touched, through the same Targetable check the rest of the client uses,
	and every part is put back to its own size and transparency the moment the module goes
	off or the body leaves range.
]]
local Hitbox
local Targets
local Size
local Show
local Visibility

-- part -> its real size and transparency, so both are restored exactly. Keyed by the part
-- so a respawned body with a fresh root is grown on its own terms.
local original = {}

local function restore(part)
	local saved = original[part]
	if part and saved then
		pcall(function()
			part.Size = saved.size
			part.Transparency = saved.transparency
		end)
		original[part] = nil
	end
end

local function restoreAll()
	for part in original do
		restore(part)
	end
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
					-- The root only: it is the invisible part shots hit, so growing it does
					-- not put a block on screen unless Show Hitbox asks for one.
					local part = allow and entity.RootPart
					if not part then continue end

					wanted[part] = true
					if not original[part] then
						original[part] = {size = part.Size, transparency = part.Transparency}
					end

					local size = Size.Value
					part.Size = Vector3.new(size, size, size)
					-- Shown faintly when asked, invisible otherwise - the root's own
					-- transparency is kept for when the module goes off.
					part.Transparency = Show.Enabled and (1 - Visibility.Value) or original[part].transparency
				end

				-- Anything grown last pass that is no longer a wanted enemy root - died,
				-- left range, changed team - is put back at once.
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
	Tooltip = 'How large to make the hit part',
	Min = 2,
	Max = 30,
	Default = 8,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
Show = Hitbox:CreateToggle({
	Name = 'Show Hitbox',
	Tooltip = 'Draws the grown hit part so you can see it',
	Function = function(callback)
		if Visibility and Visibility.Object then
			Visibility.Object.Visible = callback
		end
		-- Hidden again straight away when turned off, without waiting for the next pass.
		if not callback then
			for part, saved in original do
				pcall(function()
					part.Transparency = saved.transparency
				end)
			end
		end
	end
})
Visibility = Hitbox:CreateSlider({
	Name = 'Visibility',
	Tooltip = 'How solid the shown hitbox is drawn',
	Min = 0,
	Max = 1,
	Default = 0.5,
	Decimal = 100,
	Darker = true,
	Visible = false
})
