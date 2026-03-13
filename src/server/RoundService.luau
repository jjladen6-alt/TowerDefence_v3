local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Workspace = game:GetService('Workspace')
local HttpService = game:GetService('HttpService')

local RoundService = {}
RoundService.__index = RoundService

local function findThroughSameNameWrappers(root: Instance, childName: string): Instance?
    local visited = {}
    local cursor: Instance? = root
    while cursor and not visited[cursor] do
        visited[cursor] = true

        local wrapped = cursor:FindFirstChild(cursor.Name)
        if not wrapped and cursor:IsA('Model') then
            for _, child in ipairs(cursor:GetChildren()) do
                if child:IsA('Model') and string.lower(child.Name) == string.lower(cursor.Name) then
                    wrapped = child
                    break
                end
            end
        end
        if not wrapped then
            break
        end

        local nested = wrapped:FindFirstChild(childName)
        if nested then
            return nested
        end
        cursor = wrapped
    end

    -- Fallback to direct child only if no nested-wrapper match exists.
    return root:FindFirstChild(childName)
end

local function findMapNodeThroughWrappers(mapRoot: Instance, slashPath: string): Instance?
    local current: Instance? = mapRoot
    for segment in string.gmatch(slashPath, '[^/]+') do
        if not current then
            return nil
        end
        local nextNode = findThroughSameNameWrappers(current, segment)
        if not nextNode then
            return nil
        end
        current = nextNode
    end
    return current
end

function RoundService.new(gameConfig, net, enemyService)
    return setmetatable({
        _config = gameConfig,
        _net = net,
        _enemyService = enemyService,
        _towerPlacementService = nil,
        _queueService = nil,
        _difficultyVoteRemoteConnection = nil,
        _voteRestartRemoteConnection = nil,
        _requestBuckets = {},
        _nextCorrelationOrdinal = 0,
        _activeRoster = {},
        _activeDifficulty = 'Normal',
        _activeDifficultyPresetName = 'Normal',
        _activeDifficultyPreset = {},
        _restartVotesByUserId = {},
        _restartVotePassed = false,
        _restartCarryRoster = {},
        _difficultyVoteWindowActive = false,
        _difficultyVoteWindowLocked = false,
        _difficultyVoteTimeRemaining = nil,
        _difficultyVotesByUserId = {},
        _difficultyVoteTotals = {},
        _roundNumber = 0,
        _enemyTargetCount = 0,
        _enemySpawnedCount = 0,
        _enemyResolvedCount = 0,
        _enemyLeakedCount = 0,
        _enemyKilledCount = 0,
        _running = false,
        _phase = 'Idle',
        _phaseTimeRemaining = nil,
        _runId = 0,
        _baseHealth = 0,
        _roundOutcome = nil,
        _roundEndReason = nil,
        _roundEndTriggered = false,
        _waveStartedAt = nil,
        _peakActiveEnemyCount = 0,
        _leaksByPhase = {},
        _runtimeInvariantBreaches = 0,
        _lastInvariantWarningAt = 0,
        _lastInvariantWarningSignature = nil,
        _activeRoundModifierName = 'NoModifier',
        _activeRoundModifier = nil,
        _activeMutatorName = 'NoModifier',
        _activeMutatorThreatHint = 'Standard wave pacing.',
        _eliteExpectedCount = 0,
        _eliteSpawnedCount = 0,
        _activeMissionSnapshot = {},
        _activeMissionCompletedCount = 0,
        _activeMissionTotalCount = 0,
        _activeMapName = tostring(gameConfig.ACTIVE_MAP_NAME or gameConfig.DEFAULT_STAGE_ID or 'brown'),
        _activeActId = tostring(gameConfig.DEFAULT_ACT_ID or 'Act1'),
        _sessionStartedAt = nil,
        _telemetry = {
            maxWaveReached = 0,
            roundsEnded = 0,
            outcomes = {},
            endReasons = {},
            releaseGate = {
                roundsChecked = 0,
                overallPasses = 0,
                cleanupPasses = 0,
                countersCoherentPasses = 0,
                failuresByReason = {},
            },
        },
    }, RoundService)
end

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
        service = 'RoundService',
        kind = kind,
        payload = payload,
    }
end

function RoundService:_sanitizeCorrelationId(value): string?
    if type(value) ~= 'string' then
        return nil
    end
    local trimmed = string.gsub(value, '^%s*(.-)%s*$', '%1')
    if trimmed == '' or #trimmed > 64 then
        return nil
    end
    if not string.match(trimmed, '^[%w%-_]+$') then
        return nil
    end
    return trimmed
end

function RoundService:_nextCorrelationId(requestType: string, userId: number): string
    self._nextCorrelationOrdinal += 1
    return ('r-%d-%s-%d'):format(userId, tostring(requestType or 'request'), self._nextCorrelationOrdinal)
end

function RoundService:_resolveRequestCorrelationId(player: Player, requestType: string, payload): string
    if type(payload) == 'table' then
        local fromRequestId = self:_sanitizeCorrelationId(payload.requestId)
        if fromRequestId then
            return fromRequestId
        end
        local explicit = self:_sanitizeCorrelationId(payload.correlationId)
        if explicit then
            return explicit
        end
    end
    return self:_nextCorrelationId(requestType, player.UserId)
end

function RoundService:_emitDifficultyVoteTelemetry(payload)
    print(('[Telemetry][DifficultyVote] %s'):format(jsonEncode(toTelemetryEnvelope('DifficultyVote', payload))))
end

function RoundService:_emitDifficultyPresetTelemetry(payload)
    print(('[Telemetry][DifficultyPreset] %s'):format(jsonEncode(toTelemetryEnvelope('DifficultyPreset', payload))))
end

function RoundService:_shouldBroadcastDifficultySystemMessages(): boolean
    return self._config.DIFFICULTY_SYSTEM_MESSAGES_ENABLED == true
end

function RoundService:_broadcastDifficultySystemMessage(message: string)
    if not self:_shouldBroadcastDifficultySystemMessages() then
        return
    end
    self:_broadcastSystemMessage(message)
end

function RoundService:_getDifficultyVoteOptions()
    local configOptions = self._config.DIFFICULTY_VOTE_OPTIONS
    local options = {}
    if type(configOptions) == 'table' then
        for difficultyName, optionConfig in pairs(configOptions) do
            if type(difficultyName) == 'string' and difficultyName ~= '' and type(optionConfig) == 'table' then
                options[difficultyName] = true
            end
        end
    end

    if next(options) == nil then
        options.Normal = true
        options.Hard = true
        options.Challenge = true
    end

    return options
end

function RoundService:_getDefaultDifficulty(): string
    local configured = self._config.DEFAULT_DIFFICULTY
    if type(configured) == 'string' and configured ~= '' then
        return configured
    end
    return 'Normal'
end

function RoundService:_getDifficultyTieBreakOrder()
    local order = {}
    local configured = self._config.DIFFICULTY_VOTE_TIE_BREAK_ORDER
    if type(configured) == 'table' then
        for _, difficultyName in ipairs(configured) do
            if type(difficultyName) == 'string' and difficultyName ~= '' then
                table.insert(order, difficultyName)
            end
        end
    end

    if #order == 0 then
        order = { 'Normal', 'Hard', 'Challenge' }
    end
    return order
end

function RoundService:_getDifficultyPresets()
    local presets = self._config.DIFFICULTY_PRESETS
    if type(presets) == 'table' then
        return presets
    end
    return {}
end

function RoundService:_resolveDifficultyPreset(difficultyName: string): (string, table)
    local presets = self:_getDifficultyPresets()
    local selectedName = difficultyName
    local selectedPreset = presets[selectedName]
    if type(selectedPreset) ~= 'table' then
        selectedName = self:_getDefaultDifficulty()
        selectedPreset = presets[selectedName]
    end
    if type(selectedPreset) ~= 'table' then
        selectedName = 'Normal'
        selectedPreset = presets[selectedName]
    end
    if type(selectedPreset) ~= 'table' then
        selectedPreset = {}
    end

    local normalized = {
        enemyCountMultiplier = tonumber(selectedPreset.enemyCountMultiplier) or 1,
        spawnIntervalMultiplier = tonumber(selectedPreset.spawnIntervalMultiplier) or 1,
        enemyHealthMultiplier = tonumber(selectedPreset.enemyHealthMultiplier) or 1,
        enemyMoveSpeedMultiplier = tonumber(selectedPreset.enemyMoveSpeedMultiplier) or 1,
        roundDurationMultiplier = tonumber(selectedPreset.roundDurationMultiplier) or 1,
        killRewardMultiplier = tonumber(selectedPreset.killRewardMultiplier) or 1,
        roundRewardMultiplier = tonumber(selectedPreset.roundRewardMultiplier) or 1,
        towerCostMultiplier = tonumber(selectedPreset.towerCostMultiplier) or 1,
        upgradeCostMultiplier = tonumber(selectedPreset.upgradeCostMultiplier) or 1,
        sellRefundMultiplier = tonumber(selectedPreset.sellRefundMultiplier) or 1,
        announceText = tostring(selectedPreset.announceText or selectedName),
    }

    for key, value in pairs(normalized) do
        if type(value) == 'number' and value < 0.1 then
            normalized[key] = 0.1
        end
    end
    if normalized.sellRefundMultiplier < 0 then
        normalized.sellRefundMultiplier = 0
    end

    return selectedName, normalized
end

function RoundService:_applyDifficultyPreset(difficultyName: string, forceTelemetry: boolean?)
    local selectedName, selectedPreset = self:_resolveDifficultyPreset(difficultyName)
    local changed = (self._activeDifficultyPresetName ~= selectedName)
        or (self._activeDifficulty ~= selectedName)
        or (self._activeDifficultyPreset.announceText ~= selectedPreset.announceText)

    self._activeDifficulty = selectedName
    self._activeDifficultyPresetName = selectedName
    self._activeDifficultyPreset = selectedPreset

    if
        self._towerPlacementService
        and type(self._towerPlacementService.setDifficultyEconomyMultipliers) == 'function'
    then
        self._towerPlacementService:setDifficultyEconomyMultipliers(
            self._activeDifficulty,
            self._activeDifficultyPresetName,
            {
                killRewardMultiplier = selectedPreset.killRewardMultiplier,
                roundRewardMultiplier = selectedPreset.roundRewardMultiplier,
                towerCostMultiplier = selectedPreset.towerCostMultiplier,
                upgradeCostMultiplier = selectedPreset.upgradeCostMultiplier,
                sellRefundMultiplier = selectedPreset.sellRefundMultiplier,
            }
        )
    end

    if changed or forceTelemetry == true then
        self:_emitDifficultyPresetTelemetry({
            event = 'APPLIED',
            activeDifficulty = self._activeDifficulty,
            presetName = self._activeDifficultyPresetName,
            preset = self._activeDifficultyPreset,
        })
    end
