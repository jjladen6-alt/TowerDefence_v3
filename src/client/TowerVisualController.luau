local Debris = game:GetService('Debris')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local RunService = game:GetService('RunService')
local TweenService = game:GetService('TweenService')
local UserInputService = game:GetService('UserInputService')
local Workspace = game:GetService('Workspace')

local Shared = ReplicatedStorage:WaitForChild('Shared')
local GameConfig = require(Shared:WaitForChild('GameConfig'))

local TowerVisualController = {}
TowerVisualController.__index = TowerVisualController

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

local function getTowerRoot(towerModel: Model): BasePart?
    if towerModel.PrimaryPart and towerModel.PrimaryPart:IsA('BasePart') then
        return towerModel.PrimaryPart
    end
    local firstPart = towerModel:FindFirstChildWhichIsA('BasePart', true)
    if firstPart then
        towerModel.PrimaryPart = firstPart
    end
    return towerModel.PrimaryPart
end

local function getFireOrigin(towerModel: Model, root: BasePart): Vector3
    local _, boundsSize = towerModel:GetBoundingBox()
    local upOffset = math.max(0.75, boundsSize.Y * 0.42)
    local forwardOffset = math.max(0.35, math.min(2.5, boundsSize.Z * 0.2))
    return root.Position + Vector3.new(0, upOffset, 0) + (root.CFrame.LookVector * forwardOffset)
end

