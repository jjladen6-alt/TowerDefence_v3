local Players = game:GetService('Players')
local DataStoreService = game:GetService('DataStoreService')

local PlayerDataService = {}
PlayerDataService.__index = PlayerDataService

local PROFILE_STORE_NAME = 'TDv3_PlayerProfiles'
local SCHEMA_VERSION = 1

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
        currency = 0,
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

local function normalizeProfile(rawProfile)
    local normalized = defaultProfile()
    local source = if type(rawProfile) == 'table' then rawProfile else {}

    normalized.schemaVersion = SCHEMA_VERSION
    normalized.currency = math.max(0, math.floor(tonumber(source.currency) or normalized.currency))

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
    local normalized = normalizeProfile(loaded)
    local fallbackCurrency = tonumber(self._gameConfig and self._gameConfig.STARTING_CURRENCY) or 0
    if normalized.currency <= 0 and fallbackCurrency > 0 and loaded == nil then
        normalized.currency = math.floor(fallbackCurrency)
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
    local snapshot = deepCopy(normalizeProfile(profile))
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
        return normalizeProfile(nil)
    end
    return deepCopy(profile)
end

function PlayerDataService:getCurrency(userId: number): number
    local profile = self._profilesByUserId[userId]
    if type(profile) ~= 'table' then
        local fallbackCurrency = tonumber(self._gameConfig and self._gameConfig.STARTING_CURRENCY) or 0
        return math.max(0, math.floor(fallbackCurrency))
    end
    return math.max(0, math.floor(tonumber(profile.currency) or 0))
end

function PlayerDataService:setCurrency(userId: number, amount: number)
    if type(self._profilesByUserId[userId]) ~= 'table' then
        self:_loadProfile(userId)
    end
    local profile = self._profilesByUserId[userId]
    if type(profile) ~= 'table' then
        return
    end
    profile.currency = math.max(0, math.floor(tonumber(amount) or 0))
    self._dirtyByUserId[userId] = true
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
