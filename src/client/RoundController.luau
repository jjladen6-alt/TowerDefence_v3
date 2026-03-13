local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local StarterGui = game:GetService('StarterGui')
local UserInputService = game:GetService('UserInputService')

local Shared = ReplicatedStorage:WaitForChild('Shared')
local GameConfig = require(Shared:WaitForChild('GameConfig'))
local FAILURE_REASON_TO_MESSAGE = require(Shared:WaitForChild('FailureReasonMessages'))

local RoundController = {}
RoundController.__index = RoundController

function RoundController.new(net)
    return setmetatable({
        _net = net,
        _connections = {},
        _running = false,
        _lastOutcome = nil,
        _lastCurrency = nil,
        _lastQueueState = nil,
        _lastQueueSize = nil,
        _lastPhase = nil,
        _lastEnemyKilledCount = nil,
        _lastEnemyLeakedCount = nil,
        _lastEnemyRemainingCount = nil,
        _lastKillNotifyAt = 0,
        _pendingCurrencyGain = 0,
        _lastCurrencyGainNotifyAt = 0,
        _lastRoundStatusLogAt = 0,
        _lastRoundStatusHash = nil,
        _latestPhase = 'Idle',
        _latestRestartVotePassed = false,
        _voteRestartRemote = nil,
    }, RoundController)
end

local function getRemoteEvent(remoteName: string, timeoutSeconds: number?): RemoteEvent?
    local replicatedStorage = game:GetService('ReplicatedStorage')
    local remotesFolder = replicatedStorage:FindFirstChild('Remotes')
    if not remotesFolder then
        remotesFolder = replicatedStorage:WaitForChild('Remotes', timeoutSeconds or 5)
        if not remotesFolder then
            return nil
        end
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

function RoundController:_notify(text: string)
    if text == '' then
        return
    end
    if GameConfig.CLIENT_USE_HUD_CONTROLLER == true then
        return
    end

    local ok = pcall(function()
        StarterGui:SetCore('SendNotification', {
            Title = 'Tower Defence',
            Text = text,
            Duration = 3,
        })
    end)
    if not ok then
        print(('[HUD] %s'):format(text))
    end
end

function RoundController:_debugPrint(message: string)
    if GameConfig.DEBUG_CLIENT_EVENT_LOGS == true then
        print(message)
    end
end

function RoundController:_shouldPrintRoundStatus(statusHash: string): boolean
    if GameConfig.DEBUG_ROUND_STATUS_LOGS ~= true then
        return false
    end

    local nowTime = os.clock()
    if statusHash ~= self._lastRoundStatusHash then
        self._lastRoundStatusHash = statusHash
        self._lastRoundStatusLogAt = nowTime
        return true
    end

    return false
end

