local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ServerStorage = game:GetService('ServerStorage')
local Workspace = game:GetService('Workspace')
local HttpService = game:GetService('HttpService')
local CollectionService = game:GetService('CollectionService')

local TowerPlacementService = {}
TowerPlacementService.__index = TowerPlacementService

local ALLOWED_TOWER_TARGET_MODES = {
    First = true,
    Last = true,
    Closest = true,
}

local TRUST_REJECT_REASON_CODES = {
    MISSING_TOWER_ID = true,
    INVALID_TOWER_ID = true,
    INVALID_TOWER_REF = true,
    TOWER_ID_MISMATCH = true,
    TOWER_NOT_FOUND = true,
    MISSING_OWNER_USER_ID = true,
    INVALID_OWNER_USER_ID = true,
    NOT_OWNER = true,
}

type RejectDetails = {
    requestType: string,
    reasonCode: string,
    message: string,
}

function TowerPlacementService.new(gameConfig, net)
    return setmetatable({
        _config = gameConfig,
        _net = net,
        _playerDataService = nil,
        _activeMapName = tostring(gameConfig.ACTIVE_MAP_NAME or gameConfig.DEFAULT_STAGE_ID or 'brown'),
        _roundService = nil,
        _running = false,
        _runId = 0,
        _connections = {},
        _occupiedCells = {},
        _requestBuckets = {},
        _processedRequestIds = {},
        _missionRewardClaimsByUserId = {},
        _playerEconomy = {},
        _nextTowerId = 1,
        _nextCorrelationOrdinal = 0,
        _activeRequestContextByUserId = {},
        _activeDifficulty = 'Normal',
        _activeDifficultyPreset = 'Normal',
        _difficultyEconomyMultipliers = {
            killRewardMultiplier = 1.0,
            roundRewardMultiplier = 1.0,
            towerCostMultiplier = 1.0,
            upgradeCostMultiplier = 1.0,
            sellRefundMultiplier = 1.0,
        },
        _telemetry = {
            towerPicksByType = {},
            failReasons = {},
            trustRejects = {},
            missionRewardsPaid = 0,
            missionClaimsBlocked = 0,
        },
    }, TowerPlacementService)
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
        service = 'TowerPlacementService',
        kind = kind,
        payload = payload,
    }
end

function TowerPlacementService:_sanitizeCorrelationId(value): string?
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

function TowerPlacementService:_nextCorrelationId(requestType: string, userId: number): string
    self._nextCorrelationOrdinal += 1
    return ('tp-%d-%s-%d'):format(userId, tostring(requestType or 'request'), self._nextCorrelationOrdinal)
end

function TowerPlacementService:_resolveCorrelationId(player: Player, requestType: string, payload): string
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

function TowerPlacementService:_getRequestContext(player: Player)
    return self._activeRequestContextByUserId[player.UserId]
end

function TowerPlacementService:_emitTowerActionTelemetry(payload)
    print(('[Telemetry][TowerPlacementAction] %s'):format(jsonEncode(toTelemetryEnvelope('TowerAction', payload))))
end

local function tableKeyCount(value): number
    local count = 0
    for _ in pairs(value) do
        count += 1
    end
    return count
end

local function isFiniteNumber(value: number): boolean
    if value ~= value then
        return false
    end
    if value == math.huge or value == -math.huge then
        return false
    end
    return true
end

local function isFiniteVector3(value: Vector3): boolean
    return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

function TowerPlacementService:setActiveMapName(mapName: string)
    if type(mapName) == 'string' and mapName ~= '' then
        self._activeMapName = mapName
    end
end

function TowerPlacementService:_getActiveMapFolder(): Instance?
    return Workspace:FindFirstChild(self._activeMapName)
end

function TowerPlacementService:_getRemoteEvent(remoteName: string): RemoteEvent?
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

function TowerPlacementService:_emitTowerPlacementFailed(player: Player, details: RejectDetails)
    local requestContext = self:_getRequestContext(player)
    if details and details.reasonCode then
        self._telemetry.failReasons[details.reasonCode] = (self._telemetry.failReasons[details.reasonCode] or 0) + 1
        if TRUST_REJECT_REASON_CODES[details.reasonCode] then
            self._telemetry.trustRejects[details.reasonCode] = (self._telemetry.trustRejects[details.reasonCode] or 0)
                + 1
        end
    end

    local remoteName = self._net.ServerToClient.TowerPlacementFailed
    local failureRemote = self:_getRemoteEvent(remoteName)
    if not failureRemote then
        self:_emitTowerActionTelemetry({
            event = 'REJECTED',
            requestType = details.requestType,
            reasonCode = details.reasonCode,
            reasonMessage = details.message,
            userId = player.UserId,
            correlationId = requestContext and requestContext.correlationId or nil,
        })
        return
    end

    self:_emitTowerActionTelemetry({
        event = 'REJECTED',
        requestType = details.requestType,
        reasonCode = details.reasonCode,
        reasonMessage = details.message,
        userId = player.UserId,
        correlationId = requestContext and requestContext.correlationId or nil,
    })
    failureRemote:FireClient(player, details)
end

function TowerPlacementService:_rejectNotImplemented(player: Player, requestType: string, message: string)
    self:_emitTowerPlacementFailed(player, {
        requestType = requestType,
        reasonCode = 'NOT_IMPLEMENTED',
        message = message,
    })
end

function TowerPlacementService:_rejectInvalidPayload(player: Player, requestType: string)
    self:_emitTowerPlacementFailed(player, {
        requestType = requestType,
        reasonCode = 'INVALID_PAYLOAD',
        message = 'Payload must be a table.',
    })
end

function TowerPlacementService:_reject(player: Player, requestType: string, reasonCode: string, message: string)
    self:_emitTowerPlacementFailed(player, {
        requestType = requestType,
        reasonCode = reasonCode,
        message = message,
    })
end

function TowerPlacementService:_getRoundPhase(): string?
    if not self._roundService then
        return nil
    end

    if type(self._roundService.getPhase) ~= 'function' then
        return nil
    end

    return self._roundService:getPhase()
end

function TowerPlacementService:_isPlayerInActiveRoundRoster(player: Player): boolean
    if not self._roundService then
        return true
    end

    if type(self._roundService.isPlayerInActiveRoster) ~= 'function' then
        return true
    end

    return self._roundService:isPlayerInActiveRoster(player)
end

function TowerPlacementService:_isTowerActionWindowOpen(): boolean
    if not self._roundService then
        return true
    end

    if type(self._roundService.isAcceptingTowerActions) ~= 'function' then
        return true
    end

    return self._roundService:isAcceptingTowerActions()
end

function TowerPlacementService:_getMapModel(): Instance?
    return Workspace:FindFirstChild(self._activeMapName)
end

function TowerPlacementService:_getPlayerRoot(player: Player): BasePart?
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

function TowerPlacementService:_isPlayerWithinTowerInteractDistance(player: Player, towerModel: Model): boolean
    local playerRoot = self:_getPlayerRoot(player)
    if not playerRoot then
        return false
    end

    local towerRoot = self:_getModelRoot(towerModel)
    if not towerRoot then
        return false
    end

    local maxDistance = tonumber(self._config.TOWER_MAX_INTERACT_DISTANCE)
    if not maxDistance then
        maxDistance = tonumber(self._config.TOWER_MAX_PLACE_DISTANCE) or 45
    end
    if maxDistance < 1 then
        maxDistance = 1
    end

    local distance = (playerRoot.Position - towerRoot.Position).Magnitude
    return distance <= maxDistance
end

function TowerPlacementService:_getTowerModelsFolder(): Instance?
    local schema = self._config.TOWER_MODEL_SCHEMA
    local containerName = 'TowerModels'
    if type(schema) == 'table' and type(schema.modelContainerName) == 'string' and schema.modelContainerName ~= '' then
        containerName = schema.modelContainerName
    end
    return ServerStorage:FindFirstChild(containerName)
end

function TowerPlacementService:_getTowerRootCandidates(model: Model): { string }
    local schema = self._config.TOWER_MODEL_SCHEMA
    local candidates = {}
    local seen = {}

    local function pushName(name)
        if type(name) == 'string' and name ~= '' and not seen[name] then
            seen[name] = true
            table.insert(candidates, name)
        end
    end

    if type(schema) == 'table' then
        pushName(schema.baseRootPartName)
        if type(schema.rootPartNameCandidates) == 'table' then
            for _, candidateName in ipairs(schema.rootPartNameCandidates) do
                pushName(candidateName)
            end
        end
    end

    local towerType = model:GetAttribute('TowerType')
    if type(towerType) == 'string' and towerType ~= '' and type(schema) == 'table' and type(schema.towers) == 'table' then
        local towerSpec = schema.towers[towerType]
        if type(towerSpec) == 'table' then
            pushName(towerSpec.rootPartName)
        end
    end

    pushName('HumanoidRootPart')
    pushName('Body')
    pushName('UpperTorso')
    pushName('Torso')

    return candidates
