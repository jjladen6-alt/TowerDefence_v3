local HttpService = game:GetService('HttpService')

local TowerCombatService = {}
TowerCombatService.__index = TowerCombatService

local function jsonEncode(payload): string
    local ok, encoded = pcall(function()
        return HttpService:JSONEncode(payload)
    end)
    if ok and type(encoded) == 'string' then
        return encoded
    end
    return tostring(payload)
end

local function toTelemetryEnvelope(kind: string, payload)
    return {
        schemaVersion = 1,
        service = 'TowerCombatService',
        kind = kind,
        payload = payload,
    }
end

local function pickClosestEnemyInRange(towerPosition: Vector3, enemies, maxRange: number)
    local best = nil
    local bestDistance = math.huge
    for _, enemy in ipairs(enemies) do
        local distance = (enemy.position - towerPosition).Magnitude
        if distance <= maxRange and distance < bestDistance then
            best = enemy
            bestDistance = distance
        end
    end
    return best
end

local function isCandidateBetterByProgress(candidate, best, preferHigherProgress: boolean): boolean
    if not best then
        return true
    end

    local candidateProgress = tonumber(candidate.pathProgress) or 0
    local bestProgress = tonumber(best.pathProgress) or 0
    if preferHigherProgress then
        if candidateProgress > bestProgress then
            return true
        end
        if candidateProgress < bestProgress then
            return false
        end
    else
        if candidateProgress < bestProgress then
            return true
        end
        if candidateProgress > bestProgress then
            return false
        end
    end

    -- Stable tie-breaker when progress is equal.
    return candidate.enemyId < best.enemyId
end

local function pickFirstEnemyInRange(towerPosition: Vector3, enemies, maxRange: number)
    local best = nil
    for _, enemy in ipairs(enemies) do
        local distance = (enemy.position - towerPosition).Magnitude
        if distance <= maxRange and isCandidateBetterByProgress(enemy, best, true) then
            best = enemy
        end
    end
    return best
end

local function pickLastEnemyInRange(towerPosition: Vector3, enemies, maxRange: number)
    local best = nil
    for _, enemy in ipairs(enemies) do
        local distance = (enemy.position - towerPosition).Magnitude
        if distance <= maxRange and isCandidateBetterByProgress(enemy, best, false) then
            best = enemy
        end
    end
    return best
end

local function pickTargetByMode(towerPosition: Vector3, enemies, maxRange: number, targetMode: string)
    if targetMode == 'Last' then
        return pickLastEnemyInRange(towerPosition, enemies, maxRange)
    end
    if targetMode == 'Closest' then
        return pickClosestEnemyInRange(towerPosition, enemies, maxRange)
    end
    return pickFirstEnemyInRange(towerPosition, enemies, maxRange)
end

local function findEnemyByIdInRange(enemyId: number, towerPosition: Vector3, enemies, maxRange: number)
    for _, enemy in ipairs(enemies) do
        if enemy.enemyId == enemyId then
            local distance = (enemy.position - towerPosition).Magnitude
            if distance <= maxRange then
                return enemy
            end
            return nil
        end
    end
    return nil
end

local function getTierValue(configByTier, tier: number, fallback: number): number
    if type(configByTier) ~= 'table' then
        return fallback
    end
    local value = tonumber(configByTier[tier])
    if value == nil then
        return fallback
    end
    return value
end

