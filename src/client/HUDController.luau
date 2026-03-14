local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local UserInputService = game:GetService('UserInputService')
local GuiService = game:GetService('GuiService')
local Shared = ReplicatedStorage:WaitForChild('Shared')
local GameConfig = require(Shared:WaitForChild('GameConfig'))
local HUDTheme = require(script.Parent:WaitForChild('ui'):WaitForChild('HUDTheme'))

local HUDController = {}
HUDController.__index = HUDController

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

function HUDController.new(net)
    return setmetatable({
        _net = net,
        _running = false,
        _connections = {},
        _screenGui = nil,
        _topBar = nil,
        _queueCountdownLabel = nil,
        _labels = {},
        _state = {
            phase = 'Idle',
            timeRemaining = '-',
            baseHealth = '-',
            roundNumber = 0,
            currency = '-',
            towerCount = 0,
            towerLimit = math.max(1, tonumber(GameConfig.TOWER_MAX_TOTAL) or 100),
            eliteExpectedCount = 0,
            eliteSpawnedCount = 0,
            queueState = 'Idle',
            queueSize = 0,
            queueReadyCount = 0,
            queueCountdownTimeRemaining = nil,
            gameSpeedMultiplier = tonumber(GameConfig.COMBAT_GAME_SPEED_MULTIPLIER) or 1,
            gameSpeedLabel = '1.0x',
            speedControlState = 'LOCKED',
            restartVotePassed = false,
            roundMutatorName = 'NoModifier',
            roundMutatorThreatHint = '',
            missionCompletedCount = 0,
            missionTotalCount = 0,
            activeEnemyCount = 0,
            enemyTargetCount = 0,
            enemySpawnedCount = 0,
            enemyRemainingCount = 0,
        },
        _restartVoteButton = nil,
        _touchPreferred = false,
    }, HUDController)
end

function HUDController:_updateTopBarVisibility()
    local topBar = self._topBar
    if not topBar or not topBar.Parent then
        return
    end
    local phase = tostring(self._state.phase or 'Idle')
    local inMapPhase = phase == 'Wave' or phase == 'Results' or phase == 'Cleanup'
    topBar.Visible = inMapPhase
end

function HUDController:_updateVoteButtonVisibility()
    local phase = tostring(self._state.phase or 'Idle')
    local showRestartVote = phase == 'Results' and self._state.restartVotePassed ~= true

    local restartVoteButton = self._restartVoteButton
    if restartVoteButton and restartVoteButton.Parent then
        restartVoteButton.Visible = showRestartVote
    end
end

function HUDController:_updateQueueCountdownVisibility()
    local label = self._queueCountdownLabel
    if not label or not label.Parent then
        return
    end

    local phase = tostring(self._state.phase or 'Idle')
    local queueState = tostring(self._state.queueState or 'Idle')
    local timeRemaining = self._state.queueCountdownTimeRemaining
    local shouldShow = phase == 'Lobby' and queueState == 'CountingDown' and type(timeRemaining) == 'number'
    label.Visible = shouldShow
    if shouldShow then
        label.Text = ('Queue starts in %ds'):format(math.max(0, math.floor(timeRemaining)))
    end
end