end

function TowerPlacementService:_getTowerTemplate(towerType: string): Model?
    local towerModelsFolder = self:_getTowerModelsFolder()
    if not towerModelsFolder then
        return nil
    end

    local expectedTemplateName = towerType
    local schema = self._config.TOWER_MODEL_SCHEMA
    if type(schema) == 'table' and type(schema.towers) == 'table' then
        local towerSpec = schema.towers[towerType]
        if type(towerSpec) == 'table' and type(towerSpec.templateName) == 'string' and towerSpec.templateName ~= '' then
            expectedTemplateName = towerSpec.templateName
        end
    end

    local template = towerModelsFolder:FindFirstChild(expectedTemplateName)
    if template and template:IsA('Model') then
        return template
    end

    local aliases = self._config.TOWER_TEMPLATE_ALIASES
    if type(aliases) == 'table' then
        local aliasType = aliases[towerType]
        if type(aliasType) == 'string' and aliasType ~= '' then
            local aliasedTemplate = towerModelsFolder:FindFirstChild(aliasType)
            if aliasedTemplate and aliasedTemplate:IsA('Model') then
                return aliasedTemplate
            end
        end
    end

    return nil
end

function TowerPlacementService:_getTowerSchemaSpec(towerType: string)
    local schema = self._config.TOWER_MODEL_SCHEMA
    if type(schema) ~= 'table' or type(schema.towers) ~= 'table' then
        return nil
    end
    local towerSpec = schema.towers[towerType]
    if type(towerSpec) ~= 'table' then
        return nil
    end
    return towerSpec
end

function TowerPlacementService:_getOrCreateTowersFolder(): Folder?
    local map = self:_getMapModel()
    if not map then
        return nil
    end

    local existing = map:FindFirstChild('Towers')
    if existing and existing:IsA('Folder') then
        return existing
    end

    local created = Instance.new('Folder')
    created.Name = 'Towers'
    created.Parent = map
    return created
end

function TowerPlacementService:_getModelRoot(model: Model): BasePart?
    if model.PrimaryPart then
        return model.PrimaryPart
    end

    for _, candidateName in ipairs(self:_getTowerRootCandidates(model)) do
        local candidate = model:FindFirstChild(candidateName, true)
        if candidate and candidate:IsA('BasePart') then
            model.PrimaryPart = candidate
            return candidate
        end
    end

    local firstPart = model:FindFirstChildWhichIsA('BasePart', true)
    if firstPart then
        model.PrimaryPart = firstPart
    end

    return model.PrimaryPart
end

function TowerPlacementService:_computeWorldGridSnap(position: Vector3, gridSize: number): (number, number, Vector3)
    local gx = math.floor((position.X / gridSize) + 0.5)
    local gz = math.floor((position.Z / gridSize) + 0.5)
    return gx, gz, Vector3.new(gx * gridSize, position.Y, gz * gridSize)
end

function TowerPlacementService:_isBlockedByFolderRule(instance: Instance): boolean
    local blockedFolderNames = self._config.PLACEMENT_BLOCKED_FOLDER_NAMES
    if type(blockedFolderNames) ~= 'table' then
        return false
    end
    local current = instance
    while current and current ~= Workspace do
        for _, folderName in ipairs(blockedFolderNames) do
            if type(folderName) == 'string' and folderName ~= '' and current.Name == folderName then
                return true
            end
        end
        current = current.Parent
    end
    return false
end

function TowerPlacementService:_isBlockedByTagRule(instance: Instance): boolean
    local blockedTags = self._config.PLACEMENT_BLOCKED_TAGS
    if type(blockedTags) ~= 'table' then
        return false
    end
    local current = instance
    while current and current ~= Workspace do
        for _, tagName in ipairs(blockedTags) do
            if type(tagName) == 'string' and tagName ~= '' and CollectionService:HasTag(current, tagName) then
                return true
            end
        end
        current = current.Parent
    end
    return false
end

function TowerPlacementService:_isSurfaceBlocked(instance: Instance): boolean
    if self:_isBlockedByFolderRule(instance) then
        return true
    end
    if self:_isBlockedByTagRule(instance) then
        return true
    end
    return false
end

function TowerPlacementService:_getTowerPlacementHeight(towerType: string): number
    local footprintByType = self._config.TOWER_FOOTPRINT_BY_TYPE
    if type(footprintByType) == 'table' then
        local footprint = footprintByType[towerType]
        if type(footprint) == 'table' then
            local y = tonumber(footprint.y)
            if y and y > 0 then
                return y
            end
        end
    end
    return 4
end

function TowerPlacementService:_buildPlacementRaycastParams(player: Player): RaycastParams
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignoreList = {}
    if player.Character then
        table.insert(ignoreList, player.Character)
    end
    local towersFolder = self:_getTowersFolder()
    if towersFolder then
        table.insert(ignoreList, towersFolder)
    end
    params.FilterDescendantsInstances = ignoreList
    return params
end

function TowerPlacementService:_resolvePlacementSurface(
    player: Player,
    requestedPosition: Vector3,
    towerType: string
): (boolean, string?, string?, Vector3?, string?, number?, number?)
    local map = self:_getMapModel()
    if not map then
        return false, 'INVALID_SURFACE', 'Map is unavailable.', nil, nil, nil, nil
    end

    local gridSize = tonumber(self._config.TOWER_PLACEMENT_GRID_SIZE) or 4
    if gridSize <= 0 then
        gridSize = 4
    end

    local surfaceMode = tostring(self._config.PLACEMENT_SURFACE_MODE or 'AnySurfaceExceptBlocked')
    local params = self:_buildPlacementRaycastParams(player)
    local surfaceProbe = Workspace:Raycast(
        requestedPosition + Vector3.new(0, 128, 0),
        Vector3.new(0, -1024, 0),
        params
    )
    if not surfaceProbe then
        return false, 'INVALID_SURFACE', 'No buildable surface found.', nil, nil, nil, nil
    end

    if surfaceProbe.Instance:IsA('Terrain') and self._config.PLACEMENT_ALLOW_TERRAIN == false then
        return false, 'INVALID_SURFACE', 'Terrain placement is disabled.', nil, nil, nil, nil
    end
    if surfaceMode == 'TerrainOnlyExceptBlocked' and not surfaceProbe.Instance:IsA('Terrain') then
        return false, 'INVALID_SURFACE', 'Placement is restricted to terrain.', nil, nil, nil, nil
    end
    if self:_isSurfaceBlocked(surfaceProbe.Instance) then
        return false, 'BLOCKED_SURFACE', 'Cannot place on blocked build zones.', nil, nil, nil, nil
    end

    local gx, gz, snappedXZ = self:_computeWorldGridSnap(surfaceProbe.Position, gridSize)
    local snappedProbe = Workspace:Raycast(
        Vector3.new(snappedXZ.X, surfaceProbe.Position.Y + 256, snappedXZ.Z),
        Vector3.new(0, -1024, 0),
        params
    )
    if not snappedProbe then
        return false, 'INVALID_SURFACE', 'Snapped cell has no valid surface.', nil, nil, nil, nil
    end
    if snappedProbe.Instance:IsA('Terrain') and self._config.PLACEMENT_ALLOW_TERRAIN == false then
        return false, 'INVALID_SURFACE', 'Terrain placement is disabled.', nil, nil, nil, nil
    end
    if surfaceMode == 'TerrainOnlyExceptBlocked' and not snappedProbe.Instance:IsA('Terrain') then
        return false, 'INVALID_SURFACE', 'Placement is restricted to terrain.', nil, nil, nil, nil
    end
    if self:_isSurfaceBlocked(snappedProbe.Instance) then
        return false, 'BLOCKED_SURFACE', 'Cannot place on blocked build zones.', nil, nil, nil, nil
    end

    local placementHeight = self:_getTowerPlacementHeight(towerType)
    local snappedWorldPosition = Vector3.new(snappedXZ.X, snappedProbe.Position.Y + (placementHeight * 0.5), snappedXZ.Z)
    local cellKey = ('%s:%d:%d'):format(tostring(self._activeMapName), gx, gz)

    return true, nil, nil, snappedWorldPosition, cellKey, gx, gz
end

