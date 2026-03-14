local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local UserInputService = game:GetService('UserInputService')
local GuiService = game:GetService('GuiService')
local HttpService = game:GetService('HttpService')

local Shared = ReplicatedStorage:WaitForChild('Shared')
local GameConfig = require(Shared:WaitForChild('GameConfig'))
local HUDTheme = require(script.Parent:WaitForChild('ui'):WaitForChild('HUDTheme'))

local MatchEntryController = {}
MatchEntryController.__index = MatchEntryController

local MATCH_ENTRY_LAYOUT_VISIBLE_ATTR = 'HUDMatchEntryVisible'
local MATCH_ENTRY_LAYOUT_TOP_ATTR = 'HUDMatchEntryTop'
local MATCH_ENTRY_LAYOUT_HEIGHT_ATTR = 'HUDMatchEntryHeight'
local MATCH_ENTRY_LAYOUT_BOTTOM_ATTR = 'HUDMatchEntryBottom'

local function getSafeInsets(): (Vector2, Vector2)
    local ok, topLeft, bottomRight = pcall(function()
        return GuiService:GetGuiInset()
    end)
    if ok and typeof(topLeft) == 'Vector2' and typeof(bottomRight) == 'Vector2' then
        return topLeft, bottomRight
    end
    return Vector2.zero, Vector2.zero
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

local function getStageOptions()
    local configured = GameConfig.STAGE_SELECTION_OPTIONS
    if type(configured) == 'table' and #configured > 0 then
        return configured
    end

    return {
        {
            stageId = 'brown',
            stageLabel = 'brown',
            acts = {
                {
                    actId = 'Act1',
                    actLabel = 'Act 1',
                    unlocked = true,
                    rewardPreview = '+50 clear / +20 missions',
                },
                {
                    actId = 'Act2',
                    actLabel = 'Act 2',
                    unlocked = false,
                    lockReason = 'Unlock after Act 1 clear',
                    rewardPreview = '+70 clear / +35 missions',
                },
            },
        },
    }
end

function MatchEntryController.new(net)
    local defaultStageId = tostring(GameConfig.DEFAULT_STAGE_ID or 'brown')
    local defaultActId = tostring(GameConfig.DEFAULT_ACT_ID or 'Act1')
    return setmetatable({
        _net = net,
        _running = false,
        _connections = {},
        _screenGui = nil,
        _playButton = nil,
        _stageButton = nil,
        _readyButton = nil,
        _statusLabel = nil,
        _entryPanel = nil,
        _stageModal = nil,
        _stageRows = {},
        _latestPhase = 'Idle',
        _latestQueueState = 'Idle',
        _latestQueueSize = 0,
        _latestQueueReadyCount = 0,
        _latestQueueCountdownTimeRemaining = nil,
        _localReady = false,
        _selectedStageId = defaultStageId,
        _selectedActId = defaultActId,
        _requestSeq = 0,
        _stageOptions = getStageOptions(),
        _remotes = {},
        _visualTelemetryLastAt = {},
        _visualTelemetryLastPayloadByMarker = {},
        _touchPreferred = false,
    }, MatchEntryController)
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

function MatchEntryController:_emitVisualTelemetry(markerKey: string, payload)
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
        surface = 'MatchEntry',
        marker = markerName,
        payload = payload,
    })))
end

function MatchEntryController:_getTopCenterLayoutConfig()
    local layoutConfig = GameConfig.HUD_LAYOUT
    local topLeftStack = type(layoutConfig) == 'table' and layoutConfig.topLeftStack or nil
    local width = tonumber(topLeftStack and topLeftStack.matchEntryPanelWidth) or 340
    local height = tonumber(topLeftStack and topLeftStack.matchEntryPanelHeight) or 124
    local offsetY = tonumber(topLeftStack and topLeftStack.matchEntryPanelOffsetY) or 10
    local minTopClearance = tonumber(topLeftStack and topLeftStack.minTopClearanceFromCoreGui) or 15
    return {
        width = math.max(220, math.floor(width)),
        height = math.max(96, math.floor(height)),
        offsetY = math.floor(offsetY),
        minTopClearance = math.max(0, math.floor(minTopClearance)),
    }
