local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local UserInputService = game:GetService('UserInputService')
local GuiService = game:GetService('GuiService')
local Shared = ReplicatedStorage:WaitForChild('Shared')
local GameConfig = require(Shared:WaitForChild('GameConfig'))
local HUDTheme = require(script.Parent:WaitForChild('ui'):WaitForChild('HUDTheme'))

local HUDController = {}
HUDController.__index = HUDController

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
        _coinContainer = nil,
        _coinLabel = nil,
        _metaContainer = nil,
        _metaCoinsLabel = nil,
        _metaStatusLabel = nil,
        _metaUpgradeButtonsByTowerType = {},
        _towerMenuButton = nil,
        _towerMenuOpen = false,
        _restartVoteButton = nil,
        _touchPreferred = false,
        _state = {
            matchCoins = nil,
            permanentCoins = nil,
            towerUpgrades = {},
            metaStatus = '',
            phase = 'Lobby',
            restartVotePassed = false,
        },
    }, HUDController)
end

function HUDController:_updateVoteButtonVisibility()
    local phase = tostring(self._state.phase or 'Idle')
    local showRestartVote = phase == 'Results' and self._state.restartVotePassed ~= true
    local restartVoteButton = self._restartVoteButton
    if restartVoteButton and restartVoteButton.Parent then
        restartVoteButton.Visible = showRestartVote
    end
end

function HUDController:_updateCoinText()
    local coinLabel = self._coinLabel
    if not coinLabel then
        return
    end
    local phase = tostring(self._state.phase or 'Lobby')
    local showPermanent = phase == 'Lobby'
    local amount = tonumber(showPermanent and self._state.permanentCoins or self._state.matchCoins)
    if amount == nil then
        coinLabel.Text = if showPermanent then 'Permanent Coins: --' else 'Match Coins: --'
        return
    end
    local labelPrefix = if showPermanent then 'Permanent Coins' else 'Match Coins'
    coinLabel.Text = ('%s: %d'):format(labelPrefix, math.max(0, math.floor(amount)))
end

function HUDController:_updateMetaStatusText()
    local statusLabel = self._metaStatusLabel
    if not statusLabel then
        return
    end
    local statusText = tostring(self._state.metaStatus or '')
    if statusText == '' then
        statusText = 'Choose a tower upgrade in Lobby.'
    end
    statusLabel.Text = statusText
end

function HUDController:_getTowerMetaMaxLevel(towerType: string): number
    local maxByTower = GameConfig.META_UPGRADE_MAX_LEVEL_BY_TOWER
    if type(maxByTower) == 'table' then
        local configuredMax = tonumber(maxByTower[towerType])
        if configuredMax and configuredMax >= 0 then
            return math.floor(configuredMax)
        end
    end
    local fallback = tonumber(GameConfig.META_UPGRADE_DEFAULT_MAX_LEVEL)
    if fallback and fallback >= 0 then
        return math.floor(fallback)
    end
    return 0
end

function HUDController:_getTowerMetaUpgradeCost(towerType: string, nextLevel: number): number
    local costsByTower = GameConfig.META_UPGRADE_COSTS_BY_TOWER
    if type(costsByTower) ~= 'table' then
        return 0
    end
    local costList = costsByTower[towerType]
    if type(costList) ~= 'table' then
        return 0
    end
    local level = math.max(1, math.floor(tonumber(nextLevel) or 1))
    return math.max(0, math.floor(tonumber(costList[level]) or 0))
end

function HUDController:_updateMetaCoinText()
    local coinsLabel = self._metaCoinsLabel
    if not coinsLabel then
        return
    end
    local coins = tonumber(self._state.permanentCoins)
    if coins == nil then
        coinsLabel.Text = 'Permanent Coins: --'
        return
    end
    coinsLabel.Text = ('Permanent Coins: %d'):format(math.max(0, math.floor(coins)))
end

function HUDController:_updateMetaUpgradeButtons()
    for towerType, button in pairs(self._metaUpgradeButtonsByTowerType) do
        local currentLevel = math.max(0, math.floor(tonumber(self._state.towerUpgrades[towerType]) or 0))
        local maxLevel = self:_getTowerMetaMaxLevel(towerType)
        local nextLevel = currentLevel + 1
        local upgradeCost = self:_getTowerMetaUpgradeCost(towerType, nextLevel)
        if maxLevel <= 0 then
            button.Text = ('%s: unavailable'):format(towerType)
            button.Active = false
            button.AutoButtonColor = false
        elseif currentLevel >= maxLevel then
            button.Text = ('%s Lv%d/%d (MAX)'):format(towerType, currentLevel, maxLevel)
            button.Active = false
            button.AutoButtonColor = false
        else
            button.Text = ('%s Lv%d -> Lv%d  [%d]'):format(towerType, currentLevel, nextLevel, upgradeCost)
            button.Active = true
            button.AutoButtonColor = true
        end
    end