function TowerPlacementService:_isCellOccupied(cellKey: string): boolean
    if self._occupiedCells[cellKey] then
        return true
    end

    local map = self:_getMapModel()
    if not map then
        return false
    end

    local towersFolder = map:FindFirstChild('Towers')
    if not towersFolder then
        return false
    end

    for _, descendant in ipairs(towersFolder:GetDescendants()) do
        if descendant:IsA('Model') and descendant:GetAttribute('PlacementCellKey') == cellKey then
            return true
        end
    end

    return false
end

function TowerPlacementService:_countRuntimeTowersForUser(userId: number): number
    local towersFolder = self:_getTowersFolder()
    if not towersFolder then
        return 0
    end

    local count = 0
    for _, child in ipairs(towersFolder:GetChildren()) do
        if child:IsA('Model') and tonumber(child:GetAttribute('OwnerUserId')) == userId then
            count += 1
        end
    end
    return count
end

function TowerPlacementService:_countRuntimeTowersTotal(): number
    local towersFolder = self:_getTowersFolder()
    if not towersFolder then
        return 0
    end

    local count = 0
    for _, child in ipairs(towersFolder:GetChildren()) do
        if child:IsA('Model') then
            count += 1
        end
    end
    return count
end

function TowerPlacementService:_getTowersFolder(): Instance?
    local map = self:_getMapModel()
    if not map then
        return nil
    end

    return map:FindFirstChild('Towers')
end

function TowerPlacementService:_cleanupRuntimeTowers()
    local towersFolder = self:_getTowersFolder()
    if not towersFolder then
        return 0
    end

    local removedCount = 0
    for _, child in ipairs(towersFolder:GetChildren()) do
        if child:IsA('Model') then
            child:Destroy()
            removedCount += 1
        end
    end
    return removedCount
end

function TowerPlacementService:_findTowerModelById(towerId: string): Model?
    local towersFolder = self:_getTowersFolder()
    if not towersFolder then
        return nil
    end

    for _, descendant in ipairs(towersFolder:GetDescendants()) do
        if descendant:IsA('Model') then
            local attrTowerId = descendant:GetAttribute('TowerId')
            if attrTowerId ~= nil and tostring(attrTowerId) == towerId then
                return descendant
            end
        end
    end

    return nil
end

function TowerPlacementService:_isRuntimeTowerModel(towerModel: Model): boolean
    local towersFolder = self:_getTowersFolder()
    if not towersFolder then
        return false
    end
    if not towerModel:IsDescendantOf(towersFolder) then
        return false
    end

    local towerId = towerModel:GetAttribute('TowerId')
    if towerId == nil then
        return false
    end

    return true
end

function TowerPlacementService:_normalizeTowerIdForLookup(towerIdRaw): (string?, string?)
    if type(towerIdRaw) ~= 'string' and type(towerIdRaw) ~= 'number' then
        return nil, 'INVALID_TOWER_ID'
    end

    local normalized = tostring(towerIdRaw)
    if normalized == '' then
        return nil, 'INVALID_TOWER_ID'
    end
    if #normalized > 64 then
        return nil, 'INVALID_TOWER_ID'
    end
    if not string.match(normalized, '^[%w%-_]+$') then
        return nil, 'INVALID_TOWER_ID'
    end
    if not string.match(normalized, '^tower%-%d+$') then
        return nil, 'INVALID_TOWER_ID'
    end

    return normalized, nil
end

function TowerPlacementService:_resolvePayloadTowerModel(payload): (Model?, string?, string?)
    local towerId = payload.towerId
    if towerId == nil then
        return nil, 'MISSING_TOWER_ID', 'towerId is required.'
    end

    local normalizedTowerId, idErr = self:_normalizeTowerIdForLookup(towerId)
    if not normalizedTowerId then
        return nil, idErr or 'INVALID_TOWER_ID', 'towerId format is invalid.'
    end

    if payload.towerModel ~= nil then
        if typeof(payload.towerModel) ~= 'Instance' or not payload.towerModel:IsA('Model') then
            return nil, 'INVALID_TOWER_REF', 'towerModel must be a runtime tower model when provided.'
        end
        if not self:_isRuntimeTowerModel(payload.towerModel) then
            return nil, 'TOWER_NOT_FOUND', 'towerModel does not resolve to a live runtime tower.'
        end
        local payloadTowerId = payload.towerModel:GetAttribute('TowerId')
        if payloadTowerId == nil or tostring(payloadTowerId) ~= normalizedTowerId then
            return nil, 'TOWER_ID_MISMATCH', 'towerModel and towerId must reference the same tower.'
        end
        return payload.towerModel, nil, nil
    end

    local towerModel = self:_findTowerModelById(normalizedTowerId)
    if not towerModel then
        return nil, 'TOWER_NOT_FOUND', 'towerId does not map to a live runtime tower.'
    end

    return towerModel, nil, nil
end

function TowerPlacementService:_validateTowerOwnership(towerModel: Model, player: Player): (boolean, string?, string?)
    local ownerUserId = towerModel:GetAttribute('OwnerUserId')
    if ownerUserId == nil then
        return false, 'MISSING_OWNER_USER_ID', 'Tower is missing OwnerUserId ownership attribute.'
    end
    if type(ownerUserId) ~= 'number' then
        return false, 'INVALID_OWNER_USER_ID', 'Tower OwnerUserId ownership attribute is invalid.'
    end
    if ownerUserId ~= player.UserId then
        return false, 'NOT_OWNER', 'You do not own this tower.'
    end
    return true, nil, nil
end

function TowerPlacementService:_emitEconomyUpdated(player: Player)
    local remoteName = self._net.ServerToClient.EconomyUpdated
    local economyRemote = self:_getRemoteEvent(remoteName)
    if not economyRemote then
        return
    end

    local currency = self._playerEconomy[player.UserId] or 0
    economyRemote:FireClient(player, {
        currency = currency,
    })
end

function TowerPlacementService:_emitTowerPlaced(payload)
    local remoteName = self._net.ServerToClient.TowerPlaced
    local towerPlacedRemote = self:_getRemoteEvent(remoteName)
    if not towerPlacedRemote then
        return
    end

    towerPlacedRemote:FireAllClients(payload)
end

function TowerPlacementService:_emitTowerRemoved(payload)
    local remoteName = self._net.ServerToClient.TowerRemoved
    local towerRemovedRemote = self:_getRemoteEvent(remoteName)
    if not towerRemovedRemote then
        return
    end

    towerRemovedRemote:FireAllClients(payload)
end

function TowerPlacementService:_emitTowerUpdated(payload)
    local remoteName = self._net.ServerToClient.TowerUpdated
    local towerUpdatedRemote = self:_getRemoteEvent(remoteName)
    if not towerUpdatedRemote then
        return
    end

    towerUpdatedRemote:FireAllClients(payload)
end

function TowerPlacementService:_initializePlayerEconomy(player: Player)
    if self._playerEconomy[player.UserId] == nil then
        local startingCurrency = self._config.STARTING_CURRENCY or 0
        if self._playerDataService and type(self._playerDataService.getCurrency) == 'function' then
            startingCurrency = self._playerDataService:getCurrency(player.UserId)
        end
        self._playerEconomy[player.UserId] = math.max(0, math.floor(tonumber(startingCurrency) or 0))
    end
    self:_emitEconomyUpdated(player)
end

function TowerPlacementService:_trySpendCurrency(player: Player, amount: number): (boolean, number)
    local currentBalance = self._playerEconomy[player.UserId]
    if currentBalance == nil then
        currentBalance = self._config.STARTING_CURRENCY or 0
        self._playerEconomy[player.UserId] = currentBalance
    end

    if amount > currentBalance then
        return false, currentBalance
    end

    self._playerEconomy[player.UserId] = currentBalance - amount
    if self._playerDataService and type(self._playerDataService.setCurrency) == 'function' then
        self._playerDataService:setCurrency(player.UserId, self._playerEconomy[player.UserId])
    end
    return true, self._playerEconomy[player.UserId]
end

function TowerPlacementService:_refundCurrency(player: Player, amount: number)
    local currentBalance = self._playerEconomy[player.UserId] or (self._config.STARTING_CURRENCY or 0)
    self._playerEconomy[player.UserId] = currentBalance + amount
    if self._playerDataService and type(self._playerDataService.setCurrency) == 'function' then
        self._playerDataService:setCurrency(player.UserId, self._playerEconomy[player.UserId])
    end
end

function TowerPlacementService:_addCurrency(player: Player, amount: number): number
    local currentBalance = self._playerEconomy[player.UserId]
    if currentBalance == nil then
        currentBalance = self._config.STARTING_CURRENCY or 0
    end
    self._playerEconomy[player.UserId] = currentBalance + amount
    if self._playerDataService and type(self._playerDataService.setCurrency) == 'function' then
        self._playerDataService:setCurrency(player.UserId, self._playerEconomy[player.UserId])
    end
    return self._playerEconomy[player.UserId]