function HUDController:_updateResponsiveHudLayout()
    if not self._screenGui or not self._screenGui.Parent then
        return
    end
    local topBar = self._topBar
    if not topBar or not topBar.Parent then
        return
    end

    local layoutConfig = type(GameConfig.HUD_COMBAT_STRIP_LAYOUT) == 'table' and GameConfig.HUD_COMBAT_STRIP_LAYOUT
        or {}
    local profile = if self._touchPreferred then layoutConfig.touch else layoutConfig.desktop
    if type(profile) ~= 'table' then
        profile = {}
    end

    local camera = workspace.CurrentCamera
    local viewportSize = camera and camera.ViewportSize or Vector2.new(1280, 720)
    local _, bottomInset = getSafeInsets()
    local safePadding = math.max(0, math.floor(tonumber(GameConfig.UI_SAFE_AREA_PADDING) or 8))
    local safeRight = math.floor(bottomInset.X) + safePadding
    local safeBottom = math.floor(bottomInset.Y) + safePadding

    local topBarHeight = self._touchPreferred and 38 or 42
    local rightMargin = math.max(0, math.floor(tonumber(profile.rightMargin) or (self._touchPreferred and 8 or 14)))
    local topOffset = math.floor(tonumber(profile.topOffset) or (self._touchPreferred and 4 or 0))
    -- Align to the CoreGui top row (Roblox menu/chat), not below it.
    local topBarTop = topOffset
    local topBarBottom = topBarTop + topBarHeight
    local leftMargin = math.max(8, safePadding)
    local preferredTopBarWidth = self._touchPreferred and 248 or 420
    local maxTopBarWidth = math.max(220, viewportSize.X - leftMargin - rightMargin - safeRight)
    local topBarWidth = math.min(preferredTopBarWidth, maxTopBarWidth)
    local topBarX = math.floor((viewportSize.X - topBarWidth) * 0.5)
    local maxTopBarX = viewportSize.X - topBarWidth - rightMargin - safeRight
    local clampedMaxTopBarX = math.max(leftMargin, maxTopBarX)
    topBarX = math.clamp(topBarX, leftMargin, clampedMaxTopBarX)
    local localPlayer = Players.LocalPlayer
    local playerGui = localPlayer and localPlayer:FindFirstChildOfClass('PlayerGui')
    if playerGui and playerGui:GetAttribute(SELECTED_PANEL_LAYOUT_VISIBLE_ATTR) == true then
        local panelTop = tonumber(playerGui:GetAttribute(SELECTED_PANEL_LAYOUT_TOP_ATTR)) or 0
        local panelBottom = tonumber(playerGui:GetAttribute(SELECTED_PANEL_LAYOUT_BOTTOM_ATTR)) or 0
        local panelLeft = tonumber(playerGui:GetAttribute(SELECTED_PANEL_LAYOUT_LEFT_ATTR)) or viewportSize.X
        local panelRight = tonumber(playerGui:GetAttribute(SELECTED_PANEL_LAYOUT_RIGHT_ATTR)) or viewportSize.X
        local verticalIntersects = topBarTop < panelBottom and topBarBottom > panelTop
        if verticalIntersects then
            local topBarRight = topBarX + topBarWidth
            local horizontalIntersects = topBarX < panelRight and topBarRight > panelLeft
            if horizontalIntersects then
                topBarX = math.max(leftMargin, math.floor(panelLeft - topBarWidth - 12))
            end
        end
    end
    topBar.Size = UDim2.fromOffset(topBarWidth, topBarHeight)
    topBar.Position = UDim2.fromOffset(topBarX, topBarTop)

    local queueCountdownLabel = self._queueCountdownLabel
    if queueCountdownLabel and queueCountdownLabel.Parent then
        local queueHeight = self._touchPreferred and 32 or 26
        local queueTop = topBarBottom + (self._touchPreferred and 10 or 8)
        queueCountdownLabel.Position = UDim2.new(1, -(queueCountdownLabel.AbsoluteSize.X + safeRight + 8), 0, queueTop)
        queueCountdownLabel.Size = UDim2.fromOffset(queueCountdownLabel.AbsoluteSize.X, queueHeight)
    end

    local touchButtonWidth = math.max(154, math.floor(tonumber(GameConfig.UI_TOUCH_MIN_BUTTON_WIDTH) or 150))
    local touchButtonHeight = math.max(42, math.floor(tonumber(GameConfig.UI_TOUCH_MIN_BUTTON_HEIGHT) or 48))
    local bottomOffset = (self._touchPreferred and 12 or 8) + safeBottom
    local touchVoteRestartBottomOffset = bottomOffset + touchButtonHeight + 8
    if self._restartVoteButton and self._restartVoteButton.Parent then
        self._restartVoteButton.Position = self._touchPreferred
                and UDim2.new(1, -(touchButtonWidth + safeRight + 12), 1, -touchVoteRestartBottomOffset)
            or UDim2.new(1, -(266 + safeRight), 1, -(bottomOffset + 34))
    end

    self:_layoutTopBarLabels()
end

