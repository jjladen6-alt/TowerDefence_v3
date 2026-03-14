local Players = game:GetService('Players')
local Workspace = game:GetService('Workspace')
local HttpService = game:GetService('HttpService')

local QueueService = {}
QueueService.__index = QueueService

local DEFAULT_QUEUE_PAD_NAME_BY_STAGE = {
    brown = 'queuepadbrown',
    green = 'queuepadgreen',
    red = 'queuepadred',
    yellow = 'queuepadyellow',
}

local function findThroughSameNameWrappers(root: Instance, childName: string): Instance?
    local direct = root:FindFirstChild(childName)
    if direct then
        return direct
    end

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
            return nil
        end

        direct = wrapped:FindFirstChild(childName)
        if direct then
            return direct
        end
        cursor = wrapped
    end

    return nil
end

local function getRemoteEvent(remoteName: string, timeoutSeconds: number?): RemoteEvent?
    local replicatedStorage = game:GetService('ReplicatedStorage')
    local remotesFolder = replicatedStorage:FindFirstChild('Remotes')
    if not remotesFolder then
        remotesFolder = replicatedStorage:WaitForChild('Remotes', timeoutSeconds or 5)
    end
    if not remotesFolder then
        return nil
    end

    local remote = remotesFolder:FindFirstChild(remoteName)
    if not remote then
        remote = remotesFolder:WaitForChild(remoteName, timeoutSeconds or 5)
    end
    if remote and remote:IsA('RemoteEvent') then
        return remote
    end
    return nil
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
        service = 'QueueService',
        kind = kind,
        payload = payload,
    }
end

local function resolvePlayerFromHitPart(hitPart: BasePart?): Player?
    if not hitPart then
        return nil
    end

    local character = hitPart:FindFirstAncestorOfClass('Model')
    if not character then
        return nil
    end
    if not character:FindFirstChildOfClass('Humanoid') then
        return nil
    end
    return Players:GetPlayerFromCharacter(character)
end

function QueueService.new(gameConfig, net)
    return setmetatable({
        _config = gameConfig,
        _net = net,
        _running = false,
        _runId = 0,
        _connections = {},
        _remotes = {},
        _requestBuckets = {},
        _requestDedupByUserId = {},
        _nextCorrelationOrdinal = 0,
        _stageOrder = {},
        _stageQueues = {},
        _playerStageByUserId = {},
        _lockedQueueStageId = nil,
    }, QueueService)
end

function QueueService:_emitTelemetry(kind: string, payload)
    print(('[Telemetry][QueueService] %s'):format(jsonEncode(toTelemetryEnvelope(kind, payload))))
end

function QueueService:_getSystemMessageRemote(): RemoteEvent?
    if self._remotes.systemMessage and self._remotes.systemMessage.Parent then
        return self._remotes.systemMessage
    end
    self._remotes.systemMessage = getRemoteEvent(self._net.ServerToClient.SystemMessage, 5)
    return self._remotes.systemMessage
end

function QueueService:_sendSystemMessage(player: Player, text: string)
    if text == '' then
        return
    end
    local remote = self:_getSystemMessageRemote()
    if not remote then
        return
    end
    remote:FireClient(player, { text = text })
end

function QueueService:_sanitizeCorrelationId(value): string?
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

function QueueService:_nextCorrelationId(requestType: string, userId: number): string
    self._nextCorrelationOrdinal += 1
    return ('q-%d-%s-%d'):format(userId, tostring(requestType or 'request'), self._nextCorrelationOrdinal)
end

function QueueService:_resolveRequestCorrelationId(player: Player, requestType: string, payload): string
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

function QueueService:_checkAndConsumeRateLimit(player: Player, requestType: string): (boolean, string?)
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
        bucket = { windowStart = now, count = 0 }
        userBuckets[requestType] = bucket
    end

    if (now - bucket.windowStart) >= perSeconds then
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

function QueueService:_isPayloadShapeValid(payload): (boolean, string?)
    if type(payload) ~= 'table' then
        return false, 'INVALID_PAYLOAD_TYPE'
    end

    local maxKeys = tonumber(self._config.REQUEST_MAX_PAYLOAD_KEYS) or 16
    maxKeys = math.max(1, math.floor(maxKeys))
    local keyCount = 0
    for _ in pairs(payload) do
        keyCount += 1
        if keyCount > maxKeys then
            return false, 'PAYLOAD_TOO_LARGE'
        end
    end
    return true, nil
end

