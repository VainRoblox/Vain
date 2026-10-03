local ChinaHat
local Material
local Color
local Height
local hat, weld

-- Sits on the top of the head: the head's own half height, plus the hat's half height so
-- its rim rests there, plus whatever Height adds.
local function hatCFrame(head)
	return head.CFrame * CFrame.new(0, head.Size.Y / 2 + (hat and hat.Size.Y / 2 or 0.35) - 0.25 + (Height and Height.Value or 0), 0)
end

local function attach(head)
	if weld then weld:Destroy() end
	hat.Parent = gameCamera
	hat.CFrame = hatCFrame(head)
	hat.AssemblyLinearVelocity = Vector3.zero
	weld = Instance.new('WeldConstraint')
	weld.Part0 = hat
	weld.Part1 = head
	weld.Parent = hat
end

ChinaHat = vain.Legit:CreateModule({
	Name = 'China Hat',
	Function = function(callback)
		if callback then
			if vain.ThreadFix then
				setthreadidentity(8)
			end

			hat = Instance.new('MeshPart')
			hat.Size = Vector3.new(3, 0.7, 3)
			hat.Name = 'ChinaHat'
			hat.Material = Enum.Material[Material.Value]
			hat.Color = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
			hat.CanCollide = false
			hat.CanQuery = false
			hat.Massless = true
			hat.MeshId = 'http://www.roblox.com/asset/?id=1778999'
			hat.Transparency = 1 - Color.Opacity
			hat.Parent = gameCamera
			if entitylib.isAlive then attach(entitylib.character.Head) end

			ChinaHat:Clean(hat)
			ChinaHat:Clean(entitylib.Events.LocalAdded:Connect(function(char)
				attach(char.Head)
			end))

			repeat
				hat.LocalTransparencyModifier = ((gameCamera.CFrame.Position - gameCamera.Focus.Position).Magnitude <= 0.6 and 1 or 0)
				task.wait()
			until not ChinaHat.Enabled
		else
			hat, weld = nil, nil
		end
	end,
	Tooltip = 'Puts a china hat on your character (ty mastadawn)'
})
local materials = {'ForceField'}
for _, v in Enum.Material:GetEnumItems() do
	if v.Name ~= 'ForceField' then
		table.insert(materials, v.Name)
	end
end
Material = ChinaHat:CreateDropdown({
	Name = 'Material',
	List = materials,
	Function = function(val)
		if hat then
			hat.Material = Enum.Material[val]
		end
	end
})
Color = ChinaHat:CreateColorSlider({
	Name = 'Hat Color',
	DefaultOpacity = 0.7,
	Function = function(hue, sat, val, opacity)
		if hat then
			hat.Color = Color3.fromHSV(hue, sat, val)
			hat.Transparency = 1 - opacity
		end
	end
})
Height = ChinaHat:CreateSlider({
	Name = 'Height',
	Tooltip = 'Moves the hat up or down',
	Min = -1,
	Max = 2,
	Default = 0,
	Decimal = 100,
	Function = function()
		if hat and entitylib.isAlive then attach(entitylib.character.Head) end
	end
})