end

function TowerPlacementService:_computeTowerSellRefund(towerModel: Model): number
    local baseCost = tonumber(towerModel:GetAttribute('CostPaid'))
    if not baseCost then
        local towerType = towerModel:GetAttribute('TowerType')
        if type(towerType) == 'string' and type(self._config.TOWER_COSTS) == 'table' then
            baseCost = tonumber(self._config.TOWER_COSTS[towerType])
        end
    end
    if not baseCost or baseCost < 0 then
        baseCost = 0
    end

    local ratio = tonumber(self._config.TOWER_SELL_REFUND_RATIO)
    if not ratio then
        ratio = 0.7
    end
    if ratio < 0 then
        ratio = 0
    end
    local sellRefundMultiplier = tonumber(self._difficultyEconomyMultipliers.sellRefundMultiplier) or 1
    if sellRefundMultiplier < 0 then
        sellRefundMultiplier = 0
    end
    ratio *= sellRefundMultiplier
    if ratio > 1 then
        ratio = 1
    end

    return math.floor(baseCost * ratio)
end

function TowerPlacementService:_computeTowerUpgradeCost(towerModel: Model, nextTier: number): number
    local baseCost = tonumber(towerModel:GetAttribute('CostPaid'))
    if not baseCost then
        local towerType = towerModel:GetAttribute('TowerType')
        if type(towerType) == 'string' and type(self._config.TOWER_COSTS) == 'table' then
            baseCost = tonumber(self._config.TOWER_COSTS[towerType])
        end
    end
    if not baseCost or baseCost < 0 then
        baseCost = 0
    end

    local multiplier = tonumber(self._config.TOWER_UPGRADE_COST_MULTIPLIER) or 1.5
    if multiplier < 1 then
        multiplier = 1
    end

    local exponent = math.max(0, nextTier - 1)
    local configuredCost = math.floor(baseCost * (multiplier ^ exponent))
    local difficultyMultiplier = tonumber(self._difficultyEconomyMultipliers.upgradeCostMultiplier) or 1
    if difficultyMultiplier < 0.1 then
        difficultyMultiplier = 0.1
    end
    return math.max(1, math.floor(configuredCost * difficultyMultiplier))
end

function TowerPlacementService:_computeTowerTierStats(towerType: string, tier: number): (number, number, number)
    local baseDamage = tonumber(self._config.TOWER_DEFAULT_DAMAGE) or 10
    local baseRange = tonumber(self._config.TOWER_DEFAULT_RANGE) or 20
    local baseAttackInterval = tonumber(self._config.TOWER_ATTACK_INTERVAL_SECONDS) or 1.0

    local damageMultiplier = tonumber(self._config.TOWER_UPGRADE_DAMAGE_MULTIPLIER) or 1.25
    local rangeMultiplier = tonumber(self._config.TOWER_UPGRADE_RANGE_MULTIPLIER) or 1.1
    local attackIntervalMultiplier = tonumber(self._config.TOWER_UPGRADE_ATTACK_INTERVAL_MULTIPLIER) or 0.92

    local effectiveTier = math.max(0, math.floor(tier))
    local damage = baseDamage * (damageMultiplier ^ effectiveTier)
    local range = baseRange * (rangeMultiplier ^ effectiveTier)
    local attackInterval = baseAttackInterval * (attackIntervalMultiplier ^ effectiveTier)

    local tierStatsByType = self._config.TOWER_STATS_BY_TYPE
    if type(tierStatsByType) == 'table' and type(towerType) == 'string' and towerType ~= '' then
        local typeStats = tierStatsByType[towerType]
        if type(typeStats) == 'table' then
            local configuredTierStats = typeStats[effectiveTier]
            if type(configuredTierStats) == 'table' then
                damage = tonumber(configuredTierStats.damage) or damage
                range = tonumber(configuredTierStats.range) or range
                attackInterval = tonumber(configuredTierStats.attackInterval) or attackInterval
            end
        end
    end

    -- Scaling rule: upgraded DPS towers (tier >= 1) can one-shot at least one configured enemy tier.
    local oneShotExcludedTypes = self._config.TOWER_ONE_SHOT_EXCLUDED_TYPES
    local isOneShotExcluded = false
    if type(oneShotExcludedTypes) == 'table' then
        isOneShotExcluded = oneShotExcludedTypes[towerType] == true
    end
    if effectiveTier >= 1 and not isOneShotExcluded then
        local targetSpawnOrdinal = tonumber(self._config.TOWER_ONE_SHOT_ENEMY_SPAWN_ORDINAL)
            or tonumber(self._config.ENEMIES_PER_MATCH)
            or 1
        local oneShotBuffer = tonumber(self._config.TOWER_ONE_SHOT_DAMAGE_BUFFER) or 1
        local enemyBaseHealth = tonumber(self._config.ENEMY_BASE_HEALTH) or 1
        local enemyPerSpawnHealth = tonumber(self._config.ENEMY_HEALTH_PER_SPAWN) or 0
        local maxSpawnOrdinal = tonumber(self._config.ENEMIES_PER_MATCH) or targetSpawnOrdinal
        maxSpawnOrdinal = math.max(1, math.floor(maxSpawnOrdinal))
        targetSpawnOrdinal = math.max(1, math.min(maxSpawnOrdinal, math.floor(targetSpawnOrdinal)))
        oneShotBuffer = math.max(0, math.floor(oneShotBuffer))

        local targetEnemyHealth = enemyBaseHealth + ((targetSpawnOrdinal - 1) * enemyPerSpawnHealth)
        local minimumOneShotDamage = math.max(1, targetEnemyHealth + oneShotBuffer)
        if damage < minimumOneShotDamage then
            damage = minimumOneShotDamage
        end
    end

    if attackInterval < 0.1 then
        attackInterval = 0.1
    end

    return damage, range, attackInterval
end

function TowerPlacementService:_validateRequestId(payload): (boolean, string?, string?)
    local requestId = payload and payload.requestId
    if requestId == nil then
        return true, nil, nil
    end

    if type(requestId) ~= 'string' then
        return false, nil, 'requestId must be a string.'
    end

    if requestId == '' then
        return false, nil, 'requestId must not be empty.'
    end

    if #requestId > 64 then
        return false, nil, 'requestId is too long.'
    end

    return true, requestId, nil
end

function TowerPlacementService:_pruneProcessedRequestIdsForPlayer(playerUserId: number, nowTime: number)
    local userProcessed = self._processedRequestIds[playerUserId]
    if not userProcessed then
        return
    end

    for key, expiresAt in pairs(userProcessed) do
        if expiresAt <= nowTime then
            userProcessed[key] = nil
        end
    end
end

function TowerPlacementService:_checkAndMarkDuplicateRequest(
    player: Player,
    requestType: string,
    payload
): (boolean, string?, string?)
    local isValid, requestId, errMessage = self:_validateRequestId(payload)
    if not isValid then
        return false, nil, errMessage
    end
    if not requestId then
        return true, nil, nil
    end

    local nowTime = os.clock()
    local userId = player.UserId
    local userProcessed = self._processedRequestIds[userId]
    if not userProcessed then
        userProcessed = {}
        self._processedRequestIds[userId] = userProcessed
    end
    self:_pruneProcessedRequestIdsForPlayer(userId, nowTime)

    local dedupWindowSeconds = tonumber(self._config.REQUEST_DEDUP_WINDOW_SECONDS) or 10
    if dedupWindowSeconds < 0.25 then
        dedupWindowSeconds = 0.25
    end

    local dedupKey = ('%s:%s'):format(requestType, requestId)
    local expiresAt = userProcessed[dedupKey]
    if expiresAt and expiresAt > nowTime then
        return false, dedupKey, nil
    end

    userProcessed[dedupKey] = nowTime + dedupWindowSeconds
    return true, dedupKey, nil
end

function TowerPlacementService:_checkAndConsumeRateLimit(player: Player, requestType: string): (boolean, string?)
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