function QueueService:_checkAndTrackRequestDedup(player: Player, requestType: string, payload): (boolean, string?)
    local requestId = payload.requestId
    if requestId == nil then
        return true, nil
    end
    if type(requestId) ~= 'string' then
        return false, 'INVALID_REQUEST_ID_TYPE'
    end
    local trimmed = string.gsub(requestId, '^%s*(.-)%s*$', '%1')
    if trimmed == '' or #trimmed > 64 then
        return false, 'INVALID_REQUEST_ID'
    end

    local dedupWindowSeconds = tonumber(self._config.REQUEST_DEDUP_WINDOW_SECONDS) or 10
    dedupWindowSeconds = math.max(0, dedupWindowSeconds)
    if dedupWindowSeconds <= 0 then
        return true, nil
    end

    local now = os.clock()
    local userDedup = self._requestDedupByUserId[player.UserId]
    if not userDedup then
        userDedup = {}
        self._requestDedupByUserId[player.UserId] = userDedup
    end

    local expired = {}
    for dedupKey, seenAt in pairs(userDedup) do
        if (now - seenAt) > dedupWindowSeconds then
            table.insert(expired, dedupKey)
        end
    end
    for _, dedupKey in ipairs(expired) do
        userDedup[dedupKey] = nil
    end

    local dedupKey = ('%s:%s'):format(requestType, trimmed)
    local priorSeenAt = userDedup[dedupKey]
    if priorSeenAt and (now - priorSeenAt) <= dedupWindowSeconds then
        return false, 'DUPLICATE_REQUEST'
    end

    userDedup[dedupKey] = now
    return true, nil
end

function QueueService:_validateRequest(
    player: Player,
    requestType: string,
    payload
): (boolean, string?, string?, string)
    local correlationId = self:_resolveRequestCorrelationId(player, requestType, payload)
    local allowedRate, rateLimitMessage = self:_checkAndConsumeRateLimit(player, requestType)
    if not allowedRate then
        return false, 'RATE_LIMITED', rateLimitMessage, correlationId
    end

    local shapeOk, shapeReason = self:_isPayloadShapeValid(payload)
    if not shapeOk then
        return false, shapeReason, nil, correlationId
    end

    local dedupOk, dedupReason = self:_checkAndTrackRequestDedup(player, requestType, payload)
    if not dedupOk then
        return false, dedupReason, nil, correlationId
    end

    return true, nil, nil, correlationId
end

function QueueService:_getQueuePadNameForStage(stageId: string): string
    local overrideMap = self._config.QUEUE_PAD_NAMES_BY_STAGE
    if type(overrideMap) == 'table' then
        local fromOverride = overrideMap[stageId]
        if type(fromOverride) == 'string' and fromOverride ~= '' then
            return fromOverride
        end
    end
    return DEFAULT_QUEUE_PAD_NAME_BY_STAGE[stageId] or ('queuepad%s'):format(stageId)
end

function QueueService:_createStageQueue(stageId: string)
    local queuePadName = self:_getQueuePadNameForStage(stageId)
    self._stageQueues[stageId] = {
        stageId = stageId,
        queuePadName = queuePadName,
        queuePad = nil,
        state = 'Idle',
        countdownActive = false,
        countdownTimeRemaining = nil,
        countdownRunId = 0,
        queuedByUserId = {},
        queuedOrder = {},
        queuedSelectionByUserId = {},
        readyByUserId = {},
        lastSeenOnPadAtByUserId = {},
        lockedRoster = {},
        lockedStageSelection = nil,
    }
    table.insert(self._stageOrder, stageId)
end

function QueueService:_initializeStageQueues()
    table.clear(self._stageOrder)
    table.clear(self._stageQueues)
    table.clear(self._playerStageByUserId)
    self._lockedQueueStageId = nil

    local stageOptions = self._config.STAGE_SELECTION_OPTIONS
    if type(stageOptions) == 'table' then
        for _, stage in ipairs(stageOptions) do
            if type(stage) == 'table' and stage.implemented ~= false then
                local stageId = stage.stageId
                if type(stageId) == 'string' and stageId ~= '' and not self._stageQueues[stageId] then
                    self:_createStageQueue(stageId)
                end
            end
        end
    end

    if #self._stageOrder == 0 then
        local defaultStage = tostring(self._config.DEFAULT_STAGE_ID or 'brown')
        self:_createStageQueue(defaultStage)
    end
end

