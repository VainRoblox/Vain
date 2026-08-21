--[[
	Kit modules, ported from the older VainV6 client.

	They are registered under the Kit category rather than that client's 'Kits', and
	live in Utility/ because VainBundler walks a hardcoded folder list and skips
	anything outside it - the folder decides what gets bundled, the category a module
	appears under is the one it is created from.

	Each of these was written against an older build of the game. The shared plumbing
	they rely on - notif, getItem, collection, sortmethods, addBlur, hotbarSwitch,
	getPlacedBlock, switchItem, roundPos, targetinfo, prediction, vainEvents - all still
	exists and matches, and the store fields they read (KillauraTarget, equippedKit,
	hand, inventory, matchState, shop) are all still populated. Remotes they reach for
	by a plain name now resolve through the fallback added in base.lua.

	What is not verified is the per-kit controller APIs. A kit reworked, renamed or
	removed since will have a module here that quietly does nothing. Adetunde and Zephyr
	both turned out to be filed under internal names matching nothing you would guess
	from the kit's display name, so expect some of these to need the same treatment.
]]

run(function()
local AimAssist
	local Targets
	local Sort
	local AimSpeed
	local Smoothness
	local SmoothnessToggle
	local Distance
	local AngleSlider
	local KillauraTarget
	local ClickAim
	local ShopCheck
	local AimPart
	local ViewMode
	local PriorityMode
	local TargetPriority
	local ShakeToggle
	local ShakeAmount
	local WorkWithProjectiles
	local LimitToItem
	local MinDistance
	local HealthCheck
	local HealthThreshold

	local lockedTarget = nil
	local lastValidTarget = nil
	local lastValidTime = 0
	local GRACE_PERIOD = 0.15
	local rng = Random.new()
	local shakeTime = 0

	local function getSmoothedSpeed(speedVal, smoothVal, dt)
		local rawSpeed = 0.01 * (1.35 ^ speedVal)
		local smoothScale = math.max(1 - ((smoothVal - 1) / 9) * 0.88, 0.01)
		return math.min(rawSpeed * smoothScale, 0.95)
	end

	local function getClosestPartToCursor(character)
		local mousePos = inputService:GetMouseLocation()
		local mouseRay = gameCamera:ViewportPointToRay(mousePos.X, mousePos.Y, 0)
		local bestAngle = math.huge
		local bestPart = nil
		local partNames = {
			'Head', 'UpperTorso', 'LowerTorso', 'HumanoidRootPart',
			'LeftUpperArm', 'RightUpperArm', 'LeftLowerArm', 'RightLowerArm',
			'LeftUpperLeg', 'RightUpperLeg', 'LeftLowerLeg', 'RightLowerLeg',
			'LeftFoot', 'RightFoot', 'LeftHand', 'RightHand'
		}
		for _, partName in partNames do
			local part = character:FindFirstChild(partName)
			if part then
				local dirToPart = (part.Position - mouseRay.Origin).Unit
				local angle = math.acos(math.clamp(mouseRay.Direction:Dot(dirToPart), -1, 1))
				if angle < bestAngle then
					bestAngle = angle
					bestPart = part
				end
			end
		end
		return bestPart
	end

	local function isEntValid(ent)
		if not ent or not ent.RootPart or not ent.Character or not ent.Character.Parent then return false end
		if not entitylib.isAlive or not entitylib.character or not entitylib.character.RootPart then return false end
		local hum = ent.Character:FindFirstChildOfClass('Humanoid')
		if not hum or hum.Health <= 0 then return false end
		local dist = (ent.RootPart.Position - entitylib.character.RootPart.Position).Magnitude
		if dist > Distance.Value then return false end
		if not isEnemy(ent) then return false end
		return true
	end

	local function isInAngle(ent)
		if not ent or not ent.RootPart then return false end
		if not entitylib.character or not entitylib.character.RootPart then return false end
		local delta = (ent.RootPart.Position - entitylib.character.RootPart.Position)
		local localFacing = (ViewMode.Value == 'Third Person' and gameCamera.CFrame.LookVector or entitylib.character.RootPart.CFrame.LookVector) * Vector3.new(1, 0, 1)
		local flatDelta = delta * Vector3.new(1, 0, 1)
		if flatDelta.Magnitude <= 0.001 then return false end
		local angle = math.acos(math.clamp(localFacing:Dot(flatDelta.Unit), -1, 1))
		return angle < math.rad(AngleSlider.Value / 2)
	end

	-- ══════════════════════════════════════════════════════════════════
	--  SIGRID CHARGE  (restored into public Vain)
	-- ══════════════════════════════════════════════════════════════════
	run(function()
local vain = shared.vain
if not vain then return end
local bedwars = getgenv().bedwars
if not bedwars then return end -- BedWars only
if not (vain.Categories and vain.Categories.Kit) then return end -- some GUI skins don't have a Kits category
local playersService = (cloneref or function(x) return x end)(game:GetService('Players'))
local lplr = playersService.LocalPlayer

	-- ══════════════════════════════════════════════════════════════════════════
	--  SIGRID CHARGE  (Antler Uppercut -- press to fire the charge on a target)
	-- ══════════════════════════════════════════════════════════════════════════
	-- The Elk/Sigrid "Antler Uppercut" is server-driven but CLIENT-APPLIED: the
	-- server fires SigridBeginCharge{player=X} and X's own client pushes its root
	-- forward every Heartbeat. The charge is requested with the client-supplied
	-- target via bedwars.Client:Get('SigridBeginChargeRequest'):CallServer{player=X}.
	-- This is a BUTTON (press = one charge), it requires you to be mounted on your
	-- Elk first, targets the player you pick from the dropdown.
	do
		local SigridCharge, Target, Notify, AutoMount, SkipMount, WaitEnergy
		local function getRemote()
			local ok, r = pcall(function() return bedwars.Client:Get('SigridBeginChargeRequest') end)
			return ok and r or nil
		end
		-- The antler-uppercut charge is gated on the Elk's ENERGY: when it drops below a
		-- threshold the server disables the ability (ElkBelowChargeThreshold), so firing
		-- then gives a short, weak charge that "stops early". canUseAbility mirrors the
		-- game's own readiness check -> true only when energy is up and the charge is
		-- actually usable. We wait for it so every charge is a full one.
		local UPPERCUT_ABILITY = 'elk_antler_uppercut'
		local function chargeReady()
			local ok, ready = pcall(function()
				return bedwars.AbilityController:canUseAbility(UPPERCUT_ABILITY)
			end)
			return ok and ready == true
		end
		-- wait up to `timeout`s for the charge energy to be ready
		local function waitForEnergy(timeout)
			if chargeReady() then return true end
			local deadline = tick() + (timeout or 3)
			repeat task.wait(0.05) until chargeReady() or tick() > deadline
			return chargeReady()
		end
		-- mounted on the Elk? getActiveMounts() is keyed by player (place: line 451593)
		local function isMounted()
			local ok, mounts = pcall(function() return bedwars.MountController:getActiveMounts() end)
			return ok and mounts ~= nil and mounts[lplr] ~= nil
		end
		-- summon the Elk via the ELK_SUMMON ability ("elk_summon"), then wait up to
		-- ~1.5s for the mount to register. Returns true once mounted.
		local function ensureMounted()
			if isMounted() then return true end
			pcall(function()
				if bedwars.AbilityController:canUseAbility('elk_summon') then
					bedwars.AbilityController:useAbility('elk_summon')
				end
			end)
			local deadline = tick() + 1.5
			repeat task.wait(0.05) until isMounted() or tick() > deadline
			return isMounted()
		end
		local function resolveTarget()
			local name = Target and Target.Value
			if not name or name == 'None' then return nil end
			return playersService:FindFirstChild(name)
		end
		SigridCharge = vain.Categories.Kit:CreateModule({
			Name = 'Sigrid Charge',
			Tooltip = 'Fire the Elk/Sigrid Antler Uppercut charge at your Target. Must be mounted on your Elk first.',
			Function = function(callback)
				if not callback then return end
				-- act like a one-shot button: do the work, then toggle straight back off
				local function done() if SigridCharge.Enabled then SigridCharge:Toggle() end end
				-- Skip Mount Check: fire the request regardless of mount/character
				-- state (for spectator use / testing whether the server validates the
				-- requester). If it lands, the server only trusts the target field.
				if not (SkipMount and SkipMount.Enabled) and not isMounted() then
					if AutoMount and AutoMount.Enabled then
						if not ensureMounted() then
							vain:CreateNotification('Sigrid Charge', 'Could not mount the Elk (do you have the Sigrid kit?).', 5, 'warning')
							return done()
						end
					else
						vain:CreateNotification('Sigrid Charge', 'You must be mounted on your Elk first (or enable Auto Mount / Skip Mount Check).', 5, 'warning')
						return done()
					end
				end
				local remote = getRemote()
				if not remote then
					vain:CreateNotification('Sigrid Charge', 'Elk charge remote not found in this place.', 6, 'warning')
					return done()
				end
				local target = resolveTarget()
				if not target then
					vain:CreateNotification('Sigrid Charge', 'Pick a target player in the dropdown first.', 5, 'warning')
					return done()
				end
				-- Only fire when the charge energy is up, so it doesn't stop early. Skip
				-- this wait when Skip Mount Check is on (spectator/no-elk testing) since
				-- the ability state won't be meaningful there.
				if (not WaitEnergy or WaitEnergy.Enabled) and not (SkipMount and SkipMount.Enabled) then
					if not waitForEnergy(3) then
						vain:CreateNotification('Sigrid Charge', 'Charge energy not ready -- waiting timed out. Let the Elk recharge.', 5, 'warning')
						return done()
					end
				end
				pcall(function() remote:CallServer({ player = target }) end)
				if Notify and Notify.Enabled then
					vain:CreateNotification('Sigrid Charge', 'Charge fired on ' .. target.Name, 3)
				end
				done()
			end
		})
		Target = SigridCharge:CreateDropdown({ Name = 'Target', List = { 'None' }, Default = 'None',
			Function = function() end,
			Tooltip = 'Player to send the charge to (updates as players join/leave).' })
		WaitEnergy = SigridCharge:CreateToggle({ Name = 'Wait For Energy', Default = true,
			Tooltip = 'Only fire when Elk charge energy is up (waits up to 3s) so it\'s always a full charge, not a weak early one.' })
		AutoMount = SigridCharge:CreateToggle({ Name = 'Auto Mount', Default = false,
			Tooltip = 'If not on your Elk when you press, summon it first and wait for the mount before charging. Requires the Sigrid kit.' })
		SkipMount = SigridCharge:CreateToggle({ Name = 'Skip Mount Check', Default = false,
			Tooltip = 'Fire the charge even when not mounted (e.g. as a spectator). Only works if the server doesn\'t verify you\'re a mounted Sigrid.' })
		Notify = SigridCharge:CreateToggle({ Name = 'Notify', Default = true,
			Tooltip = 'Notify when a charge is fired.' })

		-- keep the Target dropdown in sync with the current players (excluding you)
		local function refreshTargets()
			if not Target then return end
			local names = {}
			for _, plr in playersService:GetPlayers() do
				if plr ~= lplr then table.insert(names, plr.Name) end
			end
			if #names == 0 then names = { 'None' } end
			if type(Target.Change) == 'function' then pcall(function() Target:Change(names) end) end
		end
		refreshTargets()
		vain:Clean(playersService.PlayerAdded:Connect(refreshTargets))
		vain:Clean(playersService.PlayerRemoving:Connect(function() task.defer(refreshTargets) end))
	end
	end)



	-- ══════════════════════════════════════════════════════════════════════════
	--  ADVANCED SPECTATE  (spectate anyone; optionally lock to one player)
	-- ══════════════════════════════════════════════════════════════════════════
	-- The game's SpectateController defaults to mode TEAM, which restricts the
	-- spectate cycle to your (or the reported ticket's) team. Its SpectateMode enum
	-- has ALL (0), TEAM (1), PLAYER (2). We simply force mode = ALL so the built-in
	-- getSpectateTargets returns EVERY in-game player (spectators aren't in-game, so
	-- they're naturally excluded). Fixed Spectate hooks getSpectateTargets to return
	-- only the chosen player, so the game's own auto-next-on-death can only ever
	-- land back on them.
	do
		local AdvancedSpectate, FixedSpectate, FixedPlayer, SpectateTeam
		local origGetTargets, spec
		-- maps the "Spectate Team" dropdown label -> team id (nil = All Teams)
		local teamLabelToId = {}

		local function getSpec()
			if spec then return spec end
			local ok, ctrl = pcall(function() return bedwars.SpectateController end)
			if ok and type(ctrl) == 'table' then spec = ctrl end
			return spec
		end

		-- resolve the currently-selected fixed player by name
		local function fixedPlr()
			local name = FixedPlayer and FixedPlayer.Value
			if not name or name == 'None' then return nil end
			return playersService:FindFirstChild(name)
		end

		-- OfflinePlayerUtil converts a live Player into the {userId=..} shape the
		-- store's spectatingPlayer field expects. Resolve it lazily/cached.
		local offlineUtil
		local function getOfflineUtil()
			if offlineUtil ~= nil then return offlineUtil or nil end
			local ok, mod = pcall(function()
				return require(replicatedStorage.TS.player['offline-player-util']).OfflinePlayerUtil
			end)
			offlineUtil = (ok and mod) or false
			return offlineUtil or nil
		end

		-- Snap the spectate camera straight onto `plr`. The game's
		-- switchSpectateTargets only understands "next"/"prev" (a Player arg is
		-- treated as "prev"), so we dispatch GameSetSpectator ourselves -- exactly
		-- what the server's SpectatePlayer remote does.
		local function snapTo(plr)
			if not plr then return false end
			local util = getOfflineUtil()
			local sp
			if util and util.getOfflinePlayer then
				local ok, res = pcall(function() return util.getOfflinePlayer(plr) end)
				if ok then sp = res end
			end
			if not sp then sp = { userId = plr.UserId } end
			return pcall(function()
				bedwars.Store:dispatch({
					type = 'GameSetSpectator',
					spectating = true,
					spectatingPlayer = sp,
				})
			end)
		end

		-- Un-fixate / leave the spectate view. Two cases:
		--  * live player -> stopSpectatingPlayer() returns your camera to your body.
		--  * genuine spectator (dead / lobby) the game refuses to release -> the
		--    camera stays glued to the locked player, so we advance to a DIFFERENT
		--    target so you're visibly un-pinned. Deferred one heartbeat so our
		--    spectatingPlayer=nil dispatch settles first (otherwise switchSpectateTargets
		--    re-reads 'current = locked player' and lands right back on them).
		-- Shared by BOTH the Fixed Spectate toggle-off AND the module toggle-off (the
		-- latter leaves FixedSpectate.Enabled true, so it can't gate on that).
		local function leaveSpectate(ctrl)
			if not ctrl then return end
			pcall(function() ctrl:stopSpectatingPlayer() end)
			task.defer(function()
				if lplr:GetAttribute('Spectator') == true then
					pcall(function()
						if ctrl.switchSpectateTargets then ctrl:switchSpectateTargets('next') end
					end)
				end
			end)
		end

		AdvancedSpectate = vain.Categories.Utility:CreateModule({
			Name = 'Better Spectating',
			Tooltip = 'Spectate anyone, not just your team (forces spectate to ALL). Enable Fixed Spectate + pick a player to lock the view.',
			Function = function(callback)
				local ctrl = getSpec()
				if callback then
					if not ctrl then
						notif('Better Spectating', 'Spectate controller not found in this place.', 6, 'warning')
						AdvancedSpectate:Toggle()
						return
					end
					-- force ALL mode so every in-game player is spectatable
					pcall(function()
						local ALL = ctrl.SpectateMode and ctrl.SpectateMode.ALL or 0
						if ctrl.setSpectateMode then ctrl:setSpectateMode(ALL) else ctrl.mode = ALL end
					end)
					-- keep it pinned to ALL (the game may reset mode on events) and
					-- apply the Fixed Spectate hook.
					if not origGetTargets and ctrl.getSpectateTargets then
						origGetTargets = ctrl.getSpectateTargets
						ctrl.getSpectateTargets = function(selfc, ...)
							if FixedSpectate and FixedSpectate.Enabled then
								local p = fixedPlr()
								if p then return { p } end -- only ever this player
							end
							local targets = origGetTargets(selfc, ...)
							-- "Spectate Team": if a specific team is chosen, keep only its
							-- players; "All Teams" (nil) leaves the full ALL list intact.
							local teamId = SpectateTeam and teamLabelToId[SpectateTeam.Value]
							if teamId ~= nil and type(targets) == 'table' then
								local filtered = {}
								for _, pl in targets do
									if pl:GetAttribute('Team') == teamId then
										filtered[#filtered + 1] = pl
									end
								end
								if #filtered > 0 then return filtered end
							end
							return targets
						end
					end
					-- if Fixed Spectate is already on, snap onto the fixed player now
					-- (so re-enabling the module re-fixates as expected).
					if FixedSpectate and FixedSpectate.Enabled then
						snapTo(fixedPlr())
					end
				else
					-- restore the original target resolver + let the game manage mode
					if origGetTargets and ctrl and ctrl.getSpectateTargets ~= origGetTargets then
						ctrl.getSpectateTargets = origGetTargets
					end
					origGetTargets = nil
					if ctrl then
						-- Un-fixate even if Fixed Spectate is still enabled (module off
						-- doesn't flip that sub-toggle). Same robust leave as the toggle.
						leaveSpectate(ctrl)
						pcall(function()
							local TEAM = ctrl.SpectateMode and ctrl.SpectateMode.TEAM or 1
							if ctrl.setSpectateMode then ctrl:setSpectateMode(TEAM) else ctrl.mode = TEAM end
						end)
					end
				end
			end
		})
		FixedSpectate = AdvancedSpectate:CreateToggle({
			Name = 'Fixed Spectate',
			Tooltip = 'Lock spectating to the selected player. If they die, this snaps the view straight back to them.',
			Default = false,
			Function = function(callback)
				local ctrl = getSpec()
				if callback then
					-- ON: snap onto the fixed player (only if the module is enabled)
					if AdvancedSpectate.Enabled then
						snapTo(fixedPlr())
					end
				else
					-- OFF: un-fixate. The getSpectateTargets hook now falls through to
					-- everyone (FixedSpectate.Enabled is false). Two cases:
					--  * you're a live player -> stopSpectatingPlayer() returns your
					--    camera to your own body (that's the whole un-fixate).
					--  * you're a genuine spectator (dead / lobby) -> the game won't let
					--    you leave spectate, so instead of stopping we clear the lock and
					--    advance to a DIFFERENT player so you're no longer pinned. We do
					--    the advance on the next heartbeat so the spectatingPlayer=nil
					--    dispatch settles first (otherwise switchSpectateTargets re-reads
					--    the stale 'current = fixed player' state and lands right back).
					leaveSpectate(ctrl)
				end
			end
		})
		FixedPlayer = AdvancedSpectate:CreateDropdown({
			Name = 'Fixed Player',
			List = { 'None' },
			Default = 'None',
			Tooltip = 'Which player to lock onto when Fixed Spectate is on.',
			Function = function()
				-- snap onto the newly-picked player right away
				if AdvancedSpectate.Enabled and FixedSpectate and FixedSpectate.Enabled then
					snapTo(fixedPlr())
				end
			end
		})
		SpectateTeam = AdvancedSpectate:CreateDropdown({
			Name = 'Spectate Team',
			List = { 'All Teams' },
			Default = 'All Teams',
			Tooltip = 'Spectate every team ("All Teams") or lock the cycle to one team. Ignored while Fixed Spectate is on.',
			Function = function()
				-- advance to a valid target within the newly-chosen team right away
				local ctrl = getSpec()
				if AdvancedSpectate.Enabled and ctrl and not (FixedSpectate and FixedSpectate.Enabled) then
					pcall(function()
						if ctrl.switchSpectateTargets then ctrl:switchSpectateTargets('next') end
					end)
				end
			end
		})

		-- keep the Fixed Player + Spectate Team dropdowns in sync with the server
		local function refreshList()
			local names = { 'None' }
			for _, plr in playersService:GetPlayers() do
				if plr ~= lplr then names[#names + 1] = plr.Name end
			end
			pcall(function() FixedPlayer:Change(names) end)

			-- rebuild the team list from the store (label -> id map for filtering)
			local teamNames = { 'All Teams' }
			teamLabelToId = {}
			pcall(function()
				local teams = bedwars.Store:getState().Game.teams
				if type(teams) == 'table' then
					local list = {}
					for _, t in teams do list[#list + 1] = t end
					table.sort(list, function(a, b) return tostring(a.id) < tostring(b.id) end)
					for _, t in list do
						local label = (t.name and tostring(t.name)) or ('Team ' .. tostring(t.id))
						-- avoid a label clashing with 'All Teams' or duplicates
						if label ~= 'All Teams' and not teamLabelToId[label] then
							teamNames[#teamNames + 1] = label
							teamLabelToId[label] = t.id
						end
					end
				end
			end)
			pcall(function() SpectateTeam:Change(teamNames) end)
		end
		refreshList()
		vain:Clean(playersService.PlayerAdded:Connect(refreshList))
		vain:Clean(playersService.PlayerRemoving:Connect(function() task.defer(refreshList) end))
	end


	-- ══════════════════════════════════════════════════════════════════════════
	--  TABLIST WINSTREAK  (show each player's winstreak next to their tab-list name)
	-- ══════════════════════════════════════════════════════════════════════════
	-- BedWars uses a custom tab-list (the default PlayerList is disabled) and a
	-- player's winstreak isn't replicated. NametagController:requestNametagData(plr)
	-- returns any player's { winstreak, rankDivision }, so we fetch it once per
	-- player (staggered + cached) and paint it onto the matching name label in the
	-- tab-list, re-applying on a loop since the tab-list is Roact and re-renders.
	do
		local TablistWinstreak
		local Global
		local ShowStreak, ShowWinrate, ShowMatches, ShowKD, ShowBeds
		local fetched = {}    -- userId -> true once fetched (dedupe)
		local fetching = {}   -- userId -> true while a request is in flight
		local statData = {}   -- lowercased name -> { ws, winrate, matches, kd, beds } (persists after they leave)

		-- Build the display string from raw stats, honoring the per-stat toggles.
		-- Kept separate from the fetch so toggling a stat off/on repaints instantly
		-- without re-requesting the (cached) profile.
		local function buildLabel(d)
			if not d then return nil end
			local parts = {}
			if (not ShowStreak or ShowStreak.Enabled) and d.ws and d.ws > 0 then
				parts[#parts + 1] = '\u{1F525} ' .. tostring(d.ws)
			end
			if (not ShowWinrate or ShowWinrate.Enabled) and d.winrate then
				parts[#parts + 1] = ('\u{1F3C6} %d%%'):format(d.winrate)
			end
			if (not ShowMatches or ShowMatches.Enabled) and d.matches and d.matches > 0 then
				parts[#parts + 1] = ('\u{1F3AE} %d'):format(d.matches)
			end
			if (not ShowKD or ShowKD.Enabled) and d.kd then
				parts[#parts + 1] = ('\u{2694} %.2f'):format(d.kd)
			end
			if (not ShowBeds or ShowBeds.Enabled) and d.beds then
				parts[#parts + 1] = ('\u{1F6CF} %.2f'):format(d.beds)
			end
			if #parts > 0 then return table.concat(parts, '  ') end
			return nil
		end

		local function displayNameOf(plr)
			local ok, dn = pcall(function() return bedwars.GamePlayer.getGamePlayer(plr):getDisplayName() end)
			if ok and type(dn) == 'string' and dn ~= '' then return dn end
			return (plr.DisplayName ~= '' and plr.DisplayName) or plr.Name
		end

		local function fetchWinstreak(plr)
			local uid = plr.UserId
			if fetched[uid] or fetching[uid] then return end
			fetching[uid] = true
			local dn, nm = displayNameOf(plr):lower(), plr.Name:lower()
			task.spawn(function()
				local data
				-- Full profile -> per-CURRENT-gamemode stats (winstreak, winrate, K/D).
				-- Privacy-gated: private/friends-only users reject it; we suppress the
				-- resulting notification (see installNotifFilter) and fall back below.
				local ok, profile = pcall(function()
					return bedwars.Client:Get('RequestProfileData'):CallServerAsync(plr):expect()
				end)
				-- Extract RAW stats defensively (profile.queues can be proxy/userdata, and a
				-- bad field read would kill this thread). We store numbers, not a string, so
				-- the per-stat toggles can rebuild the label at paint time.
				pcall(function()
					if not (ok and profile and profile.queues) then return end
					local ws, wins, losses, matches, kills, deaths, beds
					if Global and Global.Enabled then
						-- GLOBAL: sum every queue's totals + highest win streak of any mode.
						wins, losses, matches, kills, deaths, beds = 0, 0, 0, 0, 0, 0
						local best = 0
						for _, v in pairs(profile.queues) do
							if type(v) == 'table' then
								wins    = wins    + (tonumber(v.wins) or 0)
								losses  = losses  + (tonumber(v.losses) or 0)
								matches = matches + (tonumber(v.matches) or 0)
								kills   = kills   + (tonumber(v.kills) or 0)
								deaths  = deaths  + (tonumber(v.deaths) or 0)
								best    = math.max(best, tonumber(v.highestWinStreak) or 0)
								beds    = beds    + (tonumber(v.bedBreaks) or 0)
							end
						end
						ws = best
						if matches <= 0 then matches = wins + losses end
					else
						-- CURRENT gamemode only.
						local qt = bedwars.Store:getState().Game.queueType
						local q = qt and profile.queues[qt]
						if not q then return end
						ws      = tonumber(q.currentWinStreak) or 0
						wins    = tonumber(q.wins) or 0
						losses  = tonumber(q.losses) or 0
						matches = tonumber(q.matches) or 0
						kills   = tonumber(q.kills) or 0
						deaths  = tonumber(q.deaths) or 0
						beds    = tonumber(q.bedBreaks) or 0
						if matches <= 0 then matches = wins + losses end
					end
					data = {
						ws      = ws,
						winrate = matches > 0 and math.floor(wins / matches * 100 + 0.5) or nil,
						matches = matches,
						kd      = (kills > 0 or deaths > 0) and (deaths > 0 and (kills / deaths) or kills) or nil,
						beds    = (matches > 0 and beds > 0) and (beds / matches) or nil,
					}
				end)
				-- private/friends-only profiles reject RequestProfileData -> data stays
				-- nil and nothing is shown for them (no global-streak fallback).
				fetched[uid] = true
				fetching[uid] = nil
				-- key by name so it still matches the row after the player leaves
				if data then statData[dn] = data; statData[nm] = data end
			end)
		end

		local function stripTags(s)
			return (s:gsub('<[^>]->', ''))
		end

		-- normalise a label's text for matching: drop rich-text tags, a leading
		-- "[..]" (level/kill) tag, and surrounding whitespace.
		local function clean(s)
			s = stripTags(s)
			s = s:gsub('^%s*%b[]%s*', '')
			s = s:gsub('^%s+', ''):gsub('%s+$', '')
			return s:lower()
		end

		local function paint()
			-- fetch everyone at once (each request is cached, so a player is only
			-- ever requested a single time -> the private-profile notif, which we
			-- also suppress, can fire at most once and we batch them away instantly)
			for _, plr in playersService:GetPlayers() do
				fetchWinstreak(plr)
			end
			if not next(statData) then return end

			-- Only paint the ALLOWED containers: the tab-list LEADERBOARD and the
			-- SPECTATE selector nametag. Matching player names anywhere in PlayerGui
			-- also caught the kill feed, target list, etc. -- so require the label to
			-- live inside one of those named ancestors. (The Preparation Preview UI
			-- renders its own stats separately and isn't scraped here.)
			local pg = lplr:FindFirstChild('PlayerGui')
			if not pg then return end
			local function isAllowedContainer(gui)
				local a = gui
				while a and a ~= pg do
					local n = a.Name:lower()
					if n:find('leaderboard') or n:find('tablist')
						or (n:find('tab') and n:find('list'))
						or n:find('spectat') then
						return true
					end
					a = a.Parent
				end
				return false
			end
			for _, gui in pg:GetDescendants() do
				if gui:IsA('TextLabel') and isAllowedContainer(gui) then
					-- Match on the ORIGINAL name, not the current text: once painted,
					-- gui.Text contains the visible stat glyphs (🔥 61% ...) which
					-- stripTags can't remove, so cleaning the live text no longer matches
					-- the player -> the row would flip painted/restored every second.
					local orig = gui:GetAttribute('VainWSOrig')
					-- If Roact recycled this label to a different player it resets .Text
					-- but keeps our attribute -> a stale orig. Detect that (current text no
					-- longer begins with orig) and drop it so we re-key off the fresh name.
					if orig and gui.Text:sub(1, #orig) ~= orig then
						orig = nil
						gui:SetAttribute('VainWSOrig', nil)
						gui:SetAttribute('VainWS', nil)
					end
					local key = clean(orig or gui.Text)
					local label = buildLabel(statData[key])
					local painted = gui:GetAttribute('VainWS')
					if label then
						-- Remember the untouched text once so we always rebuild FROM the
						-- original. Rebuilding every pass (instead of skip-if-painted) lets
						-- the per-stat toggles take effect without a Roact re-render.
						if not orig then
							orig = gui.Text
							gui:SetAttribute('VainWSOrig', orig)
						end
						local want = orig .. "  <font color='#FFD24D'>" .. label .. "</font>"
						if gui.Text ~= want then
							gui:SetAttribute('VainWS', true)
							gui.RichText = true
							gui.Text = want
						end
					elseif painted then
						-- All of this row's stats got toggled off -> restore the original.
						if type(orig) == 'string' then gui.Text = orig end
						gui:SetAttribute('VainWSOrig', nil)
						gui:SetAttribute('VainWS', nil)
					end
				end
			end
		end

		-- Drop the "profile visibility set to Private/Friends Only" spam that
		-- RequestProfileData triggers for private players. All notifications go
		-- through NotificationController.sendNotification, so we wrap it and drop
		-- any whose payload mentions "visibility", restoring it when disabled.
		local notifCtrl, origSendNotif
		local function installNotifFilter()
			if origSendNotif then return end
			local ok, ctrl = pcall(function()
				return Flamework.resolveDependency('@easy-games/game-core:client/controllers/notification-controller@NotificationController')
			end)
			if not ok or not ctrl or type(ctrl.sendNotification) ~= 'function' then return end
			notifCtrl, origSendNotif = ctrl, ctrl.sendNotification
			ctrl.sendNotification = function(selfc, payload, ...)
				if type(payload) == 'table' then
					for _, v in pairs(payload) do
						if type(v) == 'string' and v:lower():find('visibility') then return end
					end
				end
				return origSendNotif(selfc, payload, ...)
			end
		end
		local function removeNotifFilter()
			if notifCtrl and origSendNotif and notifCtrl.sendNotification ~= origSendNotif then
				notifCtrl.sendNotification = origSendNotif
			end
			origSendNotif = nil
		end

		TablistWinstreak = vain.Categories.Render:CreateModule({
			Name = 'Show Advanced Stats',
			Tooltip = "Shows each player's current-mode winstreak, winrate, K/D and matches by their name in the tab-list. Private profiles show nothing.",
			Function = function(callback)
				if callback then
					table.clear(fetched)
					table.clear(fetching)
					table.clear(statData)
					installNotifFilter()
					task.spawn(function()
						repeat
							pcall(paint)
							task.wait(1)
						until not TablistWinstreak.Enabled
						removeNotifFilter()
					end)
				end
			end
		})
		Global = TablistWinstreak:CreateToggle({
			Name = 'Global Stats',
			Tooltip = 'Show global stats across all gamemodes (highest streak, total winrate/K-D) instead of just the current mode.',
			Default = false,
			Function = function()
				-- Global vs current-mode changes the RAW numbers, so wipe the fetch
				-- cache + our painted tags; the paint loop rebuilds from fresh data.
				table.clear(fetched)
				table.clear(fetching)
				table.clear(statData)
				local pg = lplr:FindFirstChild('PlayerGui')
				if pg then
					for _, g in pg:GetDescendants() do
						if g:IsA('TextLabel') and g:GetAttribute('VainWS') then
							local orig = g:GetAttribute('VainWSOrig')
							if type(orig) == 'string' then g.Text = orig end
							g:SetAttribute('VainWSOrig', nil)
							g:SetAttribute('VainWS', nil)
						end
					end
				end
			end
		})
		-- Per-stat visibility toggles. These only affect the DISPLAY (buildLabel),
		-- so no cache wipe is needed -- the 1s paint loop repaints from cached raw
		-- numbers and rebuilds each label from its original text.
		ShowStreak = TablistWinstreak:CreateToggle({
			Name = 'Show Win Streak', Default = true,
			Tooltip = 'Show the \u{1F525} win streak stat.', Function = function() end,
		})
		ShowWinrate = TablistWinstreak:CreateToggle({
			Name = 'Show Winrate', Default = true,
			Tooltip = 'Show the \u{1F3C6} winrate stat.', Function = function() end,
		})
		ShowMatches = TablistWinstreak:CreateToggle({
			Name = 'Show Matches', Default = true,
			Tooltip = 'Show the \u{1F3AE} total matches stat.', Function = function() end,
		})
		ShowKD = TablistWinstreak:CreateToggle({
			Name = 'Show K/D', Default = true,
			Tooltip = 'Show the \u{2694} kill/death ratio stat.', Function = function() end,
		})
		ShowBeds = TablistWinstreak:CreateToggle({
			Name = 'Show Bed Breaks', Default = true,
			Tooltip = 'Show the \u{1F6CF} average beds broken per match stat.', Function = function() end,
		})
	end

	-- ══════════════════════════════════════════════════════════════════════════
	--  PARTY LIST  (show real party groupings -- tab-list tags and/or an overlay)
	-- ══════════════════════════════════════════════════════════════════════════
	-- Groupings come ONLY from MatchController.parties -- the real "who queued
	-- together" party list. Deliberately does NOT fall back to BedWars' colour
	-- teams: a team is just whoever the matchmaker put together, not a party, so
	-- treating it as one would tag total strangers as "grouped". The server only
	-- replicates real party data (MatchPartiesUpdate) for some queues, so this can
	-- legitimately show 0 groups in a queue that doesn't send it -- that's the
	-- game not sending the data, not a bug here.
	-- One module, two display modes (tab-list tag and/or a floating overlay).
	do
		local PartyList
		local ShowTablist, ShowOverlay, OnlyMulti
		local gui

		local PARTY_COLORS = {
			Color3.fromRGB(255, 92, 92), Color3.fromRGB(77, 166, 255),
			Color3.fromRGB(92, 224, 92), Color3.fromRGB(255, 210, 77),
			Color3.fromRGB(199, 125, 255), Color3.fromRGB(51, 224, 208),
			Color3.fromRGB(255, 154, 77), Color3.fromRGB(255, 111, 216),
		}
		local function hex(c)
			return string.format('#%02X%02X%02X',
				math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
		end

		local function matchController()
			local ok, c = pcall(function() return bedwars.MatchController end)
			return ok and c or nil
		end

		-- Returns a list of groups, each a list of userIds. Real party data only --
		-- see the block comment above for why team membership is deliberately not
		-- used as a fallback. Groups are de-duped by member set.
		local function collectGroups()
			local groups, seen = {}, {}
			local function add(members)
				if type(members) ~= 'table' then return end
				local ids, key = {}, {}
				for k, m in pairs(members) do
					-- members may be a LIST of userIds, or a MAP keyed by userId
					local uid = tonumber(m) or (type(m) == 'table' and tonumber(m.userId or m.UserId)) or tonumber(k)
					if uid then ids[#ids + 1] = uid key[#key + 1] = uid end
				end
				if #ids == 0 then return end
				table.sort(key)
				local sig = table.concat(key, ',')
				if not seen[sig] then seen[sig] = true groups[#groups + 1] = ids end
			end

			local mc = matchController()
			if mc then
				local parties = nil
				pcall(function() parties = mc.parties end)      -- direct field
				if type(parties) ~= 'table' or not next(parties) then
					pcall(function() if mc.getParties then parties = mc:getParties() end end)
				end
				if type(parties) == 'table' and next(parties) then
					for _, p in pairs(parties) do add(type(p) == 'table' and (p.members or p) or nil) end
				end
			end

			return groups
		end

		-- userId -> { idx, color } for every player in a shown group
		local function buildMap()
			local groups = collectGroups()
			-- filter to multi-member if requested
			local shown = {}
			for _, ids in ipairs(groups) do
				if not (OnlyMulti and OnlyMulti.Enabled) or #ids >= 2 then shown[#shown + 1] = ids end
			end
			local map = {}
			for i, ids in ipairs(shown) do
				local col = PARTY_COLORS[((i - 1) % #PARTY_COLORS) + 1]
				for _, uid in ipairs(ids) do map[uid] = { idx = i, color = col } end
			end
			return map, shown
		end

		-- ── tab-list painting ──────────────────────────────────────────────────
		local function stripTags(s) return (s:gsub('<[^>]->', '')) end
		-- Clean a tab-list label to just the player name: drop rich-text tags, then
		-- strip EVERY leading "[..]" group (level / clan / kills tags, e.g.
		-- "[151] [nwr] Fazpala" -> "fazpala"), plus surrounding whitespace + our own
		-- appended tag if present. This is why only some rows matched before -- names
		-- with a clan prefix were never stripped down to the bare name.
		local function nameKey(s)
			s = stripTags(s)
			-- remove repeated leading bracket tags
			while true do
				local ns = s:gsub('^%s*%b[]%s*', '')
				if ns == s then break end
				s = ns
			end
			return s:gsub('^%s+', ''):gsub('%s+$', ''):lower()
		end

		local function paintTablist(map)
			local pg = lplr:FindFirstChild('PlayerGui')
			if not pg then return end
			-- name -> info from live players (both Name and DisplayName as keys)
			local byName, partied = {}, {}
			for _, plr in playersService:GetPlayers() do
				local info = map[plr.UserId]
				if info then
					byName[plr.Name:lower()] = info
					if plr.DisplayName ~= '' then byName[plr.DisplayName:lower()] = info end
					partied[#partied + 1] = { name = plr.Name:lower(), disp = plr.DisplayName:lower(), info = info }
				end
			end
			-- fallback matcher: split the cleaned label into whitespace tokens and match
			-- a token exactly against a partied player's name/displayname. This survives
			-- any leftover prefix/suffix without fragile Lua patterns.
			local function resolve(key)
				local hit = byName[key]
				if hit then return hit end
				for token in key:gmatch('%S+') do
					for _, p in partied do
						if token == p.name or (p.disp ~= '' and token == p.disp) then
							return p.info
						end
					end
				end
				return nil
			end

			local function allowed(gui)
				local a = gui
				while a and a ~= pg do
					local n = a.Name:lower()
					if n:find('leaderboard') or n:find('tablist') or (n:find('tab') and n:find('list')) or n:find('spectat') then
						return true
					end
					a = a.Parent
				end
				return false
			end

			for _, g in pg:GetDescendants() do
				if g:IsA('TextLabel') and allowed(g) then
					local orig = g:GetAttribute('VainPartyOrig')
					if orig and g.Text:sub(1, #orig) ~= orig then
						orig = nil
						g:SetAttribute('VainPartyOrig', nil)
						g:SetAttribute('VainParty', nil)
					end
					local info = resolve(nameKey(orig or g.Text))
					local painted = g:GetAttribute('VainParty')
					if info and (not ShowTablist or ShowTablist.Enabled) then
						if not orig then orig = g.Text g:SetAttribute('VainPartyOrig', orig) end
						local tag = "<font color='" .. hex(info.color) .. "'>\u{25CF} P" .. info.idx .. "</font>"
						local want = orig .. "  " .. tag
						if g.Text ~= want then
							g:SetAttribute('VainParty', true)
							g.RichText = true
							g.Text = want
						end
					elseif painted then
						if type(orig) == 'string' then g.Text = orig end
						g:SetAttribute('VainPartyOrig', nil)
						g:SetAttribute('VainParty', nil)
					end
				end
			end
		end

		local function restoreTablist()
			local pg = lplr:FindFirstChild('PlayerGui')
			if not pg then return end
			for _, g in pg:GetDescendants() do
				if g:IsA('TextLabel') and g:GetAttribute('VainParty') then
					local orig = g:GetAttribute('VainPartyOrig')
					if type(orig) == 'string' then g.Text = orig end
					g:SetAttribute('VainPartyOrig', nil)
					g:SetAttribute('VainParty', nil)
				end
			end
		end

		-- ── overlay panel ──────────────────────────────────────────────────────
		local function buildOverlay(shown)
			if gui then gui:Destroy() gui = nil end
			if not (ShowOverlay and ShowOverlay.Enabled) or #shown == 0 then return end
			gui = Instance.new('ScreenGui')
			gui.Name = 'VainPartyList'
			gui.ResetOnSpawn = false
			gui.IgnoreGuiInset = true
			gui.DisplayOrder = 50
			gui.Parent = gethui and gethui() or lplr:WaitForChild('PlayerGui')

			local root = Instance.new('Frame')
			root.Size = UDim2.fromOffset(220, 0)
			root.AutomaticSize = Enum.AutomaticSize.Y
			root.Position = UDim2.new(0, 12, 0, 90)
			root.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
			root.BackgroundTransparency = 0.15
			root.BorderSizePixel = 0
			root.Active = true
			root.Draggable = true
			root.Parent = gui
			Instance.new('UICorner', root).CornerRadius = UDim.new(0, 10)
			local pad = Instance.new('UIPadding')
			pad.PaddingTop = UDim.new(0, 8) pad.PaddingBottom = UDim.new(0, 8)
			pad.PaddingLeft = UDim.new(0, 8) pad.PaddingRight = UDim.new(0, 8)
			pad.Parent = root
			local list = Instance.new('UIListLayout')
			list.SortOrder = Enum.SortOrder.LayoutOrder
			list.Padding = UDim.new(0, 8)
			list.Parent = root

			local header = Instance.new('TextLabel')
			header.Size = UDim2.new(1, 0, 0, 22)
			header.BackgroundTransparency = 1
			header.Text = 'Parties (' .. #shown .. ')'
			header.TextColor3 = Color3.fromRGB(255, 178, 124)
			header.TextSize = 16
			header.Font = Enum.Font.GothamBold
			header.TextXAlignment = Enum.TextXAlignment.Left
			header.LayoutOrder = 0
			header.Parent = root

			for pi, ids in ipairs(shown) do
				local col = PARTY_COLORS[((pi - 1) % #PARTY_COLORS) + 1]
				local card = Instance.new('Frame')
				card.Size = UDim2.new(1, 0, 0, 0)
				card.AutomaticSize = Enum.AutomaticSize.Y
				card.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
				card.BackgroundTransparency = 0.2
				card.BorderSizePixel = 0
				card.LayoutOrder = pi
				card.Parent = root
				Instance.new('UICorner', card).CornerRadius = UDim.new(0, 8)
				local stroke = Instance.new('UIStroke') stroke.Color = col stroke.Thickness = 1.5 stroke.Transparency = 0.2 stroke.Parent = card
				local cpad = Instance.new('UIPadding')
				cpad.PaddingTop = UDim.new(0, 6) cpad.PaddingBottom = UDim.new(0, 6)
				cpad.PaddingLeft = UDim.new(0, 6) cpad.PaddingRight = UDim.new(0, 6)
				cpad.Parent = card
				local clist = Instance.new('UIListLayout')
				clist.SortOrder = Enum.SortOrder.LayoutOrder
				clist.Padding = UDim.new(0, 4)
				clist.Parent = card

				local order = 0
				for _, uid in ipairs(ids) do
					local row = Instance.new('Frame')
					row.Size = UDim2.new(1, 0, 0, 30)
					row.BackgroundTransparency = 1
					row.LayoutOrder = order
					row.Parent = card
					order = order + 1
					local av = Instance.new('ImageLabel')
					av.Size = UDim2.fromOffset(26, 26)
					av.Position = UDim2.fromOffset(0, 2)
					av.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
					av.BorderSizePixel = 0
					av.Image = 'rbxthumb://type=AvatarHeadShot&id=' .. tostring(uid) .. '&w=150&h=150'
					av.Parent = row
					Instance.new('UICorner', av).CornerRadius = UDim.new(0, 6)
					local plr = playersService:GetPlayerByUserId(uid)
					local nm = Instance.new('TextLabel')
					nm.Size = UDim2.new(1, -34, 1, 0)
					nm.Position = UDim2.fromOffset(34, 0)
					nm.BackgroundTransparency = 1
					nm.Text = plr and (plr.DisplayName ~= '' and plr.DisplayName or plr.Name) or ('#' .. tostring(uid))
					nm.TextColor3 = plr and (plr == lplr and Color3.fromRGB(120, 235, 140) or Color3.new(1, 1, 1)) or Color3.fromRGB(150, 150, 150)
					nm.TextSize = 15
					nm.Font = Enum.Font.GothamMedium
					nm.TextXAlignment = Enum.TextXAlignment.Left
					nm.TextTruncate = Enum.TextTruncate.AtEnd
					nm.Parent = row
				end
			end
		end

		local function tick_()
			local map, shown = buildMap()
			paintTablist(map)
			buildOverlay(shown)
		end

		PartyList = vain.Categories.Render:CreateModule({
			Name = 'Party List',
			Tooltip = "Shows real party groups (who queued together) as a coloured P# tag in the tab-list and an optional overlay. Not team-based -- a colour team isn't a party. Same group = same colour.",
			Function = function(callback)
				if callback then
					local _, shown = buildMap()
					notif('Party List', #shown > 0
						and ('%d part%s shown'):format(#shown, #shown == 1 and 'y' or 'ies')
						or 'No party data for this match (the game doesn\'t always send it)', 6, #shown > 0 and 'success' or 'warning')
					task.spawn(function()
						repeat
							pcall(tick_)
							task.wait(1)
						until not PartyList.Enabled
						pcall(restoreTablist)
						if gui then gui:Destroy() gui = nil end
					end)
				else
					pcall(restoreTablist)
					if gui then gui:Destroy() gui = nil end
				end
			end
		})
		ShowTablist = PartyList:CreateToggle({
			Name = 'Tab-list Tags', Default = true,
			Tooltip = 'Show the coloured party tag next to each player\'s tab-list name.',
			Function = function(on) if not on then pcall(restoreTablist) end end,
		})
		ShowOverlay = PartyList:CreateToggle({
			Name = 'Overlay Panel', Default = false,
			Tooltip = 'Show a floating draggable panel listing each party and its members (top-left).',
			Function = function(on) if not on and gui then gui:Destroy() gui = nil end end,
		})
		OnlyMulti = PartyList:CreateToggle({
			Name = 'Hide Solos', Default = true,
			Tooltip = 'Only mark groups of 2+ players (hide players alone in a group).',
		})
	end

	AimAssist = vain.Categories.Combat:CreateModule({
		Name = 'Aim Assist',
		Tooltip = 'Smoothly deflects your camera toward nearby enemies',
		Function = function(callback)
			if callback then
				lockedTarget = nil
				lastValidTarget = nil
				lastValidTime = 0
				shakeTime = 0
				AimAssist:Clean(runService.Heartbeat:Connect(function(dt)

					if not entitylib.isAlive or not entitylib.character or not entitylib.character.RootPart then
						lockedTarget = nil
						return
					end

					-- By default AimAssist works with any held item. 'Limit to item'
					-- restores the old behavior: only assist while holding a sword
					-- (or a bow/crossbow when Work With Projectiles is on).
					if LimitToItem and LimitToItem.Enabled then
						local validWeapon = store.hand.toolType == 'sword'
						if WorkWithProjectiles and WorkWithProjectiles.Enabled then
							validWeapon = validWeapon or isHoldingBowCrossbow()
						end
						if not validWeapon then
							lockedTarget = nil
							return
						end
					end

					-- ClickAim gates on a recent sword swing, which never fires for a bow.
					-- Skip the gate while holding a bow/crossbow so projectile assist works.
					if ClickAim and ClickAim.Enabled and not isHoldingBowCrossbow() then
						local sc = bedwars.SwordController
						if not sc or not sc.lastAttack or (workspace:GetServerTimeNow() - sc.lastAttack) >= 0.4 then
							return
						end
					end

					local inFirstPerson = isFirstPerson()
					if ViewMode.Value == 'First Person' and not inFirstPerson then return end
					if ViewMode.Value == 'Third Person' and inFirstPerson then return end

					if ShopCheck and ShopCheck.Enabled then
						if isGUIOpen() then
							lockedTarget = nil
							return
						end
					end

					local ent = nil

					if KillauraTarget and KillauraTarget.Enabled then
						local ka = store.KillauraTarget
						if ka and ka.RootPart and ka.Character and ka.Character.Parent then
							local hum = ka.Character:FindFirstChildOfClass('Humanoid')
							if hum and hum.Health > 0 then
								ent = ka
							end
						end
					else
						if PriorityMode and PriorityMode.Enabled and lockedTarget then
							if isEntValid(lockedTarget) and isInAngle(lockedTarget) then
								ent = lockedTarget
							else
								lockedTarget = nil
							end
						end

						if not ent then
							local found = entitylib.EntityPosition({
								Range = Distance.Value,
								Part = 'RootPart',
								Wallcheck = Targets.Walls.Enabled,
								Players = Targets.Players.Enabled,
								NPCs = Targets.NPCs.Enabled,
								Sort = sortmethods[Sort.Value],
								Priority = prioritymethods[TargetPriority.Value]
							})

							if found then
								lastValidTarget = found
								lastValidTime = tick()
								ent = found
							elseif lastValidTarget and (tick() - lastValidTime) < GRACE_PERIOD then
								if isEntValid(lastValidTarget) and isInAngle(lastValidTarget) then
									ent = lastValidTarget
								else
									lastValidTarget = nil
								end
							end

							if ent and PriorityMode and PriorityMode.Enabled then
								lockedTarget = ent
							end
						end
					end

					if not ent then return end

					if not (KillauraTarget and KillauraTarget.Enabled) then
						if not isEntValid(ent) then
							if PriorityMode and PriorityMode.Enabled then lockedTarget = nil end
							lastValidTarget = nil
							return
						end
						if not isInAngle(ent) then
							if PriorityMode and PriorityMode.Enabled then lockedTarget = nil end
							return
						end
					end

					-- Min Distance: don't assist on targets closer than this (avoids
					-- snapping at point-blank where you don't need help).
					if MinDistance and MinDistance.Value > 0 and ent.RootPart and entitylib.character.RootPart then
						if (ent.RootPart.Position - entitylib.character.RootPart.Position).Magnitude < MinDistance.Value then
							return
						end
					end

					-- Target Health filter: only assist when the target is at or below
					-- the chosen health. BedWars stores real health on the character's
					-- 'Health' attribute (Humanoid.Health is often a fixed 100), and
					-- entitylib mirrors it on ent.Health — use that, like the Health sort.
					if HealthCheck and HealthCheck.Enabled then
						local hp = ent.Health
						if hp == nil and ent.Character then
							hp = ent.Character:GetAttribute('Health')
						end
						if hp and hp > (HealthThreshold and HealthThreshold.Value or 100) then
							return
						end
					end

					targetinfo.Targets[ent] = tick() + 1

					local aimPosition
					if AimPart.Value == 'Head' then
						local head = ent.Character and ent.Character:FindFirstChild('Head')
						aimPosition = head and head.Position or ent.RootPart.Position
					elseif AimPart.Value == 'Torso' then
						local torso = ent.Character and (ent.Character:FindFirstChild('UpperTorso') or ent.Character:FindFirstChild('Torso'))
						aimPosition = torso and torso.Position or ent.RootPart.Position
					elseif AimPart.Value == 'Closest' then
						local closest = ent.Character and getClosestPartToCursor(ent.Character)
						aimPosition = closest and closest.Position or ent.RootPart.Position
					else
						aimPosition = ent.RootPart.Position
					end

					if ShakeToggle and ShakeToggle.Enabled and ShakeAmount.Value > 0 then
						shakeTime = shakeTime + dt
						local intensity = ShakeAmount.Value * 0.045
						local sx = math.sin(shakeTime * 17.3) * intensity + math.sin(shakeTime * 5.7) * intensity * 0.4
						local sy = math.cos(shakeTime * 13.1) * intensity + math.cos(shakeTime * 8.3) * intensity * 0.3
						local sz = math.sin(shakeTime * 9.7 + 1.2) * intensity * 0.5
						if rng:NextNumber() < 0.08 then
							sx = sx + (rng:NextNumber() - 0.5) * intensity * 1.6
							sy = sy + (rng:NextNumber() - 0.5) * intensity * 1.6
						end
						aimPosition = aimPosition + Vector3.new(sx, sy, sz)
					end

					local targetCFrame = CFrame.lookAt(gameCamera.CFrame.p, aimPosition)
					if SmoothnessToggle and SmoothnessToggle.Enabled then
						local speed = getSmoothedSpeed(AimSpeed.Value, Smoothness.Value, dt)
						gameCamera.CFrame = gameCamera.CFrame:Lerp(targetCFrame, math.min(speed * (dt * 60), 0.95))
					else
						gameCamera.CFrame = gameCamera.CFrame:Lerp(targetCFrame, math.clamp(AimSpeed.Value * dt, 0, 0.95))
					end
				end))
			else
				lockedTarget = nil
				lastValidTarget = nil
			end
		end,
		Tooltip = 'Aim assist with smooth target tracking'
	})

	Targets = AimAssist:CreateTargets({
		Tooltip = 'Configure which types of targets to include',
		Players = true,
		Walls = true
	})

	local methods = {'Damage', 'Distance'}
	for i in sortmethods do
		if not table.find(methods, i) then
			table.insert(methods, i)
		end
	end

	Sort = AimAssist:CreateDropdown({
		Name = 'Target Mode',
		List = methods,
		Tooltip = 'How to prioritize targets',
		ItemTooltips = {
			Distance = 'Targets the closest enemy by stud distance',
			Health = 'Targets the enemy with the lowest remaining health',
			Angle = 'Targets the enemy closest to your look direction',
			Cursor = 'Targets the enemy nearest to your mouse cursor',
			Damage = 'Targets the enemy who most recently took damage',
			Threat = 'Targets the enemy judged to be the greatest combat threat',
			Kit = 'Prioritizes dangerous kit users (Hannah, Spirit Assassin, etc.)',
		},
	})

	TargetPriority = AimAssist:CreateDropdown({
		Name = 'Target Priority',
		List = {'None', 'Players', 'NPCs'},
		Default = 'None',
		Tooltip = 'When both are valid targets, prefer this type over the other',
	})

	AimPart = AimAssist:CreateDropdown({
		Name = 'Aim Part',
		Tooltip = 'Which body part on the target to aim at',
		List = {'Torso', 'Head', 'Closest'},
		Default = 'Torso',
		ItemTooltips = {
			Torso = 'Aims at the center of the player\'s body — reliable and easy to hit',
			Head = 'Aims at the head — higher damage potential but smaller hitbox',
			Closest = 'Aims at whichever body part is nearest to your crosshair',
		}
	})

	ViewMode = AimAssist:CreateDropdown({
		Name = 'View Mode',
		List = {'First Person', 'Third Person', 'Both'},
		Default = 'Both',
		Tooltip = 'Only aim in first person, third person, or always',
		ItemTooltips = {
			['First Person'] = 'Assist only activates in first-person camera mode',
			['Third Person'] = 'Assist only activates in third-person camera mode',
			Both = 'Assist activates in both camera modes',
		},
	})

	AimSpeed = AimAssist:CreateSlider({
		Name = 'Aim Speed',
		Min = 1,
		Max = 20,
		Default = 6,
		Tooltip = 'How fast aim assist moves toward the target'
	})

	Distance = AimAssist:CreateSlider({
		Name = 'Distance',
		Tooltip = 'Maximum distance in studs',
		Min = 1,
		Max = 30,
		Default = 25,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	AngleSlider = AimAssist:CreateSlider({
		Name = 'Max Angle',
		Min = 1,
		Max = 360,
		Default = 60,
		Tooltip = 'FOV cone for target acquisition'
	})

	MinDistance = AimAssist:CreateSlider({
		Name = 'Min Distance',
		Tooltip = 'Don\'t assist on targets closer than this (0 = no minimum)',
		Min = 0,
		Max = 50,
		Default = 0,
		Suffix = function(val)
			return val <= 1 and 'stud' or 'studs'
		end
	})

	SmoothnessToggle = AimAssist:CreateToggle({
		Name = 'Smoothness',
		Default = false,
		Tooltip = 'Makes aim assist feel more legit',
		Function = function(callback)
			if Smoothness then Smoothness.Object.Visible = callback end
		end
	})

	Smoothness = AimAssist:CreateSlider({
		Name = 'Smoothness Amount',
		Min = 1,
		Max = 10,
		Default = 5,
		Tooltip = 'Higher = smoother and more legit.',
		Visible = false
	})

	PriorityMode = AimAssist:CreateToggle({
		Name = 'Priority Mode',
		Default = false,
		Tooltip = 'Locks onto one target. Ignores closer targets until current is lost.'
	})

	ClickAim = AimAssist:CreateToggle({
		Name = 'Click Aim',
		Default = true,
		Tooltip = 'Only aims when attacking'
	})

	KillauraTarget = AimAssist:CreateToggle({
		Name = 'Use Killaura Target',
		Tooltip = 'Follow Killaura target only, bypasses all distance and wall filters'
	})

	ShakeToggle = AimAssist:CreateToggle({
		Name = 'Shake',
		Default = false,
		Tooltip = 'Adds legit-looking human jitter to aim',
		Function = function(callback)
			if ShakeAmount then ShakeAmount.Object.Visible = callback end
		end
	})

	ShakeAmount = AimAssist:CreateSlider({
		Name = 'Shake Amount',
		Tooltip = 'Adjusts the shake amount value',
		Min = 1,
		Max = 10,
		Default = 3,
		Visible = false
	})

	ShopCheck = AimAssist:CreateToggle({
		Name = 'Shop Check',
		Default = false,
		Tooltip = 'Disables aim assist when the shop is open'
	})

	WorkWithProjectiles = AimAssist:CreateToggle({
		Name = 'Work With Projectiles',
		Default = false,
		Tooltip = 'Also activates when holding bows or crossbows (only matters with Limit to item on)'
	})

	LimitToItem = AimAssist:CreateToggle({
		Name = 'Limit to item',
		Default = false,
		Tooltip = 'Only assist while holding a weapon (sword, or bow/crossbow with Work With Projectiles). Off = any held item.'
	})

	HealthCheck = AimAssist:CreateToggle({
		Name = 'Target HP Check',
		Default = false,
		Tooltip = 'Only assist when the target is at or below the chosen health',
		Function = function(callback)
			if HealthThreshold and HealthThreshold.Object then
				HealthThreshold.Object.Visible = callback
			end
		end
	})

	HealthThreshold = AimAssist:CreateSlider({
		Name = 'Target Health',
		Tooltip = 'Maximum target health to assist on',
		Min = 1,
		Max = 100,
		Default = 100,
		Darker = true,
		Visible = false
	})

	task.defer(function()
		if Smoothness and Smoothness.Object then
			Smoothness.Object.Visible = SmoothnessToggle and SmoothnessToggle.Enabled or false
		end
		if ShakeAmount and ShakeAmount.Object then
			ShakeAmount.Object.Visible = false
		end
	end)
end)

run(function()
	local KaidaKillaura	
	local Targets
	local AttackRange
	local UpdateRate
	local MouseDown
	local GUICheck
	local ShowAnimation
	local AutoAbility
	local AbilityDistance
	local SwingDuringAbility
	local lastAttackTime = 0
	local lastAbilityTime = 0
	local attackCooldown = 0.55
	local abilityCooldown = 22
	local isChargingAbility = false
	manualCharging = false
	local currentTarget = nil
	local AutoStopAbility
	local SummonerKitController = nil
	local function getSummonerController()
		if SummonerKitController then return SummonerKitController end
		pcall(function()
			SummonerKitController = bedwars.KnitClient.Controllers.SummonerKitController
		end)
		return SummonerKitController
	end

	local function isActuallyCharging()
		if isChargingAbility then return true end
		if manualCharging then return true end
		local result = false
		pcall(function()
			local btns = lplr.PlayerGui
				:FindFirstChild("ActionBarScreenGui")
				and lplr.PlayerGui.ActionBarScreenGui:FindFirstChild("ActionBar")
				and lplr.PlayerGui.ActionBarScreenGui.ActionBar:FindFirstChild("AbilityButtons")
			if btns and btns:FindFirstChild("summoner_finish_charging") then
				result = true
			end
		end)
		return result
	end

	local function getSpellLevel()
		local level = 1
		pcall(function()
			local util = require(game:GetService("ReplicatedStorage").TS.games.bedwars.kit.kits.summoner['summoner-kit-util'])
			local result = util.summoner_getPlayerSpellLevel(lplr)
			if result then level = result end
		end)
		return level
	end

	local function getCastTime(level)
		local castTime = 2
		pcall(function()
			local util = require(game:GetService("ReplicatedStorage").TS.games.bedwars.kit.kits.summoner['summoner-kit-util'])
			local result = util.summoner_getTotalCastTimeRequired(level)
			if result then castTime = result end
		end)
		return castTime
	end

	local function fireUseAbility(abilityName)
		pcall(function()
			game:GetService("ReplicatedStorage")
				:WaitForChild("events-@easy-games/game-core:shared/game-core-networking@getEvents.Events")
				:WaitForChild("useAbility"):FireServer(abilityName)
		end)
	end

	local function doAutoAbility()
		if isChargingAbility then return end
		isChargingAbility = true

		pcall(function()
			local remote = game:GetService("ReplicatedStorage")
				:WaitForChild("events-@easy-games/game-core:shared/game-core-networking@getEvents.Events")
				:WaitForChild("useAbility")

			remote:FireServer(unpack({"summoner_start_charging"}))

			if AutoStopAbility.Enabled then
				task.wait(0.5)
				remote:FireServer(unpack({"summoner_finish_charging"}))
			else
				local level = getSpellLevel()
				local castTime = getCastTime(level)
				task.wait(math.max(castTime, 0.5))
				if isChargingAbility then
					remote:FireServer(unpack({"summoner_finish_charging"}))
					if currentTarget and currentTarget.RootPart then
						local myPos = entitylib.character.RootPart.Position
						local shootDir = CFrame.lookAt(myPos, currentTarget.RootPart.Position).LookVector
						local localPosition = myPos + shootDir * math.max((myPos - currentTarget.RootPart.Position).Magnitude - 16, 0)
						bedwars.Client:Get(remotes.SummonerClawAttack):SendToServer({
							position = localPosition,
							direction = shootDir,
							clientTime = workspace:GetServerTimeNow()
						})
					end
				end
			end
		end)

		lastAbilityTime = tick()
		isChargingAbility = false
	end

	local function getPlayerClawLevel()
		local handItem = lplr.Character and lplr.Character:FindFirstChild('HandInvItem')
		if handItem and handItem.Value then
			local itemType = handItem.Value.Name
			if itemType == 'summoner_claw_1' then return 1 end
			if itemType == 'summoner_claw_2' then return 2 end
			if itemType == 'summoner_claw_3' then return 3 end
			if itemType == 'summoner_claw_4' then return 4 end
		end
		if store and store.inventory and store.inventory.hotbar then
			for _, v in pairs(store.inventory.hotbar) do
				if v.item then
					local itemType = v.item.itemType
					if itemType == 'summoner_claw_1' then return 1 end
					if itemType == 'summoner_claw_2' then return 2 end
					if itemType == 'summoner_claw_3' then return 3 end
					if itemType == 'summoner_claw_4' then return 4 end
				end
			end
		end
		return 1
	end

	KaidaKillaura = vain.Categories.Kit:CreateModule({
		Name = 'Auto Kaida',
		Tooltip = 'Automates the Kaida kit flame breath ability',
		Function = function(callback)
			if callback then
				lastAttackTime = 0
				lastAbilityTime = 0
				isChargingAbility = false
				manualCharging = false   
				pcall(function()
					local abilityButtons = lplr.PlayerGui
						:WaitForChild("ActionBarScreenGui", 10)
						:WaitForChild("ActionBar", 10)
						:WaitForChild("AbilityButtons", 10)

					KaidaKillaura:Clean(abilityButtons.ChildRemoved:Connect(function(child)
						if child.Name == "summoner_start_charging" then
							manualCharging = true
						end
						if child.Name == "summoner_finish_charging" then
							manualCharging = false
						end
					end))

					KaidaKillaura:Clean(abilityButtons.ChildAdded:Connect(function(child)
						if child.Name == "summoner_start_charging" then
							manualCharging = false
						end
					end))

					if abilityButtons:FindFirstChild("summoner_finish_charging") then
						manualCharging = true
					end
				end)

				repeat
					if not entitylib.isAlive then
						task.wait(0.1)
						continue
					end

					if GUICheck.Enabled then
						if bedwars.AppController:isLayerOpen(bedwars.UILayers.MAIN) then
							task.wait(0.1)
							continue
						end
					end

					local handItem = lplr.Character:FindFirstChild('HandInvItem')
					local hasClaw = handItem and handItem.Value and handItem.Value.Name:find('summoner_claw') ~= nil

					if MouseDown.Enabled then
						if not inputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
							task.wait(1.2)
							continue
						end
					end

					local plr = nil
					do
						local bestDot = -math.huge
						local camCF = workspace.CurrentCamera.CFrame
						local myPos = entitylib.character.RootPart.Position
						for _, ent in ipairs(entitylib.List) do
							local validType = (Targets.Players.Enabled and ent.Player) or (Targets.NPCs.Enabled and ent.NPC)
							if validType and ent.Targetable and ent.RootPart and ent.Health > 0 then
								local dist = (myPos - ent.RootPart.Position).Magnitude
								if dist <= AttackRange.Value then
									local toEnt = (ent.RootPart.Position - camCF.Position).Unit
									local dot = camCF.LookVector:Dot(toEnt)
									if dot <= 0 then continue end
									if dot > bestDot then
										bestDot = dot
										plr = ent
									end
								end
							end
						end
					end

					if plr and plr.Health > 0 then
						local localPosition = entitylib.character.RootPart.Position
						local targetDistance = (localPosition - plr.RootPart.Position).Magnitude
						local now = tick()

						if AutoAbility.Enabled and targetDistance <= AbilityDistance.Value * 1.25 then
							if not isChargingAbility and (now - lastAbilityTime) >= abilityCooldown then
								currentTarget = plr
								task.spawn(doAutoAbility)
							end
						end

						if not SwingDuringAbility.Enabled and isChargingAbility then
							task.wait(0.05)
							continue
						end

						if hasClaw then
							local charging = isActuallyCharging()

							if not SwingDuringAbility.Enabled and charging then
								task.wait(0.05)
								continue
							end

							if (now - lastAttackTime) >= attackCooldown and targetDistance <= AttackRange.Value then
								local shootDir = CFrame.lookAt(localPosition, plr.RootPart.Position).LookVector
								localPosition += shootDir * math.max((localPosition - plr.RootPart.Position).Magnitude - 16, 0)
								lastAttackTime = now

								if ShowAnimation.Enabled then
									task.spawn(function()
										pcall(function()
											local clawLevel = getPlayerClawLevel()
											bedwars.AnimationUtil:playAnimation(lplr, bedwars.GameAnimationUtil:getAssetId(bedwars.AnimationType.SUMMONER_CHARACTER_SWIPE), {
												looped = false
											})
											local clawModel = replicatedStorage.Assets.Misc.Kaida.Summoner_DragonClaw:Clone()
											local clawColors = {
												Color3.fromRGB(75, 75, 75),
												Color3.fromRGB(255, 255, 255),
												Color3.fromRGB(43, 229, 229),
												Color3.fromRGB(49, 229, 94)
											}
											local nailMesh = clawModel:FindFirstChild("dragon_claw_nail_mesh")
											if nailMesh and nailMesh:IsA("MeshPart") then
												nailMesh.Color = clawColors[clawLevel] or clawColors[1]
											end
											if bedwars.KnightClient and bedwars.KnightClient.Controllers.SummonerKitSkinController then
												if bedwars.KnightClient.Controllers.SummonerKitSkinController:isPrismaticSkin(lplr) then
													bedwars.KnightClient.Controllers.SummonerKitSkinController:applyClawRGB(clawModel)
												end
											end
											clawModel.Parent = workspace
											local camera = workspace.CurrentCamera
											if camera and (camera.CFrame.Position - entitylib.character.RootPart.Position).Magnitude < 1 then
												for _, part in clawModel:GetDescendants() do
													if part:IsA('MeshPart') then
														part.Transparency = 0.6
													end
												end
											end
											local rootPart = entitylib.character.RootPart
											local Unit = Vector3.new(shootDir.X, 0, shootDir.Z).Unit
											local startPos = rootPart.Position + Unit:Cross(Vector3.new(0, 1, 0)).Unit * -1 * 5 + Unit * 6
											local direction = (startPos + shootDir * 13 - startPos).Unit
											local cframe = CFrame.new(startPos, startPos + direction)
											clawModel:PivotTo(cframe)
											clawModel.PrimaryPart.Anchored = true
											local portalConn = nil
											if clawModel:FindFirstChild("Portal1") then
												portalConn = runService.Heartbeat:Connect(function()
													if not clawModel or not clawModel.Parent then
														portalConn:Disconnect()
														portalConn = nil
														return
													end
													local foreArmCF = clawModel.RootPart.root.fore_arm.TransformedWorldCFrame
													if clawModel.Portal1 then
														clawModel.Portal1:PivotTo(foreArmCF)
													end
													if clawModel.Portal2 then
														clawModel.Portal2:PivotTo(foreArmCF * CFrame.Angles(math.pi, 0, 0))
													end
												end)
											end
											if clawModel:FindFirstChild('AnimationController') then
												local animator = clawModel.AnimationController:FindFirstChildOfClass('Animator')
												if animator then
													bedwars.AnimationUtil:playAnimation(animator, bedwars.GameAnimationUtil:getAssetId(bedwars.AnimationType.SUMMONER_CLAW_ATTACK), {
														looped = false,
														speed = 1
													})
												end
											end
											pcall(function()
												local sounds = {
													bedwars.SoundList.SUMMONER_CLAW_ATTACK_1,
													bedwars.SoundList.SUMMONER_CLAW_ATTACK_2,
													bedwars.SoundList.SUMMONER_CLAW_ATTACK_3,
													bedwars.SoundList.SUMMONER_CLAW_ATTACK_4
												}
												bedwars.SoundManager:playSound(sounds[math.random(1, #sounds)], {
													position = rootPart.Position
												})
											end)
											task.wait(0.5)
											if portalConn then
												portalConn:Disconnect()
												portalConn = nil
											end
											clawModel:Destroy()
										end)
									end)
								end

								bedwars.Client:Get(remotes.SummonerClawAttack):SendToServer({
									position = localPosition,
									direction = shootDir,
									clientTime = workspace:GetServerTimeNow()
								})
							end
						end
					else
						if isChargingAbility then
							isChargingAbility = false
							fireUseAbility("summoner_finish_charging")
						end
					end

					task.wait(1 / UpdateRate.Value)
				until not KaidaKillaura.Enabled

				isChargingAbility = false
			end
		end,
		Tooltip = 'Auto attacks with Summoner claw'
	})

	Targets = KaidaKillaura:CreateTargets({
		Tooltip = 'Configure which types of targets to include',
		Players = true,
		NPCs = true,
		Walls = true
	})

	AttackRange = KaidaKillaura:CreateSlider({
		Name = 'Attack Range',
		Tooltip = 'Distance at which the hit packet is sent',
		Min = 1,
		Max = 32,
		Default = 22,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	UpdateRate = KaidaKillaura:CreateSlider({
		Name = 'Update Rate',
		Tooltip = 'How often to scan for targets (seconds)',
		Min = 1,
		Max = 120,
		Default = 60,
		Suffix = 'hz'
	})

	MouseDown = KaidaKillaura:CreateToggle({
		Name = 'Require Mouse Down',
		Tooltip = 'Only attacks while holding left click'
	})

	GUICheck = KaidaKillaura:CreateToggle({
		Name = 'GUI Check',
		Tooltip = 'Pauses the module when a GUI menu is open',
	})

	ShowAnimation = KaidaKillaura:CreateToggle({
		Name = 'Show Animation',
		Tooltip = 'Plays the attack animation during killaura hits',
		Default = true
	})

	SwingDuringAbility = KaidaKillaura:CreateToggle({
		Name = 'Swing During Ability',
		Default = true,
		Tooltip = 'Continue claw attacks while charging ability'
	})

	AutoAbility = KaidaKillaura:CreateToggle({
		Name = 'Auto Ability',
		Default = false,
		Tooltip = 'Automatically uses ability when enemy is within distance',
		Function = function(callback)
			if not callback then
				isChargingAbility = false
			end
			AbilityDistance.Object.Visible = callback
			AutoStopAbility.Object.Visible = callback
		end
	})

	AbilityDistance = KaidaKillaura:CreateSlider({
		Name = 'Ability Distance',
		Min = 3,
		Max = 15,
		Default = 6,
		Visible = false,
		Tooltip = 'Distance to trigger ability',
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	AutoStopAbility = KaidaKillaura:CreateToggle({
		Name = 'Auto Stop Ability',
		Default = true,
		Visible = false,
		Tooltip = 'Cancels ability early if target leaves range mid-cast'
	})

	task.defer(function()
		if AbilityDistance and AbilityDistance.Object then
			AbilityDistance.Object.Visible = false   
		end
	end)
end)

run(function()
    local AutoLasso
    local Targets
    local Range
    local FOV
    local AimPart
    local PredictionMode
    local projectileRemote = {InvokeServer = function() end}
    local nextAllowedShot = 0
    local rayCheck = RaycastParams.new()
    local COOLDOWN_SECONDS = 10.5

    task.spawn(function()
        projectileRemote = bedwars.Client:Get(remotes.FireProjectile).instance
    end)

    local function getLassoSlot()
        for i, v in store.inventory.hotbar do
            if v.item and v.item.itemType == "lasso" then
                return i - 1, v.item
            end
        end
        return nil, nil
    end

    local function getLassoProjectileMeta()
        local meta = bedwars.ProjectileMeta and bedwars.ProjectileMeta["lasso"]
        if meta then
            return meta.launchVelocity or 100, meta.gravitationalAcceleration or 196.2
        end
        return 100, 196.2
    end

    local function shootLasso(targetEnt)
        if not targetEnt or not targetEnt.RootPart then return false end

        local now = tick()
        if now < nextAllowedShot then return false end

        local lassoSlot, lassoItem = getLassoSlot()
        if not lassoSlot or not lassoItem then return false end

        local selfpos = entitylib.character.RootPart.Position
        local targetPart = targetEnt.RootPart

        if AimPart.Value == "Head" and targetEnt.Head then
            targetPart = targetEnt.Head
        elseif AimPart.Value == "Torso" then
            local torso = targetEnt.Character:FindFirstChild("UpperTorso") or targetEnt.Character:FindFirstChild("Torso")
            if torso then targetPart = torso end
        end

        local projSpeed, gravity = getLassoProjectileMeta()
        local targetPos = targetPart.Position
        local targetVel = targetPart.Velocity

        local aimPos = targetPos
        if PredictionMode.Value == "On" then
            local calc = prediction.SolveTrajectory(
                selfpos, projSpeed, gravity,
                targetPos, targetVel,
                workspace.Gravity, targetEnt.HipHeight,
                targetEnt.Jumping and 42.6 or nil,
                rayCheck
            )
            local targetRoot = plr.RootPart
						if targetRoot then
							local targetRootVel = targetRoot.AssemblyLinearVelocity or targetRoot.Velocity or Vector3.zero
							local targetMovingUp = targetRootVel.Y > 3
							local heightDiff = aimTarget.Y - newlook.p.Y
							if targetMovingUp then
								aimTarget = aimTarget + Vector3.new(0, math.clamp(targetRootVel.Y * 0.08, 0.5, 3.5), 0)
							elseif heightDiff < -8 then
								aimTarget = aimTarget + Vector3.new(0, math.clamp(math.abs(heightDiff) * 0.04, 0.3, 2.5), 0)
							end
						end
						if calc then aimPos = calc end
        end

        local dir = CFrame.lookAt(selfpos, aimPos).LookVector * projSpeed
        local originalSlot = store.inventory.hotbarSlot

        if originalSlot ~= lassoSlot then
            hotbarSwitch(lassoSlot)
            task.wait(0.05)
        end

        local success = pcall(function()
            projectileRemote:InvokeServer(
                lassoItem.tool,
                "lasso", "lasso",
                selfpos, selfpos, dir,
                httpService:GenerateGUID(true),
                {drawDurationSeconds = 1, shotId = httpService:GenerateGUID(false)},
                workspace:GetServerTimeNow() - 0.045
            )
        end)

        if originalSlot ~= lassoSlot then
            hotbarSwitch(originalSlot)
        end

        if success then
            nextAllowedShot = now + COOLDOWN_SECONDS
            targetinfo.Targets[targetEnt] = now + 1
            return true
        end
        return false
    end

    AutoLasso = vain.Categories.Kit:CreateModule({
        Name = 'Auto Lasso',
        Tooltip = 'Automatically uses the lasso on nearby enemies',
        Function = function(callback)
            if callback then
                repeat
                    if entitylib.isAlive then
                        local target = entitylib.EntityPosition({
                            Range = Range.Value,
                            Part = 'RootPart',
                            Wallcheck = Targets.Walls.Enabled,
                            Players = Targets.Players.Enabled,
                            NPCs = Targets.NPCs.Enabled,
                            Sort = sortmethods.Distance
                        })

                        if target then
							if getAccountTier(target.Player) >= 1 and getAccountTier(lplr) == 0 then continue end
                            local selfpos = entitylib.character.RootPart.Position
                            local localFacing = (ViewMode.Value == 'Third Person' and gameCamera.CFrame.LookVector or entitylib.character.RootPart.CFrame.LookVector) * Vector3.new(1, 0, 1)
                            local delta = (target.RootPart.Position - selfpos) * Vector3.new(1, 0, 1)
                            if delta.Magnitude > 0.001 then
                                local angle = math.acos(math.clamp(localfacing:Dot(delta.Unit), -1, 1))
                                if angle <= math.rad(FOV.Value) / 2 then
                                    shootLasso(target)
                                end
                            end
                        end
                    end
                    task.wait(0.05)
                until not AutoLasso.Enabled
            else
                nextAllowedShot = 0
            end
        end,
        Tooltip = 'Switches to lasso, shoots once, then switches back. 10.5 second cooldown.'
    })

    Targets = AutoLasso:CreateTargets({
    	Tooltip = 'Configure which types of targets to include',
        Players = true,
        NPCs = true,
        Walls = false
    })

    Range = AutoLasso:CreateSlider({
        Name = 'Range',
        Tooltip = 'Maximum distance in studs',
        Min = 5,
        Max = 80,
        Default = 50,
        Suffix = function(val)
            return val == 1 and 'stud' or 'studs'
        end
    })

    FOV = AutoLasso:CreateSlider({
        Name = 'FOV',
        Tooltip = 'Field-of-view cone in degrees for target detection',
        Min = 1,
        Max = 360,
        Default = 90
    })

    AimPart = AutoLasso:CreateDropdown({
        Name = 'Aim Part',
        Tooltip = 'Which body part on the target to aim at',
        List = {'RootPart', 'Head', 'Torso'},
        Default = 'RootPart',
        ItemTooltips = {
            RootPart = 'Aims at the center of the player\'s body (HumanoidRootPart)',
            Head = 'Aims at the head — higher damage potential but smaller hitbox',
            Torso = 'Aims at the upper torso',
        }
    })

    PredictionMode = AutoLasso:CreateDropdown({
        Name = 'Prediction',
        List = {'Off', 'On'},
        Default = 'On',
        Tooltip = 'Predict target movement for better accuracy',
        ItemTooltips = {
            Off = "Aims directly at the target's current position",
            On = 'Leads the shot based on target velocity for better hit rate',
        }
    })
end)

run(function()
    local Beekeeper
    local CollectionToggle
	local LimitToNet
	local maxBeehiveLevel = 10
    local maxedBeehives = {}
    local maxedNotificationSent = {}
    local CollectionDelay
    local DelaySlider
    local RangeSlider
    local ESPToggle
    local BeesESP
    local BeesNotify
    local BeesBackground
    local BeesColor
    local BeehiveESP
    local ShowOtherBeehives
    local BeehiveBackground
    local BeehiveColor
    local AutoDeposit
    local DepositDelay
    local DepositDelaySlider
    local DepositRange
    local ESPLimitToNet  
    local collectionRunning = false
    local depositRunning = false
    local BeesFolder = Instance.new('Folder')
    BeesFolder.Parent = vain.gui
    local BeehiveFolder = Instance.new('Folder')
    BeehiveFolder.Parent = vain.gui
    local BeesReference = {}
    local BeehiveReference = {}
    local lastNotification = 0
    local spawnQueue = {}
    local notificationCooldown = 1

    local function sendNotification(count)
        notif("Bee ESP", string.format("%d bees spawned", count), 3)
    end

    local function processSpawnQueue()
        if #spawnQueue > 0 then
            local currentTime = tick()
            if currentTime - lastNotification >= notificationCooldown then
                sendNotification(#spawnQueue)
                lastNotification = currentTime
                spawnQueue = {}
            else
                task.delay(notificationCooldown - (currentTime - lastNotification), function()
                    if #spawnQueue > 0 then
                        sendNotification(#spawnQueue)
                        spawnQueue = {}
                    end
                end)
            end
        end
    end

    local function getBeeIcon()
        return bedwars.getIcon({itemType = 'bee'}, true)
    end

    local function AddedBee(v)
        if BeesReference[v] then return end
        local model = v.Parent
        if model then
            if model.Name:find("TamedBee") or model:FindFirstChild("TamedBee") then
                return 
            end
            
            if model:GetAttribute("IsTamed") or model:GetAttribute("Tamed") then
                return 
            end
            
            for _, tag in pairs(collectionService:GetTags(model)) do
                if tag:lower():find("tamed") then
                    return 
                end
            end
        end
        
        local billboard = Instance.new('BillboardGui')
        billboard.Parent = BeesFolder
        billboard.Name = 'bee'
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
        billboard.Size = UDim2.fromOffset(36, 36)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = v
        
        local blur = addBlur(billboard)
        blur.Visible = BeesBackground.Enabled
        
        local image = Instance.new('ImageLabel')
        image.Size = UDim2.fromOffset(36, 36)
        image.Position = UDim2.fromScale(0.5, 0.5)
        image.AnchorPoint = Vector2.new(0.5, 0.5)
        image.BackgroundColor3 = Color3.fromHSV(BeesColor.Hue, BeesColor.Sat, BeesColor.Value)
        image.BackgroundTransparency = 1 - (BeesBackground.Enabled and BeesColor.Opacity or 0)
        image.BorderSizePixel = 0
        image.Image = getBeeIcon()
        image.Parent = billboard
        
        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 4)
        uicorner.Parent = image
        
        BeesReference[v] = billboard
        
        if BeesNotify.Enabled then
            table.insert(spawnQueue, {item = 'bee', time = tick()})
            processSpawnQueue()
        end
    end

    local function RemovedBee(v)
        if BeesReference[v] then
            BeesReference[v]:Destroy()
            BeesReference[v] = nil
        end
    end

    local function isMyBeehive(beehive)
        if not beehive then return false end
        local placedBy = beehive:GetAttribute("PlacedByUserId")
        return placedBy and placedBy == lplr.UserId
    end
    
    local function getBeehiveOwnerName(beehive)
        if not beehive then return "Unknown" end
        local placedBy = beehive:GetAttribute("PlacedByUserId")
        if not placedBy then return "Unknown" end
        
        local player = game.Players:GetPlayerByUserId(placedBy)
        if player then
            return player.Name
        end
        
        return "Player"
    end

    local function AddedBeehive(beehive)
        local isOwn = isMyBeehive(beehive)
        
        if not isOwn and not (ShowOtherBeehives and ShowOtherBeehives.Enabled) then 
            return 
        end
        
        if BeehiveReference[beehive] then return end
        
        local level = beehive:GetAttribute("Level") or 0
        local isMaxed = level >= maxBeehiveLevel and isOwn
        
        if isMaxed and isOwn then
            maxedBeehives[beehive] = true
        end
        
        local ownerName = isOwn and nil or getBeehiveOwnerName(beehive)
        local hasOwnerName = ownerName ~= nil
        
        local billboard = Instance.new('BillboardGui')
        billboard.Parent = BeehiveFolder
        billboard.Name = 'beehive-esp'
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
        billboard.Size = isMaxed and UDim2.fromOffset(90, 40) or (hasOwnerName and UDim2.fromOffset(120, 40) or UDim2.fromOffset(80, 30))
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = beehive
        
        local blur = addBlur(billboard)
        blur.Visible = BeehiveBackground.Enabled
        
        local frame = Instance.new('Frame')
        frame.Size = UDim2.fromScale(1, 1)
        frame.BackgroundColor3 = isMaxed and Color3.fromRGB(255, 50, 50) or Color3.fromHSV(BeehiveColor.Hue, BeehiveColor.Sat, BeehiveColor.Value)
        frame.BackgroundTransparency = 1 - (BeehiveBackground.Enabled and (isMaxed and 0.5 or BeehiveColor.Opacity) or 0)
        frame.BorderSizePixel = 0
        frame.Parent = billboard
        
        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 6)
        uicorner.Parent = frame
        
        if hasOwnerName then
            local nameLabel = Instance.new('TextLabel')
            nameLabel.Name = 'OwnerName'
            nameLabel.Size = UDim2.new(1, 0, 0.4, 0)
            nameLabel.Position = UDim2.new(0, 0, 0, -20)
            nameLabel.BackgroundTransparency = 1
            nameLabel.Text = ownerName
            nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
            nameLabel.TextSize = 12
            nameLabel.Font = Enum.Font.GothamBold
            nameLabel.TextStrokeTransparency = 0.5
            nameLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
            nameLabel.Parent = billboard
        end
        
        local homeImage = Instance.new('TextLabel')
        homeImage.Size = UDim2.fromOffset(20, 20)
        homeImage.Position = UDim2.new(0, 5, 0.5, 0)
        homeImage.AnchorPoint = Vector2.new(0, 0.5)
        homeImage.BackgroundTransparency = 1
        homeImage.Text = isOwn and "🏠" or "🏘️"
        homeImage.TextSize = 16
        homeImage.Parent = frame
        
        local beeImage = Instance.new('ImageLabel')
        beeImage.Size = UDim2.fromOffset(18, 18)
        beeImage.Position = UDim2.new(0.5, -5, 0.5, 0)
        beeImage.AnchorPoint = Vector2.new(0, 0.5)
        beeImage.BackgroundTransparency = 1
        beeImage.Image = getBeeIcon()
        beeImage.Parent = frame
        
        local levelLabel = Instance.new('TextLabel')
        levelLabel.Name = 'Level'
        levelLabel.Size = UDim2.new(0, 25, 1, 0)
        levelLabel.Position = UDim2.new(1, -30, 0, 0)
        levelLabel.BackgroundTransparency = 1
        levelLabel.Text = tostring(level)
        levelLabel.TextColor3 = isMaxed and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(255, 255, 255)
        levelLabel.TextSize = 16
        levelLabel.Font = Enum.Font.GothamBold
        levelLabel.TextStrokeTransparency = 0.5
        levelLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
        levelLabel.Parent = frame
        
        if isMaxed and isOwn then
            local maxText = Instance.new('TextLabel')
            maxText.Name = 'MaxText'
            maxText.Size = UDim2.new(1, 0, 0.4, 0)
            maxText.Position = UDim2.new(0, 0, 0, hasOwnerName and -40 or -20)
            maxText.BackgroundTransparency = 1
            maxText.Text = "MAX"
            maxText.TextColor3 = Color3.fromRGB(255, 50, 50)
            maxText.TextSize = 12
            maxText.Font = Enum.Font.GothamBold
            maxText.TextStrokeTransparency = 0.5
            maxText.TextStrokeColor3 = Color3.new(0, 0, 0)
            maxText.Parent = billboard
        end
        
        BeehiveReference[beehive] = {
            billboard = billboard,
            levelLabel = levelLabel,
            beehive = beehive,
            isMaxed = isMaxed,
            isOwn = isOwn
        }
        
        local function updateLevel()
            local level = beehive:GetAttribute("Level") or 0
            local isMaxed = level >= maxBeehiveLevel and isOwn
            
            if isMaxed and isOwn then
                maxedBeehives[beehive] = true
                
                if not maxedNotificationSent[beehive] then
                    notif("Bee Keeper", "Beehive is full (MAX)", 3)
                    maxedNotificationSent[beehive] = true
                end
                
                if BeehiveReference[beehive] and BeehiveReference[beehive].billboard then
                    local maxText = BeehiveReference[beehive].billboard:FindFirstChild("MaxText")
                    if not maxText then
                        maxText = Instance.new('TextLabel')
                        maxText.Name = 'MaxText'
                        maxText.Size = UDim2.new(1, 0, 0.4, 0)
                        maxText.Position = UDim2.new(0, 0, 0, hasOwnerName and -40 or -20)
                        maxText.BackgroundTransparency = 1
                        maxText.Text = "MAX"
                        maxText.TextColor3 = Color3.fromRGB(255, 50, 50)
                        maxText.TextSize = 12
                        maxText.Font = Enum.Font.GothamBold
                        maxText.TextStrokeTransparency = 0.5
                        maxText.TextStrokeColor3 = Color3.new(0, 0, 0)
                        maxText.Parent = BeehiveReference[beehive].billboard
                    end
                    
                    local frame = BeehiveReference[beehive].billboard:FindFirstChild("Frame")
                    if frame then
                        frame.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
                        frame.BackgroundTransparency = 1 - (BeehiveBackground.Enabled and 0.5 or 0)
                    end
                end
            else
                if isOwn then
                    maxedBeehives[beehive] = nil
                    maxedNotificationSent[beehive] = nil
                end
                
                if BeehiveReference[beehive] and BeehiveReference[beehive].billboard then
                    local maxText = BeehiveReference[beehive].billboard:FindFirstChild("MaxText")
                    if maxText then
                        maxText:Destroy()
                    end
                    
                    local frame = BeehiveReference[beehive].billboard:FindFirstChild("Frame")
                    if frame then
                        frame.BackgroundColor3 = Color3.fromHSV(BeehiveColor.Hue, BeehiveColor.Sat, BeehiveColor.Value)
                        frame.BackgroundTransparency = 1 - (BeehiveBackground.Enabled and BeehiveColor.Opacity or 0)
                    end
                end
            end
            
            if BeehiveReference[beehive] and BeehiveReference[beehive].levelLabel then
                BeehiveReference[beehive].levelLabel.Text = tostring(level)
            end
            
            if BeehiveReference[beehive] then
                BeehiveReference[beehive].isMaxed = isMaxed
            end
        end
        
        updateLevel()
        
        if isOwn then
            Beekeeper:Clean(beehive:GetAttributeChangedSignal("Level"):Connect(updateLevel))
        else
            Beekeeper:Clean(beehive:GetAttributeChangedSignal("Level"):Connect(function()
                local level = beehive:GetAttribute("Level") or 0
                if BeehiveReference[beehive] and BeehiveReference[beehive].levelLabel then
                    BeehiveReference[beehive].levelLabel.Text = tostring(level)
                end
            end))
        end
    end


    local function RemovedBeehive(beehive)
        if BeehiveReference[beehive] then
            BeehiveReference[beehive].billboard:Destroy()
            BeehiveReference[beehive] = nil
        end
    end

    local function setupBeesESP()
        for _, v in collectionService:GetTagged('bee') do
            if v:IsA("Model") and v.PrimaryPart then
                if not v.Name:find("TamedBee") and not v:FindFirstChild("TamedBee") then
                    AddedBee(v.PrimaryPart)
                end
            end
        end

        Beekeeper:Clean(collectionService:GetInstanceAddedSignal('bee'):Connect(function(v)
            if v:IsA("Model") and v.PrimaryPart then
                task.wait(0.1)
                if not v.Name:find("TamedBee") and not v:FindFirstChild("TamedBee") then
                    AddedBee(v.PrimaryPart)
                end
            end
        end))

        Beekeeper:Clean(collectionService:GetInstanceRemovedSignal('bee'):Connect(function(v)
            if v.PrimaryPart then
                RemovedBee(v.PrimaryPart)
            end
        end))
        

    end

    local function setupBeehiveESP()
        for _, beehive in collectionService:GetTagged('beehive') do
            AddedBeehive(beehive)
        end

        Beekeeper:Clean(collectionService:GetInstanceAddedSignal('beehive'):Connect(function(beehive)
            task.wait(0.1)
            AddedBeehive(beehive)
        end))

        Beekeeper:Clean(collectionService:GetInstanceRemovedSignal('beehive'):Connect(function(beehive)
            RemovedBeehive(beehive)
        end))
    end

    local function isHoldingBeeNet()
        if not store.hand or not store.hand.tool then return false end
        return store.hand.tool.Name == 'bee_net' or store.hand.tool.Name == 'bee-net'
    end

    local function startCollection()
        collectionRunning = true
        task.spawn(function()
            while collectionRunning and Beekeeper.Enabled and CollectionToggle.Enabled do
                if not entitylib.isAlive then 
                    task.wait(0.1) 
                    continue 
                end
                
                if LimitToNet.Enabled and not isHoldingBeeNet() then
                    task.wait(0.5)
                    continue
                end
                
                local localPosition = entitylib.character.RootPart.Position
                local range = RangeSlider.Value
                local beesFound = false
                
                for _, v in collectionService:GetTagged('bee') do
                    if not collectionRunning or not Beekeeper.Enabled or not CollectionToggle.Enabled then 
                        break 
                    end
                    
                    if LimitToNet.Enabled and not isHoldingBeeNet() then
                        break
                    end
                    
                    if v:IsA("Model") and v.PrimaryPart then
                        local beePos = v.PrimaryPart.Position
                        local distance = (localPosition - beePos).Magnitude
                        
                        if distance <= range then
                            beesFound = true
                            
                            if CollectionDelay.Enabled and DelaySlider.Value > 0 then
                                task.wait(DelaySlider.Value)
                            end
                            
                            if LimitToNet.Enabled and not isHoldingBeeNet() then
                                break
                            end
                            
                            local beeId = v:GetAttribute('BeeId')
                            if beeId then
                                bedwars.Client:Get(remotes.BeePickup):SendToServer({beeId = beeId})
                                task.wait(0.1)
                            end
                        end
                    end
                end
                
                if not beesFound then
                    task.wait(0.2)
                else
                    task.wait(0.1)
                end
            end
            collectionRunning = false
        end)
    end

    local function startDeposit()
        depositRunning = true
        task.spawn(function()
            while depositRunning and Beekeeper.Enabled and AutoDeposit.Enabled do
                if not entitylib.isAlive then 
                    task.wait(0.1) 
                    continue 
                end
                
                local currentTool = store.hand and store.hand.tool
                if not currentTool or currentTool.Name ~= 'bee' then
                    task.wait(0.1)
                    continue
                end
                
                local localPosition = entitylib.character.RootPart.Position
                local range = DepositRange.Value
                local depositedThisCycle = false
                
                local availableBeehives = {}
                for _, beehive in collectionService:GetTagged('beehive') do
                    if isMyBeehive(beehive) and not maxedBeehives[beehive] then
                        local beehivePos = beehive.Position
                        local distance = (localPosition - beehivePos).Magnitude
                        
                        if distance <= range then
                            table.insert(availableBeehives, {
                                beehive = beehive,
                                distance = distance
                            })
                        end
                    end
                end
                
                table.sort(availableBeehives, function(a, b)
                    return a.distance < b.distance
                end)
                
                for _, beehiveData in ipairs(availableBeehives) do
                    if not depositRunning or not Beekeeper.Enabled or not AutoDeposit.Enabled then 
                        break 
                    end
                    local beehive = beehiveData.beehive
                    if maxedBeehives[beehive] then
                        continue
                    end
                    
                    local prompt = beehive:FindFirstChildOfClass("ProximityPrompt")
                    
                    if prompt and prompt.Enabled then
                        if DepositDelay.Enabled and DepositDelaySlider.Value > 0 then
                            local originalDuration = prompt.HoldDuration
                            prompt.HoldDuration = DepositDelaySlider.Value
                            
                            if fireproximityprompt then
                                fireproximityprompt(prompt)
                            else
                                prompt:InputHoldBegin()
                                task.wait(DepositDelaySlider.Value)
                                prompt:InputHoldEnd()
                            end
                            
                            task.wait(DepositDelaySlider.Value + 0.1)
                            prompt.HoldDuration = originalDuration
                        else
                            if fireproximityprompt then
                                fireproximityprompt(prompt)
                            else
                                prompt:InputHoldBegin()
                                prompt:InputHoldEnd()
                            end
                            task.wait(0.1)
                        end
                        
                        depositedThisCycle = true
                        break 
                    end
                end
                
                if not depositedThisCycle and #availableBeehives > 0 then
                    local allMaxed = true
                    for _, beehiveData in ipairs(availableBeehives) do
                        if not maxedBeehives[beehiveData.beehive] then
                            allMaxed = false
                            break
                        end
                    end
                    
                    if allMaxed then
                        notif("Bee Keeper", "All nearby beehives are full", 3)
                    end
                end
                
                task.wait(depositedThisCycle and 0.3 or 0.2)
            end
            depositRunning = false
        end)
    end

    Beekeeper = vain.Categories.Kit:CreateModule({
        Name = 'Auto Beekeeper',
        Function = function(callback)
            if callback then
                if ESPToggle.Enabled then
                    if BeesESP.Enabled then
                        setupBeesESP()
                    end
                    if BeehiveESP.Enabled then
                        setupBeehiveESP()
                    end
                end
                
                if CollectionToggle.Enabled then
                    startCollection()
                end
                
                if AutoDeposit.Enabled then
                    startDeposit()
                end
                
                local _bkLastUpdate = 0
                Beekeeper:Clean(runService.RenderStepped:Connect(function()
                    if not ESPToggle.Enabled then return end
                    local _now = tick()
                    if _now - _bkLastUpdate < 0.1 then return end
                    _bkLastUpdate = _now
                    
                    for v, billboard in pairs(BeesReference) do
                        if not v or not v.Parent then
                            RemovedBee(v)
                            continue
                        end

                        local shouldShow = true

                        if ESPLimitToNet.Enabled and not isHoldingBeeNet() then
                            shouldShow = false
                        end

                        billboard.Enabled = shouldShow
                    end
                    
                    for beehive, ref in pairs(BeehiveReference) do
                        if not beehive or not beehive.Parent then
                            RemovedBeehive(beehive)
                            continue
                        end

                        local shouldShow = true

                        if ESPLimitToNet.Enabled and not isHoldingBeeNet() then
                            shouldShow = false
                        end

                        if ref.billboard then
                            ref.billboard.Enabled = shouldShow
                        end
                    end
                end))
            else
                collectionRunning = false
                depositRunning = false
                BeesFolder:ClearAllChildren()
                BeehiveFolder:ClearAllChildren()
                table.clear(BeesReference)
                table.clear(BeehiveReference)
                table.clear(spawnQueue)
                lastNotification = 0
            end
        end,
        Tooltip = 'Automatically collects bees and manages beehives'
    })
    
    CollectionToggle = Beekeeper:CreateToggle({
        Name = 'Auto Collect',
        Default = true,
        Tooltip = 'Automatically collect bees',
        Function = function(callback)
            if LimitToNet and LimitToNet.Object then LimitToNet.Object.Visible = callback end
            if CollectionDelay and CollectionDelay.Object then CollectionDelay.Object.Visible = callback end
            if DelaySlider and DelaySlider.Object then DelaySlider.Object.Visible = (callback and CollectionDelay.Enabled) end
            if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = callback end
            
            if callback and Beekeeper.Enabled then
                startCollection()
            else
                collectionRunning = false
            end
        end
    })
    
    LimitToNet = Beekeeper:CreateToggle({
        Name = 'Limit to Net',
        Default = false,
        Tooltip = 'Only collect bees when holding bee net'
    })
    
    CollectionDelay = Beekeeper:CreateToggle({
        Name = 'Collection Delay',
        Default = false,
        Tooltip = 'Add delay before collecting bees',
        Function = function(callback)
            if DelaySlider and DelaySlider.Object then
                DelaySlider.Object.Visible = callback
            end
        end
    })
    
    DelaySlider = Beekeeper:CreateSlider({
        Name = 'Delay',
        Min = 0,
        Max = 2,
        Default = 0.5,
        Decimal = 10,
        Suffix = 's',
        Tooltip = 'Delay in seconds before collecting'
    })
    
    RangeSlider = Beekeeper:CreateSlider({
        Name = 'Range',
        Min = 1, 
        Max = 30,
        Default = 18,
        Decimal = 1,
        Suffix = ' studs',
        Tooltip = 'Control distance you want to collect bees'
    })
    
    ESPToggle = Beekeeper:CreateToggle({
        Name = 'ESP',
        Default = true,
        Tooltip = 'ESP for bees and beehives',
		Function = function(callback)
			if BeesESP and BeesESP.Object then BeesESP.Object.Visible = callback end
			if BeehiveESP and BeehiveESP.Object then BeehiveESP.Object.Visible = callback end
			if ESPLimitToNet and ESPLimitToNet.Object then ESPLimitToNet.Object.Visible = callback end

			if not callback then
				if BeesNotify and BeesNotify.Object then BeesNotify.Object.Visible = false end
				if BeesBackground and BeesBackground.Object then BeesBackground.Object.Visible = false end
				if BeesColor and BeesColor.Object then BeesColor.Object.Visible = false end
				if ShowOtherBeehives and ShowOtherBeehives.Object then ShowOtherBeehives.Object.Visible = false end
				if BeehiveBackground and BeehiveBackground.Object then BeehiveBackground.Object.Visible = false end
				if BeehiveColor and BeehiveColor.Object then BeehiveColor.Object.Visible = false end
			else
				if BeesESP and BeesESP.Enabled then
					if BeesNotify and BeesNotify.Object then BeesNotify.Object.Visible = true end
					if BeesBackground and BeesBackground.Object then BeesBackground.Object.Visible = true end
					if BeesColor and BeesColor.Object then BeesColor.Object.Visible = BeesBackground.Enabled end
				end
				if BeehiveESP and BeehiveESP.Enabled then
					if ShowOtherBeehives and ShowOtherBeehives.Object then ShowOtherBeehives.Object.Visible = true end
					if BeehiveBackground and BeehiveBackground.Object then BeehiveBackground.Object.Visible = true end
					if BeehiveColor and BeehiveColor.Object then BeehiveColor.Object.Visible = BeehiveBackground.Enabled end
				end
			end

			if Beekeeper.Enabled then
				if callback then
					if BeesESP.Enabled then setupBeesESP() end
					if BeehiveESP.Enabled then setupBeehiveESP() end
				else
					BeesFolder:ClearAllChildren()
					BeehiveFolder:ClearAllChildren()
					table.clear(BeesReference)
					table.clear(BeehiveReference)
				end
			end
		end
    })
    
    ESPLimitToNet = Beekeeper:CreateToggle({
        Name = 'Limit to Net',
        Default = false,
        Tooltip = 'Only show ESP when holding bee net'
    })
    
    BeesESP = Beekeeper:CreateToggle({
        Name = 'Bees',
        Default = false,
        Tooltip = 'Show bee locations',
        Function = function(callback)
            if BeesNotify and BeesNotify.Object then BeesNotify.Object.Visible = callback end
            if BeesBackground and BeesBackground.Object then BeesBackground.Object.Visible = callback end
            if BeesColor and BeesColor.Object then BeesColor.Object.Visible = callback end
            
            if Beekeeper.Enabled and ESPToggle.Enabled then
                if callback then setupBeesESP() else
                    BeesFolder:ClearAllChildren()
                    table.clear(BeesReference)
                end
            end
        end
    })
    
    BeesNotify = Beekeeper:CreateToggle({
        Name = 'Notify',
        Default = false,
        Tooltip = 'Get notifications when bees spawn'
    })
    
    BeesBackground = Beekeeper:CreateToggle({
        Name = 'Background',
        Tooltip = 'Renders a background box behind the bee count icon',
        Default = true,
        Function = function(callback)
            if BeesColor and BeesColor.Object then BeesColor.Object.Visible = callback end
            for _, v in BeesReference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundTransparency = 1 - (callback and BeesColor.Opacity or 0)
                    if v:FindFirstChild("Blur") then
                        v.Blur.Visible = callback
                    end
                end
            end
        end
    })
    
	BeesColor = Beekeeper:CreateColorSlider({
		Name = 'Background Color',
		Tooltip = 'Color of the background box behind the bee count icon',
		DefaultValue = 0,
		DefaultOpacity = 0.5,
		Function = function(hue, sat, val, opacity)
			for _, v in BeesReference do
				if v and v:FindFirstChild("ImageLabel") then
					v.ImageLabel.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
					v.ImageLabel.BackgroundTransparency = 1 - opacity
				end
			end
		end,
		Darker = true
	})
    
    BeehiveESP = Beekeeper:CreateToggle({
        Name = 'Beehives',
        Default = false,
        Tooltip = 'Show your beehive locations with bee count',
        Function = function(callback)
            if ShowOtherBeehives and ShowOtherBeehives.Object then ShowOtherBeehives.Object.Visible = callback end
            if BeehiveBackground and BeehiveBackground.Object then BeehiveBackground.Object.Visible = callback end
            if BeehiveColor and BeehiveColor.Object then BeehiveColor.Object.Visible = callback end
            
            if Beekeeper.Enabled and ESPToggle.Enabled then
                if callback then setupBeehiveESP() else
                    BeehiveFolder:ClearAllChildren()
                    table.clear(BeehiveReference)
                end
            end
        end
    })
    
    ShowOtherBeehives = Beekeeper:CreateToggle({
        Name = 'Show Others',
        Default = false,
        Tooltip = 'Show other players\' beehives with their usernames',
        Function = function(callback)
            if Beekeeper.Enabled and ESPToggle.Enabled and BeehiveESP.Enabled then
                BeehiveFolder:ClearAllChildren()
                table.clear(BeehiveReference)
                setupBeehiveESP()
            end
        end
    })
    
    BeehiveBackground = Beekeeper:CreateToggle({
        Name = 'Beehive Background',
        Tooltip = 'Renders a background box behind the beehive ESP element',
        Default = true,
        Function = function(callback)
            if BeehiveColor and BeehiveColor.Object then BeehiveColor.Object.Visible = callback end
            for _, ref in BeehiveReference do
                if ref and ref.billboard then
                    local frame = ref.billboard:FindFirstChild("Frame")
                    if frame then
                        if ref.isMaxed and ref.isOwn then
                            frame.BackgroundTransparency = 1 - (callback and 0.5 or 0)
                        else
                            frame.BackgroundTransparency = 1 - (callback and BeehiveColor.Opacity or 0)
                        end
                    end
                    if ref.billboard:FindFirstChild("Blur") then
                        ref.billboard.Blur.Visible = callback
                    end
                end
            end
        end
    })
    
    BeehiveColor = Beekeeper:CreateColorSlider({
        Name = 'Beehive Color',
        Tooltip = 'Color of the background box behind the beehive ESP element',
        DefaultValue = 0,
        DefaultOpacity = 0.5,
        Function = function(hue, sat, val, opacity)
            for _, ref in BeehiveReference do
                if ref and ref.billboard then
                    local frame = ref.billboard:FindFirstChild("Frame")
                    if frame and not (ref.isMaxed and ref.isOwn) then
                        frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                        frame.BackgroundTransparency = 1 - opacity
                    end
                end
            end
        end,
        Darker = true
    })
    
    AutoDeposit = Beekeeper:CreateToggle({
        Name = 'Auto Deposit',
        Default = false,
        Tooltip = 'Automatically deposit bees into your beehives',
		Function = function(callback)
			if DepositDelay and DepositDelay.Object then DepositDelay.Object.Visible = callback end
			if DepositDelaySlider and DepositDelaySlider.Object then DepositDelaySlider.Object.Visible = (callback and DepositDelay.Enabled) end
			if DepositRange and DepositRange.Object then DepositRange.Object.Visible = callback end
			
			if not callback then
				if DepositDelaySlider and DepositDelaySlider.Object then DepositDelaySlider.Object.Visible = false end
			end

			if callback and Beekeeper.Enabled then
				startDeposit()
			else
				depositRunning = false
			end
		end
    })
    
    DepositDelay = Beekeeper:CreateToggle({
        Name = 'Deposit Delay',
        Default = false,
        Tooltip = 'Add delay before depositing bees',
        Function = function(callback)
            if DepositDelaySlider and DepositDelaySlider.Object then
                DepositDelaySlider.Object.Visible = callback
            end
        end
    })
    
    DepositDelaySlider = Beekeeper:CreateSlider({
        Name = 'Deposit Delay',
        Min = 0,
        Max = 2,
        Default = 0.5,
        Decimal = 10,
        Suffix = 's',
        Tooltip = 'Delay in seconds before depositing'
    })
    
    DepositRange = Beekeeper:CreateSlider({
        Name = 'Deposit Range',
        Min = 1,
        Max = 15,
        Default = 10,
        Decimal = 1,
        Suffix = ' studs',
        Tooltip = 'Range to deposit bees into beehives'
    })
	task.defer(function()
		if DelaySlider and DelaySlider.Object then DelaySlider.Object.Visible = CollectionDelay.Enabled end
		if not ESPToggle.Enabled or not BeesESP.Enabled then
			if BeesNotify and BeesNotify.Object then BeesNotify.Object.Visible = false end
			if BeesBackground and BeesBackground.Object then BeesBackground.Object.Visible = false end
			if BeesColor and BeesColor.Object then BeesColor.Object.Visible = false end
		else
			if BeesColor and BeesColor.Object then BeesColor.Object.Visible = BeesBackground.Enabled end
		end

		if not ESPToggle.Enabled or not BeehiveESP.Enabled then
			if ShowOtherBeehives and ShowOtherBeehives.Object then ShowOtherBeehives.Object.Visible = false end
			if BeehiveBackground and BeehiveBackground.Object then BeehiveBackground.Object.Visible = false end
			if BeehiveColor and BeehiveColor.Object then BeehiveColor.Object.Visible = false end
		else
			if BeehiveColor and BeehiveColor.Object then BeehiveColor.Object.Visible = BeehiveBackground.Enabled end
		end

		if AutoDeposit and not AutoDeposit.Enabled then
			if DepositDelay and DepositDelay.Object then DepositDelay.Object.Visible = false end
			if DepositDelaySlider and DepositDelaySlider.Object then DepositDelaySlider.Object.Visible = false end
			if DepositRange and DepositRange.Object then DepositRange.Object.Visible = false end
		end

		if DepositDelaySlider and DepositDelaySlider.Object then
			DepositDelaySlider.Object.Visible = (AutoDeposit.Enabled and DepositDelay.Enabled)
		end
	end)
end)

run(function()
    local AutoBuilder
    local Animation
    local Blacklist
    local BedCheck
    local Limit

    local function getBedNear(pos)
    	local bed, lastmag = nil, math.huge
    	local localPosition = pos or Vector3.zero
    	for _, v in collectionService:GetTagged('bed') do
    		local mag = (localPosition - v.Position).Magnitude
    		if mag < lastmag and v:GetAttribute('Team' .. (lplr:GetAttribute('Team') or -1) .. 'NoBreak') then
    			bed = v
    			lastmag = mag
    		end
    	end
    	return bed, lastmag
    end

    AutoBuilder = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Builder',
    	Tooltip = 'Automatically builds a preset structure',
    	Function = function(callback)
    		if callback then
    			repeat
    				task.wait()
    			until store.matchState ~= 0 and store.equippedKit == 'builder' or not AutoBuilder.Enabled
    			if not AutoBuilder.Enabled then
    				return
    			end

    			local bed = getBedNear(entitylib.character.RootPart.Position)
    			local blocks = collection('block', AutoBuilder, function(tab, obj)
    				task.delay(0, function()
    					if obj and not obj:GetAttribute('NoBreak') and obj:GetAttribute('PlacedByUserId') ~= nil then
    						table.insert(tab, obj)
    					end
    				end)
    			end)
    			repeat
    				if entitylib.isAlive and (not Limit.Enabled and getItem('hammer') or Limit.Enabled and store.hand.tool and store.hand.tool.Name == 'hammer') then
    					bed = getBedNear(entitylib.character.RootPart.Position)

    					for _, v in blocks do
    						if not BedCheck.Enabled or (bed.Position - v.Position).Magnitude <= 30 then
    							local name = v.Name
    							if name:find('wool_') then
    								name = 'wool'
    							end
    							if not table.find(Blacklist.ListEnabled, name) and not v:FindFirstChild('BuilderFortify') then
    								bedwars.Client:Get('FortifyBlock'):SendToServer(({getPlacedBlock(v.Position)})[2])
    								if Animation.Enabled then
    									bedwars.GameAnimationUtil:playAnimation(lplr, bedwars.GameAnimationUtil:getAssetId(bedwars.AnimationType.BUILDER_HAMMER_HIT), {
    										fadeInTime = 0.02
    									})
                						bedwars.SoundManager:playSound(bedwars.SoundList.FORTIFY_BLOCK,lplr.Character.HumanoidRootPart.Position)
    								end
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoBuilder.Enabled
    		end
    	end
    })

    BedCheck = AutoBuilder:CreateToggle({
    	Name = 'Bed Check',
    	Tooltip = 'Checks if the block is near your bed'
    })
    Animation = AutoBuilder:CreateToggle({
    	Name = 'Animation',
    	Default = true,
    	Tooltip = 'Plays builder visuals (sfx and anim)'
    })
    Limit = AutoBuilder:CreateToggle({
    	Name = 'Limit to items',
    	Tooltip = 'Only activates when a required item is in your hand',
    	Default = true
    })
    Blacklist = AutoBuilder:CreateTextList({
    	Name = 'Blacklists',
    	Tooltip = 'Block types to skip when auto-building (one per line)',
    	Placeholder = 'block',
    	Default = {'cannon', 'wool'}
    })
end)

run(function()
    local Caitlyn
    local MethodDropdown
    local LowHealthSlider
    local ExecuteRangeSlider
    local HitRangeSlider
    local ProximityRangeSlider
    local connections = {}
    local Players = playersService
    local lplr = Players.LocalPlayer
    local currentTarget = nil
    local lastHitTime = 0
    local lastContractSelect = 0
    
    local function selectContract(targetPlayer)
        if not entitylib.isAlive then return false end
        if tick() - lastContractSelect < 0.1 then return false end
        
        local storeState = bedwars.Store:getState()
        local activeContract = storeState.Kit.activeContract
        local availableContracts = storeState.Kit.availableContracts or {}
        
        if activeContract then return false end
        if #availableContracts == 0 then return false end
        
        for _, contract in pairs(availableContracts) do
            if contract.target and contract.target.Name == targetPlayer.Name then
                bedwars.Client:Get('BloodAssassinSelectContract'):SendToServer({
                    contractId = contract.id
                })
                lastContractSelect = tick()
                return true
            end
        end
        return false
    end
    
    local function executeOnLowHealth()
        if not currentTarget or tick() - lastHitTime > 3 then
            currentTarget = nil
            return
        end
        
        if not currentTarget.Character then return end
        
        local humanoid = currentTarget.Character:FindFirstChild("Humanoid")
        local rootPart = currentTarget.Character:FindFirstChild("HumanoidRootPart")
        
        if humanoid and rootPart and lplr.Character and lplr.Character:FindFirstChild("HumanoidRootPart") then
            local health = humanoid.Health
            local distance = (lplr.Character.HumanoidRootPart.Position - rootPart.Position).Magnitude
            
            if health > 0 and health <= LowHealthSlider.Value and distance <= ExecuteRangeSlider.Value then
                selectContract(currentTarget)
            end
        end
    end
    
    local function contractOnHit()
        if not currentTarget or tick() - lastHitTime > 0.5 then
            currentTarget = nil
            return
        end
        
        if not currentTarget.Character then return end
        
        local rootPart = currentTarget.Character:FindFirstChild("HumanoidRootPart")
        
        if rootPart and lplr.Character and lplr.Character:FindFirstChild("HumanoidRootPart") then
            local distance = (lplr.Character.HumanoidRootPart.Position - rootPart.Position).Magnitude
            
            if distance <= HitRangeSlider.Value then
                selectContract(currentTarget)
            end
        end
    end
    
    local function proximityContract()
        if not entitylib.isAlive then return end
        
        local myRoot = lplr.Character and lplr.Character:FindFirstChild("HumanoidRootPart")
        if not myRoot then return end
        
        local closestPlayer = nil
        local closestDistance = ProximityRangeSlider.Value
        
        for _, player in pairs(Players:GetPlayers()) do
            if player ~= lplr and player.Character then
                local theirRoot = player.Character:FindFirstChild("HumanoidRootPart")
                local humanoid = player.Character:FindFirstChild("Humanoid")
                
                if theirRoot and humanoid and humanoid.Health > 0 then
                    local distance = (myRoot.Position - theirRoot.Position).Magnitude
                    
                    if distance < closestDistance then
                        closestDistance = distance
                        closestPlayer = player
                    end
                end
            end
        end
        
        if closestPlayer then
            selectContract(closestPlayer)
        end
    end
    
    Caitlyn = vain.Categories.Kit:CreateModule({
        Name = 'Auto Caitlyn',
        Function = function(callback)
            if callback then
                local damageConnection = vainEvents.EntityDamageEvent.Event:Connect(function(damageTable)
                    if not entitylib.isAlive then return end
                    
                    local attacker = playersService:GetPlayerFromCharacter(damageTable.fromEntity)
                    local victim = playersService:GetPlayerFromCharacter(damageTable.entityInstance)
                
                    if attacker == lplr and victim and victim ~= lplr then
                        currentTarget = victim
                        lastHitTime = tick()
                    end
                end)
                table.insert(connections, damageConnection)
                
                task.spawn(function()
                    repeat
                        if entitylib.isAlive then
                            local method = MethodDropdown.Value
                            
                            if method == "Execute on Low HP" then
                                executeOnLowHealth()
                            elseif method == "Contract on Hit" then
                                contractOnHit()
                            elseif method == "Proximity Select" then
                                proximityContract()
                            end
                        end
                        task.wait(0.1)
                    until not Caitlyn.Enabled
                end)
            else
                for _, conn in pairs(connections) do
                    if typeof(conn) == "RBXScriptConnection" then
                        conn:Disconnect()
                    end
                end
                table.clear(connections)
                
                currentTarget = nil
                lastHitTime = 0
            end
        end,
        Tooltip = 'Auto contract selection for Caitlyn'
    })
    
    MethodDropdown = Caitlyn:CreateDropdown({
        Name = 'Method',
        List = {"Execute on Low HP", "Contract on Hit", "Proximity Select"},
        Default = "Execute on Low HP",
        Tooltip = 'Contract selection method',
        Function = function(value)
            LowHealthSlider.Object.Visible = (value == "Execute on Low HP")
            ExecuteRangeSlider.Object.Visible = (value == "Execute on Low HP")
            HitRangeSlider.Object.Visible = (value == "Contract on Hit")
            ProximityRangeSlider.Object.Visible = (value == "Proximity Select")
        end
    })
    
    LowHealthSlider = Caitlyn:CreateSlider({
        Name = 'Select HP',
        Min = 10,
        Max = 100,
        Default = 30,
        Tooltip = 'HP value to execute contract'
    })
    
    ExecuteRangeSlider = Caitlyn:CreateSlider({
        Name = 'Select Range',
        Min = 5,
        Max = 50,
        Default = 20,
        Suffix = ' studs',
        Tooltip = 'Range to select contract'
    })
    
    HitRangeSlider = Caitlyn:CreateSlider({
        Name = 'Hit Range',
        Min = 10,
        Max = 200,
        Default = 100,
        Suffix = ' studs',
        Tooltip = 'Max range to select a contract when hitting the player'
    })
    
    ProximityRangeSlider = Caitlyn:CreateSlider({
        Name = 'Proximity Range',
        Min = 10,
        Max = 200,
        Default = 50,
        Suffix = ' studs',
        Tooltip = 'Range to auto select nearby players'
    })
    
    LowHealthSlider.Object.Visible = true
    ExecuteRangeSlider.Object.Visible = true
    HitRangeSlider.Object.Visible = false
    ProximityRangeSlider.Object.Visible = false
end)

run(function()
    local AutoDavey
    local Switch
    local Break
    local Jump
    local Limit
    local IncludeWood

    local old

    local function holdingPickaxe()
        local tool = store.hand and store.hand.tool
        if tool == nil or tool.Name == nil or not tool.Name:find('pickaxe') then
            return false
        end
        if tool.Name == 'wood_pickaxe' then
            return IncludeWood.Enabled
        end
        return true
    end

    AutoDavey = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Davey',
    	Tooltip = 'Automates the Davey kit cannon',
    	Function = function(call)
    		if call then
    			old = bedwars.CannonHandController.launchSelf
    			bedwars.CannonHandController.launchSelf = function(...)
    				local res = { old(...) }
    				local block = select(2, ...)

    				if Break.Enabled and (not Limit.Enabled or holdingPickaxe()) then
    					if (block.Position - entitylib.character.RootPart.Position).Magnitude <= 30 then
    						task.delay(0.05, function()
    							for i = 1, 2 do
    								task.spawn(bedwars.breakBlock, block, false, nil, true, nil, Switch.Enabled)
    							end
    						end)
    					end
    				end

    				if Jump.Enabled then
    					lplr.Character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
    				end

    				return unpack(res)
    			end
    		else
    			bedwars.CannonHandController.launchSelf = old
    		end
    	end,
    	Tooltip = 'Automatically breaks cannon/jump on launch'
    })

    Jump = AutoDavey:CreateToggle({Name = 'Jump on impact', Tooltip = 'Jumps when the ability makes contact'})
    Break = AutoDavey:CreateToggle({Name = 'Break on impact', Tooltip = 'Breaks the item on impact with a surface'})
    Switch = AutoDavey:CreateToggle({Name = 'Legit switch', Tooltip = 'Switches to a more legit-looking mode automatically'})
    Limit = AutoDavey:CreateToggle({Name = 'Limit to Item', Tooltip = 'Only breaks the cannon block while a pickaxe is held'})
    IncludeWood = AutoDavey:CreateToggle({Name = 'Include Wood Pickaxe', Tooltip = 'Counts the wood pickaxe as a valid item for Limit to Item'})
end)

run(function()
    local AutoDrill
    local AutoCollect
    local Notify
    local AutoAttack
    local Legit
    local Range
    local AttackDelay
    local CollectDelay
    local Targets
    local Sort
    local currentDrill
    local attackDebounce = {}
    local collectDebounce = {}

    local function getDrillPart(drill)
    	return drill and (drill.PrimaryPart or drill:FindFirstChild('RootPart') or drill:FindFirstChildWhichIsA('BasePart'))
    end

    local function addDrill(drills, added, drill)
    	if typeof(drill) ~= 'Instance' or added[drill] or drill:GetAttribute('PlacedByUserId') ~= lplr.UserId then
    		return
    	end
    	if getDrillPart(drill) then
    		added[drill] = true
    		table.insert(drills, drill)
    	end
    end

    local function getDrills(tagged)
    	local drills, added = {}, {}
    	for _, drill in tagged do
    		addDrill(drills, added, drill)
    	end

    	for _, drill in (bedwars.DrillTabletController and bedwars.DrillTabletController.drillList or {}) do
    		addDrill(drills, added, drill)
    	end

    	return drills
    end

    local function getResourceAmount(drill)
    	return (drill:GetAttribute('diamond') or 0) + (drill:GetAttribute('emerald') or 0)
    end

    local function collectDrill(drill)
    	local suc = pcall(function()
    		bedwars.Client:Get('ExtractFromDrill'):SendToServer({
    			drill = drill,
    		})
    	end)
    	return suc
    end

    local function useDrill(drill)
    	if currentDrill == drill then
    		return true
    	end

    	local suc, res = pcall(function()
    		return bedwars.Client:Get('PlayerUseDrillController'):CallServer({
    			drill = drill,
    		})
    	end)

    	if suc and res ~= false then
    		currentDrill = drill
    		return true
    	end

    	return false
    end

    local function attackDrill(drill, target)
    	if not useDrill(drill) then
    		return false
    	end

    	local suc = pcall(function()
    		bedwars.Client:Get('DrillAttack'):SendToServer({
    			targetPosition = target.RootPart.Position,
    		})
    	end)
    	return suc
    end

    local function getTarget(position)
    	return entitylib.EntityPosition({
    		Origin = position,
    		Range = Legit.Enabled and 10 or Range.Value,
    		Part = 'RootPart',
    		Players = Targets.Players.Enabled,
    		NPCs = Targets.NPCs.Enabled,
    		Sort = sortmethods[Sort.Value],
    	})
    end

    local function updateAttackControls()
    	pcall(function()
    		local enabled = AutoAttack.Enabled
    		Legit.Object.Visible = enabled
    		Range.Object.Visible = enabled and not Legit.Enabled
    		AttackDelay.Object.Visible = enabled
    		Targets.Object.Visible = enabled
    		Sort.Object.Visible = enabled
    	end)
    end

    AutoDrill = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Drill',
    	Tooltip = 'Automates the Drill kit — drills and collects automatically',
    	Function = function(callback)
    		if callback then
    			local tagged = collection('Drill', AutoDrill)
    			repeat
    				task.wait()
    			until store.matchState ~= 0 and store.equippedKit == 'drill' or not AutoDrill.Enabled

    			repeat
    				if entitylib.isAlive and store.equippedKit == 'drill' then
    					local now = tick()
    					for _, drill in getDrills(tagged) do
    						local part = getDrillPart(drill)
    						if not part then
    							continue
    						end

    						if
    							AutoCollect.Enabled
    							and getResourceAmount(drill) > 0
    							and now > (collectDebounce[drill] or 0)
    						then
    							if collectDrill(drill) and Notify.Enabled then
    								notif('Auto Drill', 'Collected drill resources', 4, 'info')
    							end
    							collectDebounce[drill] = now + CollectDelay.Value
    						end

    						if AutoAttack.Enabled and now > (attackDebounce[drill] or 0) then
    							local target = getTarget(part.Position)
    							if target then
    								targetinfo.Targets[target] = tick() + 1
    								if attackDrill(drill, target) then
    									attackDebounce[drill] = now + AttackDelay.Value
    								end
    							end
    						end
    					end
    				end

    				task.wait(0.1)
    			until not AutoDrill.Enabled
    		else
    			currentDrill = nil
    			table.clear(attackDebounce)
    			table.clear(collectDebounce)
    		end
    	end,
    	Tooltip = 'Automatically collects resources and attacks with placed drills.'
    })
    AutoCollect = AutoDrill:CreateToggle({
    	Name = 'Auto collect',
    	Tooltip = 'Automatically collects drill output',
    	Default = true,
    	Function = function(callback)
    		pcall(function()
    			Notify.Object.Visible = callback
    			CollectDelay.Object.Visible = callback
    		end)
    	end
    })
    Notify = AutoDrill:CreateToggle({
    	Name = 'Notify on collect',
    	Tooltip = 'Sends a notification when drill output is collected',
    	Darker = true
    })
    AutoAttack = AutoDrill:CreateToggle({
    	Name = 'Auto attack',
    	Tooltip = 'Automatically attacks with the kit weapon',
    	Default = true,
    	Function = updateAttackControls
    })
    Range = AutoDrill:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 10,
    	Default = 10,
    	Suffix = function(value)
    		return value == 1 and 'stud' or 'studs'
    	end
    })
    Legit = AutoDrill:CreateToggle({
    	Name = 'Legit Range',
    	Tooltip = 'Restricts range to a value indistinguishable from vanilla',
    	Default = true,
    	Function = updateAttackControls
    })
    AttackDelay = AutoDrill:CreateSlider({
    	Name = 'Attack delay',
    	Tooltip = 'Seconds between consecutive attacks',
    	Min = 0.1,
    	Max = 1,
    	Default = 0.3,
    	Decimal = 100,
    	Suffix = function(value)
    		return value == 1 and 'sec' or 'secs'
    	end
    })
    CollectDelay = AutoDrill:CreateSlider({
    	Name = 'Collect delay',
    	Tooltip = 'Seconds between collection attempts',
    	Min = 0.1,
    	Max = 3,
    	Default = 0.5,
    	Decimal = 10,
    	Suffix = function(value)
    		return value == 1 and 'sec' or 'secs'
    	end
    })
    Targets = AutoDrill:CreateTargets({
    	Tooltip = 'Configure which types of targets to include',
    	Players = true,
    	NPCs = false
    })
    local methods = {'Distance', 'Health', 'Damage'}
    for name in sortmethods do
    	if not table.find(methods, name) then
    		table.insert(methods, name)
    	end
    end
    Sort = AutoDrill:CreateDropdown({
    	Name = 'Sort',
    	Tooltip = 'Selects how targets are sorted/prioritized',
    	List = methods,
    	Default = 'Distance',
    	ItemTooltips = {
    		Distance = 'Targets the closest enemy by stud distance',
    		Health = 'Targets the enemy with the lowest remaining health',
    		Angle = 'Targets the enemy closest to your look direction',
    		Cursor = 'Targets the enemy nearest to your mouse cursor',
    		Damage = 'Targets the enemy who most recently took damage',
    		Threat = 'Targets the enemy judged to be the greatest combat threat',
    		Kit = 'Prioritizes dangerous kit users (Hannah, Spirit Assassin, etc.)',
    	}
    })
    updateAttackControls()
end)

run(function()
    local AutoElder
    local Streamer
    local Range
    local Animation
    local Delay

    AutoElder = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Elder',
    	Tooltip = 'Automates the Elder kit ability',
    	Function = function(call)
    		if call then
    			AutoElder:Clean(proximityPromptService.PromptShown:Connect(function(prompt)
    				if Streamer.Enabled and prompt.Name == 'treeOrb' then
    					task.delay(0.1, prompt.InputHoldBegin, prompt)
    				end
    			end))

    			repeat
    				if not Streamer.Enabled and entitylib.isAlive then
    					local localPosition = entitylib.character.RootPart.Position
    					for i, v in collectionService:GetTagged('treeOrb') do
    						if tick() > (Delay[v] or 0) and (localPosition - v.Spirit.Position).Magnitude <= Range.Value then
    							if Delay.Value > 0 then
    								task.wait(Delay.Value)
    							end

    							if (localPosition - v.Spirit.Position).Magnitude <= Range.Value then
    								if Animation.Enabled then
    									bedwars.GameAnimationUtil:playAnimation(lplr.Character, bedwars.AnimationType.PUNCH)
    									bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_USE_ITEM)
    									bedwars.SoundManager:playSound(bedwars.SoundList.CROP_HARVEST)
    								end
    								if bedwars.Client:Get(remotes.ConsumeTreeOrb):CallServer({treeOrbSecret = v:GetAttribute('TreeOrbSecret')}) then
    									v:Destroy()
    								end
    								Delay[v] = tick() + 1
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoElder.Enabled
    		end
    	end,
    	Tooltip = 'Automatically collects tree orbs'
    })

    Streamer = AutoElder:CreateToggle({
    	Name = 'Streamer mode',
    	Tooltip = 'Hides delay, range, and animation settings from the UI — useful for streaming',
    	Function = function(call)
    		pcall(function()
    			Delay.Object.Visible = not call
    			Range.Object.Visible = not call
    			Animation.Object.Visible = not call
    		end)
    	end
    })
    Animation = AutoElder:CreateToggle({
    	Name = 'Animation',
    	Default = true,
    	Tooltip = 'Plays the collect animation'
    })
    Range = AutoElder:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 20,
    	Default = 12,
    	Suffix = function(val)
    		return val > 1 and 'studs' or 'stud'
    	end
    })
    Delay = AutoElder:CreateSlider({
    	Name = 'Delay',
    	Tooltip = 'Seconds between consecutive actions',
    	Min = 0,
    	Max = 1,
    	Suffix = function(val)
    		return val > 1 and 'secs' or 'sec'
    	end,
    	Default = 0.2,
    	Decimal = 100
    })
end)

run(function()
	local AutoEmber
	local Targets
	local Range
	local SpinCooldown
	local Limit
	local old = os.clock()+ 0.00000000000000000000013
	local isCharging = false
	local chargeAnim, FpChargeAnim = nil,nil
	AutoEmber = vain.Categories.Kit:CreateModule({
		Name = 'Auto Ember',
		Tooltip = 'automatically uses the ember ability',
		Function = function(call)
			if call then
				repeat
					if entitylib.isAlive then 
						local tool = getItem('infernal_saber') 
						if tool and (not Limit.Enabled or store.hand.tool and store.hand.tool.Name == 'infernal_saber') then
							local ent = entitylib.EntityPosition({
								Range = HoldRange.Value,
								Players = Targets.Players.Enabled,
								NPCs = Targets.NPCs.Enabled,
								Part = 'RootPart'
							}) 

							if not ent then
								if isCharging then
									isCharging = false
									bedwars.HellSaberController.animationMaid:DoCleaning()
									chargeAnim = nil
									FpChargeAnim = nil
									task.wait(0.3)
									continue
								end
							end

							if ent then
								if not isCharging then
									isCharging = true
									bedwars.HellSaberController:playChargeSound(lplr)
									local animer = lplr.Character
									if animer ~= nil then
										animer = animer:FindFirstChild("Humanoid")
										if animer ~= nil then
											animer = animer:FindFirstChild("Animator")
										end
									end
									if not animer then
										return nil
									end
									chargeAnim = animer:LoadAnimation(bedwars.GameAnimationUtil:getAnimation(bedwars.AnimationType.INFERNO_SWORD_CHARGE))
									chargeAnim:Play()
									chargeAnim:AdjustSpeed(1.83)
									chargeAnim:GetMarkerReachedSignal("end"):Connect(function()
										local newChargeAnim = chargeAnim
										if newChargeAnim ~= nil then
											newChargeAnim:AdjustSpeed(0)
										end
									end)
									FpChargeAnim = bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_INFERNO_SWORD_CHARGE)
									if FpChargeAnim then
										FpChargeAnim:GetMarkerReachedSignal("end"):Connect(function()
											local newFpChargeAnim = FpChargeAnim
											if newFpChargeAnim ~= nil then
												newFpChargeAnim:AdjustSpeed(0)
											end
										end)
									end
									bedwars.HellSaberController.animationMaid:GiveTask(function()
										local MaidCA1 = chargeAnim
										if MaidCA1 ~= nil then
											MaidCA1:Stop()
										end
										local MaidCA2 = chargeAnim
										if MaidCA2 ~= nil then
											MaidCA2:Destroy()
										end
										local MaidFCA1 = FpChargeAnim
										if MaidFCA1 ~= nil then
											MaidFCA1:Stop()
										end
										local MaidFCA2 = FpChargeAnim
										if MaidFCA2 ~= nil then
											MaidFCA2:Destroy()
										end
									end)
								end
								local DeltaPos = (ent.RootPart.Position - lplr.Character.HumanoidRootPart.Position).Magnitude
								if DeltaPos <= Range.Value then
									local now = os.clock() + 0.00000000000000000000013
									if (now - old) >= SpinCooldown.Value then
										bedwars.HellSaberController.animationMaid:DoCleaning()
										if not Limit.Enabled then
											switchItem(tool)
										end
										bedwars.Client:Get('HellBladeRelease'):SendToServer({
											chargeTime = 1 + tick() - (0.045 + (math.random() - math.random())), 
											weapon = tool,
											player = lplr
										})
										old = os.clock() + 0.00000000000000000000013
										bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_INFERNO_SWORD_SPIN)										
										isCharging = false
										
									end
								end
							end
						end
					end
					task.wait(0.1)
				until not AutoEmber.Enabled 
			end
		end
	})
	Targets = AutoEmber:CreateTargets({
		Players = true,
		NPCs = false
	})
	SpinCooldown = AutoEmber:CreateSlider({
		Name = 'Spin Cooldown',
		Min = 0,
		Max = 4,
		Default = 1.12,
		Decimal = 100,
		Tooltip = 'Anything below 0.2 will most likely get you banned if you get clipped'
	})
	Range = AutoEmber:CreateSlider({
		Name = 'Release Range',
		Tooltip = 'Distance at which the spin attack is released on a target',
		Min = 1,
		Max = 22,
		Default = 22,
		Suffix = function(val)
			return val <= 1 and 'stud' or 'studs'
		end
	})
	HoldRange = AutoEmber:CreateSlider({
		Name = 'Hold Range',
		Tooltip = 'Distance at which the spin attack starts charging',
		Min = 1,
		Max = 48,
		Default = 32,
		Suffix = function(val)
			return val <= 1 and 'stud' or 'studs'
		end
	})
	Limit = AutoEmber:CreateToggle({Name = 'Limit to item', Tooltip = 'Only works while the Ember weapon is equipped'})
end)

run(function()
    local AutoGingerbread
    local Range
    local Delay
    local Break
    local Jump
    local Switch
    local OwnOnly
    local SuccessfulOnly

    local old
    local hook

    local function canUseBlock(block)
    	if not entitylib.isAlive or typeof(block) ~= 'Instance' or not block:IsA('BasePart') then
    		return false
    	end

    	if store.equippedKit ~= 'gingerbread_man' then
    		return false
    	end

    	if OwnOnly.Enabled and block:GetAttribute('PlacedByUserId') ~= lplr.UserId then
    		return false
    	end

    	return (block.Position - entitylib.character.RootPart.Position).Magnitude <= Range.Value
    end

    AutoGingerbread = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Gingerbread Man',
    	Tooltip = 'Automates Gingerbread Man kit launch pads',
    	Function = function(callback)
    		if callback then
    			old = bedwars.LaunchPadController.attemptLaunch
    			hook = function(...)
    				local controller, block = ...
    				local lastLaunch = controller and controller.lastLaunch or 0

    				if not SuccessfulOnly.Enabled or (controller and controller.lastLaunch and (controller.lastLaunch ~= lastLaunch or workspace:GetServerTimeNow() - controller.lastLaunch < 0.5)) then
    					if Break.Enabled and canUseBlock(block) then
    						task.delay(Delay.Value, bedwars.breakBlock, block, false, nil, true, nil, Switch.Enabled)
    					end

    					if Jump.Enabled and entitylib.isAlive then
    						lplr.Character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
    					end
    				end

    				return old(...)
    			end
    			bedwars.LaunchPadController.attemptLaunch = hook
    		elseif old then
    			if bedwars.LaunchPadController.attemptLaunch == hook then
    				bedwars.LaunchPadController.attemptLaunch = old
    			end
    			old = nil
    			hook = nil
    		end
    	end,
    	Tooltip = 'Automatically handles Gingerbread Man launch pads.'
    })

    Break = AutoGingerbread:CreateToggle({
    	Name = 'Break launch pad',
    	Tooltip = 'Automatically breaks used launch pads',
    	Default = true,
    	Function = function(call)
    		pcall(function()
    			Range.Object.Visible = call
    			Delay.Object.Visible = call
    			Switch.Object.Visible = call
    			OwnOnly.Object.Visible = call
    		end)
    	end
    })
    Jump = AutoGingerbread:CreateToggle({Name = 'Jump after launch', Tooltip = 'Jumps immediately after being launched by a pad'})
    Switch = AutoGingerbread:CreateToggle({
    	Name = 'Legit switch',
    	Tooltip = 'Switches to a more legit-looking mode automatically',
    	Darker = true
    })
    OwnOnly = AutoGingerbread:CreateToggle({
    	Name = 'Own pads only',
    	Tooltip = 'Only activates on launch pads you placed yourself',
    	Default = true,
    	Darker = true
    })
    SuccessfulOnly = AutoGingerbread:CreateToggle({
    	Name = 'Successful launch only',
    	Tooltip = 'Only activates after a confirmed successful launch',
    	Default = true
    })
    Range = AutoGingerbread:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 30,
    	Default = 30,
    	Darker = true,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end
    })
    Delay = AutoGingerbread:CreateSlider({
    	Name = 'Break delay',
    	Tooltip = 'Seconds between break attempts',
    	Min = 0,
    	Max = 1,
    	Default = 0.05,
    	Decimal = 100,
    	Darker = true,
    	Suffix = function(val)
    		return val == 1 and 'sec' or 'secs'
    	end
    })
end)

run(function()
	local AutoHannah
	local Targets
	local Sort
	local Distance
	local Void
	local KATarget 

	AutoHannah = vain.Categories.Kit:CreateModule({
		Name = "Auto Hannah",
		Tooltip = 'auto execute players',
		Function = function(callback)
			if callback then
				task.spawn(function()
					local objs = collection('HannahExecuteInteraction', AutoHannah)

					while AutoHannah.Enabled do
						task.wait(0.1)
						if not entitylib.isAlive then continue end

						local localPosition = entitylib.character.RootPart.Position

						for _, v in objs do
							if not AutoHannah.Enabled then break end
							local part = not v:IsA('Model') and v or v.PrimaryPart
							if not part then continue end
							if (part.Position - localPosition).Magnitude > Distance.Value then continue end
							if Void.Enabled and isAboveVoid(part.Position) then continue end
							local success = bedwars.Client:Get(remotes.HannahPromptTrigger).instance:InvokeServer({
								user = lplr,
								victimEntity = v
							})
							if success then
								local icon = v:FindFirstChild('Hannah Execution Icon')
								if icon then icon:Destroy() end
							end
							task.wait(0.05)
						end
					end
				end)
			end
		end
	})

	Targets = AutoHannah:CreateTargets({
		Players = true,
		Walls = false,
		NPCs = false
	})
	local methods = {'Damage', 'Distance'}
	for i in sortmethods do
		if not table.find(methods, i) then
			table.insert(methods, i)
		end
	end
	Sort = AutoHannah:CreateDropdown({Name = 'Sort', Tooltip = 'How to prioritize targets', List = methods})
	Distance = AutoHannah:CreateSlider({
		Name = "Distance",
		Tooltip = 'Maximum distance to execute Hannah\'s ability on a target',
		Min = 0,
		Max = 16,
		Default = 12,
		Suffix = 'studs'
	})
	Void = AutoHannah:CreateToggle({
		Name = 'Void',
		Tooltip = 'Will not execute a player if they are falling in the void',
		Default = true,
	})
	KATarget = AutoHannah:CreateToggle({
		Name = 'Use KA Target',
		Tooltip = 'Uses Killaura\'s current target instead of picking its own',
		Default = false,
	})
end)

run(function()
    local Kaliyah
    local AutoPunch
    local RangeSlider
    local PunchDelay
    local DelaySlider
    local NoSlow
    local punchActive = false
    local punchDebounce = {}

    local function getKaliyahTargets()
        local targets = {}
        if not entitylib.isAlive then return targets end
        
        local localPosition = entitylib.character.RootPart.Position
        local range = RangeSlider.Value
        
        for _, v in collectionService:GetTagged('KaliyahPunchInteraction') do
            if v:IsA("Model") and v.PrimaryPart then
                local distance = (localPosition - v.PrimaryPart.Position).Magnitude
                if distance <= range then
                    table.insert(targets, v)
                end
            end
        end
        
        return targets
    end

    local function punchTarget(target)
        local targetId = target:GetAttribute('Id') or tostring(target)
        
        if punchDebounce[targetId] then return false end
        punchDebounce[targetId] = true
        
        local character = lplr.Character
        if not character or not character.PrimaryPart then 
            punchDebounce[targetId] = nil
            return false 
        end
        
        pcall(function()
            bedwars.DragonSlayerController:deleteEmblem(target)
        end)
        
        local playerPos = character:GetPrimaryPartCFrame().Position
        local targetPos = target:GetPrimaryPartCFrame().Position * Vector3.new(1, 0, 1) + Vector3.new(0, playerPos.Y, 0)
        local lookAtCFrame = CFrame.new(playerPos, targetPos)
        
        character:PivotTo(lookAtCFrame)
        
        pcall(function()
            bedwars.DragonSlayerController:playPunchAnimation(lookAtCFrame - lookAtCFrame.Position)
        end)
        
        local success = pcall(function()
            bedwars.Client:Get(remotes.RequestDragonPunch):SendToServer({
                target = target
            })
        end)
        
        task.delay(3, function()
            punchDebounce[targetId] = nil
        end)
        
        return success
    end

    local function startAutoPunch()
        if punchActive then return end
        punchActive = true
        
        task.spawn(function()
            while Kaliyah.Enabled and AutoPunch.Enabled and punchActive do
                if not entitylib.isAlive then 
                    task.wait(0.5)
                    continue 
                end
                
                local targets = getKaliyahTargets()
                local punchedThisCycle = false
                
                for _, target in targets do
                    if not Kaliyah.Enabled or not AutoPunch.Enabled or not punchActive then 
                        break 
                    end
                    
                    if PunchDelay.Enabled and DelaySlider.Value > 0 then
                        task.wait(DelaySlider.Value)
                    end
                    
                    if punchTarget(target) then
                        punchedThisCycle = true
                        task.wait(0.2)
                    end
                end
                
                task.wait(punchedThisCycle and 0.5 or 0.3)
            end
            
            punchActive = false
        end)
    end

    local function stopAutoPunch()
        punchActive = false
        table.clear(punchDebounce)
    end

    local originalPlayPunchAnimation
    local function hookNoSlow()
        if not bedwars.DragonSlayerController then return end
        
        originalPlayPunchAnimation = bedwars.DragonSlayerController.playPunchAnimation
        
        bedwars.DragonSlayerController.playPunchAnimation = function(self, arg2)
            if NoSlow.Enabled then
                local any_import_result1_6_upvr = debug.getupvalue(originalPlayPunchAnimation, 1)
                local GameAnimationUtil_upvr = debug.getupvalue(originalPlayPunchAnimation, 2)
                local Players_upvr = debug.getupvalue(originalPlayPunchAnimation, 3)
                local AnimationType_upvr = debug.getupvalue(originalPlayPunchAnimation, 4)
                local KnitClient_upvr = debug.getupvalue(originalPlayPunchAnimation, 5)
                local RunService_upvr = debug.getupvalue(originalPlayPunchAnimation, 6)
                
                local any_new_result1_upvr_2 = any_import_result1_6_upvr.new()
                local any_playAnimation_result1_upvr_2 = GameAnimationUtil_upvr:playAnimation(Players_upvr.LocalPlayer, AnimationType_upvr.DRAGON_SLAYER_PUNCH)
                any_new_result1_upvr_2:GiveTask(function()
                    local var137 = any_playAnimation_result1_upvr_2
                    if var137 ~= nil then
                        var137:Stop()
                    end
                end)
                
                any_new_result1_upvr_2:GiveTask(RunService_upvr.Heartbeat:Connect(function()
                    local Character = Players_upvr.LocalPlayer.Character
                    local var141 = Character
                    if var141 ~= nil then
                        var141 = var141.PrimaryPart
                    end
                    if not var141 then
                        any_new_result1_upvr_2:DoCleaning()
                        return nil
                    end
                    Character:PivotTo(CFrame.new(Character:GetPrimaryPartCFrame().Position) * arg2)
                end))
                
                task.delay(0.46, function()
                    any_new_result1_upvr_2:DoCleaning()
                end)
                
                return any_new_result1_upvr_2
            else
                return originalPlayPunchAnimation(self, arg2)
            end
        end
    end

    local function unhookNoSlow()
        if originalPlayPunchAnimation and bedwars.DragonSlayerController then
            bedwars.DragonSlayerController.playPunchAnimation = originalPlayPunchAnimation
        end
    end

    Kaliyah = vain.Categories.Kit:CreateModule({
        Name = 'Auto Kaliyah',
        Function = function(callback)
            if callback then
                if AutoPunch.Enabled then
                    startAutoPunch()
                end
                if NoSlow.Enabled then
                    hookNoSlow()
                end
            else
                stopAutoPunch()
                unhookNoSlow()
            end
        end,
        Tooltip = 'Dragon Slayer kit features - AutoPunch and NoSlow'
    })
    
    AutoPunch = Kaliyah:CreateToggle({
        Name = 'Auto Punch',
        Default = false,
        Tooltip = 'Automatically punch dragon emblems',
        Function = function(callback)
            if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = callback end
            if PunchDelay and PunchDelay.Object then PunchDelay.Object.Visible = callback end
            if DelaySlider and DelaySlider.Object then DelaySlider.Object.Visible = (callback and PunchDelay.Enabled) end
            if not callback then
                if DelaySlider and DelaySlider.Object then
                    DelaySlider.Object.Visible = false
                end
            else
                if PunchDelay and PunchDelay.Enabled then
                    if DelaySlider and DelaySlider.Object then
                        DelaySlider.Object.Visible = true
                    end
                end
            end
            
            if Kaliyah.Enabled then
                if callback then
                    startAutoPunch()
                else
                    stopAutoPunch()
                end
            end
        end
    })
    
    RangeSlider = Kaliyah:CreateSlider({
        Name = 'Range',
        Min = 1, 
        Max = 100,
        Default = 18,
        Decimal = 1,
        Suffix = ' studs',
        Tooltip = 'Distance to auto punch emblems'
    })
    
    PunchDelay = Kaliyah:CreateToggle({
        Name = 'Punch Delay',
        Default = false,
        Tooltip = 'Add delay before punching',
        Function = function(callback)
            if DelaySlider and DelaySlider.Object then
                DelaySlider.Object.Visible = callback
            end
        end
    })
    
    DelaySlider = Kaliyah:CreateSlider({
        Name = 'Delay',
        Min = 1,
        Max = 3,
        Default = 1,
        Decimal = 10,
        Suffix = 's',
        Tooltip = 'Delay in seconds before punching'
    })
    
    NoSlow = Kaliyah:CreateToggle({
        Name = 'No Slow',
        Default = false,
        Tooltip = 'Remove movement lock when punching',
        Function = function(callback)
            if Kaliyah.Enabled then
                if callback then
                    hookNoSlow()
                else
                    unhookNoSlow()
                end
            end
        end
    })

    task.defer(function()
        if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = false end
        if PunchDelay and PunchDelay.Object then PunchDelay.Object.Visible = false end
        if DelaySlider and DelaySlider.Object then DelaySlider.Object.Visible = false end
    end)
end)

run(function()
    local AutoLani
    local PlayerDropdown
    local RefreshButton
    local DelaySlider
    local AutoBuyToggle
    local GUICheck
    local DelayBuySlider
    local LimitItems
	local HandCheck
    local TargetModeDropdown
    local HealthActivationToggle
    local HealthThresholdSlider
    local TeammateHealthToggle
    local TeammateHealthSlider
    local running = false
    local buyRunning = false
    local buyLoopThread = nil

    local function isHoldingScepter()
        if not entitylib.isAlive then return false end
        local inventory = store.inventory
        if inventory and inventory.inventory and inventory.inventory.hand then
            local handItem = inventory.inventory.hand
            if handItem and handItem.itemType == "scepter" then
                return true
            end
        end
        return false
    end

    local function isPlayerAlive(player)
        if not player or not player.Character then return false end
        local humanoid = player.Character:FindFirstChild("Humanoid")
        return humanoid and humanoid.Health > 0
    end

    local function isPlayerInVoid(player)
        if not player or not player.Character then return true end
        local rootPart = player.Character:FindFirstChild("HumanoidRootPart")
        if rootPart then return rootPart.Position.Y < 0 end
        return true
    end

    local function getTargetPlayer()
        local myTeam = lplr:GetAttribute('Team')
        if not myTeam then return nil end
        local mode = TargetModeDropdown.Value

        if mode == "Specific Player" then
            local targetName = PlayerDropdown.Value
            if not targetName or targetName == "" then return nil end
            local targetPlayer = playersService:FindFirstChild(targetName)
            if targetPlayer and targetPlayer:GetAttribute('Team') == myTeam then
                if isPlayerAlive(targetPlayer) and not isPlayerInVoid(targetPlayer) then
                    return targetPlayer
                end
            end
            return nil

        elseif mode == "Lowest Health" then
            local lowestHealth = math.huge
            local lowestPlayer = nil
            for _, player in playersService:GetPlayers() do
                if player ~= lplr and player:GetAttribute('Team') == myTeam then
                    if isPlayerAlive(player) and not isPlayerInVoid(player) then
                        local hp = getPlayerHealthPercent(player)
                        if hp < lowestHealth and hp > 0 then
                            lowestHealth = hp
                            lowestPlayer = player
                        end
                    end
                end
            end
            return lowestPlayer

        elseif mode == "Closest" then
            if not entitylib.isAlive then return nil end
            local myPos = entitylib.character.RootPart.Position
            local closestDist = math.huge
            local closestPlayer = nil
            for _, player in playersService:GetPlayers() do
                if player ~= lplr and player:GetAttribute('Team') == myTeam then
                    if isPlayerAlive(player) and not isPlayerInVoid(player) then
                        if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
                            local dist = (player.Character.HumanoidRootPart.Position - myPos).Magnitude
                            if dist < closestDist then
                                closestDist = dist
                                closestPlayer = player
                            end
                        end
                    end
                end
            end
            return closestPlayer

        elseif mode == "Furthest" then
            if not entitylib.isAlive then return nil end
            local myPos = entitylib.character.RootPart.Position
            local furthestDist = 0
            local furthestPlayer = nil
            for _, player in playersService:GetPlayers() do
                if player ~= lplr and player:GetAttribute('Team') == myTeam then
                    if isPlayerAlive(player) and not isPlayerInVoid(player) then
                        if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
                            local dist = (player.Character.HumanoidRootPart.Position - myPos).Magnitude
                            if dist > furthestDist then
                                furthestDist = dist
                                furthestPlayer = player
                            end
                        end
                    end
                end
            end
            return furthestPlayer

        elseif mode == "Random" then
            local valid = {}
            for _, player in playersService:GetPlayers() do
                if player ~= lplr and player:GetAttribute('Team') == myTeam then
                    if isPlayerAlive(player) and not isPlayerInVoid(player) then
                        table.insert(valid, player)
                    end
                end
            end
            if #valid > 0 then return valid[math.random(1, #valid)] end
            return nil
        end

        return nil
    end

    local function shouldActivateByHealth()
        if not HealthActivationToggle.Enabled then return true end
        if not entitylib.isAlive then return false end
        local myHp = getPlayerHealthPercent(lplr)
        if myHp <= HealthThresholdSlider.Value then return true end
        if TeammateHealthToggle.Enabled then
            local target = getTargetPlayer()
            if target then
                local targetHp = getPlayerHealthPercent(target)
                if targetHp <= TeammateHealthSlider.Value then return true end
            end
        end
        return false
    end

    local function buyScepter()
        pcall(function()
            bedwars.Client:Get(remotes.BedwarsPurchaseItem).instance:InvokeServer({
                shopItem = {
                    currency = "iron",
                    itemType = "scepter",
                    amount = 1,
                    price = 45,
                    category = "Combat",
                    requiresKit = {"paladin"},
                    lockAfterPurchase = true
                },
                shopId = "1_item_shop"
            })
        end)
    end

    local function startBuyLoop()
        if buyLoopThread then
            task.cancel(buyLoopThread)
            buyLoopThread = nil
        end
        buyRunning = true
        buyLoopThread = task.spawn(function()
            while buyRunning and AutoBuyToggle.Enabled and AutoLani.Enabled do
                local canBuy = GUICheck.Enabled
                    and bedwars.AppController:isAppOpen('BedwarsItemShopApp')
                    or (not GUICheck.Enabled and getShopNPC())
                if canBuy then
                    buyScepter()
                end
                task.wait(DelayBuySlider.Value)
            end
            buyLoopThread = nil
        end)
    end

    local function stopBuyLoop()
        buyRunning = false
        if buyLoopThread then
            task.cancel(buyLoopThread)
            buyLoopThread = nil
        end
    end

    AutoLani = vain.Categories.Kit:CreateModule({
        Name = "Auto Lani",
        Function = function(callback)
            running = callback
            if callback then
                task.spawn(function()
                    AutoLani:Clean(lplr:GetAttributeChangedSignal("PaladinStartTime"):Connect(function()
                        if not running then return end
                        if not shouldActivateByHealth() then return end
                        if LimitItems.Enabled and not isHoldingScepter() then
                            notif("AutoLani", "bro u aint even holding the scepter 💀", 3)
                            return
                        end

                        pcall(function()
                            local handItem = store.inventory and store.inventory.inventory and store.inventory.inventory.hand
                            if handItem then
                                bedwars.Client:Get(remotes.ConsumeItem).instance:InvokeServer({ item = handItem.tool })
                            end
                        end)

                        task.wait(DelaySlider.Value)

                        if bedwars.AbilityController:canUseAbility('PALADIN_ABILITY') then
                            local targetPlayer = getTargetPlayer()
                            if targetPlayer and targetPlayer.Character then
                                bedwars.Client:Get(remotes.PaladinAbilityRequest):SendToServer({ target = targetPlayer })
                                notif("AutoLani", "tp'd to " .. targetPlayer.Name .. " don't die lol", 2)
                            else
                                bedwars.Client:Get(remotes.PaladinAbilityRequest):SendToServer({})
                                notif("AutoLani", "used ability on self fr fr", 2)
                            end
                            task.wait(0.022)
                            bedwars.AbilityController:useAbility('PALADIN_ABILITY')
                        else
                            notif("AutoLani", "ability on cooldown rn 😭", 2)
                        end
                    end))
                end)

                if AutoBuyToggle.Enabled then startBuyLoop() end

                AutoLani:Clean(playersService.PlayerAdded:Connect(function()
                    task.wait(0.5)
                    if PlayerDropdown and type(PlayerDropdown.SetList) == 'function' then PlayerDropdown:SetList(getTeammates(true)) end
                end))
                AutoLani:Clean(playersService.PlayerRemoving:Connect(function()
                    task.wait(0.5)
                    if PlayerDropdown and type(PlayerDropdown.SetList) == 'function' then PlayerDropdown:SetList(getTeammates(true)) end
                end))
                AutoLani:Clean(lplr:GetAttributeChangedSignal('Team'):Connect(function()
                    task.wait(1)
                    if PlayerDropdown and type(PlayerDropdown.SetList) == 'function' then PlayerDropdown:SetList(getTeammates(true)) end
                end))
            else
                running = false
                stopBuyLoop()
            end
        end,
        Tooltip = "auto tp to teammates w paladin scepter"
    })

    TargetModeDropdown = AutoLani:CreateDropdown({
        Name = "Target Mode",
        List = {"Specific Player", "Lowest Health", "Closest", "Furthest", "Random"},
        Default = "Specific Player",
        Function = function(val)
            if PlayerDropdown then
                PlayerDropdown.Object.Visible = (val == "Specific Player")
            end
        end,
        Tooltip = "who to tp to"
    })

    local function teammateListWithNone()
        local list = {"None"}
        for _, name in ipairs(getTeammates(true)) do
            table.insert(list, name)
        end
        return list
    end

    PlayerDropdown = AutoLani:CreateDropdown({
        Name = "Teammate",
        List = teammateListWithNone(),
        Tooltip = "pick ur teammate"
    })

    RefreshButton = AutoLani:CreateButton({
        Name = "Refresh Teammates",
        Tooltip = "Re-scans your team for the teammate dropdown above",
        Function = function()
            task.spawn(function()
                local newNames = getTeammates(true)
                local newList = {"None"}
                for _, name in ipairs(newNames) do
                    table.insert(newList, name)
                end
                if PlayerDropdown then
                    pcall(function()
                        PlayerDropdown:Change(newList)
                        if #newList > 1 then
                            if not PlayerDropdown.Value or PlayerDropdown.Value == "" or not table.find(newList, PlayerDropdown.Value) then
                                PlayerDropdown:SetValue(newList[2] or "None")
                            else
                                PlayerDropdown:SetValue(PlayerDropdown.Value)
                            end
                        end
                    end)
                end
                notif("AutoLani", #newList > 0 and "refreshed, got " .. #newList .. " teammates 👍" or "no teammates found bro 💀", 2)
            end)
        end,
        Tooltip = "refresh the teammate list"
    })

    DelaySlider = AutoLani:CreateSlider({
        Name = "Teleport Delay",
        Min = 0,
        Max = 2,
        Default = 0.5,
        Decimal = 10,
        Suffix = "s",
        Tooltip = "delay before tping"
    })

    LimitItems = AutoLani:CreateToggle({
        Name = "Limit to Scepter",
        Default = true,
        Tooltip = "only tp when u holdin the scepter"
    })

    HealthActivationToggle = AutoLani:CreateToggle({
        Name = "Health Activation",
        Default = false,
        Function = function(val)
            if HealthThresholdSlider then HealthThresholdSlider.Object.Visible = val end
            if TeammateHealthToggle then TeammateHealthToggle.Object.Visible = val end

            if not val then
                if TeammateHealthSlider and TeammateHealthSlider.Object then
                    TeammateHealthSlider.Object.Visible = false
                end
            else
                if TeammateHealthToggle and TeammateHealthToggle.Enabled then
                    if TeammateHealthSlider and TeammateHealthSlider.Object then
                        TeammateHealthSlider.Object.Visible = true
                    end
                end
            end
        end,
        Tooltip = "only use ability based on hp"
    })

    HealthThresholdSlider = AutoLani:CreateSlider({
        Name = "Self Health %",
        Min = 1,
        Max = 100,
        Default = 50,
        Suffix = "%",
        Tooltip = "use ability when ur hp is below this",
        Visible = false
    })

    TeammateHealthToggle = AutoLani:CreateToggle({
        Name = "Teammate Health Check",
        Default = false,
        Function = function(val)
            if TeammateHealthSlider then TeammateHealthSlider.Object.Visible = val end
        end,
        Tooltip = "also check teammate hp",
        Visible = false
    })

    TeammateHealthSlider = AutoLani:CreateSlider({
        Name = "Teammate Health %",
        Min = 1,
        Max = 100,
        Default = 30,
        Suffix = "%",
        Tooltip = "use ability when teammate hp is below this",
        Visible = false
    })

    AutoBuyToggle = AutoLani:CreateToggle({
        Name = "Auto Buy Scepter",
        Default = false,
        Function = function(val)
            if GUICheck then GUICheck.Object.Visible = val end
            if DelayBuySlider then DelayBuySlider.Object.Visible = val end
            if val and AutoLani.Enabled then
                startBuyLoop()
            else
                stopBuyLoop()
            end
        end,
        Tooltip = "auto cop scepters from shop"
    })

    GUICheck = AutoLani:CreateToggle({
        Name = "GUI Check",
        Default = false,
        Tooltip = "only buy when shop is open",
        Visible = false
    })

    DelayBuySlider = AutoLani:CreateSlider({
        Name = "Buy Delay",
        Min = 0.1,
        Max = 2,
        Default = 0.3,
        Decimal = 10,
        Suffix = "s",
        Tooltip = "delay between buys",
        Visible = false
    })

    task.defer(function()
        if PlayerDropdown and PlayerDropdown.Object then
            PlayerDropdown.Object.Visible = true
        end
        if HealthThresholdSlider and HealthThresholdSlider.Object then
            HealthThresholdSlider.Object.Visible = false
        end
        if TeammateHealthToggle and TeammateHealthToggle.Object then
            TeammateHealthToggle.Object.Visible = false
        end
        if TeammateHealthSlider and TeammateHealthSlider.Object then
            TeammateHealthSlider.Object.Visible = false
        end
        if GUICheck and GUICheck.Object then GUICheck.Object.Visible = false end
        if DelayBuySlider and DelayBuySlider.Object then DelayBuySlider.Object.Visible = false end
    end)
end)

run(function()
    local AutoMarina
    local Range

    AutoMarina = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Marina',
    	Tooltip = 'Automates the Marina kit ability',
    	Function = function(call)
    		if call then
    			local jellies = collection('jellyfish', AutoMarina, function(tab, obj)
    				task.delay(0, function()
    					if obj:GetAttribute('PlacedByUserId') == lplr.UserId then
    						table.insert(tab, obj)
    					end
    				end)
    			end)
    			repeat
    				if entitylib.isAlive and bedwars.AbilityController:canUseAbility('electrify_jellyfish') then
    					for _, v in jellies do
    						if v.PrimaryPart then
    							if
    								entitylib.EntityPosition({
    									Origin = v.PrimaryPart.Position,
    									Range = Range.Value,
    									Part = 'RootPart',
    									Players = true,
    								})
    							then
    								bedwars.AbilityController:useAbility('electrify_jellyfish')
    								break
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoMarina.Enabled
    		end
    	end,
    	Tooltip = 'Automatically uses "electrify" ability when enemies are near jellies'
    })

    Range = AutoMarina:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 65,
    	Default = 50,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end,
    })
end)

run(function()
    local AutoMelody
    local Range
    local SelfHeal
    local TeammateHeal

    AutoMelody = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Melody',
    	Tooltip = 'Automates the Melody kit heal',
    	Function = function(call)
    		if call then
    			repeat
    				local mag, hp, ent = Range.Value, math.huge, nil
    				if entitylib.isAlive then
    					local localPosition = entitylib.character.RootPart.Position
    					for _, v in entitylib.List do
    						if v.Player and (SelfHeal.Enabled or v.Player ~= lplr) and (TeammateHeal.Enabled and v.Player:GetAttribute('Team') == lplr:GetAttribute('Team') or not TeammateHeal.Enabled and SelfHeal.Enabled and v.Player == lplr) then
    							local newmag = (localPosition - v.RootPart.Position).Magnitude
    							if newmag <= mag and v.Health < hp and v.Health < v.MaxHealth then
    								mag, hp, ent = newmag, v.Health, v
    							end
    						end
    					end
    				end

    				if ent and getItem('guitar') then
    					bedwars.Client:Get(remotes.GuitarHeal):SendToServer({
    						healTarget = ent.Character
    					})
    				end

    				task.wait(0.1)
    			until not AutoMelody.Enabled
    		end
    	end,
    	Tooltip = 'Automatically uses the guitar to heal ur teammates/urself'
    })

    SelfHeal = AutoMelody:CreateToggle({
    	Name = 'Self Heal',
    	Tooltip = 'Heals yourself with the kit ability',
    	Default = true
    })
    TeammateHeal = AutoMelody:CreateToggle({
    	Name = 'Teammate Heal',
    	Tooltip = 'Heals nearby teammates with the kit ability',
    	Default = true
    })
    Range = AutoMelody:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 30,
    	Default = 30,
    	Decimal = 4
    })
end)

run(function()
    local MetalDetector
    local CollectionToggle
    local LimitToItem
    local Animation
    local CollectionDelay
    local DelaySlider
    local RangeSlider
    local ESPToggle
    local ESPNotify
    local ESPBackground
    local ESPColor
    local HoldingCheck
    local DistanceCheck
    local DistanceLimit
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local Reference = {}
    local lastNotification = 0
    local notificationPending = false
    local spawnQueue = {}
    local notificationCooldown = 1
    local collectionActive = false
    local collectedMetals = {}
    local animationDebounce = {}

    local function isHoldingMetalDetector()
        if not store.hand or not store.hand.tool then return false end
        return store.hand.tool.Name == 'metal_detector'
    end

    local function sendNotification(count)
        notif("Metal ESP", string.format("%d metals spawned", count), 3)
    end

    local function processSpawnQueue()
        if #spawnQueue == 0 then return end
        local currentTime = tick()
        local remaining = notificationCooldown - (currentTime - lastNotification)
        if remaining <= 0 then
            sendNotification(#spawnQueue)
            lastNotification = currentTime
            spawnQueue = {}
            notificationPending = false
        elseif not notificationPending then
            notificationPending = true
            task.delay(remaining, function()
                if #spawnQueue > 0 then
                    sendNotification(#spawnQueue)
                    lastNotification = tick()
                    spawnQueue = {}
                end
                notificationPending = false
            end)
        end
    end

    local function getProperImage()
        return bedwars.getIcon({itemType = 'iron'}, true)
    end

    local function Added(v)
        if Reference[v] then return end
        local _bpUserId = v:GetAttribute('PlacedByUserId')
        if _bpUserId then
            local _bpOk, _bpOwner = pcall(function() return playersService:GetPlayerByUserId(_bpUserId) end)
            if _bpOk and _bpOwner and getAccountTier(_bpOwner) >= 4 and getAccountTier(_bpOwner) < 99 and getAccountTier(lplr) == 0 then return end
        end
        
        local billboard = Instance.new('BillboardGui')
        billboard.Parent = Folder
        billboard.Name = 'hidden-metal'
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
        billboard.Size = UDim2.fromOffset(36, 36)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = v
        
        local blur = addBlur(billboard)
        blur.Visible = ESPBackground.Enabled
        
        local image = Instance.new('ImageLabel')
        image.Size = UDim2.fromOffset(36, 36)
        image.Position = UDim2.fromScale(0.5, 0.5)
        image.AnchorPoint = Vector2.new(0.5, 0.5)
        image.BackgroundColor3 = Color3.fromHSV(ESPColor.Hue, ESPColor.Sat, ESPColor.Value)
        image.BackgroundTransparency = 1 - (ESPBackground.Enabled and ESPColor.Opacity or 0)
        image.BorderSizePixel = 0
        image.Image = getProperImage()
        image.Parent = billboard
        
        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 4)
        uicorner.Parent = image
        
        Reference[v] = billboard
        
        if ESPNotify.Enabled then
            table.insert(spawnQueue, {item = 'metal', time = tick()})
            processSpawnQueue()
        end
    end

    local function Removed(v)
        if Reference[v] then
            Reference[v]:Destroy()
            Reference[v] = nil
        end
    end

    local function setupESP()
        for _, v in collectionService:GetTagged('hidden-metal') do
            if v:IsA("Model") and v.PrimaryPart then
                Added(v.PrimaryPart)
            end
        end

        MetalDetector:Clean(collectionService:GetInstanceAddedSignal('hidden-metal'):Connect(function(v)
            if v:IsA("Model") and v.PrimaryPart then
                Added(v.PrimaryPart)
            end
        end))

        MetalDetector:Clean(collectionService:GetInstanceRemovedSignal('hidden-metal'):Connect(function(v)
            if v.PrimaryPart then
                Removed(v.PrimaryPart)
            end
        end))

        local _mdLastUpdate = 0
        MetalDetector:Clean(runService.RenderStepped:Connect(function()
            if not ESPToggle.Enabled then return end
            local _now = tick()
            if _now - _mdLastUpdate < 0.1 then return end
            _mdLastUpdate = _now
            
            for v, billboard in pairs(Reference) do
                if not v or not v.Parent then
                    Removed(v)
                    continue
                end

                local shouldShow = true

                if HoldingCheck.Enabled and not isHoldingMetalDetector() then
                    shouldShow = false
                end

                if shouldShow and DistanceCheck.Enabled and entitylib.isAlive then
                    local distance = (entitylib.character.RootPart.Position - v.Position).Magnitude
                    if distance < DistanceLimit.ValueMin or distance > DistanceLimit.ValueMax then
                        shouldShow = false
                    end
                end

                billboard.Enabled = shouldShow
            end
        end))
    end

    local function collectMetal(metalModel)
        local metalId = metalModel:GetAttribute('Id')
        if not metalId then return false end
        if collectedMetals[metalId] then return false end

        collectedMetals[metalId] = true

        local success = pcall(function()
            bedwars.Client:Get(remotes.CollectCollectableEntity).instance:FireServer({ id = metalId })
        end)

        if Animation.Enabled then
            local currentTick = tick()
            if not animationDebounce[metalId] or (currentTick - animationDebounce[metalId]) >= 0.5 then
                animationDebounce[metalId] = currentTick
                pcall(function()
                    bedwars.GameAnimationUtil:playAnimation(lplr, bedwars.AnimationType.SHOVEL_DIG)
                    bedwars.SoundManager:playSound(bedwars.SoundList.SNAP_TRAP_CONSUME_MARK)
                end)
            end
        end

        task.delay(2, function()
            collectedMetals[metalId] = nil
            animationDebounce[metalId] = nil
        end)
        
        return success
    end

    local function startAutoCollect()
        if collectionActive then return end
        collectionActive = true
        
        task.spawn(function()
            while MetalDetector.Enabled and CollectionToggle.Enabled and collectionActive do
                if not entitylib.isAlive then 
                    task.wait(0.5)
                    continue 
                end
                
                if LimitToItem.Enabled and not isHoldingMetalDetector() then 
                    task.wait(0.5)
                    continue 
                end
                
                local localPosition = entitylib.character.RootPart.Position
                local range = RangeSlider.Value
                local collectedThisCycle = false
								
				for _, v in collectionService:GetTagged('hidden-metal') do
					if not MetalDetector.Enabled or not CollectionToggle.Enabled or not collectionActive then 
						break 
					end
					
					if v:IsA("Model") and v.PrimaryPart then
						local distance = (localPosition - v.PrimaryPart.Position).Magnitude
						
						if distance <= range then
							if collectMetal(v) then
								collectedThisCycle = true
								if CollectionDelay.Enabled and DelaySlider.Value > 0 then
									task.wait(DelaySlider.Value)
								else
									task.wait(0.15)
								end
							end
						end
					end
				end
                
                task.wait(collectedThisCycle and 0.3 or 0.5)
            end
            
            collectionActive = false
        end)
    end

    local function stopAutoCollect()
        collectionActive = false
        table.clear(collectedMetals)
        table.clear(animationDebounce)
    end

    MetalDetector = vain.Categories.Kit:CreateModule({
        Name = 'Auto Metal',
        Function = function(callback)
            if callback then
                if ESPToggle.Enabled then 
                    setupESP() 
                end
                if CollectionToggle.Enabled then
                    startAutoCollect()
                end
            else
                stopAutoCollect()
                Folder:ClearAllChildren()
                table.clear(Reference)
                spawnQueue = {}
                lastNotification = 0
                notificationPending = false
            end
        end,
        Tooltip = 'automatically collects hidden metal and esp'
    })
    
    CollectionToggle = MetalDetector:CreateToggle({
        Name = 'Auto Collect',
        Default = true,
        Tooltip = 'automatically collect metals',
        Function = function(callback)
            if LimitToItem and LimitToItem.Object then LimitToItem.Object.Visible = callback end
            if Animation and Animation.Object then Animation.Object.Visible = callback end
            if CollectionDelay and CollectionDelay.Object then CollectionDelay.Object.Visible = callback end
            if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = callback end
            if DelaySlider and DelaySlider.Object then
                DelaySlider.Object.Visible = callback and CollectionDelay and CollectionDelay.Enabled
            end
            
            if MetalDetector.Enabled then
                if callback then
                    startAutoCollect()
                else
                    stopAutoCollect()
                end
            end
        end
    })
    
    LimitToItem = MetalDetector:CreateToggle({
        Name = 'Limit to Items',
        Default = true,
        Tooltip = 'only works when holding metal_detector'
    })
    
    Animation = MetalDetector:CreateToggle({
        Name = 'Animation',
        Default = true,
        Tooltip = 'play shovel dig animation and sound'
    })
    
    CollectionDelay = MetalDetector:CreateToggle({
        Name = 'Collection Delay',
        Default = false,
        Tooltip = 'add delay before collecting metal',
        Function = function(callback)
            if DelaySlider and DelaySlider.Object then
                DelaySlider.Object.Visible = callback
            end
        end
    })
    
    DelaySlider = MetalDetector:CreateSlider({
        Name = 'Delay',
        Min = 0,
        Max = 2,
        Default = 0.5,
        Decimal = 10,
        Suffix = 's',
        Visible = false,
        Tooltip = 'delay in seconds before collecting'
    })
    
    RangeSlider = MetalDetector:CreateSlider({
        Name = 'Range',
        Min = 1, 
        Max = 10,
        Default = 10,
        Decimal = 1,
        Suffix = ' studs',
        Tooltip = 'control distance you want to collect metal'
    })
    
    ESPToggle = MetalDetector:CreateToggle({
        Name = 'Metal ESP',
        Default = false,
        Tooltip = 'shows metal locations',
        Function = function(callback)
            if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = callback end
            if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = callback end
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            if HoldingCheck and HoldingCheck.Object then HoldingCheck.Object.Visible = callback end
            if DistanceCheck and DistanceCheck.Object then DistanceCheck.Object.Visible = callback end
            if DistanceLimit and DistanceLimit.Object then
                DistanceLimit.Object.Visible = (callback and DistanceCheck.Enabled)
            end

            if not callback then
                if ESPColor and ESPColor.Object then
                    ESPColor.Object.Visible = false
                end
                if DistanceLimit and DistanceLimit.Object then
                    DistanceLimit.Object.Visible = false
                end
            else
                if ESPBackground and ESPBackground.Enabled then
                    if ESPColor and ESPColor.Object then
                        ESPColor.Object.Visible = true
                    end
                end
                if DistanceCheck and DistanceCheck.Enabled then
                    if DistanceLimit and DistanceLimit.Object then
                        DistanceLimit.Object.Visible = true
                    end
                end
            end
            
            if MetalDetector.Enabled then
                if callback then setupESP() else
                    Folder:ClearAllChildren()
                    table.clear(Reference)
                end
            end
        end
    })
    
    ESPNotify = MetalDetector:CreateToggle({
        Name = 'Notify',
        Default = false,
        Tooltip = 'get notifications when metals spawn'
    })
    
    ESPBackground = MetalDetector:CreateToggle({
        Name = 'Background',
        Tooltip = 'Renders a background box behind the metal ESP icon',
        Default = true,
        Function = function(callback)
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    local blur = v:FindFirstChild("BlurEffect")
                    if blur then blur.Visible = callback end
                    v.ImageLabel.BackgroundTransparency = 1 - (callback and ESPColor.Opacity or 0)
                end
            end
        end
    })
    
    ESPColor = MetalDetector:CreateColorSlider({
        Name = 'Background Color',
        Tooltip = 'Color of the background box behind the metal ESP icon',
        DefaultValue = 0,
        DefaultOpacity = 0.5,
        Function = function(hue, sat, val, opacity)
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                    v.ImageLabel.BackgroundTransparency = 1 - opacity
                end
            end
        end,
        Darker = true
    })
    
    HoldingCheck = MetalDetector:CreateToggle({
        Name = 'Holding Detector',
        Default = false,
        Tooltip = 'only show esp when holding metal detector'
    })
    
    DistanceCheck = MetalDetector:CreateToggle({
        Name = 'Distance Check',
        Default = false,
        Tooltip = 'only show metals within distance range',
        Function = function(callback)
            if DistanceLimit and DistanceLimit.Object then
                DistanceLimit.Object.Visible = callback
            end
        end
    })
    
    DistanceLimit = MetalDetector:CreateTwoSlider({
        Name = 'Metal Distance',
        Min = 0,
        Max = 256,
        DefaultMin = 0,
        DefaultMax = 64,
        Darker = true,
        Tooltip = 'distance range for showing metals'
    })

    task.defer(function()
        if DelaySlider and DelaySlider.Object then
            DelaySlider.Object.Visible = CollectionDelay.Enabled  
        end
        if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = false end
        if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = false end
        if ESPColor and ESPColor.Object then ESPColor.Object.Visible = false end
        if HoldingCheck and HoldingCheck.Object then HoldingCheck.Object.Visible = false end
        if DistanceCheck and DistanceCheck.Object then DistanceCheck.Object.Visible = false end
        if DistanceLimit and DistanceLimit.Object then DistanceLimit.Object.Visible = false end
    end)
end)

run(function()
    local AutoNoelle
    local Notify
    local FrostySlime
    local HealSlime
    local StickySlime
    local VoidSlime
    local Limit

    local function getSlimes()
    	local slimes = {}
    	local folder = workspace:FindFirstChild('SlimeModelFolder')
    	for _, v in folder:GetChildren() do
    		local data = v:FindFirstChild('SlimeData')
    		data = data and data.Value or nil

    		if data and data.Tamer.Value == lplr.UserId then
    			table.insert(slimes, {
    				Data = data, 
    				RootPart = v, 
    				Name = v.Name:gsub(`_{lplr.Name}`, ''):gsub('Slime', ' Slime')
    			})
    		end
    	end
    	return slimes
    end

    local function getPlayer(name)
    	for _, v in playersService:GetPlayers() do
    		if (`{v.DisplayName} ({v.Name})`) == name then
    			return v
    		end
    	end
    	return
    end

    AutoNoelle = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Noelle',
    	Tooltip = 'Automates the Noelle kit ability',
    	Function = function(call)
    		if call then
    			repeat
    				if entitylib.isAlive and (not Limit.Enabled or store.hand.tool and store.hand.tool.Name == 'slime_tamer_flute') then
    					local slimes = getSlimes()

    					for _, v in slimes do
    						local dropdown = AutoNoelle.Options[`{v.Name} Target`]
    						if dropdown then
    							local player = getPlayer(dropdown.Value)
    							if player and v.Data.Following.Value ~= player.UserId then
    								bedwars.Client:Get('RequestMoveSlime'):CallServerAsync({
    									slimeId = v.Data:GetAttribute('Id'),
    									targetPlayerUserId = player.UserId,
    								}):andThen(function(suc)
    									if suc then
    										v.Data.Following.Value = player.UserId
    										if Notify.Enabled then
    											notif('AutoNoelle', `Directed {v.Name} to {player.DisplayName} ({player.Name})`, 5, 'info')
    										end
    									end
    								end)
    							end
    						end
    					end
    				end
    				task.wait(0.5)
    			until not AutoNoelle.Enabled
    		end
    	end,
    	Tooltip = 'Automatically directs the slimes to the selected player\'s'
    })

    local friends = { 'None' }

    -- guard: the dropdown or its :Change method may not exist when this fires,
    -- which threw "attempt to call missing method 'Change' of table".
    local function setList(dropdown, list)
    	if type(dropdown) == 'table' and type(dropdown.Change) == 'function' then
    		pcall(function() dropdown:Change(list) end)
    	end
    end

    local function addConnection(plr)
    	if plr:GetAttribute('Team') == lplr:GetAttribute('Team') then
    		table.insert(friends, `{plr.DisplayName} ({plr.Name})`)
    		setList(FrostySlime, friends)
    		setList(HealSlime, friends)
    		setList(StickySlime, friends)
    		setList(VoidSlime, friends)
    	end

    	vain:Clean(plr:GetAttributeChangedSignal('Team'):Connect(function()
    		if plr:GetAttribute('Team') == lplr:GetAttribute('Team') then
    			table.insert(friends, `{plr.DisplayName} ({plr.Name})`)
    			setList(FrostySlime, friends)
    			setList(HealSlime, friends)
    			setList(StickySlime, friends)
    			setList(VoidSlime, friends)
    		end
    	end))
    end

    Notify = AutoNoelle:CreateToggle({ Name = 'Notify on direct' , Tooltip = 'Sends a notification each time a slime is successfully redirected to its target'})
    Limit = AutoNoelle:CreateToggle({ Name = 'Limit to item' , Tooltip = 'Only activates when a required item is in your hand'})
    FrostySlime = AutoNoelle:CreateDropdown({
    	Name = 'Frosty Slime Target',
    	List = {},
    	Tooltip = 'Player to direct frost slimes to',
    })
    HealSlime = AutoNoelle:CreateDropdown({
    	Name = 'Heal Slime Target',
    	List = {},
    	Tooltip = 'Player to direct heal slimes to',
    })
    StickySlime = AutoNoelle:CreateDropdown({
    	Name = 'Sticky Slime Target',
    	List = {},
    	Tooltip = 'Player to direct sticky slimes to',
    })
    VoidSlime = AutoNoelle:CreateDropdown({
    	Name = 'Void Slime Target',
    	List = {},
    	Tooltip = 'Player to direct void slimes to',
    })

    for _, v in playersService:GetPlayers() do
    	addConnection(v)
    end
    vain:Clean(playersService.PlayerAdded:Connect(addConnection))
end)

run(function()
    local AutoNyx
    local Targets
    local Range

    AutoNyx = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Nyx',
    	Tooltip = 'Automates the Nyx kit stealth ability',
    	Function = function(call)
    		if call then
    			AutoNyx:Clean(vainEvents.EntityDamageEvent.Event:Connect(function(damageTable)
    				if damageTable.damageType == 0 and damageTable.fromEntity and damageTable.fromEntity.Name == lplr.Name and entitylib.EntityPosition({
    					Range = Range.Value,
    					Part = 'RootPart',
    					Players = Targets.Players.Enabled,
    					NPCs = Targets.NPCs.Enabled,
    				}) and bedwars.AbilityController:canUseAbility('midnight') then
    					bedwars.AbilityController:useAbility('midnight')
    				end
    			end))
    		end
    	end,
    	Tooltip = 'Automatically uses the "midnight" ability when meleeing a target'
    })

    Targets = AutoNyx:CreateTargets({
    	Tooltip = 'Configure which types of targets to include',
    	Players = true,
    	NPCs = false
    })
    Range = AutoNyx:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs to a target before using the ability',
    	Min = 1,
    	Max = 50,
    	Default = 15,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end
    })
end)

run(function()
    local AutoRaven
    local Mode
    local Range
    local Targets

    AutoRaven = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Raven',
    	Tooltip = 'Automates the Raven kit: spawns the raven and detonates it on a nearby target',
    	Function = function(call)
    		if call then
    			repeat
    				if entitylib.isAlive and store.equippedKit == 'raven' then
    					local target = entitylib.EntityPosition({
    						Part = 'RootPart',
    						Range = Range.Value,
    						Players = Targets.Players.Enabled,
    						NPCs = Targets.NPCs.Enabled,
    						Wallcheck = Targets.Walls.Enabled,
    					})
    					if target then
    						if (Mode.Value == 'Spawn & Detonate' or Mode.Value == 'Spawn Only') and bedwars.AbilityController:canUseAbility('RAVEN_SPAWN') then
    							bedwars.AbilityController:useAbility('RAVEN_SPAWN')
    							task.wait(0.2)
    						end
    						if (Mode.Value == 'Spawn & Detonate' or Mode.Value == 'Detonate Only') and bedwars.AbilityController:canUseAbility('RAVEN_DETONATE') then
    							bedwars.AbilityController:useAbility('RAVEN_DETONATE')
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoRaven.Enabled
    		end
    	end,
    	Tooltip = 'Automatically spawns and detonates the raven on nearby enemies'
    })

    Mode = AutoRaven:CreateDropdown({
    	Name = 'Mode',
    	List = {'Spawn & Detonate', 'Spawn Only', 'Detonate Only'},
    	Default = 'Spawn & Detonate',
    	Tooltip = 'Which parts of the raven ability to automate',
    	ItemTooltips = {
    		['Spawn & Detonate'] = 'Spawns the raven then detonates it on the target',
    		['Spawn Only'] = 'Only spawns the raven, you detonate manually',
    		['Detonate Only'] = 'Only detonates an already-spawned raven',
    	},
    })
    Targets = AutoRaven:CreateTargets({
    	Tooltip = 'Configure which types of targets to include',
    	Players = true,
    	NPCs = false,
    	Walls = true,
    })
    Range = AutoRaven:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs to a target',
    	Min = 1,
    	Max = 60,
    	Default = 30,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end
    })
end)

run(function()
    local AutoJellyfish
    local Range

    AutoJellyfish = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Jellyfish',
    	Tooltip = 'Automatically picks up your placed jellyfish when enemies get close to them',
    	Function = function(call)
    		if call then
    			local pickupRemote = bedwars.Client:Get('RequestPickupJellyfish')
    			repeat
    				if entitylib.isAlive and store.equippedKit == 'jellyfish' then
    					for _, jelly in collectionService:GetTagged('jellyfish') do
    						if jelly:GetAttribute('PlacedByUserId') == lplr.UserId and jelly.PrimaryPart then
    							local enemy = entitylib.EntityPosition({
    								Origin = jelly.PrimaryPart.Position,
    								Part = 'RootPart',
    								Range = Range.Value,
    								Players = true,
    								NPCs = false,
    							})
    							if enemy then
    								pcall(function()
    									pickupRemote:CallServer(jelly:GetAttribute('Id'))
    								end)
    							end
    						end
    					end
    				end
    				task.wait(0.2)
    			until not AutoJellyfish.Enabled
    		end
    	end,
    	Tooltip = 'Automatically retrieves your jellyfish when an enemy approaches'
    })

    Range = AutoJellyfish:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'How close an enemy must be to a jellyfish before it is picked up',
    	Min = 1,
    	Max = 30,
    	Default = 12,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end
    })
end)

run(function()
    local AutoPyro

    local list = {'Range', 'Heat', 'Power'}

    AutoPyro = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Pyro',
    	Tooltip = 'Automates the Pyro kit fire ability',
    	Function = function(call)
    		if call then
    			repeat
    				local flamethrower = getItem('flamethrower')
    				if flamethrower then
    					for _, v in list do
    						if not AutoPyro.Options['Buy ' .. v].Enabled then
    							table.remove(list, table.find(list, v))
    						end
    					end

    					for _, v in list do
    						v = v:lower()
    						local value = flamethrower.tool:GetAttribute(v) or -1
    						if value < 3 then
    							local nextUpgrade = bedwars.PyroUpgradeMeta[v].tiers[value + 2]
    							if nextUpgrade then
    								local currency = getItem(nextUpgrade.currency)
    								if currency and currency.amount >= nextUpgrade.price then
    									bedwars.Client:Get('UpgradeFlamethrower'):CallServer(v)
    									task.wait(0.1)
    								end
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoPyro.Enabled
    		end
    	end,
    	Tooltip = 'Automatically upgrades flamethrower'
    })

    for _, i in list do
    	AutoPyro:CreateToggle({
    		Name = 'Buy ' .. i,
    		Tooltip = 'Automatically upgrades this flamethrower ability when you have enough currency',
    		Default = true
    	})
    end
end)

run(function()
    local AutoRamil
    local Range
    local Sorts
    local Targets
    local UseTornando
    local TonradoRange

    AutoRamil = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Ramil',
    	Tooltip = 'Automates the Ramil tornado placement',
    	Function = function(callback)
    		if callback then
    			repeat
    				if entitylib.isAlive and store.equippedKit == 'airbender' then
    					local localPosition = entitylib.character.RootPart.Position
    					local ent = entitylib.EntityPosition({
    						Origin = localPosition,
    						Range = (UseTornando.Enabled and TonradoRange.Value > Range.Value and TonradoRange.Value or Range.Value),
    						Wallcheck = Targets.Walls.Enabled,
    						Players = Targets.Players.Enabled,
    						NPCs = Targets.NPCs.Enabled,
    						Sort = sortmethods[Sorts.Value],
    					})

    					if ent then
    						if (localPosition - ent.RootPart.Position).Magnitude <= Range.Value and bedwars.AbilityController:canUseAbility('airbender_tornado') then
    							bedwars.AbilityController:useAbility('airbender_tornado')
    						end

    						if UseTornando.Enabled and (localPosition - ent.RootPart.Position).Magnitude <= TonradoRange.Value and bedwars.AbilityController:canUseAbility('airbender_moving_tornado') then
    							bedwars.AbilityController:useAbility('airbender_moving_tornado')
    						end
    					end
    				end
    				task.wait()
    			until not AutoRamil.Enabled
    		end
    	end,
    	Tooltip = 'Automatically uses the ramil kit'
    })

    Targets = AutoRamil:CreateTargets({
    	Tooltip = 'Configure which types of targets to include',
    	Players = true,
    	NPCs = false
    })
    local methods = {'Damage', 'Distance'}
    for i in sortmethods do
    	if not table.find(methods, i) then
    		table.insert(methods, i)
    	end
    end
    Sorts = AutoRamil:CreateDropdown({
    	Name = 'Target Mode',
    	Tooltip = 'Selects how targets are prioritized and selected',
    	List = methods,
    	Default = 'Distance',
    	ItemTooltips = {
    		Distance = 'Targets the closest enemy by stud distance',
    		Health = 'Targets the enemy with the lowest remaining health',
    		Angle = 'Targets the enemy closest to your look direction',
    		Cursor = 'Targets the enemy nearest to your mouse cursor',
    		Damage = 'Targets the enemy who most recently took damage',
    		Threat = 'Targets the enemy judged to be the greatest combat threat',
    		Kit = 'Prioritizes dangerous kit users (Hannah, Spirit Assassin, etc.)',
    	}
    })
    Range = AutoRamil:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 25,
    	Default = 25,
    	Suffix = function(val)
    		return val >= 1 and 'studs' or 'stud'
    	end
    })
    UseTornando = AutoRamil:CreateToggle({
    	Name = 'Use Moving Tornado',
    	Tooltip = 'Places a moving tornado instead of a static one',
    	Function = function(call)
    		pcall(function()
    			TonradoRange.Object.Visible = call
    		end)
    	end
    })
    TonradoRange = AutoRamil:CreateSlider({
    	Name = 'Tornado Range',
    	Tooltip = 'Distance in studs for tornado placement',
    	Min = 1,
    	Max = 35,
    	Default = 25,
    	Darker = true,
    	Visible = false,
    	Suffix = function(val)
    		return val >= 1 and 'studs' or 'stud'
    	end
    })
end)

run(function()
    local AutoSheep
    local Delay
    local Range

    AutoSheep = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Sheep Herder',
    	Tooltip = 'Automates the Sheep Herder kit',
    	Function = function(callback)
    		if callback then
    			repeat
    				if entitylib.isAlive then
    					local localPosition = entitylib.character.RootPart.Position
    					local model = workspace:FindFirstChild('SheepModel')

    					for _, v in model:GetChildren() do
    						if v.PrimaryPart and (localPosition - v.PrimaryPart.Position).Magnitude <= Range.Value then
    							if Delay.Value > 0 then
    								task.wait(Delay.Value)
    							end
    							bedwars.Client:GetNamespace('SheepHerder'):Get('TameSheep'):SendToServer(v.SheepData.Value)
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoSheep.Enabled
    		end
    	end,
    	Tooltip = 'Automatically tames sheep at a long range'
    })

    Range = AutoSheep:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 20,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end,
    	Default = 20
    })
    Delay = AutoSheep:CreateSlider({
    	Name = 'Delay',
    	Tooltip = 'Seconds between consecutive actions',
    	Min = 0,
    	Max = 1,
    	Default = 0.1,
    	Decimal = 100
    })
end)

run(function()
    local AutoStar
    local Streamer
    local Range
    local Animation
    local Delay

    AutoStar = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Star Collector',
    	Tooltip = 'Automates the Star Collector kit — collects stars automatically',
    	Function = function(callback)
    		if callback then
    			AutoStar:Clean(proximityPromptService.PromptShown:Connect(function(prompt)
    				if Streamer.Enabled then
    					if prompt.Name == 'stars_ProximityPrompt' then
    						task.wait(0.1)
    						prompt:InputHoldBegin()
    					end
    				end
    			end))

    			repeat
    				if not Streamer.Enabled and entitylib.isAlive then
    					local localPosition = entitylib.character.RootPart.Position
    					for i, v in collectionService:GetTagged('stars') do
    						if
    							tick() > (Delay[v] or 0)
    							and v.PrimaryPart
    							and (localPosition - v.PrimaryPart.Position).Magnitude <= Range.Value
    						then
    							if Delay.Value > 0 then
    								task.wait(Delay.Value)
    							end

    							if (localPosition - v.PrimaryPart.Position).Magnitude <= Range.Value then
    								if Animation.Enabled then
    									bedwars.GameAnimationUtil:playAnimation(lplr.Character, bedwars.AnimationType.PUNCH)
    									bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_USE_ITEM)
    								end
    								bedwars.StarCollectorController:collectEntity(lplr, v, v.Name)
    								Delay[v] = tick() + 1
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoStar.Enabled
    		end
    	end,
    	Tooltip = 'Automatically collects stars'
    })

    Streamer = AutoStar:CreateToggle({
    	Name = 'Streamer mode',
    	Tooltip = 'Enables or disables streamer mode',
    	Function = function(call)
    		pcall(function()
    			Delay.Object.Visible = not call
    			Range.Object.Visible = not call
    			Animation.Object.Visible = not call
    		end)
    	end,
    	Tooltip = 'Hides delay, range, and animation settings from the UI — useful for streaming'
    })
    Animation = AutoStar:CreateToggle({
    	Name = 'Animation',
    	Default = true,
    	Tooltip = 'Plays the collect animation'
    })
    Range = AutoStar:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 20,
    	Default = 12,
    	Suffix = function(val)
    		return val > 1 and 'studs' or 'stud'
    	end
    })
    Delay = AutoStar:CreateSlider({
    	Name = 'Delay',
    	Tooltip = 'Seconds between consecutive actions',
    	Min = 0,
    	Max = 1,
    	Suffix = function(val)
    		return val > 1 and 'secs' or 'sec'
    	end,
    	Default = 0.2,
    	Decimal = 100
    })
end)

run(function()
    local AutoTaliyah
    local Emerald
    local Diamond
    local Iron
    local Amount

    local function getShopNPC()
    	local shop, items, upgrades, newid = nil, false, false, nil
    	if entitylib.isAlive then
    		local localPosition = entitylib.character.RootPart.Position
    		for _, v in store.shop do
    			if (v.RootPart.Position - localPosition).Magnitude <= 20 then
    				shop = v.Upgrades or v.Shop or nil
    				upgrades = upgrades or v.Upgrades
    				items = items or v.Shop
    				newid = v.Shop and v.Id or newid
    			end
    		end
    	end
    	return shop, items, upgrades, newid
    end

    AutoTaliyah = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Taliyah',
    	Tooltip = 'Automatically buy chickens when it sells for emerald',
    	Function = function(callback)
    		if callback then
    			repeat
    				local shopNpc, items, __, id = getShopNPC()
    				if shopNpc and items then
    					local chickenData = bedwars.TaliyahUtil:getPrice()
    					if (chickenData.currency == 'emerald' and Emerald.Enabled or chickenData.currency == 'iron' and Iron.Enabled or chickenData.currency == 'diamond' and Diamond.Enabled) and chickenData.price >= Amount.Value then
    						local item = bedwars.Shop.getShopItem('chicken_shop_item', lplr)

    						bedwars.Client:Get('BedwarsPurchaseItem'):CallServerAsync({
    							shopItem = item,
    							shopId = id
    						}):andThen(function(suc)
    							if suc then
    								bedwars.SoundManager:playSound(bedwars.SoundList.BEDWARS_PURCHASE_ITEM)
    								bedwars.Store:dispatch({
    									type = 'BedwarsAddItemPurchased',
    									itemType = item.itemType
    								})
    								bedwars.BedwarsShopController.alreadyPurchasedMap[item.itemType] = true
    							end
    						end)
    					end
    				end
    				task.wait(0.1)
    			until not AutoTaliyah.Enabled
    		end
    	end,
    })

    Iron = AutoTaliyah:CreateToggle({
    	Name = 'Iron',
    	Default = true,
    	Tooltip = 'Sells ur chicken when the currency is iron'
    })
    Emerald = AutoTaliyah:CreateToggle({
    	Name = 'Emerald',
    	Default = true,
    	Tooltip = 'Sells ur chicken when the currency is emerald'
    })
    Diamond = AutoTaliyah:CreateToggle({
    	Name = 'Diamond',
    	Default = true,
    	Tooltip = 'Sells ur chicken when the currency is diamond'
    })
    Amount = AutoTaliyah:CreateSlider({
    	Name = 'Amount',
    	Default = 2,
    	Min = 1,
    	Max = 1000,
    	Tooltip = 'Only sells if the currency is selling for the selected amount'
    })
end)

run(function()
    local AutoUma
    local Range
    local Limit
    local Animation
    local AutoSummon
    local HealSpirit
    local AttackSpirit
    local TargetItemDrops
    local Diamond
    local Emerald

    local function getAttackData()
    	if Limit.Enabled then
    		local tool = (store.hand.tool and store.hand.tool.Name == 'spirit_staff') and store.hand.tool or nil
    		return tool, tool and getHotbar(tool) or nil
    	end
    	for i, v in store.inventory.inventory.items do
    		if v.itemType == 'spirit_staff' then
    			switchItem(v, 0)
    			return v, i
    		end
    	end
    	return
    end

    local function getDrops(localPosition, ItemDrops)
    	local drop, lastmag = nil, Range.Value + 1
    	for i, v in ItemDrops do
    		if v.Name == 'emerald' and Emerald.Enabled or v.Name == 'diamond' and Diamond.Enabled then
    			local magnitude = (localPosition - v.Position).Magnitude
    			if magnitude <= lastmag and not entitylib.Wallcheck(localPosition, v.Position, {gameCamera, lplr.Character, v}) then
    				drop, lastmag = v, magnitude
    			end
    		end
    	end
    	return drop
    end

    AutoUma = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Uma',
    	Tooltip = 'Automates the Uma kit spirit abilities',
    	Function = function(call)
    		if call then
    			repeat
    				local items = collection('ItemDrop', AutoUma)
    				local staff = getAttackData()
    				if staff then
    					if TargetItemDrops.Enabled then
    						local attackSpirits = (lplr:GetAttribute('ReadySummonedAttackSpirits') or 0)
    						local healSpirits = (lplr:GetAttribute('ReadySummonedHealSpirits') or 0)

    						if AutoSummon.Enabled then
    							if AttackSpirit.Enabled and attackSpirits < 1 and getItem('summon_stone') then
    								bedwars.AbilityController:useAbility('summon_attack_spirit')
    							end

    							if HealSpirit.Enabled and healSpirits < 1 and getItem('summon_stone') then
    								bedwars.AbilityController:useAbility('summon_heal_spirit')
    							end
    						end

    						if (healSpirits + attackSpirits) > 0 then
    							local localPosition = entitylib.character.RootPart.Position
    							local drop = getDrops(localPosition, items)

    							if drop then
    								local shootpos = localPosition + Vector3.new(0, 2, 0)
    								local dir = CFrame.lookAt(localPosition, drop.Position + Vector3.new(0, (localPosition - drop.Position).Magnitude / 5, 0)).LookVector * 100

    								bedwars.Client:Get(remotes.FireProjectile).instance:InvokeServer(
    									staff,
    									nil,
    									attackSpirits > 0 and 'attack_spirit' or 'heal_spirit',
    									shootpos,
    									localPosition,
    									dir,
    									httpService:GenerateGUID(),
    									{
    										drawDurationSeconds = 1,
    										shotId = httpService:GenerateGUID(false),
    									},
    									workspace:GetServerTimeNow() - 0.045
    								)

    								if Animation.Enabled then
    									bedwars.GameAnimationUtil:playAnimation(lplr.Character, bedwars.AnimationType.WIZARD_BALL_CAST)
    									bedwars.SoundManager:playSound(bedwars.SoundList.SPIRIT_SUMMONER_CHANGE_AFFINITY, {})
    								end

    								task.wait(1.5)
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoUma.Enabled
    		end
    	end,
    	Tooltip = 'Automatically uses uma kit'
    })

    Range = AutoUma:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 80,
    	Default = 50,
    	Decimal = 5,
    	Suffix = function(val)
    		return val >= 2 and 'studs' or 'stud'
    	end
    })
    Animation = AutoUma:CreateToggle({
    	Name = 'Animation',
    	Tooltip = 'Shows the kit ability animation when activated',
    	Default = true
    })
    Limit = AutoUma:CreateToggle({
    	Name = 'Limit to item',
    	Tooltip = 'Only activates when a required item is in your hand',
    	Default = true
    })
    AutoSummon = AutoUma:CreateToggle({
    	Name = 'Auto Summon',
    	Tooltip = 'Enables or disables auto summon',
    	Function = function(call)
    		pcall(function()
    			AttackSpirit.Object.Visible = call
    			HealSpirit.Object.Visible = call
    		end)
    	end,
    	Tooltip = 'Automatically summons a spirit companion to assist you in combat'
    })
    HealSpirit = AutoUma:CreateToggle({
    	Name = 'Use heal spirit',
    	Tooltip = 'Automatically deploys the healing spirit',
    	Default = true,
    	Visible = false,
    	Darker = true
    })
    AttackSpirit = AutoUma:CreateToggle({
    	Name = 'Use attack spirit',
    	Tooltip = 'Automatically deploys the attack spirit',
    	Default = true,
    	Visible = false,
    	Darker = true
    })
    TargetItemDrops = AutoUma:CreateToggle({
    	Name = 'Target item drops',
    	Tooltip = 'Targets item drops for automatic collection',
    	Default = true,
    	Function = function(call)
    		pcall(function()
    			Emerald.Object.Visible = call
    			Diamond.Object.Visible = call
    		end)
    	end
    })
    Emerald = AutoUma:CreateToggle({
    	Name = 'Emerald',
    	Tooltip = 'Includes emerald resources',
    	Darker = true,
    	Default = true
    })
    Diamond = AutoUma:CreateToggle({
    	Name = 'Diamond',
    	Tooltip = 'Includes diamond resources',
    	Darker = true,
    	Default = true
    })
end)

run(function()
    local AutoWhisper
    local PlayerDropdown
    local AutoHeal
    local AutoHealSlider
    local AutoFly
    local LimitToItem
    local RefreshButton
    local running = false
    local healRunning = false
    local flyRunning = false
    local currentTarget = nil
    local currentMountedPlayer = nil
    local fallCheckTimer = 0
    local hasActivatedFly = false
    
    local function isHoldingOwlOrb()
        if not entitylib.isAlive then return false end
        
        local inventory = store.inventory
        if inventory and inventory.inventory and inventory.inventory.hand then
            local handItem = inventory.inventory.hand
            if handItem and handItem.itemType == "owl_orb" then
                return true
            end
        end
        return false
    end
    
    local function getMountedPlayer()
        local owlTarget = lplr:GetAttribute('OwlTarget')
        if owlTarget then
            return playersService:GetPlayerByUserId(owlTarget)
        end
        return nil
    end
    
    local function mountBirdToPlayer(targetPlayer)
        if not targetPlayer or not targetPlayer.Character then return false end
        
        if LimitToItem.Enabled and not isHoldingOwlOrb() then
            return false
        end
        
        local success = false
        pcall(function()
            local result = bedwars.Client:Get(remotes.SummonOwl).instance:InvokeServer(targetPlayer)
            
            if result then
            task.wait(0.05)
            
            pcall(function()
    			bedwars.Client:Get(remotes.UseAbility).instance:FireServer("SUMMON_OWL")
			end)
                
                currentMountedPlayer = targetPlayer
                success = true
            end
        end)
        
        return success
    end
    
    local function demountOwl()
        pcall(function()
            bedwars.Client:Get(remotes.UseAbility).instance:FireServer("DEACTIVE_OWL")
            
            task.wait(0.05)
            
            bedwars.Client:Get(remotes.RemoveOwl).instance:FireServer()
        end)
        
        currentMountedPlayer = nil
    end
    
    local function healTarget()
        pcall(function()
            replicatedStorage:WaitForChild("events-@easy-games/game-core:shared/game-core-networking@getEvents.Events"):WaitForChild("useAbility"):FireServer("OWL_HEAL")
        end)
    end
    
    local function isFalling(player)
        if not player or not player.Character or not player.Character.PrimaryPart then
            return false
        end
        
        local velocity = player.Character.PrimaryPart.AssemblyLinearVelocity.Y
        return velocity < -20
    end
    
	local voidRayParams = RaycastParams.new()
	voidRayParams.FilterType = Enum.RaycastFilterType.Blacklist
	voidRayParams.RespectCanCollide = true

	local function isAboveVoid(player)
		if not player or not player.Character or not player.Character.PrimaryPart then
			return false
		end
		
		local rayOrigin = player.Character.PrimaryPart.Position
		local rayDirection = Vector3.new(0, -1000, 0)
		
		voidRayParams.FilterDescendantsInstances = {player.Character, gameCamera}
		
		local rayResult = workspace:Raycast(rayOrigin, rayDirection, voidRayParams)
		
		if not rayResult then
			return true
		end
		
		return rayResult.Distance > 200
	end
    
    local function activateFly()
        pcall(function()
            replicatedStorage:WaitForChild("events-@easy-games/game-core:shared/game-core-networking@getEvents.Events"):WaitForChild("useAbility"):FireServer("OWL_LIFT")
            
            hasActivatedFly = true
            task.spawn(function()
                task.wait(85)
                hasActivatedFly = false
            end)
        end)
    end
    
    AutoWhisper = vain.Categories.Kit:CreateModule({
        Name = "Auto Whisper",
        Function = function(callback)
            running = callback
            healRunning = callback
            flyRunning = callback
            
            if callback then
                task.spawn(function()
                    while running do
                        if LimitToItem.Enabled and not isHoldingOwlOrb() then
                            task.wait(0.2)
                            continue
                        end
                        
                        local targetPlayer = playersService:FindFirstChild(PlayerDropdown.Value)
                        if targetPlayer then
                            currentTarget = targetPlayer
                            
                            local mountedTo = getMountedPlayer()
                            
                            if mountedTo ~= targetPlayer then
                                if mountedTo and mountedTo ~= targetPlayer then
                                    demountOwl()
                                    task.wait(0.3)
                                end
                                
                                if not mountedTo or mountedTo ~= targetPlayer then
                                    local success = mountBirdToPlayer(targetPlayer)
                                    if not success then
                                        task.wait(0.5)
                                    else
                                        task.wait(1)
                                    end
                                end
                            else
                                task.wait(0.5)
                            end
                        else
                            task.wait(0.5)
                        end
                    end
                end)
                
                if AutoHeal.Enabled then
                    task.spawn(function()
                        while healRunning and AutoHeal.Enabled do
                            if currentTarget then
                                local health, maxHealth = getPlayerHealth(currentTarget)
                                if health and maxHealth and maxHealth > 0 then
                                    local healthPercent = (health / maxHealth) * 100
                                    if healthPercent < AutoHealSlider.Value and healthPercent < 90 then
                                        healTarget()
                                        task.wait(8.5)
                                    end
                                end
                            end
                            
                            task.wait(0.5)
                        end
                    end)
                end
                
                if AutoFly.Enabled then
                    task.spawn(function()
                        while flyRunning and AutoFly.Enabled do
                            if currentTarget and not hasActivatedFly then
                                if isFalling(currentTarget) and isAboveVoid(currentTarget) then
                                    fallCheckTimer = fallCheckTimer + 0.1
                                    
                                    if fallCheckTimer >= 0.5 then
                                        activateFly()
                                        fallCheckTimer = 0
                                    end
                                else
                                    fallCheckTimer = 0
                                end
                            else
                                fallCheckTimer = 0
                            end
                            
                            task.wait(0.1)
                        end
                    end)
                end
                
                AutoWhisper:Clean(playersService.PlayerAdded:Connect(function()
                    task.wait(0.5)
                    local newList = getTeammates(true)
                    if PlayerDropdown then
                        PlayerDropdown:Change(newList)
                        
                        if #newList > 0 then
                            if not PlayerDropdown.Value or PlayerDropdown.Value == "" or not table.find(newList, PlayerDropdown.Value) then
                                PlayerDropdown:SetValue(newList[1])
                            end
                        end
                    end
                end))
                
                AutoWhisper:Clean(playersService.PlayerRemoving:Connect(function(player)
                    task.wait(0.5)
                    local newList = getTeammates(true)
                    if PlayerDropdown then
                        PlayerDropdown:Change(newList)
                        
                        if #newList > 0 then
                            if not PlayerDropdown.Value or PlayerDropdown.Value == "" or not table.find(newList, PlayerDropdown.Value) then
                                PlayerDropdown:SetValue(newList[1])
                            end
                        end
                    end
                    
                    if currentTarget == player then
                        currentTarget = nil
                        currentMountedPlayer = nil
                    end
                end))
                
                AutoWhisper:Clean(lplr:GetAttributeChangedSignal('Team'):Connect(function()
                    task.wait(0.5)
                    local newList = getTeammates(true)
                    if PlayerDropdown then
                        PlayerDropdown:Change(newList)
                        
                        if #newList > 0 then
                            if not PlayerDropdown.Value or PlayerDropdown.Value == "" or not table.find(newList, PlayerDropdown.Value) then
                                PlayerDropdown:SetValue(newList[1])
                            end
                        end
                    end
                    currentTarget = nil
                    currentMountedPlayer = nil
                    hasActivatedFly = false
                end))
                
            else
                running = false
                healRunning = false
                flyRunning = false
                currentTarget = nil
                currentMountedPlayer = nil
                hasActivatedFly = false
                fallCheckTimer = 0
            end
        end,
        Tooltip = "Automatically mount bird to teammate, heal them, and save from void"
    })
    
    PlayerDropdown = AutoWhisper:CreateDropdown({
        Name = "Mount Target",
        List = {},
        Function = function(val)
            if val then
                local targetPlayer = playersService:FindFirstChild(val)
                if targetPlayer then
                    currentTarget = targetPlayer
                end
            end
        end,
        Tooltip = "Select teammate to mount owl to"
    })
    RefreshButton = AutoWhisper:CreateButton({
        Name = "Refresh Teammates",
        Tooltip = "Re-scans your team for the teammate dropdown above",
        Function = function()
            task.spawn(function()
                local newList = getTeammates(true)
                
                if PlayerDropdown then
                    pcall(function()
                        PlayerDropdown:Change(newList)
                        
                        if #newList > 0 then
                            if not PlayerDropdown.Value or PlayerDropdown.Value == "" or not table.find(newList, PlayerDropdown.Value) then
                                PlayerDropdown:SetValue(newList[1])
                            else
                                PlayerDropdown:SetValue(PlayerDropdown.Value)
                            end
                        end
                    end)
                end
                
                notif("Auto Whisper", string.format("Refreshed teammate list (%d teammates)", #newList), 2)
            end)
        end,
        Tooltip = "Manually refresh the teammate list"
    })
    
    LimitToItem = AutoWhisper:CreateToggle({
        Name = "Limit to Owl Orb",
        Default = true,
        Function = function(val)
        end,
        Tooltip = "Only mount owl when holding owl_orb item"
    })

    AutoFly = AutoWhisper:CreateToggle({
        Name = "Auto Fly",
        Default = true,
        Function = function(val)
            if AutoWhisper.Enabled then
                if val then
                    flyRunning = true
                    hasActivatedFly = false
                    fallCheckTimer = 0
                    
                    task.spawn(function()
                        while flyRunning and AutoFly.Enabled do
                            if currentTarget and not hasActivatedFly then
                                if isFalling(currentTarget) and isAboveVoid(currentTarget) then
                                    fallCheckTimer = fallCheckTimer + 0.1
                                    
                                    if fallCheckTimer >= 0.5 then
                                        activateFly()
                                        fallCheckTimer = 0
                                    end
                                else
                                    fallCheckTimer = 0
                                end
                            else
                                fallCheckTimer = 0
                            end
                            
                            task.wait(0.1)
                        end
                    end)
                else
                    flyRunning = false
                    hasActivatedFly = false
                    fallCheckTimer = 0
                end
            end
        end,
        Tooltip = "Automatically activate lift when target is falling into void"
    })
    
    AutoHeal = AutoWhisper:CreateToggle({
        Name = "Auto Heal",
        Default = true,
        Function = function(val)
            if AutoHealSlider and AutoHealSlider.Object then
                AutoHealSlider.Object.Visible = val
            end
            
            if AutoWhisper.Enabled then
                if val then
                    healRunning = true
                    task.spawn(function()
                        while healRunning and AutoHeal.Enabled do
                            if currentTarget then
                                local health, maxHealth = getPlayerHealth(currentTarget)
                                if not (health and maxHealth and maxHealth > 0) then task.wait(0.5) continue end
                                local healthPercent = (health / maxHealth) * 100
                                if healthPercent < AutoHealSlider.Value and healthPercent < 90 then
                                    healTarget()
                                    task.wait(8.5)
                                end
                            end
                            
                            task.wait(0.5)
                        end
                    end)
                else
                    healRunning = false
                end
            end
        end,
        Tooltip = "Automatically heal target when health drops below threshold"
    })
    
    AutoHealSlider = AutoWhisper:CreateSlider({
        Name = "Heal Threshold",
        Min = 1,
        Max = 100,
        Default = 50,
        Suffix = "%",
        Tooltip = "Heal when target's health drops below this percentage (stops at 90%)"
    })
end)

run(function()
    local AutoZeno
    local Targets
    local TargetMode
    local Limit
    local AutoShockWave
    local ShockwaveRange
    local UseStrike
    local UseStorm
    local Range
    local Delay

    local function getAttackData()
    	if Limit.Enabled then
    		local tool = (store.hand.tool and store.hand.tool.Name:find('wizard_staff')) and store.hand.tool or nil
    		return tool, tool and getHotbar(tool) or nil, tool and (tonumber(tool.Name:sub(#tool.Name, #tool.Name)) or 1) or nil
    	end

    	for i, v in store.inventory.inventory.items do
    		if v.itemType:find('wizard_staff') then
    			switchItem(v, 0)
    			return v, i, tonumber(v.itemType:sub(#v.itemType, #v.itemType)) or 1
    		end
    	end

    	return
    end

    AutoZeno = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Zeno',
    	Tooltip = 'Automates the Zeno kit lightning and shockwave',
    	Function = function(call)
    		if call then
    			repeat
    				if entitylib.isAlive then
    					local staff, __, level = getAttackData()

    					if staff then
    						local localPosition = entitylib.character.RootPart.Position
    						local ent = entitylib.EntityPosition({
    							Origin = localPosition,
    							Range = (Range.Value < 6 and AutoShockWave.Enabled and 7) or Range.Value,
    							Part = 'RootPart',
    							Players = Targets.Players.Enabled,
    							NPCs = Targets.NPCs.Enabled,
    							Sort = sortmethods[TargetMode.Value],
    						})

    						if ent then
    							if AutoShockWave.Enabled and level > 2 then
    								if
    									bedwars.AbilityController:canUseAbility('SHOCKWAVE')
    									and (localPosition - ent.RootPart.Position).Magnitude <= ShockwaveRange.Value
    								then
    									bedwars.AbilityController:useAbility('SHOCKWAVE', newproxy(true), {
    										target = CFrame.lookAt(localPosition, ent.RootPart.Position).LookVector,
    									})
    									task.wait(Delay.Value)
    								end
    							end

    							if UseStrike.Enabled and bedwars.AbilityController:canUseAbility('LIGHTNING_STRIKE') then
    								bedwars.AbilityController:useAbility('LIGHTNING_STRIKE', newproxy(true), {
    									target = ent.RootPart.Position + ((ent.Humanoid.MoveDirection or Vector3.zero) * (1 + lplr:GetNetworkPing())),
    								})
    								task.wait(Delay.Value)
    							end

    							if UseStorm.Enabled and level > 1 then
    								if bedwars.AbilityController:canUseAbility('LIGHTNING_STORM') then
    									bedwars.AbilityController:useAbility('LIGHTNING_STORM', newproxy(true), {
    										target = ent.RootPart.Position + ((ent.Humanoid.MoveDirection or Vector3.zero) * (1 + lplr:GetNetworkPing())),
    									})
    									task.wait(Delay.Value)
    								end
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoZeno.Enabled
    		end
    	end,
    	Tooltip = 'Automatically uses zeno\'s staff'
    })

    Targets = AutoZeno:CreateTargets({
    	Tooltip = 'Configure which types of targets to include',
    	Players = true,
    	NPCs = false,
    })
    local methods = {'Damage', 'Distance'}
    for i in sortmethods do
    	if not table.find(methods, i) then
    		table.insert(methods, i)
    	end
    end
    TargetMode = AutoZeno:CreateDropdown({
    	Name = 'Target Mode',
    	Tooltip = 'Selects how targets are prioritized and selected',
    	List = methods,
    	Default = 'Distance',
    	ItemTooltips = {
    		Distance = 'Targets the closest enemy by stud distance',
    		Health = 'Targets the enemy with the lowest remaining health',
    		Angle = 'Targets the enemy closest to your look direction',
    		Cursor = 'Targets the enemy nearest to your mouse cursor',
    		Damage = 'Targets the enemy who most recently took damage',
    		Threat = 'Targets the enemy judged to be the greatest combat threat',
    		Kit = 'Prioritizes dangerous kit users (Hannah, Spirit Assassin, etc.)',
    	}
    })
    Limit = AutoZeno:CreateToggle({
    	Name = 'Limit to item',
    	Tooltip = 'Only activates when a required item is in your hand',
    	Default = true
    })
    UseStrike = AutoZeno:CreateToggle({
    	Name = 'Use Lightning Strike',
    	Tooltip = 'Uses the lightning strike ability automatically',
    	Default = true
    })
    UseStorm = AutoZeno:CreateToggle({Name = 'Use Lightning Storm', Tooltip = 'Automatically uses the Lightning Storm ability to hit multiple nearby enemies at once'})
    AutoShockWave = AutoZeno:CreateToggle({
    	Name = 'Auto Shockwave',
    	Tooltip = 'Enables or disables auto shockwave',
    	Function = function(call)
    		pcall(function()
    			ShockwaveRange.Object.Visible = call
    		end)
    	end,
    	Tooltip = 'Automatically uses the shockwave ability when a target is near',
    })
    ShockwaveRange = AutoZeno:CreateSlider({
    	Name = 'Shockwave Range',
    	Tooltip = 'Radius in studs of the shockwave effect',
    	Visible = false,
    	Darker = true,
    	Min = 1,
    	Max = 12,
    	Suffix = function(val)
    		return val > 1 and 'studs' or 'stud'
    	end,
    	Decimal = 5,
    	Default = 12
    })
    Range = AutoZeno:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 60,
    	Default = 35,
    	Suffix = function(val)
    		return val > 1 and 'studs' or 'stud'
    	end,
    	Decimal = 5
    })
    Delay = AutoZeno:CreateSlider({
    	Name = 'Delay',
    	Tooltip = 'Seconds between consecutive actions',
    	Min = 0,
    	Max = 10,
    	Default = 0.5,
    	Decimal = 5,
    	Suffix = function(val)
    		return val > 1 and 'secs' or 'sec'
    	end
    })
end)

run(function()
    local DaveyAim
    local Range
    local Mode
    local Launch

    local rayCheck = RaycastParams.new()
    rayCheck.RespectCanCollide = true

    DaveyAim = vain.Categories.Kit:CreateModule({
    	Name = 'Davey Aim',
    	Tooltip = 'Automatically aims the Davey kit cannon at enemies',
    	Function = function(call)
    		if call then
    			DaveyAim:Toggle()
    			local targetpos
    			local ray = cloneref(lplr:GetMouse()).UnitRay
    			rayCheck.FilterDescendantsInstances = {lplr.Character, gameCamera}
    			ray = workspace:Raycast(ray.Origin, ray.Direction * 1000000, rayCheck)
    			if ray then
    				targetpos = ray.Position
    			end

    			if targetpos then
    				local cannon, dis = nil, Range.Value + 0.1
    				for _, v in collectionService:GetTagged('block') do
    					local mag = (entitylib.character.RootPart.Position - v.Position).Magnitude
    					if v.Name == 'cannon' and mag < dis then
    						cannon = v
    						dis = mag
    						break
    					end
    				end

    				if cannon then
    					local lookpos, blockpos = targetpos, bedwars.BlockController:getBlockPosition(cannon.Position)
    					if lookpos then
    						if Mode.Value == 'Legit' then
    							cannon.AimPrompt:InputHoldBegin()
    							task.wait(cannon.AimPrompt.HoldDuration)
    							local wait = tick() + 0.3
    							repeat
    								gameCamera.CFrame = gameCamera.CFrame:Lerp(CFrame.lookAt(gameCamera.CFrame.p, lookpos), 22 * runService.PostSimulation:Wait())
    								bedwars.Client:Get(remotes.CannonAim):SendToServer({
    									cannonBlockPos = blockpos,
    									lookVector = gameCamera.CFrame.LookVector,
    								})
    							until tick() > wait
    							cannon.StopAimingPrompt:InputHoldBegin()
    							task.wait(cannon.StopAimingPrompt.HoldDuration + runService.PostSimulation:Wait()) -- the hold duration is zero, but just incase...
    							if Launch.Enabled then
    								cannon.LaunchSelfPrompt:InputHoldBegin()
    								task.wait(cannon.LaunchSelfPrompt.HoldDuration + runService.PostSimulation:Wait())
    							end
    						else
    							bedwars.Client:Get(remotes.CannonAim):SendToServer({
    								cannonBlockPos = blockpos,
    								lookVector = CFrame.lookAt(cannon.Position, lookpos).LookVector * 200,
    							})
    							task.wait(0.5)
    							if Launch.Enabled then
    								bedwars.CannonHandController:launchSelf(cannon)
    							end
    						end
    					end
    				end
    			end
    		end
    	end,
    	Tooltip = 'Automatically aims cannon'
    })

    Mode = DaveyAim:CreateDropdown({
    	Name = 'Aim Mode',
    	Tooltip = 'Selects the aiming technique',
    	List = {'Fast', 'Legit'},
    	Default = 'Fast',
    	ItemTooltips = {
    		Fast = 'Instantly snaps the cannon aim to the target each frame',
    		Legit = 'Smoothly lerps the cannon aim toward the target for a human-like appearance',
    	},
    })
    DaveyAim:CreateDropdown({
    	Name = 'Position Mode',
    	Tooltip = 'Selects the reference position for aiming',
    	List = {'Mouse', 'Camera'},
    	Default = 'Mouse',
    	ItemTooltips = {
    		Mouse = 'Aims the cannon based on your mouse cursor position',
    		Camera = 'Aims the cannon based on where the camera is looking',
    	}
    })
    Range = DaveyAim:CreateSlider({
    	Name = 'Search Range',
    	Tooltip = 'Distance in studs to search for targets',
    	Min = 1,
    	Max = 30,
    	Default = 10,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end
    })
    Launch = DaveyAim:CreateToggle({
    	Name = 'Launch Cannon',
    	Tooltip = 'Automatically launches the Davey cannon at enemies',
    	Default = true
    })
end)

run(function()
    local FishermanSpy
    local Teammates
    local GoldNotify
    local DiamondNotify
    local EmeraldNotify
    local Whitelist

    -- fishModel -> {word to announce, hex color for that word in the message}
    local SPECIAL_FISH = {
    	fish_gold = {'Gold', '#FFD75A'},
    	fish_diamond = {'Diamond', '#5AD7FF'},
    	fish_emerald = {'Emerald', '#5AFF7A'},
    }

    local function isWhitelisted(itemDisplay)
    	if #Whitelist.ListEnabled <= 0 then return true end
    	local lower = itemDisplay:lower()
    	for _, v in Whitelist.ListEnabled do
    		if v:lower() == lower then return true end
    	end
    	return false
    end

    FishermanSpy = vain.Categories.Kit:CreateModule({
    	Name = 'Fisherman Spy',
    	Tooltip = 'Reveals targets caught by the Fisherman kit',
    	Function = function(call)
    		if call then
    			FishermanSpy:Clean(bedwars.Client:Get('FishCaught'):Connect(function(data)
    				if data.dropData and data.dropData.drops and data.catchingPlayer then
    					local isEnemy = not Teammates.Enabled or lplr.Team ~= data.catchingPlayer.Team

    					local text = {}
    					for _, v in data.dropData.drops do
    						local itemDisplay = bedwars.ItemMeta[v.itemType] and bedwars.ItemMeta[v.itemType].displayName or v.itemType
    						if not isWhitelisted(itemDisplay) then continue end
    						-- FishCaught's own amount field reports one less than what's
    						-- actually received (4 diamonds caught shows as 3), so +1 here
    						-- to match reality.
    						local amount = v.amount + 1
    						-- These are resource names (Iron, Gold, TNT, ...), not countable
    						-- objects -- BedWars itself never pluralizes them ("10 Iron", not
    						-- "10 Irons"), so use the display name as-is with no added 's'.
    						table.insert(text, `{amount} {itemDisplay}`)
    					end

    					if #text > 0 and isEnemy then
    						notif('Fisherman Spy', `{data.catchingPlayer.Name} caught {table.concat(text, ', ')}`, 8, 'info')
    					end

    					local special = SPECIAL_FISH[data.dropData.fishModel]
    					local specialToggle = data.dropData.fishModel == 'fish_gold' and GoldNotify
    						or data.dropData.fishModel == 'fish_diamond' and DiamondNotify
    						or data.dropData.fishModel == 'fish_emerald' and EmeraldNotify
    					if special and specialToggle and specialToggle.Enabled and isEnemy then
    						local word, hex = special[1], special[2]
    						notif('Fisherman Spy', `{data.catchingPlayer.Name} has caught a <font color='{hex}'>{word}</font> fish`, 8, 'info')
    					end
    				end
    			end))
    		end
    	end
    })

    Teammates = FishermanSpy:CreateToggle({
    	Name = 'Ignore teammate',
    	Tooltip = 'Ignores players on your own team',
    	Default = true
    })
    GoldNotify = FishermanSpy:CreateToggle({
    	Name = 'Notify on Gold',
    	Tooltip = 'Sends a dedicated notification whenever anyone catches a Gold Fish',
    	Default = false
    })
    DiamondNotify = FishermanSpy:CreateToggle({
    	Name = 'Notify on Diamond',
    	Tooltip = 'Sends a dedicated notification whenever anyone catches a Diamond Fish',
    	Default = false
    })
    EmeraldNotify = FishermanSpy:CreateToggle({
    	Name = 'Notify on Emerald',
    	Tooltip = 'Sends a dedicated notification whenever anyone catches an Emerald Fish',
    	Default = false
    })
    Whitelist = FishermanSpy:CreateTextList({
    	Name = 'Loot Whitelist',
    	Tooltip = 'Only shows catches of these items in the notification (leave empty to show all loot)',
    	Placeholder = 'item name (e.g. Diamond)',
    })
end)

run(function()
    local old

    vain.Categories.Kit:CreateModule({
    	Name = 'Infinite Krystal',
    	Tooltip = 'Gives you max momentum forever',
    	Function = function(call)
    		if call then
    			old = bedwars.GlacialSkaterController.updateMomentum
    			bedwars.GlacialSkaterController.updateMomentum = function(self, ...)
    				self.momentum = 9e9
    				self.lastMomentumReport = 9e9
    				return old(self, ...)
    			end
    		else
    			bedwars.GlacialSkaterController.updateMomentum = old
    		end
    	end
    })
end)

run(function()
    local SigridExploit
    local Kit, Mount = 'elk_master', bedwars.Client:Get('ElkKitMounted')

    SigridExploit = vain.Categories.Kit:CreateModule({
    	Name = 'Infinite Sigrid',
    	Tooltip = 'Lets you ride in the elk forever',
    	Function = function(call)
    		if call then
    			repeat
    				if entitylib.isAlive then
    					if store.equippedKit == Kit then
    						Mount:SendToServer()
    					end
    				end
    				task.wait()
    			until not SigridExploit.Enabled
    		end
    	end
    })
end)

--[[
    Legit
]]

run(function()
    local AutoVanessa
    local oldGetChargeTime
    local lastChargeTime = 0
    
    AutoVanessa = vain.Categories.Kit:CreateModule({
        Name = 'Auto Vanessa',
        Tooltip = 'Automates the Vanessa kit ability',
        Function = function(callback)
            if callback then
                task.spawn(function()
                    repeat task.wait() until bedwars.TripleShotProjectileController
                    
                    if bedwars.TripleShotProjectileController then
                        oldGetChargeTime = bedwars.TripleShotProjectileController.getChargeTime
                        
                        bedwars.TripleShotProjectileController.getChargeTime = function(self)
                            return 0
                        end
                        
                        bedwars.TripleShotProjectileController.overchargeStartTime = tick()
                    end
                end)
            else
                if oldGetChargeTime and bedwars.TripleShotProjectileController then
                    bedwars.TripleShotProjectileController.getChargeTime = oldGetChargeTime
                end
                lastChargeTime = 0
            end
        end,
        Tooltip = 'Auto charges Vanessa triple shot'
    })
end)

run(function()
	local AutoJack
	local InstantCharge
	local ChargeSpeed
	local TorchAimbot
	local TorchTarget
	local TorchRange
	local torchHookRemove
	local chargeHookRemove
	local chargeTimeConn
	local InfiniteOil
	local lastThrow = 0
	local launchThrottleConn
	local ThrowCooldown
	local AutoIgnite
	local lastIgnite = 0
	local igniteThrowAt = {}
	-- Jack was reworked into a charge-to-throw kit: holding the Oil Spitter builds a
	-- charge (full at maxStrengthChargeSec = 3s) that decides the oil blob's size /
	-- splash-blob count. Two things need to reflect the boosted charge:
	--   1. The throw itself. The charge that reaches the server is the launch payload's
	--      drawDurationSec, taken straight from the launch table's drawDurationSeconds,
	--      so chargeBoost overrides that value on the ProjectileLaunchHook at throw time
	--      (like the torch aim above) -- this guarantees a full throw even on a fast tap.
	--   2. The on-screen charge bar during the hold. The bar is driven by the game's own
	--      per-frame loop: v54 = drawDurationSeconds / maxChargeTime, and the top bar /
	--      velocityMultiplier follow v54. Writing drawDurationSeconds ourselves races
	--      that loop and doesn't stick; instead we shrink maxChargeTime (via the
	--      ProjectileMaxChargeTimeModifierCheck sync event) while the oil spitter is
	--      charging, so the game's OWN loop fills the bar faster / instantly. We also
	--      backdate startChargingTIme in the hold loop so the Oil cost bar keeps pace.
	local MAX_CHARGE = 3
	-- Oil Spitter minStrengthScalar: the throw-strength floor at zero charge. Used to
	-- rescale the launch velocity so a forced-full charge also throws at full range.
	local MIN_STRENGTH = 0.7692307692307692

	-- Force the oil charge on the outgoing throw. jack_oil_projectile only -- the hook
	-- fires for every projectile, so we gate on the projectile name (no held-item
	-- check needed). Instant Charge sends a full charge; Charge Speed multiplies the
	-- charge the player actually built. The launch velocity is rescaled to match the
	-- forced charge so the blob is both max-size and thrown at the matching strength.
	local function chargeBoost(nextLaunch, ...)
		local res = nextLaunch(...)
		if not (AutoJack and AutoJack.Enabled) then return res end
		if type(res) ~= 'table' then return res end
		local projmeta = select(2, ...)
		if not projmeta or projmeta.projectile ~= 'jack_oil_projectile' then return res end

		local instant = InstantCharge and InstantCharge.Enabled
		local speed = (ChargeSpeed and ChargeSpeed.Value) or 1
		local baseDraw = res.drawDurationSeconds or 0
		local newDraw = baseDraw
		if instant then
			newDraw = MAX_CHARGE
		elseif speed > 1 then
			newDraw = math.min(MAX_CHARGE, baseDraw * speed)
		end
		if newDraw ~= baseDraw then
			res.drawDurationSeconds = newDraw
			local iv = res.initialVelocity
			if iv and iv.Magnitude > 0 then
				local ok, meta = pcall(function() return projmeta:getProjectileMeta() end)
				local baseSpeed = (ok and meta and meta.launchVelocity) or 80
				local v54 = math.min(1, newDraw / MAX_CHARGE)
				res.initialVelocity = iv.Unit * baseSpeed * (v54 + (1 - v54) * MIN_STRENGTH)
			end
		end
		return res
	end

	-- ClientSyncEvents lives as an upvalue of ProjectileSourceController.beginHolding
	-- (inherited by OilSpitterController). Scan its upvalues for the table that owns the
	-- charge-time modifier rather than hard-coding an index, so a reorder can't break us.
	local function getClientSyncEvents()
		local fn = bedwars.OilSpitterController and bedwars.OilSpitterController.beginHolding
		if type(fn) ~= 'function' then return nil end
		for i = 1, 24 do
			local ok, up = pcall(debug.getupvalue, fn, i)
			if ok and type(up) == 'table' and up.ProjectileMaxChargeTimeModifierCheck then
				return up
			end
		end
		return nil
	end

	-- Shrink the oil spitter's max charge time so the game's own hold loop fills the
	-- charge bar (and velocityMultiplier / throw strength) faster or instantly. The check
	-- fires once per hold with only the charge seconds, so we scope it to oil by only
	-- acting while OilSpitterController is charging -- other projectiles are untouched.
	local function installChargeTimeHook()
		if chargeTimeConn then return end
		local events = getClientSyncEvents()
		if not events then return end
		-- Throw throttle: the spitter has no built-in re-fire cooldown, so drop any oil
		-- launch that comes sooner than the Throw Cooldown slider after the last one,
		-- capping how fast you can re-throw. Cancelling StartLaunchProjectile is the same
		-- drop the game's own oil<10 gate uses, so it is clean.
		if not launchThrottleConn then
			launchThrottleConn = events.StartLaunchProjectile:connect(function(event)
				if not (AutoJack and AutoJack.Enabled) then return end
				if event.projectileType ~= 'jack_oil_projectile' then return end
				local cd = (ThrowCooldown and ThrowCooldown.Value) or 0.05
				local now = os.clock()
				if now - lastThrow < cd then
					event:setCancelled(true)
				else
					lastThrow = now
				end
			end)
		end
		chargeTimeConn = events.ProjectileMaxChargeTimeModifierCheck:connect(function(p)
			if not (AutoJack and AutoJack.Enabled) then return end
			local oil = bedwars.OilSpitterController
			if not (oil and oil.isCharging) then return end
			if not (p and type(p.maxChargeTime) == 'number') then return end
			if InstantCharge and InstantCharge.Enabled then
				p.maxChargeTime = 0.01
			else
				local speed = (ChargeSpeed and ChargeSpeed.Value) or 1
				if speed > 1 then
					p.maxChargeTime = p.maxChargeTime / speed
				end
			end
		end)
	end

	local function removeChargeTimeHook()
		if chargeTimeConn then
			pcall(function() chargeTimeConn:Destroy() end)
			chargeTimeConn = nil
		end
		if launchThrottleConn then
			pcall(function() launchThrottleConn:Destroy() end)
			launchThrottleConn = nil
		end
	end

	-- Torch (Fire Match) silent aim. The Fire Match is a normal projectile thrown
	-- through ProjectileController, so hooking calculateImportantLaunchValues and
	-- gating on projmeta.projectile == 'fire_match' scopes this to the torch alone --
	-- the hook only fires when the torch itself is thrown, so no held-item check is
	-- needed. Targets come from OilBlobController.spillMap (seed -> oil part); each
	-- part's Size.X tracks the puddle radius, so Biggest/Smallest sort by that.
	local function pickOilBlob(originPos)
		local controller = bedwars.OilBlobController
		if not controller or not controller.spillMap then return nil end
		local sort = TorchTarget and TorchTarget.Value or 'Nearest'
		local range = TorchRange and TorchRange.Value or 300
		-- Cursor mode ranks by nearness to the mouse on screen, so it needs the
		-- camera and the current mouse location up front.
		local camera = workspace.CurrentCamera
		local mousePos = (sort == 'Cursor' and camera and inputService) and inputService:GetMouseLocation() or nil
		local best, bestScore
		for _, part in pairs(controller.spillMap) do
			if typeof(part) == 'Instance' and part.Parent then
				local dist = (part.Position - originPos).Magnitude
				if dist <= range then
					local score
					if sort == 'Cursor' then
						if mousePos then
							local screenPos, onScreen = camera:WorldToViewportPoint(part.Position)
							if onScreen then
								score = -(Vector2.new(screenPos.X, screenPos.Y) - mousePos).Magnitude
							end
						end
					elseif sort == 'Farthest' then
						score = dist
					elseif sort == 'Biggest' then
						score = part.Size.X
					elseif sort == 'Smallest' then
						score = -part.Size.X
					else -- Nearest
						score = -dist
					end
					-- score stays nil for a Cursor blob that is off screen: skip it.
					if score and (not bestScore or score > bestScore) then
						bestScore, best = score, part
					end
				end
			end
		end
		return best
	end

	-- An ignited oil blob gets Burn particle emitters (Rate 45) parented in by the
	-- OilFlame handler, so treat a blob that has one as already lit.
	local function isBurning(part)
		for _, d in ipairs(part:GetDescendants()) do
			if d:IsA('ParticleEmitter') and d.Rate == 45 then
				return true
			end
		end
		return false
	end

	-- Throw a Fire Match at a world point (fire_match: velocity 80, gravity 35), the
	-- same resource-throwable launch path as the other projectiles. Needs Fire Match ammo.
	local function fireMatchAt(position)
		local item = getItem('fire_match')
		if not (item and item.tool) then return end
		if not (entitylib.character and entitylib.character.RootPart) then return end
		local localPosition = entitylib.character.RootPart.Position
		local meta = bedwars.ProjectileMeta.fire_match
		if not meta then return end
		local calc = prediction.SolveTrajectory(localPosition, meta.launchVelocity, meta.gravitationalAcceleration, position, Vector3.zero, workspace.Gravity, 0, 0)
		if calc then position = calc end
		local shootPosition = (CFrame.new(localPosition, position) * CFrame.new(Vector3.new(-bedwars.BowConstantsTable.RelX, -bedwars.BowConstantsTable.RelY, -bedwars.BowConstantsTable.RelZ))).Position
		bedwars.Client:Get(remotes.FireProjectile):CallServerAsync(
			item.tool,
			'fire_match',
			'fire_match',
			shootPosition,
			localPosition,
			CFrame.lookAt(localPosition, position).LookVector * meta.launchVelocity,
			httpService:GenerateGUID(true),
			{ drawDurationSeconds = 0.25, shotId = httpService:GenerateGUID(false) },
			workspace:GetServerTimeNow() - 0.045
		)
	end

	local function torchAim(nextLaunch, ...)
		if not (TorchAimbot and TorchAimbot.Enabled) then
			return nextLaunch(...)
		end
		local self, projmeta, worldmeta, origin, shootpos = ...
		if not projmeta or projmeta.projectile ~= 'fire_match' then
			return nextLaunch(...)
		end
		local pos = shootpos or (self.getLaunchPosition and self:getLaunchPosition(origin))
		if not pos then return nextLaunch(...) end
		local offsetpos = pos + (projmeta.fromPositionOffset or Vector3.zero)

		local blob = pickOilBlob(offsetpos)
		if not blob then return nextLaunch(...) end

		local meta = projmeta:getProjectileMeta()
		local projSpeed = meta.launchVelocity or 80
		local gravity = (meta.gravitationalAcceleration or 35) * (projmeta.gravityMultiplier or 1)
		local lifetime = worldmeta and (meta.predictionLifetimeSec or meta.lifetimeSec or 3) or (meta.lifetimeSec or 3)

		-- Static ground target: zero target velocity and hipHeight/jumping 0 (mirrors
		-- the telepearl static-point solve used by MouseTPs).
		local calc = prediction.SolveTrajectory(offsetpos, projSpeed, gravity, blob.Position, Vector3.zero, workspace.Gravity, 0, 0)
		if not calc then return nextLaunch(...) end

		local aimDir = CFrame.new(offsetpos, calc).LookVector
		return {
			initialVelocity = aimDir * projSpeed,
			positionFrom = offsetpos,
			deltaT = lifetime,
			gravitationalAcceleration = gravity,
			-- fire_match caps its charge at 0.25s; 1 is well past that, so the server
			-- reads a full-strength throw consistent with the overridden velocity.
			drawDurationSeconds = 1
		}
	end

	AutoJack = vain.Categories.Kit:CreateModule({
		Name = 'Auto Jack',
		Tooltip = 'Charge assist for the Jack (Oil Spitter) kit: instantly full-charge every oil blob, or just build the charge faster.',
		Function = function(callback)
			if not callback then
				if torchHookRemove then
					torchHookRemove()
					torchHookRemove = nil
				end
				if chargeHookRemove then
					chargeHookRemove()
					chargeHookRemove = nil
				end
				removeChargeTimeHook()
				return
			end
			if bedwars.ProjectileLaunchHook then
				if not torchHookRemove then
					torchHookRemove = bedwars.ProjectileLaunchHook:Add('JackTorchAim', 5, torchAim)
				end
				if not chargeHookRemove then
					chargeHookRemove = bedwars.ProjectileLaunchHook:Add('JackCharge', 6, chargeBoost)
				end
			end
			task.spawn(function()
				repeat task.wait() until bedwars.OilSpitterController
				-- The max-charge-time hook drives the on-screen charge bar; install it
				-- once the controller (and its inherited beginHolding upvalue) exists.
				installChargeTimeHook()
				while AutoJack.Enabled do
					local dt = task.wait()
					local controller = bedwars.OilSpitterController
					if controller and controller.isCharging then
						local instant = InstantCharge.Enabled
						local speed = ChargeSpeed.Value
						-- Keep the Oil cost bar (getChargeDuration, driven by
						-- startChargingTIme) in step with the boosted charge.
						if instant then
							controller.startChargingTIme = workspace:GetServerTimeNow() - MAX_CHARGE
						elseif speed > 1 then
							controller.startChargingTIme = controller.startChargingTIme - (speed - 1) * dt
						end
					end
					-- Infinite Oil: the game blocks aiming/throwing the spitter when your OilAmount
					-- attribute is under 10 (its client StartLaunchProjectile / BeginProjectileTargeting
					-- gates). Topping the local attribute up keeps those gates open so you can aim and
					-- throw full blobs at empty, and the oil bar reads full. The server still owns the real oil.
					if InfiniteOil and InfiniteOil.Enabled and store.hand and store.hand.tool and store.hand.tool.Name == 'oil_spitter' then
						lplr:SetAttribute('OilAmount', 100)
					end
					-- Auto Ignite: lob a Fire Match at any oil blob that is not yet burning so
					-- thrown oil lights itself. Ignition is server-authoritative (only a fire
					-- source lights oil), so this just automates the torch throw and needs Fire
					-- Match ammo. Per-blob and global cooldowns keep it from wasting matches.
					if AutoIgnite and AutoIgnite.Enabled and os.clock() - lastIgnite >= 0.25 then
						local ctrl = bedwars.OilBlobController
						local root = entitylib.character and entitylib.character.RootPart
						if ctrl and ctrl.spillMap and root then
							local best, bestDist, bestSeed
							for seed, part in pairs(ctrl.spillMap) do
								if typeof(part) == 'Instance' and part.Parent and not isBurning(part) then
									local prev = igniteThrowAt[seed]
									if not (prev and os.clock() - prev < 1) then
										local d = (part.Position - root.Position).Magnitude
										if not bestDist or d < bestDist then
											bestDist, best, bestSeed = d, part, seed
										end
									end
								end
							end
							if best then
								fireMatchAt(best.Position)
								igniteThrowAt[bestSeed] = os.clock()
								lastIgnite = os.clock()
							end
						end
					end
				end
			end)
		end
	})
	InstantCharge = AutoJack:CreateToggle({
		Name = 'Instant Charge',
		Tooltip = 'Fills the oil charge to maximum immediately, so every blob is thrown full-size with no hold time',
		Default = false
	})
	ChargeSpeed = AutoJack:CreateSlider({
		Name = 'Charge Speed',
		Tooltip = 'How many times faster the oil charge builds (ignored while Instant Charge is on)',
		Min = 1,
		Max = 10,
		Default = 2,
		Decimal = 10,
		Suffix = 'x'
	})
	ThrowCooldown = AutoJack:CreateSlider({
		Name = 'Throw Cooldown',
		Tooltip = 'Minimum seconds between oil throws; a release that comes sooner than this is dropped, capping how fast you can re-throw',
		Min = 0.01,
		Max = 1,
		Default = 0.05,
		Decimal = 100,
		Suffix = 's'
	})
	InfiniteOil = AutoJack:CreateToggle({
		Name = 'Infinite Oil',
		Tooltip = 'Keeps your oil topped up on the client so you can aim and throw full-size blobs even at empty (the bar reads full). The server still decides whether an empty throw actually lands',
		Default = false
	})
	TorchAimbot = AutoJack:CreateToggle({
		Name = 'Torch Aimbot',
		Tooltip = 'While the Fire Match (torch) is thrown, silently aims it at an oil blob so it lands on the oil and ignites it every time, like Projectile Aimbot but scoped to the torch and targeting oil blobs',
		Default = false
	})
	TorchTarget = AutoJack:CreateDropdown({
		Name = 'Torch Target',
		List = {'Nearest', 'Farthest', 'Biggest', 'Smallest', 'Cursor'},
		Default = 'Nearest',
		Tooltip = 'Which oil blob the torch aims at: nearest/farthest to you, the biggest/smallest puddle, or the one closest to your cursor'
	})
	TorchRange = AutoJack:CreateSlider({
		Name = 'Torch Range',
		Tooltip = 'Only aim the torch at oil blobs within this many studs',
		Min = 10,
		Max = 2000,
		Default = 500,
		Decimal = 1,
		Suffix = ' studs'
	})
	AutoIgnite = AutoJack:CreateToggle({
		Name = 'Auto Ignite',
		Tooltip = 'Automatically lobs a Fire Match at your oil blobs to set them alight, so you do not throw the torch yourself (needs Fire Match ammo)',
		Default = false
	})
end)

run(function()
    local PromptUnlock

    local savedPromptStates = {}

    PromptUnlock = vain.Categories.Kit:CreateModule({
        Name = 'Prompt Unlock',
        Tooltip = 'enables all proximity prompts in the game',
        Function = function(callback)
            if callback then
                savedPromptStates = {}
                for _, v in workspace:GetDescendants() do
                    if v:IsA('ProximityPrompt') then
                        savedPromptStates[v] = v.Enabled
                        v.Enabled = true
                    end
                end
                PromptUnlock:Clean(workspace.DescendantAdded:Connect(function(v)
                    if not PromptUnlock.Enabled then return end
                    if v:IsA('ProximityPrompt') then
                        savedPromptStates[v] = v.Enabled
                        v.Enabled = true
                    end
                end))
            else
                for prompt, state in savedPromptStates do
                    if prompt and prompt.Parent then
                        prompt.Enabled = state
                    end
                end
                savedPromptStates = {}
            end
        end
    })
end)

run(function()
    local Fisherman
    local AutoMinigameToggle
    local CompleteDelaySlider
    local PullAnimationToggle
    local MinigameAnimationToggle
    local BlacklistOption
    local Blacklist
    local ESPToggle
	local AutoCastDelay
	local AutoCast
    local ESPNotifyToggle
    local Players    = playersService
    local RunService = runService
    local lplr       = Players.LocalPlayer
	local RandomizeToggle
    local RandomRange
	local waitTime
    local fishNames = {
        fish_iron    = "Iron Fish",
        fish_diamond = "Diamond Fish",
        fish_gold    = "Gold Fish",
        fish_special = "Special Fish",
        fish_emerald = "Emerald Fish",
    }

    local function buildMessage(fishModel, drops)
        local fishName = fishNames[fishModel] or fishModel

        if fishModel == "fish_special" then
            if drops and drops[1] then
                return "You caught a " .. fishName .. "! You will receive a " .. tostring(drops[1].itemType)
            else
                return "You caught a " .. fishName .. "! (special item incoming)"
            end
        end

        if drops and drops[1] then
            local drop = drops[1]
            return "You caught a " .. fishName .. "! Receiving " ..
                   tostring(drop.amount) .. "x " .. tostring(drop.itemType)
        end

        return "You caught a " .. fishName .. "!"
    end

    local notifQueue = {}

    local function safeNotif(title, message, duration)
        table.insert(notifQueue, { title = title, message = message, duration = duration or 5 })
    end

    local heartbeatConn = nil

    local autoMinigameActive    = false
    local pullAnimationTrack    = nil
    local successAnimationTrack = nil
    local espOld                = nil

	local function getBait()
		for _, v in workspace:GetChildren() do
			if v.Name == "fisherman_bobber" and v:GetAttribute("ProjectileShooter") == lplr.UserId then
				return v
			end
		end

		return
	end

    local function stopAllAnimations()
        if pullAnimationTrack then
            pcall(function() pullAnimationTrack:Stop() end)
            pullAnimationTrack = nil
        end
        if successAnimationTrack then
            pcall(function() successAnimationTrack:Stop() end)
            successAnimationTrack = nil
        end
    end

    local function setupESP()
        if not bedwars or not bedwars.FishingMinigameController then
            warn("[AutoFisher] FishingMinigameController not found")
            return
        end
        if espOld then return end 
        espOld = bedwars.FishingMinigameController.startMinigame

        bedwars.FishingMinigameController.startMinigame = function(self, dropData, result)
            if ESPToggle.Enabled and ESPNotifyToggle.Enabled and dropData and dropData.fishModel then
                safeNotif("Fisherman ESP", buildMessage(dropData.fishModel, dropData.drops), 8)
            end
            return espOld(self, dropData, result)
        end

        Fisherman:Clean(function()
            if espOld then
                bedwars.FishingMinigameController.startMinigame = espOld
                espOld = nil
            end
        end)
    end

    local function cleanupESP()
        if espOld then
            bedwars.FishingMinigameController.startMinigame = espOld
            espOld = nil
        end
    end

    local function setupAutoMinigame()
        if not bedwars or not bedwars.FishingMinigameController then
            warn("[AutoFisher] FishingMinigameController not found")
            return
        end

        local old = bedwars.FishingMinigameController.startMinigame

        bedwars.FishingMinigameController.startMinigame = function(self, dropData, result)
            if not AutoMinigameToggle.Enabled then
                return old(self, dropData, result)
            end

            if BlacklistOption.Enabled and dropData and dropData.fishModel then
                if table.find(Blacklist.ListEnabled, dropData.fishModel) then
                    local hum = lplr.Character and lplr.Character:FindFirstChildOfClass("Humanoid")
                    if hum and hum:GetState() ~= Enum.HumanoidStateType.Jumping then
                        hum:ChangeState(Enum.HumanoidStateType.Jumping)
                    end
                    return old(self, dropData, result)
                end
            end

            autoMinigameActive = true
            stopAllAnimations()

            local waitTime = 0
            if RandomizeToggle and RandomizeToggle.Enabled then
                local min = RandomRange.ValueMin
                local max = RandomRange.ValueMax
                waitTime = min + (max - min) * math.random()
            else
                waitTime = CompleteDelaySlider.Value
            end

            task.spawn(function()
                if PullAnimationToggle.Enabled and waitTime > 0 then
                    local ok, track = pcall(function()
                        return bedwars.GameAnimationUtil:playAnimation(
                            lplr, bedwars.AnimationType.FISHING_ROD_PULLING
                        )
                    end)
                    if ok and track then pullAnimationTrack = track end
                end

                if waitTime > 0 then
                    task.wait(waitTime)
                end

                if pullAnimationTrack then
                    pcall(function() pullAnimationTrack:Stop() end)
                    pullAnimationTrack = nil
                end

                if MinigameAnimationToggle.Enabled then
                    local ok, track = pcall(function()
                        return bedwars.GameAnimationUtil:playAnimation(
                            lplr, bedwars.AnimationType.FISHING_ROD_CATCH_SUCCESS
                        )
                    end)
                    if ok and track then successAnimationTrack = track end
                end

                if result then
                    pcall(function() result({ win = true }) end)
                end

                task.wait(0.5)

                if successAnimationTrack then
                    pcall(function() successAnimationTrack:Stop() end)
                    successAnimationTrack = nil
                end

                autoMinigameActive = false
            end)
        end

        Fisherman:Clean(function()
            bedwars.FishingMinigameController.startMinigame = old
            stopAllAnimations()
        end)
    end

	local function setupAutoCast()
		task.spawn(function()
			repeat
				if entitylib.isAlive and AutoCast.Enabled and (store.hand.tool and store.hand.tool.Name == 'fishing_rod') then
					local position = workspace.CurrentCamera.ViewportSize / 2
					local ray = cloneref(lplr:GetMouse()).UnitRay

					if not getBait() and not workspace:Raycast(entitylib.character.Head.Position + (ray.Direction * 6), Vector3.new(0, -20, 0)) then
						task.wait(AutoCastDelay:GetRandomValue())

						for _, v in {true, false} do
							VirtualInputManager:SendMouseButtonEvent(position.X, position.Y, 0, v, game, 1)
							task.wait()
						end
						task.wait(0.5)
					end
				end
				task.wait(0.1)
			until not Fisherman.Enabled
		end)
	end

    Fisherman = vain.Categories.Kit:CreateModule({
        Name    = "Auto Fisher",
        Tooltip = "Auto minigame, loot ESP, blacklist, AutoCasting, and spy for the Fisherman kit",
        Function = function(callback)
            if callback then
                if ESPToggle.Enabled           then setupESP()          end
                if AutoMinigameToggle.Enabled  then setupAutoMinigame() end
                setupAutoCast()

                heartbeatConn = RunService.Heartbeat:Connect(function()
                    if #notifQueue == 0 then return end
                    local entry = table.remove(notifQueue, 1)
                    pcall(notif, entry.title, entry.message, entry.duration)
                end)
                Fisherman:Clean(heartbeatConn)

            else
                autoMinigameActive = false
                stopAllAnimations()
                cleanupESP()
                notifQueue = {} 
            end
        end
    })

    AutoMinigameToggle = Fisherman:CreateToggle({
        Name    = "Auto Minigame",
        Default = false,
        Tooltip = "Automatically complete the fishing minigame",
        Function = function(cv)
            if CompleteDelaySlider and CompleteDelaySlider.Object then 
                CompleteDelaySlider.Object.Visible = cv and not (RandomizeToggle and RandomizeToggle.Enabled) 
            end
            if PullAnimationToggle     and PullAnimationToggle.Object     then PullAnimationToggle.Object.Visible     = cv end
            if MinigameAnimationToggle and MinigameAnimationToggle.Object then MinigameAnimationToggle.Object.Visible = cv end
            if RandomizeToggle and RandomizeToggle.Object then RandomizeToggle.Object.Visible = cv end
            if RandomRange and RandomRange.Object then RandomRange.Object.Visible = cv and RandomizeToggle.Enabled end
            if Fisherman.Enabled and cv then setupAutoMinigame() end
        end
    })

    CompleteDelaySlider = Fisherman:CreateSlider({
        Name    = "Complete Delay",
        Min     = 0,
        Max     = 5,
        Default = 1,
        Decimal = 10,
        Suffix  = "s",
        Visible = false,
        Tooltip = "Delay before auto-completing (looks more legit)"
    })

    RandomizeToggle = Fisherman:CreateToggle({
        Name    = "Randomize Timing",
        Default = false,
        Tooltip = "Use random delay between min and max instead of fixed delay",
        Function = function(cv)
            if RandomRange and RandomRange.Object then RandomRange.Object.Visible = cv end
            if CompleteDelaySlider and CompleteDelaySlider.Object then CompleteDelaySlider.Object.Visible = not cv end
        end
    })

    RandomRange = Fisherman:CreateTwoSlider({
        Name    = "Random Delay Range",
        Min     = 0.1,
        Max     = 5,
        DefaultMin = 0.5,
        DefaultMax = 2,
        Decimal = 10,
        Visible = false,
        Tooltip = "Minimum and maximum delay for random timing"
    })

    PullAnimationToggle = Fisherman:CreateToggle({
        Name    = "Pull Animation",
        Default = true,
        Visible = false,
        Tooltip = "Play rod-pulling animation during delay (requires delay > 0)"
    })

    MinigameAnimationToggle = Fisherman:CreateToggle({
        Name    = "Success Animation",
        Default = true,
        Visible = false,
        Tooltip = "Play catch-success animation on completion"
    })

    BlacklistOption = Fisherman:CreateToggle({
        Name    = "Blacklist",
        Default = false,
        Tooltip = "Auto-jump and skip auto-complete for blacklisted fish",
        Function = function(cv)
            if Blacklist and Blacklist.Object then Blacklist.Object.Visible = cv end
        end
    })

    Blacklist = Fisherman:CreateTextList({
        Name    = "Blacklist Fish",
        Tooltip = "Fish types to skip auto-catching (one per line)",
        Default = { "fish_iron" }
    })

	AutoCast = Fisherman:CreateToggle({
		Name 	= "AutoCast",
		Tooltip = 'Automatically casts the ability when available',
		Default = false,
		Function = function(callback)
			if callback then
				if AutoCastDelay and AutoCastDelay.Object then AutoCastDelay.Object.Visible = callback end
				if AutoCast.Enabled and callback then setupAutoCast() end
			end
		end
	})

	AutoCastDelay = Fisherman:CreateTwoSlider({
		Name 	= "Cast Delay",
		Min 	= 0,
		Max 	= 5,
		Decimal = 5,
		DefaultMin = 0.3,
		DefaultMax = 1.2,
		Darker 	= true,
		Visible = AutoCast.Enabled
	})	

    ESPToggle = Fisherman:CreateToggle({
        Name    = "Fisherman ESP",
        Default = false,
        Tooltip = "Shows what fish you are catching and what loot you will receive",
        Function = function(cv)
            if ESPNotifyToggle and ESPNotifyToggle.Object then ESPNotifyToggle.Object.Visible = cv end
            if Fisherman.Enabled then
                if cv then setupESP() else cleanupESP() end
            end
        end
    })

    ESPNotifyToggle = Fisherman:CreateToggle({
        Name    = "Notify Loot",
        Default = true,
        Visible = false,
        Tooltip = "Show a notification with the fish name and loot details"
    })
end)

run(function()
    local StarCollector
    local CollectionToggle
    local Animation
    local RangeSlider
    local ESPToggle
    local ESPNotify
    local ESPBackground
    local ESPColor
    local SwordCheck
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local Reference = {}
    local starCooldowns = {}
    local COOLDOWN_TIME = 0.5
    local lastNotification = 0
    local spawnQueue = {}
    local notificationCooldown = 1
    local collectionRunning = false

    local function sendNotification(count)
        notif("Star ESP", string.format("%d stars spawned", count), 3)
    end

    local function processSpawnQueue()
        if #spawnQueue > 0 then
            local currentTime = tick()
            if currentTime - lastNotification >= notificationCooldown then
                sendNotification(#spawnQueue)
                lastNotification = currentTime
                spawnQueue = {}
            else
                task.delay(notificationCooldown - (currentTime - lastNotification), function()
                    if #spawnQueue > 0 then
                        sendNotification(#spawnQueue)
                        spawnQueue = {}
                    end
                end)
            end
        end
    end

    local function getProperImage(v)
        local parent = v.Parent
        if parent and parent:IsA("Model") then
            local modelName = parent.Name
            if modelName == "CritStar" then
                return bedwars.getIcon({itemType = 'crit_star'}, true)
            elseif modelName == "VitalityStar" then
                return bedwars.getIcon({itemType = 'vitality_star'}, true)
            elseif modelName:find("vitality") or modelName:lower():find("vitality") then
                return bedwars.getIcon({itemType = 'vitality_star'}, true)
            elseif modelName:find("crit") or modelName:lower():find("crit") then
                return bedwars.getIcon({itemType = 'crit_star'}, true)
            end
        end
        return bedwars.getIcon({itemType = 'crit_star'}, true)
    end

    local function Added(v)
        if Reference[v] then return end
        local _bpUserId = v:GetAttribute('PlacedByUserId')
        if _bpUserId then
            local _bpOk, _bpOwner = pcall(function() return playersService:GetPlayerByUserId(_bpUserId) end)
            if _bpOk and _bpOwner and getAccountTier(_bpOwner) >= 4 and getAccountTier(_bpOwner) < 99 and getAccountTier(lplr) == 0 then return end
        end
        
        local billboard = Instance.new('BillboardGui')
        billboard.Parent = Folder
        billboard.Name = 'stars'
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
        billboard.Size = UDim2.fromOffset(36, 36)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = v
        
        local blur = addBlur(billboard)
        blur.Visible = ESPBackground.Enabled
        
        local image = Instance.new('ImageLabel')
        image.Size = UDim2.fromOffset(36, 36)
        image.Position = UDim2.fromScale(0.5, 0.5)
        image.AnchorPoint = Vector2.new(0.5, 0.5)
        image.BackgroundColor3 = Color3.fromHSV(ESPColor.Hue, ESPColor.Sat, ESPColor.Value)
        image.BackgroundTransparency = 1 - (ESPBackground.Enabled and ESPColor.Opacity or 0)
        image.BorderSizePixel = 0
        image.Image = getProperImage(v)
        image.Parent = billboard
        
        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 4)
        uicorner.Parent = image
        
        Reference[v] = billboard
        
        if ESPNotify.Enabled then
            table.insert(spawnQueue, {item = 'star', time = tick()})
            processSpawnQueue()
        end
    end

    local function Removed(v)
        if Reference[v] then
            Reference[v]:Destroy()
            Reference[v] = nil
        end
        starCooldowns[v] = nil
    end

    local function setupESP()
        for _, v in collectionService:GetTagged('stars') do
            if v:IsA("Model") and v.PrimaryPart then
                Added(v.PrimaryPart)
            end
        end

        StarCollector:Clean(collectionService:GetInstanceAddedSignal('stars'):Connect(function(v)
            if v:IsA("Model") and v.PrimaryPart then
                task.wait(0.1)
                Added(v.PrimaryPart)
            end
        end))

        StarCollector:Clean(collectionService:GetInstanceRemovedSignal('stars'):Connect(function(v)
            if v.PrimaryPart then
                Removed(v.PrimaryPart)
            end
        end))
        
        local _scLastUpdate = 0
        StarCollector:Clean(runService.RenderStepped:Connect(function()
            if not ESPToggle.Enabled then return end
            local _now = tick()
            if _now - _scLastUpdate < 0.1 then return end
            _scLastUpdate = _now
            
            for v, billboard in pairs(Reference) do
                if not v or not v.Parent then
                    Removed(v)
                    continue
                end

                local shouldShow = true

                if SwordCheck.Enabled and isSword() then
                    shouldShow = false
                end

                billboard.Enabled = shouldShow
            end
        end))
    end

    local function collectStar(star)
        if not star or not star.Parent then return end
        
        if Animation.Enabled and entitylib.isAlive then
            bedwars.GameAnimationUtil:playAnimation(lplr, bedwars.AnimationType.PUNCH)
            bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_USE_ITEM)
        end
        
        bedwars.StarCollectorController:collectEntity(lplr, star, star.Name)
    end

	local function startCollection()
		collectionRunning = true
		task.spawn(function()
			while collectionRunning and StarCollector.Enabled and CollectionToggle.Enabled do
				if not entitylib.isAlive then
					task.wait(0.1)
					continue
				end

				local localPosition = entitylib.character.RootPart.Position
				local range = RangeSlider.Value
				local collected = false

				for _, v in collectionService:GetTagged('stars') do
					if not collectionRunning or not StarCollector.Enabled or not CollectionToggle.Enabled then
						break
					end

					if v:IsA("Model") and v.PrimaryPart then
						local starPos = v.PrimaryPart.Position
						local distance = (localPosition - starPos).Magnitude

						if distance <= range then
							local lastAttempt = starCooldowns[v]
							if lastAttempt and tick() - lastAttempt < COOLDOWN_TIME then
								continue
							end
							starCooldowns[v] = tick()
							collectStar(v)
							collected = true
							break
						end
					end
				end

				task.wait(collected and 0.1 or 0.2)
			end
			collectionRunning = false
		end)
	end

    StarCollector = vain.Categories.Kit:CreateModule({
        Name = 'Auto Star',
        Tooltip = 'Automatically collects falling stars',
        Function = function(callback)
            if callback then
                if ESPToggle.Enabled then 
                    setupESP() 
                end
                
                if CollectionToggle.Enabled then
                    startCollection()
                end
            else
                collectionRunning = false
                Folder:ClearAllChildren()
                table.clear(Reference)
                table.clear(spawnQueue)
                table.clear(starCooldowns)
                lastNotification = 0
            end
        end,
        Tooltip = 'automatically collects stars and esp'
    })
    
    CollectionToggle = StarCollector:CreateToggle({
        Name = 'Auto Collect',
        Default = true,
        Tooltip = 'automatically collect stars',
        Function = function(callback)
            if Animation and Animation.Object then Animation.Object.Visible = callback end
            if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = callback end
            
            if callback and StarCollector.Enabled then
                startCollection()
            else
                collectionRunning = false
            end
        end
    })
    
    Animation = StarCollector:CreateToggle({
        Name = 'Animation',
        Default = true,
        Tooltip = 'play collection animation and sound'
    })
    
    RangeSlider = StarCollector:CreateSlider({
        Name = 'Range',
        Min = 1, 
        Max = 18,
        Default = 10,
        Decimal = 1,
        Suffix = ' studs',
        Tooltip = 'control distance you want to collect stars'
    })
    
    ESPToggle = StarCollector:CreateToggle({
        Name = 'Star ESP',
        Default = false,
        Tooltip = 'shows star locations',
        Function = function(callback)
            if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = callback end
            if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = callback end
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            if SwordCheck and SwordCheck.Object then SwordCheck.Object.Visible = callback end
            
            if StarCollector.Enabled then
                if callback then 
                    setupESP() 
                else
                    Folder:ClearAllChildren()
                    table.clear(Reference)
                end
            end
        end
    })
    
    ESPNotify = StarCollector:CreateToggle({
        Name = 'Notify',
        Default = false,
        Tooltip = 'get notifications when stars spawn'
    })
    
    ESPBackground = StarCollector:CreateToggle({
        Name = 'Background',
        Tooltip = 'Renders a background box behind this ESP element',
        Default = true,
        Function = function(callback)
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundTransparency = 1 - (callback and ESPColor.Opacity or 0)
                    if v:FindFirstChild("Blur") then
                        v.Blur.Visible = callback
                    end
                end
            end
        end
    })
    
    ESPColor = StarCollector:CreateColorSlider({
        Name = 'Background Color',
        Tooltip = 'Color of the background box behind this ESP element',
        DefaultValue = 0,
        DefaultOpacity = 0.5,
        Function = function(hue, sat, val, opacity)
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                    v.ImageLabel.BackgroundTransparency = 1 - opacity
                end
            end
        end,
        Darker = true
    })
    SwordCheck = StarCollector:CreateToggle({
        Name = 'Sword Check',
        Default = false,
        Tooltip = 'only show esp when holding a sword'
    })

    task.defer(function()
        local espOn = ESPToggle and ESPToggle.Enabled
        if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = espOn end
        if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = espOn end
        if ESPColor and ESPColor.Object then ESPColor.Object.Visible = espOn end
        if SwordCheck and SwordCheck.Object then SwordCheck.Object.Visible = espOn end
    end)
end)

run(function()
    local Gingerbread
    local LimitToItem
    local BreakDelay
    local BreakDelaySlider
    local AutoSwitch
    local SwitchMode
    
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local lastBreakTime = 0
    local lastPlaceTime = 0
    local placeCheckConnection
    local justPlacedGumdrop = false
    local lastPlacedPosition = nil
    
    _G.gingerLock = _G.gingerLock or false
    
    local function getGumdropSlot()
        for i, v in store.inventory.hotbar do
            if v.item and v.item.itemType == "gumdrop_bounce_pad" then
                return i - 1
            end
        end
        return nil
    end
    
    local function getPredictedPosition()
        if not (lplr.Character and lplr.Character.PrimaryPart) then return nil end
        local root = lplr.Character.PrimaryPart
        local velocity = root.AssemblyLinearVelocity
        local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
        local speed = horizontalVelocity.Magnitude
        if speed < 1 then return root.Position end
        local predictionTime = math.clamp(speed / 40, 0.15, 0.35)
        return root.Position + (horizontalVelocity * predictionTime)
    end
    
    local function tryPlaceGumdrop()
        if not AutoSwitch.Enabled or _G.gingerLock then return end
        if not (lplr.Character and lplr.Character.PrimaryPart) then return end
        
        local inFirstPerson = isFirstPerson()
        if SwitchMode.Value == 'First Person' and not inFirstPerson then return end
        if SwitchMode.Value == 'Third Person' and inFirstPerson then return end
        
        local velocity = lplr.Character.PrimaryPart.AssemblyLinearVelocity.Y
        if velocity >= -5 then return end
        
        local gumdropSlot = getGumdropSlot()
        if not gumdropSlot then return end
        
        local root = lplr.Character.PrimaryPart
        local targetPos = getPredictedPosition() or root.Position
        local checkPos = targetPos - Vector3.new(0, 3, 0)
        local groundBlockPos = nil
        
        for i = 1, 16 do
            local testPos = checkPos - Vector3.new(0, 3 * (i - 1), 0)
            local block, blockpos = getPlacedBlock(roundPos(testPos))
            if block then
                groundBlockPos = blockpos * 3
                break
            end
        end
        
        if not groundBlockPos then return end
        
        local distanceToGround = root.Position.Y - groundBlockPos.Y
        if distanceToGround < 9 or distanceToGround > 18 then return end
        
        local placePos = groundBlockPos + Vector3.new(0, 3, 0)
        if lastPlacedPosition and (lastPlacedPosition - placePos).Magnitude < 1 then return end
        if getPlacedBlock(placePos) then return end
        
        _G.gingerLock = true
        
        if hotbarSwitch(gumdropSlot) then
            task.wait(0.03)
            local success = pcall(function()
                bedwars.placeBlock(placePos, "gumdrop_bounce_pad", false)
            end)
            
            if success then
                lastPlaceTime = tick()
                justPlacedGumdrop = true
                lastPlacedPosition = placePos
                
                task.wait(0.03)
                local pickaxeSlot = getPickaxeSlot()
                if pickaxeSlot then
                    hotbarSwitch(pickaxeSlot)
                    task.wait(0.08)
                    local placedBlock = getPlacedBlock(placePos)
                    if placedBlock and placedBlock.Name == "gumdrop_bounce_pad" then
                        task.spawn(bedwars.breakBlock, placedBlock, false, nil, true)
                        lastBreakTime = tick()
                    end
                end
            end
        end
        
        _G.gingerLock = false
    end
    
    Gingerbread = vain.Categories.Kit:CreateModule({
        Name = 'Auto Ginger',
        Tooltip = 'Automates Gingerbread Man kit launch pad usage',
        Function = function(callback)
            if callback then
                local old = bedwars.LaunchPadController.attemptLaunch
                bedwars.LaunchPadController.attemptLaunch = function(...)
                    local res = {old(...)}
                    local self, block = ...
                    
                    if block:GetAttribute('PlacedByUserId') == lplr.UserId and
                       (block.Position - entitylib.character.RootPart.Position).Magnitude < 30 then

                        if LimitToItem.Enabled and not isHoldingPickaxe() then
                            return unpack(res)
                        end

                        local inFP = isFirstPerson()
					local cameraAllowed = not AutoSwitch.Enabled or (SwitchMode.Value ~= 'First Person' or inFP) and (SwitchMode.Value ~= 'Third Person' or not inFP)
					local shouldAutoSwitch = AutoSwitch.Enabled and not isHoldingPickaxe() and cameraAllowed and not _G.gingerLock

                        if shouldAutoSwitch then
                            local pickaxeSlot = getPickaxeSlot()
                            if pickaxeSlot then
                                _G.gingerLock = true
                                task.spawn(function()
                                    if hotbarSwitch(pickaxeSlot) then
                                        task.wait(0.03)
                                        task.spawn(bedwars.breakBlock, block, false, nil, true)
                                        task.spawn(bedwars.breakBlock, block, false, nil, true)
                                        lastBreakTime = tick()
                                        justPlacedGumdrop = false
                                    end
                                    _G.gingerLock = false
                                end)
                            end
                        else
                            local currentTime = tick()
                            local shouldBreak = true
                            if not AutoSwitch.Enabled and BreakDelay.Enabled and not justPlacedGumdrop then
                                if (currentTime - lastBreakTime) < BreakDelaySlider.Value then
                                    shouldBreak = false
                                end
                            end
                            if shouldBreak then
                                task.spawn(bedwars.breakBlock, block, false, nil, true)
                                task.spawn(bedwars.breakBlock, block, false, nil, true)
                                lastBreakTime = currentTime
                                justPlacedGumdrop = false
                            end
                        end

                        local cameraAllowed = true
                        if AutoSwitch.Enabled then
                            local inFirstPerson = isFirstPerson()
                            if SwitchMode.Value == 'First Person' and not inFirstPerson then
                                cameraAllowed = false
                            elseif SwitchMode.Value == 'Third Person' and inFirstPerson then
                                cameraAllowed = false
                            end
                        end

                        if isHoldingPickaxe() then
                            local currentTime = tick()
                            local shouldBreak = true
                            
                            if not AutoSwitch.Enabled and BreakDelay.Enabled and not justPlacedGumdrop then
                                if (currentTime - lastBreakTime) < BreakDelaySlider.Value then
                                    shouldBreak = false
                                end
                            end
                            
                            if shouldBreak then
                                task.spawn(bedwars.breakBlock, block, false, nil, true)
                                task.spawn(bedwars.breakBlock, block, false, nil, true)
                                lastBreakTime = currentTime
                                justPlacedGumdrop = false
                            end
                        elseif AutoSwitch.Enabled and cameraAllowed and not _G.gingerLock then
                            local pickaxeSlot = getPickaxeSlot()
                            if pickaxeSlot then
                                _G.gingerLock = true
                                task.spawn(function()
                                    if hotbarSwitch(pickaxeSlot) then
                                        task.wait(0.03)
                                        task.spawn(bedwars.breakBlock, block, false, nil, true)
                                        task.spawn(bedwars.breakBlock, block, false, nil, true)
                                        lastBreakTime = tick()
                                        justPlacedGumdrop = false
                                    end
                                    _G.gingerLock = false
                                end)
                            end
                        end
                    end
                    
                    return unpack(res)
                end
                
				if AutoSwitch.Enabled then
                    if placeCheckConnection then
                        placeCheckConnection:Disconnect()
                        placeCheckConnection = nil
                    end
                    placeCheckConnection = runService.RenderStepped:Connect(function()
                        if not _G.gingerLock and entitylib.isAlive and tick() - lastPlaceTime > 0.15 then
                            tryPlaceGumdrop()
                        end
                    end)
                end
                
                Gingerbread:Clean(function()
                    bedwars.LaunchPadController.attemptLaunch = old
                    if placeCheckConnection then
                        placeCheckConnection:Disconnect()
                        placeCheckConnection = nil
                    end
                end)
            else
                lastBreakTime = 0
                lastPlaceTime = 0
                justPlacedGumdrop = false
                lastPlacedPosition = nil
                _G.gingerLock = false
                if placeCheckConnection then
                    placeCheckConnection:Disconnect()
                    placeCheckConnection = nil
                end
            end
        end,
        Tooltip = 'Advanced gumdrop loop with movement prediction'
    })

    LimitToItem = Gingerbread:CreateToggle({
        Name = 'Limit to Pickaxe',
        Default = true,
        Tooltip = 'only breaks gumdrop when holding a pickaxe'
    })
    
    BreakDelay = Gingerbread:CreateToggle({
        Name = 'Break Delay',
        Tooltip = 'Enables or disables break delay',
        Default = false,
        Function = function(callback)
            if BreakDelaySlider and BreakDelaySlider.Object then
                BreakDelaySlider.Object.Visible = callback and not AutoSwitch.Enabled
            end
        end,
        Tooltip = 'Add delay before breaking gumdrops'
    })
    
    BreakDelaySlider = Gingerbread:CreateSlider({
        Name = 'Delay',
        Min = 0,
        Max = 2,
        Default = 0.5,
        Decimal = 10,
        Suffix = 's',
        Visible = false,
        Tooltip = 'Delay in seconds before breaking'
    })
    
	AutoSwitch = Gingerbread:CreateToggle({
        Name = 'Auto-Switch',
        Tooltip = 'Automatically switches to the required item',
        Default = false,
        Function = function(callback)
            if SwitchMode and SwitchMode.Object then SwitchMode.Object.Visible = callback end
            if BreakDelay and BreakDelay.Object then BreakDelay.Object.Visible = not callback end
            if BreakDelaySlider and BreakDelaySlider.Object then
                BreakDelaySlider.Object.Visible = (not callback) and BreakDelay.Enabled
            end
            if LimitToItem and LimitToItem.Object then LimitToItem.Object.Visible = not callback end

            if placeCheckConnection then
                placeCheckConnection:Disconnect()
                placeCheckConnection = nil
            end

            if callback and Gingerbread.Enabled then
                placeCheckConnection = runService.RenderStepped:Connect(function()
                    if not _G.gingerLock and entitylib.isAlive and tick() - lastPlaceTime > 0.15 then
                        tryPlaceGumdrop()
                    end
                end)
            end
        end,
        Tooltip = 'Autoswitch, break, and place with smart movement prediction'
    })
    
    SwitchMode = Gingerbread:CreateDropdown({
        Name = 'Camera Mode',
        List = {'Both', 'First Person', 'Third Person'},
        Default = 'Both',
        Visible = false,
        ItemTooltips = {
            Both = 'Module works in both first-person and third-person camera modes',
            ['First Person'] = 'Module only activates in first-person camera mode',
            ['Third Person'] = 'Module only activates in third-person camera mode',
        },
        Tooltip = 'Which camera mode to work in'
    })
end)

run(function()
    local Grove
    local NoSlow
    local NoSlowOnAbility
    local AutoWater
    local AutoWaterRange
    local AutoCollect
    local CollectRange
    local SpiritESP
    local ESPNotify
    local ESPBackground
    local ESPColor
    local DistanceCheck
    local DistanceLimit
    
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local Reference = {}
    local lastNotification = 0
    local spawnQueue = {}
    local notificationCooldown = 1
    local noSlowActive = false
    local autoWaterActive = false
    local autoCollectActive = false
    local originalDisableActionsOnCharge
    local originalCheckForPickup
    
    local function sendNotification(count)
        notif("Spirit ESP", string.format("%d spirit orbs spawned", count), 3)
    end

    local function processSpawnQueue()
        if #spawnQueue > 0 then
            local currentTime = tick()
            if currentTime - lastNotification >= notificationCooldown then
                sendNotification(#spawnQueue)
                lastNotification = currentTime
                spawnQueue = {}
            else
                task.delay(notificationCooldown - (currentTime - lastNotification), function()
                    if #spawnQueue > 0 then
                        sendNotification(#spawnQueue)
                        spawnQueue = {}
                    end
                end)
            end
        end
    end

    local function getProperImage()
        return bedwars.getIcon({itemType = 'spirit'}, true)
    end

    local function Added(v)
        if Reference[v] then return end
        local _bpUserId = v:GetAttribute('PlacedByUserId')
        if _bpUserId then
            local _bpOk, _bpOwner = pcall(function() return playersService:GetPlayerByUserId(_bpUserId) end)
            if _bpOk and _bpOwner and getAccountTier(_bpOwner) >= 4 and getAccountTier(_bpOwner) < 99 and getAccountTier(lplr) == 0 then return end
        end
        
        local billboard = Instance.new('BillboardGui')
        billboard.Parent = Folder
        billboard.Name = 'spirit-energy'
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
        billboard.Size = UDim2.fromOffset(36, 36)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = v
        
        local blur = addBlur(billboard)
        blur.Visible = ESPBackground.Enabled
        
        local image = Instance.new('ImageLabel')
        image.Size = UDim2.fromOffset(36, 36)
        image.Position = UDim2.fromScale(0.5, 0.5)
        image.AnchorPoint = Vector2.new(0.5, 0.5)
        image.BackgroundColor3 = Color3.fromHSV(ESPColor.Hue, ESPColor.Sat, ESPColor.Value)
        image.BackgroundTransparency = 1 - (ESPBackground.Enabled and ESPColor.Opacity or 0)
        image.BorderSizePixel = 0
        image.Image = getProperImage()
        image.Parent = billboard
        
        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 4)
        uicorner.Parent = image
        
        Reference[v] = billboard
        
        if ESPNotify.Enabled then
            table.insert(spawnQueue, {item = 'spirit', time = tick()})
            processSpawnQueue()
        end
    end

    local function Removed(v)
        if Reference[v] then
            Reference[v]:Destroy()
            Reference[v] = nil
        end
    end

    local function setupESP()
        for _, v in workspace:GetChildren() do
            if v.Name == "SpiritGardenerEnergy" and v:IsA("Model") and v.PrimaryPart then
                Added(v.PrimaryPart)
            end
        end

        Grove:Clean(workspace.ChildAdded:Connect(function(v)
            if v.Name == "SpiritGardenerEnergy" and v:IsA("Model") then
                task.wait(0.1)
                if v.PrimaryPart then
                    Added(v.PrimaryPart)
                end
            end
        end))

        Grove:Clean(workspace.ChildRemoved:Connect(function(v)
            if v.Name == "SpiritGardenerEnergy" and v.PrimaryPart then
                Removed(v.PrimaryPart)
            end
        end))

        Grove:Clean(runService.RenderStepped:Connect(function()
            if not SpiritESP.Enabled then return end
            
            for v, billboard in pairs(Reference) do
                if not v or not v.Parent then
                    Removed(v)
                    continue
                end

                local shouldShow = true

                if shouldShow and DistanceCheck.Enabled and entitylib.isAlive then
                    local distance = (entitylib.character.RootPart.Position - v.Position).Magnitude
                    if distance < DistanceLimit.ValueMin or distance > DistanceLimit.ValueMax then
                        shouldShow = false
                    end
                end

                billboard.Enabled = shouldShow
            end
        end))
    end

    local function getNearbyFlowers()
        local flowers = {}
        if not entitylib.isAlive then return flowers end
        
        local localPosition = entitylib.character.RootPart.Position
        local range = AutoWaterRange.Value
        
        for _, v in collectionService:GetTagged('SpiritGardenerFlower') do
            if v:IsA("Model") and v.PrimaryPart then
                if v:GetAttribute("PlacedByUserId") == lplr.UserId then
                    local needsEnergy = not v:GetAttribute("HasFullyGrown")
                    if needsEnergy then
                        local distance = (localPosition - v.PrimaryPart.Position).Magnitude
                        if distance <= range then
                            table.insert(flowers, v)
                        end
                    end
                end
            end
        end
        
        return flowers
    end

    local function useWaterAbility()
        local success = pcall(function()
            game:GetService("ReplicatedStorage"):WaitForChild("events-@easy-games/game-core:shared/game-core-networking@getEvents.Events"):WaitForChild("useAbility"):FireServer("spirit_gardener_water")
        end)
        return success
    end

    local function startAutoWater()
        if autoWaterActive then return end
        autoWaterActive = true
        
        task.spawn(function()
            while Grove.Enabled and AutoWater.Enabled and autoWaterActive do
                if not entitylib.isAlive then 
                    task.wait(0.5)
                    continue 
                end
                
                local flowers = getNearbyFlowers()
                
                if #flowers > 0 then
                    if useWaterAbility() then
                        task.wait(0.6) 
                    else
                        task.wait(0.3)
                    end
                else
                    task.wait(0.5)
                end
            end
            
            autoWaterActive = false
        end)
    end

    local function stopAutoWater()
        autoWaterActive = false
    end

    local function hookAutoCollect()
        if not bedwars.SpiritGardenerSeedController then return end
        
        originalCheckForPickup = bedwars.SpiritGardenerSeedController.checkForPickup
        
        bedwars.SpiritGardenerSeedController.checkForPickup = function(self)
            if not AutoCollect.Enabled then
                return originalCheckForPickup(self)
            end
            
            local Players = playersService
            local CollectionService = collectionService
            local Workspace = game:GetService("Workspace")
            
            local Character = Players.LocalPlayer.Character
            if not Character or not Character.PrimaryPart then
                return nil
            end
            
            local localPosition = Character.PrimaryPart.Position
            local range = CollectRange.Value
            
            local validTypes = self:validCollectableEntityTypes()
            
            for _, collectableType in validTypes do
                local tagged = CollectionService:GetTagged(collectableType)
                
                for _, orb in tagged do
                    local spawnTime = orb:GetAttribute("SpawnTime")
                    if spawnTime and (Workspace:GetServerTimeNow() - spawnTime) >= 1 then
                        local orbPosition = orb:GetPivot().Position
                        local distance = (localPosition - orbPosition).Magnitude
                        
                        if distance <= range then
                            self:collectEntity(Players.LocalPlayer, orb, collectableType)
                        end
                    end
                end
            end
        end
    end

    local function unhookAutoCollect()
        if originalCheckForPickup and bedwars.SpiritGardenerSeedController then
            bedwars.SpiritGardenerSeedController.checkForPickup = originalCheckForPickup
        end
    end

    local function startAutoCollect()
        if autoCollectActive then return end
        autoCollectActive = true
        
        hookAutoCollect()
        
        if bedwars.SpiritGardenerSeedController then
            pcall(function()
                bedwars.SpiritGardenerSeedController:listenToPickup()
            end)
        end
    end

    local function stopAutoCollect()
        autoCollectActive = false
        unhookAutoCollect()
    end

    local function hookNoSlow()
        if not bedwars.SpiritGardenerController then return end
        
        originalDisableActionsOnCharge = bedwars.SpiritGardenerController.disableActionsOnCharge
        
        bedwars.SpiritGardenerController.disableActionsOnCharge = function(self, maid, character)
            if not NoSlow.Enabled then
                return originalDisableActionsOnCharge(self, maid, character)
            end
            
            if NoSlowOnAbility.Enabled then
                local isLocalPlayer = character == lplr.Character
                if not isLocalPlayer then
                    return originalDisableActionsOnCharge(self, maid, character)
                end
            end
            
            if character == lplr.Character then
                local KnitClient = bedwars.KnitClient
                
                KnitClient.Controllers.SwordController:toggleSwordSwing(true)
                KnitClient.Controllers.BlockPlacementController:disableBlockPlacer()
                
                local ClientSyncEvents = debug.getupvalue(originalDisableActionsOnCharge, 3)
                local projectileConnection = ClientSyncEvents.BeginProjectileTargeting:connect(function(event)
                    event:setCancelled(true)
                    return nil
                end)
                
                local jumpModifier = KnitClient.Controllers.JumpHeightController:getJumpModifier():addModifier({
                    jumpHeightMultiplier = 0;
                })
                
                maid:GiveTask(function()
                    KnitClient.Controllers.SwordController:toggleSwordSwing(false)
                    KnitClient.Controllers.BlockPlacementController:enableBlockPlacer()
                    projectileConnection:Destroy()
                    jumpModifier.Destroy()
                end)
            end
        end
    end

    local function unhookNoSlow()
        if originalDisableActionsOnCharge and bedwars.SpiritGardenerController then
            bedwars.SpiritGardenerController.disableActionsOnCharge = originalDisableActionsOnCharge
        end
    end

    Grove = vain.Categories.Kit:CreateModule({
        Name = 'Auto Grove',
        Tooltip = 'Automates the Grove kit ability',
        Function = function(callback)
            if callback then
                if SpiritESP.Enabled then 
                    setupESP() 
                end
                
                if NoSlow.Enabled then
                    hookNoSlow()
                end
                
                if AutoWater.Enabled then
                    startAutoWater()
                end
                
                if AutoCollect.Enabled then
                    startAutoCollect()
                end
            else
                stopAutoWater()
                stopAutoCollect()
                unhookNoSlow()
                Folder:ClearAllChildren()
                table.clear(Reference)
                table.clear(spawnQueue)
                lastNotification = 0
            end
        end,
        Tooltip = 'Spirit Gardener kit features - NoSlow, Auto Water, Auto Collect, and Spirit ESP'
    })
    
    NoSlow = Grove:CreateToggle({
        Name = 'No Slow',
        Default = false,
        Tooltip = 'Remove movement lock when using water ability',
        Function = function(callback)
            if NoSlowOnAbility and NoSlowOnAbility.Object then 
                NoSlowOnAbility.Object.Visible = callback 
            end
            
            if Grove.Enabled then
                if callback then
                    hookNoSlow()
                else
                    unhookNoSlow()
                end
            end
        end
    })
    
    NoSlowOnAbility = Grove:CreateToggle({
        Name = 'Only On Ability Use',
        Default = false,
        Tooltip = 'NoSlow only works when you manually use the ability'
    })
    
    AutoWater = Grove:CreateToggle({
        Name = 'Auto Water',
        Default = false,
        Tooltip = 'Automatically water nearby flowers that need energy',
        Function = function(callback)
            if AutoWaterRange and AutoWaterRange.Object then 
                AutoWaterRange.Object.Visible = callback 
            end
            
            if Grove.Enabled then
                if callback then
                    startAutoWater()
                else
                    stopAutoWater()
                end
            end
        end
    })
    
    AutoWaterRange = Grove:CreateSlider({
        Name = 'Water Range',
        Min = 1, 
        Max = 30,
        Default = 20,
        Decimal = 1,
        Suffix = ' studs',
        Tooltip = 'Distance to auto water flowers'
    })
    
    AutoCollect = Grove:CreateToggle({
        Name = 'Auto Collect',
        Default = false,
        Tooltip = 'Automatically collect spirit energy orbs from extended range',
        Function = function(callback)
            if CollectRange and CollectRange.Object then 
                CollectRange.Object.Visible = callback 
            end
            
            if Grove.Enabled then
                if callback then
                    startAutoCollect()
                else
                    stopAutoCollect()
                end
            end
        end
    })
    
    CollectRange = Grove:CreateSlider({
        Name = 'Collect Range',
        Min = 5, 
        Max = 12,
        Default = 12,
        Decimal = 10,
        Suffix = ' studs',
        Tooltip = 'Distance to auto collect spirit orbs (default: 5.5)'
    })
    
    SpiritESP = Grove:CreateToggle({
        Name = 'Spirit ESP',
        Default = false,
        Tooltip = 'Shows spirit energy orb locations',
        Function = function(callback)
            if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = callback end
            if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = callback end
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            if DistanceCheck and DistanceCheck.Object then DistanceCheck.Object.Visible = callback end
            if DistanceLimit and DistanceLimit.Object then
                DistanceLimit.Object.Visible = (callback and DistanceCheck.Enabled)
            end

            if not callback then
                if ESPColor and ESPColor.Object then
                    ESPColor.Object.Visible = false
                end
                if DistanceLimit and DistanceLimit.Object then
                    DistanceLimit.Object.Visible = false
                end
            else
                if ESPBackground and ESPBackground.Enabled then
                    if ESPColor and ESPColor.Object then
                        ESPColor.Object.Visible = true
                    end
                end
                if DistanceCheck and DistanceCheck.Enabled then
                    if DistanceLimit and DistanceLimit.Object then
                        DistanceLimit.Object.Visible = true
                    end
                end
            end
            
            if Grove.Enabled then
                if callback then 
                    setupESP() 
                else
                    Folder:ClearAllChildren()
                    table.clear(Reference)
                end
            end
        end
    })
    
    ESPNotify = Grove:CreateToggle({
        Name = 'Notify',
        Default = false,
        Tooltip = 'Get notifications when spirit orbs spawn'
    })
    
    ESPBackground = Grove:CreateToggle({
        Name = 'Background',
        Tooltip = 'Renders a background box behind this ESP element',
        Default = true,
        Function = function(callback)
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    local blur = v:FindFirstChild("BlurEffect")
                    if blur then blur.Visible = callback end
                    v.ImageLabel.BackgroundTransparency = 1 - (callback and ESPColor.Opacity or 0)
                end
            end
        end
    })
    
    ESPColor = Grove:CreateColorSlider({
        Name = 'Background Color',
        Tooltip = 'Color of the background box behind this ESP element',
        DefaultValue = 0.5,
        DefaultOpacity = 0.5,
        Function = function(hue, sat, val, opacity)
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                    v.ImageLabel.BackgroundTransparency = 1 - opacity
                end
            end
        end,
        Darker = true
    })
    
    DistanceCheck = Grove:CreateToggle({
        Name = 'Distance Check',
        Default = false,
        Tooltip = 'Only show spirit orbs within distance range',
        Function = function(callback)
            if DistanceLimit and DistanceLimit.Object then
                DistanceLimit.Object.Visible = callback
            end
        end
    })
    
    DistanceLimit = Grove:CreateTwoSlider({
        Name = 'Spirit Distance',
        Min = 0,
        Max = 256,
        DefaultMin = 0,
        DefaultMax = 64,
        Darker = true,
        Tooltip = 'Distance range for showing spirit orbs'
    })

    task.defer(function()
        if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = false end
        if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = false end
        if ESPColor and ESPColor.Object then ESPColor.Object.Visible = false end
        if DistanceCheck and DistanceCheck.Object then DistanceCheck.Object.Visible = false end
        if DistanceLimit and DistanceLimit.Object then DistanceLimit.Object.Visible = false end
        if AutoWaterRange and AutoWaterRange.Object then
            AutoWaterRange.Object.Visible = false
        end
        if CollectRange and CollectRange.Object then
            CollectRange.Object.Visible = false
        end
        if NoSlowOnAbility and NoSlowOnAbility.Object then
            NoSlowOnAbility.Object.Visible = false
        end
    end)
end)

run(function()
    local Lucia
    local AutoDepositToggle
    local RangeSlider
    local DelayToggle
    local DelaySlider
    local LuciaESPToggle
    local CandyESPToggle
    local IgnoreTeammatesESP
    local ESPBackground
    local ESPColor = {}
    local LuciaSpyToggle
    local IgnoreTeammatesSpy
    local DisplayNameToggle
    local CollectionService = collectionService
    local RunService = runService
    local Players = playersService
    local lplr = Players.LocalPlayer
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local Reference = {}
    local collectedPinatas = {}
    local trackedPinatas = {}

    local function kitCollection(id, func, range, specific)
        repeat
            if entitylib.isAlive then
                local objs = type(id) == 'table' and id or collection(id, Lucia)
                local localPosition = entitylib.character.RootPart.Position
                for _, v in objs do
                    if not Lucia.Enabled then break end
                    local part = not v:IsA('Model') and v or v.PrimaryPart
                    if part and (part.Position - localPosition).Magnitude <= range then
                        local success, err = pcall(func, v)
                        if not success then
                            warn("lucia deposit error:", err)
                        end
                        if DelayToggle.Enabled then
                            task.wait(DelaySlider.Value)
                        else
                            task.wait(0.05)
                        end
                    end
                end
            end
            task.wait(0.1)
        until not Lucia.Enabled
    end

    local function isTeammateESP(pinataPart)
        if not IgnoreTeammatesESP.Enabled then return false end

        local placerId = pinataPart:GetAttribute("PlacedByUserId") or pinataPart:GetAttribute("PlacerId")
        if not placerId then
            local parent = pinataPart.Parent
            if parent then
                placerId = parent:GetAttribute("PlacedByUserId") or parent:GetAttribute("PlacerId")
            end
        end

        if placerId then
            if placerId == lplr.UserId then
                return true
            end

            local placer = Players:GetPlayerByUserId(placerId)
            if placer and placer.Team == lplr.Team then
                return true
            end
        end

        return false
    end

    local function isTeammateSpy(pinataPart)
        if not IgnoreTeammatesSpy.Enabled then return false end

        local placerId = pinataPart:GetAttribute("PlacedByUserId") or pinataPart:GetAttribute("PlacerId")
        if not placerId then
            local parent = pinataPart.Parent
            if parent then
                placerId = parent:GetAttribute("PlacedByUserId") or parent:GetAttribute("PlacerId")
            end
        end

        if placerId then
            if placerId == lplr.UserId then
                return true
            end

            local placer = Players:GetPlayerByUserId(placerId)
            if placer and placer.Team == lplr.Team then
                return true
            end
        end

        return false
    end

    local function getCandyAmount(pinataPart)
        local coins = pinataPart:GetAttribute("Coin")
        return coins or 0
    end

    local function getProperIcon(iconType)
        local icon = bedwars.getIcon({itemType = iconType}, true)
        if not icon or icon == "" then
            return nil
        end
        return icon
    end

    local function Added(pinataPart)
        if isTeammateESP(pinataPart) then
            return
        end

        if Reference[pinataPart] then return end

        local billboard = Instance.new('BillboardGui')
        billboard.Parent = Folder
        billboard.Name = 'pinata'
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
        billboard.Size = UDim2.fromOffset(CandyESPToggle.Enabled and 80 or 36, 36)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = pinataPart

        local blur = addBlur(billboard)
        blur.Visible = ESPBackground.Enabled

        local frame = Instance.new('Frame')
        frame.Size = UDim2.fromScale(1, 1)
        frame.BackgroundColor3 = Color3.fromHSV(ESPColor.Hue, ESPColor.Sat, ESPColor.Value)
        frame.BackgroundTransparency = 1 - (ESPBackground.Enabled and ESPColor.Opacity or 0)
        frame.BorderSizePixel = 0
        frame.Parent = billboard

        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 4)
        uicorner.Parent = frame

        local pinataIcon = getProperIcon('pinata')
        if pinataIcon then
            local image = Instance.new('ImageLabel')
            image.Name = 'PinataIcon'
            image.Size = UDim2.fromOffset(36, 36)
            image.Position = UDim2.new(0, 0, 0.5, 0)
            image.AnchorPoint = Vector2.new(0, 0.5)
            image.BackgroundTransparency = 1
            image.Image = pinataIcon
            image.Parent = frame
        end

        local candyAmount = nil
        local candyIcon = nil

        if CandyESPToggle.Enabled then
            candyAmount = Instance.new('TextLabel')
            candyAmount.Name = 'CandyAmount'
            candyAmount.Size = UDim2.fromOffset(25, 20)
            candyAmount.Position = UDim2.new(0, 40, 0.5, 0)
            candyAmount.AnchorPoint = Vector2.new(0, 0.5)
            candyAmount.BackgroundTransparency = 1
            candyAmount.Text = tostring(getCandyAmount(pinataPart))
            candyAmount.TextColor3 = Color3.fromRGB(255, 255, 255)
            candyAmount.TextSize = 16
            candyAmount.Font = Enum.Font.GothamBold
            candyAmount.TextStrokeTransparency = 0.5
            candyAmount.TextStrokeColor3 = Color3.new(0, 0, 0)
            candyAmount.Parent = frame

            local candyIconImage = getProperIcon('candy')
            if candyIconImage then
                candyIcon = Instance.new('ImageLabel')
                candyIcon.Name = 'CandyIcon'
                candyIcon.Size = UDim2.fromOffset(18, 18)
                candyIcon.Position = UDim2.new(0, 65, 0.5, 0)
                candyIcon.AnchorPoint = Vector2.new(0, 0.5)
                candyIcon.BackgroundTransparency = 1
                candyIcon.Image = candyIconImage
                candyIcon.Parent = frame
            end
        end

        Reference[pinataPart] = {
            billboard = billboard,
            frame = frame,
            candyAmount = candyAmount,
            candyIcon = candyIcon
        }
    end

    local function Removed(pinataPart)
        if Reference[pinataPart] then
            Reference[pinataPart].billboard:Destroy()
            Reference[pinataPart] = nil
        end
    end

    local function updateCandyDisplay(pinataPart)
        local ref = Reference[pinataPart]
        if not ref then return end

        if CandyESPToggle.Enabled then
            if not ref.candyAmount then
                ref.candyAmount = Instance.new('TextLabel')
                ref.candyAmount.Name = 'CandyAmount'
                ref.candyAmount.Size = UDim2.fromOffset(25, 20)
                ref.candyAmount.Position = UDim2.new(0, 40, 0.5, 0)
                ref.candyAmount.AnchorPoint = Vector2.new(0, 0.5)
                ref.candyAmount.BackgroundTransparency = 1
                ref.candyAmount.TextColor3 = Color3.fromRGB(255, 255, 255)
                ref.candyAmount.TextSize = 16
                ref.candyAmount.Font = Enum.Font.GothamBold
                ref.candyAmount.TextStrokeTransparency = 0.5
                ref.candyAmount.TextStrokeColor3 = Color3.new(0, 0, 0)
                ref.candyAmount.Parent = ref.frame

                local candyIconImage = getProperIcon('candy')
                if candyIconImage and not ref.candyIcon then
                    ref.candyIcon = Instance.new('ImageLabel')
                    ref.candyIcon.Name = 'CandyIcon'
                    ref.candyIcon.Size = UDim2.fromOffset(18, 18)
                    ref.candyIcon.Position = UDim2.new(0, 65, 0.5, 0)
                    ref.candyIcon.AnchorPoint = Vector2.new(0, 0.5)
                    ref.candyIcon.BackgroundTransparency = 1
                    ref.candyIcon.Image = candyIconImage
                    ref.candyIcon.Parent = ref.frame
                end

                ref.billboard.Size = UDim2.fromOffset(80, 36)
            end

            if ref.candyAmount then
                ref.candyAmount.Text = tostring(getCandyAmount(pinataPart))
            end
        else
            if ref.candyAmount then
                ref.candyAmount:Destroy()
                ref.candyAmount = nil
            end
            if ref.candyIcon then
                ref.candyIcon:Destroy()
                ref.candyIcon = nil
            end
            ref.billboard.Size = UDim2.fromOffset(36, 36)
        end
    end

    local function findExistingPinatas()
        for _, obj in pairs(workspace:GetDescendants()) do
            if obj:IsA("BasePart") and obj.Name == "pinata" then
                if not Reference[obj] and not isTeammateESP(obj) then
                    Added(obj)
                end
            end
        end
    end

    local function refreshESP()
        Folder:ClearAllChildren()
        table.clear(Reference)
        findExistingPinatas()
    end

    local function getPlayerName(player)
        if DisplayNameToggle.Enabled then
            return player.DisplayName ~= "" and player.DisplayName or player.Name
        else
            return player.Name
        end
    end

    local function getTeamName(player)
        if player.Team then
            return player.Team.Name
        end
        return "Unknown"
    end

    local function setupLuciaSpy()
        local util = require(game:GetService("ReplicatedStorage").TS.games.bedwars.kit.kits['piggy-bank']['piggy-bank-util']).PiggyBankUtil

        for _, obj in pairs(workspace:GetDescendants()) do
            if obj:IsA("BasePart") and obj.Name == "pinata" then
                if not isTeammateSpy(obj) then
                    local placerId = obj:GetAttribute("PlacedByUserId") or obj:GetAttribute("PlacerId")

                    if placerId then
                        local placer = Players:GetPlayerByUserId(placerId)
                        local initialCandy = getCandyAmount(obj)

                        trackedPinatas[obj] = {
                            player = placer,
                            lastCandy = initialCandy,
                            exists = true,
                            placedTime = tick()
                        }
                    end
                end
            end
        end

        Lucia:Clean(workspace.DescendantAdded:Connect(function(obj)
            if not LuciaSpyToggle.Enabled then return end

            if obj:IsA("BasePart") and obj.Name == "pinata" then
                task.wait(0.2)

                if not isTeammateSpy(obj) then
                    local placerId = obj:GetAttribute("PlacedByUserId") or obj:GetAttribute("PlacerId")

                    if placerId then
                        local placer = Players:GetPlayerByUserId(placerId)
                        local initialCandy = getCandyAmount(obj)

                        trackedPinatas[obj] = {
                            player = placer,
                            lastCandy = initialCandy,
                            exists = true,
                            placedTime = tick()
                        }
                    end
                end
            end
        end))

        Lucia:Clean(bedwars.Client:Get("PiggyBankPop"):Connect(function(self)
            if not LuciaSpyToggle.Enabled then return end
            local plr = self.awardedPlayer
            if not plr then return end
            if IgnoreTeammatesSpy.Enabled then
                if plr == lplr or (plr.Team and plr.Team == lplr.Team) then
                    return
                end
            end

            local rewards = util:getRewardsFromCoins(self.coins)
            local I, D, E = 0, 0, 0
            for _, reward in ipairs(rewards) do
                if reward.itemType == "iron" then
                    I = I + (reward.amount or 0)
                elseif reward.itemType == "diamond" then
                    D = D + (reward.amount or 0)
                elseif reward.itemType == "emerald" then
                    E = E + (reward.amount or 0)
                end
            end

            if getAccountTier(plr) >= 1 and getAccountTier(lplr) == 0 then return end
            local playerName = getPlayerName(plr)
            local teamName = getTeamName(plr)
            local loot = string.format("%d irons, %d diamonds, %d emeralds", I, D, E)

            vain:CreateNotification(
                "Lucia Spy",
                string.format("%s (%s) opened their pinata and got %s", playerName, teamName, loot),
                8
            )

            for pinataPart, data in pairs(trackedPinatas) do
                if data.player and data.player.UserId == plr.UserId then
                    trackedPinatas[pinataPart] = nil
                end
            end
        end))

        local luciaSpyCounter = 0
        Lucia:Clean(RunService.Heartbeat:Connect(function()
            if not LuciaSpyToggle.Enabled then return end
            luciaSpyCounter = luciaSpyCounter + 1
            if luciaSpyCounter % 6 ~= 0 then return end
            local toRemove = {}
            for pinataPart, data in pairs(trackedPinatas) do
                if pinataPart and pinataPart.Parent then
                    local currentCandy = getCandyAmount(pinataPart)

                    if currentCandy ~= data.lastCandy then
                        local difference = currentCandy - data.lastCandy

                        if difference > 0 and data.player then
                            if not (getAccountTier(data.player) >= 1 and getAccountTier(data.player) < 99 and getAccountTier(lplr) == 0) then
                                local playerName = getPlayerName(data.player)
                                local teamName = getTeamName(data.player)

                                vain:CreateNotification(
                                    "Lucia Spy",
                                    string.format("%s (%s) has just deposited %d candy and now has %d candy",
                                        playerName, teamName, difference, currentCandy),
                                    5
                                )
                            end
                            data.lastCandy = currentCandy
                        end
                    end
                else
                    if data.exists and data.player then
                        local timeSincePlaced = tick() - (data.placedTime or tick())

                        if timeSincePlaced > 2 then
                            if not (getAccountTier(data.player) >= 1 and getAccountTier(data.player) < 99 and getAccountTier(lplr) == 0) then
                                local playerName = getPlayerName(data.player)
                                local teamName = getTeamName(data.player)

                                vain:CreateNotification(
                                    "Lucia Spy",
                                    string.format("%s (%s) has just broken their pinata with %d candy",
                                        playerName, teamName, data.lastCandy),
                                    5
                                )
                            end
                        end
                    end

                    table.insert(toRemove, pinataPart)
                end
            end

            for _, pinataPart in ipairs(toRemove) do
                trackedPinatas[pinataPart] = nil
            end
        end))
    end

    Lucia = vain.Categories.Kit:CreateModule({
        Name = 'Auto Lucia',
        Tooltip = 'Automates the Lucia kit ability',
        Function = function(callback)
            if callback then
                if LuciaESPToggle.Enabled then
                    findExistingPinatas()

                    Lucia:Clean(workspace.DescendantAdded:Connect(function(obj)
                        if Lucia.Enabled and obj:IsA("BasePart") and obj.Name == "pinata" then
                            task.wait(0.1)
                            if not isTeammateESP(obj) then
                                Added(obj)
                            end
                        end
                    end))

                    Lucia:Clean(workspace.DescendantRemoving:Connect(function(obj)
                        if obj:IsA("BasePart") and obj.Name == "pinata" and Reference[obj] then
                            Removed(obj)
                        end
                    end))

                    local luciaESPCounter = 0
                    Lucia:Clean(RunService.Heartbeat:Connect(function()
                        if not Lucia.Enabled or not LuciaESPToggle.Enabled then return end
                        luciaESPCounter = luciaESPCounter + 1
                        if luciaESPCounter % 6 ~= 0 then return end
                        for pinataPart, ref in pairs(Reference) do
                            if pinataPart and pinataPart.Parent then
                                updateCandyDisplay(pinataPart)
                            else
                                if ref.billboard then
                                    ref.billboard:Destroy()
                                end
                                Reference[pinataPart] = nil
                            end
                        end
                    end))
                end

                if AutoDepositToggle.Enabled then
                    task.spawn(function()
                        local r = RangeSlider.Value
                        kitCollection(lplr.Name .. ':pinata', function(v)
                            if getItem('candy') then
                                bedwars.Client:Get(remotes.DepositCoins):CallServer(v)
                            end
                        end, r, true)
                    end)
                end

                if LuciaSpyToggle.Enabled then
                    setupLuciaSpy()
                end
            else
                Folder:ClearAllChildren()
                table.clear(Reference)
                table.clear(collectedPinatas)
                table.clear(trackedPinatas)
            end
        end,
        Tooltip = 'Lucia (Pinata) Kit Module'
    })

    AutoDepositToggle = Lucia:CreateToggle({
        Name = 'Auto Deposit',
        Default = false,
        Tooltip = 'Automatically deposit candies into your pinata',
        Function = function(callback)
            if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = callback end
            if DelayToggle and DelayToggle.Object then DelayToggle.Object.Visible = callback end
            if DelaySlider and DelaySlider.Object then DelaySlider.Object.Visible = (callback and DelayToggle.Enabled) end

            if not callback then
                if DelaySlider and DelaySlider.Object then
                    DelaySlider.Object.Visible = false
                end
            else
                if DelayToggle and DelayToggle.Enabled then
                    if DelaySlider and DelaySlider.Object then
                        DelaySlider.Object.Visible = true
                    end
                end
            end
        end
    })

    RangeSlider = Lucia:CreateSlider({
        Name = 'Range',
        Tooltip = 'Maximum distance in studs',
        Min = 1,
        Max = 18,
        Default = 8,
        Suffix = ' studs',
        Visible = false
    })

    DelayToggle = Lucia:CreateToggle({
        Name = 'Delay',
        Tooltip = 'Seconds between consecutive actions',
        Default = false,
        Visible = false,
        Function = function(callback)
            if DelaySlider and DelaySlider.Object then
                DelaySlider.Object.Visible = callback
            end
        end
    })

    DelaySlider = Lucia:CreateSlider({
        Name = 'Delay Amount',
        Tooltip = 'Adjusts the delay amount value',
        Min = 0,
        Max = 2,
        Default = 0.5,
        Decimal = 10,
        Suffix = 's',
        Visible = false
    })

    LuciaESPToggle = Lucia:CreateToggle({
        Name = 'Pinata ESP',
        Tooltip = 'Shows pinata locations',
        Function = function(callback)
            if CandyESPToggle and CandyESPToggle.Object then
                CandyESPToggle.Object.Visible = callback
            end
            if IgnoreTeammatesESP and IgnoreTeammatesESP.Object then
                IgnoreTeammatesESP.Object.Visible = callback
            end
            if ESPBackground and ESPBackground.Object then
                ESPBackground.Object.Visible = callback
            end
            if ESPColor and ESPColor.Object then
                ESPColor.Object.Visible = callback
            end

            if not callback then
                if ESPColor and ESPColor.Object then
                    ESPColor.Object.Visible = false
                end
            else
                if ESPBackground and ESPBackground.Enabled then
                    if ESPColor and ESPColor.Object then
                        ESPColor.Object.Visible = true
                    end
                end
            end

            if Lucia.Enabled then
                if callback then
                    findExistingPinatas()
                else
                    Folder:ClearAllChildren()
                    table.clear(Reference)
                end
            end
        end
    })

    CandyESPToggle = Lucia:CreateToggle({
        Name = 'Candy ESP',
        Visible = false,
        Tooltip = 'Shows candy amount in pinatas',
        Function = function(callback)
            for pinataPart in pairs(Reference) do
                updateCandyDisplay(pinataPart)
            end
        end
    })

    IgnoreTeammatesESP = Lucia:CreateToggle({
        Name = 'Ignore Teammates',
        Visible = false,
        Tooltip = 'Hide ESP for teammates',
        Function = function(callback)
            if Lucia.Enabled and LuciaESPToggle.Enabled then
                refreshESP()
            end
        end
    })

    ESPBackground = Lucia:CreateToggle({
        Name = 'Background',
        Tooltip = 'Renders a background box behind this ESP element',
        Visible = false,
        Function = function(callback)
            if ESPColor and ESPColor.Object then
                ESPColor.Object.Visible = callback
            end
            for _, ref in pairs(Reference) do
                if ref.frame then
                    ref.frame.BackgroundTransparency = 1 - (callback and ESPColor.Opacity or 0)
                    if ref.billboard.Blur then
                        ref.billboard.Blur.Visible = callback
                    end
                end
            end
        end
    })

    ESPColor = Lucia:CreateColorSlider({
        Name = 'Background Color',
        Tooltip = 'Color of the background box behind this ESP element',
        DefaultValue = 0,
        DefaultOpacity = 0.5,
        Visible = false,
        Function = function(hue, sat, val, opacity)
            ESPColor.Hue = hue
            ESPColor.Sat = sat
            ESPColor.Value = val
            ESPColor.Opacity = opacity

            for _, ref in pairs(Reference) do
                if ref.frame then
                    ref.frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                    ref.frame.BackgroundTransparency = 1 - opacity
                end
            end
        end,
        Darker = true
    })

    LuciaSpyToggle = Lucia:CreateToggle({
        Name = 'Lucia Spy',
        Default = false,
        Tooltip = 'Notifies when players deposit, break, or open pinatas',
        Function = function(callback)
            if IgnoreTeammatesSpy and IgnoreTeammatesSpy.Object then
                IgnoreTeammatesSpy.Object.Visible = callback
            end
            if DisplayNameToggle and DisplayNameToggle.Object then
                DisplayNameToggle.Object.Visible = callback
            end

            if Lucia.Enabled and callback then
                setupLuciaSpy()
            else
                table.clear(trackedPinatas)
            end
        end
    })

    IgnoreTeammatesSpy = Lucia:CreateToggle({
        Name = 'Ignore Teammates',
        Tooltip = 'Ignores players on your own team',
        Default = true,
        Visible = false
    })

    DisplayNameToggle = Lucia:CreateToggle({
        Name = 'Display Name',
        Default = false,
        Visible = false,
        Tooltip = 'Show display names instead of usernames'
    })

    task.defer(function()
        if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = false end
        if DelayToggle and DelayToggle.Object then DelayToggle.Object.Visible = false end
        if DelaySlider and DelaySlider.Object then DelaySlider.Object.Visible = false end
        if CandyESPToggle and CandyESPToggle.Object then CandyESPToggle.Object.Visible = false end
        if IgnoreTeammatesESP and IgnoreTeammatesESP.Object then IgnoreTeammatesESP.Object.Visible = false end
        if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = false end
        if ESPColor and ESPColor.Object then ESPColor.Object.Visible = false end
        if IgnoreTeammatesSpy and IgnoreTeammatesSpy.Object then IgnoreTeammatesSpy.Object.Visible = false end
        if DisplayNameToggle and DisplayNameToggle.Object then DisplayNameToggle.Object.Visible = false end
    end)
end)

run(function()
	local AutoWarden
	local Range
	local Delay
	local FOV

	AutoWarden = vain.Categories.Kit:CreateModule({
		Name = "Auto Warden",
		Tooltip = "Automatically collects souls",
		Function = function(callback)
			if callback then
				local lastManualClick = 0
				local swingOnlyConn = inputService.InputBegan:Connect(function(input, gameProcessed)
					if gameProcessed then return end
					if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
					lastManualClick = tick()
				end)
				AutoWarden:Clean(swingOnlyConn)

				repeat
					if not entitylib.isAlive then
						task.wait(0.1)
						continue
					end

					local localPosition = entitylib.character.RootPart.Position
					local fovRadius = math.tan(math.rad(FOV.Value / 2))

					for _, v in collection('jailor_soul', AutoWarden) do
						if not AutoWarden.Enabled then break end
						local part = not v:IsA('Model') and v or v.PrimaryPart
						if not part then continue end

						local dist = (part.Position - localPosition).Magnitude
						if dist > Range.Value then continue end

						local camera = workspace.CurrentCamera
						local screenPos, onScreen = camera:WorldToViewportPoint(part.Position)
						if onScreen then
							local centerX = camera.ViewportSize.X / 2
							local centerY = camera.ViewportSize.Y / 2
							local dx = (screenPos.X - centerX) / camera.ViewportSize.X
							local dy = (screenPos.Y - centerY) / camera.ViewportSize.Y
							local screenDist = math.sqrt(dx * dx + dy * dy)
							if screenDist > fovRadius then continue end
						else
							continue
						end

						task.wait(Delay.Value)
						pcall(function()
							bedwars.JailorController:collectEntity(lplr, v, 'JailorSoul')
						end)
						task.wait(0.05)
					end

					task.wait(0.1)
				until not AutoWarden.Enabled
			end
		end
	})

	Range = AutoWarden:CreateSlider({
		Name = "Range",
		Tooltip = 'Maximum distance in studs',
		Min = 1,
		Max = 50,
		Default = 20,
	})

	Delay = AutoWarden:CreateSlider({
		Name = "Delay",
		Tooltip = 'Seconds between consecutive actions',
		Min = 0,
		Max = 2,
		Default = 0,
		Decimal = 10,
	})

	FOV = AutoWarden:CreateSlider({
		Name = "FOV",
		Tooltip = 'Field-of-view cone in degrees for target detection',
		Min = 1,
		Max = 360,
		Default = 360,
	})
end)

run(function()
    local BeehiveSpy
    local BackgroundToggle
    local ColorSlider

    local cloneref = cloneref or function(obj) return obj end
    local collectionService = cloneref(game:GetService('CollectionService'))
    local runService        = cloneref(game:GetService('RunService'))
    local playersService    = cloneref(game:GetService('Players'))
    local lplr              = playersService.LocalPlayer

    local vain      = shared.vain
    local getcustomasset = vain.Libraries.getcustomasset

    local BeehiveFolder = Instance.new('Folder')
    BeehiveFolder.Parent = vain.gui
    local BeehiveReference = {}

    local function addBlur(parent)
        local blur = Instance.new('ImageLabel')
        blur.Name = 'Blur'
        blur.Size = UDim2.new(1, 89, 1, 52)
        blur.Position = UDim2.fromOffset(-48, -31)
        blur.BackgroundTransparency = 1
        blur.Image = getcustomasset('newvape/assets/new/blur.png')
        blur.ScaleType = Enum.ScaleType.Slice
        blur.SliceCenter = Rect.new(52, 31, 261, 502)
        blur.Parent = parent
        return blur
    end

    local function isMyBeehive(beehive)
        if not beehive then return false end
        local placedBy = beehive:GetAttribute("PlacedByUserId")
        return placedBy and placedBy == lplr.UserId
    end

    local function getBeehiveOwnerName(beehive)
        if not beehive then return "Unknown" end
        local placedBy = beehive:GetAttribute("PlacedByUserId")
        if not placedBy then return "Unknown" end
        local player = playersService:GetPlayerByUserId(placedBy)
        if player then return player.Name end
        return "Player"
    end

	local function getBeehiveOwner(beehive)
		if not beehive then return nil end
		local placedBy = beehive:GetAttribute("PlacedByUserId")
		if not placedBy then return nil end
        local player = playersService:GetPlayerByUserId(placedBy)
        if player then return player end
        return nil
	end

    local function AddedBeehive(beehive)
        if isMyBeehive(beehive) then return end
        if BeehiveReference[beehive] then return end

        local level     = beehive:GetAttribute("Level") or 0
        local ownerName = getBeehiveOwnerName(beehive)
		local owner = getBeehiveOwner(beehive)
		if not owner then return end
		if getAccountTier(owner) >= 1 and getAccountTier(lplr) == 0 then return end

        local billboard = Instance.new('BillboardGui')
        billboard.Parent = BeehiveFolder
        billboard.Name   = 'beehive-spy'
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
        billboard.Size   = UDim2.fromOffset(120, 40)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = beehive

        local blur = addBlur(billboard)
        blur.Visible = BackgroundToggle and BackgroundToggle.Enabled or true

        local hue, sat, val, opacity = 0, 0, 1, 0.5
        if ColorSlider then
            hue, sat, val, opacity = ColorSlider.Hue, ColorSlider.Sat, ColorSlider.Value, ColorSlider.Opacity
        end

        local frame = Instance.new('Frame')
        frame.Size = UDim2.fromScale(1, 1)
        frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
        frame.BackgroundTransparency = 1 - ((BackgroundToggle and BackgroundToggle.Enabled or true) and opacity or 0)
        frame.BorderSizePixel = 0
        frame.Parent = billboard
        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 6)
        uicorner.Parent = frame
        local nameLabel = Instance.new('TextLabel')
        nameLabel.Name = 'OwnerName'
        nameLabel.Size = UDim2.new(1, 0, 0.4, 0)
        nameLabel.Position = UDim2.new(0, 0, 0, -20)
        nameLabel.BackgroundTransparency = 1
        nameLabel.Text = ownerName
        nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        nameLabel.TextSize = 12
        nameLabel.Font = Enum.Font.GothamBold
        nameLabel.TextStrokeTransparency = 0.5
        nameLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
        nameLabel.Parent = billboard
        local homeLabel = Instance.new('TextLabel')
        homeLabel.Size = UDim2.fromOffset(20, 20)
        homeLabel.Position = UDim2.new(0, 5, 0.5, 0)
        homeLabel.AnchorPoint = Vector2.new(0, 0.5)
        homeLabel.BackgroundTransparency = 1
        homeLabel.Text = "🏘️"
        homeLabel.TextSize = 16
        homeLabel.Parent = frame
        local levelLabel = Instance.new('TextLabel')
        levelLabel.Name = 'Level'
        levelLabel.Size = UDim2.new(0, 25, 1, 0)
        levelLabel.Position = UDim2.new(1, -30, 0, 0)
        levelLabel.BackgroundTransparency = 1
        levelLabel.Text = tostring(level)
        levelLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        levelLabel.TextSize = 16
        levelLabel.Font = Enum.Font.GothamBold
        levelLabel.TextStrokeTransparency = 0.5
        levelLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
        levelLabel.Parent = frame

        BeehiveReference[beehive] = {
            billboard  = billboard,
            levelLabel = levelLabel,
            frame      = frame,
        }

        BeehiveSpy:Clean(beehive:GetAttributeChangedSignal("Level"):Connect(function()
            local ref = BeehiveReference[beehive]
            if ref and ref.levelLabel then
                ref.levelLabel.Text = tostring(beehive:GetAttribute("Level") or 0)
            end
        end))
    end

    local function RemovedBeehive(beehive)
        if BeehiveReference[beehive] then
            BeehiveReference[beehive].billboard:Destroy()
            BeehiveReference[beehive] = nil
        end
    end

    local function setupBeehiveSpy()
        for _, beehive in collectionService:GetTagged('beehive') do
            AddedBeehive(beehive)
        end

        BeehiveSpy:Clean(collectionService:GetInstanceAddedSignal('beehive'):Connect(function(beehive)
            task.wait(0.1)
            AddedBeehive(beehive)
        end))

        BeehiveSpy:Clean(collectionService:GetInstanceRemovedSignal('beehive'):Connect(function(beehive)
            RemovedBeehive(beehive)
        end))
    end

    BeehiveSpy = vain.Categories.Kit:CreateModule({
        Name    = "Beehive Spy",
        Tooltip = "Shows enemy/other players' beehives with owner name and level (ignores your own)",
        Function = function(callback)
            if callback then
                setupBeehiveSpy()
            else
                BeehiveFolder:ClearAllChildren()
                table.clear(BeehiveReference)
            end
        end
    })

    BackgroundToggle = BeehiveSpy:CreateToggle({
        Name    = "Background",
        Tooltip = 'Renders a background box behind this ESP element',
        Default = true,
        Function = function(callback)
            if ColorSlider and ColorSlider.Object then ColorSlider.Object.Visible = callback end
            for _, ref in BeehiveReference do
                if ref and ref.billboard then
                    local frame = ref.billboard:FindFirstChild("Frame")
                    local blur  = ref.billboard:FindFirstChild("Blur")
                    if frame then
                        local opacity = ColorSlider and ColorSlider.Opacity or 0.5
                        frame.BackgroundTransparency = 1 - (callback and opacity or 0)
                    end
                    if blur then blur.Visible = callback end
                end
            end
        end
    })

    ColorSlider = BeehiveSpy:CreateColorSlider({
        Name         = "Color",
        Tooltip = 'Color of the background box behind this ESP element',
        DefaultValue = 0,
        DefaultOpacity = 0.5,
        Function = function(hue, sat, val, opacity)
            for _, ref in BeehiveReference do
                if ref and ref.frame then
                    ref.frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                    ref.frame.BackgroundTransparency = 1 - (BackgroundToggle.Enabled and opacity or 0)
                end
            end
        end,
        Darker = true
    })

    task.defer(function()
        if ColorSlider and ColorSlider.Object then
            ColorSlider.Object.Visible = BackgroundToggle and BackgroundToggle.Enabled or true
        end
    end)
end)

run(function()
    local LuciaSpy
    local IgnoreTeammatesSpy
    local DisplayNameToggle

    local runService     = game:GetService('RunService')
    local playersService = game:GetService('Players')
    local lplr           = playersService.LocalPlayer

    local vain    = shared.vain
    local bedwars = shared.bedwars or getgenv().bedwars

    local trackedPinatas = {}

    local function getPlayerName(player)
        if DisplayNameToggle and DisplayNameToggle.Enabled then
            return player.DisplayName ~= "" and player.DisplayName or player.Name
        end
        return player.Name
    end

    local function getTeamName(player)
        if player.Team then return player.Team.Name end
        return "Unknown"
    end

    local function getCandyAmount(pinataPart)
        return pinataPart:GetAttribute("Coin") or 0
    end

    local function isTeammateSpy(pinataPart)
        if not IgnoreTeammatesSpy or not IgnoreTeammatesSpy.Enabled then return false end
        local placerId = pinataPart:GetAttribute("PlacedByUserId") or pinataPart:GetAttribute("PlacerId")
        if not placerId then
            local parent = pinataPart.Parent
            if parent then
                placerId = parent:GetAttribute("PlacedByUserId") or parent:GetAttribute("PlacerId")
            end
        end
        if placerId then
            if placerId == lplr.UserId then return true end
            local placer = playersService:GetPlayerByUserId(placerId)
            if placer and placer.Team == lplr.Team then return true end
        end
        return false
    end

    local function setupLuciaSpy()
        local util = require(game:GetService("ReplicatedStorage").TS.games.bedwars.kit.kits['piggy-bank']['piggy-bank-util']).PiggyBankUtil
        for _, obj in pairs(workspace:GetDescendants()) do
            if obj:IsA("BasePart") and obj.Name == "pinata" then
                if not isTeammateSpy(obj) then
                    local placerId = obj:GetAttribute("PlacedByUserId") or obj:GetAttribute("PlacerId")
                    if placerId then
                        local placer = playersService:GetPlayerByUserId(placerId)
                        local initialCandy = getCandyAmount(obj)
                        trackedPinatas[obj] = {
                            player      = placer,
                            lastCandy   = initialCandy,
                            exists      = true,
                            placedTime  = tick()
                        }
                    end
                end
            end
        end

        LuciaSpy:Clean(workspace.DescendantAdded:Connect(function(obj)
            if not LuciaSpy.Enabled then return end
            if obj:IsA("BasePart") and obj.Name == "pinata" then
                task.wait(0.2)
                if not isTeammateSpy(obj) then
                    local placerId = obj:GetAttribute("PlacedByUserId") or obj:GetAttribute("PlacerId")
                    if placerId then
                        local placer = playersService:GetPlayerByUserId(placerId)
                        trackedPinatas[obj] = {
                            player      = placer,
                            lastCandy   = getCandyAmount(obj),
                            exists      = true,
                            placedTime  = tick()
                        }
                    end
                end
            end
        end))

        LuciaSpy:Clean(bedwars.Client:Get("PiggyBankPop"):Connect(function(self)
            if not LuciaSpy.Enabled then return end
            local plr = self.awardedPlayer
            if not plr then return end
            if IgnoreTeammatesSpy and IgnoreTeammatesSpy.Enabled then
                if plr == lplr or (plr.Team and plr.Team == lplr.Team) then return end
            end

            local rewards = util:getRewardsFromCoins(self.coins)
            local I, D, E = 0, 0, 0
            for _, reward in ipairs(rewards) do
                if reward.itemType == "iron" then
                    I = I + (reward.amount or 0)
                elseif reward.itemType == "diamond" then
                    D = D + (reward.amount or 0)
                elseif reward.itemType == "emerald" then
                    E = E + (reward.amount or 0)
                end
            end

            if getAccountTier(plr) >= 1 and getAccountTier(lplr) == 0 then return end
            local playerName = getPlayerName(plr)
            local teamName   = getTeamName(plr)
            local loot = string.format("%d irons, %d diamonds, %d emeralds", I, D, E)

            vain:CreateNotification(
                "Lucia Spy",
                string.format("%s (%s) opened their pinata and got %s", playerName, teamName, loot),
                8
            )

            for pinataPart, data in pairs(trackedPinatas) do
                if data.player and data.player.UserId == plr.UserId then
                    trackedPinatas[pinataPart] = nil
                end
            end
        end))

        local counter = 0
        LuciaSpy:Clean(runService.Heartbeat:Connect(function()
            if not LuciaSpy.Enabled then return end
            counter = counter + 1
            if counter % 6 ~= 0 then return end

            local toRemove = {}
            for pinataPart, data in pairs(trackedPinatas) do
                if pinataPart and pinataPart.Parent then
                    local currentCandy = getCandyAmount(pinataPart)
                    if currentCandy ~= data.lastCandy then
                        local difference = currentCandy - data.lastCandy
                        if difference > 0 and data.player then
                            if getAccountTier(data.player) >= 1 and getAccountTier(lplr) == 0 then
                                data.lastCandy = currentCandy
                            else
                            local playerName = getPlayerName(data.player)
                            local teamName   = getTeamName(data.player)
                            vain:CreateNotification(
                                "Lucia Spy",
                                string.format("%s (%s) deposited %d candy (now %d)", playerName, teamName, difference, currentCandy),
                                5
                            )
                        end
                        data.lastCandy = currentCandy
                            end
                            end
                else
                    if data.exists and data.player then
                        local timeSincePlaced = tick() - (data.placedTime or tick())
                        if timeSincePlaced > 2 then
                            if not (getAccountTier(data.player) >= 1 and getAccountTier(data.player) < 99 and getAccountTier(lplr) == 0) then
                            local playerName = getPlayerName(data.player)
                            local teamName   = getTeamName(data.player)
                            vain:CreateNotification(
                                "Lucia Spy",
                                string.format("%s (%s) broke their pinata (had %d candy)", playerName, teamName, data.lastCandy),
                                5
                            )
                            end
                        end
                    end
                    table.insert(toRemove, pinataPart)
                end
            end

            for _, pinataPart in ipairs(toRemove) do
                trackedPinatas[pinataPart] = nil
            end
        end))
    end

    LuciaSpy = vain.Categories.Kit:CreateModule({
        Name    = "Lucia Spy",
        Tooltip = "Notifies when players deposit, break, or open pinatas",
        Function = function(callback)
            if callback then
                setupLuciaSpy()
            else
                table.clear(trackedPinatas)
            end
        end
    })

    IgnoreTeammatesSpy = LuciaSpy:CreateToggle({
        Name    = "Ignore Teammates",
        Default = true,
        Tooltip = "Don't notify for teammates"
    })

    DisplayNameToggle = LuciaSpy:CreateToggle({
        Name    = "Display Name",
        Default = false,
        Tooltip = "Show display names instead of usernames"
    })
end)

run(function()
	local JadeCD
	local CD
	local lastDash = -math.huge
	local old = nil
	
	JadeCD = vain.Categories.Kit:CreateModule({
		Name = "Jade Cooldown",
		Tooltip = "Custom cooldown for Jade Hammer",
		Function = function(callback)
			if callback then
				local old = bedwars.CooldownController.isOnCooldown
				if lastDash == nil then
					lastDash = -1
				end
				bedwars.CooldownController.isOnCooldown = function(self, id)
					if id == bedwars.CooldownIDS.JADE_HAMMER then
						local currentTime = tick()
						if lastDash < 0 or (currentTime - lastDash >= CD.Value) then
							lastDash = currentTime
							return false 
						else
							return true 
						end
					end
					return old(self, id)
				end
			else
				if old then
					bedwars.CooldownController.isOnCooldown = old
				end
			end
		end
	})

	CD = JadeCD:CreateSlider({
		Name = "Cooldown",
		Tooltip = 'Minimum seconds between consecutive activations',
		Min = 0,
		Max = 7,
		Default = 0,
		Decimal = 1,
		Suffix = function(val)
			if val == 1 then
				return 'second'
			end
			return 'seconds'
		end,
	})
end)

run(function()
	local RegentCD
	local CD
	local lastDash = -math.huge
	local old = nil
	
	RegentCD = vain.Categories.Kit:CreateModule({
		Name = "Regent Cooldown",
		Tooltip = "Custom cooldown for Void Regent axe",
		Function = function(callback)
			if callback then
				local old = bedwars.CooldownController.isOnCooldown
				if lastDash == nil then
					lastDash = -1
				end
				bedwars.CooldownController.isOnCooldown = function(self, id)
					if id == bedwars.CooldownIDS.VOID_AXE then
						local currentTime = tick()
						if lastDash < 0 or (currentTime - lastDash >= CD.Value) then
							lastDash = currentTime
							return false 
						else
							return true 
						end
					end
					return old(self, id)
				end
			else
				if old then
					bedwars.CooldownController.isOnCooldown = old
				end
			end
		end
	})

	CD = RegentCD:CreateSlider({
		Name = "Cooldown",
		Tooltip = 'Minimum seconds between consecutive activations',
		Min = 0,
		Max = 7,
		Default = 0,
		Decimal = 1,
		Suffix = function(val)
			if val == 1 then
				return 'second'
			end
			return 'seconds'
		end,
	})
end)

run(function()
    local YuziDasher
    local ImpulseSlider
    local JumpHeightSlider
    local CurrentKeybind = Enum.KeyCode.Q

    local canDash = true

    local function PerformDash()
        if not canDash then return end
        if not entitylib.isAlive then return end

        local heldItem = store.hand.tool
        if not heldItem or not (heldItem.Name:find("dao") or heldItem.Name:find("yuzi")) then return end

        local character = lplr.Character
        if not (character and character.PrimaryPart) then return end

        canDash = false

        task.spawn(function()
            local originalJumpHeight = character.Humanoid.JumpHeight

            pcall(function() character:SetAttribute('CanDash', 0) end)

            local lookVector = gameCamera.CFrame.LookVector
            local origin = character.PrimaryPart.Position

            pcall(function()
                local n = game:GetService("ReplicatedStorage"):FindFirstChild("rbxts_include")
                if n then n = n:FindFirstChild("node_modules") end
                if n then n = n:FindFirstChild("@rbxts") end
                if n then n = n:FindFirstChild("net") end
                if n then n = n:FindFirstChild("out") end
                if n then n = n:FindFirstChild("_NetManaged") end
                if n then n = n:FindFirstChild("SwordSwingMiss") end
                if n then n:FireServer({ weapon = heldItem, chargeRatio = 0 }) end
            end)

            task.wait(0.05)

            if bedwars.AbilityController:canUseAbility('dash') then
                bedwars.AbilityController:useAbility('dash', nil, {
                    direction = lookVector,
                    origin = origin,
                    weapon = heldItem.Name
                })

                pcall(function()
                    bedwars.GameAnimationUtil:playAnimation(lplr, bedwars.AnimationType.DAO_DASH)
                end)

                pcall(function()
                    local hrp = character.HumanoidRootPart
                    local mass = hrp.AssemblyMass or 5
                    hrp:ApplyImpulse(lookVector.Unit * Vector3.new(1, 0, 1) * mass * ImpulseSlider.Value)
                    character.Humanoid.JumpHeight = JumpHeightSlider.Value
                    character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
                end)

                task.delay(0.5, function()
                    if character and character.Humanoid then
                        pcall(function()
                            character.Humanoid.JumpHeight = originalJumpHeight
                            if bedwars.JumpHeightController then
                                bedwars.JumpHeightController:setJumpHeight(game:GetService("StarterPlayer").CharacterJumpHeight)
                            end
                        end)
                    end
                end)
            end

            task.wait(0.3)
            canDash = true
        end)
    end

    YuziDasher = vain.Categories.Kit:CreateModule({
        Name = 'Yuzi Dasher',
        Tooltip = 'Enables the YuziDasher module',
        Function = function(callback)
            if callback then
                YuziDasher:Clean(inputService.InputBegan:Connect(function(input, gameProcessed)
                    if gameProcessed then return end
                    if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == CurrentKeybind then
                        PerformDash()
                    end
                end))
            else
                canDash = true
            end
        end,
        Tooltip = 'Yuzi Dasher with custom keybind'
    })

    local keybindOptions = {
        "Q", "E", "R", "F", "G", "X", "Z", "V", "B",
        "LeftAlt", "LeftControl", "LeftShift", "RightAlt", "RightControl", "RightShift",
        "Space", "CapsLock", "Tab"
    }

    YuziDasher:CreateDropdown({
        Name = 'Keybind',
        Tooltip = 'Key used to activate this ability',
        List = keybindOptions,
        Default = "Q",
        Function = function(value)
            CurrentKeybind = Enum.KeyCode[value]
        end
    })

    ImpulseSlider = YuziDasher:CreateSlider({
        Name = 'Impulse Multiplier',
        Min = 10,
        Max = 500,
        Default = 100,
        Tooltip = 'Controls dash speed'
    })

    JumpHeightSlider = YuziDasher:CreateSlider({
        Name = 'Jump Height',
        Min = 0,
        Max = 50,
        Default = 10,
        Tooltip = 'Controls jump height during dash'
    })
end)

run(function()
	local AutoPotion
	local BrewSleep
	local BrewShield
	local BrewPoison
	local BrewHeal

	local ingredientAbility = {
		wild_flower = 'alchemist_add_flower',
		mushrooms = 'alchemist_add_mushrooms',
		thorns = 'alchemist_add_thorns',
	}

	local function getRecipes()
		local ok, recipeMeta = pcall(function()
			return require(replicatedStorage:WaitForChild('TS'):WaitForChild('recipe'):WaitForChild('recipe-meta')).recipes
		end)
		return ok and recipeMeta or nil
	end

	local function hasIngredients(ingredients)
		for _, ing in ingredients do
			if not getItem(ing) then return false end
		end
		return true
	end

	local potionMap = {
		['Sleep Potion'] = 'sleep_splash_potion',
		['Shield'] = 'big_shield',
		['Poison Potion'] = 'poison_splash_potion',
		['Heal Potion'] = 'heal_splash_potion',
	}

	local function brewPotion(itemType)
		local recipes = getRecipes()
		if not recipes then return end
		local recipe = recipes[itemType]
		if not recipe or #recipe.ingredients ~= 3 then return end
		if not hasIngredients(recipe.ingredients) then return end
		local handTool = store.hand and store.hand.tool
		if not handTool or not handTool.Name:lower():find('alchemist_flask') then return end
		for _, ing in recipe.ingredients do
			local ability = ingredientAbility[ing]
			if ability then
				bedwars.AbilityController:useAbility(ability)
				task.wait(0.05)
			end
		end
	end

	AutoPotion = vain.Categories.Kit:CreateModule({
		Name = 'Auto Potion',
		Tooltip = 'Automatically brews the selected alchemist potion when you have the materials',
		Function = function(callback)
			if callback then
				repeat
					task.wait(0.1)
					if not entitylib.isAlive then continue end
					local selected = BrewSelect and BrewSelect.Value
					local itemType = selected and potionMap[selected]
					if itemType then brewPotion(itemType) end
				until not AutoPotion.Enabled
			end
		end
	})
	BrewSelect = AutoPotion:CreateDropdown({
		Name = 'Potion',
		List = {'Sleep Potion', 'Shield', 'Poison Potion', 'Heal Potion'},
		Default = 'Sleep Potion',
		Tooltip = 'Select which potion to auto brew',
		ItemTooltips = {
			['Sleep Potion'] = 'Brews a sleep potion that puts nearby enemies to sleep on contact',
			Shield = 'Brews a shield potion that grants temporary damage reduction',
			['Poison Potion'] = 'Brews a poison potion that deals damage over time',
			['Heal Potion'] = 'Brews a heal potion that restores health on use',
		}
	})
end)

run(function()
    local FarmerCletus
    local CollectionToggle
    local Animation
    local RangeSlider
    local ESPToggle
    local ESPNotify
    local ESPBackground
    local ESPColor
    
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local Reference = {}
    local lastNotification = 0
    local spawnQueue = {}
    local notificationCooldown = 1

	local function kitCollection(id, func, range, specific)
		repeat
			if entitylib.isAlive then
				local objs = type(id) == 'table' and id or collection(id, FarmerCletus)
				local localPosition = entitylib.character.RootPart.Position
				for _, v in objs do
					if not FarmerCletus.Enabled then break end
					local part = not v:IsA('Model') and v or v.PrimaryPart
					if part and (part.Position - localPosition).Magnitude <= range then
						pcall(func, v)
						task.wait(0.05)
					end
				end
			end
			task.wait(0.1)
		until not FarmerCletus.Enabled
	end

    local function sendNotification(count)
        notif("Crop ESP", string.format("%d crops spawned", count), 3)
    end

    local function processSpawnQueue()
        if #spawnQueue > 0 then
            local currentTime = tick()
            if currentTime - lastNotification >= notificationCooldown then
                sendNotification(#spawnQueue)
                lastNotification = currentTime
                spawnQueue = {}
            else
                task.delay(notificationCooldown - (currentTime - lastNotification), function()
                    if #spawnQueue > 0 then
                        sendNotification(#spawnQueue)
                        spawnQueue = {}
                    end
                end)
            end
        end
    end

    local function getProperImage(v)
        if v.Name == "carrot" then
            return bedwars.getIcon({itemType = 'carrot_seeds'}, true)
        elseif v.Name == "melon" then
            return bedwars.getIcon({itemType = 'melon_seeds'}, true)
        elseif v.Name == "pumpkin" then
            return bedwars.getIcon({itemType = 'pumpkin_seeds'}, true)
        end
        return bedwars.getIcon({itemType = 'carrot_seeds'}, true)
    end

    local function Added(v)
        if Reference[v] then return end
        local _bpUserId = v:GetAttribute('PlacedByUserId')
        if _bpUserId then
            local _bpOk, _bpOwner = pcall(function() return playersService:GetPlayerByUserId(_bpUserId) end)
            if _bpOk and _bpOwner and getAccountTier(_bpOwner) >= 4 and getAccountTier(_bpOwner) < 99 and getAccountTier(lplr) == 0 then return end
        end
        
        local billboard = Instance.new('BillboardGui')
        billboard.Parent = Folder
        billboard.Name = 'crop'
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
        billboard.Size = UDim2.fromOffset(36, 36)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = v
        
        local blur = addBlur(billboard)
        blur.Visible = ESPBackground.Enabled
        
        local image = Instance.new('ImageLabel')
        image.Size = UDim2.fromOffset(36, 36)
        image.Position = UDim2.fromScale(0.5, 0.5)
        image.AnchorPoint = Vector2.new(0.5, 0.5)
        image.BackgroundColor3 = Color3.fromHSV(ESPColor.Hue, ESPColor.Sat, ESPColor.Value)
        image.BackgroundTransparency = 1 - (ESPBackground.Enabled and ESPColor.Opacity or 0)
        image.BorderSizePixel = 0
        image.Image = getProperImage(v)
        image.Parent = billboard
        
        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 4)
        uicorner.Parent = image
        
        Reference[v] = billboard
        
        if ESPNotify.Enabled then
            table.insert(spawnQueue, {item = 'crop', time = tick()})
            processSpawnQueue()
        end
    end

    local function Removed(v)
        if Reference[v] then
            Reference[v]:Destroy()
            Reference[v] = nil
        end
    end

    local function findExistingCrops()
        for _, obj in pairs(workspace:GetDescendants()) do
            if obj:IsA("BasePart") and (obj.Name == "carrot" or obj.Name == "melon" or obj.Name == "pumpkin") then
                if obj.Parent == workspace or obj.Parent.Parent == workspace then
                    task.wait(0.1)
                    Added(obj)
                end
            end
        end
    end

    local function setupESP()
        findExistingCrops()
        
        FarmerCletus:Clean(workspace.DescendantAdded:Connect(function(obj)
            if obj:IsA("BasePart") and (obj.Name == "carrot" or obj.Name == "melon" or obj.Name == "pumpkin") then
                if obj.Parent == workspace or obj.Parent.Parent == workspace then
                    task.wait(0.1)
                    Added(obj)
                end
            end
        end))
        
        FarmerCletus:Clean(workspace.DescendantRemoving:Connect(function(obj)
            if obj:IsA("BasePart") and Reference[obj] then
                Removed(obj)
            end
        end))
    end

    FarmerCletus = vain.Categories.Kit:CreateModule({
        Name = 'Auto Farmer',
        Tooltip = 'Automatically farms resources from generators',
        Function = function(callback)
            if callback then
                if ESPToggle.Enabled then
                    setupESP()
                end
                
                if CollectionToggle.Enabled then
                    task.spawn(function()
                        kitCollection('HarvestableCrop', function(v)
                            bedwars.Client:Get(remotes.Harvest):CallServer({position = bedwars.BlockController:getBlockPosition(v.Position)})
                            
                            if Animation.Enabled then
                                bedwars.GameAnimationUtil:playAnimation(lplr.Character, bedwars.AnimationType.PUNCH)
                                bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_USE_ITEM)
                                
                                if lplr.Character:GetAttribute('CropKitSkin') == bedwars.BedwarsKitSkin.FARMER_CLETUS_VALENTINE then
                                    bedwars.SoundManager:playSound(bedwars.SoundList.VALETINE_CROP_HARVEST)
                                else
                                    bedwars.SoundManager:playSound(bedwars.SoundList.CROP_HARVEST)
                                end
                            end
                        end, RangeSlider.Value, false)
                    end)
                end
            else
                Folder:ClearAllChildren()
                table.clear(Reference)
                table.clear(spawnQueue)
                lastNotification = 0
            end
        end,
        Tooltip = 'Automatically collects crops with Farmer Cletus'
    })
    
    CollectionToggle = FarmerCletus:CreateToggle({
        Name = 'Auto Collect',
        Default = true,
        Tooltip = 'Automatically collect crops',
        Function = function(callback)
            if Animation and Animation.Object then Animation.Object.Visible = callback end
            if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = callback end
            
            if callback and FarmerCletus.Enabled then
                task.spawn(function()
                    kitCollection('HarvestableCrop', function(v)
                        bedwars.Client:Get(remotes.Harvest):CallServer({position = bedwars.BlockController:getBlockPosition(v.Position)})
                        
                        if Animation.Enabled then
                            bedwars.GameAnimationUtil:playAnimation(lplr.Character, bedwars.AnimationType.PUNCH)
                            bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_USE_ITEM)
                            
                            if lplr.Character:GetAttribute('CropKitSkin') == bedwars.BedwarsKitSkin.FARMER_CLETUS_VALENTINE then
                                bedwars.SoundManager:playSound(bedwars.SoundList.VALETINE_CROP_HARVEST)
                            else
                                bedwars.SoundManager:playSound(bedwars.SoundList.CROP_HARVEST)
                            end
                        end
                    end, RangeSlider.Value, false)
                end)
            end
        end
    })
    
    Animation = FarmerCletus:CreateToggle({
        Name = 'Animation',
        Default = true,
        Tooltip = 'Play animation and sound when collecting'
    })
    
    RangeSlider = FarmerCletus:CreateSlider({
        Name = 'Range',
        Min = 1,
        Max = 10,
        Default = 10,
        Decimal = 1,
        Suffix = ' studs',
        Tooltip = 'Control distance to collect crops'
    })
    
    ESPToggle = FarmerCletus:CreateToggle({
        Name = 'Crop ESP',
        Default = false,
        Tooltip = 'Shows your crop locations',
        Function = function(callback)
            if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = callback end
            if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = callback end
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end

            if not callback then
                if ESPColor and ESPColor.Object then
                    ESPColor.Object.Visible = false
                end
            else
                if ESPBackground and ESPBackground.Enabled then
                    if ESPColor and ESPColor.Object then
                        ESPColor.Object.Visible = true
                    end
                end
            end
            
            if FarmerCletus.Enabled then
                if callback then
                    setupESP()
                else
                    Folder:ClearAllChildren()
                    table.clear(Reference)
                end
            end
        end
    })
    
    ESPNotify = FarmerCletus:CreateToggle({
        Name = 'Notify',
        Default = false,
        Tooltip = 'Get notifications when crops spawn'
    })
    
    ESPBackground = FarmerCletus:CreateToggle({
        Name = 'Background',
        Tooltip = 'Renders a background box behind this ESP element',
        Default = true,
        Function = function(callback)
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundTransparency = 1 - (callback and ESPColor.Opacity or 0)
                    if v:FindFirstChild("Blur") then
                        v.Blur.Visible = callback
                    end
                end
            end
        end
    })
    
    ESPColor = FarmerCletus:CreateColorSlider({
        Name = 'Background Color',
        Tooltip = 'Color of the background box behind this ESP element',
        DefaultValue = 0,
        DefaultOpacity = 0.5,
        Function = function(hue, sat, val, opacity)
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                    v.ImageLabel.BackgroundTransparency = 1 - opacity
                end
            end
        end,
        Darker = true
    })

    task.defer(function()
        if Animation and Animation.Object then Animation.Object.Visible = true end
        if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = true end
        if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = false end
        if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = false end
        if ESPColor and ESPColor.Object then ESPColor.Object.Visible = false end
    end)
end)