function TowerPlacementService:_handleRequestPlaceTower(player: Player, payload)
    if type(payload) ~= 'table' then
        self:_rejectInvalidPayload(player, 'RequestPlaceTower')
        return
    end

    local towerType = payload.towerType
    if type(towerType) ~= 'string' or towerType == '' then
        self:_reject(player, 'RequestPlaceTower', 'INVALID_TOWER_TYPE', 'towerType is required.')
        return
    end
    if #towerType > 32 or not string.match(towerType, '^[%w_%-]+$') then
        self:_reject(player, 'RequestPlaceTower', 'INVALID_TOWER_TYPE', 'towerType format is invalid.')
        return
    end
    if type(self._config.TOWER_COSTS) ~= 'table' or self._config.TOWER_COSTS[towerType] == nil then
        self:_reject(player, 'RequestPlaceTower', 'UNKNOWN_TOWER_TYPE', 'Tower type is not configured.')
        return
    end

    local position = payload.position
    if typeof(position) ~= 'Vector3' then
        self:_reject(player, 'RequestPlaceTower', 'INVALID_POSITION', 'position must be a Vector3.')
        return
    end
    if not isFiniteVector3(position) then
        self:_reject(player, 'RequestPlaceTower', 'INVALID_POSITION', 'position must contain finite numbers.')
        return
    end
    local maxAbsPosition = tonumber(self._config.WORLD_MAX_ABS_POSITION) or 50000
    if maxAbsPosition < 100 then
        maxAbsPosition = 100
    end
    if
        math.abs(position.X) > maxAbsPosition
        or math.abs(position.Y) > maxAbsPosition
        or math.abs(position.Z) > maxAbsPosition
    then
        self:_reject(player, 'RequestPlaceTower', 'INVALID_POSITION', 'position is outside world bounds.')
        return
    end

    local rotationY = 0
    if payload.rotationY ~= nil then
        if type(payload.rotationY) ~= 'number' or not isFiniteNumber(payload.rotationY) then
            self:_reject(player, 'RequestPlaceTower', 'INVALID_ROTATION', 'rotationY must be a finite number.')
            return
        end
        local quarterTurns = math.floor((payload.rotationY / 90) + 0.5)
        rotationY = (quarterTurns % 4) * 90
    end

    local phase = self:_getRoundPhase()
    if phase ~= 'Wave' then
        self:_reject(player, 'RequestPlaceTower', 'INVALID_PHASE', 'Tower placement is only allowed during Wave.')
        return
    end
    if not self:_isTowerActionWindowOpen() then
        self:_reject(player, 'RequestPlaceTower', 'ACTION_WINDOW_CLOSED', 'Tower actions are locked for this round.')
        return
    end
    if not self:_isPlayerInActiveRoundRoster(player) then
        self:_reject(player, 'RequestPlaceTower', 'NOT_IN_MATCH_ROSTER', 'You are not in the active match roster.')
        return
    end

    local root = self:_getPlayerRoot(player)
    if not root then
        self:_reject(player, 'RequestPlaceTower', 'PLAYER_NOT_READY', 'Character root is not available.')
        return
    end

    local maxDistance = tonumber(self._config.TOWER_MAX_PLACE_DISTANCE) or 45
    if maxDistance < 1 then
        maxDistance = 1
    end
    local distance = (root.Position - position).Magnitude
    if distance > maxDistance then
        self:_reject(player, 'RequestPlaceTower', 'OUT_OF_RANGE', 'Placement is beyond max placement distance.')
        return
    end

    local surfaceOk, surfaceReasonCode, surfaceMessage, snappedWorldPosition, cellKey =
        self:_resolvePlacementSurface(player, position, towerType)
    if not surfaceOk then
        self:_reject(
            player,
            'RequestPlaceTower',
            surfaceReasonCode or 'INVALID_SURFACE',
            surfaceMessage or 'Unable to resolve a valid placement surface.'
        )
        return
    end

    local resolvedPosition = snappedWorldPosition :: Vector3
    local resolvedCellKey = cellKey :: string
    local resolvedDistance = (root.Position - resolvedPosition).Magnitude
    if resolvedDistance > maxDistance then
        self:_reject(player, 'RequestPlaceTower', 'OUT_OF_RANGE', 'Placement is beyond max placement distance.')
        return
    end

    if self:_isCellOccupied(resolvedCellKey) then
        self:_reject(player, 'RequestPlaceTower', 'CELL_OCCUPIED', 'Placement cell is already occupied.')
        return
    end

    local maxPerPlayer = tonumber(self._config.TOWER_MAX_PER_PLAYER) or 25
    if maxPerPlayer < 1 then
        maxPerPlayer = 1
    end
    local placedByPlayer = self:_countRuntimeTowersForUser(player.UserId)
    if placedByPlayer >= maxPerPlayer then
        self:_reject(
            player,
            'RequestPlaceTower',
            'PLAYER_TOWER_LIMIT_REACHED',
            ('You reached your tower cap (%d).'):format(maxPerPlayer)
        )
        return
    end

    local maxTotal = tonumber(self._config.TOWER_MAX_TOTAL) or 100
    if maxTotal < 1 then
        maxTotal = 1
    end
    local placedTotal = self:_countRuntimeTowersTotal()
    if placedTotal >= maxTotal then
        self:_reject(player, 'RequestPlaceTower', 'TOWER_LIMIT_REACHED', ('Tower cap reached (%d).'):format(maxTotal))
        return
    end

    local baseTowerCost = tonumber(self._config.TOWER_COSTS[towerType])
    if not baseTowerCost or baseTowerCost < 0 then
        self:_reject(player, 'RequestPlaceTower', 'INVALID_TOWER_COST', 'Tower cost is not configured correctly.')
        return
    end
    local towerCostMultiplier = tonumber(self._difficultyEconomyMultipliers.towerCostMultiplier) or 1
    if towerCostMultiplier < 0.1 then
        towerCostMultiplier = 0.1
    end
    local towerCost = math.max(1, math.floor(baseTowerCost * towerCostMultiplier))

    local template = self:_getTowerTemplate(towerType)
    if not template then
        self:_reject(player, 'RequestPlaceTower', 'TOWER_TEMPLATE_MISSING', 'Tower model template is missing.')
        return
    end

    local canSpend, currentBalance = self:_trySpendCurrency(player, towerCost)
    if not canSpend then
        self:_reject(
            player,
            'RequestPlaceTower',
            'UNAFFORDABLE',
            ('Not enough currency. Need %d, have %d.'):format(towerCost, currentBalance)
        )
        return
    end

    local placementSuccess, placementErr = pcall(function()
        local towersFolder = self:_getOrCreateTowersFolder()
        if not towersFolder then
            error('MISSING_TOWERS_FOLDER')
        end

        local towerModel = template:Clone()
        local towerRoot = self:_getModelRoot(towerModel)
        if not towerRoot then
            towerModel:Destroy()
            error('TOWER_TEMPLATE_HAS_NO_BASEPART')
        end

        local towerId = ('tower-%d'):format(self._nextTowerId)
        self._nextTowerId += 1

        towerModel.Name = ('%s_%s'):format(towerType, towerId)
        towerModel:SetAttribute('TowerId', towerId)
        towerModel:SetAttribute('TowerType', towerType)
        towerModel:SetAttribute('OwnerUserId', player.UserId)
        towerModel:SetAttribute('OwnerName', player.Name)
        towerModel:SetAttribute('PlacementCellKey', resolvedCellKey)
        towerModel:SetAttribute('CostPaid', towerCost)
        towerModel:SetAttribute('UpgradeTier', 0)
        local baseTierDamage, baseTierRange, baseTierAttackInterval = self:_computeTowerTierStats(towerType, 0)
        towerModel:SetAttribute('Damage', baseTierDamage)
        towerModel:SetAttribute('Range', baseTierRange)
        towerModel:SetAttribute('AttackInterval', baseTierAttackInterval)
        towerModel:SetAttribute('TargetMode', 'First')
        towerModel:SetAttribute('PlacementRotationY', rotationY)
        local towerSpec = self:_getTowerSchemaSpec(towerType)
        if type(towerSpec) == 'table' and type(towerSpec.facingPartName) == 'string' and towerSpec.facingPartName ~= '' then
            towerModel:SetAttribute('FacingPartName', towerSpec.facingPartName)
        end
        towerModel.Parent = towersFolder
        towerModel:PivotTo(CFrame.new(resolvedPosition) * CFrame.Angles(0, math.rad(rotationY), 0))

        self._occupiedCells[resolvedCellKey] = towerId
        self._telemetry.towerPicksByType[towerType] = (self._telemetry.towerPicksByType[towerType] or 0) + 1

        self:_emitEconomyUpdated(player)
        self:_emitTowerPlaced({
            towerId = towerId,
            towerType = towerType,
            ownerUserId = player.UserId,
            ownerName = player.Name,
            position = resolvedPosition,
            rotationY = rotationY,
            cellKey = resolvedCellKey,
            costPaid = towerCost,
        })
        self:_emitTowerActionTelemetry({
            event = 'ACCEPTED',
            requestType = 'RequestPlaceTower',
            userId = player.UserId,
            towerId = towerId,
            towerType = towerType,
            cellKey = resolvedCellKey,
            correlationId = (self:_getRequestContext(player) and self:_getRequestContext(player).correlationId) or nil,
        })
    end)

    if not placementSuccess then
        self:_refundCurrency(player, towerCost)
        self:_emitEconomyUpdated(player)
        self:_reject(
            player,
            'RequestPlaceTower',
            'PLACE_INTERNAL_ERROR',
            ('Placement failed: %s'):format(tostring(placementErr))
        )
        return
    end