function QueueService:_resolveSelectionFromPayload(payload): (boolean, table?, string?, string?)
    local stageId = if type(payload) == 'table'
            and type(payload.stageId) == 'string'
            and payload.stageId ~= ''
        then payload.stageId
        else nil
    local actId = tostring(
        (type(payload) == 'table' and type(payload.actId) == 'string' and payload.actId ~= '' and payload.actId)
            or self._config.DEFAULT_ACT_ID
            or 'Act1'
    )

    local configuredStages = self._config.STAGE_SELECTION_OPTIONS
    if type(configuredStages) ~= 'table' then
        stageId = stageId or tostring(self._config.DEFAULT_STAGE_ID or 'brown')
        return true, { stageId = stageId, actId = actId, implemented = true }, nil, nil
    end

    local selectedStage = nil
    if stageId then
        for _, stage in ipairs(configuredStages) do
            if type(stage) == 'table' and tostring(stage.stageId or '') == stageId then
                selectedStage = stage
                break
            end
        end
        if not selectedStage then
            return false, nil, 'UNKNOWN_STAGE', ('Unknown stageId "%s".'):format(stageId)
        end
    else
        for _, stage in ipairs(configuredStages) do
            if type(stage) == 'table' and stage.implemented ~= false then
                selectedStage = stage
                stageId = tostring(stage.stageId)
                break
            end
        end
    end

    if not selectedStage or not stageId then
        return false, nil, 'UNKNOWN_STAGE', 'No implemented stage found.'
    end
    if selectedStage.implemented == false then
        return false, nil, 'STAGE_NOT_IMPLEMENTED', ('Stage "%s" is not available yet.'):format(stageId)
    end

    local selectedAct = nil
    if type(selectedStage.acts) == 'table' then
        for _, act in ipairs(selectedStage.acts) do
            if type(act) == 'table' and tostring(act.actId or '') == actId then
                selectedAct = act
                break
            end
        end
    end
    if not selectedAct then
        return false, nil, 'UNKNOWN_ACT', ('Unknown actId "%s" for stage "%s".'):format(actId, stageId)
    end
    if selectedAct.unlocked == false then
        return false, nil, 'ACT_LOCKED', ('Act "%s" is currently locked.'):format(actId)
    end

    return true,
        {
            stageId = stageId,
            actId = actId,
            stageLabel = tostring(selectedStage.stageLabel or stageId),
            implemented = true,
        },
        nil,
        nil
end

function QueueService:_getStageQueueSize(stageId: string): number
    local stageQueue = self._stageQueues[stageId]
    if not stageQueue then
        return 0
    end
    local count = 0
    for _ in pairs(stageQueue.queuedByUserId) do
        count += 1
    end
    return count
end

function QueueService:_getStageReadyCount(stageId: string): number
    local stageQueue = self._stageQueues[stageId]
    if not stageQueue then
        return 0
    end
    local ready = 0
    for userId in pairs(stageQueue.queuedByUserId) do
        if stageQueue.readyByUserId[userId] ~= false then
            ready += 1
        end
    end
    return ready
end

function QueueService:_getPlayerRoot(player: Player): BasePart?
    local character = player.Character
    if not character then
        return nil
    end
    local root = character:FindFirstChild('HumanoidRootPart')
    if root and root:IsA('BasePart') then
        return root
    end
    return nil
end

function QueueService:_isPointInsidePad(queuePad: BasePart?, worldPoint: Vector3): boolean
    if not queuePad then
        return false
    end
    local localPoint = queuePad.CFrame:PointToObjectSpace(worldPoint)
    local halfSize = queuePad.Size * 0.5
    local yTolerance = halfSize.Y + 7
    return math.abs(localPoint.X) <= halfSize.X
        and math.abs(localPoint.Z) <= halfSize.Z
        and math.abs(localPoint.Y) <= yTolerance
end

function QueueService:_isPlayerOnStagePad(player: Player, stageId: string): boolean
    local stageQueue = self._stageQueues[stageId]
    if not stageQueue then
        return false
    end
    local root = self:_getPlayerRoot(player)
    if not root then
        return false
    end
    return self:_isPointInsidePad(stageQueue.queuePad, root.Position)
end

function QueueService:_resolvePlayerStageFromPad(player: Player): string?
    for _, stageId in ipairs(self._stageOrder) do
        if self:_isPlayerOnStagePad(player, stageId) then
            return stageId
        end
    end
    return nil
end

function QueueService:_getQueueMinPlayers(): number
    local minPlayers = tonumber(self._config.QUEUE_MIN_PLAYERS) or 1
    if minPlayers < 1 then
        minPlayers = 1
    end
    return math.floor(minPlayers)
end

function QueueService:_getQueueCountdownSeconds(): number
    local seconds = tonumber(self._config.QUEUE_START_COUNTDOWN_SECONDS) or 10
    if seconds < 1 then
        seconds = 1
    end
    return math.floor(seconds)
end

function QueueService:_removeQueuedPlayerFromStage(userId: number, stageId: string)
    local stageQueue = self._stageQueues[stageId]
    if not stageQueue or stageQueue.state == 'Locked' then
        return
    end

    stageQueue.queuedByUserId[userId] = nil
    stageQueue.queuedSelectionByUserId[userId] = nil
    stageQueue.readyByUserId[userId] = nil
    stageQueue.lastSeenOnPadAtByUserId[userId] = nil

    for index = #stageQueue.queuedOrder, 1, -1 do
        if stageQueue.queuedOrder[index] == userId then
            table.remove(stageQueue.queuedOrder, index)
            break
        end
    end

    if self._playerStageByUserId[userId] == stageId then
        self._playerStageByUserId[userId] = nil
    end
    self:_evaluateCountdown(stageId)