function HUDController:_bindTopLeftLayoutFootprint()
    local localPlayer = Players.LocalPlayer
    local playerGui = localPlayer and localPlayer:FindFirstChildOfClass('PlayerGui')
    if not playerGui then
        return
    end
    local attrs = {
        SELECTED_PANEL_LAYOUT_VISIBLE_ATTR,
        SELECTED_PANEL_LAYOUT_LEFT_ATTR,
        SELECTED_PANEL_LAYOUT_TOP_ATTR,
        SELECTED_PANEL_LAYOUT_RIGHT_ATTR,
        SELECTED_PANEL_LAYOUT_BOTTOM_ATTR,
    }
    for _, attrName in ipairs(attrs) do
        table.insert(
            self._connections,
            playerGui:GetAttributeChangedSignal(attrName):Connect(function()
                self:_updateResponsiveHudLayout()
            end)
        )
    end

    local camera = workspace.CurrentCamera
    if camera then
        table.insert(
            self._connections,
            camera:GetPropertyChangedSignal('ViewportSize'):Connect(function()
                self:_updateResponsiveHudLayout()
            end)
        )
    end
end

function HUDController:_resolveCombatCueLabel()
    local s = self._state
    local phase = tostring(s.phase or 'Idle')
    if phase ~= 'Wave' then
        return 'Spawn: Standby', 'Lane: Standby'
    end

    local activeEnemyCount = tonumber(s.activeEnemyCount) or 0
    local enemyRemainingCount = tonumber(s.enemyRemainingCount) or 0
    local enemyTargetCount = math.max(1, tonumber(s.enemyTargetCount) or 1)
    local enemySpawnedCount = tonumber(s.enemySpawnedCount) or 0

    local spawnLabel = 'Spawn: Flow'
    if enemyRemainingCount <= 0 and activeEnemyCount <= 0 then
        spawnLabel = 'Spawn: Clear'
    elseif enemySpawnedCount < enemyTargetCount then
        spawnLabel = 'Spawn: Spawning'
    elseif activeEnemyCount >= 12 then
        spawnLabel = 'Spawn: Heavy'
    end

    local laneLabel = 'Lane: Stable'
    if activeEnemyCount >= 14 then
        laneLabel = 'Lane: Congested'
    elseif (tonumber(s.baseHealth) or 0) > 0 and (tonumber(s.baseHealth) or 0) <= 35 then
        laneLabel = 'Lane: Base Danger'
    elseif
        (tonumber(s.eliteExpectedCount) or 0) > 0
        and (tonumber(s.eliteSpawnedCount) or 0) < (tonumber(s.eliteExpectedCount) or 0)
    then
        local spawnProgress = enemySpawnedCount / enemyTargetCount
        if spawnProgress >= 0.5 then
            laneLabel = 'Lane: Elite Window'
        end
    end
    return spawnLabel, laneLabel
end

function HUDController:_applyVisualPriority()
    local labels = self._labels
    if not labels.base or not labels.spawn or not labels.lane or not labels.mode or not labels.elites then
        return
    end
    local accessibility = type(GameConfig.VISUAL_ACCESSIBILITY) == 'table' and GameConfig.VISUAL_ACCESSIBILITY or {}
    local colorSafeCritical = accessibility.colorSafeCritical == true
    local s = self._state
    local baseHealth = tonumber(s.baseHealth) or 0
    local baseMax = math.max(1, tonumber(GameConfig.BASE_MAX_HEALTH) or 100)
    local baseRatio = baseHealth / baseMax
    labels.base.TextColor3 = if baseRatio <= 0.3
        then (colorSafeCritical and Color3.fromRGB(255, 235, 120) or Color3.fromRGB(255, 118, 118))
        elseif baseRatio <= 0.6 then Color3.fromRGB(255, 214, 140)
        else Color3.fromRGB(220, 240, 220)
    labels.spawn.TextColor3 = if (tonumber(s.activeEnemyCount) or 0) >= 12
        then Color3.fromRGB(255, 204, 138)
        else Color3.fromRGB(210, 210, 210)
    labels.lane.TextColor3 = if string.find(labels.lane.Text, 'Danger', 1, true) ~= nil
        then (colorSafeCritical and Color3.fromRGB(255, 235, 120) or Color3.fromRGB(255, 126, 126))
        else Color3.fromRGB(210, 210, 210)
    labels.mode.TextColor3 = if tostring(s.phase or 'Idle') == 'Wave'
        then Color3.fromRGB(190, 235, 255)
        else Color3.fromRGB(205, 205, 205)
    labels.elites.TextColor3 = if (tonumber(s.eliteExpectedCount) or 0) > 0
        then Color3.fromRGB(255, 195, 125)
        else Color3.fromRGB(185, 185, 185)
