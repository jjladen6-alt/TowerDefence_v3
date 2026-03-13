local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local RunService = game:GetService('RunService')
local UserInputService = game:GetService('UserInputService')
local GuiService = game:GetService('GuiService')
local HttpService = game:GetService('HttpService')
local CollectionService = game:GetService('CollectionService')

local Shared = ReplicatedStorage:WaitForChild('Shared')
local GameConfig = require(Shared:WaitForChild('GameConfig'))
local FAILURE_REASON_TO_MESSAGE = require(Shared:WaitForChild('FailureReasonMessages'))
local HUDTheme = require(script.Parent:WaitForChild('ui'):WaitForChild('HUDTheme'))

local TowerPlacementController = {}
TowerPlacementController.__index = TowerPlacementController

local CONTROL_HINT =
    'Controls: 1-4 tower, click/tap place/select, Enter place, R rotate, C cancel, U upgrade, X sell.'
local REMOTE_RESOLVE_ATTEMPTS = 10
local REMOTE_RESOLVE_RETRY_SECONDS = 0.5
local TARGET_MODE_ORDER = { 'First', 'Last', 'Closest' }
local PREVIEW_REASON_TO_HINT = {
    AIM_AT_WORLD = 'Aim at the map to place.',
    INVALID_SURFACE = 'Invalid: aim at a buildable surface.',
    BLOCKED_SURFACE = 'Invalid: that zone is blocked for building.',
    OUT_OF_RANGE_OR_INVALID_SURFACE = 'Invalid: move closer or aim at valid terrain/surface.',
    OUT_OF_RANGE = 'Invalid: move closer to place.',
    CELL_OCCUPIED = 'Invalid: that cell is occupied. Pick a new cell.',
    OK = 'Placement valid.',
}
local FAILURE_REASON_TO_PREVIEW_HINT = {
    INVALID_SURFACE = 'Invalid: aim at a buildable surface.',
    BLOCKED_SURFACE = 'Invalid: that zone is blocked for building.',
    OUT_OF_RANGE = 'Invalid: move closer to place.',
    CELL_OCCUPIED = 'Invalid: that cell is occupied. Pick a new cell.',
    PLAYER_TOWER_LIMIT_REACHED = 'Invalid: you reached your tower limit.',
    TOWER_LIMIT_REACHED = 'Invalid: map tower cap reached.',
    INVALID_PHASE = 'Placement is only allowed during wave.',
    ACTION_WINDOW_CLOSED = 'Round is ending. Placement is locked.',
}
local SELECTED_PANEL_LAYOUT_VISIBLE_ATTR = 'HUDSelectedTowerPanelVisible'
local SELECTED_PANEL_LAYOUT_LEFT_ATTR = 'HUDSelectedTowerPanelLeft'
local SELECTED_PANEL_LAYOUT_TOP_ATTR = 'HUDSelectedTowerPanelTop'
local SELECTED_PANEL_LAYOUT_RIGHT_ATTR = 'HUDSelectedTowerPanelRight'
local SELECTED_PANEL_LAYOUT_BOTTOM_ATTR = 'HUDSelectedTowerPanelBottom'

local function getSafeInsets(): (Vector2, Vector2)
    local ok, topLeft, bottomRight = pcall(function()
        return GuiService:GetGuiInset()
    end)
    if ok and typeof(topLeft) == 'Vector2' and typeof(bottomRight) == 'Vector2' then
        return topLeft, bottomRight
    end
    return Vector2.zero, Vector2.zero
end

local function encodeJson(payload): string
    local ok, encoded = pcall(function()
        return HttpService:JSONEncode(payload)
    end)
    if ok and type(encoded) == 'string' then
        return encoded
    end
    return '{}'
end

function TowerPlacementController.new(net)
    return setmetatable({
        _net = net,
        _activeMapName = tostring(GameConfig.ACTIVE_MAP_NAME or GameConfig.DEFAULT_STAGE_ID or 'brown'),
        _running = false,
        _connections = {},
        _remotes = {},
        _screenGui = nil,
        _placingArmed = false,
        _selectedTowerId = nil,
        _selectedTowerModel = nil,
        _selectedTowerType = 'Basic',
        _selectedTargetMode = 'First',
        _requestSeq = 0,
        _targetModeButton = nil,
        _placeButton = nil,
        _upgradeButton = nil,
        _sellButton = nil,
        _placementStatusLabel = nil,
        _towerTypeButtons = {},
        _previewFolder = nil,
        _previewGhost = nil,
        _previewRange = nil,
        _previewFootprint = nil,
        _previewPosition = nil,
        _previewValid = false,
        _previewReason = '',
        _placementRotationQuarter = 0,
        _previewHintLabel = nil,
        _placementActionHintLabel = nil,
        _placementActionHintExpiresAt = 0,
        _towerUpdatedRemote = nil,
        _placementFailedRemote = nil,
        _targetModeButtons = {},
        _targetModeFrame = nil,
        _towerLoadoutFrame = nil,
        _selectedPanel = nil,
        _selectedPanelLabels = {},
        _selectedPortraitFrame = nil,
        _lastPlacementFailureReasonCode = nil,
        _lastPlacementFailureAt = 0,
        _rotateButton = nil,
        _cancelButton = nil,
        _latestPhase = 'Idle',
        _latestCurrency = 0,
        _phaseStatusLabel = nil,
        _previewReasonTelemetryLast = '',
        _visualTelemetryLastAt = {},
        _visualTelemetryLastPayloadByMarker = {},
        _selectedPanelLayoutSignature = '',
    }, TowerPlacementController)
end

function TowerPlacementController:_getActiveMapFolder(): Instance?
    return workspace:FindFirstChild(self._activeMapName)
end

local function getRemoteEvent(remoteName: string, timeoutSeconds: number?): RemoteEvent?
    local remotesFolder = ReplicatedStorage:FindFirstChild('Remotes')
    if not remotesFolder then
        remotesFolder = ReplicatedStorage:WaitForChild('Remotes', timeoutSeconds or 5)
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

function TowerPlacementController:_notify(text: string)
    local label = self._placementActionHintLabel
    if not label or not label.Parent then
        return
    end
    if text == '' then
        label.Visible = false
        label.Text = ''
        self._placementActionHintExpiresAt = 0
        return
    end

    label.Text = text
    label.Visible = true
    self._placementActionHintExpiresAt = os.clock() + 2.0
end

function TowerPlacementController:_emitVisualTelemetry(markerKey: string, payload)
    local cfg = type(GameConfig.VISUAL_TELEMETRY) == 'table' and GameConfig.VISUAL_TELEMETRY or nil
    if not cfg or cfg.enabled == false then
        return
    end
    local markerMap = type(cfg.markers) == 'table' and cfg.markers or {}
    local markerName = tostring(markerMap[markerKey] or markerKey)
    local minInterval = math.max(0, tonumber(cfg.minIntervalSeconds) or 0.35)
    local nowTime = os.clock()
    local lastAt = self._visualTelemetryLastAt[markerName]
    if type(lastAt) == 'number' and (nowTime - lastAt) < minInterval then
        return
    end
    local payloadSignature = encodeJson(payload)
    local lastPayloadSignature = self._visualTelemetryLastPayloadByMarker[markerName]
    if payloadSignature == lastPayloadSignature then
        return
    end
    self._visualTelemetryLastAt[markerName] = nowTime
    self._visualTelemetryLastPayloadByMarker[markerName] = payloadSignature
    print(('[Telemetry][VisualUX] %s'):format(encodeJson({
        schemaVersion = 1,
        surface = 'TowerPlacement',
        marker = markerName,
        payload = payload,
    })))
end

function TowerPlacementController:_getPhaseLabel(phaseName: string): string
    local labels = type(GameConfig.VISUAL_PHASE_LABELS) == 'table' and GameConfig.VISUAL_PHASE_LABELS or {}
    return tostring(labels[phaseName] or phaseName)
end

function TowerPlacementController:_updatePhaseVisualState()
    local isWave = self._latestPhase == 'Wave'
    if not isWave and self._placingArmed then
        self:_setPlacementArmed(false)
    end
    if self._towerLoadoutFrame and self._towerLoadoutFrame.Parent then
        self._towerLoadoutFrame.Visible = isWave
    end
    if self._previewHintLabel and self._previewHintLabel.Parent and not isWave then
        self._previewHintLabel.Visible = false
    end
    if self._targetModeFrame and self._targetModeFrame.Parent and not isWave then
        self._targetModeFrame.Visible = false
    end
    if self._phaseStatusLabel and self._phaseStatusLabel.Parent then
        self._phaseStatusLabel.Text = ('Phase: %s'):format(self:_getPhaseLabel(self._latestPhase))
        self._phaseStatusLabel.TextColor3 =
            if isWave then Color3.fromRGB(190, 235, 255) else Color3.fromRGB(195, 205, 220)
    end
end

function TowerPlacementController:_resolveRemotes(): boolean
    self._remotes.place = getRemoteEvent(self._net.ClientToServer.RequestPlaceTower, 5)
    self._remotes.sell = getRemoteEvent(self._net.ClientToServer.RequestSellTower, 5)
    self._remotes.upgrade = getRemoteEvent(self._net.ClientToServer.RequestUpgradeTower, 5)
    self._remotes.targetMode = getRemoteEvent(self._net.ClientToServer.RequestSetTowerTargetMode, 5)
    self._towerUpdatedRemote = getRemoteEvent(self._net.ServerToClient.TowerUpdated, 5)
    self._placementFailedRemote = getRemoteEvent(self._net.ServerToClient.TowerPlacementFailed, 5)

    return self._remotes.place ~= nil
        and self._remotes.sell ~= nil
        and self._remotes.upgrade ~= nil
        and self._remotes.targetMode ~= nil
end

