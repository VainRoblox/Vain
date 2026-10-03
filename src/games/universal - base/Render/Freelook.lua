--[[
	Freelook.

	Look around without turning your character. Turning comes from the Humanoid's
	AutoRotate - it swings the body to face the camera - so that is switched off and the
	facing you had is held, and walking is redirected to follow your body rather than the
	camera (the ControlModule's move vector, taken relative to the held facing), so you
	keep running the way you were going while you look behind you.

	Hold keeps it on only while its keybind is down; Toggle flips it with each press. Snap
	Back turns the camera to face forward again when it ends.
]]
local Freelook
local Mode, SnapBack, KeepMovement
local facing, oldAutoRotate, controls

local function body()
	local character = lplr.Character
	return character and character:FindFirstChildOfClass('Humanoid'), character and character:FindFirstChild('HumanoidRootPart')
end

local function bindHeld()
	local bind = Freelook.Bind
	if type(bind) ~= 'table' or #bind == 0 then return false end
	for _, key in bind do
		local ok, down = pcall(function() return inputService:IsKeyDown(Enum.KeyCode[key]) end)
		if not (ok and down) then return false end
	end
	return true
end

Freelook = vain.Categories.Render:CreateModule({
	Name = 'Freelook',
	Function = function(callback)
		if callback then
			-- Hold lasts only while the key is down, so a click in the GUI or a profile that
			-- saved it on has nothing to hold.
			if Mode.Value == 'Hold' and not bindHeld() then
				task.defer(function()
					if Freelook.Enabled then Freelook:Toggle() end
				end)
				return
			end

			local humanoid, root = body()
			if not (humanoid and root) then
				task.defer(function()
					if Freelook.Enabled then Freelook:Toggle() end
				end)
				return
			end
			local look = root.CFrame.LookVector * Vector3.new(1, 0, 1)
			facing = CFrame.lookAt(Vector3.zero, look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, -1))
			oldAutoRotate = humanoid.AutoRotate
			humanoid.AutoRotate = false
			if not controls then
				pcall(function() controls = require(lplr.PlayerScripts.PlayerModule):GetControls() end)
			end

			-- Stepped runs after the ControlModule has moved you for the frame and before
			-- physics, so the move set here is the one that counts.
			Freelook:Clean(runService.Stepped:Connect(function()
				local hum, rootPart = body()
				if not (hum and rootPart and facing) then return end
				hum.AutoRotate = false
				if (rootPart.CFrame.LookVector - facing.LookVector).Magnitude > 0.01 then
					rootPart.CFrame = CFrame.new(rootPart.Position) * facing
				end
				if KeepMovement.Enabled and controls then
					local ok, move = pcall(controls.GetMoveVector, controls)
					if ok and move then
						hum:Move(facing:VectorToWorldSpace(move), false)
					end
				end
			end))

			if Mode.Value == 'Hold' then
				Freelook:Clean(inputService.InputEnded:Connect(function(input)
					if Freelook.Enabled and table.find(Freelook.Bind, input.KeyCode.Name) then
						Freelook:Toggle()
					end
				end))
			end
		else
			local humanoid = body()
			if humanoid then
				humanoid.AutoRotate = oldAutoRotate ~= false
			end
			if SnapBack.Enabled and facing then
				local camera = workspace.CurrentCamera
				local look = camera.CFrame.LookVector
				local forward = facing.LookVector * math.sqrt(math.max(1 - look.Y * look.Y, 0)) + Vector3.new(0, look.Y, 0)
				camera.CFrame = CFrame.lookAt(camera.CFrame.Position, camera.CFrame.Position + forward)
			end
			facing, oldAutoRotate = nil, nil
		end
	end,
	Tooltip = 'Look around without turning your character'
})
Mode = Freelook:CreateDropdown({
	Name = 'Mode',
	List = {'Hold', 'Toggle'},
	Tooltips = {
		Hold = 'On only while the keybind is held',
		Toggle = 'Each press of the keybind flips it'
	}
})
SnapBack = Freelook:CreateToggle({
	Name = 'Snap Back',
	Tooltip = 'Faces the camera forward again when it ends',
	Default = true
})
KeepMovement = Freelook:CreateToggle({
	Name = 'Keep Movement',
	Tooltip = 'Walks the way your body faces, not the camera',
	Default = true
})