end

function HUDController:_updateTowerMenuVisibility()
    local phase = tostring(self._state.phase or 'Lobby')
    local menuAllowed = (GameConfig.META_UPGRADE_SHOP_ENABLED == true and phase == 'Lobby')

    local towerMenuButton = self._towerMenuButton
    if towerMenuButton and towerMenuButton.Parent then
        towerMenuButton.Visible = menuAllowed
        towerMenuButton.Text = if self._towerMenuOpen then 'Close Towers' else 'Towers'
    end

    local metaContainer = self._metaContainer
    if metaContainer and metaContainer.Parent then
        metaContainer.Visible = (menuAllowed and self._towerMenuOpen)
    end
end

function HUDController:_toggleTowerMenu()
    self._towerMenuOpen = not self._towerMenuOpen
    self:_updateTowerMenuVisibility()
end

function HUDController:_updateCoinVisibility()
    local coinContainer = self._coinContainer
    if not coinContainer or not coinContainer.Parent then
        return
    end
    local phase = tostring(self._state.phase or 'Lobby')
    coinContainer.Visible = (phase == 'Lobby' or phase == 'Wave' or phase == 'Results' or phase == 'Cleanup')
    self:_updateCoinText()

    self:_updateTowerMenuVisibility()
end

function HUDController:_updateResponsiveHudLayout()
    if not self._screenGui or not self._screenGui.Parent then
        return
    end

    local _, bottomInset = getSafeInsets()
    local safePadding = math.max(0, math.floor(tonumber(GameConfig.UI_SAFE_AREA_PADDING) or 8))
    local safeRight = math.floor(bottomInset.X) + safePadding
    local safeBottom = math.floor(bottomInset.Y) + safePadding

    local coinContainer = self._coinContainer
    if coinContainer and coinContainer.Parent then
        local topOffset = self._touchPreferred and 8 or 6
        coinContainer.Position = UDim2.new(1, -(safeRight + 8), 0, topOffset)
    end

    local towerMenuButton = self._towerMenuButton
    if towerMenuButton and towerMenuButton.Parent then
        local buttonWidth = self._touchPreferred and 148 or 132
        local buttonHeight = self._touchPreferred and 48 or 40
        local livePanelWidth = 0
        if self._metaContainer and self._metaContainer.Parent then
            livePanelWidth = math.floor(self._metaContainer.AbsoluteSize.X)
        end
        local panelWidth = if livePanelWidth > 0 then livePanelWidth else (self._touchPreferred and 300 or 320)
        local openOffsetFromCenter = math.floor(panelWidth / 2) + 12
        local menuX = safePadding + 8
        if self._towerMenuOpen then
            menuX = math.max(safePadding + 8, (self._screenGui.AbsoluteSize.X / 2) - openOffsetFromCenter - buttonWidth)
        end
        towerMenuButton.Size = UDim2.fromOffset(buttonWidth, buttonHeight)
        towerMenuButton.AnchorPoint = Vector2.new(0, 0.5)
        towerMenuButton.Position = UDim2.fromOffset(menuX, math.floor(self._screenGui.AbsoluteSize.Y * 0.5))
    end

    local metaContainer = self._metaContainer
    if metaContainer and metaContainer.Parent then
        local minWidth = self._touchPreferred and 260 or 280
        metaContainer.Size = UDim2.fromOffset(minWidth, 0)
        metaContainer.AnchorPoint = Vector2.new(0.5, 0.5)
        metaContainer.Position = UDim2.new(0.5, 0, 0.5, 0)
    end

    local restartVoteButton = self._restartVoteButton
    if restartVoteButton and restartVoteButton.Parent then
        local touchButtonWidth = math.max(154, math.floor(tonumber(GameConfig.UI_TOUCH_MIN_BUTTON_WIDTH) or 150))
        local touchButtonHeight = math.max(42, math.floor(tonumber(GameConfig.UI_TOUCH_MIN_BUTTON_HEIGHT) or 48))
        local bottomOffset = (self._touchPreferred and 12 or 8) + safeBottom
        if self._touchPreferred then
            restartVoteButton.Size = UDim2.fromOffset(touchButtonWidth, touchButtonHeight)
            restartVoteButton.Position = UDim2.new(1, -(touchButtonWidth + safeRight + 12), 1, -(bottomOffset + 8))
        else
            restartVoteButton.Size = UDim2.fromOffset(132, 34)
            restartVoteButton.Position = UDim2.new(1, -(140 + safeRight), 1, -(bottomOffset + 34))
        end
    end