local function computeSupportAttackIntervalMultipliers(towers, config)
    local supportTypeName = 'Support'
    local auraRadiusByTier = config.SUPPORT_TOWER_AURA_RADIUS_BY_TIER
    local intervalMultiplierByTier = config.SUPPORT_TOWER_ATTACK_INTERVAL_MULTIPLIER_BY_TIER
    local minAggregateMultiplier = tonumber(config.SUPPORT_TOWER_MIN_ATTACK_INTERVAL_MULTIPLIER) or 0.75
    minAggregateMultiplier = math.clamp(minAggregateMultiplier, 0.1, 1)

    local emitters = {}
    for _, tower in ipairs(towers) do
        if tower.towerId ~= '' and tostring(tower.towerType or '') == supportTypeName then
            local tier = math.max(0, math.floor(tonumber(tower.upgradeTier) or 0))
            local radius = getTierValue(auraRadiusByTier, tier, 20)
            local buffMultiplier = getTierValue(intervalMultiplierByTier, tier, 0.94)
            radius = math.max(1, radius)
            buffMultiplier = math.clamp(buffMultiplier, 0.1, 1)

            table.insert(emitters, {
                position = tower.position,
                radius = radius,
                buffMultiplier = buffMultiplier,
                towerId = tower.towerId,
            })
        end
    end

    if #emitters == 0 then
        return {}, 0, 0
    end

    local perTowerMultiplier = {}
    local buffedTowerCount = 0
    for _, tower in ipairs(towers) do
        local towerId = tower.towerId
        if towerId ~= '' and tostring(tower.towerType or '') ~= supportTypeName then
            local aggregateMultiplier = 1
            for _, emitter in ipairs(emitters) do
                if emitter.towerId ~= towerId then
                    local distance = (tower.position - emitter.position).Magnitude
                    if distance <= emitter.radius then
                        aggregateMultiplier *= emitter.buffMultiplier
                    end
                end
            end
            if aggregateMultiplier < minAggregateMultiplier then
                aggregateMultiplier = minAggregateMultiplier
            end
            if aggregateMultiplier < 1 then
                perTowerMultiplier[towerId] = aggregateMultiplier
                buffedTowerCount += 1
            end
        end
    end

    return perTowerMultiplier, #emitters, buffedTowerCount
end

local function normalizeAngleRadians(value: number): number
    return math.atan2(math.sin(value), math.cos(value))
end

local function yawFromLookVector(lookVector: Vector3): number
    return math.atan2(-lookVector.X, -lookVector.Z)
end

local function clampNumber(value: number, minValue: number, maxValue: number): number
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

function TowerCombatService.new(gameConfig, enemyService, towerPlacementService)
    return setmetatable({
        _config = gameConfig,
        _enemyService = enemyService,
        _towerPlacementService = towerPlacementService,
        _roundService = nil,
        _running = false,
        _runId = 0,
        _lastAttackAtByTowerId = {},
        _targetEnemyByTowerId = {},
        _lastFacingUpdateAtByTowerId = {},
        _wasWavePhase = false,
        _debugEnabled = gameConfig.DEBUG_TOWER_COMBAT == true,
        _debugPrintIntervalSeconds = tonumber(gameConfig.DEBUG_TOWER_COMBAT_PRINT_INTERVAL_SECONDS) or 5,
        _debugLogOutsideWave = gameConfig.DEBUG_TOWER_COMBAT_LOG_OUTSIDE_WAVE == true,
        _debugLastPrintAt = 0,
        _debugCounters = {
            ticks = 0,
            towersSeen = 0,
            enemiesSeen = 0,
            shotsAttempted = 0,
            hitsLanded = 0,
            missesNoTarget = 0,
            applyDamageErrors = 0,
            damageApplied = 0,
            killsObserved = 0,
            supportEmittersSeen = 0,
            supportBuffedTowersSeen = 0,
            supportBuffedShots = 0,
            facingUpdatesApplied = 0,
            facingUpdatesSkipped = 0,
        },
    }, TowerCombatService)
end

function TowerCombatService:setRoundService(roundService)
    self._roundService = roundService
end

function TowerCombatService:_isWavePhase(): boolean
    local roundService = self._roundService
    if not roundService or type(roundService.getPhase) ~= 'function' then
        return true
    end
    return roundService:getPhase() == 'Wave'
end

function TowerCombatService:_canTowerAttack(towerId: string, attackInterval: number, nowTime: number): boolean
    local lastAttackAt = self._lastAttackAtByTowerId[towerId]
    if not lastAttackAt then
        return true
    end
    return (nowTime - lastAttackAt) >= attackInterval
end

function TowerCombatService:_recordTowerAttack(towerId: string, nowTime: number)
    self._lastAttackAtByTowerId[towerId] = nowTime
end

function TowerCombatService:_pruneMissingTowerCooldowns(activeTowers)
    local liveTowerIds = {}
    for _, tower in ipairs(activeTowers) do
        if tower.towerId ~= '' then
            liveTowerIds[tower.towerId] = true
        end
    end

    for towerId in pairs(self._lastAttackAtByTowerId) do
        if not liveTowerIds[towerId] then
            self._lastAttackAtByTowerId[towerId] = nil
        end
    end

    for towerId in pairs(self._targetEnemyByTowerId) do
        if not liveTowerIds[towerId] then
            self._targetEnemyByTowerId[towerId] = nil
        end
    end

    for towerId in pairs(self._lastFacingUpdateAtByTowerId) do
        if not liveTowerIds[towerId] then
            self._lastFacingUpdateAtByTowerId[towerId] = nil
        end
    end