function RoundController:start()
    if self._running then
        return
    end
    self._running = true

    local localPlayer = Players.LocalPlayer
    self._voteRestartRemote = getRemoteEvent(self._net.ClientToServer.RequestVoteRestart, 5)

    local roundStatusRemote = getRemoteEvent(self._net.ServerToClient.RoundStatus, 5)
    if roundStatusRemote then
        table.insert(
            self._connections,
            roundStatusRemote.OnClientEvent:Connect(function(payload)
                local phase = payload and payload.phase or 'Unknown'
                local timeRemaining = payload and payload.timeRemaining
                local activeEnemyCount = payload and payload.activeEnemyCount
                local baseHealth = payload and payload.baseHealth
                local lastLeakEnemyId = payload and payload.lastLeakEnemyId
                local outcome = payload and payload.outcome
                local endReason = payload and payload.endReason
                local queueState = payload and payload.queueState
                local queueSize = payload and payload.queueSize
                local enemyTargetCount = payload and payload.enemyTargetCount
                local enemySpawnedCount = payload and payload.enemySpawnedCount
                local enemyResolvedCount = payload and payload.enemyResolvedCount
                local enemyLeakedCount = payload and payload.enemyLeakedCount
                local enemyKilledCount = payload and payload.enemyKilledCount
                local enemyRemainingCount = payload and payload.enemyRemainingCount
                local roundNumber = payload and payload.roundNumber
                local roundModifierName = payload and payload.roundModifierName
                local roundMutatorName = payload and (payload.roundMutatorName or roundModifierName)
                local missionCompletedCount = payload and payload.missionCompletedCount
                local missionTotalCount = payload and payload.missionTotalCount
                local selectedDifficulty = payload and (payload.activeDifficulty or payload.selectedDifficulty)
                local activeDifficultyPreset = payload and payload.activeDifficultyPreset
                local restartVoteYesCount = payload and payload.restartVoteYesCount
                local restartVoteRequiredCount = payload and payload.restartVoteRequiredCount
                local restartVotePassed = payload and payload.restartVotePassed

                local previousPhase = self._lastPhase
                self._lastPhase = phase
                self._latestPhase = phase
                self._latestRestartVotePassed = restartVotePassed == true
                if phase == 'Wave' and previousPhase ~= 'Wave' then
                    self._lastEnemyKilledCount = enemyKilledCount
                    self._lastEnemyLeakedCount = enemyLeakedCount
                    self._lastEnemyRemainingCount = enemyRemainingCount
                    if type(enemyTargetCount) == 'number' then
                        if type(roundNumber) == 'number' then
                            if type(roundModifierName) == 'string' and roundModifierName ~= '' then
                                self:_notify(
                                    ('Round %d started [%s]: %d enemies.'):format(
                                        roundNumber,
                                        roundModifierName,
                                        enemyTargetCount
                                    )
                                )
                            else
                                self:_notify(('Round %d started: %d enemies.'):format(roundNumber, enemyTargetCount))
                            end
                        else
                            self:_notify(('Wave started: %d enemies.'):format(enemyTargetCount))
                        end
                    else
                        self:_notify('Wave started.')
                    end
                end

                if outcome and outcome ~= self._lastOutcome then
                    self._lastOutcome = outcome
                    if outcome == 'Victory' then
                        self:_notify('Round complete: Victory!')
                    elseif outcome == 'Defeat' then
                        self:_notify('Round complete: Defeat.')
                    else
                        self:_notify(('Round complete: %s'):format(tostring(outcome)))
                    end
                elseif not outcome then
                    self._lastOutcome = nil
                end

                if type(queueState) == 'string' and type(queueSize) == 'number' then
                    if queueState ~= self._lastQueueState or queueSize ~= self._lastQueueSize then
                        self._lastQueueState = queueState
                        self._lastQueueSize = queueSize
                        local playerLabel = queueSize == 1 and 'player' or 'players'
                        self:_notify(('Queue: %d %s (%s)'):format(queueSize, playerLabel, queueState))
                    end
                end

                if phase == 'Wave' then
                    if type(enemyKilledCount) == 'number' then
                        local previousKills = tonumber(self._lastEnemyKilledCount) or enemyKilledCount
                        if enemyKilledCount > previousKills then
                            local killDelta = enemyKilledCount - previousKills
                            local nowTime = os.clock()
                            local canNotify = (nowTime - self._lastKillNotifyAt) >= 1.5 or killDelta >= 3
                            if canNotify then
                                self._lastKillNotifyAt = nowTime
                                if type(enemyRemainingCount) == 'number' then
                                    local label = killDelta == 1 and 'enemy' or 'enemies'
                                    self:_notify(
                                        ('+%d %s down. %d remaining.'):format(killDelta, label, enemyRemainingCount)
                                    )
                                else
                                    local label = killDelta == 1 and 'enemy' or 'enemies'
                                    self:_notify(('+%d %s down.'):format(killDelta, label))
                                end
                            end
                        end
                        self._lastEnemyKilledCount = enemyKilledCount
                    end

                    if type(enemyLeakedCount) == 'number' then
                        local previousLeaks = tonumber(self._lastEnemyLeakedCount) or enemyLeakedCount
                        if enemyLeakedCount > previousLeaks then
                            if type(baseHealth) == 'number' then
                                self:_notify(('Leak! Base health: %d'):format(baseHealth))
                            else
                                self:_notify('Leak! Enemy reached the base.')
                            end
                        end
                        self._lastEnemyLeakedCount = enemyLeakedCount
                    end

                    if type(enemyRemainingCount) == 'number' then
                        local previousRemaining = tonumber(self._lastEnemyRemainingCount)
                        if
                            previousRemaining
                            and previousRemaining > 5
                            and enemyRemainingCount <= 5
                            and enemyRemainingCount > 0
                        then
                            self:_notify(('Final push: %d enemies left.'):format(enemyRemainingCount))
                        end
                        self._lastEnemyRemainingCount = enemyRemainingCount
                    end
                end

                local statusHash = table.concat({
                    tostring(roundNumber),
                    tostring(phase),
                    tostring(timeRemaining),
                    tostring(activeEnemyCount),
                    tostring(baseHealth),
                    tostring(lastLeakEnemyId),
                    tostring(outcome),
                    tostring(endReason),
                    tostring(queueState),
                    tostring(queueSize),
                    tostring(enemyTargetCount),
                    tostring(enemySpawnedCount),
                    tostring(enemyResolvedCount),
                    tostring(enemyLeakedCount),
                    tostring(enemyKilledCount),
                    tostring(enemyRemainingCount),
                    tostring(roundModifierName),
                    tostring(roundMutatorName),
                    tostring(missionCompletedCount),
                    tostring(missionTotalCount),
                    tostring(selectedDifficulty),
                    tostring(activeDifficultyPreset),
                    tostring(restartVoteYesCount),
                    tostring(restartVoteRequiredCount),
                    tostring(restartVotePassed),
                }, '|')
                if self:_shouldPrintRoundStatus(statusHash) then
                    print(
                        ('[RoundStatus] roundNumber=%s phase=%s timeRemaining=%s activeEnemyCount=%s baseHealth=%s lastLeakEnemyId=%s outcome=%s endReason=%s queueState=%s queueSize=%s enemyTargetCount=%s enemySpawnedCount=%s enemyResolvedCount=%s enemyLeakedCount=%s enemyKilledCount=%s enemyRemainingCount=%s roundModifierName=%s roundMutatorName=%s missions=%s/%s selectedDifficulty=%s activeDifficultyPreset=%s restartVote=%s/%s:%s'):format(
                            tostring(roundNumber),
                            tostring(phase),
                            tostring(timeRemaining),
                            tostring(activeEnemyCount),
                            tostring(baseHealth),
                            tostring(lastLeakEnemyId),
                            tostring(outcome),
                            tostring(endReason),
                            tostring(queueState),
                            tostring(queueSize),
                            tostring(enemyTargetCount),
                            tostring(enemySpawnedCount),
                            tostring(enemyResolvedCount),
                            tostring(enemyLeakedCount),
                            tostring(enemyKilledCount),
                            tostring(enemyRemainingCount),
                            tostring(roundModifierName),
                            tostring(roundMutatorName),
                            tostring(missionCompletedCount),
                            tostring(missionTotalCount),
                            tostring(selectedDifficulty),
                            tostring(activeDifficultyPreset),
                            tostring(restartVoteYesCount),
                            tostring(restartVoteRequiredCount),
                            tostring(restartVotePassed)
                        )
                    )
                end
            end)
        )
    end

    table.insert(
        self._connections,
        UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
            if gameProcessedEvent or input.UserInputType ~= Enum.UserInputType.Keyboard then
                return
            end

            if input.KeyCode == Enum.KeyCode.R then
                if self._voteRestartRemote and self._latestPhase == 'Results' and not self._latestRestartVotePassed then
                    self._voteRestartRemote:FireServer({
                        vote = true,
                    })
                end
            end
        end)
    )

    local systemMessageRemote = getRemoteEvent(self._net.ServerToClient.SystemMessage, 5)
    if systemMessageRemote then
        table.insert(
            self._connections,
            systemMessageRemote.OnClientEvent:Connect(function(payload)
                local text = payload and payload.text or ''
                if text ~= '' then
                    local _, queueMessage = string.match(text, '^%[Queue%]%[([%w_]+)%]%s*(.*)$')
                    if queueMessage and queueMessage ~= '' then
                        self:_notify(queueMessage)
                    else
                        self:_notify(text)
                    end
                    self:_debugPrint(('[SystemMessage] %s'):format(text))
                end
            end)
        )
    end

    local towerPlacementFailedRemote = getRemoteEvent(self._net.ServerToClient.TowerPlacementFailed, 5)
    if towerPlacementFailedRemote then
        table.insert(
            self._connections,
            towerPlacementFailedRemote.OnClientEvent:Connect(function(payload)
                local requestType = payload and payload.requestType or 'UnknownRequest'
                local reasonCode = payload and payload.reasonCode or 'UNKNOWN_REASON'
                local message = payload and payload.message or ''
                local hudMessage = FAILURE_REASON_TO_MESSAGE[reasonCode] or message
                if hudMessage ~= '' then
                    self:_notify(hudMessage)
                end
                self:_debugPrint(
                    ('[TowerPlacementFailed] requestType=%s reasonCode=%s message=%s'):format(
                        tostring(requestType),
                        tostring(reasonCode),
                        tostring(message)
                    )
                )
            end)
        )
    end

    local economyUpdatedRemote = getRemoteEvent(self._net.ServerToClient.EconomyUpdated, 5)
    if economyUpdatedRemote then
        table.insert(
            self._connections,
            economyUpdatedRemote.OnClientEvent:Connect(function(payload)
                local currency = payload and payload.currency
                if type(currency) == 'number' then
                    local previousCurrency = self._lastCurrency
                    self._lastCurrency = currency
                    if previousCurrency == nil then
                        self:_notify(('Currency: %d'):format(currency))
                    else
                        local delta = currency - previousCurrency
                        if delta > 0 then
                            self._pendingCurrencyGain += delta
                            local nowTime = os.clock()
                            local shouldFlush = self._pendingCurrencyGain >= 25
                                or (nowTime - self._lastCurrencyGainNotifyAt) >= 1.0
                            if shouldFlush then
                                self._lastCurrencyGainNotifyAt = nowTime
                                self:_notify(('+%d currency (total %d)'):format(self._pendingCurrencyGain, currency))
                                self._pendingCurrencyGain = 0
                            end
                        end
                    end
                end
                self:_debugPrint(('[EconomyUpdated] currency=%s'):format(tostring(currency)))
            end)
        )
    end

    local towerPlacedRemote = getRemoteEvent(self._net.ServerToClient.TowerPlaced, 5)
    if towerPlacedRemote then
        table.insert(
            self._connections,
            towerPlacedRemote.OnClientEvent:Connect(function(payload)
                local ownerUserId = payload and payload.ownerUserId
                local towerId = payload and payload.towerId
                local towerType = payload and payload.towerType
                if localPlayer and ownerUserId == localPlayer.UserId then
                    self:_notify('Tower placed.')
                end
                self:_debugPrint(
                    ('[TowerPlaced] towerId=%s towerType=%s ownerUserId=%s'):format(
                        tostring(towerId),
                        tostring(towerType),
                        tostring(ownerUserId)
                    )
                )
            end)
        )
    end

    local towerRemovedRemote = getRemoteEvent(self._net.ServerToClient.TowerRemoved, 5)
    if towerRemovedRemote then
        table.insert(
            self._connections,
            towerRemovedRemote.OnClientEvent:Connect(function(payload)
                local ownerUserId = payload and payload.ownerUserId
                local refundAmount = payload and payload.refundAmount
                local towerId = payload and payload.towerId
                if localPlayer and ownerUserId == localPlayer.UserId then
                    if type(refundAmount) == 'number' then
                        self:_notify(('Tower sold. Refund: %d'):format(refundAmount))
                    else
                        self:_notify('Tower sold.')
                    end
                end
                self:_debugPrint(
                    ('[TowerRemoved] towerId=%s ownerUserId=%s refundAmount=%s'):format(
                        tostring(towerId),
                        tostring(ownerUserId),
                        tostring(refundAmount)
                    )
                )
            end)
        )
    end

    local towerUpdatedRemote = getRemoteEvent(self._net.ServerToClient.TowerUpdated, 5)
    if towerUpdatedRemote then
        table.insert(
            self._connections,
            towerUpdatedRemote.OnClientEvent:Connect(function(payload)
                local ownerUserId = payload and payload.ownerUserId
                local upgradeTier = payload and payload.upgradeTier
                local towerId = payload and payload.towerId
                local upgradeCost = payload and payload.upgradeCost
                local targetMode = payload and payload.targetMode
                if localPlayer and ownerUserId == localPlayer.UserId then
                    if type(targetMode) == 'string' and targetMode ~= '' then
                        self:_notify(('Tower target mode: %s'):format(targetMode))
                    elseif type(upgradeTier) == 'number' then
                        self:_notify(('Tower upgraded to tier %d.'):format(upgradeTier))
                    else
                        self:_notify('Tower upgraded.')
                    end
                end
                self:_debugPrint(
                    ('[TowerUpdated] towerId=%s ownerUserId=%s upgradeTier=%s upgradeCost=%s targetMode=%s'):format(
                        tostring(towerId),
                        tostring(ownerUserId),
                        tostring(upgradeTier),
                        tostring(upgradeCost),
                        tostring(targetMode)
                    )
                )
            end)
        )
    end
end

function RoundController:stop()
    if not self._running then
        return
    end
    self._running = false
    self._lastOutcome = nil
    self._lastCurrency = nil
    self._lastQueueState = nil
    self._lastQueueSize = nil
    self._lastPhase = nil
    self._lastEnemyKilledCount = nil
    self._lastEnemyLeakedCount = nil
    self._lastEnemyRemainingCount = nil
    self._lastKillNotifyAt = 0
    self._pendingCurrencyGain = 0
    self._lastCurrencyGainNotifyAt = 0
    self._lastRoundStatusLogAt = 0
    self._lastRoundStatusHash = nil
    self._latestPhase = 'Idle'
    self._latestRestartVotePassed = false
    self._voteRestartRemote = nil

    for _, connection in ipairs(self._connections) do
        connection:Disconnect()
    end
    table.clear(self._connections)
end

return RoundController
