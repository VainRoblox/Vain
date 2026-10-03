--[[
	Dex Explorer, as a one-shot rather than a toggle.

	The GUI has no button-style modules, so this is a toggle that un-latches itself the
	moment it is pressed. Three rules keep it to one Dex, opened only by you:

	It never opens on its own. Restoring a config, loading a profile or anything else
	that switches modules on does so without you touching anything, and that is what was
	opening Dex out of nowhere - an old config with it recorded as on. So it only opens if
	a click, tap or key press happened a moment before; anything else is ignored.

	It never opens twice. The guard used to live in this file, so re-injecting Vain reset
	it and the next press opened a second Dex over the first. It is kept in the executor's
	globals now, which outlive a re-inject, along with the Dex window itself - so a second
	press is refused for as long as that window exists.

	Closing Dex is the one way to get it back: once its window is gone, the next press
	opens a fresh one.
]]
local DexExplorer
local genv = getgenv and getgenv() or shared
local lastInput = 0
local INTENT_WINDOW = 0.6

-- A press of any kind. A GUI click or a keybind both arrive this way; a config being
-- restored does not.
local function noteInput(input)
	local kind = input.UserInputType
	if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch
		or kind == Enum.UserInputType.Keyboard or kind == Enum.UserInputType.Gamepad1 then
		lastInput = os.clock()
	end
end
-- Cleaned up with Vain where the GUI supports it; every skin does not.
for _, signal in {inputService.InputBegan, inputService.InputEnded} do
	local connection = signal:Connect(noteInput)
	if vain.Clean then vain:Clean(connection) end
end

-- Dex's own window, found by the open button it always carries - wherever the executor
-- hid it.
local function findDexGui()
	local roots = {}
	if gethui then
		local ok, hidden = pcall(gethui)
		if ok and hidden then roots[#roots + 1] = hidden end
	end
	roots[#roots + 1] = game:GetService('CoreGui')

	for _, root in roots do
		local ok, found = pcall(function()
			for _, gui in root:GetChildren() do
				if gui:IsA('ScreenGui') then
					local button = gui:FindFirstChild('OpenButton', true)
					if button and button:IsA('TextButton') and (button.Text == 'Dex' or button.Text == 'X') then
						return gui
					end
				end
			end
		end)
		if ok and found then return found end
	end
end

-- Whether a Dex from this game session is still open.
local function dexOpen()
	local gui = genv.VainDexGui
	if typeof(gui) == 'Instance' then
		return gui.Parent ~= nil
	end
	if findDexGui() then return true end
	-- Opened, but its window was never found: it cannot be told apart from still being
	-- open, so it counts as open and stays to one.
	return genv.VainDexOpened == true
end

DexExplorer = vain.Categories.Utility:CreateModule({
	Name = 'Dex Explorer',
	Button = true,
	Function = function(callback)
		-- Only the switch-on edge matters where it renders as a toggle.
		if callback == false then return end

		if DexExplorer.Enabled and DexExplorer.Toggle then
			pcall(function() DexExplorer:Toggle() end)
		end

		-- Nobody pressed anything: a config or profile switching it on. Ignored.
		if os.clock() - lastInput > INTENT_WINDOW then return end

		if genv.VainDexStarting or dexOpen() then
			notif('Dex Explorer', 'Dex is already open', 4)
			return
		end

		genv.VainDexStarting = true
		local suc, err = pcall(function()
			return loadstring(game:HttpGet('https://raw.githubusercontent.com/infyiff/backup/main/dex.lua'))()
		end)
		genv.VainDexStarting = nil

		if not suc then
			notif('Dex Explorer', 'Failed to load: '..tostring(err), 6, 'alert')
			return
		end

		genv.VainDexOpened = true
		-- Its window is looked for once it has had a moment to build, so closing it can
		-- free the next press.
		task.spawn(function()
			for _ = 1, 20 do
				local gui = findDexGui()
				if gui then
					genv.VainDexGui = gui
					return
				end
				task.wait(0.25)
			end
		end)
	end,
	Tooltip = 'Opens the Dex explorer for browsing the game in its own window'
})