end

function RoundService:_checkAndConsumeRateLimit(player: Player, requestType: string): (boolean, string?)
    local limitsTable = self._config.REQUEST_RATE_LIMITS
    if type(limitsTable) ~= 'table' then
        return true, nil
    end

    local limitConfig = limitsTable[requestType]
    if type(limitConfig) ~= 'table' then
        return true, nil
    end

    local maxRequests = tonumber(limitConfig.maxRequests)
    local perSeconds = tonumber(limitConfig.perSeconds)
    if not maxRequests or not perSeconds or maxRequests <= 0 or perSeconds <= 0 then
        return true, nil
    end

    local userBuckets = self._requestBuckets[player.UserId]
    if not userBuckets then
        userBuckets = {}
        self._requestBuckets[player.UserId] = userBuckets
    end

    local now = os.clock()
    local bucket = userBuckets[requestType]
    if not bucket then
        bucket = {
            windowStart = now,
            count = 0,
        }
        userBuckets[requestType] = bucket
    end

    local elapsed = now - bucket.windowStart
    if elapsed >= perSeconds then
        bucket.windowStart = now
        bucket.count = 0
    end

    if bucket.count >= maxRequests then
        local retryAfter = math.max(0, perSeconds - (now - bucket.windowStart))
        return false, ('Rate limit exceeded. Retry in %.2fs.'):format(retryAfter)
    end

    bucket.count += 1
    return true, nil
end

function RoundService:_clearDifficultyVoteState()
    self._difficultyVoteWindowActive = false
    self._difficultyVoteWindowLocked = false
    self._difficultyVoteTimeRemaining = nil
    table.clear(self._difficultyVotesByUserId)
    table.clear(self._difficultyVoteTotals)
end

function RoundService:_clearRestartVoteState()
    table.clear(self._restartVotesByUserId)
    self._restartVotePassed = false
end

function RoundService:_pruneActiveRosterAndVotes(): number
    local liveRoster = {}
    local liveUserIdSet = {}
    for _, rosterPlayer in ipairs(self._activeRoster) do
        if rosterPlayer and rosterPlayer.Parent and not liveUserIdSet[rosterPlayer.UserId] then
            liveUserIdSet[rosterPlayer.UserId] = true
            table.insert(liveRoster, rosterPlayer)
        end
    end
    self._activeRoster = liveRoster

    for userId in pairs(self._restartVotesByUserId) do
        if not liveUserIdSet[userId] then
            self._restartVotesByUserId[userId] = nil
        end
    end

    local rebuiltDifficultyTotals = {}
    for userId, difficultyName in pairs(self._difficultyVotesByUserId) do
        if not liveUserIdSet[userId] or type(difficultyName) ~= 'string' or difficultyName == '' then
            self._difficultyVotesByUserId[userId] = nil
        else
            rebuiltDifficultyTotals[difficultyName] = (rebuiltDifficultyTotals[difficultyName] or 0) + 1
        end
    end
    table.clear(self._difficultyVoteTotals)
    for difficultyName, count in pairs(rebuiltDifficultyTotals) do
        self._difficultyVoteTotals[difficultyName] = count
    end

    return #self._activeRoster
end

function RoundService:_getLiveActiveRosterSize(): number
    return self:_pruneActiveRosterAndVotes()
end

function RoundService:_getRestartVoteCount(): number
    self:_pruneActiveRosterAndVotes()
    local voteCount = 0
    for _, rosterPlayer in ipairs(self._activeRoster) do
        if rosterPlayer and rosterPlayer.Parent and self._restartVotesByUserId[rosterPlayer.UserId] == true then
            voteCount += 1
        end
    end
    return voteCount
end

function RoundService:_getRestartVoteThreshold(): number
    local rosterSize = self:_getLiveActiveRosterSize()
    if rosterSize <= 0 then
        return 0
    end
    return math.max(1, math.ceil(rosterSize * 0.5))
end

function RoundService:_resolveDifficultyVoteWinner(allowedOptions): string
    local bestDifficulty = self:_getDefaultDifficulty()
    local bestVotes = -1
    local tieBreakOrder = self:_getDifficultyTieBreakOrder()

    for _, difficultyName in ipairs(tieBreakOrder) do
        if allowedOptions[difficultyName] then
            local votes = self._difficultyVoteTotals[difficultyName] or 0
            if votes > bestVotes then
                bestVotes = votes
                bestDifficulty = difficultyName
            end
        end
    end

    if bestVotes <= 0 then
        local defaultDifficulty = self:_getDefaultDifficulty()
        if allowedOptions[defaultDifficulty] then
            bestDifficulty = defaultDifficulty
        end
    end
    return bestDifficulty
end

function RoundService:_handleRequestVoteDifficulty(player: Player, payload)
    local requestType = self._net.ClientToServer.RequestVoteDifficulty
    local correlationId = self:_resolveRequestCorrelationId(player, requestType, payload)
    local allowedRate, rateLimitMessage = self:_checkAndConsumeRateLimit(player, requestType)
    if not allowedRate then
        self:_emitDifficultyVoteTelemetry({
            event = 'REJECTED',
            userId = player.UserId,
            reason = 'RATE_LIMITED',
            correlationId = correlationId,
        })
        self:_broadcastDifficultySystemMessage(
            ('[Vote] %s: %s'):format(player.Name, rateLimitMessage or 'Rate limited.')
        )
        return
    end

    if self._phase ~= 'Lobby' then
        self:_emitDifficultyVoteTelemetry({
            event = 'REJECTED',
            userId = player.UserId,
            reason = 'NOT_LOBBY',
            phase = self._phase,
            correlationId = correlationId,
        })
        self:_broadcastDifficultySystemMessage(('[Vote] %s vote rejected: lobby only.'):format(player.Name))
        return
    end

    if not self._difficultyVoteWindowActive or self._difficultyVoteWindowLocked then
        self:_emitDifficultyVoteTelemetry({
            event = 'REJECTED',
            userId = player.UserId,
            reason = 'WINDOW_CLOSED',
            voteWindowActive = self._difficultyVoteWindowActive,
            voteWindowLocked = self._difficultyVoteWindowLocked,
            correlationId = correlationId,
        })
        self:_broadcastDifficultySystemMessage(('[Vote] %s vote rejected: vote window is closed.'):format(player.Name))
        return
    end

    if not self:isPlayerInActiveRoster(player) then
        self:_emitDifficultyVoteTelemetry({
            event = 'REJECTED',
            userId = player.UserId,
            reason = 'NOT_IN_ROSTER',
            correlationId = correlationId,
        })
        self:_broadcastDifficultySystemMessage(('[Vote] %s vote rejected: not in locked roster.'):format(player.Name))
        return
    end

    if type(payload) ~= 'table' then
        self:_emitDifficultyVoteTelemetry({
            event = 'REJECTED',
            userId = player.UserId,
            reason = 'INVALID_PAYLOAD',
            correlationId = correlationId,
        })
        self:_broadcastDifficultySystemMessage(('[Vote] %s vote rejected: invalid payload.'):format(player.Name))
        return
    end

    local requestedDifficulty = payload.difficulty
    if type(requestedDifficulty) ~= 'string' or requestedDifficulty == '' then
        self:_emitDifficultyVoteTelemetry({
            event = 'REJECTED',
            userId = player.UserId,
            reason = 'MISSING_DIFFICULTY',
            correlationId = correlationId,
        })
        self:_broadcastDifficultySystemMessage(('[Vote] %s vote rejected: missing difficulty.'):format(player.Name))
        return
    end

    local allowedOptions = self:_getDifficultyVoteOptions()
    if not allowedOptions[requestedDifficulty] then
        self:_emitDifficultyVoteTelemetry({
            event = 'REJECTED',
            userId = player.UserId,
            reason = 'UNSUPPORTED_DIFFICULTY',
            difficulty = requestedDifficulty,
            correlationId = correlationId,
        })
        self:_broadcastDifficultySystemMessage(
            ('[Vote] %s vote rejected: unsupported difficulty "%s".'):format(player.Name, tostring(requestedDifficulty))
        )
        return
    end

    local priorVote = self._difficultyVotesByUserId[player.UserId]
    if type(priorVote) == 'string' and priorVote ~= '' then
        local priorCount = self._difficultyVoteTotals[priorVote] or 0
        self._difficultyVoteTotals[priorVote] = math.max(0, priorCount - 1)
    end

    self._difficultyVotesByUserId[player.UserId] = requestedDifficulty
    self._difficultyVoteTotals[requestedDifficulty] = (self._difficultyVoteTotals[requestedDifficulty] or 0) + 1
    self:_emitDifficultyVoteTelemetry({
        event = 'CAST',
        userId = player.UserId,
        difficulty = requestedDifficulty,
        totals = self._difficultyVoteTotals,
        correlationId = correlationId,
    })

    self:_broadcastDifficultySystemMessage(('[Vote] %s voted %s.'):format(player.Name, requestedDifficulty))
end

function RoundService:_handleRequestVoteRestart(player: Player, payload)
    local requestType = self._net.ClientToServer.RequestVoteRestart
    local correlationId = self:_resolveRequestCorrelationId(player, requestType, payload)
    local allowedRate, rateLimitMessage = self:_checkAndConsumeRateLimit(player, requestType)
    if not allowedRate then
        self:_emitDifficultyVoteTelemetry({
            event = 'RESTART_REJECTED',
            userId = player.UserId,
            reason = 'RATE_LIMITED',
            correlationId = correlationId,
        })
        self:_broadcastSystemMessage(('[RestartVote] %s: %s'):format(player.Name, rateLimitMessage or 'Rate limited.'))
        return
    end

    if self._phase ~= 'Results' or self._restartVotePassed then
        self:_emitDifficultyVoteTelemetry({
            event = 'RESTART_REJECTED',
            userId = player.UserId,
            reason = 'WINDOW_CLOSED',
            phase = self._phase,
            alreadyPassed = self._restartVotePassed,
            correlationId = correlationId,
        })
        return
    end
    if not self:isPlayerInActiveRoster(player) then
        self:_emitDifficultyVoteTelemetry({
            event = 'RESTART_REJECTED',
            userId = player.UserId,
            reason = 'NOT_IN_ROSTER',
            correlationId = correlationId,
        })
        return
    end

    local voteState = true
    if type(payload) == 'table' and payload.vote ~= nil then
        voteState = payload.vote == true
    end
    self._restartVotesByUserId[player.UserId] = voteState

    local voteCount = self:_getRestartVoteCount()
    local threshold = self:_getRestartVoteThreshold()
    self:_broadcastSystemMessage(
        ('Restart vote %s by %s (%d/%d).'):format(voteState and 'YES' or 'NO', player.Name, voteCount, threshold)
    )
    self:_emitDifficultyVoteTelemetry({
        event = 'RESTART_CAST',
        userId = player.UserId,
        vote = voteState,
        yesCount = voteCount,
        threshold = threshold,
        correlationId = correlationId,
    })

    if voteCount >= threshold then
        self._restartVotePassed = true
        self:_broadcastSystemMessage('Restart vote passed. Requeueing current roster.')
        self:_emitDifficultyVoteTelemetry({
            event = 'RESTART_LOCKED',
            passed = true,
            yesCount = voteCount,
            threshold = threshold,
            correlationId = correlationId,
        })
    end
