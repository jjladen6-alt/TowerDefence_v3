local Players = game:GetService('Players')
local DataStoreService = game:GetService('DataStoreService')

local PlayerDataService = {}
PlayerDataService.__index = PlayerDataService

local PROFILE_STORE_NAME = 'TDv3_PlayerProfiles'
local SCHEMA_VERSION = 1

local function getConfiguredTowerTypes(gameConfig): { string }
    local towerTypes = {}
    local seen = {}

    local function addTowerType(value)
        if type(value) == 'string' and value ~= '' and not seen[value] then
            seen[value] = true
            table.insert(towerTypes, value)
        end
    end

    if type(gameConfig) == 'table' then
        local towerCosts = gameConfig.TOWER_COSTS
        if type(towerCosts) == 'table' then
            for towerType in pairs(towerCosts) do
                addTowerType(towerType)
            end
        end

        local towerSchema = gameConfig.TOWER_MODEL_SCHEMA
        if type(towerSchema) == 'table' and type(towerSchema.towers) == 'table' then
            for towerType in pairs(towerSchema.towers) do
                addTowerType(towerType)
            end
        end
    end

    table.sort(towerTypes)
    return towerTypes
end

local function getTowerUpgradeMaxLevel(gameConfig, towerType: string): number
    if type(gameConfig) ~= 'table' then
        return 0
    end
    local configured = gameConfig.META_UPGRADE_MAX_LEVEL_BY_TOWER
    if type(configured) == 'table' then
        local explicitMax = tonumber(configured[towerType])
        if explicitMax and explicitMax >= 0 then
            return math.floor(explicitMax)
        end
    end
    local fallback = tonumber(gameConfig.META_UPGRADE_DEFAULT_MAX_LEVEL)
    if fallback and fallback >= 0 then
        return math.floor(fallback)
    end
    return 0
end

local function buildDefaultMaps()
    local maps = {}
    for mapIndex = 1, 6 do
        local mapId = ('Map%d'):format(mapIndex)
        maps[mapId] = {
            unlocked = true,
            bestAct = 0,
            bestWave = 0,
        }
    end
    return maps
end

local function defaultProfile()
    return {
        schemaVersion = SCHEMA_VERSION,
        permanentCoins = 0,
        currency = 0,
        towerUpgrades = {},
        maps = buildDefaultMaps(),
        stats = {
            roundsPlayed = 0,
            roundsWon = 0,
        },
    }
end

local function deepCopy(value)
    if type(value) ~= 'table' then
        return value
    end
    local copied = {}
    for key, childValue in pairs(value) do
        copied[key] = deepCopy(childValue)
    end
    return copied
end

local function normalizeTowerUpgrades(rawUpgrades, gameConfig)
    local normalizedUpgrades = {}
    if type(rawUpgrades) ~= 'table' then
        return normalizedUpgrades
    end

    local allowedTowerTypes = getConfiguredTowerTypes(gameConfig)
    local allowAnyTowerType = #allowedTowerTypes == 0
    local allowedLookup = {}
    for _, towerType in ipairs(allowedTowerTypes) do
        allowedLookup[towerType] = true
    end

    for towerType, rawLevel in pairs(rawUpgrades) do
        if type(towerType) == 'string' and towerType ~= '' and (allowAnyTowerType or allowedLookup[towerType]) then
            local maxLevel = getTowerUpgradeMaxLevel(gameConfig, towerType)
            local level = math.max(0, math.floor(tonumber(rawLevel) or 0))
            if maxLevel > 0 then
                level = math.min(maxLevel, level)
            end
            if level > 0 then
                normalizedUpgrades[towerType] = level
            end
        end
    end

    return normalizedUpgrades
end

local function normalizeProfile(rawProfile, gameConfig)
    local normalized = defaultProfile()
    local source = if type(rawProfile) == 'table' then rawProfile else {}

    normalized.schemaVersion = SCHEMA_VERSION
    local legacyCurrency = math.max(0, math.floor(tonumber(source.currency) or 0))
    local permanentCoins = tonumber(source.permanentCoins)
    if permanentCoins == nil then
        permanentCoins = legacyCurrency
    end
    normalized.permanentCoins = math.max(0, math.floor(permanentCoins or 0))
    -- Legacy field retained during migration window.
    normalized.currency = normalized.permanentCoins
    normalized.towerUpgrades = normalizeTowerUpgrades(source.towerUpgrades, gameConfig)

    if type(source.maps) == 'table' then
        for mapId, mapState in pairs(source.maps) do
            if type(mapId) == 'string' and type(mapState) == 'table' then
                if normalized.maps[mapId] == nil then
                    normalized.maps[mapId] = {
                        unlocked = true,
                        bestAct = 0,
                        bestWave = 0,
                    }
                end
                normalized.maps[mapId].unlocked = mapState.unlocked ~= false
                normalized.maps[mapId].bestAct = math.max(0, math.floor(tonumber(mapState.bestAct) or 0))
                normalized.maps[mapId].bestWave = math.max(0, math.floor(tonumber(mapState.bestWave) or 0))
            end
        end
    end

    if type(source.stats) == 'table' then
        normalized.stats.roundsPlayed = math.max(0, math.floor(tonumber(source.stats.roundsPlayed) or 0))
        normalized.stats.roundsWon = math.max(0, math.floor(tonumber(source.stats.roundsWon) or 0))
    end

    return normalized
