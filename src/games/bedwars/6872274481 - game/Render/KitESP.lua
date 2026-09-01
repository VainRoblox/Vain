local KitESP
local Background
local Color = {}
local Reference = {}
local Folder = Instance.new('Folder')
Folder.Parent = vain.gui

local ESPKits = {
	alchemist = {'alchemist_ingedients', 'wild_flower'},
	beekeeper = {'bee', 'bee'},
	bigman = {'treeOrb', 'natures_essence_1'},
	ghost_catcher = {'ghost', 'ghost_orb'},
	metal_detector = {'hidden-metal', 'iron'},
	sheep_herder = {'SheepModel', 'purple_hay_bale'},
	sorcerer = {'alchemy_crystal', 'wild_flower'},
	star_collector = {'stars', 'crit_star'}
}

-- Settings are created after CreateModule returns, so they can still be nil while this
-- file is executing - and the module can be switched on inside that window when the GUI
-- restores a saved config. Reading .Enabled straight off them threw.
local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function backgroundColor()
	return Color3.fromHSV(Color.Hue or 0, Color.Sat or 0, Color.Value or 0)
end

--[[
	What to hang the icon on.

	Some of these tags are put on models and some straight onto parts, so reaching for
	PrimaryPart alone came back with nothing for half of them - and nothing then became
	the key of the reference table, which is an error rather than a missing icon. That is
	why the whole module fell over on the kits whose objects are bare parts.
]]
local function adorneeOf(v)
	if v:IsA('BasePart') then return v end
	if v:IsA('Model') then return v.PrimaryPart or v:FindFirstChildWhichIsA('BasePart', true) end
end

local function Added(v, icon)
	local adornee = adorneeOf(v)
	if not adornee or Reference[v] then return end

	local billboard = Instance.new('BillboardGui')
	billboard.Parent = Folder
	billboard.Name = icon
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
	billboard.Size = UDim2.fromOffset(36, 36)
	billboard.AlwaysOnTop = true
	billboard.ClipsDescendants = false
	billboard.Adornee = adornee
	local blur = addBlur(billboard)
	blur.Visible = on(Background)
	local image = Instance.new('ImageLabel')
	image.Size = UDim2.fromOffset(36, 36)
	image.Position = UDim2.fromScale(0.5, 0.5)
	image.AnchorPoint = Vector2.new(0.5, 0.5)
	image.BackgroundColor3 = backgroundColor()
	image.BackgroundTransparency = 1 - (on(Background) and (Color.Opacity or 0.5) or 0)
	image.BorderSizePixel = 0
	image.Image = bedwars.getIcon({itemType = icon}, true)
	image.Parent = billboard
	local uicorner = Instance.new('UICorner')
	uicorner.CornerRadius = UDim.new(0, 4)
	uicorner.Parent = image
	Reference[v] = billboard
end

local function Removed(v)
	local billboard = Reference[v]
	if billboard then
		Reference[v] = nil
		billboard:Destroy()
	end
end

-- Keyed by the tagged instance rather than by the part it was drawn on: a model being
-- taken apart loses its PrimaryPart before the tag goes, so looking the icon back up by
-- part left it on screen forever.
-- Held separately from the module's own cleanup so a kit change can drop just these,
-- rather than stacking a second kit's listeners on top of the first.
local Connections = {}

local function unhook()
	for _, conn in Connections do
		conn:Disconnect()
	end
	table.clear(Connections)
end

local function addKit(tag, icon)
	Connections[#Connections + 1] = collectionService:GetInstanceAddedSignal(tag):Connect(function(v)
		Added(v, icon)
	end)
	Connections[#Connections + 1] = collectionService:GetInstanceRemovedSignal(tag):Connect(Removed)
	for _, v in collectionService:GetTagged(tag) do
		Added(v, icon)
	end
end

KitESP = vain.Categories.Render:CreateModule({
	Name = 'KitESP',
	Function = function(callback)
		if callback then
			--[[
				Set up against whichever kit is equipped, and again if that changes.

				The old version waited once for a kit and then hooked whatever was
				equipped at that moment, so switching kits - or turning this on before
				picking one, in the lobby - left it watching nothing for the rest of the
				round with no way back short of a retoggle.
			]]
			local hooked
			local function follow()
				local kit = ESPKits[store.equippedKit]
				if hooked == store.equippedKit then return end
				hooked = store.equippedKit

				unhook()
				for v in Reference do
					Removed(v)
				end
				if kit then
					addKit(kit[1], kit[2])
				end
			end

			follow()
			KitESP:Clean(lplr:GetAttributeChangedSignal('PlayingAsKit'):Connect(function()
				if KitESP.Enabled then
					task.defer(follow)
				end
			end))
		else
			unhook()
			Folder:ClearAllChildren()
			table.clear(Reference)
		end
	end,
	Tooltip = 'ESP for certain kit related objects'
})
Background = KitESP:CreateToggle({
	Name = 'Background',
	Tooltip = 'Draws a background behind the text',
	Function = function(callback)
		if Color.Object then Color.Object.Visible = callback end
		for _, v in Reference do
			v.ImageLabel.BackgroundTransparency = 1 - (callback and (Color.Opacity or 0.5) or 0)
			v.Blur.Visible = callback
		end
	end,
	Default = true
})
Color = KitESP:CreateColorSlider({
	Name = 'Background Color',
	Tooltip = 'Color of the background',
	DefaultValue = 0,
	DefaultOpacity = 0.5,
	Function = function(hue, sat, val, opacity)
		for _, v in Reference do
			v.ImageLabel.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			v.ImageLabel.BackgroundTransparency = 1 - opacity
		end
	end,
	Darker = true
})