end

function HUDController:_bindLayoutSignals()
    local camera = workspace.CurrentCamera
    if camera then
        table.insert(
            self._connections,
            camera:GetPropertyChangedSignal('ViewportSize'):Connect(function()
                self:_updateResponsiveHudLayout()
            end)
        )
    end

    table.insert(
        self._connections,
        UserInputService.LastInputTypeChanged:Connect(function(lastInputType)
            local touchPreferred = (lastInputType == Enum.UserInputType.Touch)
            if self._touchPreferred ~= touchPreferred then
                self._touchPreferred = touchPreferred
                self:_updateResponsiveHudLayout()
            end
        end)
    )
end

function HUDController:_bindVoteButton()
    if not self._screenGui then
        return
    end

    local restartVoteButton = Instance.new('TextButton')
    restartVoteButton.Name = 'RestartVoteButton'
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
            local remote = getRemoteEvent(self._net.ClientToServer.RequestVoteRestart, 2)
            if not remote then
                return
            end
            remote:FireServer({
                vote = true,
            })
        end)
    )
    self:_updateVoteButtonVisibility()
end

function HUDController:_requestTowerMetaUpgrade(towerType: string)
    local purchaseRemote = getRemoteEvent(self._net.ClientToServer.RequestPurchaseTowerMetaUpgrade, 2)
    if not purchaseRemote then
        self._state.metaStatus = 'Upgrade remote is unavailable.'
        self:_updateMetaStatusText()
        return
    end
    purchaseRemote:FireServer({
        towerType = towerType,
    })
    self._state.metaStatus = ('Requested %s upgrade...'):format(towerType)
    self:_updateMetaStatusText()
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

    self._touchPreferred = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

    local coinContainer = Instance.new('Frame')
    coinContainer.Name = 'CoinContainer'
    coinContainer.AnchorPoint = Vector2.new(1, 0)
    coinContainer.AutomaticSize = Enum.AutomaticSize.XY
    coinContainer.Size = UDim2.fromOffset(0, 0)
    coinContainer.Parent = screenGui
    HUDTheme.applySurface(coinContainer)
    self._coinContainer = coinContainer

    local coinPadding = Instance.new('UIPadding')
    coinPadding.PaddingLeft = UDim.new(0, self._touchPreferred and 10 or 8)
    coinPadding.PaddingRight = UDim.new(0, self._touchPreferred and 10 or 8)
    coinPadding.PaddingTop = UDim.new(0, self._touchPreferred and 6 or 5)
    coinPadding.PaddingBottom = UDim.new(0, self._touchPreferred and 6 or 5)
    coinPadding.Parent = coinContainer

    local coinLabel = Instance.new('TextLabel')
    coinLabel.Name = 'CoinLabel'
    coinLabel.BackgroundTransparency = 1
    coinLabel.AutomaticSize = Enum.AutomaticSize.XY
    coinLabel.Size = UDim2.fromOffset(0, 0)
    coinLabel.Position = UDim2.fromOffset(0, 0)
    coinLabel.TextXAlignment = Enum.TextXAlignment.Left
    coinLabel.Parent = coinContainer
    HUDTheme.applyText(coinLabel, {
        textXAlignment = Enum.TextXAlignment.Left,
        textSize = self._touchPreferred and 14 or 13,
    })
    self._coinLabel = coinLabel

    local metaContainer = Instance.new('Frame')
    metaContainer.Name = 'MetaUpgradeContainer'
    metaContainer.AnchorPoint = Vector2.new(0, 0)
    metaContainer.AutomaticSize = Enum.AutomaticSize.XY
    metaContainer.Parent = screenGui
    HUDTheme.applySurface(metaContainer, {
        backgroundTransparency = 0.14,
    })
    self._metaContainer = metaContainer

    local towerMenuButton = Instance.new('TextButton')
    towerMenuButton.Name = 'TowerMenuButton'
    towerMenuButton.Text = 'Towers'
    towerMenuButton.AutoButtonColor = true
    towerMenuButton.Parent = screenGui
    HUDTheme.applySurface(towerMenuButton, {
        useGradient = false,
    })
    HUDTheme.applyText(towerMenuButton, {
        textXAlignment = Enum.TextXAlignment.Center,
        textSize = self._touchPreferred and 15 or 13,
    })
    self._towerMenuButton = towerMenuButton
    table.insert(
        self._connections,
        towerMenuButton.MouseButton1Click:Connect(function()
            self:_toggleTowerMenu()
        end)
    )

    local metaPadding = Instance.new('UIPadding')
    metaPadding.PaddingLeft = UDim.new(0, self._touchPreferred and 10 or 8)
    metaPadding.PaddingRight = UDim.new(0, self._touchPreferred and 10 or 8)
    metaPadding.PaddingTop = UDim.new(0, self._touchPreferred and 8 or 6)
    metaPadding.PaddingBottom = UDim.new(0, self._touchPreferred and 8 or 6)
    metaPadding.Parent = metaContainer

    local metaLayout = Instance.new('UIListLayout')
    metaLayout.FillDirection = Enum.FillDirection.Vertical
    metaLayout.Padding = UDim.new(0, self._touchPreferred and 6 or 4)
    metaLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    metaLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    metaLayout.Parent = metaContainer

    local metaTitle = Instance.new('TextLabel')
    metaTitle.Name = 'MetaTitle'
    metaTitle.BackgroundTransparency = 1
    metaTitle.AutomaticSize = Enum.AutomaticSize.XY
    metaTitle.Size = UDim2.fromOffset(0, 0)
    metaTitle.Text = 'Tower Upgrades'
    metaTitle.TextXAlignment = Enum.TextXAlignment.Left
    metaTitle.Parent = metaContainer
    HUDTheme.applyText(metaTitle, {
        textXAlignment = Enum.TextXAlignment.Left,
        textSize = self._touchPreferred and 14 or 13,
    })

    local statusLabel = Instance.new('TextLabel')
    statusLabel.Name = 'MetaStatusLabel'
    statusLabel.BackgroundTransparency = 1
    statusLabel.AutomaticSize = Enum.AutomaticSize.XY
    statusLabel.Size = UDim2.fromOffset(0, 0)
    statusLabel.TextWrapped = false
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.Parent = metaContainer
    HUDTheme.applyText(statusLabel, {
        textXAlignment = Enum.TextXAlignment.Left,
        textSize = self._touchPreferred and 12 or 11,
        textTransparency = 0.08,
    })
    self._metaStatusLabel = statusLabel

    table.clear(self._metaUpgradeButtonsByTowerType)
    local towerTypes = {}
    if type(GameConfig.TOWER_COSTS) == 'table' then
        for towerType in pairs(GameConfig.TOWER_COSTS) do
            if type(towerType) == 'string' and towerType ~= '' then
                table.insert(towerTypes, towerType)
            end
        end
    end
    table.sort(towerTypes)

    for _, towerType in ipairs(towerTypes) do
        local upgradeButton = Instance.new('TextButton')
        upgradeButton.Name = ('MetaUpgrade_%s'):format(towerType)
        upgradeButton.AutomaticSize = Enum.AutomaticSize.XY
        upgradeButton.Size = UDim2.fromOffset(0, self._touchPreferred and 28 or 24)
        upgradeButton.TextXAlignment = Enum.TextXAlignment.Left
        upgradeButton.Parent = metaContainer
        HUDTheme.applySurface(upgradeButton, {
            useGradient = false,
            backgroundTransparency = 0.24,
        })
        HUDTheme.applyText(upgradeButton, {
            textXAlignment = Enum.TextXAlignment.Left,
            textSize = self._touchPreferred and 13 or 12,
        })
        local buttonPadding = Instance.new('UIPadding')
        buttonPadding.PaddingLeft = UDim.new(0, 8)
        buttonPadding.PaddingRight = UDim.new(0, 8)
        buttonPadding.Parent = upgradeButton

        table.insert(
            self._connections,
            upgradeButton.MouseButton1Click:Connect(function()
                self:_requestTowerMetaUpgrade(towerType)
            end)
        )
        self._metaUpgradeButtonsByTowerType[towerType] = upgradeButton
    end

    self:_bindVoteButton()
    self:_updateCoinText()
    self:_updateMetaCoinText()
    self:_updateMetaUpgradeButtons()
    self:_updateMetaStatusText()
    self:_updateCoinVisibility()
    self:_updateTowerMenuVisibility()
    self:_updateResponsiveHudLayout()
