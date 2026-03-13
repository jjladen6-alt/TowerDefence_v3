local ReplicatedStorage = game:GetService('ReplicatedStorage')
local HttpService = game:GetService('HttpService')

local Server = script
local Shared = ReplicatedStorage:WaitForChild('Shared')

local Net = require(Shared:WaitForChild('Net'))
local GameConfig = require(Shared:WaitForChild('GameConfig'))
local WorldContractValidator = require(Server:WaitForChild('WorldContractValidator'))
local PlayerDataService = require(Server:WaitForChild('PlayerDataService'))
local EnemyService = require(Server:WaitForChild('EnemyService'))
local RoundService = require(Server:WaitForChild('RoundService'))
local TowerPlacementService = require(Server:WaitForChild('TowerPlacementService'))
local TowerCombatService = require(Server:WaitForChild('TowerCombatService'))
local QueueService = require(Server:WaitForChild('QueueService'))

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
        service = 'ServerInit',
        kind = kind,
        payload = payload,
    }
end

local function emitServerInitTelemetry(kind: string, payload)
    print(('[Telemetry][ServerInit] %s'):format(jsonEncode(toTelemetryEnvelope(kind, payload))))
end

local startupValidationOk, startupValidationErr = pcall(function()
    WorldContractValidator.validateStartup(Net, GameConfig)
end)
if not startupValidationOk then
    emitServerInitTelemetry('StartupFailure', {
        stage = 'WorldContractValidation',
        reasonCode = 'VALIDATION_FAILED',
        message = tostring(startupValidationErr),
    })
    error(startupValidationErr)
end

local playerDataService = PlayerDataService.new(GameConfig)
local enemyService = EnemyService.new(GameConfig)
local roundService = RoundService.new(GameConfig, Net, enemyService)
local towerPlacementService = TowerPlacementService.new(GameConfig, Net)
local towerCombatService = TowerCombatService.new(GameConfig, enemyService, towerPlacementService)
local queueService = QueueService.new(GameConfig, Net)
towerPlacementService:setRoundService(roundService)
towerPlacementService:setPlayerDataService(playerDataService)
roundService:setQueueService(queueService)
roundService:setTowerPlacementService(towerPlacementService)
towerCombatService:setRoundService(roundService)

local startupServices = {
    { name = 'PlayerDataService', instance = playerDataService },
    { name = 'QueueService', instance = queueService },
    { name = 'TowerPlacementService', instance = towerPlacementService },
    { name = 'TowerCombatService', instance = towerCombatService },
    { name = 'RoundService', instance = roundService },
}

local startedServices = {}

local function stopService(entry, reasonCode: string)
    local stopOk, stopErr = pcall(function()
        entry.instance:stop()
    end)
    if not stopOk then
        emitServerInitTelemetry('RollbackStopFailure', {
            reasonCode = reasonCode,
            service = entry.name,
            message = tostring(stopErr),
        })
    end
end

local function rollbackStartedServices(reasonCode: string, message: string, failedService: string?)
    emitServerInitTelemetry('StartupFailure', {
        stage = 'ServiceStart',
        reasonCode = reasonCode,
        failedService = failedService,
        message = message,
        startedServices = table.clone(startedServices),
    })
    for index = #startupServices, 1, -1 do
        local serviceEntry = startupServices[index]
        for _, startedName in ipairs(startedServices) do
            if startedName == serviceEntry.name then
                stopService(serviceEntry, reasonCode)
                break
            end
        end
    end
end

for _, serviceEntry in ipairs(startupServices) do
    local ok, startErr = pcall(function()
        serviceEntry.instance:start()
    end)
    if not ok then
        rollbackStartedServices('SERVICE_START_FAILED', tostring(startErr), serviceEntry.name)
        error(('[ServerInit] Failed to start %s: %s'):format(serviceEntry.name, tostring(startErr)))
    end
    table.insert(startedServices, serviceEntry.name)
end

game:BindToClose(function()
    for index = #startupServices, 1, -1 do
        stopService(startupServices[index], 'BIND_TO_CLOSE')
    end
end)

print('[Server] TowerDefence_v3 startup complete (round loop + release-gate baseline active)')