function TowerPlacementController:_resolveRemotesWithRetry(): boolean
    for attempt = 1, REMOTE_RESOLVE_ATTEMPTS do
        if self:_resolveRemotes() then
            return true
        end

        if attempt < REMOTE_RESOLVE_ATTEMPTS then
            task.wait(REMOTE_RESOLVE_RETRY_SECONDS)
        end
    end

    return false
end

function TowerPlacementController:_buildPlacementRaycastParams(): RaycastParams
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignoreList = {}
    local localPlayer = Players.LocalPlayer
    local character = localPlayer and localPlayer.Character
    if character then
        table.insert(ignoreList, character)
    end
    local map = self:_getActiveMapFolder()
    local towersFolder = map and map:FindFirstChild('Towers')
    if towersFolder then
        table.insert(ignoreList, towersFolder)
    end
    if self._previewFolder and self._previewFolder.Parent then
        table.insert(ignoreList, self._previewFolder)
    end
    params.FilterDescendantsInstances = ignoreList
    return params
end

function TowerPlacementController:_getRaycastResult(screenPosition: Vector2): RaycastResult?
    local camera = workspace.CurrentCamera
    if not camera then
        return nil
    end
    local ray = camera:ViewportPointToRay(screenPosition.X, screenPosition.Y)
    return workspace:Raycast(ray.Origin, ray.Direction * 1000, self:_buildPlacementRaycastParams())
end

function TowerPlacementController:_resolveTowerIdFromHit(hitInstance: Instance?): string?
    if not hitInstance then
        return nil
    end

    local towerModel = hitInstance:FindFirstAncestorWhichIsA('Model')
    if not towerModel then
        return nil
    end

    local map = self:_getActiveMapFolder()
    local towersFolder = map and map:FindFirstChild('Towers')
    if not towersFolder or not towerModel:IsDescendantOf(towersFolder) then
        return nil
    end

    local towerId = towerModel:GetAttribute('TowerId')
    if towerId == nil then
        return nil
    end

    return tostring(towerId)
end

function TowerPlacementController:_firePlace(position: Vector3)
    local placeRemote = self._remotes.place
    if not placeRemote then
        self:_notify('Tower placement unavailable: missing remote.')
        return
    end
    placeRemote:FireServer({
        requestId = self:_nextRequestId('place'),
        towerType = self._selectedTowerType,
        position = position,
        rotationY = (self._placementRotationQuarter % 4) * 90,
    })
end

function TowerPlacementController:_getPreviewVisualConfig()
    local configured = GameConfig.PLACEMENT_PREVIEW_VISUALS
    if type(configured) ~= 'table' then
        configured = {}
    end
    return {
        validColor = configured.validColor or Color3.fromRGB(90, 220, 110),
        invalidColor = configured.invalidColor or Color3.fromRGB(225, 90, 90),
        ghostValidTransparency = tonumber(configured.ghostValidTransparency) or 0.5,
        ghostInvalidTransparency = tonumber(configured.ghostInvalidTransparency) or 0.7,
        rangeTransparency = tonumber(configured.rangeTransparency) or 0.72,
        footprintTransparency = tonumber(configured.footprintTransparency) or 0.78,
    }
end

function TowerPlacementController:_getSelectedTowerFootprint(): Vector3
    local fallback = Vector3.new(3, 4, 3)
    local towerType = self._selectedTowerType
    local footprintByType = GameConfig.TOWER_FOOTPRINT_BY_TYPE
    if type(footprintByType) ~= 'table' then
        return fallback
    end
    local configured = footprintByType[towerType]
    if type(configured) ~= 'table' then
        return fallback
    end
    local x = tonumber(configured.x) or fallback.X
    local y = tonumber(configured.y) or fallback.Y
    local z = tonumber(configured.z) or fallback.Z
    if x <= 0 then
        x = fallback.X
    end
    if y <= 0 then
        y = fallback.Y
    end
    if z <= 0 then
        z = fallback.Z
    end
    return Vector3.new(x, y, z)
end

function TowerPlacementController:_rotatePlacement()
    self._placementRotationQuarter = (self._placementRotationQuarter + 1) % 4
    self:_updatePlacementPreview()
    self:_notify(('Rotation: %d°'):format(self._placementRotationQuarter * 90))
end

function TowerPlacementController:_cancelPlacement()
    self:_setPlacementArmed(false)
    self:_notify('Placement canceled.')
end

function TowerPlacementController:_isBlockedByFolderRule(instance: Instance): boolean
    local blockedFolderNames = GameConfig.PLACEMENT_BLOCKED_FOLDER_NAMES
    if type(blockedFolderNames) ~= 'table' then
        return false
    end
    local current = instance
    while current and current ~= workspace do
        for _, folderName in ipairs(blockedFolderNames) do
            if type(folderName) == 'string' and folderName ~= '' and current.Name == folderName then
                return true
            end
        end
        current = current.Parent
    end
    return false
end

function TowerPlacementController:_isBlockedByTagRule(instance: Instance): boolean
    local blockedTags = GameConfig.PLACEMENT_BLOCKED_TAGS
    if type(blockedTags) ~= 'table' then
        return false
    end
    local current = instance
    while current and current ~= workspace do
        for _, tagName in ipairs(blockedTags) do
            if type(tagName) == 'string' and tagName ~= '' and CollectionService:HasTag(current, tagName) then
                return true
            end
        end
        current = current.Parent
    end
    return false
end

function TowerPlacementController:_isBuildSurfaceAllowed(instance: Instance?): boolean
    if not instance then
        return false
    end
    local surfaceMode = tostring(GameConfig.PLACEMENT_SURFACE_MODE or 'AnySurfaceExceptBlocked')
    if surfaceMode == 'TerrainOnlyExceptBlocked' and not instance:IsA('Terrain') then
        return false
    end
    if instance:IsA('Terrain') and GameConfig.PLACEMENT_ALLOW_TERRAIN == false then
        return false
    end
    if self:_isBlockedByFolderRule(instance) then
        return false
    end
    if self:_isBlockedByTagRule(instance) then
        return false
    end
    return true
end

function TowerPlacementController:_getPlacementRoot(): BasePart?
    local localPlayer = Players.LocalPlayer
    local character = localPlayer and localPlayer.Character
    if not character then
        return nil
    end
    local rootPart = character:FindFirstChild('HumanoidRootPart')
    if rootPart and rootPart:IsA('BasePart') then
        return rootPart
    end
    return nil
end

function TowerPlacementController:_getSnappedSurfaceCellPosition(targetWorldPosition: Vector3): (Vector3?, string?)
    local rootPart = self:_getPlacementRoot()
    if not rootPart then
        return nil, 'OUT_OF_RANGE'
    end

    local gridSize = tonumber(GameConfig.TOWER_PLACEMENT_GRID_SIZE) or 4
    if gridSize <= 0 then
        gridSize = 4
    end

    local gx = math.floor((targetWorldPosition.X / gridSize) + 0.5)
    local gz = math.floor((targetWorldPosition.Z / gridSize) + 0.5)
    local snappedX = gx * gridSize
    local snappedZ = gz * gridSize

    local raycastParams = self:_buildPlacementRaycastParams()
    local surfaceProbe = workspace:Raycast(
        Vector3.new(snappedX, targetWorldPosition.Y + 256, snappedZ),
        Vector3.new(0, -1024, 0),
        raycastParams
    )
    if not surfaceProbe then
        return nil, 'INVALID_SURFACE'
    end
    if not self:_isBuildSurfaceAllowed(surfaceProbe.Instance) then
        return nil, 'BLOCKED_SURFACE'
    end

    local footprint = self:_getSelectedTowerFootprint()
    local snappedWorldPosition = Vector3.new(snappedX, surfaceProbe.Position.Y + (footprint.Y * 0.5), snappedZ)
    local maxDistance = tonumber(GameConfig.TOWER_MAX_PLACE_DISTANCE) or 45
    if maxDistance <= 0 then
        maxDistance = 45
    end
    local distanceToPlayer = (rootPart.Position - snappedWorldPosition).Magnitude
    if distanceToPlayer > maxDistance then
        return nil, 'OUT_OF_RANGE'
    end

    return snappedWorldPosition, nil
end

function TowerPlacementController:_fireUpgrade()
    if not self._selectedTowerId then
        self:_notify('Select a tower first.')
        return
    end
    if self._latestPhase ~= 'Wave' then
        self:_notify('Upgrade is only available during wave.')
        return
    end
    local model = self._selectedTowerModel
    local localPlayer = Players.LocalPlayer
    local ownerUserId = model and tonumber(model:GetAttribute('OwnerUserId')) or nil
    if not (model and localPlayer and ownerUserId and ownerUserId == localPlayer.UserId) then
        self:_notify('You can only upgrade your own tower.')
        return
    end
    local towerType = tostring(model:GetAttribute('TowerType') or self._selectedTowerType or 'Basic')
    local tier = tonumber(model:GetAttribute('UpgradeTier')) or 0
    local maxTier = tonumber(GameConfig.TOWER_MAX_UPGRADE_TIER) or 3
    if tier >= maxTier then
        self:_notify('Tower is already at max tier.')
        return
    end
    local previewCost = self:_computeUpgradeCostPreview(model, towerType, tier + 1)
    if (tonumber(self._latestCurrency) or 0) < previewCost then
        self:_notify(('Need $%d to upgrade.'):format(previewCost))
        return
    end

    local upgradeRemote = self._remotes.upgrade
    if not upgradeRemote then
        self:_notify('Upgrade unavailable: missing remote.')
        return
    end
    upgradeRemote:FireServer({
        requestId = self:_nextRequestId('upgrade'),
        towerId = self._selectedTowerId,
    })
end

function TowerPlacementController:_fireSell()
    if not self._selectedTowerId then
        self:_notify('Select a tower first.')
        return
    end
    if self._latestPhase ~= 'Wave' then
        self:_notify('Sell is only available during wave.')
        return
    end
    local model = self._selectedTowerModel
    local localPlayer = Players.LocalPlayer
    local ownerUserId = model and tonumber(model:GetAttribute('OwnerUserId')) or nil
    if not (model and localPlayer and ownerUserId and ownerUserId == localPlayer.UserId) then
        self:_notify('You can only sell your own tower.')
        return
    end

    local sellRemote = self._remotes.sell
    if not sellRemote then
        self:_notify('Sell unavailable: missing remote.')
        return
    end
    sellRemote:FireServer({
        requestId = self:_nextRequestId('sell'),
        towerId = self._selectedTowerId,
    })