local function emitFireballPart(
    container: Instance,
    towerId: string,
    origin: Vector3,
    color: Color3,
    radius: number,
    lifetimeSeconds: number
): Part
    local fireball = Instance.new('Part')
    fireball.Name = 'MuzzleFireball'
    fireball.Shape = Enum.PartType.Ball
    fireball.Anchored = true
    fireball.CanCollide = false
    fireball.CanTouch = false
    fireball.CanQuery = false
    fireball.CastShadow = false
    fireball.Material = Enum.Material.Neon
    fireball.Color = color:Lerp(Color3.fromRGB(255, 145, 55), 0.45)
    fireball.Transparency = 0.2
    fireball.Size = Vector3.new(radius, radius, radius)
    fireball.CFrame = CFrame.new(origin)
    fireball:SetAttribute('TowerId', towerId)
    fireball.Parent = container

    local fireballTween = TweenService:Create(
        fireball,
        TweenInfo.new(math.max(0.04, lifetimeSeconds * 0.65), Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        {
            Size = Vector3.new(radius * 1.9, radius * 1.9, radius * 1.9),
            Transparency = 1,
        }
    )
    fireballTween:Play()
    Debris:AddItem(fireball, lifetimeSeconds)
    return fireball
end

local function emitBulletPart(
    container: Instance,
    towerId: string,
    origin: Vector3,
    direction: Vector3,
    travelDistance: number,
    bulletWidth: number,
    color: Color3,
    lifetimeSeconds: number
): Part
    local bullet = Instance.new('Part')
    bullet.Name = 'AttackBullet'
    bullet.Anchored = true
    bullet.CanCollide = false
    bullet.CanTouch = false
    bullet.CanQuery = false
    bullet.CastShadow = false
    bullet.Material = Enum.Material.Neon
    bullet.Color = color
    bullet.Transparency = 0.12
    bullet.Size = Vector3.new(bulletWidth, bulletWidth, math.max(0.6, bulletWidth * 3.2))
    bullet.CFrame = CFrame.lookAt(origin, origin + direction)
    bullet:SetAttribute('TowerId', towerId)
    bullet.Parent = container

    local endPosition = origin + (direction * travelDistance)
    local bulletTween = TweenService:Create(
        bullet,
        TweenInfo.new(math.max(0.04, lifetimeSeconds * 0.72), Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
        {
            CFrame = CFrame.lookAt(endPosition, endPosition + direction),
            Transparency = 1,
        }
    )
    bulletTween:Play()
    Debris:AddItem(bullet, lifetimeSeconds)
    return bullet
end

function TowerVisualController.new(net)
    return setmetatable({
        _net = net,
        _activeMapName = tostring(GameConfig.ACTIVE_MAP_NAME or GameConfig.DEFAULT_STAGE_ID or 'brown'),
        _running = false,
        _connections = {},
        _phase = 'Idle',
        _towerStateById = {},
        _vfxFolder = nil,
        _activePulseCount = 0,
        _pulseBudgetTier = 'Medium',
        _pulseWindowSecond = 0,
        _pulseWindowCount = 0,
    }, TowerVisualController)
end

function TowerVisualController:_getActiveMapFolder(): Instance?
    return Workspace:FindFirstChild(self._activeMapName)
end

function TowerVisualController:_resolveVfxBudgetTier(): string
    local budgetConfig = type(GameConfig.VFX_BUDGET) == 'table' and GameConfig.VFX_BUDGET or {}
    local defaultTier = tostring(budgetConfig.defaultTier or 'Medium')
    if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
        local touchTier = tostring(budgetConfig.touchDefaultTier or defaultTier)
        if touchTier ~= '' then
            defaultTier = touchTier
        end
    end
    if defaultTier ~= 'Low' and defaultTier ~= 'High' then
        defaultTier = 'Medium'
    end
    return defaultTier
end

function TowerVisualController:_getVfxBudgetTierConfig()
    local budgetConfig = type(GameConfig.VFX_BUDGET) == 'table' and GameConfig.VFX_BUDGET or {}
    local tiers = type(budgetConfig.tiers) == 'table' and budgetConfig.tiers or {}
    local tierConfig = tiers[self._pulseBudgetTier]
    if type(tierConfig) ~= 'table' then
        tierConfig = tiers.Medium
    end
    if type(tierConfig) ~= 'table' then
        tierConfig = {
            maxActivePulses = 36,
            pulseLifetimeSeconds = 0.18,
            pulseSizeMultiplier = 1.0,
            auraRateMultiplier = 0.8,
            maxAuraRate = 6,
            maxBurstPerSecond = 22,
        }
    end
    return tierConfig
end

function TowerVisualController:_getTierVisualStyle(towerType: string, tier: number)
    local progression = GameConfig.TOWER_VISUAL_PROGRESSION
    local typeStyle = type(progression) == 'table' and progression[towerType] or nil
    local tierStyle = type(typeStyle) == 'table' and typeStyle[tier] or nil
    if type(tierStyle) ~= 'table' then
        tierStyle = type(typeStyle) == 'table' and typeStyle[0] or nil
    end
    if type(tierStyle) ~= 'table' then
        tierStyle = {
            accentColor = Color3.fromRGB(120, 210, 255),
            fillTransparency = 0.9,
            outlineTransparency = 0.3,
            auraRate = 0,
        }
    end
    return tierStyle
end

function TowerVisualController:_getAttackVfxStyle(towerType: string)
    local attackVfx = GameConfig.TOWER_ATTACK_VFX
    local byType = type(attackVfx) == 'table' and attackVfx.byType or nil
    local style = type(byType) == 'table' and byType[towerType] or nil
    if type(style) ~= 'table' then
        style = {
            pulseColor = Color3.fromRGB(120, 210, 255),
            pulseSize = 2.5,
            pulseRateFloor = 0.8,
        }
    end
    return style
end

function TowerVisualController:_ensureVfxFolder(): Folder
    local folder = self._vfxFolder
    if folder and folder.Parent then
        return folder
    end
    folder = Instance.new('Folder')
    folder.Name = 'ClientTowerVisualVfx'
    folder.Parent = Workspace
    self._vfxFolder = folder
    return folder
end

function TowerVisualController:_clearTowerTransientVfx(towerId: string)
    local folder = self._vfxFolder
    if not folder or not folder.Parent then
        return
    end
    for _, child in ipairs(folder:GetChildren()) do
        if tostring(child:GetAttribute('TowerId') or '') == towerId then
            child:Destroy()
        end
    end
end

function TowerVisualController:_clearAllTransientVfx()
    local folder = self._vfxFolder
    if not folder or not folder.Parent then
        return
    end
    folder:ClearAllChildren()
    self._activePulseCount = 0
    self._pulseWindowCount = 0
end

function TowerVisualController:_applyTierVisuals(towerModel: Model)
    -- Visual cleanup: no client-side tower outlines/glow markers.
    local highlight = towerModel:FindFirstChild('ClientTierHighlight')
    if highlight and highlight:IsA('Highlight') then
        highlight:Destroy()
    end

    local root = getTowerRoot(towerModel)
    if root then
        local auraAttachment = root:FindFirstChild('ClientTierAuraAttachment')
        if auraAttachment and auraAttachment:IsA('Attachment') then
            auraAttachment:Destroy()
        end
    end
end

function TowerVisualController:_emitAttackPulse(towerId: string, towerModel: Model, towerType: string, tier: number)
    local root = getTowerRoot(towerModel)
    if not root then
        return
    end

    local tierConfig = self:_getVfxBudgetTierConfig()
    local maxActivePulses = math.max(1, math.floor(tonumber(tierConfig.maxActivePulses) or 36))
    if self._activePulseCount >= maxActivePulses then
        return
    end

    local nowSecond = math.floor(os.clock())
    if nowSecond ~= self._pulseWindowSecond then
        self._pulseWindowSecond = nowSecond
        self._pulseWindowCount = 0
    end
    local maxBurstPerSecond = math.max(1, math.floor(tonumber(tierConfig.maxBurstPerSecond) or 22))
    if self._pulseWindowCount >= maxBurstPerSecond then
        return
    end

    local folder = self:_ensureVfxFolder()
    local vfxStyle = self:_getAttackVfxStyle(towerType)
    local pulseColor = vfxStyle.pulseColor
    if typeof(pulseColor) ~= 'Color3' then
        pulseColor = Color3.fromRGB(120, 210, 255)
    end

    local pulseLifetime = math.clamp(tonumber(tierConfig.pulseLifetimeSeconds) or 0.18, 0.08, 0.4)
    local sizeMultiplier = math.clamp(tonumber(tierConfig.pulseSizeMultiplier) or 1, 0.6, 1.6)
    local basePulseSize = math.max(0.8, tonumber(vfxStyle.pulseSize) or 2.2)
    local pulseSize = basePulseSize * sizeMultiplier
    local origin = getFireOrigin(towerModel, root)

    local fireball = emitFireballPart(folder, towerId, origin, pulseColor, pulseSize * 0.55, pulseLifetime)
    self._activePulseCount += 1
    self._pulseWindowCount += 1
    fireball.Destroying:Once(function()
        self._activePulseCount = math.max(0, self._activePulseCount - 1)
    end)
    local bulletDistance = math.max(4, pulseSize * 3.6)
    local bulletWidth = math.max(0.12, 0.18 * sizeMultiplier)

    if towerType == 'Rapid' then
        -- Rapid tower signature: muzzle fireball + radial bullet spray.
        local bulletCount = math.clamp(8 + (tier * 2), 8, 14)
        local budgetRemaining = math.max(0, maxActivePulses - self._activePulseCount)
        bulletCount = math.min(bulletCount, budgetRemaining)
        for index = 1, bulletCount do
            local angle = ((index - 1) / bulletCount) * (math.pi * 2)
            local jitter = (math.random() - 0.5) * 0.22
            local verticalBias = (math.random() - 0.5) * 0.18
            local direction = Vector3.new(math.cos(angle + jitter), verticalBias, math.sin(angle + jitter)).Unit
            local bullet = emitBulletPart(
                folder,
                towerId,
                origin,
                direction,
                bulletDistance * (0.9 + (math.random() * 0.45)),
                bulletWidth,
                pulseColor,
                pulseLifetime
            )
            self._activePulseCount += 1
            bullet.Destroying:Once(function()
                self._activePulseCount = math.max(0, self._activePulseCount - 1)
            end)
        end
    else
        local lookVector = root.CFrame.LookVector
        local bullet = emitBulletPart(
            folder,
            towerId,
            origin,
            lookVector,
            bulletDistance * 1.35,
            bulletWidth * 1.1,
            pulseColor,
            pulseLifetime
        )
        self._activePulseCount += 1
        bullet.Destroying:Once(function()
            self._activePulseCount = math.max(0, self._activePulseCount - 1)
        end)
    end
end

function TowerVisualController:_trackTowerByModel(towerModel: Model)
    local towerId = tostring(towerModel:GetAttribute('TowerId') or '')
    if towerId == '' then
        return
    end
    local towerType = tostring(towerModel:GetAttribute('TowerType') or 'Basic')
    local tier = math.max(0, math.floor(tonumber(towerModel:GetAttribute('UpgradeTier')) or 0))
    local attackInterval = math.max(0.05, tonumber(towerModel:GetAttribute('AttackInterval')) or 1)
    self._towerStateById[towerId] = {
        model = towerModel,
        towerType = towerType,
        tier = tier,
        attackInterval = attackInterval,
        nextPulseAt = 0,
        hasAttackFxNonce = towerModel:GetAttribute('AttackFxNonce') ~= nil,
        lastAttackFxNonce = math.max(0, math.floor(tonumber(towerModel:GetAttribute('AttackFxNonce')) or 0)),
    }
    self:_applyTierVisuals(towerModel)
end

function TowerVisualController:_untrackTower(towerId: string)
    self._towerStateById[towerId] = nil
    self:_clearTowerTransientVfx(towerId)
end

function TowerVisualController:_syncTowerFromWorkspace(towerId: string)
    local map = self:_getActiveMapFolder()
    local towersFolder = map and map:FindFirstChild('Towers')
    if not towersFolder then
        self:_untrackTower(towerId)
        return
    end
    for _, child in ipairs(towersFolder:GetChildren()) do
        if child:IsA('Model') and tostring(child:GetAttribute('TowerId') or '') == towerId then
            self:_trackTowerByModel(child)
            return
        end
    end
    self:_untrackTower(towerId)
end

function TowerVisualController:_scanExistingTowers()
    local map = self:_getActiveMapFolder()
    local towersFolder = map and map:FindFirstChild('Towers')
    if not towersFolder then
        return
    end
    for _, child in ipairs(towersFolder:GetChildren()) do
        if child:IsA('Model') then
            self:_trackTowerByModel(child)
        end
    end
end

function TowerVisualController:_tick(nowTime: number)
    if self._phase ~= 'Wave' then
        return
    end
    for towerId, state in pairs(self._towerStateById) do
        local towerModel = state.model
        if not towerModel or not towerModel.Parent then
            self:_syncTowerFromWorkspace(towerId)
        else
            local tier = math.max(0, math.floor(tonumber(towerModel:GetAttribute('UpgradeTier')) or state.tier or 0))
            state.tier = tier
            local attackInterval =
                math.max(0.05, tonumber(towerModel:GetAttribute('AttackInterval')) or state.attackInterval or 1)
            state.attackInterval = attackInterval
            if not state.hasAttackFxNonce and towerModel:GetAttribute('AttackFxNonce') ~= nil then
                state.hasAttackFxNonce = true
                state.lastAttackFxNonce = math.max(0, math.floor(tonumber(towerModel:GetAttribute('AttackFxNonce')) or 0))
            end
            if state.hasAttackFxNonce then
                local currentAttackFxNonce = math.max(
                    0,
                    math.floor(tonumber(towerModel:GetAttribute('AttackFxNonce')) or state.lastAttackFxNonce or 0)
                )
                if currentAttackFxNonce > (state.lastAttackFxNonce or 0) then
                    local burstsToEmit = math.min(3, currentAttackFxNonce - (state.lastAttackFxNonce or 0))
                    for _ = 1, burstsToEmit do
                        self:_emitAttackPulse(towerId, towerModel, state.towerType, state.tier)
                    end
                    state.lastAttackFxNonce = currentAttackFxNonce
                    state.nextPulseAt = nowTime + math.max(0.04, attackInterval * 0.15)
                end
            elseif nowTime >= (state.nextPulseAt or 0) then
                -- Fallback for towers created before AttackFxNonce existed.
                local vfxStyle = self:_getAttackVfxStyle(state.towerType)
                local pulseRateFloor = math.max(0.05, tonumber(vfxStyle.pulseRateFloor) or 0.2)
                local pulseInterval = math.max(pulseRateFloor, attackInterval)
                self:_emitAttackPulse(towerId, towerModel, state.towerType, state.tier)
                state.nextPulseAt = nowTime + pulseInterval
            end
        end
    end
end

function TowerVisualController:start()
    if self._running then
        return
    end
    self._running = true
    self._pulseBudgetTier = self:_resolveVfxBudgetTier()
    self._pulseWindowSecond = math.floor(os.clock())
    self._pulseWindowCount = 0

    local towerPlacedRemote = getRemoteEvent(self._net.ServerToClient.TowerPlaced, 5)
    if towerPlacedRemote then
        table.insert(
            self._connections,
            towerPlacedRemote.OnClientEvent:Connect(function(payload)
                local towerId = tostring(payload and payload.towerId or '')
                if towerId ~= '' then
                    self:_syncTowerFromWorkspace(towerId)
                end
            end)
        )
    end

    local towerUpdatedRemote = getRemoteEvent(self._net.ServerToClient.TowerUpdated, 5)
    if towerUpdatedRemote then
        table.insert(
            self._connections,
            towerUpdatedRemote.OnClientEvent:Connect(function(payload)
                local towerId = tostring(payload and payload.towerId or '')
                if towerId ~= '' then
                    self:_syncTowerFromWorkspace(towerId)
                end
            end)
        )
    end

    local towerRemovedRemote = getRemoteEvent(self._net.ServerToClient.TowerRemoved, 5)
    if towerRemovedRemote then
        table.insert(
            self._connections,
            towerRemovedRemote.OnClientEvent:Connect(function(payload)
                local towerId = tostring(payload and payload.towerId or '')
                if towerId ~= '' then
                    self:_untrackTower(towerId)
                end
            end)
        )
    end

    local roundStatusRemote = getRemoteEvent(self._net.ServerToClient.RoundStatus, 5)
    if roundStatusRemote then
        table.insert(
            self._connections,
            roundStatusRemote.OnClientEvent:Connect(function(payload)
                local phase = tostring(payload and payload.phase or self._phase)
                local activeMapName = tostring(payload and payload.activeMapName or self._activeMapName)
                if activeMapName ~= '' and activeMapName ~= self._activeMapName then
                    self._activeMapName = activeMapName
                    table.clear(self._towerStateById)
                    self:_scanExistingTowers()
                end
                if phase ~= self._phase then
                    self._phase = phase
                    if phase ~= 'Wave' then
                        self:_clearAllTransientVfx()
                        if phase == 'Cleanup' or phase == 'Lobby' then
                            table.clear(self._towerStateById)
                        end
                    end
                    for _, state in pairs(self._towerStateById) do
                        if state and state.model and state.model.Parent then
                            self:_applyTierVisuals(state.model)
                        end
                    end
                end
            end)
        )
    end

    self:_scanExistingTowers()
    table.insert(
        self._connections,
        RunService.Heartbeat:Connect(function()
            self:_tick(os.clock())
        end)
    )
end

function TowerVisualController:stop()
    if not self._running then
        return
    end
    self._running = false
    for _, connection in ipairs(self._connections) do
        connection:Disconnect()
    end
    table.clear(self._connections)
    table.clear(self._towerStateById)
    self:_clearAllTransientVfx()
    if self._vfxFolder then
        self._vfxFolder:Destroy()
        self._vfxFolder = nil
    end
    self._pulseBudgetTier = 'Medium'
    self._pulseWindowSecond = 0
    self._pulseWindowCount = 0
end

return TowerVisualController