end

function QueueService:_removeQueuedPlayerByUserId(userId: number)
    local stageId = self._playerStageByUserId[userId]
    if stageId then
        self:_removeQueuedPlayerFromStage(userId, stageId)
        return
    end
    for _, candidateStageId in ipairs(self._stageOrder) do
        if self._stageQueues[candidateStageId].queuedByUserId[userId] then
            self:_removeQueuedPlayerFromStage(userId, candidateStageId)
        end
    end
end

function QueueService:_addQueuedPlayerToStage(player: Player, stageId: string, selection)
    local stageQueue = self._stageQueues[stageId]
    if not stageQueue or stageQueue.state == 'Locked' then
        return
    end

    local priorStageId = self._playerStageByUserId[player.UserId]
    if priorStageId and priorStageId ~= stageId then
        self:_removeQueuedPlayerFromStage(player.UserId, priorStageId)
    end

    if not stageQueue.queuedByUserId[player.UserId] then
        stageQueue.queuedByUserId[player.UserId] = player
        table.insert(stageQueue.queuedOrder, player.UserId)
    end
    if stageQueue.readyByUserId[player.UserId] == nil then
        stageQueue.readyByUserId[player.UserId] = true
    end
    if type(selection) == 'table' then
        stageQueue.queuedSelectionByUserId[player.UserId] = selection
    end
    stageQueue.lastSeenOnPadAtByUserId[player.UserId] = os.clock()
    self._playerStageByUserId[player.UserId] = stageId
    self:_evaluateCountdown(stageId)
end

function QueueService:_cancelCountdown(stageId: string, reasonCode: string?, correlationId: string?)
    local stageQueue = self._stageQueues[stageId]
    if not stageQueue or not stageQueue.countdownActive then
        return
    end

    stageQueue.countdownRunId += 1
    stageQueue.countdownActive = false
    stageQueue.countdownTimeRemaining = nil
    if stageQueue.state ~= 'Locked' then
        stageQueue.state = 'Idle'
    end
    self:_emitTelemetry('QueueLifecycle', {
        event = 'COUNTDOWN_CANCELLED',
        stageId = stageId,
        reasonCode = reasonCode or 'UNSPECIFIED',
        queueSize = self:_getStageQueueSize(stageId),
        correlationId = correlationId,
    })
end

function QueueService:_lockCurrentRoster(stageId: string)
    local stageQueue = self._stageQueues[stageId]
    if not stageQueue then
        return
    end
    if self._lockedQueueStageId and self._lockedQueueStageId ~= stageId then
        self:_cancelCountdown(stageId, 'LOCK_PENDING', nil)
        return
    end

    table.clear(stageQueue.lockedRoster)
    for _, userId in ipairs(stageQueue.queuedOrder) do
        local player = stageQueue.queuedByUserId[userId]
        local isReady = stageQueue.readyByUserId[userId] ~= false
        if player and player.Parent == Players and isReady then
            table.insert(stageQueue.lockedRoster, player)
        end
    end

    local selectedStage = nil
    for _, player in ipairs(stageQueue.lockedRoster) do
        local selection = stageQueue.queuedSelectionByUserId[player.UserId]
        if type(selection) == 'table' then
            selectedStage = table.clone(selection)
            break
        end
    end
    if not selectedStage then
        selectedStage = {
            stageId = stageId,
            actId = tostring(self._config.DEFAULT_ACT_ID or 'Act1'),
            stageLabel = stageId,
            implemented = true,
        }
    end
    stageQueue.lockedStageSelection = selectedStage

    table.clear(stageQueue.queuedByUserId)
    table.clear(stageQueue.queuedOrder)
    table.clear(stageQueue.lastSeenOnPadAtByUserId)
    table.clear(stageQueue.readyByUserId)
    table.clear(stageQueue.queuedSelectionByUserId)

    stageQueue.state = 'Locked'
    stageQueue.countdownActive = false
    stageQueue.countdownTimeRemaining = 0
    self._lockedQueueStageId = stageId

    self:_emitTelemetry('QueueLifecycle', {
        event = 'ROSTER_LOCKED',
        stageId = stageId,
        lockedCount = #stageQueue.lockedRoster,
        selectedActId = selectedStage.actId,
    })
end