end

function PlayerDataService.new(gameConfig)
    local storeName = PROFILE_STORE_NAME
    if type(gameConfig) == 'table' then
        local configuredName = gameConfig.PLAYER_PROFILE_DATASTORE_NAME
        if type(configuredName) == 'string' and configuredName ~= '' then
            storeName = configuredName
        end
    end
    local dataStore = DataStoreService:GetDataStore(storeName)
    return setmetatable({
        _gameConfig = gameConfig,
        _dataStore = dataStore,
        _running = false,
        _runId = 0,
        _profilesByUserId = {},
        _dirtyByUserId = {},
        _connections = {},
    }, PlayerDataService)
end

function PlayerDataService:_profileKeyForUserId(userId: number): string
    return ('u_%d'):format(userId)
end

function PlayerDataService:_loadProfile(userId: number)
    local key = self:_profileKeyForUserId(userId)
    local ok, loaded = pcall(function()
        return self._dataStore:GetAsync(key)
    end)
    if not ok then
        warn(('[PlayerDataService] Failed loading profile for %d: %s'):format(userId, tostring(loaded)))
        loaded = nil
    end
    local normalized = normalizeProfile(loaded, self._gameConfig)
    local fallbackCurrency = tonumber(self._gameConfig and self._gameConfig.STARTING_CURRENCY) or 0
    if normalized.permanentCoins <= 0 and fallbackCurrency > 0 and loaded == nil then
        normalized.permanentCoins = math.floor(fallbackCurrency)
        normalized.currency = normalized.permanentCoins
    end
    self._profilesByUserId[userId] = normalized
    -- Only mark newly created profiles dirty; existing profiles should not autosave on shutdown
    -- unless gameplay actually changed them.
    self._dirtyByUserId[userId] = loaded == nil
end

function PlayerDataService:_saveProfile(userId: number, force: boolean?)
    local profile = self._profilesByUserId[userId]
    if type(profile) ~= 'table' then
        return false
    end
    if force ~= true and self._dirtyByUserId[userId] ~= true then
        return true
    end
    local key = self:_profileKeyForUserId(userId)
    local snapshot = deepCopy(normalizeProfile(profile, self._gameConfig))
    local ok, err = pcall(function()
        self._dataStore:UpdateAsync(key, function()
            return snapshot
        end)
    end)
    if not ok then
        warn(('[PlayerDataService] Failed saving profile for %d: %s'):format(userId, tostring(err)))
        return false
    end
    self._dirtyByUserId[userId] = nil
    self._profilesByUserId[userId] = snapshot
    return true
end

function PlayerDataService:_saveDirtyProfiles()
    for userId, isDirty in pairs(self._dirtyByUserId) do
        if isDirty then
            self:_saveProfile(userId)
        end
    end
end

function PlayerDataService:getProfile(userId: number)
    local profile = self._profilesByUserId[userId]
    if type(profile) ~= 'table' then
        return normalizeProfile(nil, self._gameConfig)
    end
    return deepCopy(profile)
end

function PlayerDataService:getCurrency(userId: number): number
    local profile = self._profilesByUserId[userId]
    if type(profile) ~= 'table' then
        local fallbackCurrency = tonumber(self._gameConfig and self._gameConfig.STARTING_CURRENCY) or 0
        return math.max(0, math.floor(fallbackCurrency))
    end
    return math.max(0, math.floor(tonumber(profile.permanentCoins) or 0))
end

function PlayerDataService:setCurrency(userId: number, amount: number)
    if type(self._profilesByUserId[userId]) ~= 'table' then
        self:_loadProfile(userId)
    end
    local profile = self._profilesByUserId[userId]
    if type(profile) ~= 'table' then
        return
    end
    local normalizedAmount = math.max(0, math.floor(tonumber(amount) or 0))
    profile.permanentCoins = normalizedAmount
    -- Legacy field retained during migration window.
    profile.currency = normalizedAmount
    self._dirtyByUserId[userId] = true
