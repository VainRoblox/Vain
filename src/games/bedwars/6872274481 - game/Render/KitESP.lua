local KitESP = {Enabled = false}
local Notify
local Tracers
local Background
local Color
local Reference = {}
local Folder = Instance.new('Folder')
Folder.Parent = vain.gui

-- Settings are created after CreateModule returns, so they can still be nil while this
-- file is executing - and the module can be switched on inside that window when the GUI
-- restores a saved config. Reading .Enabled straight off them threw.
local function on(setting)
	return setting ~= nil and setting.Enabled
end

local function backgroundColor()
	return Color3.fromHSV(Color and Color.Hue or 0, Color and Color.Sat or 0, Color and Color.Value or 0)
end

--[[
	Beekeeper tags both the wild bees worth collecting and the tamed ones already swarming
	a placed hive with 'bee'. Both come from the same builder, but the tamed swarm is given
	a BeeId of -1 while a collectible carries a real, positive one from the server. Without
	this the hive you already own buries the map in icons.
]]
local function beeCollectibleOnly(v)
	local id = v:GetAttribute('BeeId')
	return not (type(id) == 'number' and id <= 0)
end

-- Wren's shadow coins carry no tag of their own: they are ordinary item drops, sharing
-- the ItemDrop tag with every other dropped thing on the map, so they go by name.
local function shadowCoinsOnly(v)
	return v.Name == 'shadow_coin'
end

--[[
	What each kit leaves lying about, keyed by the id the game uses rather than the name it
	shows - several were renamed and kept the old id, so Eldertree is still bigman.

	An entry is {source, icon, byName, filter}. Most collectibles carry a CollectionService
	tag, but some are plain Workspace models with a known name and no tag at all, which is
	what byName is for - that is why the stars and Grove's energy never appeared when they
	were looked up as tags.
]]
local ESPKits = {
	alchemist = {
		{'Thorns', 'thorns', true},
		{'Mushrooms', 'mushrooms', true},
		{'Flower', 'wild_flower', true},
		{'alchemist_ingedients', 'wild_flower'},
		{'alchemy_crystal', 'spirit'}
	},
	beekeeper = {
		{'bee', 'bee', false, beeCollectibleOnly}
	},
	-- Eldertree
	bigman = {
		{'treeOrb', 'natures_essence_1'}
	},
	-- Wren
	black_market_trader = {
		{'ItemDrop', 'shadow_coin', false, shadowCoinsOnly}
	},
	-- Gompy
	ghost_catcher = {
		{'ghost', 'ghost_orb'}
	},
	metal_detector = {
		{'hidden-metal', 'iron'}
	},
	-- Death Adder
	sorcerer = {
		{'alchemy_crystal', 'spirit'}
	},
	-- Grove
	spirit_gardener = {
		{'SpiritGardenerEnergy', 'spirit', true}
	},
	-- Star Collector Stella
	star_collector = {
		{'CritStar', 'crit_star', true},
		{'VitalityStar', 'vitality_star', true}
	}
}

--[[
	What to hang the icon on.

	Some of these are models and some are bare parts, so reaching for PrimaryPart alone
	came back with nothing for half of them - and nothing then became the key of the
	reference table, which is an error rather than a missing icon.
]]
local function adorneeOf(v)
	if typeof(v) ~= 'Instance' then return end
	if v:IsA('BasePart') then return v end
	return v:FindFirstChildWhichIsA('BasePart', true) or (v:IsA('Model') and v.PrimaryPart or nil)
end

--[[
	How far above the object's own middle to sit.

	This used to be a flat three studs, which is most of a player's height - so on a bee
	lying on the floor the icon floated well clear of it with nothing to say what it was
	pointing at. Measured from the thing itself instead, it rests on what it marks.
]]
local function iconHeight(v, adornee)
	local size
	if v:IsA('Model') then
		local ok, extents = pcall(v.GetExtentsSize, v)
		size = ok and extents or nil
	end
	size = size or adornee.Size
	return math.clamp(size.Y * 0.5, 0.5, 4)
end

local function espadd(v, adornee, icon)
	if not adornee or Reference[adornee] then return end

	local billboard = Instance.new('BillboardGui')
	billboard.Parent = Folder
	billboard.Name = icon
	billboard.StudsOffsetWorldSpace = Vector3.new(0, iconHeight(v, adornee), 0)
	billboard.Size = UDim2.fromOffset(36, 36)
	billboard.AlwaysOnTop = true
	billboard.ClipsDescendants = false
	billboard.Adornee = adornee
	local blur = addBlur(billboard)
	blur.Visible = on(Background)
	local image = Instance.new('ImageLabel')
	image.BorderSizePixel = 0
	image.Image = bedwars.getIcon({itemType = icon}, true)
	image.BackgroundColor3 = backgroundColor()
	image.BackgroundTransparency = 1 - (on(Background) and (Color and Color.Opacity or 0.5) or 0)
	image.Size = UDim2.fromOffset(36, 36)
	image.Position = UDim2.fromScale(0.5, 0.5)
	image.AnchorPoint = Vector2.new(0.5, 0.5)
	image.Parent = billboard
	local uicorner = Instance.new('UICorner')
	uicorner.CornerRadius = UDim.new(0, 4)
	uicorner.Parent = image
	Reference[adornee] = billboard