end

function RoundService:_bindVoteDifficultyRemote()
    local remoteName = self._net.ClientToServer.RequestVoteDifficulty
    local remote = self:_getRemoteEvent(remoteName)
    if not remote then
        warn(('[RoundService] Missing remote: %s'):format(remoteName))
        return
    end

    self._difficultyVoteRemoteConnection = remote.OnServerEvent:Connect(function(player, payload)
        if not self._running then
            return
        end
        self:_handleRequestVoteDifficulty(player, payload)
    end)
end

function RoundService:_bindVoteRestartRemote()
    local remoteName = self._net.ClientToServer.RequestVoteRestart
    local remote = self:_getRemoteEvent(remoteName)
    if not remote then
        warn(('[RoundService] Missing remote: %s'):format(remoteName))
        return
    end

    self._voteRestartRemoteConnection = remote.OnServerEvent:Connect(function(player, payload)
        if not self._running then
            return
        end
        self:_handleRequestVoteRestart(player, payload)
    end)
end

function RoundService:_runDifficultyVoteWindow(runId: number)
    local allowedOptions = self:_getDifficultyVoteOptions()
    local windowSeconds = tonumber(self._config.DIFFICULTY_VOTE_WINDOW_SECONDS) or 8
    if windowSeconds < 1 then
        windowSeconds = 1
    end
    windowSeconds = math.floor(windowSeconds)

    self:_clearDifficultyVoteState()
    self._difficultyVoteWindowActive = true
    self._difficultyVoteWindowLocked = false
    self._difficultyVoteTimeRemaining = windowSeconds
    self:_emitDifficultyVoteTelemetry({
        event = 'OPEN',
        durationSeconds = windowSeconds,
        rosterSize = self:_getLiveActiveRosterSize(),
    })
    self:_broadcastDifficultySystemMessage(
        ('Difficulty vote open (%ds). Options: Normal / Hard / Challenge.'):format(windowSeconds)
    )

    for remaining = windowSeconds, 0, -1 do
        if not self._running or self._runId ~= runId or self._phase ~= 'Lobby' then
            self:_emitDifficultyVoteTelemetry({
                event = 'ABORTED',
                reason = 'LOOP_INTERRUPTED',
                running = self._running,
                runIdMatches = self._runId == runId,
                phase = self._phase,
            })
            self:_clearDifficultyVoteState()
            return
        end
        self._difficultyVoteTimeRemaining = remaining
        local activeRosterSize = self:_getLiveActiveRosterSize()
        local votedCount = 0
        for _, rosterPlayer in ipairs(self._activeRoster) do
            if rosterPlayer and rosterPlayer.Parent and self._difficultyVotesByUserId[rosterPlayer.UserId] then
                votedCount += 1
            end
        end
        if activeRosterSize > 0 and votedCount >= activeRosterSize then
            break
        end
        if remaining > 0 then
            task.wait(1)
        end
    end

    self._difficultyVoteWindowLocked = true
    self._difficultyVoteWindowActive = false
    self._difficultyVoteTimeRemaining = 0
    self._activeDifficulty = self:_resolveDifficultyVoteWinner(allowedOptions)
    self:_emitDifficultyVoteTelemetry({
        event = 'LOCKED',
        selectedDifficulty = self._activeDifficulty,
        totals = self._difficultyVoteTotals,
    })
    self:_broadcastDifficultySystemMessage(('Difficulty vote locked: %s selected.'):format(self._activeDifficulty))
end