end

function TowerPlacementController:_fireTargetMode()
    if not self._selectedTowerId then
        self:_notify('Select a tower first.')
        return
    end
    if self._latestPhase ~= 'Wave' then
        self:_notify('Target mode is only available during wave.')
        return
    end
    local model = self._selectedTowerModel
    local localPlayer = Players.LocalPlayer
    local ownerUserId = model and tonumber(model:GetAttribute('OwnerUserId')) or nil
    if not (model and localPlayer and ownerUserId and ownerUserId == localPlayer.UserId) then
        self:_notify('You can only change target mode on your tower.')
        return
    end

    local targetModeRemote = self._remotes.targetMode
    if not targetModeRemote then
        self:_notify('Target mode unavailable: missing remote.')
        return
    end
    targetModeRemote:FireServer({
        requestId = self:_nextRequestId('target'),
        towerId = self._selectedTowerId,
        targetMode = self._selectedTargetMode,
    })
end

function TowerPlacementController:_cycleTargetMode()
    local currentIndex = 1
    for index, modeName in ipairs(TARGET_MODE_ORDER) do
        if modeName == self._selectedTargetMode then
            currentIndex = index
            break
        end
    end
    local nextIndex = currentIndex + 1
    if nextIndex > #TARGET_MODE_ORDER then
        nextIndex = 1
    end
    self._selectedTargetMode = TARGET_MODE_ORDER[nextIndex]
    self:_updateTargetModeUi()
    self:_fireTargetMode()
    self:_emitVisualTelemetry('tower_target_mode', {
        towerId = self._selectedTowerId,
        targetMode = self._selectedTargetMode,
        phase = self._latestPhase,
    })
    self:_notify(('Target mode: %s'):format(self._selectedTargetMode))
end

function TowerPlacementController:_findTowerModelById(towerId: string): Model?
    local map = self:_getActiveMapFolder()
    local towersFolder = map and map:FindFirstChild('Towers')
    if not towersFolder then
        return nil
    end

    for _, child in ipairs(towersFolder:GetChildren()) do
        if child:IsA('Model') then
            local candidate = child:GetAttribute('TowerId')
            if candidate ~= nil and tostring(candidate) == towerId then
                return child
            end
        end
    end
    return nil
end

function TowerPlacementController:_getTowerRole(towerType: string): string
    if towerType == 'Rapid' then
        return 'DPS'
    elseif towerType == 'Sniper' then
        return 'Precision'
    elseif towerType == 'Support' then
        return 'Support'
    end
    return 'General'
end

function TowerPlacementController:_computeTowerTierStatsPreview(towerType: string, tier: number): (number, number, number)
    local baseDamage = tonumber(GameConfig.TOWER_DEFAULT_DAMAGE) or 10
    local baseRange = tonumber(GameConfig.TOWER_DEFAULT_RANGE) or 20
    local baseAttackInterval = tonumber(GameConfig.TOWER_ATTACK_INTERVAL_SECONDS) or 1.0
    local damageMultiplier = tonumber(GameConfig.TOWER_UPGRADE_DAMAGE_MULTIPLIER) or 1.25
    local rangeMultiplier = tonumber(GameConfig.TOWER_UPGRADE_RANGE_MULTIPLIER) or 1.1
    local attackIntervalMultiplier = tonumber(GameConfig.TOWER_UPGRADE_ATTACK_INTERVAL_MULTIPLIER) or 0.92
    local effectiveTier = math.max(0, math.floor(tonumber(tier) or 0))

    local damage = baseDamage * (damageMultiplier ^ effectiveTier)
    local range = baseRange * (rangeMultiplier ^ effectiveTier)
    local attackInterval = baseAttackInterval * (attackIntervalMultiplier ^ effectiveTier)

    local statsByType = GameConfig.TOWER_STATS_BY_TYPE
    if type(statsByType) == 'table' then
        local perType = statsByType[towerType]
        if type(perType) == 'table' then
            local configuredTier = perType[effectiveTier]
            if type(configuredTier) == 'table' then
                damage = tonumber(configuredTier.damage) or damage
                range = tonumber(configuredTier.range) or range
                attackInterval = tonumber(configuredTier.attackInterval) or attackInterval
            end
        end
    end
    if attackInterval < 0.1 then
        attackInterval = 0.1
    end
    return damage, range, attackInterval
end

function TowerPlacementController:_computeUpgradeCostPreview(towerModel: Model, towerType: string, nextTier: number): number
    local costPaid = tonumber(towerModel:GetAttribute('CostPaid')) or 0
    if costPaid <= 0 then
        local costs = GameConfig.TOWER_COSTS
        if type(costs) == 'table' then
            costPaid = tonumber(costs[towerType]) or 0
        end
    end
    local multiplier = tonumber(GameConfig.TOWER_UPGRADE_COST_MULTIPLIER) or 1.5
    if multiplier < 1 then
        multiplier = 1
    end
    local exponent = math.max(0, (tonumber(nextTier) or 1) - 1)
    return math.max(1, math.floor((costPaid * (multiplier ^ exponent)) + 0.5))
end

function TowerPlacementController:_updateTargetModeUi()
    local selectionModel = self._selectedTowerModel
    local localPlayer = Players.LocalPlayer
    local ownerUserId = selectionModel and tonumber(selectionModel:GetAttribute('OwnerUserId')) or nil
    local canChangeMode = self._selectedTowerId ~= nil
        and self._latestPhase == 'Wave'
        and selectionModel ~= nil
        and localPlayer ~= nil
        and ownerUserId ~= nil
        and ownerUserId == localPlayer.UserId
    if self._targetModeButton then
        self._targetModeButton.Text = ('Target: %s'):format(self._selectedTargetMode)
    end
    for modeName, button in pairs(self._targetModeButtons) do
        if button and button.Parent then
            local isSelected = modeName == self._selectedTargetMode
            button.Active = canChangeMode
            button.AutoButtonColor = canChangeMode
            if canChangeMode then
                button.BackgroundColor3 = isSelected and Color3.fromRGB(52, 120, 58) or Color3.fromRGB(42, 42, 42)
                button.TextColor3 = Color3.fromRGB(240, 240, 240)
            else
                button.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
                button.TextColor3 = Color3.fromRGB(155, 155, 155)
            end
        end
    end
end

function TowerPlacementController:_updateSelectionActionUi()
    local hasSelection = self._selectedTowerId ~= nil
    if hasSelection then
        local model = self._selectedTowerModel
        if not model or not model.Parent then
            model = self:_findTowerModelById(self._selectedTowerId)
            self._selectedTowerModel = model
        end
        hasSelection = model ~= nil
    end

    if not hasSelection then
        self._selectedTowerId = nil
        self._selectedTowerModel = nil
    end

    local model = self._selectedTowerModel
    local localPlayer = Players.LocalPlayer
    local ownerUserId = model and tonumber(model:GetAttribute('OwnerUserId')) or nil
    local ownedByLocalPlayer = ownerUserId ~= nil and localPlayer ~= nil and ownerUserId == localPlayer.UserId
    local phaseAllowsActions = self._latestPhase == 'Wave'
    local maxTier = tonumber(GameConfig.TOWER_MAX_UPGRADE_TIER) or 3
    local currentTier = model and (tonumber(model:GetAttribute('UpgradeTier')) or 0) or 0
    local upgradeLockedReason = nil
    if not hasSelection then
        upgradeLockedReason = 'Select tower'
    elseif not phaseAllowsActions then
        upgradeLockedReason = 'Wave only'
    elseif not ownedByLocalPlayer then
        upgradeLockedReason = 'Not owner'
    elseif currentTier >= maxTier then
        upgradeLockedReason = 'Max tier'
    else
        local towerType = tostring(model:GetAttribute('TowerType') or self._selectedTowerType or 'Basic')
        local nextTier = currentTier + 1
        local previewCost = self:_computeUpgradeCostPreview(model, towerType, nextTier)
        if (tonumber(self._latestCurrency) or 0) < previewCost then
            upgradeLockedReason = 'Need $' .. tostring(previewCost)
        end
    end
    local sellLockedReason = nil
    if not hasSelection then
        sellLockedReason = 'Select tower'
    elseif not phaseAllowsActions then
        sellLockedReason = 'Wave only'
    elseif not ownedByLocalPlayer then
        sellLockedReason = 'Not owner'
    end
    local targetLockedReason = nil
    if not hasSelection then
        targetLockedReason = 'Select tower'
    elseif not phaseAllowsActions then
        targetLockedReason = 'Wave only'
    elseif not ownedByLocalPlayer then
        targetLockedReason = 'Not owner'
    end

    if self._upgradeButton and self._upgradeButton.Parent then
        self._upgradeButton.Visible = hasSelection
        self._upgradeButton.Active = hasSelection and upgradeLockedReason == nil
        self._upgradeButton.AutoButtonColor = self._upgradeButton.Active
        self._upgradeButton.Text = if upgradeLockedReason == nil then 'Upgrade' else ('Upgrade [' .. upgradeLockedReason .. ']')
    end
    if self._sellButton and self._sellButton.Parent then
        self._sellButton.Visible = hasSelection
        self._sellButton.Active = hasSelection and sellLockedReason == nil
        self._sellButton.AutoButtonColor = self._sellButton.Active
        self._sellButton.Text = if sellLockedReason == nil then 'Sell' else ('Sell [' .. sellLockedReason .. ']')
    end
    if self._targetModeButton and self._targetModeButton.Parent then
        self._targetModeButton.Visible = hasSelection
        self._targetModeButton.Active = hasSelection and targetLockedReason == nil
        self._targetModeButton.AutoButtonColor = self._targetModeButton.Active
        self._targetModeButton.Text = if targetLockedReason == nil
            then ('Target: %s'):format(self._selectedTargetMode)
            else ('Target: %s [%s]'):format(self._selectedTargetMode, targetLockedReason)
    end
    if self._targetModeFrame and self._targetModeFrame.Parent then
        self._targetModeFrame.Visible = hasSelection
    end