end

function MatchEntryController:_publishTopLeftLayoutFootprint()
    local localPlayer = Players.LocalPlayer
    local playerGui = localPlayer and localPlayer:FindFirstChildOfClass('PlayerGui')
    if not playerGui then
        return
    end

    local panel = self._entryPanel
    local isVisible = panel ~= nil and panel.Parent ~= nil and panel.Visible
    local top = 0
    local height = 0
    if panel and panel.Parent then
        top = panel.AbsolutePosition.Y
        height = panel.AbsoluteSize.Y
    end
    playerGui:SetAttribute(MATCH_ENTRY_LAYOUT_VISIBLE_ATTR, isVisible)
    playerGui:SetAttribute(MATCH_ENTRY_LAYOUT_TOP_ATTR, top)
    playerGui:SetAttribute(MATCH_ENTRY_LAYOUT_HEIGHT_ATTR, height)
    playerGui:SetAttribute(MATCH_ENTRY_LAYOUT_BOTTOM_ATTR, top + height)
end

function MatchEntryController:_nextRequestId(prefix: string): string
    self._requestSeq += 1
    local userId = Players.LocalPlayer and Players.LocalPlayer.UserId or 0
    local millis = math.floor(os.clock() * 1000)
    return ('%s-%d-%d-%d'):format(prefix, userId, millis, self._requestSeq)
end

function MatchEntryController:_setStatus(text: string, channel: string?)
    local label = self._statusLabel
    if not label or not label.Parent then
        return
    end
    label.Text = text
    if channel == 'critical' then
        label.TextColor3 = Color3.fromRGB(255, 170, 170)
    elseif channel == 'warn' then
        label.TextColor3 = Color3.fromRGB(255, 230, 165)
    else
        label.TextColor3 = Color3.fromRGB(235, 245, 255)
    end
end

function MatchEntryController:_getPhaseLabel(phaseName: string): string
    local labels = type(GameConfig.VISUAL_PHASE_LABELS) == 'table' and GameConfig.VISUAL_PHASE_LABELS or {}
    return tostring(labels[phaseName] or phaseName)
end

function MatchEntryController:_resolveSelectedAct()
    for _, stage in ipairs(self._stageOptions) do
        if stage.stageId == self._selectedStageId and type(stage.acts) == 'table' then
            for _, act in ipairs(stage.acts) do
                if act.actId == self._selectedActId then
                    return stage, act
                end
            end
        end
    end
    return nil, nil
end

function MatchEntryController:_isSelectionUnlocked(): boolean
    local _, act = self:_resolveSelectedAct()
    if not act then
        return false
    end
    return act.unlocked ~= false
end

function MatchEntryController:_queueRejectUiMessage(reasonCode: string, message: string): string
    local map = {
        RATE_LIMITED = 'Too many requests. Please wait.',
        QUEUE_LOCKED = 'Queue is locked for this round.',
        NOT_ON_QUEUE_PAD = 'Stand on the matching color queue pad to join.',
        NOT_ON_STAGE_PAD = 'Stand on the matching color queue pad for that stage.',
        INVALID_READY_VALUE = 'Ready toggle payload invalid.',
        NOT_QUEUED = 'Join queue first via Play.',
        DUPLICATE_REQUEST = 'Duplicate request ignored.',
        PAYLOAD_TOO_LARGE = 'Request payload too large.',
        INVALID_PAYLOAD_TYPE = 'Invalid request payload.',
        INVALID_REQUEST_ID = 'Invalid request id.',
        INVALID_REQUEST_ID_TYPE = 'Invalid request id format.',
    }
    if map[reasonCode] then
        return map[reasonCode]
    end
    if message ~= '' then
        return message
    end
    return ('Queue request rejected: %s'):format(reasonCode)