end

function HUDController:_layoutTopBarLabels()
    local topBar = self._topBar
    if not topBar or not topBar.Parent then
        return
    end
    local labels = self._labels
    local layoutOrder = if self._touchPreferred
        then {
            { key = 'wave', minWidth = 54, preferredWidth = 62, priority = 1 },
            { key = 'time', minWidth = 74, preferredWidth = 84, priority = 2 },
            { key = 'base', minWidth = 58, preferredWidth = 66, priority = 3 },
        }
        else {
            { key = 'wave', minWidth = 72, preferredWidth = 86, priority = 1 },
            { key = 'time', minWidth = 100, preferredWidth = 124, priority = 2 },
            { key = 'base', minWidth = 82, preferredWidth = 96, priority = 3 },
        }
    local gap = 6
    local innerPadding = 10
    local availableWidth = math.max(220, topBar.AbsoluteSize.X - (innerPadding * 2))
    local desiredTotalWidth = 0
    for _, item in ipairs(layoutOrder) do
        desiredTotalWidth += item.preferredWidth
    end
    desiredTotalWidth += (#layoutOrder - 1) * gap
    local visibleByKey = {}
    for _, item in ipairs(layoutOrder) do
        visibleByKey[item.key] = true
    end
    for _, key in ipairs({ 'mode', 'speed', 'spawn', 'lane', 'elites' }) do
        visibleByKey[key] = false
    end

    local visibleItems = {}
    for _, item in ipairs(layoutOrder) do
        if visibleByKey[item.key] then
            table.insert(visibleItems, item)
        end
    end
    local minimumTotalWidth = 0
    for _, item in ipairs(visibleItems) do
        minimumTotalWidth += item.minWidth
    end
    minimumTotalWidth += math.max(0, #visibleItems - 1) * gap
    local widthBudget = math.max(minimumTotalWidth, availableWidth)
    local elasticBudget = widthBudget - minimumTotalWidth
    local preferredElasticTotal = 0
    for _, item in ipairs(visibleItems) do
        preferredElasticTotal += (item.preferredWidth - item.minWidth)
    end

    local xOffset = innerPadding
    for _, item in ipairs(layoutOrder) do
        local label = labels[item.key]
        if label then
            if visibleByKey[item.key] then
                local width = item.minWidth
                if preferredElasticTotal > 0 and elasticBudget > 0 then
                    local itemElastic = (item.preferredWidth - item.minWidth) / preferredElasticTotal
                    width += math.floor((elasticBudget * itemElastic) + 0.5)
                end
                label.Visible = true
                label.Position = UDim2.fromOffset(xOffset, 12)
                label.Size = UDim2.fromOffset(width, 18)
                xOffset += width + gap
            else
                label.Visible = false
            end
        end
    end
    for key, label in pairs(labels) do
        if label and visibleByKey[key] ~= true then
            label.Visible = false
        end
    end
end

function HUDController:_updateHudText()
    local s = self._state
    local accessibility = type(GameConfig.VISUAL_ACCESSIBILITY) == 'table' and GameConfig.VISUAL_ACCESSIBILITY or {}
    local criticalPrefix = accessibility.colorSafeCritical == true and tostring(accessibility.criticalPrefix or '!!')
        or ''
    local phase = tostring(s.phase or 'Idle')
    local visualPhaseLabels = type(GameConfig.VISUAL_PHASE_LABELS) == 'table' and GameConfig.VISUAL_PHASE_LABELS or {}
    local modeLabel = tostring(visualPhaseLabels[phase] or phase)
    self._labels.wave.Text = ('Wave: %s'):format(tostring(s.roundNumber))
    self._labels.mode.Text = ('Mode: %s'):format(modeLabel)
    self._labels.time.Text = ('Countdown: %s'):format(tostring(s.timeRemaining))
    local baseValue = tonumber(s.baseHealth) or 0
    local baseMax = math.max(1, tonumber(GameConfig.BASE_MAX_HEALTH) or 100)
    local baseWarningThreshold = 0.3
    local baseLabelPrefix = if criticalPrefix ~= '' and (baseValue / baseMax) <= baseWarningThreshold
        then (criticalPrefix .. ' ')
        else ''
    self._labels.base.Text = ('%sBase: %s'):format(baseLabelPrefix, tostring(s.baseHealth))

    local speedLabel = tostring(s.gameSpeedLabel or '1.0x')
    local speedState = tostring(s.speedControlState or 'LOCKED')
    self._labels.speed.Text = ('Speed: %s [%s]'):format(speedLabel, speedState)

    local spawnLabel, laneLabel = self:_resolveCombatCueLabel()
    self._labels.spawn.Text = spawnLabel
    if criticalPrefix ~= '' and string.find(laneLabel, 'Danger', 1, true) ~= nil then
        laneLabel = ('%s %s'):format(criticalPrefix, laneLabel)
    end
    self._labels.lane.Text = laneLabel

    if (tonumber(s.eliteExpectedCount) or 0) > 0 then
        self._labels.elites.Text = ('Elites: %d/%d'):format(
            tonumber(s.eliteSpawnedCount) or 0,
            tonumber(s.eliteExpectedCount) or 0
        )
    else
        self._labels.elites.Text = 'Elites: none'
    end

    self:_applyVisualPriority()
end

function HUDController:_bindVoteButtons()
    if not self._screenGui then
        return
    end

    local touchPreferred = self._touchPreferred
    local touchButtonWidth = math.max(154, math.floor(tonumber(GameConfig.UI_TOUCH_MIN_BUTTON_WIDTH) or 150))
    local touchButtonHeight = math.max(42, math.floor(tonumber(GameConfig.UI_TOUCH_MIN_BUTTON_HEIGHT) or 48))
    local _, bottomInset = getSafeInsets()
    local safePadding = math.max(0, math.floor(tonumber(GameConfig.UI_SAFE_AREA_PADDING) or 8))
    local bottomOffset = (touchPreferred and 12 or 8) + math.floor(bottomInset.Y) + safePadding
    local touchVoteRestartBottomOffset = bottomOffset + touchButtonHeight + 8

    local restartVoteButton = Instance.new('TextButton')
    restartVoteButton.Name = 'RestartVoteButton'
    restartVoteButton.Size = touchPreferred and UDim2.fromOffset(touchButtonWidth, touchButtonHeight)
        or UDim2.fromOffset(132, 34)
    restartVoteButton.Position = touchPreferred
            and UDim2.new(1, -(touchButtonWidth + 12), 1, -touchVoteRestartBottomOffset)
        or UDim2.new(1, -266, 1, -(bottomOffset + 34))
    restartVoteButton.Visible = false
    restartVoteButton.AutoButtonColor = false
    restartVoteButton.Text = 'Vote Restart'
    restartVoteButton.Parent = self._screenGui
    HUDTheme.applySurface(restartVoteButton, {
        useGradient = false,
    })
    HUDTheme.applyText(restartVoteButton, {
        textXAlignment = Enum.TextXAlignment.Center,
        textSize = 12,
    })
    self._restartVoteButton = restartVoteButton

    table.insert(
        self._connections,
        restartVoteButton.MouseButton1Click:Connect(function()
            local remoteName = self._net.ClientToServer.RequestVoteRestart
            local voteRestartRemote = getRemoteEvent(remoteName, 2)
            if not voteRestartRemote then
                return
            end
            voteRestartRemote:FireServer({
                vote = true,
            })
        end)
    )
    self:_updateVoteButtonVisibility()
end

function HUDController:_createHud()
    local playerGui = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass('PlayerGui')
    if not playerGui then
        return
    end

    local screenGui = Instance.new('ScreenGui')
    screenGui.Name = 'HUDController'
    screenGui.ResetOnSpawn = false
    screenGui.DisplayOrder = 10
    screenGui.IgnoreGuiInset = true
    screenGui.Parent = playerGui
    self._screenGui = screenGui

    local topBar = Instance.new('Frame')
    topBar.Name = 'TopBar'
    topBar.ClipsDescendants = true
    local touchPreferred = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
    self._touchPreferred = touchPreferred
    local camera = workspace.CurrentCamera
    local viewportSize = camera and camera.ViewportSize or Vector2.new(1280, 720)
    local topBarHeight = touchPreferred and 38 or 42
    local rightMargin = touchPreferred and 8 or 14
    local topBarWidth = math.max(220, math.min(touchPreferred and 248 or 420, viewportSize.X - 24 - rightMargin))
    local topBarX = math.floor((viewportSize.X - topBarWidth) * 0.5)
    topBar.Size = UDim2.fromOffset(topBarWidth, topBarHeight)
    topBar.Position = touchPreferred and UDim2.fromOffset(topBarX, 2) or UDim2.fromOffset(topBarX, 0)
    topBar.Parent = screenGui
    self._topBar = topBar
    HUDTheme.applySurface(topBar)

    local function createLabel(name: string, xOffset: number, width: number): TextLabel
        local label = Instance.new('TextLabel')
        label.Name = name
        label.Size = UDim2.fromOffset(width, 18)
        label.Position = UDim2.fromOffset(xOffset, 12)
        label.BackgroundTransparency = 1
        HUDTheme.applyText(label, {
            textXAlignment = Enum.TextXAlignment.Left,
            textSize = touchPreferred and 11 or 12,
        })
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Text = '-'
        label.Parent = topBar
        return label
    end

    -- Milestone 4: persistent combat strip prioritizes tactical-critical signals.
    self._labels.wave = createLabel('WaveLabel', 10, 78)
    self._labels.mode = createLabel('ModeLabel', 88, 94)
    self._labels.time = createLabel('TimeLabel', 182, 112)
    self._labels.base = createLabel('BaseLabel', 294, 84)
    self._labels.speed = createLabel('SpeedLabel', 378, 126)
    self._labels.spawn = createLabel('SpawnCueLabel', 504, 124)
    self._labels.lane = createLabel('LaneCueLabel', 628, 148)
    self._labels.elites = createLabel('ElitesLabel', 776, 110)
    self:_updateTopBarVisibility()

    local queueCountdownLabel = Instance.new('TextLabel')
    queueCountdownLabel.Name = 'QueueCountdownLabel'
    queueCountdownLabel.Size = touchPreferred and UDim2.fromOffset(184, 32) or UDim2.fromOffset(150, 26)
    queueCountdownLabel.Position = touchPreferred and UDim2.new(1, -192, 0, 60) or UDim2.new(1, -158, 0, 44)
    queueCountdownLabel.TextXAlignment = Enum.TextXAlignment.Center
    queueCountdownLabel.Text = ''
    queueCountdownLabel.Visible = false
    queueCountdownLabel.Parent = screenGui
    HUDTheme.applySurface(queueCountdownLabel, {
        cornerRadius = 10,
        strokeThickness = 1.5,
        strokeTransparency = 0.22,
    })
    HUDTheme.applyText(queueCountdownLabel, {
        textXAlignment = Enum.TextXAlignment.Center,
    })
    self._queueCountdownLabel = queueCountdownLabel
    self:_updateQueueCountdownVisibility()
    self:_bindVoteButtons()
    self:_updateResponsiveHudLayout()
end

function HUDController:_bindTowerRuntimeCounters()
    local towerPlacedRemote = getRemoteEvent(self._net.ServerToClient.TowerPlaced, 5)
    if towerPlacedRemote then
        table.insert(
            self._connections,
            towerPlacedRemote.OnClientEvent:Connect(function(payload)
                if type(payload) ~= 'table' then
                    return
                end
                self._state.towerCount = math.max(0, (tonumber(self._state.towerCount) or 0) + 1)
                self:_updateHudText()
            end)
        )
    end

    local towerRemovedRemote = getRemoteEvent(self._net.ServerToClient.TowerRemoved, 5)
    if towerRemovedRemote then
        table.insert(
            self._connections,
            towerRemovedRemote.OnClientEvent:Connect(function(_payload)
                self._state.towerCount = math.max(0, (tonumber(self._state.towerCount) or 0) - 1)
                self:_updateHudText()
            end)
        )
    end
end

function HUDController:_bindRoundStatus()
    local roundStatusRemote = getRemoteEvent(self._net.ServerToClient.RoundStatus, 5)
    if not roundStatusRemote then
        return
    end

    table.insert(
        self._connections,
        roundStatusRemote.OnClientEvent:Connect(function(payload)
            local state = self._state

            state.phase = payload and payload.phase or state.phase
            state.timeRemaining = payload and payload.timeRemaining or '-'
            state.baseHealth = payload and payload.baseHealth or '-'
            state.roundNumber = payload and payload.roundNumber or state.roundNumber
            state.eliteExpectedCount = payload and payload.eliteExpectedCount or 0
            state.eliteSpawnedCount = payload and payload.eliteSpawnedCount or 0
            state.queueState = payload and payload.queueState or state.queueState
            state.queueSize = payload and payload.queueSize or state.queueSize
            state.queueReadyCount = payload and payload.queueReadyCount or state.queueReadyCount
            state.restartVotePassed = payload and payload.restartVotePassed == true
            state.gameSpeedMultiplier = payload and payload.gameSpeedMultiplier or state.gameSpeedMultiplier
            state.gameSpeedLabel = payload and payload.gameSpeedLabel or state.gameSpeedLabel
            state.speedControlState = payload and payload.speedControlState or state.speedControlState
            state.activeEnemyCount = payload and payload.activeEnemyCount or state.activeEnemyCount
            state.enemyTargetCount = payload and payload.enemyTargetCount or state.enemyTargetCount
            state.enemySpawnedCount = payload and payload.enemySpawnedCount or state.enemySpawnedCount
            state.enemyRemainingCount = payload and payload.enemyRemainingCount or state.enemyRemainingCount
            state.roundMutatorName = payload and (payload.roundMutatorName or payload.roundModifierName)
                or state.roundMutatorName
            state.roundMutatorThreatHint = payload and payload.roundMutatorThreatHint or state.roundMutatorThreatHint
            state.missionCompletedCount = payload and payload.missionCompletedCount or state.missionCompletedCount
            state.missionTotalCount = payload and payload.missionTotalCount or state.missionTotalCount
            local queueCountdownTimeRemaining = payload and payload.queueCountdownTimeRemaining
            if type(queueCountdownTimeRemaining) == 'number' then
                state.queueCountdownTimeRemaining = queueCountdownTimeRemaining
            elseif
                state.phase == 'Lobby'
                and state.queueState == 'CountingDown'
                and type(payload and payload.timeRemaining) == 'number'
            then
                state.queueCountdownTimeRemaining = payload.timeRemaining
            else
                state.queueCountdownTimeRemaining = nil
            end
            if state.phase == 'Lobby' then
                state.towerCount = 0
            end
            self:_updateTopBarVisibility()
            self:_updateQueueCountdownVisibility()
            self:_updateVoteButtonVisibility()

            self:_updateHudText()
        end)
    )
end

function HUDController:start()
    if self._running then
        return
    end
    self._running = true

    self:_createHud()
    self:_bindTopLeftLayoutFootprint()
    self:_bindRoundStatus()
    self:_bindTowerRuntimeCounters()
    self:_updateHudText()
end

function HUDController:stop()
    if not self._running then
        return
    end
    self._running = false

    for _, connection in ipairs(self._connections) do
        connection:Disconnect()
    end
    table.clear(self._connections)
    table.clear(self._labels)

    if self._screenGui then
        self._screenGui:Destroy()
        self._screenGui = nil
    end
    self._topBar = nil
    self._queueCountdownLabel = nil
    self._restartVoteButton = nil
    self._touchPreferred = false
end

return HUDController