end

function TowerPlacementController:_updateSelectedTowerPanel()
    local panel = self._selectedPanel
    if not panel or not panel.Parent then
        self:_publishSelectedPanelFootprint()
        return
    end

    local labels = self._selectedPanelLabels
    if not self._selectedTowerId then
        panel.Visible = false
        self:_updateSelectionActionUi()
        self:_publishSelectedPanelFootprint()
        return
    end

    local model = self._selectedTowerModel
    if not model or not model.Parent then
        model = self:_findTowerModelById(self._selectedTowerId)
        self._selectedTowerModel = model
    end
    if not model then
        panel.Visible = false
        self:_updateSelectionActionUi()
        self:_publishSelectedPanelFootprint()
        return
    end

    panel.Visible = self._latestPhase == 'Wave'
    self:_updateSelectionActionUi()
    local towerType = tostring(model:GetAttribute('TowerType') or self._selectedTowerType or 'Basic')
    local tier = tonumber(model:GetAttribute('UpgradeTier')) or 0
    local targetMode = model:GetAttribute('TargetMode')
    if type(targetMode) == 'string' and targetMode ~= '' and targetMode ~= self._selectedTargetMode then
        self._selectedTargetMode = targetMode
        self:_updateTargetModeUi()
    end
    local damage = tonumber(model:GetAttribute('Damage')) or 0
    local range = tonumber(model:GetAttribute('Range')) or 0
    local attackInterval = tonumber(model:GetAttribute('AttackInterval')) or 0
    local costPaid = tonumber(model:GetAttribute('CostPaid')) or 0
    if costPaid <= 0 then
        local costs = GameConfig.TOWER_COSTS
        if type(costs) == 'table' then
            costPaid = tonumber(costs[towerType]) or 0
        end
    end
    local refundRatio = tonumber(GameConfig.TOWER_SELL_REFUND_RATIO) or 0.7
    local refundPreview = math.max(0, math.floor((costPaid * refundRatio) + 0.5))
    local maxTier = tonumber(GameConfig.TOWER_MAX_UPGRADE_TIER) or 3
    local lastUpgradeCost = tonumber(model:GetAttribute('LastUpgradeCost')) or 0
    local upgradeLine = ''
    if tier >= maxTier then
        upgradeLine = 'Upgrade: MAX'
    elseif lastUpgradeCost > 0 then
        upgradeLine = ('Upgrade: $%d'):format(lastUpgradeCost)
    else
        local baseCost = 0
        local costs = GameConfig.TOWER_COSTS
        if type(costs) == 'table' then
            baseCost = tonumber(costs[towerType]) or 0
        end
        local multiplier = tonumber(GameConfig.TOWER_UPGRADE_COST_MULTIPLIER) or 1.5
        local nextCost = math.max(1, math.floor((baseCost * multiplier ^ (tier + 1)) + 0.5))
        upgradeLine = ('Upgrade: ~$%d'):format(nextCost)
    end

    labels.title.Text = ('Selected Tower (%s)'):format(tostring(self._selectedTowerId))
    labels.role.Text = ('Role: %s'):format(self:_getTowerRole(towerType))
    labels.typeTier.Text = ('Type: %s | Tier: %d'):format(towerType, tier)
    if labels.portrait then
        labels.portrait.Text = ('Portrait: %s'):format(towerType)
    end
    if towerType == 'Support' then
        local auraByTier = GameConfig.SUPPORT_TOWER_AURA_RADIUS_BY_TIER
        local auraRadius = 0
        if type(auraByTier) == 'table' then
            auraRadius = tonumber(auraByTier[tier]) or 0
        end
        local buffByTier = GameConfig.SUPPORT_TOWER_ATTACK_INTERVAL_MULTIPLIER_BY_TIER
        local buffMultiplier = 1
        if type(buffByTier) == 'table' then
            buffMultiplier = tonumber(buffByTier[tier]) or 1
        end
        labels.stats.Text = ('AURA %.1f | BUFF x%.2f | INT %.2fs'):format(auraRadius, buffMultiplier, attackInterval)
    else
        labels.stats.Text = ('DMG %.0f | RNG %.1f | INT %.2fs'):format(damage, range, attackInterval)
    end
    if labels.targetMode then
        labels.targetMode.Text = ('Target mode: %s'):format(self._selectedTargetMode)
    end
    labels.upgrade.Text = upgradeLine
    labels.sell.Text = ('Sell refund: ~$%d'):format(refundPreview)
    if labels.delta then
        if tier >= maxTier then
            labels.delta.Text = 'Next upgrade delta: MAX'
        else
            local nextTier = tier + 1
            local nextDamage, nextRange, nextAttackInterval = self:_computeTowerTierStatsPreview(towerType, nextTier)
            local previewUpgradeCost = self:_computeUpgradeCostPreview(model, towerType, nextTier)
            if towerType == 'Support' then
                local auraByTier = GameConfig.SUPPORT_TOWER_AURA_RADIUS_BY_TIER
                local currentAura = type(auraByTier) == 'table' and (tonumber(auraByTier[tier]) or 0) or 0
                local nextAura = type(auraByTier) == 'table' and (tonumber(auraByTier[nextTier]) or currentAura) or currentAura
                labels.delta.Text = ('Next: Aura +%.1f | Int %.2f->%.2f | Cost $%d'):format(
                    nextAura - currentAura,
                    attackInterval,
                    nextAttackInterval,
                    previewUpgradeCost
                )
            else
                labels.delta.Text = ('Next: Dmg +%.0f | Rng +%.1f | Int %.2f->%.2f | Cost $%d'):format(
                    nextDamage - damage,
                    nextRange - range,
                    attackInterval,
                    nextAttackInterval,
                    previewUpgradeCost
                )
            end
        end
    end
    self:_publishSelectedPanelFootprint()
end

function TowerPlacementController:_publishSelectedPanelFootprint()
    local localPlayer = Players.LocalPlayer
    local playerGui = localPlayer and localPlayer:FindFirstChildOfClass('PlayerGui')
    if not playerGui then
        return
    end

    local panel = self._selectedPanel
    local visible = panel ~= nil and panel.Parent ~= nil and panel.Visible == true
    local left = 0
    local top = 0
    local right = 0
    local bottom = 0
    if visible and panel then
        left = math.floor(panel.AbsolutePosition.X + 0.5)
        top = math.floor(panel.AbsolutePosition.Y + 0.5)
        right = left + math.floor(panel.AbsoluteSize.X + 0.5)
        bottom = top + math.floor(panel.AbsoluteSize.Y + 0.5)
    end

    local signature = ('%s|%d|%d|%d|%d'):format(tostring(visible), left, top, right, bottom)
    if signature == self._selectedPanelLayoutSignature then
        return
    end
    self._selectedPanelLayoutSignature = signature

    playerGui:SetAttribute(SELECTED_PANEL_LAYOUT_VISIBLE_ATTR, visible)
    playerGui:SetAttribute(SELECTED_PANEL_LAYOUT_LEFT_ATTR, left)
    playerGui:SetAttribute(SELECTED_PANEL_LAYOUT_TOP_ATTR, top)
    playerGui:SetAttribute(SELECTED_PANEL_LAYOUT_RIGHT_ATTR, right)
    playerGui:SetAttribute(SELECTED_PANEL_LAYOUT_BOTTOM_ATTR, bottom)
end

function TowerPlacementController:_nextRequestId(prefix: string): string
    self._requestSeq += 1
    local userId = Players.LocalPlayer and Players.LocalPlayer.UserId or 0
    local millis = math.floor(os.clock() * 1000)
    return ('%s-%d-%d-%d'):format(prefix, userId, millis, self._requestSeq)
end

function TowerPlacementController:_setSelectedTowerType(towerType: string, armPlacement: boolean?)
    if type(towerType) ~= 'string' or towerType == '' then
        return
    end

    local configuredCosts = GameConfig.TOWER_COSTS
    if type(configuredCosts) ~= 'table' or configuredCosts[towerType] == nil then
        self:_notify(('Tower type not configured: %s'):format(towerType))
        return
    end

    local wasPlacingArmed = self._placingArmed
    local previousTowerType = self._selectedTowerType
    self._selectedTowerType = towerType
    if previousTowerType ~= towerType then
        self._placementRotationQuarter = 0
    end
    if armPlacement == true then
        if wasPlacingArmed and previousTowerType == towerType then
            self:_setPlacementArmed(false)
        else
            self:_setPlacementArmed(true)
        end
    else
        self:_updatePlacementUi()
        self:_notify(('Placement tower: %s'):format(towerType))
    end
end

function TowerPlacementController:_getAvailableTowerTypes(): { string }
    local result = {}
    local configuredCosts = GameConfig.TOWER_COSTS
    if type(configuredCosts) ~= 'table' then
        return { 'Basic' }
    end

    local preferredOrder = { 'Basic', 'Rapid', 'Sniper', 'Support' }
    local seen = {}
    for _, towerType in ipairs(preferredOrder) do
        if configuredCosts[towerType] ~= nil then
            table.insert(result, towerType)
            seen[towerType] = true
        end
    end
    for towerType in pairs(configuredCosts) do
        if type(towerType) == 'string' and not seen[towerType] then
            table.insert(result, towerType)
        end
    end

    return result
end

function TowerPlacementController:_refreshTowerTypeButtons()
    for towerType, button in pairs(self._towerTypeButtons) do
        if button and button.Parent then
            local isSelected = towerType == self._selectedTowerType
            HUDTheme.applyInventoryButtonState(button, isSelected)
        end
    end