end

function MatchEntryController:_applyEntrySurfaceVisibility()
    local playButton = self._playButton
    local stageButton = self._stageButton
    local readyButton = self._readyButton
    if not playButton or not stageButton or not readyButton then
        return
    end

    local inLobby = self._latestPhase == 'Lobby'
    playButton.Visible = inLobby
    stageButton.Visible = inLobby
    readyButton.Visible = inLobby
    local panel = self._entryPanel
    if panel and panel.Parent then
        panel.Visible = inLobby
    end
    local modal = self._stageModal
    if modal and modal.Parent and not inLobby then
        modal.Visible = false
    end
    self:_publishTopLeftLayoutFootprint()
end

function MatchEntryController:_updateActionButtons()
    local playButton = self._playButton
    local stageButton = self._stageButton
    local readyButton = self._readyButton
    if not playButton or not stageButton or not readyButton then
        return
    end

    local queueState = tostring(self._latestQueueState or 'Idle')
    local inLobby = self._latestPhase == 'Lobby'
    local queueLocked = queueState == 'Locked'
    local unlockedSelection = self:_isSelectionUnlocked()
    playButton.Active = inLobby and not queueLocked
    playButton.AutoButtonColor = playButton.Active
    playButton.Text = if queueLocked then 'Play (Locked)' else 'Play'

    stageButton.Text = 'Map'
    stageButton.Active = inLobby and not queueLocked
    stageButton.AutoButtonColor = stageButton.Active

    local readyLabel = self._localReady and 'Ready: ON' or 'Ready: OFF'
    if not unlockedSelection then
        readyLabel = 'Ready (Stage Locked)'
    end
    readyButton.Text = readyLabel
    readyButton.Active = inLobby and not queueLocked and unlockedSelection
    readyButton.AutoButtonColor = readyButton.Active

    self:_applyEntrySurfaceVisibility()
end

function MatchEntryController:_emitCreateMatchRequest()
    local remote = self._remotes.createMatch
    if not remote then
        self:_setStatus('Play unavailable: missing queue remote.', 'critical')
        return
    end
    remote:FireServer({
        requestId = self:_nextRequestId('play'),
        stageId = self._selectedStageId,
        actId = self._selectedActId,
    })
end

function MatchEntryController:_emitReadyRequest(readyValue: boolean)
    local remote = self._remotes.ready
    if not remote then
        self:_setStatus('Ready unavailable: missing queue remote.', 'critical')
        return
    end
    remote:FireServer({
        requestId = self:_nextRequestId('ready'),
        ready = readyValue,
        stageId = self._selectedStageId,
        actId = self._selectedActId,
    })
end

function MatchEntryController:_openStageModal()
    local modal = self._stageModal
    if not modal then
        return
    end
    if self._latestPhase ~= 'Lobby' then
        self:_setStatus('Stage select is available during Lobby only.', 'warn')
        return
    end
    modal.Visible = true
    self:_setStatus('Select Stage and Act, then press Ready.', 'routine')
end

function MatchEntryController:_closeStageModal()
    local modal = self._stageModal
    if not modal then
        return
    end
    modal.Visible = false
end

function MatchEntryController:_onPlayPressed()
    if self._latestPhase ~= 'Lobby' then
        self:_setStatus('Play is available during Lobby only.', 'warn')
        return
    end
    self:_emitCreateMatchRequest()
    self:_setStatus('Play requested. Stand on your color queue pad if prompted.', 'routine')
end

function MatchEntryController:_onReadyPressed()
    if not self:_isSelectionUnlocked() then
        self:_setStatus('Selected stage/act is locked.', 'warn')
        return
    end
    self._localReady = not self._localReady
    self:_emitReadyRequest(self._localReady)
    self:_updateActionButtons()
    self:_setStatus(self._localReady and 'Ready sent.' or 'Ready unset.', 'routine')
end

