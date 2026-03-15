local Net = {}

Net.ClientToServer = {
    RequestCreateMatch = 'RequestCreateMatch',
    RequestReady = 'RequestReady',
    RequestVoteDifficulty = 'RequestVoteDifficulty',
    RequestPlaceTower = 'RequestPlaceTower',
    RequestUpgradeTower = 'RequestUpgradeTower',
    RequestSellTower = 'RequestSellTower',
    RequestSetTowerTargetMode = 'RequestSetTowerTargetMode',
    RequestVoteRestart = 'RequestVoteRestart',
    RequestPurchaseTowerMetaUpgrade = 'RequestPurchaseTowerMetaUpgrade',
}

Net.ServerToClient = {
    RoundStatus = 'RoundStatus',
    TowerPlaced = 'TowerPlaced',
    TowerUpdated = 'TowerUpdated',
    TowerRemoved = 'TowerRemoved',
    TowerPlacementFailed = 'TowerPlacementFailed',
    SystemMessage = 'SystemMessage',
    EconomyUpdated = 'EconomyUpdated',
    MetaProgressionUpdated = 'MetaProgressionUpdated',
}

function Net.getAllRemoteNames()
    local names = {}

    for _, remoteName in pairs(Net.ClientToServer) do
        table.insert(names, remoteName)
    end

    for _, remoteName in pairs(Net.ServerToClient) do
        table.insert(names, remoteName)
    end

    return names
end

return Net