end

function TowerPlacementController:_updatePlacementUi()
    self:_refreshTowerTypeButtons()
    if self._placeButton and self._placeButton.Parent then
        self._placeButton.Visible = self._placingArmed
        self._placeButton.Active = self._placingArmed and self._previewValid
        self._placeButton.AutoButtonColor = self._placeButton.Active
    end
    if self._rotateButton and self._rotateButton.Parent then
        self._rotateButton.Visible = self._placingArmed
    end
    if self._cancelButton and self._cancelButton.Parent then
        self._cancelButton.Visible = self._placingArmed
    end
end

function TowerPlacementController:_getSelectedTowerRange(): number
    local towerType = self._selectedTowerType
    local statsByType = GameConfig.TOWER_STATS_BY_TYPE
    if type(statsByType) == 'table' then
        local typeStats = statsByType[towerType]
        if type(typeStats) == 'table' then
            local tier0 = typeStats[0]
            if type(tier0) == 'table' then
                local range = tonumber(tier0.range)
                if range and range > 0 then
                    return range
                end
            end
        end
    end

    local defaultRange = tonumber(GameConfig.TOWER_DEFAULT_RANGE) or 20
    if defaultRange <= 0 then
        defaultRange = 20
    end
    return defaultRange
end

function TowerPlacementController:_ensurePlacementPreview()
    if self._previewFolder and self._previewFolder.Parent then
        return
    end

    local folder = Instance.new('Folder')
    folder.Name = 'ClientPlacementPreview'
    folder.Parent = workspace
    self._previewFolder = folder

    local ghost = Instance.new('Part')
    ghost.Name = 'Ghost'
    ghost.Anchored = true
    ghost.CanCollide = false
    ghost.CanTouch = false
    ghost.CanQuery = false
    ghost.Transparency = 0.55
    ghost.Material = Enum.Material.ForceField
    ghost.Size = Vector3.new(3, 4, 3)
    ghost.CastShadow = false
    ghost.Parent = folder
    self._previewGhost = ghost

    local rangePart = Instance.new('Part')
    rangePart.Name = 'Range'
    rangePart.Anchored = true
    rangePart.CanCollide = false
    rangePart.CanTouch = false
    rangePart.CanQuery = false
    rangePart.Transparency = 0.72
    rangePart.Material = Enum.Material.Neon
    rangePart.Shape = Enum.PartType.Cylinder
    rangePart.Size = Vector3.new(6, 0.16, 6)
    rangePart.CastShadow = false
    rangePart.Parent = folder
    self._previewRange = rangePart

    local footprintPart = Instance.new('Part')
    footprintPart.Name = 'Footprint'
    footprintPart.Anchored = true
    footprintPart.CanCollide = false
    footprintPart.CanTouch = false
    footprintPart.CanQuery = false
    footprintPart.Transparency = 0.78
    footprintPart.Material = Enum.Material.Neon
    footprintPart.Size = Vector3.new(3, 0.14, 3)
    footprintPart.CastShadow = false
    footprintPart.Parent = folder
    self._previewFootprint = footprintPart

    folder.Parent = workspace
    folder:SetAttribute('Visible', false)
end

function TowerPlacementController:_setPlacementPreviewVisible(isVisible: boolean)
    if not self._previewGhost or not self._previewRange or not self._previewFootprint then
        return
    end
    self._previewGhost.Parent = isVisible and self._previewFolder or nil
    self._previewRange.Parent = isVisible and self._previewFolder or nil
    self._previewFootprint.Parent = isVisible and self._previewFolder or nil
end

function TowerPlacementController:_setPreviewHint(text: string, screenPosition: Vector2?)
    if not self._previewHintLabel then
        return
    end
    if not self._placingArmed or text == '' then
        self._previewHintLabel.Visible = false
        self._previewHintLabel.Text = ''
        return
    end

    local _ = screenPosition
    self._previewHintLabel.Visible = true
    self._previewHintLabel.Text = text
end

function TowerPlacementController:_updatePlacementPreview()
    if not self._running then
        return
    end
    if not self._placingArmed then
        self._previewPosition = nil
        self._previewValid = false
        self._previewReason = ''
        self:_setPreviewHint('', nil)
        self:_setPlacementPreviewVisible(false)
        return
    end

    self:_ensurePlacementPreview()
    if not self._previewGhost or not self._previewRange or not self._previewFootprint then
        return
    end

    local mouseLocation = UserInputService:GetMouseLocation()
    local raycastResult = self:_getRaycastResult(mouseLocation)
    local targetPosition = raycastResult and raycastResult.Position or nil
    local snappedPosition = nil
    local localRejectReason = nil
    if targetPosition then
        snappedPosition, localRejectReason = self:_getSnappedSurfaceCellPosition(targetPosition)
    end

    if not snappedPosition then
        self._previewPosition = nil
        self._previewValid = false
        if not targetPosition then
            self._previewReason = 'AIM_AT_WORLD'
            self:_setPreviewHint(PREVIEW_REASON_TO_HINT[self._previewReason], mouseLocation)
        elseif localRejectReason == 'BLOCKED_SURFACE' then
            self._previewReason = 'BLOCKED_SURFACE'
            self:_setPreviewHint(PREVIEW_REASON_TO_HINT[self._previewReason], mouseLocation)
        elseif localRejectReason == 'INVALID_SURFACE' then
            self._previewReason = 'INVALID_SURFACE'
            self:_setPreviewHint(PREVIEW_REASON_TO_HINT[self._previewReason], mouseLocation)
        elseif localRejectReason == 'OUT_OF_RANGE' then
            self._previewReason = 'OUT_OF_RANGE'
            self:_setPreviewHint(PREVIEW_REASON_TO_HINT[self._previewReason], mouseLocation)
        else
            self._previewReason = 'OUT_OF_RANGE_OR_INVALID_SURFACE'
            self:_setPreviewHint(PREVIEW_REASON_TO_HINT[self._previewReason], mouseLocation)
        end
        local nowTime = os.clock()
        if
            self._lastPlacementFailureReasonCode == 'CELL_OCCUPIED'
            and (nowTime - self._lastPlacementFailureAt) <= 2.0
        then
            self._previewReason = 'CELL_OCCUPIED'
            self:_setPreviewHint(PREVIEW_REASON_TO_HINT[self._previewReason], mouseLocation)
        end
        if self._previewReasonTelemetryLast ~= self._previewReason then
            self._previewReasonTelemetryLast = self._previewReason
            self:_emitVisualTelemetry('placement_preview', {
                reason = self._previewReason,
                phase = self._latestPhase,
                armed = self._placingArmed,
            })
        end
        self:_setPlacementPreviewVisible(false)
        self:_updatePlacementUi()
        return
    end

    self._previewPosition = snappedPosition
    self._previewValid = true
    self._previewReason = 'OK'
    if self._previewReasonTelemetryLast ~= self._previewReason then
        self._previewReasonTelemetryLast = self._previewReason
        self:_emitVisualTelemetry('placement_preview', {
            reason = self._previewReason,
            phase = self._latestPhase,
            armed = self._placingArmed,
        })
    end
    self:_setPlacementPreviewVisible(true)
    self:_setPreviewHint(PREVIEW_REASON_TO_HINT[self._previewReason], mouseLocation)

    local isValid = self._previewValid
    local visualConfig = self:_getPreviewVisualConfig()
    local previewColor = isValid and visualConfig.validColor or visualConfig.invalidColor
    self._previewGhost.Color = previewColor
    self._previewRange.Color = previewColor
    self._previewFootprint.Color = previewColor
    self._previewGhost.Transparency = if isValid
        then visualConfig.ghostValidTransparency
        else visualConfig.ghostInvalidTransparency
    self._previewRange.Transparency = visualConfig.rangeTransparency
    self._previewFootprint.Transparency = visualConfig.footprintTransparency

    local gridSize = tonumber(GameConfig.TOWER_PLACEMENT_GRID_SIZE) or 4
    if gridSize <= 0 then
        gridSize = 4
    end

    local footprint = self:_getSelectedTowerFootprint()
    local rotationRad = math.rad((self._placementRotationQuarter % 4) * 90)
    local rotatedFootprintX = footprint.X
    local rotatedFootprintZ = footprint.Z
    if self._placementRotationQuarter % 2 == 1 then
        rotatedFootprintX = footprint.Z
        rotatedFootprintZ = footprint.X
    end

    self._previewGhost.Size = Vector3.new(rotatedFootprintX, footprint.Y, rotatedFootprintZ)
    self._previewGhost.CFrame = CFrame.new(snappedPosition + Vector3.new(0, footprint.Y * 0.5, 0))
        * CFrame.Angles(0, rotationRad, 0)

    local range = self:_getSelectedTowerRange()
    local diameter = math.max(2, range * 2)
    self._previewRange.Size = Vector3.new(diameter, 0.16, diameter)
    self._previewRange.CFrame = CFrame.new(snappedPosition + Vector3.new(0, 0.06, 0))
    self._previewFootprint.Size = Vector3.new(rotatedFootprintX, 0.14, rotatedFootprintZ)
    self._previewFootprint.CFrame = CFrame.new(snappedPosition + Vector3.new(0, 0.07, 0))
        * CFrame.Angles(0, rotationRad, 0)
    self:_updatePlacementUi()
end

function TowerPlacementController:_setPlacementArmed(isArmed: boolean)
    self._placingArmed = isArmed
    if not isArmed then
        self._placementRotationQuarter = 0
    end
    self:_updatePlacementUi()
    self:_updatePlacementPreview()
end

function TowerPlacementController:_togglePlacement()
    self:_setPlacementArmed(not self._placingArmed)
end

function TowerPlacementController:_attemptPlaceFromPreview()
    if self._previewValid and self._previewPosition then
        self:_firePlace(self._previewPosition)
    else
        self:_notify('Placement blocked: aim at a valid in-range build surface.')
    end
end