function MatchEntryController:_buildStageRows(container: Frame)
    for _, row in ipairs(self._stageRows) do
        if row and row.Parent then
            row:Destroy()
        end
    end
    table.clear(self._stageRows)

    local y = 40
    for _, stage in ipairs(self._stageOptions) do
        local stageTitle = Instance.new('TextLabel')
        stageTitle.Name = ('Stage_%s_Title'):format(tostring(stage.stageId))
        stageTitle.Size = UDim2.new(1, -20, 0, 18)
        stageTitle.Position = UDim2.fromOffset(10, y)
        stageTitle.BackgroundTransparency = 1
        stageTitle.Text = tostring(stage.stageLabel or stage.stageId)
        stageTitle.Parent = container
        HUDTheme.applyText(stageTitle, {
            textXAlignment = Enum.TextXAlignment.Left,
            textSize = 13,
        })
        table.insert(self._stageRows, stageTitle)
        y += 20

        local acts = stage.acts
        local stageImplemented = stage.implemented ~= false
        if type(acts) == 'table' then
            for _, act in ipairs(acts) do
                local button = Instance.new('TextButton')
                button.Name = ('%s_%s_Button'):format(tostring(stage.stageId), tostring(act.actId))
                button.Size = UDim2.new(1, -20, 0, 30)
                button.Position = UDim2.fromOffset(10, y)
                button.AutoButtonColor = true
                button.Parent = container
                HUDTheme.applySurface(button, {
                    useGradient = false,
                    cornerRadius = 10,
                })
                HUDTheme.applyText(button, {
                    textXAlignment = Enum.TextXAlignment.Left,
                    textSize = 11,
                })

                local unlocked = stageImplemented and (act.unlocked ~= false)
                local lockTag = if not stageImplemented
                    then 'NOT IMPLEMENTED'
                    elseif unlocked then 'UNLOCKED'
                    else ('LOCKED: ' .. tostring(act.lockReason or 'Unavailable'))
                local reward = tostring(act.rewardPreview or 'No reward preview')
                button.Text = ('%s | %s | %s'):format(tostring(act.actLabel or act.actId), lockTag, reward)
                button.Active = unlocked
                button.AutoButtonColor = unlocked
                button.TextColor3 = unlocked and Color3.fromRGB(236, 246, 255) or Color3.fromRGB(255, 198, 176)

                table.insert(
                    self._connections,
                    button.MouseButton1Click:Connect(function()
                        self._selectedStageId = tostring(stage.stageId)
                        self._selectedActId = tostring(act.actId)
                        self._localReady = false
                        self:_closeStageModal()
                        self:_updateActionButtons()
                        if unlocked then
                            self:_setStatus(
                                ('Stage selected: %s / %s.'):format(
                                    tostring(stage.stageLabel or stage.stageId),
                                    tostring(act.actLabel or act.actId)
                                ),
                                'routine'
                            )
                        else
                            self:_setStatus('Selected act is locked.', 'warn')
                        end
                    end)
                )

                table.insert(self._stageRows, button)
                y += 34
            end
        end
    end
end

