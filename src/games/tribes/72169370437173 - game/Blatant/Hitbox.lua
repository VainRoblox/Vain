--[[
	Hitbox.

	Grows the hit part on enemy bodies and draws it as a box, so you can see exactly where it
	reaches. It helps the ranged weapons - bow, gun, thrown - which hit-test against the body
	a projectile passes through, so a bigger body is a bigger thing to hit. Melee does not
	gain from it: a swing picks targets by distance, not overlap, so Reach is what widens
	melee - this is its ranged counterpart.

	The root part is the one grown, never the head, so there is no giant head on screen - that
	was the head, which is drawn, being resized. The box itself is a separate adornment drawn
	on top, at the transparency you set, so it shows up reliably whatever the part behind it
	is doing, and it is torn down the instant the body dies, leaves range or the module goes
	off - as is the part's real size.
]]
local Hitbox
local Targets
local Size
local Show
local Visibility

-- part -> its real size, so it is restored to the stud. part -> adornment lives alongside.
local original = {}
local boxes = {}

local folder = Instance.new('Folder')
folder.Name = 'VainHitbox'
folder.Parent = vain.gui

local function drop(part)
	if original[part] then
		pcall(function() part.Size = original[part] end)
		original[part] = nil
	end
	if boxes[part] then
		pcall(function() boxes[part]:Destroy() end)
		boxes[part] = nil
	end
end

local function dropAll()
	for part in original do
		drop(part)
	end
	for part in boxes do
		drop(part)
	end
end

Hitbox = vain.Categories.Blatant:CreateModule({
	Name = 'Hitbox',
	Function = function(callback)
		if callback then
			Hitbox:Clean(runService.Heartbeat:Connect(function()
				local wanted = {}
				local size = Size.Value

				for _, entity in entitylib.List do
					local allow = entity.Targetable
						and (entity.Player and Targets.Players.Enabled or (entity.NPC and Targets.NPCs.Enabled))
					local part = allow and entity.RootPart
					if not part then continue end

					wanted[part] = true
					if not original[part] then
						original[part] = part.Size
					end
					part.Size = Vector3.new(size, size, size)

					-- The visible box: a separate adornment so it shows reliably, on top,
					-- at the transparency chosen, without touching how the part itself draws.
					if Show.Enabled then
						local box = boxes[part]
						if not box then
							box = Instance.new('BoxHandleAdornment')
							box.Adornee = part
							box.AlwaysOnTop = true
							box.ZIndex = 0
							box.Parent = folder
							boxes[part] = box
						end
						box.Size = Vector3.new(size, size, size)
						box.Color3 = Color3.fromRGB(255, 80, 80)
						box.Transparency = 1 - Visibility.Value
					elseif boxes[part] then
						pcall(function() boxes[part]:Destroy() end)
						boxes[part] = nil
					end
				end

				-- Anything touched last pass that is no longer a wanted enemy root is put
				-- back and its box removed at once.
				for part in original do
					if not wanted[part] then
						drop(part)
					end
				end
			end))

			Hitbox:Clean(dropAll)
		else
			dropAll()
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
	Tooltip = 'Draws the hitbox so you can see it',
	Function = function(callback)
		if Visibility and Visibility.Object then
			Visibility.Object.Visible = callback
		end
		if not callback then
			for part in boxes do
				pcall(function() boxes[part]:Destroy() end)
				boxes[part] = nil
			end
		end
	end,
	Default = true
})
Visibility = Hitbox:CreateSlider({
	Name = 'Visibility',
	Tooltip = 'How solid the shown hitbox is drawn',
	Min = 0,
	Max = 1,
	Default = 0.5,
	Decimal = 100,
	Darker = true
})