end

function TowerPlacementService:_handleRequestSellTower(player: Player, payload)
    if type(payload) ~= 'table' then
        self:_rejectInvalidPayload(player, 'RequestSellTower')
        return
    end

    local phase = self:_getRoundPhase()
    if phase ~= 'Wave' then
        self:_reject(player, 'RequestSellTower', 'INVALID_PHASE', 'Tower sell is only allowed during Wave.')
        return
    end
    if not self:_isTowerActionWindowOpen() then
        self:_reject(player, 'RequestSellTower', 'ACTION_WINDOW_CLOSED', 'Tower actions are locked for this round.')
        return
    end

    local towerModel, resolveError, resolveMessage = self:_resolvePayloadTowerModel(payload)
    if not towerModel then
        self:_reject(
            player,
            'RequestSellTower',
            resolveError or 'INVALID_TOWER_REF',
            resolveMessage or 'Invalid tower reference.'
        )
        return
    end

    local owned, ownershipCode, ownershipMessage = self:_validateTowerOwnership(towerModel, player)
    if not owned then
        self:_reject(
            player,
            'RequestSellTower',
            ownershipCode or 'NOT_OWNER',
            ownershipMessage or 'Ownership mismatch.'
        )
        return
    end
    if not self:_isPlayerInActiveRoundRoster(player) then
        self:_reject(player, 'RequestSellTower', 'NOT_IN_MATCH_ROSTER', 'You are not in the active match roster.')
        return
    end
    if not self:_isPlayerWithinTowerInteractDistance(player, towerModel) then
        self:_reject(player, 'RequestSellTower', 'OUT_OF_RANGE', 'Tower is too far away to sell.')
        return
    end

    local towerId = towerModel:GetAttribute('TowerId')
    local towerType = towerModel:GetAttribute('TowerType')
    local cellKey = towerModel:GetAttribute('PlacementCellKey')
    local refundAmount = self:_computeTowerSellRefund(towerModel)

    towerModel:Destroy()

    if type(cellKey) == 'string' and cellKey ~= '' then
        self._occupiedCells[cellKey] = nil
    end

    if refundAmount > 0 then
        self:_refundCurrency(player, refundAmount)
    end

    self:_emitEconomyUpdated(player)
    self:_emitTowerRemoved({
        towerId = towerId,
        towerType = towerType,
        ownerUserId = player.UserId,
        ownerName = player.Name,
        refundAmount = refundAmount,
        cellKey = cellKey,
    })
    self:_emitTowerActionTelemetry({
        event = 'ACCEPTED',
        requestType = 'RequestSellTower',
        userId = player.UserId,
        towerId = towerId,
        towerType = towerType,
        refundAmount = refundAmount,
        correlationId = (self:_getRequestContext(player) and self:_getRequestContext(player).correlationId) or nil,
    })
end

function TowerPlacementService:_handleRequestUpgradeTower(player: Player, payload)
    if type(payload) ~= 'table' then
        self:_rejectInvalidPayload(player, 'RequestUpgradeTower')
        return
    end

    local phase = self:_getRoundPhase()
    if phase ~= 'Wave' then
        self:_reject(player, 'RequestUpgradeTower', 'INVALID_PHASE', 'Tower upgrade is only allowed during Wave.')
        return
    end
    if not self:_isTowerActionWindowOpen() then
        self:_reject(player, 'RequestUpgradeTower', 'ACTION_WINDOW_CLOSED', 'Tower actions are locked for this round.')
        return
    end

    local towerModel, resolveError, resolveMessage = self:_resolvePayloadTowerModel(payload)
    if not towerModel then
        self:_reject(
            player,
            'RequestUpgradeTower',
            resolveError or 'INVALID_TOWER_REF',
            resolveMessage or 'Invalid tower reference.'
        )
        return
    end

    local owned, ownershipCode, ownershipMessage = self:_validateTowerOwnership(towerModel, player)
    if not owned then
        self:_reject(
            player,
            'RequestUpgradeTower',
            ownershipCode or 'NOT_OWNER',
            ownershipMessage or 'Ownership mismatch.'
        )
        return
    end
    if not self:_isPlayerInActiveRoundRoster(player) then
        self:_reject(player, 'RequestUpgradeTower', 'NOT_IN_MATCH_ROSTER', 'You are not in the active match roster.')
        return
    end
    if not self:_isPlayerWithinTowerInteractDistance(player, towerModel) then
        self:_reject(player, 'RequestUpgradeTower', 'OUT_OF_RANGE', 'Tower is too far away to upgrade.')
        return
    end

    local currentTier = tonumber(towerModel:GetAttribute('UpgradeTier')) or 0
    local nextTier = currentTier + 1
    local maxTier = tonumber(self._config.TOWER_MAX_UPGRADE_TIER) or 3
    if nextTier > maxTier then
        self:_reject(player, 'RequestUpgradeTower', 'MAX_TIER_REACHED', 'Tower is already at max upgrade tier.')
        return
    end

    local upgradeCost = self:_computeTowerUpgradeCost(towerModel, nextTier)
    if upgradeCost <= 0 then
        self:_reject(player, 'RequestUpgradeTower', 'INVALID_UPGRADE_COST', 'Upgrade cost is not configured correctly.')
        return
    end

    local canSpend, currentBalance = self:_trySpendCurrency(player, upgradeCost)
    if not canSpend then
        self:_reject(
            player,
            'RequestUpgradeTower',
            'UNAFFORDABLE_UPGRADE',
            ('Not enough currency. Need %d, have %d.'):format(upgradeCost, currentBalance)
        )
        return
    end

    local updateOk, updateErr = pcall(function()
        local towerType = tostring(towerModel:GetAttribute('TowerType') or '')
        local damage, range, attackInterval = self:_computeTowerTierStats(towerType, nextTier)

        towerModel:SetAttribute('UpgradeTier', nextTier)
        towerModel:SetAttribute('Damage', damage)
        towerModel:SetAttribute('Range', range)
        towerModel:SetAttribute('AttackInterval', attackInterval)
        towerModel:SetAttribute('LastUpgradeCost', upgradeCost)

        self:_emitEconomyUpdated(player)
        self:_emitTowerUpdated({
            towerId = towerModel:GetAttribute('TowerId'),
            towerType = towerModel:GetAttribute('TowerType'),
            ownerUserId = player.UserId,
            ownerName = player.Name,
            upgradeTier = nextTier,
            damage = damage,
            range = range,
            attackInterval = attackInterval,
            upgradeCost = upgradeCost,
        })
        self:_emitTowerActionTelemetry({
            event = 'ACCEPTED',
            requestType = 'RequestUpgradeTower',
            userId = player.UserId,
            towerId = towerModel:GetAttribute('TowerId'),
            towerType = towerModel:GetAttribute('TowerType'),
            upgradeTier = nextTier,
            upgradeCost = upgradeCost,
            correlationId = (self:_getRequestContext(player) and self:_getRequestContext(player).correlationId) or nil,
        })
    end)

    if not updateOk then
        self:_refundCurrency(player, upgradeCost)
        self:_emitEconomyUpdated(player)
        self:_reject(
            player,
            'RequestUpgradeTower',
            'UPGRADE_INTERNAL_ERROR',
            ('Upgrade failed: %s'):format(tostring(updateErr))
        )
        return
    end
end

