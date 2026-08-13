local AutoQueue

AutoQueue = vain.Categories.Utility:CreateModule({
	Name = 'AutoQueue',
	Function = function(callback)
		if callback then
			AutoQueue:Clean(vainEvents.MatchEnded.Event:Connect(function(_, obj)
				task.defer(function()
					firesignal(obj.Main.requeuebutton.Activated)
				end)
			end))
		end
	end,
	Tooltip = 'Automatically requeue after the match ends.'
})