end

function PlayerDataService:getPermanentCoins(userId: number): number
    return self:getCurrency(userId)
end

function PlayerDataService:setPermanentCoins(userId: number, amount: number)
    self:setCurrency(userId, amount)
end

function PlayerDataService:addPermanentCoins(userId: number, delta: number): number
    local current = self:getPermanentCoins(userId)
    local nextAmount = current + math.max(0, math.floor(tonumber(delta) or 0))
    self:setPermanentCoins(userId, nextAmount)
    return self:getPermanentCoins(userId)
end

function PlayerDataService:getTowerUpgradeLevel(userId: number, towerType: string): number
    local profile = self._profilesByUserId[userId]
    if type(profile) ~= 'table' then
        self:_loadProfile(userId)
        profile = self._profilesByUserId[userId]
    end
    if type(profile) ~= 'table' or type(profile.towerUpgrades) ~= 'table' then
        return 0
    end

    local normalizedTowerType = tostring(towerType or '')
    if normalizedTowerType == '' then
        return 0
    end
    local maxLevel = getTowerUpgradeMaxLevel(self._gameConfig, normalizedTowerType)
    local level = math.max(0, math.floor(tonumber(profile.towerUpgrades[normalizedTowerType]) or 0))
    if maxLevel > 0 then
        level = math.min(maxLevel, level)
    end
    return level
end

function PlayerDataService:setTowerUpgradeLevel(userId: number, towerType: string, level: number): number
    if type(self._profilesByUserId[userId]) ~= 'table' then
        self:_loadProfile(userId)
    end
    local profile = self._profilesByUserId[userId]
    if type(profile) ~= 'table' then
        return 0
    end
    if type(profile.towerUpgrades) ~= 'table' then
        profile.towerUpgrades = {}
    end

    local normalizedTowerType = tostring(towerType or '')
    if normalizedTowerType == '' then
        return 0
    end

    local maxLevel = getTowerUpgradeMaxLevel(self._gameConfig, normalizedTowerType)
    local nextLevel = math.max(0, math.floor(tonumber(level) or 0))
    if maxLevel > 0 then
        nextLevel = math.min(maxLevel, nextLevel)
    end

    if nextLevel <= 0 then
        profile.towerUpgrades[normalizedTowerType] = nil
    else
        profile.towerUpgrades[normalizedTowerType] = nextLevel
    end
    self._dirtyByUserId[userId] = true
    return nextLevel
end

function PlayerDataService:getAllTowerUpgradeLevels(userId: number)
    local profile = self._profilesByUserId[userId]
    if type(profile) ~= 'table' then
        self:_loadProfile(userId)
        profile = self._profilesByUserId[userId]
    end
    local result = {}
    if type(profile) ~= 'table' or type(profile.towerUpgrades) ~= 'table' then
        return result
    end

    for towerType, level in pairs(profile.towerUpgrades) do
        if type(towerType) == 'string' and towerType ~= '' then
            local maxLevel = getTowerUpgradeMaxLevel(self._gameConfig, towerType)
            local safeLevel = math.max(0, math.floor(tonumber(level) or 0))
            if maxLevel > 0 then
                safeLevel = math.min(maxLevel, safeLevel)
            end
            if safeLevel > 0 then
                result[towerType] = safeLevel
            end
        end
    end
    return result
end

function PlayerDataService:start()
    if self._running then
        return
    end
    self._running = true
    self._runId += 1
    local runId = self._runId

    for _, player in ipairs(Players:GetPlayers()) do
        self:_loadProfile(player.UserId)
    end

    table.insert(
        self._connections,
        Players.PlayerAdded:Connect(function(player)
            if not self._running or self._runId ~= runId then
                return
            end
            self:_loadProfile(player.UserId)
        end)
    )

    table.insert(
        self._connections,
        Players.PlayerRemoving:Connect(function(player)
            if not self._running or self._runId ~= runId then
                return
            end
            self:_saveProfile(player.UserId)
            self._profilesByUserId[player.UserId] = nil
            self._dirtyByUserId[player.UserId] = nil
        end)
    )
end

function PlayerDataService:stop()
    if not self._running then
        return
    end
    self._running = false
    self._runId += 1

    self:_saveDirtyProfiles()
    for _, connection in ipairs(self._connections) do
        connection:Disconnect()
    end
    table.clear(self._connections)
    table.clear(self._profilesByUserId)
    table.clear(self._dirtyByUserId)
end

return PlayerDataService