function MatchEntryController:_createHud()
    local playerGui = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass('PlayerGui')
    if not playerGui then
        return
    end

    local screenGui = Instance.new('ScreenGui')
    screenGui.Name = 'MatchEntryController'
    screenGui.ResetOnSpawn = false
    screenGui.DisplayOrder = 18
    screenGui.IgnoreGuiInset = true
    screenGui.Parent = playerGui
    self._screenGui = screenGui

    local topInset = getSafeInsets()
    local topInsetY = math.floor(topInset.Y)

    local touchPreferred = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
    self._touchPreferred = touchPreferred
    local _, bottomInset = getSafeInsets()
    local safePadding = math.max(0, math.floor(tonumber(GameConfig.UI_SAFE_AREA_PADDING) or 8))
    local safeBottomY = math.floor(bottomInset.Y) + safePadding
    local camera = workspace.CurrentCamera
    local viewportSize = camera and camera.ViewportSize or Vector2.new(1280, 720)

    local panel = Instance.new('Frame')
    panel.Name = 'MatchEntryPanel'
    local layout = self:_getTopCenterLayoutConfig()
    local mobilePanelWidth = 252
    local mobilePanelHeight = 44
    panel.Size = touchPreferred and UDim2.fromOffset(mobilePanelWidth, mobilePanelHeight)
        or UDim2.fromOffset(layout.width, layout.height)
    panel.AnchorPoint = touchPreferred and Vector2.new(0, 1) or Vector2.new(0.5, 0)
    panel.Position = touchPreferred and UDim2.fromOffset(10, viewportSize.Y - safeBottomY - 10)
        or UDim2.new(0.5, 0, 0, topInsetY + math.max(layout.offsetY, layout.minTopClearance))
    panel.Parent = screenGui
    self._entryPanel = panel
    HUDTheme.applySurface(panel, {
        cornerRadius = 12,
        useGradient = false,
    })

    local title = Instance.new('TextLabel')
    title.Name = 'Title'
    title.Size = UDim2.new(1, -12, 0, 20)
    title.Position = UDim2.fromOffset(6, 4)
    title.BackgroundTransparency = 1
    title.Text = 'Match Entry: Play -> Stage -> Ready'
    title.Parent = panel
    HUDTheme.applyText(title, {
        textXAlignment = Enum.TextXAlignment.Left,
        textSize = 12,
    })

    local actionButtonWidth = touchPreferred and 76 or 102
    local actionButtonHeight = touchPreferred and 28 or 30
    local function createActionButton(name: string, text: string, x: number): TextButton
        local button = Instance.new('TextButton')
        button.Name = name
        button.Size = UDim2.fromOffset(actionButtonWidth, actionButtonHeight)
        button.Position = UDim2.fromOffset(x, touchPreferred and 8 or 30)
        button.Text = text
        button.Parent = panel
        HUDTheme.applySurface(button, {
            useGradient = false,
            cornerRadius = 10,
        })
        HUDTheme.applyText(button, {
            textXAlignment = Enum.TextXAlignment.Center,
            textSize = touchPreferred and 10 or 11,
        })
        return button
    end

    self._playButton = createActionButton('PlayButton', 'Play', touchPreferred and 6 or 8)
    self._stageButton = createActionButton('StageButton', 'Stage', touchPreferred and 88 or 118)
    self._readyButton = createActionButton('ReadyButton', 'Ready', touchPreferred and 170 or 228)

    local status = Instance.new('TextLabel')
    status.Name = 'Status'
    status.Size = UDim2.new(1, -12, 0, 52)
    status.Position = UDim2.fromOffset(6, 66)
    status.BackgroundTransparency = 1
    status.TextWrapped = true
    status.TextYAlignment = Enum.TextYAlignment.Top
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.Text = 'Waiting for lobby status...'
    status.Visible = not touchPreferred
    status.Parent = panel
    HUDTheme.applyText(status, {
        textXAlignment = Enum.TextXAlignment.Left,
        textSize = 11,
    })
    self._statusLabel = status

    local modal = Instance.new('Frame')
    modal.Name = 'StageModal'
    modal.Size = UDim2.fromOffset(420, 280)
    modal.Position = UDim2.new(0.5, -210, 0.5, -140)
    modal.Visible = false
    modal.Parent = screenGui
    HUDTheme.applySurface(modal, {
        cornerRadius = 12,
    })
    self._stageModal = modal

    local modalTitle = Instance.new('TextLabel')
    modalTitle.Name = 'ModalTitle'
    modalTitle.Size = UDim2.new(1, -50, 0, 24)
    modalTitle.Position = UDim2.fromOffset(10, 6)
    modalTitle.BackgroundTransparency = 1
    modalTitle.Text = 'Stage Select'
    modalTitle.Parent = modal
    HUDTheme.applyText(modalTitle, {
        textXAlignment = Enum.TextXAlignment.Left,
    })

    local closeButton = Instance.new('TextButton')
    closeButton.Name = 'CloseButton'
    closeButton.Size = UDim2.fromOffset(30, 24)
    closeButton.Position = UDim2.new(1, -36, 0, 6)
    closeButton.Text = 'X'
    closeButton.Parent = modal
    HUDTheme.applySurface(closeButton, {
        useGradient = false,
        cornerRadius = 8,
    })
    HUDTheme.applyText(closeButton, {
        textXAlignment = Enum.TextXAlignment.Center,
    })
    table.insert(
        self._connections,
        closeButton.MouseButton1Click:Connect(function()
            self:_closeStageModal()
        end)
    )

    self:_buildStageRows(modal)

    table.insert(
        self._connections,
        self._playButton.MouseButton1Click:Connect(function()
            self:_onPlayPressed()
        end)
    )
    table.insert(
        self._connections,
        self._stageButton.MouseButton1Click:Connect(function()
            self:_openStageModal()
        end)
    )
    table.insert(
        self._connections,
        self._readyButton.MouseButton1Click:Connect(function()
            self:_onReadyPressed()
        end)
    )

    self:_publishTopLeftLayoutFootprint()