end

local function espremove(v)
	local adornee = adorneeOf(v)
	if adornee and Reference[adornee] then
		Reference[adornee]:Destroy()
		Reference[adornee] = nil
	end
end

local function addKit(source, icon, byName, filter)
	if byName then
		local function check(v)
			if v.Name == source and v:IsA('Model') then
				espadd(v, adorneeOf(v), icon)
			end
		end
		KitESP:Clean(workspace.ChildAdded:Connect(check))
		KitESP:Clean(workspace.ChildRemoved:Connect(function(v)
			pcall(espremove, v)
		end))
		for _, v in workspace:GetChildren() do
			check(v)
		end
		return
	end

	local function tryAdd(v)
		if filter and not filter(v) then return end
		espadd(v, adorneeOf(v), icon)
	end
	KitESP:Clean(collectionService:GetInstanceAddedSignal(source):Connect(tryAdd))
	KitESP:Clean(collectionService:GetInstanceRemovedSignal(source):Connect(espremove))
	for _, v in collectionService:GetTagged(source) do
		tryAdd(v)
	end
end

local TracerLines = {}
local TracerConn

local function clearTracers()
	for _, line in TracerLines do
		pcall(function() line:Remove() end)
	end
	table.clear(TracerLines)
end

local function updateTracers()
	if not on(Tracers) then return end

	local view = gameCamera.ViewportSize
	local originX, originY = view.X / 2, view.Y
	local color = backgroundColor()

	for part, line in TracerLines do
		if not Reference[part] or not part.Parent then
			pcall(function() line:Remove() end)
			TracerLines[part] = nil
		end
	end

	for part in Reference do
		if typeof(part) == 'Instance' and part:IsA('BasePart') then
			local point, visible = gameCamera:WorldToViewportPoint(part.Position)
			local line = TracerLines[part]
			if visible and point.Z > 0 then
				if not line then
					line = Drawing.new('Line')
					line.Thickness = 1
					TracerLines[part] = line
				end
				line.Color = color
				line.From = Vector2.new(originX, originY)
				line.To = Vector2.new(point.X, point.Y)
				line.Visible = true
			elseif line then
				line.Visible = false
			end
		end
	end
end

KitESP = vain.Categories.Render:CreateModule({
	Name = 'KitESP',
	Function = function(callback)
		if callback then
			Folder:ClearAllChildren()
			table.clear(Reference)

			if TracerConn then TracerConn:Disconnect() end
			TracerConn = runService.RenderStepped:Connect(updateTracers)

			--[[
				Polled rather than driven off a signal.

				The equipped kit is kept on the store, which is written from a subscription
				rather than from an attribute, so there is no event to hang this on that
				fires reliably. Watching the player's kit attribute meant that switching
				this on mid-match - with a kit already equipped, so nothing left to change -
				hooked nothing at all and stayed dead for the rest of the round.
			]]
			task.spawn(function()
				local current
				while KitESP.Enabled do
					local kit = store.equippedKit or ''
					if kit ~= current then
						Folder:ClearAllChildren()
						table.clear(Reference)
						clearTracers()

						local entries = kit ~= '' and ESPKits[kit]
						if entries then
							for _, entry in entries do
								addKit(entry[1], entry[2], entry[3], entry[4])
							end
							if on(Notify) then
								notif('KitESP', 'Tracking objects for ' .. kit, 4, 'check')
							end
						elseif kit ~= '' and on(Notify) then
							notif('KitESP', kit .. ' has nothing to track', 4, 'alert')
						end
						current = kit
					end
					task.wait(0.5)
				end

				Folder:ClearAllChildren()
				table.clear(Reference)
			end)
		else
			Folder:ClearAllChildren()
			table.clear(Reference)
			if TracerConn then
				TracerConn:Disconnect()
				TracerConn = nil
			end
			clearTracers()
		end
	end,
	Tooltip = 'ESP for the objects your equipped kit collects'
})
Notify = KitESP:CreateToggle({
	Name = 'Notify',
	Tooltip = 'Says which kit was picked up and whether it has anything to track'
})
Tracers = KitESP:CreateToggle({
	Name = 'Tracers',
	Tooltip = 'Draws a line from the bottom of the screen to each object',
	Function = function(callback)
		if not callback then clearTracers() end
	end
})
Background = KitESP:CreateToggle({
	Name = 'Background',
	Tooltip = 'Draws a background behind the icon',
	Function = function(callback)
		if Color and Color.Object then Color.Object.Visible = callback end
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