function QueueService:_startCountdown(stageId: string)
    local stageQueue = self._stageQueues[stageId]
    if not stageQueue or stageQueue.countdownActive or not self._running then
        return
    end

    local minPlayers = self:_getQueueMinPlayers()
    if self:_getStageQueueSize(stageId) < minPlayers then
        stageQueue.state = 'Idle'
        stageQueue.countdownActive = false
        stageQueue.countdownTimeRemaining = nil
        return
    end

    stageQueue.countdownActive = true
    stageQueue.state = 'CountingDown'
    stageQueue.countdownRunId += 1
    local countdownRunId = stageQueue.countdownRunId
    local countdownSeconds = self:_getQueueCountdownSeconds()

    task.spawn(function()
        for remaining = countdownSeconds, 0, -1 do
            if not self._running then
                return
            end
            local liveStageQueue = self._stageQueues[stageId]
            if
                not liveStageQueue
                or not liveStageQueue.countdownActive
                or liveStageQueue.countdownRunId ~= countdownRunId
                or liveStageQueue.state == 'Locked'
            then
                return
            end
            if self:_getStageQueueSize(stageId) < minPlayers then
                self:_cancelCountdown(stageId, 'INSUFFICIENT_PLAYERS', nil)
                return
            end

            liveStageQueue.countdownTimeRemaining = remaining
            if remaining > 0 then
                task.wait(1)
            end
        end

        local liveStageQueue = self._stageQueues[stageId]
        if
            not self._running
            or not liveStageQueue
            or not liveStageQueue.countdownActive
            or liveStageQueue.countdownRunId ~= countdownRunId
            or liveStageQueue.state == 'Locked'
        then
            return
        end
        self:_lockCurrentRoster(stageId)
    end)
end

function QueueService:_evaluateCountdown(stageId: string)
    local stageQueue = self._stageQueues[stageId]
    if not stageQueue or stageQueue.state == 'Locked' then
        return
    end

    local minPlayers = self:_getQueueMinPlayers()
    local queueSize = self:_getStageQueueSize(stageId)
    if queueSize < minPlayers then
        self:_cancelCountdown(stageId, 'INSUFFICIENT_PLAYERS', nil)
        if not stageQueue.countdownActive then
            stageQueue.state = 'Idle'
            stageQueue.countdownTimeRemaining = nil
        end
        return
    end

    if not stageQueue.countdownActive then
        self:_startCountdown(stageId)
    end
end

function QueueService:_rejectRequest(
    player: Player,
    requestType: string,
    reasonCode: string,
    message: string,
    extraPayload,
    correlationId: string?
)
    self:_sendSystemMessage(player, ('[Queue][%s] %s'):format(reasonCode, message))
    local payload = {
        event = 'REQUEST_REJECTED',
        requestType = requestType,
        reasonCode = reasonCode,
        userId = player.UserId,
        queueState = self:getState(),
        correlationId = correlationId,
    }
    if type(extraPayload) == 'table' then
        for key, value in pairs(extraPayload) do
            payload[key] = value
        end
    end
    self:_emitTelemetry('QueueRequest', payload)
end

function QueueService:_setPlayerReady(player: Player, stageId: string, isReady: boolean, correlationId: string?)
    local stageQueue = self._stageQueues[stageId]
    if not stageQueue or not stageQueue.queuedByUserId[player.UserId] then
        self:_rejectRequest(
            player,
            self._net.ClientToServer.RequestReady,
            'NOT_QUEUED',
            'Queue action rejected: stand on a color queue pad first.',
            nil,
            correlationId
        )
        return
    end
    stageQueue.readyByUserId[player.UserId] = isReady
    self:_sendSystemMessage(
        player,
        ('[Queue][%s] Ready state: %s'):format(
            isReady and 'READY_SET' or 'READY_UNSET',
            isReady and 'READY' or 'NOT READY'
        )
    )
    self:_emitTelemetry('QueueRequest', {
        event = 'READY_STATE_CHANGED',
        stageId = stageId,
        userId = player.UserId,
        ready = isReady,
        queueSize = self:_getStageQueueSize(stageId),
        correlationId = correlationId,
    })
end

