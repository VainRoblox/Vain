local Blink
local Type
local AutoSend
local AutoSendLength
local oldphys, oldsend

-- Roblox retires fast flags without warning and setfflag throws outright once the name
-- is gone, so every call goes through this. A missing flag becomes a no-op instead of an
-- error raised on the same line every frame.
local function trySetFFlag(flag, value)
	return setfflag ~= nil and (pcall(setfflag, flag, value))
end

Blink = vain.Categories.Utility:CreateModule({
	Name = 'Blink',
	Function = function(callback)
		if callback then
			local teleported
			Blink:Clean(lplr.OnTeleport:Connect(function()
				trySetFFlag('PhysicsSenderMaxBandwidthBps', '38760')
				trySetFFlag('DataSenderRate', '60')
				teleported = true
			end))

			repeat
				local physicsrate, senderrate = '0', Type.Value == 'All' and '-1' or '60'
				if AutoSend.Enabled and tick() % (AutoSendLength.Value + 0.1) > AutoSendLength.Value then
					physicsrate, senderrate = '38760', '60'
				end

				if physicsrate ~= oldphys or senderrate ~= oldsend then
					trySetFFlag('PhysicsSenderMaxBandwidthBps', physicsrate)
					trySetFFlag('DataSenderRate', senderrate)
					oldphys, oldsend = physicsrate, senderrate
				end

				task.wait(0.03)
			until (not Blink.Enabled and not teleported)
		else
			if setfflag then
				trySetFFlag('PhysicsSenderMaxBandwidthBps', '38760')
				trySetFFlag('DataSenderRate', '60')
			end
			oldphys, oldsend = nil, nil
		end
	end,
	Tooltip = 'Chokes packets until disabled.'
})
Type = Blink:CreateDropdown({
	Name = 'Type',
	List = {'Movement Only', 'All'},
	Tooltip = 'Movement Only - Only chokes movement packets\nAll - Chokes remotes & movement'
})
AutoSend = Blink:CreateToggle({
	Name = 'Auto send',
	Function = function(callback)
		AutoSendLength.Object.Visible = callback
	end,
	Tooltip = 'Automatically send packets in intervals'
})
AutoSendLength = Blink:CreateSlider({
	Name = 'Send threshold',
	Min = 0,
	Max = 1,
	Decimal = 100,
	Darker = true,
	Visible = false,
	Suffix = function(val)
		return val == 1 and 'second' or 'seconds'
	end
})