end

function HUDController:_bindEconomyUpdates()
    local economyUpdatedRemote = getRemoteEvent(self._net.ServerToClient.EconomyUpdated, 5)
    if not economyUpdatedRemote then
        return
    end

    table.insert(
        self._connections,
        economyUpdatedRemote.OnClientEvent:Connect(function(payload)
            local currency = payload and payload.currency
            if type(currency) == 'number' then
                self._state.matchCoins = currency
                self:_updateCoinText()
            end
        end)
    )
end

function HUDController:_bindMetaProgressionUpdates()
    local remoteName = self._net.ServerToClient.MetaProgressionUpdated
    if type(remoteName) ~= 'string' or remoteName == '' then
        return
    end
    local progressionRemote = getRemoteEvent(remoteName, 5)
    if not progressionRemote then
        return
    end

    table.insert(
        self._connections,
        progressionRemote.OnClientEvent:Connect(function(payload)
            if type(payload) ~= 'table' then
                return
            end
            local permanentCoins = payload.permanentCoins
            if type(permanentCoins) == 'number' then
                self._state.permanentCoins = math.max(0, math.floor(permanentCoins))
                self:_updateMetaCoinText()
            end

            if type(payload.towerUpgrades) == 'table' then
                self._state.towerUpgrades = payload.towerUpgrades
                self:_updateMetaUpgradeButtons()
            end

            if type(payload.purchasedTowerType) == 'string' then
                local level = math.max(0, math.floor(tonumber(payload.purchasedLevel) or 0))
                local cost = math.max(0, math.floor(tonumber(payload.purchaseCost) or 0))
                self._state.metaStatus = ('Upgraded %s to Lv%d (-%d)'):format(payload.purchasedTowerType, level, cost)
                self:_updateMetaStatusText()
            end
        end)
    )
