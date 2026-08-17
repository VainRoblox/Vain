--[[
	Vain - Bedwars dependency diagnostic.

	Run this in Bedwars with your executor. It probes every game internal that
	base.lua resolves, each one isolated, and reports exactly which paths the game
	has moved. Result is printed AND copied to your clipboard.

	This changes nothing in the game - it only reads.
]]

local replicatedStorage = game:GetService('ReplicatedStorage')
local lplr = game:GetService('Players').LocalPlayer
local out, pass, fail = {}, 0, 0

local function log(name, ok, detail)
	if ok then
		pass += 1
		table.insert(out, 'OK    ' .. name)
	else
		fail += 1
		table.insert(out, 'FAIL  ' .. name .. '  -> ' .. tostring(detail))
	end
end

-- Probe a resolution. Returns the value so later probes can chain off it.
local function probe(name, fn)
	local suc, res = pcall(fn)
	if not suc then
		log(name, false, res)
		return nil
	end
	if res == nil then
		log(name, false, 'resolved to nil')
		return nil
	end
	log(name, true)
	return res
end

table.insert(out, '=== Vain Bedwars diagnostic ===')
table.insert(out, 'PlaceId: ' .. tostring(game.PlaceId))

-- 1. Knit / Flamework - everything else hangs off these.
local Knit = probe('Knit (getupvalue setup,9)', function()
	return debug.getupvalue(require(lplr.PlayerScripts.TS.knit).setup, 9)
end)
local Flamework = probe('Flamework.core', function()
	return require(replicatedStorage['rbxts_include']['node_modules']['@flamework'].core.out).Flamework
end)

if Knit then
	probe('Knit.Start upvalue 1', function()
		return debug.getupvalue(Knit.Start, 1)
	end)
	probe('Knit.Controllers', function()
		return Knit.Controllers
	end)
	for _, name in {
		'ProjectileController', 'BlockBreakController', 'DamageIndicatorController',
		'NametagController', 'SprintController', 'SwordController', 'ViewmodelController',
		'SoundManager', 'FovController', 'BalloonController'
	} do
		probe('Knit.Controllers.' .. name, function()
			return Knit.Controllers[name]
		end)
	end
	-- Hardcoded upvalue indices - these shift whenever the game's own code changes.
	probe('BowConstantsTable (enableBeam upvalue 8)', function()
		return debug.getupvalue(Knit.Controllers.ProjectileController.enableBeam, 8)
	end)
	probe('FireProjectile (launchProjectileWithValues upvalue 2)', function()
		return debug.getupvalue(Knit.Controllers.ProjectileController.launchProjectileWithValues, 2)
	end)
	probe('BlockBreaker', function()
		return Knit.Controllers.BlockBreakController.blockBreaker
	end)
	probe('DamageIndicator', function()
		return Knit.Controllers.DamageIndicatorController.spawnDamageIndicator
	end)
end

if Flamework then
	for _, dep in {
		'@easy-games/game-core:client/controllers/ability/ability-controller@AbilityController',
		'client/controllers/game/kill-feed/kill-feed-controller@KillFeedController',
		'@easy-games/lobby:client/controllers/party-controller@PartyController'
	} do
		probe('Flamework: ' .. dep:sub(-40), function()
			return Flamework.resolveDependency(dep)
		end)
	end
end

-- 2. Plain require paths from base.lua's bedwars table.
probe('remotes.Client', function()
	return require(replicatedStorage.TS.remotes).default.Client
end)
probe('InventoryUtil', function()
	return require(replicatedStorage.TS.inventory['inventory-util']).InventoryUtil
end)
probe('ItemMeta (getItemMeta upvalue 1)', function()
	return debug.getupvalue(require(replicatedStorage.TS.item['item-meta']).getItemMeta, 1)
end)
probe('TeamUpgradeMeta (upvalue 6)', function()
	return debug.getupvalue(require(replicatedStorage.TS.games.bedwars['team-upgrade']['team-upgrade-meta']).getTeamUpgradeMetaForQueue, 6)
end)
probe('AnimationType', function()
	return require(replicatedStorage.TS.animation['animation-type']).AnimationType
end)
probe('GameAnimationUtil', function()
	return require(replicatedStorage.TS.animation['animation-util']).GameAnimationUtil
end)
probe('AnimationUtil (game-core)', function()
	return require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out['shared'].util['animation-util']).AnimationUtil
end)
probe('AppController', function()
	return require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out.client.controllers['app-controller']).AppController
end)
probe('BlockEngine (block-engine out)', function()
	return require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['block-engine'].out).BlockEngine
end)
probe('ClientBlockEngine', function()
	return require(lplr.PlayerScripts.TS.lib['block-engine']['client-block-engine']).ClientBlockEngine
end)
probe('BlockPlacer', function()
	return require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['block-engine'].out.client.placement['block-placer']).BlockPlacer
end)
probe('ClientDamageBlock', function()
	return require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['block-engine'].out.shared.remotes).BlockEngineRemotes.Client
end)
probe('CombatConstant', function()
	return require(replicatedStorage.TS.combat['combat-constant']).CombatConstant
end)
probe('KnockbackUtil', function()
	return require(replicatedStorage.TS.damage['knockback-util']).KnockbackUtil
end)
probe('ProjectileMeta', function()
	return require(replicatedStorage.TS.projectile['projectile-meta']).ProjectileMeta
end)
probe('QueryUtil', function()
	return require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).GameQueryUtil
end)
probe('BedwarsKitMeta', function()
	return require(replicatedStorage.TS.games.bedwars.kit['bedwars-kit-meta']).BedwarsKitMeta
end)
probe('MageKitUtil', function()
	return require(replicatedStorage.TS.games.bedwars.kit.kits.mage['mage-kit-util']).MageKitUtil
end)
probe('KillEffectMeta', function()
	return require(replicatedStorage.TS.locker['kill-effect']['kill-effect-meta']).KillEffectMeta
end)
probe('BedBreakEffectMeta', function()
	return require(replicatedStorage.TS.locker['bed-break-effect']['bed-break-effect-meta']).BedBreakEffectMeta
end)
probe('EmoteType', function()
	return require(replicatedStorage.TS.locker.emote['emote-type']).EmoteType
end)
probe('QueueMeta', function()
	return require(replicatedStorage.TS.game['queue-meta']).QueueMeta
end)
probe('QueueCard', function()
	return require(lplr.PlayerScripts.TS.controllers.global.queue.ui['queue-card']).QueueCard
end)
probe('HudAliveCount', function()
	return require(lplr.PlayerScripts.TS.controllers.global['top-bar'].ui.game['hud-alive-player-counts']).HudAlivePlayerCounts
end)
probe('ClickHold', function()
	return require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out.client.ui.lib.util['click-hold']).ClickHold
end)
probe('ClientConstructor (@rbxts/net)', function()
	return require(replicatedStorage['rbxts_include']['node_modules']['@rbxts'].net.out.client)
end)

table.insert(out, '')
table.insert(out, ('RESULT: %d ok, %d FAILED'):format(pass, fail))

local report = table.concat(out, '\n')
print(report)
if setclipboard then
	setclipboard(report)
	print('\n[copied to clipboard - paste it back to Claude]')
end