function TowerPlacementService:_handleRequestSetTowerTargetMode(player: Player, payload)
    if type(payload) ~= 'table' then
        self:_rejectInvalidPayload(player, 'RequestSetTowerTargetMode')
        return
    end

    local phase = self:_getRoundPhase()
    if phase ~= 'Wave' then
        self:_reject(
            player,
            'RequestSetTowerTargetMode',
            'INVALID_PHASE',
            'Tower target mode change is only allowed during Wave.'
        )
        return
    end
    if not self:_isTowerActionWindowOpen() then
        self:_reject(
            player,
            'RequestSetTowerTargetMode',
            'ACTION_WINDOW_CLOSED',
            'Tower actions are locked for this round.'
        )
        return
    end

    local towerModel, resolveError, resolveMessage = self:_resolvePayloadTowerModel(payload)
    if not towerModel then
        self:_reject(
            player,
            'RequestSetTowerTargetMode',
            resolveError or 'INVALID_TOWER_REF',
            resolveMessage or 'Invalid tower reference.'
        )
        return
    end

    local owned, ownershipCode, ownershipMessage = self:_validateTowerOwnership(towerModel, player)
    if not owned then
        self:_reject(
            player,
            'RequestSetTowerTargetMode',
            ownershipCode or 'NOT_OWNER',
            ownershipMessage or 'Ownership mismatch.'
        )
        return
    end
    if not self:_isPlayerInActiveRoundRoster(player) then
        self:_reject(
            player,
            'RequestSetTowerTargetMode',
            'NOT_IN_MATCH_ROSTER',
            'You are not in the active match roster.'
        )
        return
    end
    if not self:_isPlayerWithinTowerInteractDistance(player, towerModel) then
        self:_reject(
            player,
            'RequestSetTowerTargetMode',
            'OUT_OF_RANGE',
            'Tower is too far away to change target mode.'
        )
        return
    end

    local targetMode = payload.targetMode
    if type(targetMode) ~= 'string' or not ALLOWED_TOWER_TARGET_MODES[targetMode] then
        self:_reject(
            player,
            'RequestSetTowerTargetMode',
            'INVALID_TARGET_MODE',
            'targetMode must be one of: First, Last, Closest.'
        )
        return
    end

    towerModel:SetAttribute('TargetMode', targetMode)
    self:_emitTowerUpdated({
        towerId = towerModel:GetAttribute('TowerId'),
        towerType = towerModel:GetAttribute('TowerType'),
        ownerUserId = player.UserId,
        ownerName = player.Name,
        targetMode = targetMode,
    })
    self:_emitTowerActionTelemetry({
        event = 'ACCEPTED',
        requestType = 'RequestSetTowerTargetMode',
        userId = player.UserId,
        towerId = towerModel:GetAttribute('TowerId'),
        targetMode = targetMode,
        correlationId = (self:_getRequestContext(player) and self:_getRequestContext(player).correlationId) or nil,
    })
end

function TowerPlacementService:_connectHandler(remoteName: string, callback)
    local remote = self:_getRemoteEvent(remoteName)
    if not remote then
        warn(('[TowerPlacementService] Missing remote: %s'):format(remoteName))
        return
    end

    table.insert(
        self._connections,
        remote.OnServerEvent:Connect(function(player, payload)
            if not self._running then
                return
            end

            if type(payload) == 'table' then
                local maxPayloadKeys = tonumber(self._config.REQUEST_MAX_PAYLOAD_KEYS) or 16
                if maxPayloadKeys < 1 then
                    maxPayloadKeys = 1
                end
                local keyCount = tableKeyCount(payload)
                if keyCount > maxPayloadKeys then
                    self:_emitTowerPlacementFailed(player, {
                        requestType = remoteName,
                        reasonCode = 'PAYLOAD_TOO_LARGE',
                        message = ('Payload has too many fields (%d > %d).'):format(keyCount, maxPayloadKeys),
                    })
                    return
                end
            end

            local allowed, rateLimitMessage = self:_checkAndConsumeRateLimit(player, remoteName)
            if not allowed then
                self:_emitTowerPlacementFailed(player, {
                    requestType = remoteName,
                    reasonCode = 'RATE_LIMITED',
                    message = rateLimitMessage or 'Request rate exceeded.',
                })
                return
            end

            local accepted, _, requestIdError = self:_checkAndMarkDuplicateRequest(player, remoteName, payload)
            if not accepted then
                if requestIdError then
                    self:_emitTowerPlacementFailed(player, {
                        requestType = remoteName,
                        reasonCode = 'INVALID_REQUEST_ID',
                        message = requestIdError,
                    })
                else
                    self:_emitTowerPlacementFailed(player, {
                        requestType = remoteName,
                        reasonCode = 'DUPLICATE_REQUEST',
                        message = 'Duplicate request ignored.',
                    })
                end
                return
            end

            local correlationId = self:_resolveCorrelationId(player, remoteName, payload)
            self._activeRequestContextByUserId[player.UserId] = {
                requestType = remoteName,
                correlationId = correlationId,
            }
            local ok, err = pcall(callback, self, player, payload)
            self._activeRequestContextByUserId[player.UserId] = nil
            if not ok then
                warn(('[TowerPlacementService] Handler error for %s: %s'):format(remoteName, tostring(err)))
                self:_emitTowerPlacementFailed(player, {
                    requestType = remoteName,
                    reasonCode = 'INTERNAL_ERROR',
                    message = 'Request failed unexpectedly.',
                })
            end
        end)
    )
end

function TowerPlacementService:start()
    if self._running then
        return
    end

    self._running = true
    self._runId += 1
    self._nextCorrelationOrdinal = 0
    table.clear(self._occupiedCells)
    self._activeDifficulty = 'Normal'
    self._activeDifficultyPreset = 'Normal'
    self._difficultyEconomyMultipliers.killRewardMultiplier = 1.0
    self._difficultyEconomyMultipliers.roundRewardMultiplier = 1.0
    self._difficultyEconomyMultipliers.towerCostMultiplier = 1.0
    self._difficultyEconomyMultipliers.upgradeCostMultiplier = 1.0
    self._difficultyEconomyMultipliers.sellRefundMultiplier = 1.0
    table.clear(self._telemetry.towerPicksByType)
    table.clear(self._telemetry.failReasons)
    table.clear(self._telemetry.trustRejects)
    self._telemetry.missionRewardsPaid = 0
    self._telemetry.missionClaimsBlocked = 0
    table.clear(self._activeRequestContextByUserId)

    table.insert(
        self._connections,
        Players.PlayerAdded:Connect(function(player)
            self:_initializePlayerEconomy(player)
        end)
    )
    table.insert(
        self._connections,
        Players.PlayerRemoving:Connect(function(player)
            self._playerEconomy[player.UserId] = nil
            self._requestBuckets[player.UserId] = nil
            self._processedRequestIds[player.UserId] = nil
            self._missionRewardClaimsByUserId[player.UserId] = nil
        end)
    )

    for _, player in ipairs(Players:GetPlayers()) do
        self:_initializePlayerEconomy(player)
    end

    self:_connectHandler(self._net.ClientToServer.RequestPlaceTower, self._handleRequestPlaceTower)
    self:_connectHandler(self._net.ClientToServer.RequestSellTower, self._handleRequestSellTower)
    self:_connectHandler(self._net.ClientToServer.RequestUpgradeTower, self._handleRequestUpgradeTower)
    self:_connectHandler(self._net.ClientToServer.RequestSetTowerTargetMode, self._handleRequestSetTowerTargetMode)
end

function TowerPlacementService:stop()
    if not self._running then
        return
    end

    self._running = false
    self._runId += 1

    for _, connection in ipairs(self._connections) do
        connection:Disconnect()
    end
    table.clear(self._connections)
    self:_cleanupRuntimeTowers()
    table.clear(self._occupiedCells)
    table.clear(self._requestBuckets)
    table.clear(self._processedRequestIds)
    table.clear(self._missionRewardClaimsByUserId)
    table.clear(self._activeRequestContextByUserId)
    table.clear(self._playerEconomy)
    self._nextTowerId = 1

    local snapshot = {
        activeDifficulty = self._activeDifficulty,
        activeDifficultyPreset = self._activeDifficultyPreset,
        difficultyEconomyMultipliers = self._difficultyEconomyMultipliers,
        towerPicksByType = self._telemetry.towerPicksByType,
        failReasons = self._telemetry.failReasons,
        trustRejects = self._telemetry.trustRejects,
        missionRewardsPaid = self._telemetry.missionRewardsPaid,
        missionClaimsBlocked = self._telemetry.missionClaimsBlocked,
    }
    print(
        ('[Telemetry][TowerPlacementService] %s'):format(
            jsonEncode(toTelemetryEnvelope('ServiceStopSummary', snapshot))
        )
    )
end

function TowerPlacementService:setRoundService(roundService)
    self._roundService = roundService
end

function TowerPlacementService:setPlayerDataService(playerDataService)
    self._playerDataService = playerDataService
end

