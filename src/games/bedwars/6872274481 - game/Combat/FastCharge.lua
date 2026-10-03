--[[
	Fast Charge.

	ProjectileAimbot's Instant Charge on its own, for when you would rather aim yourself.

	A charged weapon's strength comes from how long it has been drawn: the game takes the
	draw time against the projectile source's maxStrengthChargeSec and scales the launch
	from there into velocityMultiplier, which is what the launch reads. So both are raised to
	the share of a full charge you set whenever a launch is worked out - the shot leaves as
	strong as if you had held it that long, and the aim arc shows it too.
]]
local FastCharge
local ChargeSpeed
local old, hook

local function applyCharge(projmeta)
	if type(projmeta) ~= 'table' or projmeta.drawDurationSeconds == nil then return end

	local tool = store.hand and store.hand.tool
	local meta = tool and bedwars.ItemMeta[tool.Name]
	local source = meta and meta.projectileSource
	local maxcharge = source and source.maxStrengthChargeSec
	if not maxcharge then return end

	local wanted = maxcharge * (ChargeSpeed.Value / 100)
	if projmeta.drawDurationSeconds < wanted then
		projmeta.drawDurationSeconds = wanted
	end
	-- The same scale the game's charge loop uses; without it the launch keeps last frame's.
	local ratio = maxcharge > 0 and math.min(1, projmeta.drawDurationSeconds / maxcharge) or 1
	local multiplier = ratio + (1 - ratio) * (source.minStrengthScalar or 0.5)
	if (projmeta.velocityMultiplier or 0) < multiplier then
		projmeta.velocityMultiplier = multiplier
	end
end

FastCharge = vain.Categories.Combat:CreateModule({
	Name = 'FastCharge',
	Tooltip = 'Fully charges bows and crossbows straight away',
	Function = function(callback)
		local controller = bedwars.ProjectileController
		if callback then
			if not controller then return end
			--[[
				Wrapped on the controller, and safe to stack: ProjectileAimbot and the
				fishing rod wrap this same method, so each wrapper keeps the original it was
				built with, and putting it back is skipped if something wrapped after it.
			]]
			local original = controller.calculateImportantLaunchValues
			if type(original) ~= 'function' then return end
			old = original
			hook = function(self, projmeta, ...)
				if FastCharge.Enabled then
					pcall(applyCharge, projmeta)
				end
				return original(self, projmeta, ...)
			end
			controller.calculateImportantLaunchValues = hook
		else
			if hook and old and controller and controller.calculateImportantLaunchValues == hook then
				controller.calculateImportantLaunchValues = old
			end
			hook = nil
		end
	end
})
ChargeSpeed = FastCharge:CreateSlider({
	Name = 'Charge Speed',
	Tooltip = 'How much of a full draw is applied straight away',
	Min = 0,
	Max = 100,
	Default = 100,
	Suffix = function()
		return '%'
	end
})