function QueueService:_handleRequestCreateMatch(player: Player, payload)
    local requestType = self._net.ClientToServer.RequestCreateMatch
    local validRequest, rejectReason, rejectMessage, correlationId = self:_validateRequest(player, requestType, payload)
    if not validRequest then
        self:_rejectRequest(
            player,
            requestType,
            rejectReason or 'INVALID_REQUEST',
            rejectMessage or 'Queue create request rejected.',
            {
                payloadType = typeof(payload),
            },
            correlationId
        )
        return
    end

    if self._lockedQueueStageId then
        self:_rejectRequest(
            player,
            requestType,
            'QUEUE_LOCKED',
            'A match is locking now. Please wait for the next lobby window.',
            { lockedStageId = self._lockedQueueStageId },
            correlationId
        )
        return
    end

    local selectionOk, selection, selectionReasonCode, selectionReasonMessage =
        self:_resolveSelectionFromPayload(payload)
    if not selectionOk then
        self:_rejectRequest(
            player,
            requestType,
            selectionReasonCode or 'INVALID_STAGE_SELECTION',
            selectionReasonMessage or 'Invalid stage selection.',
            nil,
            correlationId
        )
        return
    end

    local stageIdFromPad = self:_resolvePlayerStageFromPad(player)
    local stageId = selection and selection.stageId
    if not stageId and stageIdFromPad then
        stageId = stageIdFromPad
    end
    if not stageId then
        self:_rejectRequest(
            player,
            requestType,
            'NOT_ON_QUEUE_PAD',
            'Stand on a color queue pad to choose a stage queue.',
            nil,
            correlationId
        )
        return
    end
    if stageIdFromPad ~= stageId then
        self:_rejectRequest(
            player,
            requestType,
            'NOT_ON_STAGE_PAD',
            ('Stand on the %s queue pad to join that stage queue.'):format(stageId),
            nil,
            correlationId
        )
        return
    end

    selection.stageId = stageId
    self:_addQueuedPlayerToStage(player, stageId, selection)
    self:_sendSystemMessage(player, ('[Queue][QUEUED] Queued for %s.'):format(stageId))
    self:_emitTelemetry('QueueRequest', {
        event = 'REQUEST_ACCEPTED',
        requestType = requestType,
        stageId = stageId,
        userId = player.UserId,
        queueSize = self:_getStageQueueSize(stageId),
        correlationId = correlationId,
    })
end

function QueueService:_handleRequestReady(player: Player, payload)
    local requestType = self._net.ClientToServer.RequestReady
    local validRequest, rejectReason, rejectMessage, correlationId = self:_validateRequest(player, requestType, payload)
    if not validRequest then
        self:_rejectRequest(
            player,
            requestType,
            rejectReason or 'INVALID_REQUEST',
            rejectMessage or 'Queue ready request rejected.',
            {
                payloadType = typeof(payload),
            },
            correlationId
        )
        return
    end

    local selectionOk, selection, selectionReasonCode, selectionReasonMessage =
        self:_resolveSelectionFromPayload(payload)
    if not selectionOk then
        self:_rejectRequest(
            player,
            requestType,
            selectionReasonCode or 'INVALID_STAGE_SELECTION',
            selectionReasonMessage or 'Invalid stage selection.',
            nil,
            correlationId
        )
        return
    end

    local readyValue = true
    if type(payload) == 'table' and payload.ready ~= nil then
        if type(payload.ready) ~= 'boolean' then
            self:_rejectRequest(
                player,
                requestType,
                'INVALID_READY_VALUE',
                'Ready must be true or false.',
                nil,
                correlationId
            )
            return
        end
        readyValue = payload.ready == true
    end

    local playerStageId = self._playerStageByUserId[player.UserId]
    local stageId = selection and selection.stageId or playerStageId
    if not stageId and playerStageId then
        stageId = playerStageId
    end
    if not stageId then
        self:_rejectRequest(
            player,
            requestType,
            'NOT_QUEUED',
            'Ready toggle rejected: you are not in a queue.',
            nil,
            correlationId
        )
        return
    end

    local stageQueue = self._stageQueues[stageId]
    if not stageQueue or stageQueue.state == 'Locked' then
        self:_rejectRequest(
            player,
            requestType,
            'QUEUE_LOCKED',
            'Ready toggle rejected: queue already locked for this match.',
            { stageId = stageId },
            correlationId
        )
        return
    end

    if type(selection) == 'table' then
        selection.stageId = stageId
        stageQueue.queuedSelectionByUserId[player.UserId] = selection
    end
    self:_setPlayerReady(player, stageId, readyValue, correlationId)
    self:_emitTelemetry('QueueRequest', {
        event = 'REQUEST_ACCEPTED',
        requestType = requestType,
        stageId = stageId,
        userId = player.UserId,
        ready = readyValue,
        queueSize = self:_getStageQueueSize(stageId),
        countdownActive = stageQueue.countdownActive,
        countdownTimeRemaining = stageQueue.countdownTimeRemaining,
        correlationId = correlationId,
    })
end

function QueueService:_onQueuePadTouched(stageId: string, hitPart: BasePart)
    local player = resolvePlayerFromHitPart(hitPart)
    if not player then
        return
    end
    if self:_isPlayerOnStagePad(player, stageId) then
        self:_addQueuedPlayerToStage(player, stageId, {
            stageId = stageId,
            actId = tostring(self._config.DEFAULT_ACT_ID or 'Act1'),
            stageLabel = stageId,
            implemented = true,
        })
    end
end

function QueueService:_onQueuePadTouchEnded(stageId: string, hitPart: BasePart)
    local player = resolvePlayerFromHitPart(hitPart)
    if not player then
        return
    end
    local stageQueue = self._stageQueues[stageId]
    if stageQueue then
        stageQueue.lastSeenOnPadAtByUserId[player.UserId] = os.clock()
    end
end

