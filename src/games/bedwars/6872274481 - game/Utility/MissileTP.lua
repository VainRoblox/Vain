local MissileTP

--[[
	Tells the server the missile is yours to steer, which is the step this was missing.

	The server only lets go of a guided projectile once it has been told the client has
	taken control - it is what the game sends the moment its own launch finishes. Without
	it the missile stays the server's, so every position written to it here was replicated
	straight back over and the missile carried on flying wherever it was already going.
]]
local function control(model, state)
	pcall(function()
		bedwars.Client:Get('GuidedProjectileClientControlStateChanged'):SendToServer({
			newState = state,
			model = model
		})
	end)
end

MissileTP = vain.Categories.Utility:CreateModule({
	Name = 'MissileTP',
	Function = function(callback)
		if not callback then return end
		MissileTP:Toggle()

		local plr = entitylib.EntityMouse({
			Range = 1000,
			Players = true,
			Part = 'RootPart'
		})

		if not getItem('guided_missile') then
			notif('MissileTP', 'No guided missile', 3)
			return
		end
		if not plr then
			notif('MissileTP', 'No player under your mouse', 3)
			return
		end

		local projectile = bedwars.RuntimeLib.await(bedwars.GuidedProjectileController.fireGuidedProjectile:CallServerAsync('guided_missile'))
		if not projectile then
			notif('MissileTP', 'Missile on cooldown.', 3)
			return
		end

		local projectilemodel = projectile.model
		if not projectilemodel.PrimaryPart then
			projectilemodel:GetPropertyChangedSignal('PrimaryPart'):Wait()
		end

		control(projectilemodel, true)

		local bodyforce = Instance.new('BodyForce')
		bodyforce.Force = Vector3.new(0, projectilemodel.PrimaryPart.AssemblyMass * workspace.Gravity, 0)
		bodyforce.Name = 'AntiGravity'
		bodyforce.Parent = projectilemodel.PrimaryPart

		repeat
			-- The target can die or leave while the missile is still in the air, which used
			-- to throw on a RootPart that was no longer there and strand the missile
			-- mid-flight with nothing releasing it.
			local root = plr.Character and plr.RootPart
			if not root or not root.Parent then break end

			projectilemodel:PivotTo(CFrame.lookAlong(root.CFrame.Position, gameCamera.CFrame.LookVector))
			task.wait(0.1)
		until not projectilemodel.Parent

		control(projectilemodel, false)
	end,
	Tooltip = 'Fires a guided missile and pins it to the player under your mouse'
})