function TowerPlacementController:_handlePointer(screenPosition: Vector2)
    local result = self:_getRaycastResult(screenPosition)
    if not result then
        return
    end

    if self._placingArmed then
        self:_attemptPlaceFromPreview()
        return
    end

    local towerId = self:_resolveTowerIdFromHit(result.Instance)
    if towerId then
        self._selectedTowerId = towerId
        self._selectedTowerModel = self:_findTowerModelById(towerId)
        if self._selectedTowerModel then
            local targetMode = self._selectedTowerModel:GetAttribute('TargetMode')
            if type(targetMode) == 'string' and targetMode ~= '' then
                self._selectedTargetMode = targetMode
                self:_updateTargetModeUi()
            end
        end
        self:_updateSelectedTowerPanel()
        self:_emitVisualTelemetry('tower_selection', {
            towerId = towerId,
            phase = self._latestPhase,
            interaction = 'selected',
        })
        self:_notify(('Selected tower %s'):format(towerId))
    else
        self._selectedTowerId = nil
        self._selectedTowerModel = nil
        self._selectedTargetMode = 'First'
        self:_updateTargetModeUi()
        self:_updateSelectionActionUi()
        self:_updateSelectedTowerPanel()
        self:_emitVisualTelemetry('tower_selection', {
            towerId = nil,
            phase = self._latestPhase,
            interaction = 'cleared',
        })
    end
end