end

function MatchEntryController:_bindRoundStatus()
    local roundStatusRemote = self._remotes.roundStatus
    if not roundStatusRemote then
        return
    end

    table.insert(
        self._connections,
        roundStatusRemote.OnClientEvent:Connect(function(payload)
            if type(payload) ~= 'table' then
                return
            end
            local previousPhase = self._latestPhase
            local previousQueueState = self._latestQueueState
            self._latestPhase = tostring(payload.phase or self._latestPhase or 'Idle')
            self._latestQueueState = tostring(payload.queueState or self._latestQueueState or 'Idle')
            self._latestQueueSize = tonumber(payload.queueSize) or self._latestQueueSize or 0
            self._latestQueueReadyCount = tonumber(payload.queueReadyCount) or self._latestQueueReadyCount or 0
            self._latestQueueCountdownTimeRemaining = payload.queueCountdownTimeRemaining

            if previousPhase ~= self._latestPhase then
                if self._latestPhase == 'Wave' then
                    self:_setStatus('Transition: entering match wave.', 'routine')
                    self:_closeStageModal()
                elseif self._latestPhase == 'Lobby' and previousPhase ~= 'Idle' then
                    self._localReady = false
                    self:_setStatus('Back to lobby. Start with Play.', 'routine')
                end
                self:_emitVisualTelemetry('phase_surface', {
                    phase = self._latestPhase,
                    phaseLabel = self:_getPhaseLabel(self._latestPhase),
                    queueState = self._latestQueueState,
                })
            end

            if self._latestPhase == 'Lobby' then
                if
                    self._latestQueueState == 'CountingDown'
                    and type(self._latestQueueCountdownTimeRemaining) == 'number'
                then
                    self:_setStatus(
                        ('Queue countdown: %ds (%d ready of %d queued).'):format(
                            math.max(0, math.floor(self._latestQueueCountdownTimeRemaining)),
                            math.max(0, self._latestQueueReadyCount),
                            math.max(0, self._latestQueueSize)
                        ),
                        'routine'
                    )
                elseif self._latestQueueState == 'Locked' and previousQueueState ~= 'Locked' then
                    self:_setStatus('Queue locked. Waiting for match transition.', 'warn')
                elseif self._latestQueueState == 'Idle' and previousQueueState == 'Locked' then
                    self:_setStatus('Queue reopened. Use Play to join.', 'routine')
                end
            end

            self:_updateActionButtons()
        end)
    )
end

