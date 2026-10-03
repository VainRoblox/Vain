local Mode
local Expand
local Show
local ShowColor
local objects = {}
local Folder = Instance.new('Folder')
Folder.Parent = vain.gui
local regionBox
local oldRegion, regionHook

-- The box a player's own hitbox part starts from, before Expand grows it.
local BASE_SIZE = Vector3.new(3, 6, 3)
-- The game's default swing reach: 3.8 blocks of 3 studs.
local DEFAULT_REACH = 3.8 * 3

local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function showColor()
	local color = Color3.fromHSV(ShowColor and ShowColor.Hue or 0, ShowColor and ShowColor.Sat or 0.8, ShowColor and ShowColor.Value or 1)
	return color, ShowColor and ShowColor.Opacity or 0.35
end

-- Visible or not, an expanded part is the same part - only how it is drawn changes.
local function styleHitbox(part)
	if on(Show) then
		local color, opacity = showColor()
		part.Color = color
		part.Material = Enum.Material.SmoothPlastic
		part.Transparency = 1 - opacity
	else
		part.Transparency = 1
	end
end

local function createHitbox(ent)
	if ent.Targetable and ent.Player then
		local hitbox = Instance.new('Part')
		hitbox.Name = 'VainHitbox'
		hitbox.Size = BASE_SIZE + Vector3.one * (Expand.Value / 5)
		hitbox.Position = ent.RootPart.Position
		hitbox.CanCollide = false
		hitbox.CanTouch = false
		hitbox.CastShadow = false
		hitbox.Massless = true
		styleHitbox(hitbox)
		hitbox.Parent = ent.Character
		local weld = Instance.new('Motor6D')
		weld.Part0 = hitbox
		weld.Part1 = ent.RootPart
		weld.Parent = hitbox
		objects[ent] = hitbox
	end
end

local function removeHitbox(ent)
	if objects[ent] then
		objects[ent]:Destroy()
		objects[ent] = nil
	end
end

-- How far the held sword reaches, the way swingSwordInRegion works it out: its own
-- attackRange when it has one, the default otherwise - and never less than Expand.
local function swordReach()
	local tool = store.hand and store.hand.tool
	local meta = tool and bedwars.ItemMeta[tool.Name]
	local sword = meta and meta.sword
	if not sword then return nil end

	local reach = DEFAULT_REACH
	if type(sword.attackRange) == 'number' and sword.attackRange > 0 then
		reach = sword.attackRange
	end
	return math.max(reach, Expand.Value)
end

--[[
	The swing box, drawn where the game looks for targets.

	getTargetInRegion builds an axis-aligned box half the reach ahead of you, as wide and
	deep as the reach and twice your hip height (at least three studs) each way up and
	down. This draws that same box, so what you see is what a swing actually checks.
]]
local function drawRegion()
	if not regionBox then return end

	local reach = Mode.Value == 'Sword' and on(Show) and entitylib.isAlive and swordReach()
	if not reach then
		regionBox.Visible = false
		return
	end

	local root = entitylib.character.RootPart
	local hum = entitylib.character.Humanoid
	local height = math.max(3, hum and hum.HipHeight or 1.5)
	local center = root.Position + root.CFrame.LookVector.Unit * (reach / 2)
	local color, opacity = showColor()

	regionBox.CFrame = CFrame.new(center)
	regionBox.Size = Vector3.new(reach, height * 2, reach)
	regionBox.Color3 = color
	regionBox.Transparency = 1 - opacity
	regionBox.Visible = true
end

HitBoxes = vain.Categories.Blatant:CreateModule({
	Name = 'HitBoxes',
	Function = function(callback)
		if callback then
			if Mode.Value == 'Sword' then
				--[[
					The reach, raised where the swing asks for its targets.

					This used to change a number inside swingSwordInRegion by its position in
					the function's constants, which moved when the game was patched and was
					switched off. Every swing hands its reach to getTargetInRegion, so it is
					raised there instead - which also covers swords with their own
					attackRange, a case the constant never touched.
				]]
				local controller = bedwars.SwordController
				oldRegion = controller.getTargetInRegion
				regionHook = function(self, range, ...)
					if HitBoxes.Enabled and Mode.Value == 'Sword' and type(range) == 'number' then
						range = math.max(range, Expand.Value)
					end
					return oldRegion(self, range, ...)
				end
				controller.getTargetInRegion = regionHook

				regionBox = Instance.new('BoxHandleAdornment')
				regionBox.Name = 'SwingRegion'
				regionBox.Adornee = workspace.Terrain
				regionBox.AlwaysOnTop = false
				regionBox.ZIndex = 0
				regionBox.Visible = false
				regionBox.Parent = Folder
				HitBoxes:Clean(runService.RenderStepped:Connect(drawRegion))
			else
				HitBoxes:Clean(entitylib.Events.EntityAdded:Connect(createHitbox))
				-- EntityRemoved is the one entitylib fires; listening for EntityRemoving
				-- left every removed player's part behind.
				HitBoxes:Clean(entitylib.Events.EntityRemoved:Connect(removeHitbox))
				for _, ent in entitylib.List do
					createHitbox(ent)
				end
			end
		else
			-- Put back only while ours is the one installed, so a wrapper added after it
			-- keeps working.
			local controller = bedwars.SwordController
			if regionHook and controller and controller.getTargetInRegion == regionHook then
				controller.getTargetInRegion = oldRegion
			end
			regionHook = nil
			regionBox = nil
			Folder:ClearAllChildren()
			for _, part in objects do
				part:Destroy()
			end
			table.clear(objects)
		end
	end,
	Tooltip = 'Expands attack hitbox'
})
Mode = HitBoxes:CreateDropdown({
	Name = 'Mode',
	List = {'Sword', 'Player'},
	Function = function()
		if HitBoxes.Enabled then
			HitBoxes:Toggle()
			HitBoxes:Toggle()
		end
	end,
	Tooltip = 'Sword - Increases the range around you to hit entities\nPlayer - Increases the players hitbox'
})
Expand = HitBoxes:CreateSlider({
	Name = 'Expand amount',
	Tooltip = 'Sword - how far your swing reaches\nPlayer - how much bigger their hitbox gets',
	Min = 0,
	Max = 14.4,
	Default = 14.4,
	Decimal = 10,
	Function = function(val)
		if HitBoxes.Enabled and Mode.Value == 'Player' then
			for _, part in objects do
				part.Size = BASE_SIZE + Vector3.one * (val / 5)
			end
		end
	end,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
Show = HitBoxes:CreateToggle({
	Name = 'Show Hitboxes',
	Tooltip = 'Draws the hitboxes - your swing box in Sword, theirs in Player',
	Function = function(callback)
		if ShowColor and ShowColor.Object then ShowColor.Object.Visible = callback end
		for _, part in objects do
			styleHitbox(part)
		end
	end
})
ShowColor = HitBoxes:CreateColorSlider({
	Name = 'Hitbox Color',
	Tooltip = 'Colour of the drawn hitboxes',
	DefaultHue = 0,
	DefaultSat = 0.8,
	DefaultValue = 1,
	DefaultOpacity = 0.35,
	Darker = true,
	Visible = false,
	Function = function()
		for _, part in objects do
			styleHitbox(part)
		end
	end
})