function TowerPlacementController:_createHud()
    local playerGui = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass('PlayerGui')
    if not playerGui then
        return
    end

    local screenGui = Instance.new('ScreenGui')
    screenGui.Name = 'TowerPlacementControls'
    screenGui.ResetOnSpawn = false
    screenGui.DisplayOrder = 20
    screenGui.IgnoreGuiInset = true
    screenGui.Parent = playerGui
    self._screenGui = screenGui
    local touchPreferred = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
    local topInset, bottomInset = getSafeInsets()
    local safePadding = math.max(0, math.floor(tonumber(GameConfig.UI_SAFE_AREA_PADDING) or 8))
    local safeTopY = math.floor(topInset.Y) + safePadding
    local safeBottomY = math.floor(bottomInset.Y) + safePadding
    local camera = workspace.CurrentCamera
    local viewportHeight = camera and camera.ViewportSize.Y or 720
    local touchButtonWidth = math.max(150, math.floor(tonumber(GameConfig.UI_TOUCH_MIN_BUTTON_WIDTH) or 150))
    local touchButtonHeight = math.max(50, math.floor(tonumber(GameConfig.UI_TOUCH_MIN_BUTTON_HEIGHT) or 48))
    local actionRightX = touchPreferred and (touchButtonWidth + 12) or 122
    local actionBaseBottomY = (touchPreferred and 12 or 8) + safeBottomY
    local mobileInventoryScale = 0.78
    local inventoryHudLayout = type(GameConfig.INVENTORY_HUD_LAYOUT) == 'table' and GameConfig.INVENTORY_HUD_LAYOUT or {}
    local inventoryHudScale = tonumber(inventoryHudLayout.scale) or 0.8
    inventoryHudScale = math.clamp(inventoryHudScale, 0.6, 1.2)
    local inventoryDropViewportPct = tonumber(inventoryHudLayout.dropViewportPct) or 0.05
    inventoryDropViewportPct = math.clamp(inventoryDropViewportPct, 0, 0.2)
    local inventoryLowerPixels = math.floor((viewportHeight * inventoryDropViewportPct) + 0.5)

    local function createActionButton(name: string, text: string, order: number): TextButton
        local button = Instance.new('TextButton')
        button.Name = name
        button.Text = text
        HUDTheme.applyText(button, {
            textXAlignment = Enum.TextXAlignment.Center,
            textSize = touchPreferred and 13 or 11,
        })
        button.Size = touchPreferred and UDim2.fromOffset(touchButtonWidth, touchButtonHeight)
            or UDim2.fromOffset(132, 42)
        button.Position = UDim2.new(
            0,
            12,
            1,
            -(
                    if touchPreferred
                        then ((order * (touchButtonHeight + 6)) + actionBaseBottomY)
                        else ((order * 48) + actionBaseBottomY)
                )
        )
        button.AutoButtonColor = false
        button.Parent = screenGui
        HUDTheme.applySurface(button, {
            useGradient = false,
        })
        return button
    end

    local function createInventoryCard(parent: GuiObject, index: number, towerType: string): TextButton
        local towerButton = Instance.new('TextButton')
        towerButton.Name = ('TowerType_%s'):format(towerType)
        local scaledMobileInventory = mobileInventoryScale * inventoryHudScale
        local cardWidth = touchPreferred and math.max(64, math.floor((110 * scaledMobileInventory) + 0.5))
            or math.max(80, math.floor((102 * inventoryHudScale) + 0.5))
        local cardHeight = touchPreferred and math.max(34, math.floor((52 * scaledMobileInventory) + 0.5))
            or math.max(36, math.floor((48 * inventoryHudScale) + 0.5))
        local spacing = touchPreferred and math.max(68, math.floor((114 * scaledMobileInventory) + 0.5))
            or math.max(84, math.floor((106 * inventoryHudScale) + 0.5))
        towerButton.Size = UDim2.fromOffset(cardWidth, cardHeight)
        towerButton.Position = UDim2.fromOffset(6 + ((index - 1) * spacing), math.floor((22 * inventoryHudScale) + 0.5))
        towerButton.TextWrapped = false
        towerButton.TextYAlignment = Enum.TextYAlignment.Center
        towerButton.AutoButtonColor = false
        HUDTheme.applyText(towerButton, {
            textXAlignment = Enum.TextXAlignment.Center,
            textSize = touchPreferred and 12 or 11,
        })
        towerButton.Parent = parent
        towerButton.Text = ('%d %s'):format(index, towerType)
        HUDTheme.applyInventoryButtonState(towerButton, false)
        return towerButton
    end

    local upgradeButton = createActionButton('UpgradeButton', 'Upgrade', 3)
    upgradeButton.Size = touchPreferred and UDim2.fromOffset(touchButtonWidth - 18, touchButtonHeight)
        or UDim2.fromOffset(114, 36)
    upgradeButton.Position = touchPreferred
            and UDim2.new(1, -actionRightX, 1, -(actionBaseBottomY + (touchButtonHeight * 3) + 24))
        or UDim2.new(1, -122, 1, -(actionBaseBottomY + 120))
    local sellButton = createActionButton('SellButton', 'Sell', 2)
    sellButton.Size = touchPreferred and UDim2.fromOffset(touchButtonWidth - 18, touchButtonHeight)
        or UDim2.fromOffset(114, 36)
    sellButton.Position = touchPreferred
            and UDim2.new(1, -actionRightX, 1, -(actionBaseBottomY + (touchButtonHeight * 2) + 16))
        or UDim2.new(1, -122, 1, -(actionBaseBottomY + 80))
    local targetModeButton = createActionButton('TargetModeButton', 'Target: First', 1)
    targetModeButton.Size = touchPreferred and UDim2.fromOffset(touchButtonWidth - 18, touchButtonHeight)
        or UDim2.fromOffset(114, 36)
    targetModeButton.Position = touchPreferred
            and UDim2.new(1, -actionRightX, 1, -(actionBaseBottomY + (touchButtonHeight * 4) + 32))
        or UDim2.new(1, -122, 1, -(actionBaseBottomY + 160))
    targetModeButton.Visible = false
    self._targetModeButton = targetModeButton
    local placeActionButton = Instance.new('TextButton')
    placeActionButton.Name = 'PlaceActionButton'
    placeActionButton.Size = touchPreferred and UDim2.fromOffset(120, touchButtonHeight) or UDim2.fromOffset(104, 34)
    placeActionButton.Position = touchPreferred and UDim2.new(0, 12, 1, -(safeBottomY + 122))
        or UDim2.new(0.5, -146, 1, -(safeBottomY + 116))
    placeActionButton.Text = 'Place (Enter)'
    placeActionButton.Visible = false
    placeActionButton.Parent = screenGui
    HUDTheme.applySurface(placeActionButton, {
        useGradient = false,
        cornerRadius = 10,
    })
    HUDTheme.applyText(placeActionButton, {
        textXAlignment = Enum.TextXAlignment.Center,
        textSize = touchPreferred and 12 or 11,
    })
    self._placeButton = placeActionButton

    local rotateActionButton = Instance.new('TextButton')
    rotateActionButton.Name = 'RotateActionButton'
    rotateActionButton.Size = touchPreferred and UDim2.fromOffset(120, touchButtonHeight) or UDim2.fromOffset(104, 34)
    rotateActionButton.Position = touchPreferred and UDim2.new(0, 138, 1, -(safeBottomY + 122))
        or UDim2.new(0.5, -36, 1, -(safeBottomY + 116))
    rotateActionButton.Text = 'Rotate (R)'
    rotateActionButton.Visible = false
    rotateActionButton.Parent = screenGui
    HUDTheme.applySurface(rotateActionButton, {
        useGradient = false,
        cornerRadius = 10,
    })
    HUDTheme.applyText(rotateActionButton, {
        textXAlignment = Enum.TextXAlignment.Center,
        textSize = touchPreferred and 12 or 11,
    })
    self._rotateButton = rotateActionButton

    local cancelActionButton = Instance.new('TextButton')
    cancelActionButton.Name = 'CancelActionButton'
    cancelActionButton.Size = touchPreferred and UDim2.fromOffset(120, touchButtonHeight) or UDim2.fromOffset(104, 34)
    cancelActionButton.Position = touchPreferred and UDim2.new(0, 264, 1, -(safeBottomY + 122))
        or UDim2.new(0.5, 74, 1, -(safeBottomY + 116))
    cancelActionButton.Text = 'Cancel (C)'
    cancelActionButton.Visible = false
    cancelActionButton.Parent = screenGui
    HUDTheme.applySurface(cancelActionButton, {
        useGradient = false,
        cornerRadius = 10,
    })
    HUDTheme.applyText(cancelActionButton, {
        textXAlignment = Enum.TextXAlignment.Center,
        textSize = touchPreferred and 12 or 11,
    })
    self._cancelButton = cancelActionButton

    self._placementStatusLabel = nil
    local towerLoadoutFrame = Instance.new('Frame')
    towerLoadoutFrame.Name = 'TowerLoadoutFrame'
    local mobileInventoryWidth = math.max(224, math.floor((462 * mobileInventoryScale * inventoryHudScale) + 0.5))
    local mobileInventoryHeight = math.max(54, math.floor((84 * mobileInventoryScale * inventoryHudScale) + 0.5))
    local desktopInventoryWidth = math.max(340, math.floor((430 * inventoryHudScale) + 0.5))
    local desktopInventoryHeight = math.max(60, math.floor((76 * inventoryHudScale) + 0.5))
    local touchInventoryOffset = math.max(20, 58 - inventoryLowerPixels)
    local desktopInventoryOffset = math.max(20, 60 - inventoryLowerPixels)
    towerLoadoutFrame.Size = touchPreferred and UDim2.fromOffset(mobileInventoryWidth, mobileInventoryHeight)
        or UDim2.fromOffset(desktopInventoryWidth, desktopInventoryHeight)
    towerLoadoutFrame.Position = touchPreferred
            and UDim2.new(0.5, -math.floor(mobileInventoryWidth / 2), 1, -(safeBottomY + touchInventoryOffset))
        or UDim2.new(0.5, -math.floor(desktopInventoryWidth / 2), 1, -(safeBottomY + desktopInventoryOffset))
    towerLoadoutFrame.Parent = screenGui
    self._towerLoadoutFrame = towerLoadoutFrame
    HUDTheme.applySurface(towerLoadoutFrame)

    local towerTitle = Instance.new('TextLabel')
    towerTitle.Name = 'TowerSelectionTitle'
    towerTitle.Size = UDim2.new(0.55, -8, 0, 18)
    towerTitle.Position = UDim2.fromOffset(6, 2)
    towerTitle.BackgroundTransparency = 1
    HUDTheme.applyText(towerTitle, {
        textXAlignment = Enum.TextXAlignment.Left,
    })
    towerTitle.Text = 'Inventory'
    towerTitle.Parent = towerLoadoutFrame

    local phaseStatusLabel = Instance.new('TextLabel')
    phaseStatusLabel.Name = 'PhaseStatus'
    phaseStatusLabel.Size = UDim2.new(0.45, -8, 0, 18)
    phaseStatusLabel.Position = UDim2.new(0.55, 0, 0, 2)
    phaseStatusLabel.BackgroundTransparency = 1
    phaseStatusLabel.TextXAlignment = Enum.TextXAlignment.Right
    phaseStatusLabel.Parent = towerLoadoutFrame
    HUDTheme.applyText(phaseStatusLabel, {
        textXAlignment = Enum.TextXAlignment.Right,
        textSize = touchPreferred and 11 or 10,
    })
    self._phaseStatusLabel = phaseStatusLabel

    local availableTowerTypes = self:_getAvailableTowerTypes()
    for index, towerType in ipairs(availableTowerTypes) do
        local towerButton = createInventoryCard(towerLoadoutFrame, index, towerType)
        self._towerTypeButtons[towerType] = towerButton

        table.insert(
            self._connections,
            towerButton.MouseButton1Click:Connect(function()
                self:_setSelectedTowerType(towerType, true)
            end)
        )
    end

    table.insert(
        self._connections,
        upgradeButton.MouseButton1Click:Connect(function()
            self:_fireUpgrade()
        end)
    )
    table.insert(
        self._connections,
        sellButton.MouseButton1Click:Connect(function()
            self:_fireSell()
        end)
    )
    table.insert(
        self._connections,
        placeActionButton.MouseButton1Click:Connect(function()
            self:_attemptPlaceFromPreview()
        end)
    )
    table.insert(
        self._connections,
        rotateActionButton.MouseButton1Click:Connect(function()
            self:_rotatePlacement()
        end)
    )
    table.insert(
        self._connections,
        cancelActionButton.MouseButton1Click:Connect(function()
            self:_cancelPlacement()
        end)
    )
    local previewHintLabel = Instance.new('TextLabel')
    previewHintLabel.Name = 'PlacementPreviewHint'
    previewHintLabel.Size = touchPreferred and UDim2.fromOffset(390, 32) or UDim2.fromOffset(340, 26)
    previewHintLabel.Position = touchPreferred and UDim2.new(0, 12, 1, -(safeBottomY + 196))
        or UDim2.new(0.5, -170, 1, -(safeBottomY + 182))
    HUDTheme.applyText(previewHintLabel, {
        textXAlignment = Enum.TextXAlignment.Center,
    })
    previewHintLabel.Visible = false
    previewHintLabel.ZIndex = 21
    previewHintLabel.Parent = screenGui
    HUDTheme.applySurface(previewHintLabel, {
        useGradient = false,
    })
    self._previewHintLabel = previewHintLabel

    local actionHintLabel = Instance.new('TextLabel')
    actionHintLabel.Name = 'PlacementActionHint'
    actionHintLabel.Size = touchPreferred and UDim2.fromOffset(390, 30) or UDim2.fromOffset(340, 24)
    actionHintLabel.Position = touchPreferred and UDim2.new(0, 12, 1, -(safeBottomY + 230))
        or UDim2.new(0.5, -170, 1, -(safeBottomY + 212))
    actionHintLabel.Visible = false
    actionHintLabel.ZIndex = 21
    actionHintLabel.Parent = screenGui
    HUDTheme.applySurface(actionHintLabel, {
        useGradient = false,
    })
    HUDTheme.applyText(actionHintLabel, {
        textXAlignment = Enum.TextXAlignment.Center,
        textSize = touchPreferred and 12 or 11,
    })
    self._placementActionHintLabel = actionHintLabel

    local targetModeFrame = Instance.new('Frame')
    targetModeFrame.Name = 'TargetModeFrame'
    targetModeFrame.Size = touchPreferred and UDim2.fromOffset(244, 42) or UDim2.fromOffset(212, 36)
    targetModeFrame.Position = touchPreferred
            and UDim2.new(1, -(actionRightX + 252), 1, -(actionBaseBottomY + (touchButtonHeight * 4) + 32))
        or UDim2.new(1, -342, 1, -(actionBaseBottomY + 160))
    targetModeFrame.Visible = false
    targetModeFrame.Parent = screenGui
    self._targetModeFrame = targetModeFrame
    HUDTheme.applySurface(targetModeFrame, {
        useGradient = false,
    })

    local modeButtonWidth = touchPreferred and 76 or 66
    for index, modeName in ipairs(TARGET_MODE_ORDER) do
        local modeButton = Instance.new('TextButton')
        modeButton.Name = ('Mode_%s'):format(modeName)
        modeButton.Size = touchPreferred and UDim2.fromOffset(modeButtonWidth, 34)
            or UDim2.fromOffset(modeButtonWidth, 28)
        modeButton.Position = UDim2.fromOffset(6 + ((index - 1) * (modeButtonWidth + 4)), touchPreferred and 4 or 4)
        modeButton.Text = modeName
        modeButton.AutoButtonColor = false
        modeButton.Parent = targetModeFrame
        HUDTheme.applySurface(modeButton, {
            useGradient = false,
        })
        HUDTheme.applyText(modeButton, {
            textXAlignment = Enum.TextXAlignment.Center,
            textSize = touchPreferred and 12 or 11,
        })
        self._targetModeButtons[modeName] = modeButton

        table.insert(
            self._connections,
            modeButton.MouseButton1Click:Connect(function()
                if not self._selectedTowerId then
                    self:_notify('Select a tower first.')
                    return
                end
                if self._latestPhase ~= 'Wave' then
                    self:_notify('Target mode is only available during wave.')
                    return
                end
                local selectedModel = self._selectedTowerModel
                local localPlayer = Players.LocalPlayer
                local ownerUserId = selectedModel and tonumber(selectedModel:GetAttribute('OwnerUserId')) or nil
                if not (selectedModel and localPlayer and ownerUserId and ownerUserId == localPlayer.UserId) then
                    self:_notify('You can only change target mode on your tower.')
                    return
                end
                self._selectedTargetMode = modeName
                self:_updateTargetModeUi()
                self:_fireTargetMode()
            end)
        )
    end

    local selectedPanel = Instance.new('Frame')
    selectedPanel.Name = 'SelectedTowerPanel'
    selectedPanel.Size = touchPreferred and UDim2.fromOffset(300, 176) or UDim2.fromOffset(380, 226)
    selectedPanel.Position = touchPreferred and UDim2.new(1, -312, 0, safeTopY + 54)
        or UDim2.new(1, -392, 0, safeTopY + 72)
    selectedPanel.Visible = false
    selectedPanel.Parent = screenGui
    self._selectedPanel = selectedPanel
    HUDTheme.applySurface(selectedPanel)

    local portraitFrame = Instance.new('Frame')
    portraitFrame.Name = 'PortraitFrame'
    portraitFrame.Size = touchPreferred and UDim2.fromOffset(72, 72) or UDim2.fromOffset(88, 88)
    portraitFrame.Position = touchPreferred and UDim2.fromOffset(220, 8) or UDim2.fromOffset(284, 8)
    portraitFrame.Parent = selectedPanel
    HUDTheme.applySurface(portraitFrame, {
        useGradient = false,
        cornerRadius = 8,
    })
    self._selectedPortraitFrame = portraitFrame

    local function makePanelLabel(name: string, y: number, size: number): TextLabel
        local label = Instance.new('TextLabel')
        label.Name = name
        label.Size = UDim2.new(1, -10, 0, size)
        label.Position = UDim2.fromOffset(6, y)
        label.BackgroundTransparency = 1
        HUDTheme.applyText(label, {
            textXAlignment = Enum.TextXAlignment.Left,
        })
        label.Text = ''
        label.Parent = selectedPanel
        return label
    end

    if touchPreferred then
        self._selectedPanelLabels.title = makePanelLabel('Title', 6, 20)
        self._selectedPanelLabels.role = makePanelLabel('Role', 26, 18)
        self._selectedPanelLabels.typeTier = makePanelLabel('TypeTier', 44, 18)
        self._selectedPanelLabels.targetMode = makePanelLabel('TargetMode', 62, 18)
        self._selectedPanelLabels.portrait = makePanelLabel('Portrait', 80, 18)
        self._selectedPanelLabels.stats = makePanelLabel('Stats', 102, 18)
        self._selectedPanelLabels.delta = makePanelLabel('Delta', 122, 24)
        self._selectedPanelLabels.upgrade = makePanelLabel('Upgrade', 146, 16)
        self._selectedPanelLabels.sell = makePanelLabel('Sell', 162, 14)
    else
        self._selectedPanelLabels.title = makePanelLabel('Title', 6, 22)
        self._selectedPanelLabels.role = makePanelLabel('Role', 30, 20)
        self._selectedPanelLabels.typeTier = makePanelLabel('TypeTier', 52, 20)
        self._selectedPanelLabels.targetMode = makePanelLabel('TargetMode', 72, 20)
        self._selectedPanelLabels.portrait = makePanelLabel('Portrait', 94, 20)
        self._selectedPanelLabels.stats = makePanelLabel('Stats', 118, 22)
        self._selectedPanelLabels.delta = makePanelLabel('Delta', 144, 34)
        self._selectedPanelLabels.upgrade = makePanelLabel('Upgrade', 182, 20)
        self._selectedPanelLabels.sell = makePanelLabel('Sell', 204, 20)
    end

    self._upgradeButton = upgradeButton
    self._sellButton = sellButton
    self._targetModeButton = targetModeButton
    table.insert(
        self._connections,
        targetModeButton.MouseButton1Click:Connect(function()
            if not targetModeButton.Active then
                return
            end
            self:_cycleTargetMode()
        end)
    )
    self:_refreshTowerTypeButtons()
    self:_updateTargetModeUi()
    self:_updateSelectionActionUi()
    self:_updatePlacementUi()
    self:_publishSelectedPanelFootprint()