function QueueService:_syncQueuePresence()
    local now = os.clock()
    local graceSeconds = tonumber(self._config.QUEUE_LEAVE_GRACE_SECONDS) or 0.75
    if graceSeconds < 0.1 then
        graceSeconds = 0.1
    end
    local countdownGraceSeconds = tonumber(self._config.QUEUE_COUNTDOWN_LEAVE_GRACE_SECONDS)
    if not countdownGraceSeconds then
        countdownGraceSeconds = math.max(graceSeconds, 2)
    end
    if countdownGraceSeconds < graceSeconds then
        countdownGraceSeconds = graceSeconds
    end

    for _, player in ipairs(Players:GetPlayers()) do
        local stageIdOnPad = self:_resolvePlayerStageFromPad(player)
        local priorStageId = self._playerStageByUserId[player.UserId]
        if stageIdOnPad then
            if priorStageId and priorStageId ~= stageIdOnPad then
                self:_removeQueuedPlayerFromStage(player.UserId, priorStageId)
            end
            self:_addQueuedPlayerToStage(player, stageIdOnPad, {
                stageId = stageIdOnPad,
                actId = tostring(self._config.DEFAULT_ACT_ID or 'Act1'),
                stageLabel = stageIdOnPad,
                implemented = true,
            })
            local stageQueue = self._stageQueues[stageIdOnPad]
            if stageQueue then
                stageQueue.lastSeenOnPadAtByUserId[player.UserId] = now
            end
        end
    end

    for _, stageId in ipairs(self._stageOrder) do
        local stageQueue = self._stageQueues[stageId]
        if stageQueue and stageQueue.state ~= 'Locked' then
            local removeUserIds = {}
            local effectiveGraceSeconds = stageQueue.countdownActive and countdownGraceSeconds or graceSeconds
            for userId in pairs(stageQueue.queuedByUserId) do
                local lastSeenAt = stageQueue.lastSeenOnPadAtByUserId[userId]
                if not lastSeenAt or (now - lastSeenAt) > effectiveGraceSeconds then
                    table.insert(removeUserIds, userId)
                end
            end
            for _, userId in ipairs(removeUserIds) do
                self:_removeQueuedPlayerFromStage(userId, stageId)
            end
        end
    end
end

function QueueService:_startPresenceLoop(runId: number)
    local intervalSeconds = tonumber(self._config.QUEUE_PRESENCE_SAMPLE_INTERVAL_SECONDS) or 0.1
    if intervalSeconds < 0.05 then
        intervalSeconds = 0.05
    end

    task.spawn(function()
        while self._running and self._runId == runId do
            self:_syncQueuePresence()
            task.wait(intervalSeconds)
        end
    end)
end

function QueueService:start()
    if self._running then
        return
    end

    self._running = true
    self._runId += 1
    self._nextCorrelationOrdinal = 0
    table.clear(self._requestBuckets)
    table.clear(self._requestDedupByUserId)
    self:_initializeStageQueues()

    local lobby = Workspace:FindFirstChild('lobby')
    for _, stageId in ipairs(self._stageOrder) do
        local stageQueue = self._stageQueues[stageId]
        local queuePad = nil
        if lobby then
            local found = findThroughSameNameWrappers(lobby, stageQueue.queuePadName)
            if found and found:IsA('BasePart') then
                queuePad = found
            end
        end
        if not queuePad then
            warn(
                ('[QueueService] QueuePad not found at Workspace/lobby/%s for stage %s'):format(
                    stageQueue.queuePadName,
                    stageId
                )
            )
        else
            stageQueue.queuePad = queuePad
            table.insert(
                self._connections,
                queuePad.Touched:Connect(function(hitPart)
                    if self._running and hitPart:IsA('BasePart') then
                        self:_onQueuePadTouched(stageId, hitPart)
                    end
                end)
            )
            table.insert(
                self._connections,
                queuePad.TouchEnded:Connect(function(hitPart)
                    if self._running and hitPart:IsA('BasePart') then
                        self:_onQueuePadTouchEnded(stageId, hitPart)
                    end
                end)
            )
        end
    end

    table.insert(
        self._connections,
        Players.PlayerRemoving:Connect(function(player)
            self:_removeQueuedPlayerByUserId(player.UserId)
        end)
    )

    self._remotes.createMatch = getRemoteEvent(self._net.ClientToServer.RequestCreateMatch, 5)
    self._remotes.ready = getRemoteEvent(self._net.ClientToServer.RequestReady, 5)
    if self._remotes.createMatch then
        table.insert(
            self._connections,
            self._remotes.createMatch.OnServerEvent:Connect(function(player, payload)
                if self._running then
                    self:_handleRequestCreateMatch(player, payload)
                end
            end)
        )
    end
    if self._remotes.ready then
        table.insert(
            self._connections,
            self._remotes.ready.OnServerEvent:Connect(function(player, payload)
                if self._running then
                    self:_handleRequestReady(player, payload)
                end
            end)
        )
    end

    for _, stageId in ipairs(self._stageOrder) do
        self:_evaluateCountdown(stageId)
    end
    self:_startPresenceLoop(self._runId)