function MatchEntryController:_bindSystemMessages()
    local systemRemote = self._remotes.systemMessage
    if not systemRemote then
        return
    end

    table.insert(
        self._connections,
        systemRemote.OnClientEvent:Connect(function(payload)
            local text = type(payload) == 'table' and tostring(payload.text or '') or ''
            if text == '' then
                return
            end

            local reasonCode, reasonMessage = string.match(text, '^%[Queue%]%[([%w_]+)%]%s*(.*)$')
            if reasonCode then
                local uiMessage = self:_queueRejectUiMessage(reasonCode, reasonMessage or '')
                local channel = 'warn'
                if
                    reasonCode == 'RATE_LIMITED'
                    or reasonCode == 'QUEUE_LOCKED'
                    or reasonCode == 'NOT_ON_QUEUE_PAD'
                    or reasonCode == 'INVALID_READY_VALUE'
                then
                    channel = 'critical'
                end
                self:_setStatus(uiMessage, channel)
                if reasonCode == 'READY_SET' then
                    self._localReady = true
                elseif reasonCode == 'READY_UNSET' then
                    self._localReady = false
                end
                self:_updateActionButtons()
                return
            end

            if string.find(string.lower(text), 'match started', 1, true) then
                self:_setStatus('Transition: match start confirmed.', 'routine')
            end
        end)
    )
end

function MatchEntryController:start()
    if self._running then
        return
    end
    self._running = true

    self._remotes.createMatch = getRemoteEvent(self._net.ClientToServer.RequestCreateMatch, 5)
    self._remotes.ready = getRemoteEvent(self._net.ClientToServer.RequestReady, 5)
    self._remotes.roundStatus = getRemoteEvent(self._net.ServerToClient.RoundStatus, 5)
    self._remotes.systemMessage = getRemoteEvent(self._net.ServerToClient.SystemMessage, 5)

    self:_createHud()
    self:_bindRoundStatus()
    self:_bindSystemMessages()
    self:_updateActionButtons()

    table.insert(
        self._connections,
        UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
            if gameProcessedEvent or input.UserInputType ~= Enum.UserInputType.Keyboard then
                return
            end
            if input.KeyCode == Enum.KeyCode.P then
                self:_onPlayPressed()
            elseif input.KeyCode == Enum.KeyCode.G then
                self:_openStageModal()
            elseif input.KeyCode == Enum.KeyCode.Y then
                self:_onReadyPressed()
            end
        end)
    )
end

function MatchEntryController:stop()
    if not self._running then
        return
    end
    self._running = false

    for _, connection in ipairs(self._connections) do
        connection:Disconnect()
    end
    table.clear(self._connections)

    for _, row in ipairs(self._stageRows) do
        if row and row.Parent then
            row:Destroy()
        end
    end
    table.clear(self._stageRows)

    if self._screenGui then
        self._screenGui:Destroy()
        self._screenGui = nil
    end

    self._playButton = nil
    self._stageButton = nil
    self._readyButton = nil
    self._statusLabel = nil
    self._entryPanel = nil
    self._stageModal = nil
    self._localReady = false
    self._latestPhase = 'Idle'
    self._latestQueueState = 'Idle'
    self._latestQueueSize = 0
    self._latestQueueReadyCount = 0
    self._latestQueueCountdownTimeRemaining = nil

    local localPlayer = Players.LocalPlayer
    local playerGui = localPlayer and localPlayer:FindFirstChildOfClass('PlayerGui')
    if playerGui then
        playerGui:SetAttribute(MATCH_ENTRY_LAYOUT_VISIBLE_ATTR, false)
        playerGui:SetAttribute(MATCH_ENTRY_LAYOUT_TOP_ATTR, 0)
        playerGui:SetAttribute(MATCH_ENTRY_LAYOUT_HEIGHT_ATTR, 0)
        playerGui:SetAttribute(MATCH_ENTRY_LAYOUT_BOTTOM_ATTR, 0)
    end
    table.clear(self._visualTelemetryLastAt)
    table.clear(self._visualTelemetryLastPayloadByMarker)
    table.clear(self._remotes)
end

return MatchEntryController