end

function TowerPlacementController:start()
    if self._running then
        return
    end

    if not self:_resolveRemotesWithRetry() then
        self:_notify('Tower controls unavailable: remotes missing.')
        return
    end
    self._running = true

    local roundStatusRemote = getRemoteEvent(self._net.ServerToClient.RoundStatus, 5)
    if roundStatusRemote then
        table.insert(
            self._connections,
            roundStatusRemote.OnClientEvent:Connect(function(payload)
                local activeMapName = payload and payload.activeMapName
                if type(activeMapName) == 'string' and activeMapName ~= '' then
                    self._activeMapName = activeMapName
                end
                local phase = payload and payload.phase
                if type(phase) == 'string' and phase ~= '' then
                    self._latestPhase = phase
                    self:_updatePhaseVisualState()
                    self:_emitVisualTelemetry('phase_surface', {
                        phase = phase,
                        phaseLabel = self:_getPhaseLabel(phase),
                    })
                    self:_updateSelectionActionUi()
                    self:_updateSelectedTowerPanel()
                end
            end)
        )
    end

    local economyRemote = getRemoteEvent(self._net.ServerToClient.EconomyUpdated, 5)
    if economyRemote then
        table.insert(
            self._connections,
            economyRemote.OnClientEvent:Connect(function(payload)
                local currency = payload and payload.currency
                if type(currency) == 'number' then
                    self._latestCurrency = currency
                    self:_updateSelectionActionUi()
                    self:_updateSelectedTowerPanel()
                end
            end)
        )
    end

    table.insert(
        self._connections,
        UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
            if gameProcessedEvent then
                return
            end

            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                local mouseLocation = UserInputService:GetMouseLocation()
                self:_handlePointer(mouseLocation)
                return
            end

            if input.UserInputType == Enum.UserInputType.Touch then
                self:_handlePointer(Vector2.new(input.Position.X, input.Position.Y))
                return
            end

            if input.UserInputType ~= Enum.UserInputType.Keyboard then
                return
            end

            if input.KeyCode == Enum.KeyCode.One then
                self:_setSelectedTowerType('Basic', true)
            elseif input.KeyCode == Enum.KeyCode.Two then
                self:_setSelectedTowerType('Rapid', true)
            elseif input.KeyCode == Enum.KeyCode.Three then
                self:_setSelectedTowerType('Sniper', true)
            elseif input.KeyCode == Enum.KeyCode.Four then
                self:_setSelectedTowerType('Support', true)
            elseif input.KeyCode == Enum.KeyCode.U then
                self:_fireUpgrade()
            elseif input.KeyCode == Enum.KeyCode.X then
                self:_fireSell()
            elseif input.KeyCode == Enum.KeyCode.T then
                self:_cycleTargetMode()
            elseif input.KeyCode == Enum.KeyCode.R then
                if self._placingArmed then
                    self:_rotatePlacement()
                end
            elseif input.KeyCode == Enum.KeyCode.C then
                if self._placingArmed then
                    self:_cancelPlacement()
                end
            elseif input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.KeypadEnter then
                if self._placingArmed then
                    self:_attemptPlaceFromPreview()
                end
            end
        end)
    )

    if self._towerUpdatedRemote then
        table.insert(
            self._connections,
            self._towerUpdatedRemote.OnClientEvent:Connect(function(payload)
                if type(payload) ~= 'table' then
                    return
                end
                local towerId = payload.towerId
                if towerId == nil or tostring(towerId) ~= tostring(self._selectedTowerId) then
                    return
                end
                local targetMode = payload.targetMode
                if type(targetMode) == 'string' and targetMode ~= '' then
                    self._selectedTargetMode = targetMode
                    self:_updateTargetModeUi()
                    self:_updateSelectedTowerPanel()
                end
                self:_updateSelectedTowerPanel()
                self:_updateSelectionActionUi()
            end)
        )
    end

    if self._placementFailedRemote then
        table.insert(
            self._connections,
            self._placementFailedRemote.OnClientEvent:Connect(function(payload)
                if type(payload) ~= 'table' then
                    return
                end
                local reasonCode = tostring(payload.reasonCode or '')
                if reasonCode == '' then
                    return
                end
                self._lastPlacementFailureReasonCode = reasonCode
                self._lastPlacementFailureAt = os.clock()
                self:_emitVisualTelemetry('reject_reason', {
                    reasonCode = reasonCode,
                    requestType = tostring(payload.requestType or ''),
                    phase = self._latestPhase,
                })
                if self._placingArmed then
                    local previewHint = FAILURE_REASON_TO_PREVIEW_HINT[reasonCode]
                    if type(previewHint) == 'string' and previewHint ~= '' then
                        self:_setPreviewHint(previewHint, UserInputService:GetMouseLocation())
                    end
                end
                local message = FAILURE_REASON_TO_MESSAGE[reasonCode]
                if type(message) == 'string' and message ~= '' then
                    self:_notify(message)
                end
            end)
        )
    end

    self:_createHud()
    self:_updatePhaseVisualState()
    self:_ensurePlacementPreview()
    table.insert(
        self._connections,
        RunService.RenderStepped:Connect(function()
            self:_updatePlacementPreview()
            self:_updateSelectedTowerPanel()
            if
                self._placementActionHintLabel
                and self._placementActionHintLabel.Visible
                and self._placementActionHintExpiresAt > 0
                and os.clock() >= self._placementActionHintExpiresAt
            then
                self._placementActionHintLabel.Visible = false
                self._placementActionHintLabel.Text = ''
                self._placementActionHintExpiresAt = 0
            end
        end)
    )

    print(('[TowerPlacementController] %s'):format(CONTROL_HINT))
end

function TowerPlacementController:stop()
    if not self._running then
        return
    end
    self._running = false
    self._placingArmed = false
    self._selectedTowerId = nil
    self._selectedTargetMode = 'First'

    for _, connection in ipairs(self._connections) do
        connection:Disconnect()
    end
    table.clear(self._connections)

    if self._screenGui then
        self._screenGui:Destroy()
        self._screenGui = nil
    end
    self._targetModeButton = nil
    self._upgradeButton = nil
    self._sellButton = nil
    self._rotateButton = nil
    self._cancelButton = nil
    self._targetModeFrame = nil
    self._selectedTowerModel = nil
    self._placeButton = nil
    self._placementStatusLabel = nil
    self._previewPosition = nil
    self._previewValid = false
    if self._previewFolder then
        self._previewFolder:Destroy()
        self._previewFolder = nil
    end
    self._previewGhost = nil
    self._previewRange = nil
    self._previewFootprint = nil
    self._previewReason = ''
    self._placementRotationQuarter = 0
    self._previewHintLabel = nil
    self._placementActionHintLabel = nil
    self._placementActionHintExpiresAt = 0
    self._towerLoadoutFrame = nil
    self._towerUpdatedRemote = nil
    self._placementFailedRemote = nil
    self._lastPlacementFailureReasonCode = nil
    self._lastPlacementFailureAt = 0
    self._selectedPortraitFrame = nil
    self._phaseStatusLabel = nil
    self._latestPhase = 'Idle'
    self._latestCurrency = 0
    self._previewReasonTelemetryLast = ''
    self._selectedPanelLayoutSignature = ''
    table.clear(self._visualTelemetryLastAt)
    table.clear(self._visualTelemetryLastPayloadByMarker)
    if self._selectedPanel then
        self._selectedPanel:Destroy()
        self._selectedPanel = nil
    end
    self:_publishSelectedPanelFootprint()
    table.clear(self._selectedPanelLabels)
    table.clear(self._targetModeButtons)
    table.clear(self._towerTypeButtons)
end

return TowerPlacementController