end

function QueueService:stop()
    if not self._running then
        return
    end

    self._running = false
    self._runId += 1
    for _, connection in ipairs(self._connections) do
        connection:Disconnect()
    end
    table.clear(self._connections)
    table.clear(self._remotes)
    table.clear(self._requestBuckets)
    table.clear(self._requestDedupByUserId)
    self:_initializeStageQueues()
end

function QueueService:getQueueSize(): number
    local total = 0
    for _, stageId in ipairs(self._stageOrder) do
        total += self:_getStageQueueSize(stageId)
    end
    return total
end

function QueueService:getState(): string
    if self._lockedQueueStageId then
        return 'Locked'
    end
    for _, stageId in ipairs(self._stageOrder) do
        local stageQueue = self._stageQueues[stageId]
        if stageQueue and stageQueue.countdownActive then
            return 'CountingDown'
        end
    end
    if self:getQueueSize() > 0 then
        return 'Queued'
    end
    return 'Idle'
end

function QueueService:getLockedRoster(): { Player }
    if not self._lockedQueueStageId then
        return {}
    end
    local stageQueue = self._stageQueues[self._lockedQueueStageId]
    if not stageQueue then
        return {}
    end
    local snapshot = {}
    for _, player in ipairs(stageQueue.lockedRoster) do
        if player and player.Parent == Players then
            table.insert(snapshot, player)
        end
    end
    return snapshot
end

function QueueService:takeLockedRoster(): ({ Player }, table?)
    if not self._lockedQueueStageId then
        return {}, nil
    end

    local stageId = self._lockedQueueStageId
    local stageQueue = self._stageQueues[stageId]
    if not stageQueue then
        self._lockedQueueStageId = nil
        return {}, nil
    end

    local rosterSnapshot = self:getLockedRoster()
    local stageSelection = if type(stageQueue.lockedStageSelection) == 'table'
        then table.clone(stageQueue.lockedStageSelection)
        else nil

    table.clear(stageQueue.lockedRoster)
    stageQueue.lockedStageSelection = nil
    stageQueue.state = 'Idle'
    stageQueue.countdownActive = false
    stageQueue.countdownTimeRemaining = nil
    self._lockedQueueStageId = nil

    return rosterSnapshot, stageSelection
end

function QueueService:getSnapshot()
    local selectedStageId = self._lockedQueueStageId
    local queueState = self:getState()
    local size = 0
    local readyCount = 0
    local countdownActive = false
    local countdownTimeRemaining = nil
    local selectedActId = nil

    if selectedStageId then
        local stageQueue = self._stageQueues[selectedStageId]
        if stageQueue then
            size = #stageQueue.lockedRoster
            readyCount = size
            countdownActive = false
            countdownTimeRemaining = 0
            selectedActId = stageQueue.lockedStageSelection and stageQueue.lockedStageSelection.actId or nil
        end
    else
        for _, stageId in ipairs(self._stageOrder) do
            local stageQueue = self._stageQueues[stageId]
            if stageQueue and stageQueue.countdownActive then
                selectedStageId = stageId
                size = self:_getStageQueueSize(stageId)
                readyCount = self:_getStageReadyCount(stageId)
                countdownActive = true
                countdownTimeRemaining = stageQueue.countdownTimeRemaining
                break
            end
        end
        if not selectedStageId then
            for _, stageId in ipairs(self._stageOrder) do
                local stageSize = self:_getStageQueueSize(stageId)
                if stageSize > 0 then
                    selectedStageId = stageId
                    size = stageSize
                    readyCount = self:_getStageReadyCount(stageId)
                    break
                end
            end
        end
    end

    local queueByStage = {}
    for _, stageId in ipairs(self._stageOrder) do
        local stageQueue = self._stageQueues[stageId]
        queueByStage[stageId] = {
            state = stageQueue and stageQueue.state or 'Idle',
            size = self:_getStageQueueSize(stageId),
            readyCount = self:_getStageReadyCount(stageId),
            countdownActive = stageQueue and stageQueue.countdownActive or false,
            countdownTimeRemaining = stageQueue and stageQueue.countdownTimeRemaining or nil,
            queuePadName = stageQueue and stageQueue.queuePadName or nil,
        }
    end

    return {
        state = queueState,
        size = size,
        readyCount = readyCount,
        countdownActive = countdownActive,
        countdownTimeRemaining = countdownTimeRemaining,
        selectedStageId = selectedStageId,
        selectedActId = selectedActId,
        queuesByStage = queueByStage,
    }
end

return QueueService