function RoundService:_resolveRoundModifier(roundNumber: number): (string, table)
    local modifiers = self._config.ROUND_MUTATORS
    if type(modifiers) ~= 'table' then
        modifiers = self._config.ROUND_MODIFIERS
    end
    local fallback = {
        enemyCountMultiplier = 1.0,
        spawnIntervalMultiplier = 1.0,
        enemyHealthMultiplier = 1.0,
        enemyMoveSpeedMultiplier = 1.0,
        announceText = 'No modifier',
        threatHint = 'Standard wave pacing.',
    }
    if type(modifiers) ~= 'table' then
        return 'NoModifier', fallback
    end

    local rotation = self._config.ROUND_MUTATOR_ROTATION
    if type(rotation) ~= 'table' or #rotation == 0 then
        rotation = self._config.ROUND_MODIFIER_ROTATION
    end
    local selectedName = 'NoModifier'
    if type(rotation) == 'table' and #rotation > 0 then
        local index = ((math.max(1, roundNumber) - 1) % #rotation) + 1
        local candidate = rotation[index]
        if type(candidate) == 'string' and candidate ~= '' then
            selectedName = candidate
        end
    end

    local selectedConfig = modifiers[selectedName]
    if type(selectedConfig) ~= 'table' then
        selectedName = 'NoModifier'
        selectedConfig = modifiers[selectedName]
    end
    if type(selectedConfig) ~= 'table' then
        selectedConfig = fallback
    end

    local normalized = {
        enemyCountMultiplier = tonumber(selectedConfig.enemyCountMultiplier) or 1.0,
        spawnIntervalMultiplier = tonumber(selectedConfig.spawnIntervalMultiplier) or 1.0,
        enemyHealthMultiplier = tonumber(selectedConfig.enemyHealthMultiplier) or 1.0,
        enemyMoveSpeedMultiplier = tonumber(selectedConfig.enemyMoveSpeedMultiplier) or 1.0,
        announceText = tostring(selectedConfig.announceText or selectedName),
        threatHint = tostring(selectedConfig.threatHint or ''),
    }
    if normalized.enemyCountMultiplier < 0.1 then
        normalized.enemyCountMultiplier = 0.1
    end
    if normalized.spawnIntervalMultiplier < 0.1 then
        normalized.spawnIntervalMultiplier = 0.1
    end
    if normalized.enemyHealthMultiplier < 0.1 then
        normalized.enemyHealthMultiplier = 0.1
    end
    if normalized.enemyMoveSpeedMultiplier < 0.1 then
        normalized.enemyMoveSpeedMultiplier = 0.1
    end

    return selectedName, normalized
end

function RoundService:setActiveStageSelection(selection)
    if type(selection) == 'table' then
        local stageId = selection.stageId
        local actId = selection.actId
        if type(stageId) == 'string' and stageId ~= '' then
            self._activeMapName = stageId
        end
        if type(actId) == 'string' and actId ~= '' then
            self._activeActId = actId
        end
        self:_broadcastSystemMessage(
            ('[Stage] Active selection -> stageId=%s actId=%s'):format(
                tostring(self._activeMapName),
                tostring(self._activeActId)
            )
        )
        return
    end
    self._activeMapName = tostring(self._config.ACTIVE_MAP_NAME or self._config.DEFAULT_STAGE_ID or 'brown')
    self._activeActId = tostring(self._config.DEFAULT_ACT_ID or 'Act1')
    self:_broadcastSystemMessage(
        ('[Stage] Default selection -> stageId=%s actId=%s'):format(
            tostring(self._activeMapName),
            tostring(self._activeActId)
        )
    )
end

function RoundService:_getActiveMapFolder(): Instance?
    return Workspace:FindFirstChild(self._activeMapName)
end

function RoundService:_getMapSpawn(): BasePart?
    local map = self:_getActiveMapFolder()
    if not map then
        return nil
    end

    local spawn = findMapNodeThroughWrappers(map, 'spawn1')
    if spawn and spawn:IsA('BasePart') then
        return spawn
    end

    return nil
end

function RoundService:_getLobbySpawn(): BasePart?
    local lobby = Workspace:FindFirstChild('lobby')
    if not lobby then
        return nil
    end

    local spawn = findThroughSameNameWrappers(lobby, 'SpawnLocation')
    if spawn and spawn:IsA('BasePart') then
        return spawn
    end

    return nil
end

function RoundService:_configureSpawnPolicyForPhase(phase: string)
    local mapSpawn = self:_getMapSpawn()
    local lobbySpawn = self:_getLobbySpawn()

    local mapSpawnEnabled = phase == 'Wave'
    local lobbySpawnEnabled = phase ~= 'Wave'

    if mapSpawn and mapSpawn:IsA('SpawnLocation') then
        mapSpawn.Enabled = mapSpawnEnabled
        mapSpawn.Neutral = true
    end

    if lobbySpawn and lobbySpawn:IsA('SpawnLocation') then
        lobbySpawn.Enabled = lobbySpawnEnabled
        lobbySpawn.Neutral = true
    end
end

function RoundService:_tryTeleportPlayerToCFrame(player: Player, targetCFrame: CFrame, runId: number): boolean
    local maxAttempts = tonumber(self._config.QUEUE_TELEPORT_ATTEMPTS) or 10
    local retryDelay = tonumber(self._config.QUEUE_TELEPORT_RETRY_SECONDS) or 0.2
    if maxAttempts < 1 then
        maxAttempts = 1
    end
    if retryDelay < 0.05 then
        retryDelay = 0.05
    end

    for attempt = 1, maxAttempts do
        if not self._running or self._runId ~= runId then
            return false
        end

        local character = player.Character
        if character then
            local root = character:FindFirstChild('HumanoidRootPart')
            if root and root:IsA('BasePart') then
                root.CFrame = targetCFrame
                return true
            end
        end

        if attempt < maxAttempts then
            task.wait(retryDelay)
        end
    end

    return false
end

function RoundService:_teleportRosterToSpawn(
    roster: { Player },
    spawnPart: BasePart?,
    runId: number,
    missingSpawnMessage: string,
    successMessageTemplate: string
)
    if not spawnPart then
        self:_broadcastSystemMessage(missingSpawnMessage)
        return
    end

    local offsetStep = 4
    local teleported = 0
    for index, player in ipairs(roster) do
        if player and player.Parent then
            local laneOffset = Vector3.new((index - 1) * offsetStep, 3, 0)
            local targetCFrame = spawnPart.CFrame + laneOffset
            local ok = self:_tryTeleportPlayerToCFrame(player, targetCFrame, runId)
            if ok then
                teleported += 1
            end
        end
    end

    if teleported > 0 then
        self:_broadcastSystemMessage((successMessageTemplate):format(teleported))
    else
        self:_broadcastSystemMessage('No players were teleported.')
    end
end

function RoundService:_teleportActiveRosterToMapSpawn(runId: number)
    local mapSpawn = self:_getMapSpawn()
    self:_teleportRosterToSpawn(
        self._activeRoster,
        mapSpawn,
        runId,
        ('Match start failed: missing %s/spawn1.'):format(tostring(self._activeMapName)),
        ('Match started. Teleported %%d player(s) to %s.'):format(tostring(self._activeMapName))
    )
end

function RoundService:_teleportActiveRosterToLobbySpawn(runId: number)
    local lobbySpawn = self:_getLobbySpawn()
    self:_teleportRosterToSpawn(
        self._activeRoster,
        lobbySpawn,
        runId,
        'Return to lobby failed: missing lobby/SpawnLocation.',
        'Returned %d player(s) to lobby.'
    )
end

function RoundService:_teleportAllPlayersToLobbySpawn(runId: number)
    local lobbySpawn = self:_getLobbySpawn()
    local allPlayers = game:GetService('Players'):GetPlayers()
    self:_teleportRosterToSpawn(
        allPlayers,
        lobbySpawn,
        runId,
        'Lobby spawn missing: lobby/SpawnLocation.',
        'Lobby sync: teleported %d player(s) to lobby.'
    )
end

function RoundService:_getBaseCore(): Instance?
    local map = self:_getActiveMapFolder()
    if not map then
        return nil
    end

    return findMapNodeThroughWrappers(map, 'Base/Core')
end

function RoundService:_initializeBaseHealth()
    self._baseHealth = self._config.BASE_MAX_HEALTH or 100
    local baseCore = self:_getBaseCore()
    if not baseCore then
        return
    end

    baseCore:SetAttribute('Health', self._baseHealth)

    local healthValue = baseCore:FindFirstChild('Health')
    if healthValue and healthValue:IsA('NumberValue') then
        healthValue.Value = self._baseHealth
    end
end

function RoundService:_applyLeakDamage(enemyId: number)
    local damage = self._config.BASE_LEAK_DAMAGE or 10
    self._baseHealth = math.max(0, self._baseHealth - damage)
    self._enemyLeakedCount += 1
    self._enemyResolvedCount = math.min(self._enemyTargetCount, self._enemyResolvedCount + 1)
    self:_refreshMissionSnapshot(self._roundOutcome or '')
    local phaseKey = tostring(self._phase or 'Unknown')
    self._leaksByPhase[phaseKey] = (self._leaksByPhase[phaseKey] or 0) + 1

    local baseCore = self:_getBaseCore()
    if baseCore then
        baseCore:SetAttribute('Health', self._baseHealth)

        local healthValue = baseCore:FindFirstChild('Health')
        if healthValue and healthValue:IsA('NumberValue') then
            healthValue.Value = self._baseHealth
        end
    end

    self:_broadcastRoundStatus(self:_withEnemyProgress({
        phase = self._phase,
        wave = 1,
        timeRemaining = self._phaseTimeRemaining,
        baseHealth = self._baseHealth,
        lastLeakEnemyId = enemyId,
        outcome = self._roundOutcome,
        activeEnemyCount = self._enemyService:getActiveEnemyCount(),
    }))

    if self._phase == 'Wave' and self._baseHealth <= 0 then
        self:_triggerRoundEnd('Defeat', 'BASE_DESTROYED')
    end
end

function RoundService:_getRemoteEvent(remoteName: string): RemoteEvent?
    local remotesFolder = ReplicatedStorage:FindFirstChild('Remotes')
    if not remotesFolder then
        return nil
    end

    local remote = remotesFolder:FindFirstChild(remoteName)
    if remote and remote:IsA('RemoteEvent') then
        return remote
    end

    return nil
end

function RoundService:_broadcastRoundStatus(payload)
    local remoteName = self._net.ServerToClient.RoundStatus
    local roundStatusRemote = self:_getRemoteEvent(remoteName)
    if not roundStatusRemote then
        return
    end

    roundStatusRemote:FireAllClients(payload)
end

function RoundService:_broadcastSystemMessage(message: string)
    local remoteName = self._net.ServerToClient.SystemMessage
    local systemMessageRemote = self:_getRemoteEvent(remoteName)
    if not systemMessageRemote then
        return
    end

    systemMessageRemote:FireAllClients({
        text = message,
    })
end

function RoundService:_getEnemiesPerMatch(roundNumber: number?): number
    local target = tonumber(self._config.ENEMIES_PER_MATCH)
    if not target then
        target = tonumber(self._config.ENEMY_PER_WAVE) or 1
    end
    local effectiveRoundNumber = math.max(1, math.floor(tonumber(roundNumber) or 1))
    local perRound = tonumber(self._config.ENEMIES_PER_MATCH_PER_ROUND) or 0
    local maxPerMatch = tonumber(self._config.ENEMIES_PER_MATCH_MAX)
    target = math.floor(target + ((effectiveRoundNumber - 1) * perRound))
    if maxPerMatch then
        maxPerMatch = math.max(1, math.floor(maxPerMatch))
        target = math.min(target, maxPerMatch)
    end
    target = math.max(1, target)
    return target
end

function RoundService:_getRoundDurationSeconds(roundNumber: number?): number
    local duration = tonumber(self._config.ROUND_DURATION) or 180
    local effectiveRoundNumber = math.max(1, math.floor(tonumber(roundNumber) or 1))
    local perRound = tonumber(self._config.ROUND_DURATION_PER_ROUND) or 0
    local minDuration = tonumber(self._config.ROUND_DURATION_MIN)
    duration = math.floor(duration + ((effectiveRoundNumber - 1) * perRound))
    if minDuration then
        duration = math.max(math.floor(minDuration), duration)
    end
    local difficultyDurationMultiplier = tonumber(self._activeDifficultyPreset.roundDurationMultiplier) or 1
    if difficultyDurationMultiplier < 0.1 then
        difficultyDurationMultiplier = 0.1
    end
    duration = math.floor(duration * difficultyDurationMultiplier)
    duration = math.max(10, duration)
    return duration
end

function RoundService:_getEliteWavePreview(roundNumber: number, enemyTargetCount: number)
    local eliteConfig = self._config.ENEMY_ELITE
    if type(eliteConfig) ~= 'table' then
        return {
            enabled = false,
            expectedCount = 0,
        }
    end
    if eliteConfig.enabled == false then
        return {
            enabled = false,
            expectedCount = 0,
        }
    end

    local unlockRound = tonumber(eliteConfig.unlockRound) or math.huge
    unlockRound = math.max(1, math.floor(unlockRound))
    if roundNumber < unlockRound then
        return {
            enabled = false,
            expectedCount = 0,
        }
    end

    local cadence = tonumber(eliteConfig.everySpawnOrdinal) or 0
    cadence = math.max(0, math.floor(cadence))
    if cadence <= 0 then
        return {
            enabled = false,
            expectedCount = 0,
        }
    end

    local expectedCount = math.floor(math.max(0, enemyTargetCount) / cadence)
    local eliteTag = eliteConfig.tag
    if type(eliteTag) ~= 'string' or eliteTag == '' then
        eliteTag = 'Elite'
    end
    return {
        enabled = true,
        expectedCount = expectedCount,
        cadence = cadence,
        tag = eliteTag,
    }
end

function RoundService:_getMissionDefinitions()
    local configured = self._config.MISSION_DEFINITIONS
    if type(configured) ~= 'table' then
        return {}
    end

    local normalized = {}
    for _, definition in ipairs(configured) do
        if type(definition) == 'table' then
            local missionId = definition.id
            local missionType = definition.missionType
            if
                type(missionId) == 'string'
                and missionId ~= ''
                and type(missionType) == 'string'
                and missionType ~= ''
            then
                table.insert(normalized, {
                    id = missionId,
                    missionType = missionType,
                    required = math.max(1, math.floor(tonumber(definition.required) or 1)),
                    reward = math.max(0, math.floor(tonumber(definition.reward) or 0)),
                    description = tostring(definition.description or missionId),
                })
            end
        end
    end
    return normalized
end

function RoundService:_evaluateMissionProgressForDefinition(definition, outcome: string)
    local missionType = definition.missionType
    if missionType == 'kills' then
        local progress = math.max(0, self._enemyKilledCount)
        local target = math.max(1, definition.required)
        return progress, target, progress >= target
    end
    if missionType == 'no_leak' then
        local leaked = math.max(0, self._enemyLeakedCount)
        local progress = leaked == 0 and 1 or 0
        return progress, 1, leaked == 0
    end
    if missionType == 'round_clear' then
        local progress = outcome == 'Victory' and 1 or 0
        return progress, 1, outcome == 'Victory'
    end

    return 0, math.max(1, definition.required), false
end

function RoundService:_refreshMissionSnapshot(outcome: string?)
    local snapshot = {}
    local completedCount = 0
    local definitions = self:_getMissionDefinitions()
    for _, definition in ipairs(definitions) do
        local progress, target, completed = self:_evaluateMissionProgressForDefinition(definition, outcome or '')
        if completed then
            completedCount += 1
        end
        table.insert(snapshot, {
            id = definition.id,
            missionType = definition.missionType,
            progress = progress,
            target = target,
            completed = completed,
            reward = definition.reward,
            description = definition.description,
        })
    end
    self._activeMissionSnapshot = snapshot
    self._activeMissionCompletedCount = completedCount
    self._activeMissionTotalCount = #snapshot
end

function RoundService:_withEnemyProgress(payload)
    local configuredSpeedMultiplier = tonumber(self._config.COMBAT_GAME_SPEED_MULTIPLIER) or 1
    if configuredSpeedMultiplier < 0.25 then
        configuredSpeedMultiplier = 0.25
    end
    payload.gameSpeedMultiplier = configuredSpeedMultiplier
    payload.gameSpeedLabel = ('%.1fx'):format(configuredSpeedMultiplier)
    payload.speedControlState = (self._phase == 'Wave' or self._phase == 'Results') and 'LIVE' or 'LOCKED'
    payload.roundNumber = self._roundNumber
    payload.enemyTargetCount = self._enemyTargetCount
    payload.enemySpawnedCount = self._enemySpawnedCount
    payload.enemyResolvedCount = self._enemyResolvedCount
    payload.enemyLeakedCount = self._enemyLeakedCount
    payload.enemyKilledCount = self._enemyKilledCount
    payload.enemyRemainingCount = math.max(0, self._enemyTargetCount - self._enemyResolvedCount)
    payload.eliteExpectedCount = self._eliteExpectedCount
    payload.eliteSpawnedCount = self._eliteSpawnedCount
    if payload.roundModifierName == nil then
        payload.roundModifierName = self._activeRoundModifierName
    end
    payload.roundMutatorName = self._activeMutatorName
    payload.roundMutatorThreatHint = self._activeMutatorThreatHint
    payload.missionSnapshot = self._activeMissionSnapshot
    payload.missionCompletedCount = self._activeMissionCompletedCount
    payload.missionTotalCount = self._activeMissionTotalCount
    payload.selectedDifficulty = self._activeDifficulty
    payload.activeDifficultyPreset = self._activeDifficultyPresetName
    payload.activeDifficulty = self._activeDifficulty
    payload.difficultyVoteWindowActive = self._difficultyVoteWindowActive
    payload.difficultyVoteWindowLocked = self._difficultyVoteWindowLocked
    payload.difficultyVoteTimeRemaining = self._difficultyVoteTimeRemaining
    payload.difficultyVoteTotals = self._difficultyVoteTotals
    payload.restartVoteYesCount = self:_getRestartVoteCount()
    payload.restartVoteRequiredCount = self:_getRestartVoteThreshold()
    payload.restartVotePassed = self._restartVotePassed
    payload.activeMapName = self._activeMapName
    payload.activeActId = self._activeActId
    payload.endReason = payload.endReason or self._roundEndReason
    return payload
end

function RoundService:_emitRoundBalanceSnapshot(outcome: string, reason: string, activeEnemyCountAtEnd: number)
    if self._config.DEBUG_BALANCE_SNAPSHOT == false then
        return
    end

    local target = math.max(1, self._enemyTargetCount)
    local resolved = math.max(0, self._enemyResolvedCount)
    local killed = math.max(0, self._enemyKilledCount)
    local leaked = math.max(0, self._enemyLeakedCount)
    local clearRate = math.floor(((killed / target) * 10000) + 0.5) / 100
    local leakRate = math.floor(((leaked / target) * 10000) + 0.5) / 100
    local waveDurationSeconds = 0
    if self._waveStartedAt then
        waveDurationSeconds = math.max(0, os.clock() - self._waveStartedAt)
    end
    waveDurationSeconds = math.floor((waveDurationSeconds * 100) + 0.5) / 100
    local targetSoloClearRateMinPct = tonumber(self._config.BALANCE_TARGET_SOLO_CLEAR_RATE_MIN_PCT) or 40
    local targetSoloClearRateMaxPct = tonumber(self._config.BALANCE_TARGET_SOLO_CLEAR_RATE_MAX_PCT) or 60
    targetSoloClearRateMinPct = math.max(0, math.floor(targetSoloClearRateMinPct))
    targetSoloClearRateMaxPct = math.max(targetSoloClearRateMinPct, math.floor(targetSoloClearRateMaxPct))
    local leaksByPhaseSnapshot = table.clone(self._leaksByPhase)
    local pressurePeakPct = math.floor(((math.max(0, self._peakActiveEnemyCount) / target) * 10000) + 0.5) / 100

    local snapshot = {
        outcome = outcome,
        reason = reason,
        baseHealth = self._baseHealth,
        waveDurationSeconds = waveDurationSeconds,
        enemyTargetCount = self._enemyTargetCount,
        enemySpawnedCount = self._enemySpawnedCount,
        enemyResolvedCount = resolved,
        enemyKilledCount = killed,
        enemyLeakedCount = leaked,
        enemyRemainingCount = math.max(0, self._enemyTargetCount - resolved),
        activeEnemyCountAtEnd = math.max(0, activeEnemyCountAtEnd),
        peakActiveEnemyCount = math.max(0, self._peakActiveEnemyCount),
        pressurePeakPctOfTarget = pressurePeakPct,
        leaksByPhase = leaksByPhaseSnapshot,
        clearRatePct = clearRate,
        leakRatePct = leakRate,
        eliteExpectedCount = self._eliteExpectedCount,
        eliteSpawnedCount = self._eliteSpawnedCount,
        targetSoloClearRateMinPct = targetSoloClearRateMinPct,
        targetSoloClearRateMaxPct = targetSoloClearRateMaxPct,
        roundModifierName = self._activeRoundModifierName,
        roundMutatorName = self._activeMutatorName,
        activeDifficulty = self._activeDifficulty,
        activeDifficultyPreset = self._activeDifficultyPresetName,
        missionCompletedCount = self._activeMissionCompletedCount,
        missionTotalCount = self._activeMissionTotalCount,
    }
    print(('[Balance][Round] %s'):format(jsonEncode(toTelemetryEnvelope('BalanceRound', snapshot))))
end

function RoundService:_emitReleaseGateSummary(payload)
    if self._config.DEBUG_RELEASE_GATE_SUMMARY == false then
        return
    end

    local summary = {
        roundOutcome = payload.roundOutcome,
        roundModifierName = tostring(payload.roundModifierName or self._activeRoundModifierName or 'NoModifier'),
        roundMutatorName = tostring(payload.roundMutatorName or self._activeMutatorName or 'NoModifier'),
        countersCoherent = payload.countersCoherent,
        resolvedNotExceedSpawned = payload.resolvedNotExceedSpawned,
        spawnedNotExceedTarget = payload.spawnedNotExceedTarget,
        terminalOutcomeConsistent = payload.terminalOutcomeConsistent,
        runtimeInvariantHealthy = payload.runtimeInvariantHealthy,
        towersCleared = payload.towersCleared,
        enemiesClearedAfterRestart = payload.enemiesClearedAfterRestart,
        rosterCleared = payload.rosterCleared,
        cleanupPass = payload.cleanupPass,
        overallPass = payload.overallPass,
        enemyTargetCount = self._enemyTargetCount,
        enemySpawnedCount = self._enemySpawnedCount,
        enemyResolvedCount = self._enemyResolvedCount,
        enemyKilledCount = self._enemyKilledCount,
        enemyLeakedCount = self._enemyLeakedCount,
        activeDifficulty = self._activeDifficulty,
        activeDifficultyPreset = self._activeDifficultyPresetName,
        missionCompletedCount = self._activeMissionCompletedCount,
        missionTotalCount = self._activeMissionTotalCount,
        eliteExpectedCount = self._eliteExpectedCount,
        eliteSpawnedCount = self._eliteSpawnedCount,
        towersAfterCleanup = payload.towersAfterCleanup,
        activeEnemiesAfterRestart = payload.activeEnemiesAfterRestart,
    }
    print(('[ReleaseGate][Round] %s'):format(jsonEncode(toTelemetryEnvelope('ReleaseGateRound', summary))))
end

function RoundService:_emitReleaseGateSessionSummary()
    if self._config.DEBUG_RELEASE_GATE_SUMMARY == false then
        return
    end

    local gate = self._telemetry.releaseGate
    local roundsChecked = gate.roundsChecked or 0
    local overallPasses = gate.overallPasses or 0
    local requiredRounds = tonumber(self._config.RELEASE_GATE_REQUIRED_ROUNDS) or 3
    requiredRounds = math.max(1, math.floor(requiredRounds))
    local requiredPassRatePct = tonumber(self._config.RELEASE_GATE_REQUIRED_PASS_RATE_PCT) or 100
    requiredPassRatePct = math.max(0, math.min(100, math.floor(requiredPassRatePct)))
    local passRatePct = 0
    if roundsChecked > 0 then
        passRatePct = math.floor(((overallPasses / roundsChecked) * 10000) + 0.5) / 100
    end
    local roundsRequirementMet = roundsChecked >= requiredRounds
    local passRateRequirementMet = passRatePct >= requiredPassRatePct
    local goNoGo = roundsRequirementMet and passRateRequirementMet

    local summary = {
        requiredRounds = requiredRounds,
        requiredPassRatePct = requiredPassRatePct,
        roundsChecked = roundsChecked,
        overallPasses = overallPasses,
        passRatePct = passRatePct,
        roundsRequirementMet = roundsRequirementMet,
        passRateRequirementMet = passRateRequirementMet,
        goNoGo = goNoGo,
        failuresByReason = gate.failuresByReason,
    }
    print(('[ReleaseGate][Session] %s'):format(jsonEncode(toTelemetryEnvelope('ReleaseGateSession', summary))))
end

function RoundService:_recordReleaseGateResult(payload)
    local gate = self._telemetry.releaseGate
    gate.roundsChecked += 1
    if payload.countersCoherent then
        gate.countersCoherentPasses += 1
    else
        gate.failuresByReason.COUNTER_MISMATCH = (gate.failuresByReason.COUNTER_MISMATCH or 0) + 1
    end
    if payload.cleanupPass then
        gate.cleanupPasses += 1
    else
        if not payload.towersCleared then
            gate.failuresByReason.TOWERS_NOT_CLEARED = (gate.failuresByReason.TOWERS_NOT_CLEARED or 0) + 1
        end
        if not payload.enemiesClearedAfterRestart then
            gate.failuresByReason.ENEMIES_NOT_CLEARED = (gate.failuresByReason.ENEMIES_NOT_CLEARED or 0) + 1
        end
    end
    if payload.overallPass then
        gate.overallPasses += 1
    end

    if not payload.resolvedNotExceedSpawned then
        gate.failuresByReason.RESOLVED_EXCEEDS_SPAWNED = (gate.failuresByReason.RESOLVED_EXCEEDS_SPAWNED or 0) + 1
    end
    if not payload.spawnedNotExceedTarget then
        gate.failuresByReason.SPAWNED_EXCEEDS_TARGET = (gate.failuresByReason.SPAWNED_EXCEEDS_TARGET or 0) + 1
    end
    if not payload.terminalOutcomeConsistent then
        gate.failuresByReason.TERMINAL_OUTCOME_MISMATCH = (gate.failuresByReason.TERMINAL_OUTCOME_MISMATCH or 0) + 1
    end
    if not payload.rosterCleared then
        gate.failuresByReason.ROSTER_NOT_CLEARED = (gate.failuresByReason.ROSTER_NOT_CLEARED or 0) + 1
    end
    if not payload.runtimeInvariantHealthy then
        gate.failuresByReason.RUNTIME_INVARIANT_BREACH = (gate.failuresByReason.RUNTIME_INVARIANT_BREACH or 0) + 1
    end
end

function RoundService:_checkRuntimeInvariants(contextLabel: string)
    if self._config.DEBUG_RUNTIME_INVARIANT_CHECKS == false then
        return
    end

    local violations = {}
    if self._enemyTargetCount < 0 then
        table.insert(violations, 'TARGET_NEGATIVE')
    end
    if self._enemySpawnedCount < 0 then
        table.insert(violations, 'SPAWNED_NEGATIVE')
    end
    if self._enemyResolvedCount < 0 then
        table.insert(violations, 'RESOLVED_NEGATIVE')
    end
    if self._enemyKilledCount < 0 then
        table.insert(violations, 'KILLED_NEGATIVE')
    end
    if self._enemyLeakedCount < 0 then
        table.insert(violations, 'LEAKED_NEGATIVE')
    end
    if self._enemyKilledCount + self._enemyLeakedCount > self._enemyResolvedCount then
        table.insert(violations, 'KILL_LEAK_EXCEED_RESOLVED')
    end
    if self._enemyResolvedCount > self._enemySpawnedCount then
        table.insert(violations, 'RESOLVED_EXCEED_SPAWNED')
    end
    if self._enemySpawnedCount > self._enemyTargetCount then
        table.insert(violations, 'SPAWNED_EXCEED_TARGET')
    end

    if #violations == 0 then
        return
    end

    local joined = table.concat(violations, ',')
    local nowTime = os.clock()
    local cooldownSeconds = tonumber(self._config.DEBUG_RUNTIME_INVARIANT_WARNING_COOLDOWN_SECONDS) or 5
    if cooldownSeconds < 0 then
        cooldownSeconds = 0
    end
    local signature = ('%s|%s'):format(contextLabel, joined)
    local shouldEmit = signature ~= self._lastInvariantWarningSignature
        or (nowTime - self._lastInvariantWarningAt) >= cooldownSeconds
    if not shouldEmit then
        return
    end

    -- Count distinct/cooled incidents, not every repeated tick.
    self._runtimeInvariantBreaches += 1
    self._lastInvariantWarningAt = nowTime
    self._lastInvariantWarningSignature = signature
    warn(('[RoundService][Invariant] context=%s violations=%s'):format(contextLabel, joined))
    if self._config.DEBUG_RUNTIME_INVARIANT_BROADCAST_SYSTEM_MESSAGE ~= false then
        self:_broadcastSystemMessage(('Invariant warning (%s): %s'):format(contextLabel, joined))
    end
end

function RoundService:_bindEnemyCallbacks(runId: number)
    self._enemyService:setEnemyLeakedHandler(function(enemyId)
        if not self._running or self._runId ~= runId then
            return
        end
        self:_applyLeakDamage(enemyId)
    end)

    self._enemyService:setEnemyDiedHandler(function(payload)
        if not self._running or self._runId ~= runId then
            return
        end
        self._enemyKilledCount += 1
        self._enemyResolvedCount = math.min(self._enemyTargetCount, self._enemyResolvedCount + 1)
        self:_refreshMissionSnapshot(self._roundOutcome or '')
        self:_checkRuntimeInvariants('enemy_died')

        local source = payload and payload.source
        local towerId = source and source.towerId
        local towerPlacementService = self._towerPlacementService
        if towerPlacementService and type(towerPlacementService.awardKillRewardByTowerId) == 'function' then
            if type(towerId) == 'string' and towerId ~= '' then
                towerPlacementService:awardKillRewardByTowerId(towerId, payload)
            end
        end
    end)
end

function RoundService:_triggerRoundEnd(outcome: string, reason: string)
    if self._roundEndTriggered then
        return
    end
    self._roundEndTriggered = true
    self._roundOutcome = outcome
    self._roundEndReason = reason
    -- Refresh final mission state before emitting terminal snapshots.
    self:_refreshMissionSnapshot(outcome)
    local activeEnemyCountAtEnd = self._enemyService:getActiveEnemyCount()
    self:_emitRoundBalanceSnapshot(outcome, reason, activeEnemyCountAtEnd)

    -- Freeze enemy runtime immediately on terminal outcome so no extra leaks/resolves happen in Results.
    self._enemyService:stop()
    self._enemyService:start()
    self:_bindEnemyCallbacks(self._runId)

    self._telemetry.roundsEnded += 1
    self._telemetry.outcomes[outcome] = (self._telemetry.outcomes[outcome] or 0) + 1
    self._telemetry.endReasons[reason] = (self._telemetry.endReasons[reason] or 0) + 1

    local towerPlacementService = self._towerPlacementService
    if towerPlacementService and type(towerPlacementService.awardRoundOutcomeRewardForRoster) == 'function' then
        local rewardedPlayers = towerPlacementService:awardRoundOutcomeRewardForRoster(self._activeRoster, outcome)
        local rewardsByOutcome = self._config.ROUND_REWARDS
        local rewardAmount = 0
        if type(rewardsByOutcome) == 'table' then
            rewardAmount = tonumber(rewardsByOutcome[outcome]) or 0
        end
        rewardAmount = math.max(0, math.floor(rewardAmount))
        if rewardedPlayers > 0 and rewardAmount > 0 then
            self:_broadcastSystemMessage(
                ('Round rewards paid: +%d (%s) to %d player(s).'):format(rewardAmount, outcome, rewardedPlayers)
            )
        end
    end
    if towerPlacementService and type(towerPlacementService.awardMissionRewardsForRoster) == 'function' then
        local missionSummary = towerPlacementService:awardMissionRewardsForRoster(
            self._activeRoster,
            self._roundNumber,
            self._activeMissionSnapshot
        )
        if type(missionSummary) == 'table' then
            local completedCount = tonumber(missionSummary.completedCount) or self._activeMissionCompletedCount
            local totalCount = tonumber(missionSummary.totalCount) or self._activeMissionTotalCount
            self:_broadcastSystemMessage(('Missions complete: %d/%d.'):format(completedCount, totalCount))
            local rewardedPlayers = tonumber(missionSummary.rewardedPlayers) or 0
            local totalPayout = tonumber(missionSummary.totalPayout) or 0
            if rewardedPlayers > 0 and totalPayout > 0 then
                self:_broadcastSystemMessage(
                    ('Mission rewards paid: +%d total across %d player(s).'):format(totalPayout, rewardedPlayers)
                )
            end
        end
    end

    self:_broadcastRoundStatus(self:_withEnemyProgress({
        phase = self._phase,
        wave = 1,
        timeRemaining = self._phaseTimeRemaining,
        baseHealth = self._baseHealth,
        activeEnemyCount = self._enemyService:getActiveEnemyCount(),
        outcome = outcome,
        endReason = reason,
    }))

    self:_broadcastSystemMessage(('Round ended: %s (%s)'):format(outcome, reason))
end

function RoundService:_runLobbyPhase(runId: number)
    self._phase = 'Lobby'
    self:_configureSpawnPolicyForPhase(self._phase)
    self:_teleportAllPlayersToLobbySpawn(runId)
    self._roundOutcome = nil
    self._roundEndReason = nil
    self._roundEndTriggered = false
    self._waveStartedAt = nil
    self._peakActiveEnemyCount = 0
    self._runtimeInvariantBreaches = 0
    self._lastInvariantWarningAt = 0
    self._lastInvariantWarningSignature = nil
    self._activeRoundModifierName = 'NoModifier'
    self._activeRoundModifier = nil
    self._activeMutatorName = 'NoModifier'
    self._activeMutatorThreatHint = 'Standard wave pacing.'
    self._eliteExpectedCount = 0
    self._eliteSpawnedCount = 0
    self._activeMissionSnapshot = {}
    self._activeMissionCompletedCount = 0
    self._activeMissionTotalCount = 0
    self:_clearDifficultyVoteState()
    self:_clearRestartVoteState()
    self._activeDifficulty = self:_getDefaultDifficulty()
    self:_applyDifficultyPreset(self._activeDifficulty, true)
    if type(self._enemyService.setRoundModifier) == 'function' then
        self._enemyService:setRoundModifier(nil)
    end
    table.clear(self._leaksByPhase)
    self._enemyTargetCount = self:_getEnemiesPerMatch(self._roundNumber + 1)
    self._enemySpawnedCount = 0
    self._enemyResolvedCount = 0
    self._enemyLeakedCount = 0
    self._enemyKilledCount = 0
    self:_initializeBaseHealth()

    if #self._restartCarryRoster > 0 then
        self._activeRoster = table.clone(self._restartCarryRoster)
        table.clear(self._restartCarryRoster)
        local liveRosterSize = self:_getLiveActiveRosterSize()
        self:_broadcastSystemMessage(('Restart continuity: reusing roster (%d player(s)).'):format(liveRosterSize))
        if self._config.DIFFICULTY_VOTE_ENABLED == true then
            self:_runDifficultyVoteWindow(runId)
        else
            self:_clearDifficultyVoteState()
        end
        self:_applyDifficultyPreset(self._activeDifficulty, true)
        self:_broadcastSystemMessage(
            ('Match mode: %s (%s).'):format(
                tostring(self._activeDifficulty),
                tostring(self._activeDifficultyPresetName)
            )
        )
        return
    end

    self:setActiveStageSelection(nil)

    local queueService = self._queueService
    if
        queueService
        and type(queueService.getSnapshot) == 'function'
        and type(queueService.takeLockedRoster) == 'function'
    then
        self._phaseTimeRemaining = nil
        while self._running and self._runId == runId do
            local queueSnapshot = queueService:getSnapshot()
            local queueState = queueSnapshot and queueSnapshot.state or 'Idle'
            local queueSize = queueSnapshot and queueSnapshot.size or 0
            local queueReadyCount = queueSnapshot and queueSnapshot.readyCount or 0
            local queueCountdownActive = queueSnapshot and queueSnapshot.countdownActive or false
            local queueCountdownTimeRemaining = queueSnapshot and queueSnapshot.countdownTimeRemaining or nil
            self._phaseTimeRemaining = queueCountdownTimeRemaining

            self:_broadcastRoundStatus(self:_withEnemyProgress({
                phase = self._phase,
                timeRemaining = self._phaseTimeRemaining,
                baseHealth = self._baseHealth,
                outcome = self._roundOutcome,
                activeEnemyCount = self._enemyService:getActiveEnemyCount(),
                queueState = queueState,
                queueSize = queueSize,
                queueReadyCount = queueReadyCount,
                queueCountdownActive = queueCountdownActive,
                queueCountdownTimeRemaining = queueCountdownTimeRemaining,
            }))

            if queueState == 'Locked' then
                local lockedRoster, stageSelection = queueService:takeLockedRoster()
                if #lockedRoster > 0 then
                    self:setActiveStageSelection(stageSelection)
                    self._activeRoster = lockedRoster
                    if self._config.DIFFICULTY_VOTE_ENABLED == true then
                        self:_runDifficultyVoteWindow(runId)
                    else
                        self:_clearDifficultyVoteState()
                    end
                    self:_applyDifficultyPreset(self._activeDifficulty, true)
                    self:_broadcastSystemMessage(
                        ('Match mode: %s (%s).'):format(
                            tostring(self._activeDifficulty),
                            tostring(self._activeDifficultyPresetName)
                        )
                    )
                    return
                end
            end

            task.wait(0.2)
        end
        return
    end

    local duration = self._config.LOBBY_DURATION or 15
    self._phaseTimeRemaining = duration

    for remaining = duration, 0, -1 do
        if not self._running or self._runId ~= runId then
            return
        end

        self._phaseTimeRemaining = remaining
        self:_broadcastRoundStatus(self:_withEnemyProgress({
            phase = self._phase,
            timeRemaining = remaining,
            baseHealth = self._baseHealth,
            outcome = self._roundOutcome,
            activeEnemyCount = self._enemyService:getActiveEnemyCount(),
        }))
        task.wait(1)
    end
end

function RoundService:_runWavePhase(runId: number)
    self._phase = 'Wave'
    self:_configureSpawnPolicyForPhase(self._phase)
    if type(self._enemyService.setActiveMapName) == 'function' then
        self._enemyService:setActiveMapName(self._activeMapName)
    end
    if
        self._towerPlacementService
        and type(self._towerPlacementService.setActiveMapName) == 'function'
    then
        self._towerPlacementService:setActiveMapName(self._activeMapName)
    end
    self._roundNumber += 1
    local roundModifierName, roundModifier = self:_resolveRoundModifier(self._roundNumber)
    local difficultyPreset = self._activeDifficultyPreset
    self:_applyDifficultyPreset(self._activeDifficulty)
    difficultyPreset = self._activeDifficultyPreset
    self._activeRoundModifierName = roundModifierName
    self._activeRoundModifier = roundModifier
    self._activeMutatorName = roundModifierName
    self._activeMutatorThreatHint = tostring(roundModifier.threatHint or '')
    self._roundOutcome = nil
    self._roundEndReason = nil
    self._roundEndTriggered = false
    -- Ensure callbacks are always live for this run, even after EnemyService restarts in cleanup.
    self:_bindEnemyCallbacks(runId)
    self._telemetry.maxWaveReached = math.max(self._telemetry.maxWaveReached, self._roundNumber)
    self._enemyTargetCount = self:_getEnemiesPerMatch(self._roundNumber)
    if type(roundModifier) == 'table' then
        local countMultiplier = tonumber(roundModifier.enemyCountMultiplier) or 1
        countMultiplier *= (tonumber(difficultyPreset.enemyCountMultiplier) or 1)
        if countMultiplier < 0.1 then
            countMultiplier = 0.1
        end
        self._enemyTargetCount = math.max(1, math.floor((self._enemyTargetCount * countMultiplier) + 0.5))
    end
    self._enemySpawnedCount = 0
    self._enemyResolvedCount = 0
    self._enemyLeakedCount = 0
    self._enemyKilledCount = 0
    self._eliteSpawnedCount = 0
    self:_refreshMissionSnapshot('')
    self._waveStartedAt = os.clock()
    self._peakActiveEnemyCount = 0
    if type(self._enemyService.setRoundNumber) == 'function' then
        self._enemyService:setRoundNumber(self._roundNumber)
    end
    if type(self._enemyService.setRoundModifier) == 'function' then
        self._enemyService:setRoundModifier({
            enemyHealthMultiplier = (tonumber(roundModifier.enemyHealthMultiplier) or 1)
                * (tonumber(difficultyPreset.enemyHealthMultiplier) or 1),
            enemyMoveSpeedMultiplier = (tonumber(roundModifier.enemyMoveSpeedMultiplier) or 1)
                * (tonumber(difficultyPreset.enemyMoveSpeedMultiplier) or 1),
        })
    end
    if type(roundModifier) == 'table' then
        self:_broadcastSystemMessage(
            ('Round %d started [%s/%s] (%s)'):format(
                self._roundNumber,
                tostring(self._activeDifficulty),
                tostring(self._activeDifficultyPresetName),
                tostring(roundModifier.announceText or roundModifierName)
            )
        )
        if self._activeMutatorThreatHint ~= '' then
            self:_broadcastSystemMessage(('Mutator threat: %s'):format(self._activeMutatorThreatHint))
        end
    end
    local elitePreview = self:_getEliteWavePreview(self._roundNumber, self._enemyTargetCount)
    self._eliteExpectedCount = elitePreview.expectedCount or 0
    if elitePreview.enabled and self._eliteExpectedCount > 0 then
        self:_broadcastSystemMessage(
            ('Elite pressure: every %dth enemy is %s (expected %d this round).'):format(
                elitePreview.cadence,
                tostring(elitePreview.tag),
                self._eliteExpectedCount
            )
        )
    else
        self._eliteExpectedCount = 0
    end
    self:_teleportActiveRosterToMapSpawn(runId)

    local spawnBatchDone = false
    local spawnBatchError = nil
    local eliteFirstSeenAnnounced = false
    local spawnInterval = tonumber(self._config.ENEMY_SPAWN_INTERVAL_SECONDS) or 1.0
    if type(roundModifier) == 'table' then
        local spawnIntervalMultiplier = tonumber(roundModifier.spawnIntervalMultiplier) or 1
        spawnIntervalMultiplier *= (tonumber(difficultyPreset.spawnIntervalMultiplier) or 1)
        if spawnIntervalMultiplier < 0.1 then
            spawnIntervalMultiplier = 0.1
        end
        spawnInterval *= spawnIntervalMultiplier
    end
    if spawnInterval < 0 then
        spawnInterval = 0
    end

    task.spawn(function()
        local spawnedCount, spawnError = self._enemyService:spawnBatch(self._enemyTargetCount, spawnInterval, function()
            return self._running and self._runId == runId and not self._roundEndTriggered
        end, function(_, currentSpawnedCount)
            self._enemySpawnedCount = currentSpawnedCount
        end, function(enemyId)
            local snapshot = self._enemyService:getEnemySnapshot(enemyId)
            if snapshot and snapshot.isElite == true then
                self._eliteSpawnedCount += 1
                if not eliteFirstSeenAnnounced then
                    eliteFirstSeenAnnounced = true
                    local label = snapshot.eliteTag
                    if type(label) ~= 'string' or label == '' then
                        label = 'Elite'
                    end
                    self:_broadcastSystemMessage(
                        ('%s unit spawned (%d/%d).'):format(label, self._eliteSpawnedCount, self._eliteExpectedCount)
                    )
                end
            end
        end)
        self._enemySpawnedCount = spawnedCount
        if spawnError and spawnError ~= 'STOPPED_BY_CALLER' and spawnError ~= 'SERVICE_STOPPED' then
            spawnBatchError = spawnError
        end
        spawnBatchDone = true
    end)

    local waveTimer = self:_getRoundDurationSeconds(self._roundNumber)
    while self._running and self._runId == runId do
        local activeEnemyCount = self._enemyService:getActiveEnemyCount()
        if activeEnemyCount > self._peakActiveEnemyCount then
            self._peakActiveEnemyCount = activeEnemyCount
        end
        self:_checkRuntimeInvariants('wave_tick')
        local clampedTimeRemaining = math.max(waveTimer, 0)
        self._phaseTimeRemaining = clampedTimeRemaining
        self:_broadcastRoundStatus(self:_withEnemyProgress({
            phase = self._phase,
            wave = self._roundNumber,
            timeRemaining = clampedTimeRemaining,
            baseHealth = self._baseHealth,
            outcome = self._roundOutcome,
            activeEnemyCount = activeEnemyCount,
        }))

        if self._roundEndTriggered then
            break
        end

        if spawnBatchError then
            self:_triggerRoundEnd('Defeat', ('SPAWN_FAILED:%s'):format(tostring(spawnBatchError)))
            break
        end

        if spawnBatchDone and self._enemyResolvedCount >= self._enemyTargetCount and activeEnemyCount == 0 then
            self:_triggerRoundEnd('Victory', 'WAVE_CLEARED')
            break
        end

        if waveTimer <= 0 then
            self:_triggerRoundEnd('Defeat', 'WAVE_TIMEOUT')
            break
        end

        task.wait(1)
        if waveTimer > 0 then
            waveTimer -= 1
        end
    end
end

function RoundService:_runResultsPhase(runId: number)
    self._phase = 'Results'
    self:_configureSpawnPolicyForPhase(self._phase)
    self:_clearRestartVoteState()
    local duration = self._config.RESULTS_DURATION or 10
    self._phaseTimeRemaining = duration
    self:_broadcastSystemMessage('Results phase: vote restart now if you want immediate requeue.')

    for remaining = duration, 0, -1 do
        if not self._running or self._runId ~= runId then
            return
        end

        self._phaseTimeRemaining = remaining
        self:_broadcastRoundStatus(self:_withEnemyProgress({
            phase = self._phase,
            timeRemaining = remaining,
            baseHealth = self._baseHealth,
            outcome = self._roundOutcome,
            activeEnemyCount = self._enemyService:getActiveEnemyCount(),
        }))
        if self._restartVotePassed then
            break
        end
        task.wait(1)
    end
end

function RoundService:_runCleanupPhase(runId: number)
    if self._runId ~= runId then
        return
    end

    self._phase = 'Cleanup'
    self:_configureSpawnPolicyForPhase(self._phase)
    self._phaseTimeRemaining = 0
    local rosterSizeBeforeClear = self:_getLiveActiveRosterSize()
    self:_teleportActiveRosterToLobbySpawn(runId)

    local completedRoundModifierName = self._activeRoundModifierName
    local completedRoundMutatorName = self._activeMutatorName
    local towerPlacementService = self._towerPlacementService
    local towersBeforeCleanup = 0
    local towersRemoved = 0
    if towerPlacementService and type(towerPlacementService.clearRuntimeTowers) == 'function' then
        if type(towerPlacementService.getRuntimeTowerCount) == 'function' then
            towersBeforeCleanup = towerPlacementService:getRuntimeTowerCount()
        end
        towersRemoved = towerPlacementService:clearRuntimeTowers()
    end

    if self._restartVotePassed and self:_getLiveActiveRosterSize() > 0 then
        self._restartCarryRoster = table.clone(self._activeRoster)
    else
        table.clear(self._restartCarryRoster)
    end
    table.clear(self._activeRoster)
    local rosterCleared = #self._activeRoster == 0
    local activeEnemiesBeforeRestart = self._enemyService:getActiveEnemyCount()
    if type(self._enemyService.setRoundModifier) == 'function' then
        self._enemyService:setRoundModifier(nil)
    end
    self._activeRoundModifierName = 'NoModifier'
    self._activeRoundModifier = nil
    self._activeMutatorName = 'NoModifier'
    self._activeMutatorThreatHint = 'Standard wave pacing.'
    self._enemyService:stop()
    self._enemyService:start()
    -- EnemyService:stop() clears handlers; rebind for the next loop cycle.
    self:_bindEnemyCallbacks(runId)
    local activeEnemiesAfterRestart = self._enemyService:getActiveEnemyCount()
    local towersAfterCleanup = 0
    if towerPlacementService and type(towerPlacementService.getRuntimeTowerCount) == 'function' then
        towersAfterCleanup = towerPlacementService:getRuntimeTowerCount()
    end

    if self._config.DEBUG_SOAK_SNAPSHOT ~= false then
        print(('[Soak][RoundCleanup] %s'):format(jsonEncode(toTelemetryEnvelope('SoakRoundCleanup', {
            roundOutcome = self._roundOutcome,
            rosterSizeBeforeClear = rosterSizeBeforeClear,
            towersBeforeCleanup = towersBeforeCleanup,
            towersRemoved = towersRemoved,
            towersAfterCleanup = towersAfterCleanup,
            activeEnemiesBeforeRestart = activeEnemiesBeforeRestart,
            activeEnemiesAfterRestart = activeEnemiesAfterRestart,
        }))))
    end

    local countersCoherent = (self._enemyKilledCount + self._enemyLeakedCount) == self._enemyResolvedCount
    local resolvedNotExceedSpawned = self._enemyResolvedCount <= self._enemySpawnedCount
    local spawnedNotExceedTarget = self._enemySpawnedCount <= self._enemyTargetCount
    local terminalOutcomeConsistent = true
    if self._roundOutcome == 'Victory' then
        terminalOutcomeConsistent = self._enemyResolvedCount >= self._enemyTargetCount
    elseif self._roundOutcome == 'Defeat' then
        terminalOutcomeConsistent = self._baseHealth <= 0 or self._roundEndReason == 'WAVE_TIMEOUT'
    end
    local towersCleared = towersAfterCleanup == 0
    local enemiesClearedAfterRestart = activeEnemiesAfterRestart == 0
    local cleanupPass = towersCleared and enemiesClearedAfterRestart and rosterCleared
    local runtimeInvariantHealthy = self._runtimeInvariantBreaches == 0
    local overallPass = countersCoherent
        and resolvedNotExceedSpawned
        and spawnedNotExceedTarget
        and terminalOutcomeConsistent
        and runtimeInvariantHealthy
        and cleanupPass

    if self._config.DEBUG_RELEASE_GATE_SUMMARY ~= false and not overallPass then
        local failureLabels = {}
        if not countersCoherent then
            table.insert(failureLabels, 'COUNTER_MISMATCH')
        end
        if not resolvedNotExceedSpawned then
            table.insert(failureLabels, 'RESOLVED_EXCEEDS_SPAWNED')
        end
        if not spawnedNotExceedTarget then
            table.insert(failureLabels, 'SPAWNED_EXCEEDS_TARGET')
        end
        if not terminalOutcomeConsistent then
            table.insert(failureLabels, 'TERMINAL_OUTCOME_MISMATCH')
        end
        if not towersCleared then
            table.insert(failureLabels, 'TOWERS_NOT_CLEARED')
        end
        if not enemiesClearedAfterRestart then
            table.insert(failureLabels, 'ENEMIES_NOT_CLEARED')
        end
        if not rosterCleared then
            table.insert(failureLabels, 'ROSTER_NOT_CLEARED')
        end
        if not runtimeInvariantHealthy then
            table.insert(failureLabels, 'RUNTIME_INVARIANT_BREACH')
        end
        self:_broadcastSystemMessage(('Release gate round FAIL: %s'):format(table.concat(failureLabels, ', ')))
    end

    self:_recordReleaseGateResult({
        countersCoherent = countersCoherent,
        resolvedNotExceedSpawned = resolvedNotExceedSpawned,
        spawnedNotExceedTarget = spawnedNotExceedTarget,
        terminalOutcomeConsistent = terminalOutcomeConsistent,
        runtimeInvariantHealthy = runtimeInvariantHealthy,
        towersCleared = towersCleared,
        enemiesClearedAfterRestart = enemiesClearedAfterRestart,
        rosterCleared = rosterCleared,
        cleanupPass = cleanupPass,
        overallPass = overallPass,
    })
    self:_emitReleaseGateSummary({
        roundOutcome = self._roundOutcome,
        roundModifierName = completedRoundModifierName,
        roundMutatorName = completedRoundMutatorName,
        countersCoherent = countersCoherent,
        resolvedNotExceedSpawned = resolvedNotExceedSpawned,
        spawnedNotExceedTarget = spawnedNotExceedTarget,
        terminalOutcomeConsistent = terminalOutcomeConsistent,
        runtimeInvariantHealthy = runtimeInvariantHealthy,
        towersCleared = towersCleared,
        enemiesClearedAfterRestart = enemiesClearedAfterRestart,
        rosterCleared = rosterCleared,
        cleanupPass = cleanupPass,
        overallPass = overallPass,
        towersAfterCleanup = towersAfterCleanup,
        activeEnemiesAfterRestart = activeEnemiesAfterRestart,
    })

    self:_broadcastRoundStatus(self:_withEnemyProgress({
        phase = self._phase,
        timeRemaining = 0,
        baseHealth = self._baseHealth,
        outcome = self._roundOutcome,
        roundModifierName = completedRoundModifierName,
        roundMutatorName = completedRoundMutatorName,
        activeEnemyCount = self._enemyService:getActiveEnemyCount(),
    }))
    self:_clearRestartVoteState()
    task.wait(0.1)
end

function RoundService:_runLoop(runId: number)
    while self._running and self._runId == runId do
        self:_runLobbyPhase(runId)
        if not self._running or self._runId ~= runId then
            break
        end

        self:_runWavePhase(runId)
        if not self._running or self._runId ~= runId then
            break
        end

        self:_runResultsPhase(runId)
        if not self._running or self._runId ~= runId then
            break
        end

        self:_runCleanupPhase(runId)
    end
end

function RoundService:start()
    if self._running then
        return
    end

    self._running = true
    self._runId += 1
    self._nextCorrelationOrdinal = 0
    self:_configureSpawnPolicyForPhase('Lobby')
    self._sessionStartedAt = os.clock()
    self._telemetry.maxWaveReached = 0
    self._telemetry.roundsEnded = 0
    table.clear(self._telemetry.outcomes)
    table.clear(self._telemetry.endReasons)
    self._telemetry.releaseGate.roundsChecked = 0
    self._telemetry.releaseGate.overallPasses = 0
    self._telemetry.releaseGate.cleanupPasses = 0
    self._telemetry.releaseGate.countersCoherentPasses = 0
    table.clear(self._telemetry.releaseGate.failuresByReason)
    local runId = self._runId

    self._enemyService:start()
    self:_initializeBaseHealth()
    self:_bindEnemyCallbacks(runId)
    self:_bindVoteDifficultyRemote()
    self:_bindVoteRestartRemote()
    task.spawn(function()
        self:_runLoop(runId)
    end)
end

function RoundService:stop()
    if not self._running then
        return
    end

    self._running = false
    self._runId += 1
    self._phase = 'Stopped'
    self:_configureSpawnPolicyForPhase(self._phase)
    self._phaseTimeRemaining = nil
    self._roundNumber = 0
    self._roundOutcome = nil
    self._roundEndReason = nil
    self._roundEndTriggered = false
    self._waveStartedAt = nil
    self._peakActiveEnemyCount = 0
    self._runtimeInvariantBreaches = 0
    self._lastInvariantWarningAt = 0
    self._lastInvariantWarningSignature = nil
    table.clear(self._leaksByPhase)
    self._enemyTargetCount = 0
    self._enemySpawnedCount = 0
    self._enemyResolvedCount = 0
    self._enemyLeakedCount = 0
    self._enemyKilledCount = 0
    self._activeRoundModifierName = 'NoModifier'
    self._activeRoundModifier = nil
    self._activeMutatorName = 'NoModifier'
    self._activeMutatorThreatHint = 'Standard wave pacing.'
    self._activeMissionSnapshot = {}
    self._activeMissionCompletedCount = 0
    self._activeMissionTotalCount = 0
    table.clear(self._activeRoster)
    self._enemyService:setEnemyLeakedHandler(nil)
    self._enemyService:setEnemyDiedHandler(nil)
    self._enemyService:stop()
    if self._difficultyVoteRemoteConnection then
        self._difficultyVoteRemoteConnection:Disconnect()
        self._difficultyVoteRemoteConnection = nil
    end
    if self._voteRestartRemoteConnection then
        self._voteRestartRemoteConnection:Disconnect()
        self._voteRestartRemoteConnection = nil
    end
    table.clear(self._requestBuckets)
    self:_clearDifficultyVoteState()
    self:_clearRestartVoteState()
    table.clear(self._restartCarryRoster)

    local sessionLengthSeconds = 0
    if self._sessionStartedAt then
        sessionLengthSeconds = math.max(0, os.clock() - self._sessionStartedAt)
    end
    local snapshot = {
        sessionLengthSeconds = math.floor((sessionLengthSeconds * 100) + 0.5) / 100,
        maxWaveReached = self._telemetry.maxWaveReached,
        roundsEnded = self._telemetry.roundsEnded,
        outcomes = self._telemetry.outcomes,
        endReasons = self._telemetry.endReasons,
        releaseGate = {
            roundsChecked = self._telemetry.releaseGate.roundsChecked,
            overallPasses = self._telemetry.releaseGate.overallPasses,
            cleanupPasses = self._telemetry.releaseGate.cleanupPasses,
            countersCoherentPasses = self._telemetry.releaseGate.countersCoherentPasses,
            failuresByReason = self._telemetry.releaseGate.failuresByReason,
        },
    }
    self:_emitReleaseGateSessionSummary()
    print(('[Telemetry][RoundService] %s'):format(jsonEncode(toTelemetryEnvelope('ServiceStopSummary', snapshot))))
    self._sessionStartedAt = nil
end

function RoundService:getPhase(): string
    return self._phase
end

function RoundService:getRoundNumber(): number
    return self._roundNumber
end

function RoundService:setQueueService(queueService)
    self._queueService = queueService
end

function RoundService:setTowerPlacementService(towerPlacementService)
    self._towerPlacementService = towerPlacementService
end

function RoundService:isPlayerInActiveRoster(player: Player): boolean
    if not player then
        return false
    end

    local userId = player.UserId
    for _, rosterPlayer in ipairs(self._activeRoster) do
        if rosterPlayer and rosterPlayer.UserId == userId and rosterPlayer.Parent then
            return true
        end
    end

    return false
end

function RoundService:isAcceptingTowerActions(): boolean
    if not self._running then
        return false
    end

    if self._phase ~= 'Wave' then
        return false
    end

    return self._roundEndTriggered ~= true
end

return RoundService