function TowerPlacementService:setDifficultyEconomyMultipliers(
    difficultyName: string?,
    presetName: string?,
    multipliers
)
    self._activeDifficulty = if type(difficultyName) == 'string' and difficultyName ~= ''
        then difficultyName
        else 'Normal'
    self._activeDifficultyPreset = if type(presetName) == 'string' and presetName ~= '' then presetName else 'Normal'

    local normalized = {
        killRewardMultiplier = 1.0,
        roundRewardMultiplier = 1.0,
        towerCostMultiplier = 1.0,
        upgradeCostMultiplier = 1.0,
        sellRefundMultiplier = 1.0,
    }
    if type(multipliers) == 'table' then
        local killRewardMultiplier = tonumber(multipliers.killRewardMultiplier)
        local roundRewardMultiplier = tonumber(multipliers.roundRewardMultiplier)
        local towerCostMultiplier = tonumber(multipliers.towerCostMultiplier)
        local upgradeCostMultiplier = tonumber(multipliers.upgradeCostMultiplier)
        local sellRefundMultiplier = tonumber(multipliers.sellRefundMultiplier)
        if killRewardMultiplier and killRewardMultiplier > 0 then
            normalized.killRewardMultiplier = killRewardMultiplier
        end
        if roundRewardMultiplier and roundRewardMultiplier > 0 then
            normalized.roundRewardMultiplier = roundRewardMultiplier
        end
        if towerCostMultiplier and towerCostMultiplier > 0 then
            normalized.towerCostMultiplier = towerCostMultiplier
        end
        if upgradeCostMultiplier and upgradeCostMultiplier > 0 then
            normalized.upgradeCostMultiplier = upgradeCostMultiplier
        end
        if sellRefundMultiplier and sellRefundMultiplier >= 0 then
            normalized.sellRefundMultiplier = sellRefundMultiplier
        end
    end
    self._difficultyEconomyMultipliers = normalized
end

function TowerPlacementService:_getActiveRoundNumber(): number
    local roundService = self._roundService
    if not roundService or type(roundService.getRoundNumber) ~= 'function' then
        return 1
    end

    local parsed = tonumber(roundService:getRoundNumber()) or 1
    return math.max(1, math.floor(parsed))
end

function TowerPlacementService:awardKillRewardByTowerId(towerId: string, killPayload): (boolean, string?)
    if type(towerId) ~= 'string' or towerId == '' then
        return false, 'INVALID_TOWER_ID'
    end

    local rewardAmount = tonumber(self._config.KILL_REWARD) or 0
    local perRoundBonus = tonumber(self._config.KILL_REWARD_PER_ROUND) or 0
    local roundNumber = self:_getActiveRoundNumber()
    rewardAmount += (math.max(1, roundNumber) - 1) * perRoundBonus
    local rewardMultiplier = 1
    if type(killPayload) == 'table' then
        local payloadMultiplier = tonumber(killPayload.rewardMultiplier)
        if payloadMultiplier then
            rewardMultiplier = math.max(0.1, payloadMultiplier)
        end
    end
    rewardAmount = rewardAmount * rewardMultiplier
    rewardAmount *= (tonumber(self._difficultyEconomyMultipliers.killRewardMultiplier) or 1)
    rewardAmount = math.max(0, math.floor(rewardAmount))
    if rewardAmount <= 0 then
        return false, 'KILL_REWARD_DISABLED'
    end

    local towerModel = self:_findTowerModelById(towerId)
    if not towerModel then
        return false, 'TOWER_NOT_FOUND'
    end

    local ownerUserId = tonumber(towerModel:GetAttribute('OwnerUserId'))
    if not ownerUserId then
        return false, 'TOWER_OWNER_MISSING'
    end

    local ownerPlayer = Players:GetPlayerByUserId(ownerUserId)
    if not ownerPlayer then
        return false, 'OWNER_NOT_IN_SERVER'
    end

    self:_addCurrency(ownerPlayer, rewardAmount)
    self:_emitEconomyUpdated(ownerPlayer)
    return true, nil
end

function TowerPlacementService:awardRoundOutcomeRewardForRoster(roster, outcome: string): number
    if type(roster) ~= 'table' then
        return 0
    end

    local rewardsByOutcome = self._config.ROUND_REWARDS
    if type(rewardsByOutcome) ~= 'table' then
        return 0
    end

    local rewardAmount = tonumber(rewardsByOutcome[outcome]) or 0
    local perRoundBonus = tonumber(self._config.ROUND_REWARD_PER_ROUND) or 0
    local roundNumber = self:_getActiveRoundNumber()
    rewardAmount += (math.max(1, roundNumber) - 1) * perRoundBonus
    rewardAmount *= (tonumber(self._difficultyEconomyMultipliers.roundRewardMultiplier) or 1)
    rewardAmount = math.max(0, math.floor(rewardAmount))
    if rewardAmount <= 0 then
        return 0
    end

    local rewardedPlayers = 0
    for _, player in ipairs(roster) do
        if typeof(player) == 'Instance' and player:IsA('Player') and player.Parent then
            self:_addCurrency(player, rewardAmount)
            self:_emitEconomyUpdated(player)
            rewardedPlayers += 1
        end
    end

    return rewardedPlayers
end

function TowerPlacementService:awardMissionRewardsForRoster(roster, roundNumber: number, missionSnapshot)
    local summary = {
        rewardedPlayers = 0,
        totalPayout = 0,
        completedCount = 0,
        totalCount = 0,
    }
    if type(roster) ~= 'table' or type(missionSnapshot) ~= 'table' then
        return summary
    end

    local completedMissions = {}
    for _, mission in ipairs(missionSnapshot) do
        if type(mission) == 'table' then
            summary.totalCount += 1
            if mission.completed == true then
                summary.completedCount += 1
                local missionId = mission.id
                local rewardAmount = math.max(0, math.floor(tonumber(mission.reward) or 0))
                if type(missionId) == 'string' and missionId ~= '' and rewardAmount > 0 then
                    table.insert(completedMissions, {
                        id = missionId,
                        reward = rewardAmount,
                    })
                end
            end
        end
    end

    if #completedMissions == 0 then
        return summary
    end

    local effectiveRound = math.max(1, math.floor(tonumber(roundNumber) or self:_getActiveRoundNumber()))
    for _, player in ipairs(roster) do
        if typeof(player) == 'Instance' and player:IsA('Player') and player.Parent then
            local userClaims = self._missionRewardClaimsByUserId[player.UserId]
            if not userClaims then
                userClaims = {}
                self._missionRewardClaimsByUserId[player.UserId] = userClaims
            end

            local playerPayout = 0
            for _, completedMission in ipairs(completedMissions) do
                local claimKey = ('%d:%s'):format(effectiveRound, completedMission.id)
                if userClaims[claimKey] then
                    self._telemetry.missionClaimsBlocked += 1
                else
                    userClaims[claimKey] = true
                    playerPayout += completedMission.reward
                end
            end

            if playerPayout > 0 then
                self:_addCurrency(player, playerPayout)
                self:_emitEconomyUpdated(player)
                summary.rewardedPlayers += 1
                summary.totalPayout += playerPayout
                self._telemetry.missionRewardsPaid += playerPayout
            end
        end
    end

    return summary
end

function TowerPlacementService:clearRuntimeTowers(): number
    local removedCount = self:_cleanupRuntimeTowers()
    table.clear(self._occupiedCells)
    return removedCount
end

function TowerPlacementService:getRuntimeTowerCount(): number
    local towersFolder = self:_getTowersFolder()
    if not towersFolder then
        return 0
    end

    local count = 0
    for _, child in ipairs(towersFolder:GetChildren()) do
        if child:IsA('Model') then
            count += 1
        end
    end
    return count
end

function TowerPlacementService:getActiveTowers()
    local towers = {}
    local towersFolder = self:_getTowersFolder()
    if not towersFolder then
        return towers
    end

    for _, descendant in ipairs(towersFolder:GetDescendants()) do
        if descendant:IsA('Model') then
            local root = self:_getModelRoot(descendant)
            if root and root.Parent then
                table.insert(towers, {
                    towerId = tostring(descendant:GetAttribute('TowerId') or ''),
                    model = descendant,
                    towerType = tostring(descendant:GetAttribute('TowerType') or ''),
                    upgradeTier = tonumber(descendant:GetAttribute('UpgradeTier')) or 0,
                    position = root.Position,
                    damage = tonumber(descendant:GetAttribute('Damage'))
                        or (tonumber(self._config.TOWER_DEFAULT_DAMAGE) or 10),
                    range = tonumber(descendant:GetAttribute('Range'))
                        or (tonumber(self._config.TOWER_DEFAULT_RANGE) or 20),
                    attackInterval = tonumber(descendant:GetAttribute('AttackInterval'))
                        or (tonumber(self._config.TOWER_ATTACK_INTERVAL_SECONDS) or 1.0),
                    targetMode = tostring(descendant:GetAttribute('TargetMode') or 'First'),
                    facingPartName = tostring(descendant:GetAttribute('FacingPartName') or ''),
                })
            end
        end
    end

    return towers
end

return TowerPlacementService