end

function HUDController:_bindRoundStatus()
    local roundStatusRemote = getRemoteEvent(self._net.ServerToClient.RoundStatus, 5)
    if not roundStatusRemote then
        return
    end

    table.insert(
        self._connections,
        roundStatusRemote.OnClientEvent:Connect(function(payload)
            self._state.phase = payload and payload.phase or self._state.phase
            self._state.restartVotePassed = payload and payload.restartVotePassed == true
            self:_updateCoinVisibility()
            self:_updateVoteButtonVisibility()
        end)
    )
end

function HUDController:_bindTowerPlacementFailures()
    local failureRemote = getRemoteEvent(self._net.ServerToClient.TowerPlacementFailed, 5)
    if not failureRemote then
        return
    end
    table.insert(
        self._connections,
        failureRemote.OnClientEvent:Connect(function(payload)
            if type(payload) ~= 'table' then
                return
            end
            if payload.requestType == 'RequestPurchaseTowerMetaUpgrade' then
                local message = tostring(payload.message or 'Upgrade purchase failed.')
                self._state.metaStatus = message
                self:_updateMetaStatusText()
            end
        end)
    )
end

function HUDController:start()
    if self._running then
        return
    end
    self._running = true

    self:_createHud()
    self:_bindLayoutSignals()
    self:_bindEconomyUpdates()
    self:_bindMetaProgressionUpdates()
    self:_bindTowerPlacementFailures()
    self:_bindRoundStatus()
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

    if self._screenGui then
        self._screenGui:Destroy()
        self._screenGui = nil
    end
    self._coinContainer = nil
    self._coinLabel = nil
    self._metaContainer = nil
    self._metaCoinsLabel = nil
    self._metaStatusLabel = nil
    table.clear(self._metaUpgradeButtonsByTowerType)
    self._towerMenuButton = nil
    self._towerMenuOpen = false
    self._restartVoteButton = nil
    self._touchPreferred = false
    self._state.matchCoins = nil
    self._state.permanentCoins = nil
    self._state.towerUpgrades = {}
    self._state.metaStatus = ''
    self._state.phase = 'Lobby'
    self._state.restartVotePassed = false
end

return HUDController