end

function TowerCombatService:_getFacingConfig()
    local facingConfig = self._config.TOWER_FACING
    if type(facingConfig) ~= 'table' then
        return nil
    end
    if facingConfig.enabled == false then
        return nil
    end

    local resolved = {
        enabled = true,
        enabledTowerTypes = facingConfig.enabledTowerTypes,
        maxTurnSpeedDegPerSecond = facingConfig.maxTurnSpeedDegPerSecond,
        minAngleDeltaDeg = facingConfig.minAngleDeltaDeg,
        updateIntervalSeconds = facingConfig.updateIntervalSeconds,
    }

    local activeProfile = facingConfig.activeProfile
    local profiles = facingConfig.profiles
    if type(activeProfile) == 'string' and activeProfile ~= '' and type(profiles) == 'table' then
        local profile = profiles[activeProfile]
        if type(profile) == 'table' then
            if resolved.maxTurnSpeedDegPerSecond == nil then
                resolved.maxTurnSpeedDegPerSecond = profile.maxTurnSpeedDegPerSecond
            end
            if resolved.minAngleDeltaDeg == nil then
                resolved.minAngleDeltaDeg = profile.minAngleDeltaDeg
            end
            if resolved.updateIntervalSeconds == nil then
                resolved.updateIntervalSeconds = profile.updateIntervalSeconds
            end
        end
    end

    return resolved
end

function TowerCombatService:_isFacingEnabledForTowerType(towerType: string): boolean
    local facingConfig = self:_getFacingConfig()
    if not facingConfig then
        return false
    end

    local enabledTowerTypes = facingConfig.enabledTowerTypes
    if type(enabledTowerTypes) ~= 'table' or next(enabledTowerTypes) == nil then
        return true
    end
    return enabledTowerTypes[towerType] == true
end

function TowerCombatService:_resolveTowerFacingPart(tower): BasePart?
    local model = tower.model
    if typeof(model) ~= 'Instance' or not model:IsA('Model') then
        return nil
    end

    local facingPartName = tower.facingPartName
    if type(facingPartName) == 'string' and facingPartName ~= '' then
        local explicitPart = model:FindFirstChild(facingPartName, true)
        if explicitPart and explicitPart:IsA('BasePart') then
            return explicitPart
        end
    end

    if model.PrimaryPart then
        return model.PrimaryPart
    end

    local firstPart = model:FindFirstChildWhichIsA('BasePart', true)
    if firstPart then
        model.PrimaryPart = firstPart
    end
    return model.PrimaryPart
end

function TowerCombatService:_updateTowerFacing(tower, targetPosition: Vector3, nowTime: number)
    local towerId = tower.towerId
    if towerId == '' then
        self:_debugIncrement('facingUpdatesSkipped', 1)
        return
    end

    local towerType = tostring(tower.towerType or '')
    if not self:_isFacingEnabledForTowerType(towerType) then
        self:_debugIncrement('facingUpdatesSkipped', 1)
        return
    end

    local facingConfig = self:_getFacingConfig()
    if not facingConfig then
        self:_debugIncrement('facingUpdatesSkipped', 1)
        return
    end

    local lastUpdateAt = self._lastFacingUpdateAtByTowerId[towerId] or 0
    local updateIntervalSeconds = tonumber(facingConfig.updateIntervalSeconds) or 0.1
    updateIntervalSeconds = clampNumber(updateIntervalSeconds, 0.02, 1.0)
    if lastUpdateAt > 0 and (nowTime - lastUpdateAt) < updateIntervalSeconds then
        self:_debugIncrement('facingUpdatesSkipped', 1)
        return
    end

    local facingPart = self:_resolveTowerFacingPart(tower)
    if not facingPart then
        self:_debugIncrement('facingUpdatesSkipped', 1)
        return
    end

    local currentPosition = facingPart.Position
    local toTarget = Vector3.new(targetPosition.X - currentPosition.X, 0, targetPosition.Z - currentPosition.Z)
    if toTarget.Magnitude < 0.05 then
        self:_debugIncrement('facingUpdatesSkipped', 1)
        return
    end

    local desiredYaw = yawFromLookVector(toTarget.Unit)
    local currentYaw = yawFromLookVector(facingPart.CFrame.LookVector)
    local deltaYaw = normalizeAngleRadians(desiredYaw - currentYaw)
    local minAngleDeltaDeg = clampNumber(tonumber(facingConfig.minAngleDeltaDeg) or 1.5, 0.1, 45)
    if math.abs(math.deg(deltaYaw)) < minAngleDeltaDeg then
        self._lastFacingUpdateAtByTowerId[towerId] = nowTime
        self:_debugIncrement('facingUpdatesSkipped', 1)
        return
    end

    local elapsedSinceUpdate = if lastUpdateAt > 0 then (nowTime - lastUpdateAt) else updateIntervalSeconds
    local maxTurnSpeedDegPerSecond = clampNumber(tonumber(facingConfig.maxTurnSpeedDegPerSecond) or 300, 45, 1080)
    local maxStepRadians = math.rad(maxTurnSpeedDegPerSecond) * math.max(0.01, elapsedSinceUpdate)
    local stepYaw = clampNumber(deltaYaw, -maxStepRadians, maxStepRadians)
    local nextYaw = currentYaw + stepYaw

    local pivot = tower.model:GetPivot()
    tower.model:PivotTo(CFrame.new(pivot.Position) * CFrame.Angles(0, nextYaw, 0))
    self._lastFacingUpdateAtByTowerId[towerId] = nowTime
    self:_debugIncrement('facingUpdatesApplied', 1)
end

function TowerCombatService:_debugIncrement(counterName: string, amount: number?)
    if not self._debugEnabled then
        return
    end
    local current = self._debugCounters[counterName] or 0
    self._debugCounters[counterName] = current + (amount or 1)
end

function TowerCombatService:_debugMaybeFlush(nowTime: number)
    if not self._debugEnabled then
        return
    end

    local interval = self._debugPrintIntervalSeconds
    if interval < 1 then
        interval = 1
    end

    if (nowTime - self._debugLastPrintAt) < interval then
        return
    end

    print(
        ('[TowerCombatDebug] ticks=%d towersSeen=%d enemiesSeen=%d shotsAttempted=%d hitsLanded=%d missesNoTarget=%d applyDamageErrors=%d damageApplied=%d killsObserved=%d supportEmittersSeen=%d supportBuffedTowersSeen=%d supportBuffedShots=%d'):format(
            self._debugCounters.ticks or 0,
            self._debugCounters.towersSeen or 0,
            self._debugCounters.enemiesSeen or 0,
            self._debugCounters.shotsAttempted or 0,
            self._debugCounters.hitsLanded or 0,
            self._debugCounters.missesNoTarget or 0,
            self._debugCounters.applyDamageErrors or 0,
            self._debugCounters.damageApplied or 0,
            self._debugCounters.killsObserved or 0,
            self._debugCounters.supportEmittersSeen or 0,
            self._debugCounters.supportBuffedTowersSeen or 0,
            self._debugCounters.supportBuffedShots or 0
        )
    )

    -- Keep debug prints interval-based so values reflect recent activity.
    self:_resetDebugCounters(nowTime)
end

function TowerCombatService:_resetDebugCounters(nowTime: number?)
    self._debugLastPrintAt = nowTime or 0
    for key in pairs(self._debugCounters) do
        self._debugCounters[key] = 0
    end
end

function TowerCombatService:_tickCombat()
    local nowTime = os.clock()
    local isWavePhase = self:_isWavePhase()
    if isWavePhase and not self._wasWavePhase then
        table.clear(self._lastAttackAtByTowerId)
        table.clear(self._targetEnemyByTowerId)
        table.clear(self._lastFacingUpdateAtByTowerId)
        if self._debugEnabled and self._config.DEBUG_TOWER_COMBAT_RESET_ON_WAVE_START ~= false then
            self:_resetDebugCounters(nowTime)
        end
    end
    self._wasWavePhase = isWavePhase

    self:_debugIncrement('ticks', 1)

    if not isWavePhase then
        if self._debugLogOutsideWave then
            self:_debugMaybeFlush(nowTime)
        end
        return
    end

    local enemies = self._enemyService:getTargetableEnemies()
    self:_debugIncrement('enemiesSeen', #enemies)
    if #enemies == 0 then
        self:_debugMaybeFlush(nowTime)
        return
    end

    local towers = self._towerPlacementService:getActiveTowers()
    self:_debugIncrement('towersSeen', #towers)
    if #towers == 0 then
        self:_debugMaybeFlush(nowTime)
        return
    end

    local supportAttackIntervalMultipliers, supportEmitterCount, supportBuffedTowerCount =
        computeSupportAttackIntervalMultipliers(towers, self._config)
    self:_debugIncrement('supportEmittersSeen', supportEmitterCount or 0)
    self:_debugIncrement('supportBuffedTowersSeen', supportBuffedTowerCount or 0)
    self:_pruneMissingTowerCooldowns(towers)

    for _, tower in ipairs(towers) do
        local towerId = tower.towerId
        if towerId ~= '' then
            local range = math.max(0, tonumber(tower.range) or 0)
            local damage = math.max(0, tonumber(tower.damage) or 0)
            local attackInterval = tonumber(tower.attackInterval) or 1.0
            local supportMultiplier = supportAttackIntervalMultipliers[towerId] or 1
            if supportMultiplier < 1 then
                attackInterval *= supportMultiplier
                self:_debugIncrement('supportBuffedShots', 1)
            end
            if attackInterval < 0.05 then
                attackInterval = 0.05
            end

            if range > 0 and damage > 0 and self:_canTowerAttack(towerId, attackInterval, nowTime) then
                self:_debugIncrement('shotsAttempted', 1)
                local targetEnemy = nil
                local lockedTargetEnemyId = self._targetEnemyByTowerId[towerId]
                if lockedTargetEnemyId ~= nil then
                    targetEnemy = findEnemyByIdInRange(lockedTargetEnemyId, tower.position, enemies, range)
                end
                if not targetEnemy then
                    local targetMode = tostring(tower.targetMode or 'First')
                    targetEnemy = pickTargetByMode(tower.position, enemies, range, targetMode)
                    if targetEnemy then
                        self._targetEnemyByTowerId[towerId] = targetEnemy.enemyId
                    else
                        self._targetEnemyByTowerId[towerId] = nil
                    end
                end
                if targetEnemy then
                    self:_updateTowerFacing(tower, targetEnemy.position, nowTime)
                    local ok, result = self._enemyService:applyDamage(targetEnemy.enemyId, damage, {
                        sourceType = 'Tower',
                        towerId = towerId,
                    })
                    if ok then
                        self:_debugIncrement('hitsLanded', 1)
                        if type(result) == 'table' then
                            self:_debugIncrement('damageApplied', tonumber(result.damageApplied) or 0)
                            if result.isDead then
                                self:_debugIncrement('killsObserved', 1)
                                self._targetEnemyByTowerId[towerId] = nil
                            end
                        end
                        self:_recordTowerAttack(towerId, nowTime)
                    else
                        self:_debugIncrement('applyDamageErrors', 1)
                        self._targetEnemyByTowerId[towerId] = nil
                    end
                else
                    self:_debugIncrement('missesNoTarget', 1)
                end
            end
        end
    end

    self:_debugMaybeFlush(nowTime)
end

function TowerCombatService:start()
    if self._running then
        return
    end

    self._running = true
    self._runId += 1
    self._wasWavePhase = false
    table.clear(self._lastFacingUpdateAtByTowerId)
    self:_resetDebugCounters(0)
    local runId = self._runId
    local tickSeconds = tonumber(self._config.TOWER_COMBAT_TICK_SECONDS) or 0.1
    if tickSeconds < 0.05 then
        tickSeconds = 0.05
    end

    task.spawn(function()
        while self._running and self._runId == runId do
            self:_tickCombat()
            task.wait(tickSeconds)
        end
    end)
end

function TowerCombatService:stop()
    if not self._running then
        return
    end

    self._running = false
    self._runId += 1
    self._wasWavePhase = false
    table.clear(self._lastAttackAtByTowerId)
    table.clear(self._targetEnemyByTowerId)
    table.clear(self._lastFacingUpdateAtByTowerId)
    if self._debugEnabled then
        self:_debugMaybeFlush(os.clock() + self._debugPrintIntervalSeconds)
    end
    print(('[Telemetry][TowerCombatService] %s'):format(jsonEncode(toTelemetryEnvelope('ServiceStopSummary', {
        running = false,
        debugEnabled = self._debugEnabled,
        tickSeconds = tonumber(self._config.TOWER_COMBAT_TICK_SECONDS) or 0.1,
    }))))
end

return TowerCombatService
