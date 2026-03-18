local ServerStorage = game:GetService('ServerStorage')
local Workspace = game:GetService('Workspace')

local EnemyService = {}
EnemyService.__index = EnemyService

local MOVE_TICK_SECONDS = 0.05
local WAYPOINT_REACH_DISTANCE = 3

local function trim(text: string): string
    return (string.gsub(string.gsub(text, '^%s+', ''), '%s+$', ''))
end

local function getWaypointOrder(name: string): number?
    local normalized = string.upper(trim(name))
    local directNumber = tonumber(normalized)
    if directNumber then
        return directNumber
    end

    local wpNumber = string.match(normalized, '^WP(%d+)$')
    if wpNumber then
        return tonumber(wpNumber)
    end

    return nil
end

local function sortByNameDeterministic(instances: { Instance })
    table.sort(instances, function(a, b)
        local numA = getWaypointOrder(a.Name) or tonumber(a.Name)
        local numB = getWaypointOrder(b.Name) or tonumber(b.Name)
        if numA and numB then
            return numA < numB
        end

        return a.Name < b.Name
    end)
end

local function getPreferredTemplateSetForMap(mapName: string, templates: { Model }): { Model }
    local normalizedMap = string.lower(mapName or '')
    local mapSet = {}
    local pattern = ('^%senemy%%d+$'):format(normalizedMap)

    for _, template in ipairs(templates) do
        local templateName = string.lower(template.Name)
        if string.match(templateName, pattern) then
            table.insert(mapSet, template)
        end
    end

    return mapSet
end

local function resolveTemplateSpawnHeightOffset(config, templateName: string): number
    local overrides = if type(config.ENEMY_SPAWN_HEIGHT_OFFSET_BY_TEMPLATE) == 'table'
        then config.ENEMY_SPAWN_HEIGHT_OFFSET_BY_TEMPLATE
        else nil

    if overrides then
        local exactOverride = tonumber(overrides[templateName])
        if exactOverride ~= nil then
            return exactOverride
        end
        local lowercaseOverride = tonumber(overrides[string.lower(templateName)])
        if lowercaseOverride ~= nil then
            return lowercaseOverride
        end
    end

    return tonumber(config.ENEMY_SPAWN_HEIGHT_OFFSET_STUDS) or 0
end

local function resolveTemplateFacingRotationOffsetDeg(config, templateName: string): Vector3
    local overrides = if type(config.ENEMY_FACING_ROTATION_OFFSET_DEG_BY_TEMPLATE) == 'table'
        then config.ENEMY_FACING_ROTATION_OFFSET_DEG_BY_TEMPLATE
        else nil
    local globalYawOffset = tonumber(config.ENEMY_FACING_GLOBAL_YAW_OFFSET_DEG) or 0

    local function parseRotationOffset(raw): Vector3?
        if type(raw) == 'number' then
            return Vector3.new(0, raw, 0)
        end
        if type(raw) ~= 'table' then
            return nil
        end

        local x = tonumber(raw.x or raw.X or raw[1]) or 0
        local y = tonumber(raw.y or raw.Y or raw[2]) or 0
        local z = tonumber(raw.z or raw.Z or raw[3]) or 0
        return Vector3.new(x, y, z)
    end

    if overrides then
        local exactOverride = parseRotationOffset(overrides[templateName])
        if exactOverride ~= nil then
            return Vector3.new(exactOverride.X, exactOverride.Y + globalYawOffset, exactOverride.Z)
        end
        local lowercaseOverride = parseRotationOffset(overrides[string.lower(templateName)])
        if lowercaseOverride ~= nil then
            return Vector3.new(lowercaseOverride.X, lowercaseOverride.Y + globalYawOffset, lowercaseOverride.Z)
        end
    end

    -- Backward compatibility: keep supporting yaw-only overrides.
    local legacyYawOverrides = if type(config.ENEMY_FACING_YAW_OFFSET_DEG_BY_TEMPLATE) == 'table'
        then config.ENEMY_FACING_YAW_OFFSET_DEG_BY_TEMPLATE
        else nil
    if legacyYawOverrides then
        local exactLegacyYaw = tonumber(legacyYawOverrides[templateName])
        if exactLegacyYaw ~= nil then
            return Vector3.new(0, exactLegacyYaw + globalYawOffset, 0)
        end
        local lowercaseLegacyYaw = tonumber(legacyYawOverrides[string.lower(templateName)])
        if lowercaseLegacyYaw ~= nil then
            return Vector3.new(0, lowercaseLegacyYaw + globalYawOffset, 0)
        end
    end

    return Vector3.new(0, globalYawOffset, 0)
end

local function toRotationOffsetCFrame(rotationOffsetDeg: Vector3): CFrame
    return CFrame.fromOrientation(
        math.rad(rotationOffsetDeg.X),
        math.rad(rotationOffsetDeg.Y),
        math.rad(rotationOffsetDeg.Z)
    )
end

local function moveModelRootTo(
    model: Model,
    targetPosition: Vector3,
    lookDirection: Vector3,
    rootFromPivot: CFrame,
    facingRotationOffset: CFrame
)
    if lookDirection.Magnitude <= 0 then
        lookDirection = Vector3.new(0, 0, -1)
    end
    local desiredRootCFrame = CFrame.new(targetPosition, targetPosition + lookDirection) * facingRotationOffset
    local desiredPivot = desiredRootCFrame * rootFromPivot:Inverse()
    model:PivotTo(desiredPivot)
end

local function collectWaypointParts(waypointsFolder: Instance): { BasePart }
    local waypointParts = {}

    -- Always include descendants so nested waypoint groups are supported.
    for _, descendant in ipairs(waypointsFolder:GetDescendants()) do
        if descendant:IsA('BasePart') and getWaypointOrder(descendant.Name) ~= nil then
            table.insert(waypointParts, descendant)
        end
    end

    sortByNameDeterministic(waypointParts)
    return waypointParts
end

local function isWaypointName(name: string): boolean
    return getWaypointOrder(name) ~= nil
end

local collectWaypointPartsFromMapFallback: (map: Instance) -> { BasePart }

local function findChildCaseInsensitive(root: Instance, childName: string): Instance?
    local direct = root:FindFirstChild(childName)
    if direct then
        return direct
    end

    local target = string.lower(childName)
    for _, child in ipairs(root:GetChildren()) do
        if string.lower(child.Name) == target then
            return child
        end
    end

    return nil
end

local function getTrailingDigits(name: string): string?
    return string.match(string.upper(trim(name)), '(%d+)$')
end

local function resolveWaypointRouteNode(waypointsFolder: Instance, spawnName: string): (Instance?, string?)
    local candidateNames = {}
    local seen = {}

    local function addCandidate(name: string?)
        if type(name) ~= 'string' or name == '' then
            return
        end
        local key = string.lower(name)
        if seen[key] then
            return
        end
        seen[key] = true
        table.insert(candidateNames, name)
    end

    addCandidate(spawnName)
    addCandidate(trim(spawnName))
    local laneSuffix = getTrailingDigits(spawnName)
    if laneSuffix then
        local laneNumber = tonumber(laneSuffix)
        local numericSuffix = if laneNumber ~= nil then tostring(laneNumber) else nil

        addCandidate(('Spawn%s'):format(laneSuffix))
        addCandidate(('WP%s'):format(laneSuffix))
        addCandidate(('Path%s'):format(laneSuffix))
        addCandidate(('Route%s'):format(laneSuffix))
        addCandidate(('Lane%s'):format(laneSuffix))
        if numericSuffix then
            addCandidate(('Spawn%s'):format(numericSuffix))
            addCandidate(('WP%s'):format(numericSuffix))
            addCandidate(('Path%s'):format(numericSuffix))
            addCandidate(('Route%s'):format(numericSuffix))
            addCandidate(('Lane%s'):format(numericSuffix))
        end
    end

    for _, candidateName in ipairs(candidateNames) do
        local routeNode = findChildCaseInsensitive(waypointsFolder, candidateName)
        if routeNode and (routeNode:IsA('Folder') or routeNode:IsA('Model') or routeNode:IsA('BasePart')) then
            return routeNode, routeNode.Name
        end
    end

    return nil, nil
end

local function collectWaypointsFromRouteNode(routeNode: Instance): { BasePart }
    if routeNode:IsA('BasePart') and getWaypointOrder(routeNode.Name) ~= nil then
        return { routeNode }
    end

    if routeNode:IsA('Folder') or routeNode:IsA('Model') then
        return collectWaypointParts(routeNode)
    end

    return {}
end

local function hasBranchedWaypointRoutes(waypointsFolder: Instance): boolean
    for _, child in ipairs(waypointsFolder:GetChildren()) do
        if child:IsA('Folder') or child:IsA('Model') then
            if #collectWaypointParts(child) > 0 then
                return true
            end
        end
    end
    return false
end

local function formatBranchedRouteNames(waypointsFolder: Instance): string
    local names = {}
    for _, child in ipairs(waypointsFolder:GetChildren()) do
        if child:IsA('Folder') or child:IsA('Model') then
            table.insert(names, child.Name)
        end
    end
    table.sort(names, function(a, b)
        local numA = getWaypointOrder(a) or tonumber(a)
        local numB = getWaypointOrder(b) or tonumber(b)
        if numA and numB then
            return numA < numB
        end
        return a < b
    end)
    if #names == 0 then
        return '(none)'
    end
    return table.concat(names, ', ')
end

local function collectSpawnRouteWaypoints(
    map: Instance,
    waypointsFolder: Instance,
    spawnName: string,
    preferredRouteName: string?
): ({ BasePart }, string)
    local routeNode = nil
    local routeLabel = 'GlobalWaypoints'

    if type(preferredRouteName) == 'string' and preferredRouteName ~= '' then
        local preferred = findChildCaseInsensitive(waypointsFolder, preferredRouteName)
        if preferred and (preferred:IsA('Folder') or preferred:IsA('Model') or preferred:IsA('BasePart')) then
            routeNode = preferred
            routeLabel = preferred.Name
        end
    end

    if not routeNode then
        local resolvedNode, resolvedName = resolveWaypointRouteNode(waypointsFolder, spawnName)
        if resolvedNode then
            routeNode = resolvedNode
            routeLabel = resolvedName or resolvedNode.Name
        end
    end

    if routeNode then
        local routeWaypoints = collectWaypointsFromRouteNode(routeNode)
        if #routeWaypoints > 0 then
            return routeWaypoints, routeLabel
        end
    end

    if hasBranchedWaypointRoutes(waypointsFolder) then
        return {}, 'MissingRouteForSpawn'
    end

    local waypoints = collectWaypointParts(waypointsFolder)
    if #waypoints == 0 then
        waypoints = collectWaypointPartsFromMapFallback(map)
    end
    return waypoints, routeLabel
end

collectWaypointPartsFromMapFallback = function(map: Instance): { BasePart }
    local waypointParts = {}
    for _, descendant in ipairs(map:GetDescendants()) do
        if descendant:IsA('BasePart') and isWaypointName(descendant.Name) then
            table.insert(waypointParts, descendant)
        end
    end
    sortByNameDeterministic(waypointParts)
    return waypointParts
end

local function findThroughSameNameWrappers(root: Instance, childName: string): Instance?
    local visited = {}
    local cursor: Instance? = root
    while cursor and not visited[cursor] do
        visited[cursor] = true

        local wrapped = cursor:FindFirstChild(cursor.Name)
        if not wrapped and cursor:IsA('Model') then
            for _, child in ipairs(cursor:GetChildren()) do
                if child:IsA('Model') and string.lower(child.Name) == string.lower(cursor.Name) then
                    wrapped = child
                    break
                end
            end
        end
        if not wrapped then
            break
        end

        local nested = wrapped:FindFirstChild(childName)
        if nested then
            return nested
        end
        cursor = wrapped
    end

    -- Fallback to direct child only if no nested-wrapper match exists.
    return root:FindFirstChild(childName)
end

local function getModelRoot(model: Model): BasePart?
    if model.PrimaryPart then
        return model.PrimaryPart
    end

    local firstPart = model:FindFirstChildWhichIsA('BasePart', true)
    if firstPart then
        model.PrimaryPart = firstPart
    end

    return model.PrimaryPart
end

local function prepareEnemyForPathing(model: Model): number
    local preparedCount = 0
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA('BasePart') then
            -- Movement is fully server-driven via PivotTo, so disable physics drift/falling.
            descendant.Anchored = true
            descendant.CanCollide = false
            descendant.AssemblyLinearVelocity = Vector3.zero
            descendant.AssemblyAngularVelocity = Vector3.zero
            preparedCount += 1
        end
    end
    return preparedCount
end

local function resolveMaterialFromName(materialName: string?): Enum.Material
    if type(materialName) == 'string' and Enum.Material[materialName] ~= nil then
        return Enum.Material[materialName]
    end
    return Enum.Material.SmoothPlastic
end

local function applyEnemyVisualContrast(model: Model, gameConfig, variant: string, isElite: boolean)
    local contrastConfig = type(gameConfig.ENEMY_VISUAL_CONTRAST) == 'table' and gameConfig.ENEMY_VISUAL_CONTRAST or nil
    if not contrastConfig then
        return
    end
    local defaultStyle = type(contrastConfig.default) == 'table' and contrastConfig.default or {}
    local variantStyles = type(contrastConfig.variants) == 'table' and contrastConfig.variants or nil
    local variantStyle = type(variantStyles) == 'table'
            and type(variantStyles[variant]) == 'table'
            and variantStyles[variant]
        or {}

    local bodyColor = variantStyle.bodyColor or defaultStyle.bodyColor or Color3.fromRGB(212, 78, 78)
    local accentColor = variantStyle.accentColor or defaultStyle.accentColor or Color3.fromRGB(255, 194, 120)
    local resolvedMaterial = resolveMaterialFromName(defaultStyle.material)

    local partIndex = 0
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA('BasePart') then
            partIndex += 1
            descendant.Material = resolvedMaterial
            descendant.Color = if partIndex % 3 == 0 then accentColor else bodyColor
            descendant.Reflectance = 0
        end
    end

    local highlight = model:FindFirstChild('EnemyContrastHighlight')
    if highlight and highlight:IsA('Highlight') then
        highlight:Destroy()
    end
end

local function formatWaypointDebugList(waypoints: { BasePart }): string
    local names = {}
    for _, waypoint in ipairs(waypoints) do
        table.insert(names, waypoint.Name)
    end
    return table.concat(names, ' -> ')
end

local function normalizeAnimationId(value): string?
    if value == nil then
        return nil
    end

    local raw = trim(tostring(value))
    if raw == '' then
        return nil
    end

    if string.match(raw, '^rbxassetid://%d+$') then
        return raw
    end

    local directNumeric = tonumber(raw)
    if directNumeric ~= nil then
        return ('rbxassetid://%d'):format(math.floor(directNumeric))
    end

    local numericFromUrl = string.match(raw, '/(%d+)')
    if numericFromUrl then
        return ('rbxassetid://%s'):format(numericFromUrl)
    end

    return nil
end

local function resolveTemplateWalkAnimationId(config, model: Model, templateName: string): string?
    local fromModelWalkAttr = normalizeAnimationId(model:GetAttribute('WalkAnimationId'))
    if fromModelWalkAttr then
        return fromModelWalkAttr
    end

    local fromModelGenericAttr = normalizeAnimationId(model:GetAttribute('AnimationId'))
    if fromModelGenericAttr then
        return fromModelGenericAttr
    end

    -- Allow templates to carry their own Animation instance IDs.
    local embeddedAnimation = model:FindFirstChild('WalkAnimation', true)
        or model:FindFirstChild('Walk', true)
        or model:FindFirstChild('Animation', true)
    if embeddedAnimation and embeddedAnimation:IsA('Animation') then
        local fromEmbeddedAnimation = normalizeAnimationId(embeddedAnimation.AnimationId)
        if fromEmbeddedAnimation then
            return fromEmbeddedAnimation
        end
    end

    local byTemplate = if type(config.ENEMY_WALK_ANIMATION_ID_BY_TEMPLATE) == 'table'
        then config.ENEMY_WALK_ANIMATION_ID_BY_TEMPLATE
        else nil
    if byTemplate then
        local exactTemplateAnimationId = normalizeAnimationId(byTemplate[templateName])
        if exactTemplateAnimationId then
            return exactTemplateAnimationId
        end

        local lowercaseTemplateAnimationId = normalizeAnimationId(byTemplate[string.lower(templateName)])
        if lowercaseTemplateAnimationId then
            return lowercaseTemplateAnimationId
        end
    end

    return normalizeAnimationId(config.ENEMY_WALK_ANIMATION_ID)
end

local function startEnemyWalkAnimation(config, model: Model, templateName: string): AnimationTrack?
    local walkAnimationId = resolveTemplateWalkAnimationId(config, model, templateName)
    if not walkAnimationId then
        return nil
    end

    local animator = nil
    local animationController = model:FindFirstChildOfClass('AnimationController')
    if animationController then
        animator = animationController:FindFirstChildOfClass('Animator')
        if not animator then
            animator = Instance.new('Animator')
            animator.Parent = animationController
        end
    end

    if not animator then
        local humanoid = model:FindFirstChildOfClass('Humanoid')
        if humanoid then
            animator = humanoid:FindFirstChildOfClass('Animator')
            if not animator then
                animator = Instance.new('Animator')
                animator.Parent = humanoid
            end
        end
    end

    if not animator then
        return nil
    end

    local animation = Instance.new('Animation')
    animation.AnimationId = walkAnimationId
    local ok, loadedTrack = pcall(function()
        return animator:LoadAnimation(animation)
    end)
    if not ok then
        warn(
            ('[EnemyService] Failed to load walk animation for template "%s" (%s): %s'):format(
                tostring(templateName),
                tostring(walkAnimationId),
                tostring(loadedTrack)
            )
        )
        return nil
    end

    loadedTrack.Priority = Enum.AnimationPriority.Movement
    loadedTrack.Looped = true
    loadedTrack:Play(0.1, 1, 1)
    return loadedTrack
end

function EnemyService.new(gameConfig)
    return setmetatable({
        _config = gameConfig,
        _activeMapName = tostring(gameConfig.ACTIVE_MAP_NAME or gameConfig.DEFAULT_STAGE_ID or 'brown'),
        _running = false,
        _runId = 0,
        _roundNumber = 1,
        _roundModifier = nil,
        _spawnedThisRun = 0,
        _nextEnemyId = 1,
        _activeEnemies = {},
        _rng = Random.new(),
        _onEnemyLeaked = nil,
        _onEnemyDied = nil,
        _debugPathing = gameConfig.DEBUG_WAYPOINT_PATHING == true,
    }, EnemyService)
end

function EnemyService:setActiveMapName(mapName: string)
    if type(mapName) == 'string' and mapName ~= '' then
        self._activeMapName = mapName
    end
end

function EnemyService:_getActiveMapFolder(): Instance?
    return Workspace:FindFirstChild(self._activeMapName)
end

local function setModelHealthAttributes(model: Model, maxHealth: number, health: number)
    model:SetAttribute('MaxHealth', maxHealth)
    model:SetAttribute('Health', health)

    local healthValue = model:FindFirstChild('Health')
    if not healthValue then
        healthValue = Instance.new('NumberValue')
        healthValue.Name = 'Health'
        healthValue.Parent = model
    end
    if healthValue:IsA('NumberValue') then
        healthValue.Value = health
    end

    local maxHealthValue = model:FindFirstChild('MaxHealth')
    if not maxHealthValue then
        maxHealthValue = Instance.new('NumberValue')
        maxHealthValue.Name = 'MaxHealth'
        maxHealthValue.Parent = model
    end
    if maxHealthValue:IsA('NumberValue') then
        maxHealthValue.Value = maxHealth
    end
end

local function updateModelHealth(model: Model, health: number)
    model:SetAttribute('Health', health)
    local healthValue = model:FindFirstChild('Health')
    if healthValue and healthValue:IsA('NumberValue') then
        healthValue.Value = health
    end
end

function EnemyService:_computeSpawnEnemyMaxHealth(spawnOrdinal: number): number
    local baseHealth = tonumber(self._config.ENEMY_BASE_HEALTH) or 100
    local perSpawnHealth = tonumber(self._config.ENEMY_HEALTH_PER_SPAWN) or 0
    local perRoundHealth = tonumber(self._config.ENEMY_HEALTH_PER_ROUND) or 0
    local effectiveRoundNumber = math.max(1, math.floor(tonumber(self._roundNumber) or 1))
    local scaledHealth = baseHealth
        + (math.max(1, spawnOrdinal) - 1) * perSpawnHealth
        + (effectiveRoundNumber - 1) * perRoundHealth
    local roundModifier = self._roundModifier
    if type(roundModifier) == 'table' then
        local modifierMultiplier = tonumber(roundModifier.enemyHealthMultiplier) or 1
        if modifierMultiplier < 0.1 then
            modifierMultiplier = 0.1
        end
        scaledHealth *= modifierMultiplier
    end
    return math.max(1, math.floor(scaledHealth))
end

function EnemyService:_computeEnemyMoveSpeed(speedMultiplier: number?): number
    local baseMoveSpeed = tonumber(self._config.ENEMY_MOVE_SPEED) or 12
    local perRoundMoveSpeed = tonumber(self._config.ENEMY_MOVE_SPEED_PER_ROUND) or 0
    local effectiveRoundNumber = math.max(1, math.floor(tonumber(self._roundNumber) or 1))
    local scaledMoveSpeed = baseMoveSpeed + ((effectiveRoundNumber - 1) * perRoundMoveSpeed)
    local roundModifier = self._roundModifier
    if type(roundModifier) == 'table' then
        local modifierMultiplier = tonumber(roundModifier.enemyMoveSpeedMultiplier) or 1
        if modifierMultiplier < 0.1 then
            modifierMultiplier = 0.1
        end
        scaledMoveSpeed *= modifierMultiplier
    end
    local appliedMultiplier = tonumber(speedMultiplier) or 1
    if appliedMultiplier < 0.1 then
        appliedMultiplier = 0.1
    end
    scaledMoveSpeed *= appliedMultiplier
    if scaledMoveSpeed < 1 then
        scaledMoveSpeed = 1
    end
    return scaledMoveSpeed
end

function EnemyService:_getVariantConfig(variantName: string)
    local variants = self._config.ENEMY_VARIANTS
    if type(variants) ~= 'table' then
        return nil
    end
    local config = variants[variantName]
    if type(config) ~= 'table' then
        return nil
    end
    return config
end

function EnemyService:_isVariantUnlocked(variantName: string): boolean
    local config = self:_getVariantConfig(variantName)
    if not config then
        return false
    end
    local unlockRound = tonumber(config.unlockRound) or 1
    unlockRound = math.max(1, math.floor(unlockRound))
    return self._roundNumber >= unlockRound
end

function EnemyService:_getEliteConfig()
    local config = self._config.ENEMY_ELITE
    if type(config) ~= 'table' then
        return nil
    end
    return config
end

function EnemyService:_isEliteSpawn(spawnOrdinal: number): boolean
    local eliteConfig = self:_getEliteConfig()
    if not eliteConfig then
        return false
    end
    if eliteConfig.enabled == false then
        return false
    end

    local unlockRound = tonumber(eliteConfig.unlockRound) or math.huge
    unlockRound = math.max(1, math.floor(unlockRound))
    if self._roundNumber < unlockRound then
        return false
    end

    local everySpawnOrdinal = tonumber(eliteConfig.everySpawnOrdinal) or 0
    everySpawnOrdinal = math.max(0, math.floor(everySpawnOrdinal))
    if everySpawnOrdinal <= 0 then
        return false
    end

    return (math.max(1, math.floor(spawnOrdinal)) % everySpawnOrdinal) == 0
end

function EnemyService:_getEliteMultipliers(spawnOrdinal: number)
    local eliteConfig = self:_getEliteConfig()
    if not eliteConfig then
        return false, 1, 1, 1, nil
    end
    if not self:_isEliteSpawn(spawnOrdinal) then
        return false, 1, 1, 1, nil
    end

    local healthMultiplier = tonumber(eliteConfig.healthMultiplier) or 1
    local speedMultiplier = tonumber(eliteConfig.speedMultiplier) or 1
    local rewardMultiplier = tonumber(eliteConfig.rewardMultiplier) or 1
    if healthMultiplier < 0.1 then
        healthMultiplier = 0.1
    end
    if speedMultiplier < 0.1 then
        speedMultiplier = 0.1
    end
    if rewardMultiplier < 0.1 then
        rewardMultiplier = 0.1
    end

    local tag = eliteConfig.tag
    if type(tag) ~= 'string' or tag == '' then
        tag = 'Elite'
    end
    return true, healthMultiplier, speedMultiplier, rewardMultiplier, tag
end

function EnemyService:_selectEnemyVariant(spawnOrdinal: number): string
    local defaultVariant = 'Normal'
    if not self:_isVariantUnlocked(defaultVariant) then
        local variants = self._config.ENEMY_VARIANTS
        if type(variants) == 'table' then
            for variantName, config in pairs(variants) do
                if type(variantName) == 'string' and type(config) == 'table' then
                    local unlockRound = tonumber(config.unlockRound) or 1
                    if self._roundNumber >= math.max(1, math.floor(unlockRound)) then
                        defaultVariant = variantName
                        break
                    end
                end
            end
        end
    end

    local target = math.max(1, self._spawnedThisRun)
    if spawnOrdinal > 0 then
        target = math.max(target, spawnOrdinal)
    end
    local progress = (math.max(1, spawnOrdinal) - 1) / math.max(1, target - 1)

    local selectedVariant = defaultVariant
    local bestBandProgress = -1
    local bands = self._config.ENEMY_VARIANT_PROGRESS_BANDS
    if type(bands) == 'table' then
        for _, band in ipairs(bands) do
            if type(band) == 'table' then
                local minProgress = tonumber(band.minProgress)
                local variantName = band.variant
                if minProgress and type(variantName) == 'string' and minProgress <= progress then
                    if minProgress >= bestBandProgress and self:_isVariantUnlocked(variantName) then
                        bestBandProgress = minProgress
                        selectedVariant = variantName
                    end
                end
            end
        end
    end

    if not self:_isVariantUnlocked(selectedVariant) then
        return defaultVariant
    end
    return selectedVariant
end

function EnemyService:_getEnemyRecord(enemyId: number)
    return self._activeEnemies[enemyId]
end

function EnemyService:_debugPathingLog(message: string)
    if not self._debugPathing then
        return
    end

    print(('[EnemyService][Pathing] %s'):format(message))
end

function EnemyService:setEnemyLeakedHandler(callback)
    self._onEnemyLeaked = callback
end

function EnemyService:setEnemyDiedHandler(callback)
    self._onEnemyDied = callback
end

function EnemyService:start()
    self._running = true
    self._runId += 1
    self._roundNumber = math.max(1, math.floor(tonumber(self._roundNumber) or 1))
    self._roundModifier = nil
    self._spawnedThisRun = 0
end

function EnemyService:stop()
    self._running = false
    self._runId += 1
    self._roundNumber = 1
    self._roundModifier = nil
    self._spawnedThisRun = 0
    self._onEnemyLeaked = nil
    self._onEnemyDied = nil

    for enemyId, record in pairs(self._activeEnemies) do
        if record.model and record.model.Parent then
            record.model:Destroy()
        end
        self._activeEnemies[enemyId] = nil
    end
end

function EnemyService:setRoundNumber(roundNumber: number)
    local parsed = tonumber(roundNumber) or 1
    self._roundNumber = math.max(1, math.floor(parsed))
end

function EnemyService:setRoundModifier(roundModifier)
    if type(roundModifier) ~= 'table' then
        self._roundModifier = nil
        return
    end
    self._roundModifier = roundModifier
end

function EnemyService:getActiveEnemyCount(): number
    local count = 0
    for _ in pairs(self._activeEnemies) do
        count += 1
    end
    return count
end

function EnemyService:getTargetableEnemies()
    local result = {}
    for enemyId, record in pairs(self._activeEnemies) do
        if record and not record.leakApplied and not record.deathApplied then
            local model = record.model
            if model and model.Parent then
                local root = getModelRoot(model)
                if root and root.Parent then
                    table.insert(result, {
                        enemyId = enemyId,
                        position = root.Position,
                        health = tonumber(record.health) or 0,
                        maxHealth = tonumber(record.maxHealth) or 0,
                        spawnOrdinal = tonumber(record.spawnOrdinal) or 0,
                        pathProgress = tonumber(record.pathProgress) or 0,
                    })
                end
            end
        end
    end
    return result
end

function EnemyService:getEnemySnapshot(enemyId: number)
    if type(enemyId) ~= 'number' then
        return nil
    end

    local record = self:_getEnemyRecord(enemyId)
    if not record then
        return nil
    end

    return {
        enemyId = enemyId,
        spawnOrdinal = tonumber(record.spawnOrdinal) or 0,
        pathProgress = tonumber(record.pathProgress) or 0,
        variant = record.variant,
        isElite = record.isElite == true,
        eliteTag = record.eliteTag,
        rewardMultiplier = tonumber(record.rewardMultiplier) or 1,
        maxHealth = tonumber(record.maxHealth) or 0,
        moveSpeed = tonumber(record.moveSpeed) or 0,
    }
end

function EnemyService:_resolveEnemy(enemyId: number)
    local record = self._activeEnemies[enemyId]
    if not record then
        return
    end

    local animationTrack = record.animationTrack
    if typeof(animationTrack) == 'Instance' and animationTrack:IsA('AnimationTrack') then
        pcall(function()
            animationTrack:Stop(0)
        end)
    end

    if record.model and record.model.Parent then
        record.model:Destroy()
    end

    self._activeEnemies[enemyId] = nil
end

function EnemyService:_moveEnemyAlongWaypoints(enemyId: number, model: Model, runId: number)
    local record = self._activeEnemies[enemyId]
    local map = self:_getActiveMapFolder()
    if not map then
        self:_debugPathingLog(('enemyId=%d resolveReason=MISSING_MAP'):format(enemyId))
        self:_resolveEnemy(enemyId)
        return
    end

    local waypointsFolder = findThroughSameNameWrappers(map, 'Waypoints')
    if not waypointsFolder then
        self:_debugPathingLog(('enemyId=%d resolveReason=MISSING_WAYPOINTS_FOLDER'):format(enemyId))
        self:_resolveEnemy(enemyId)
        return
    end

    local spawnPointName = tostring(record and record.spawnPointName or '')
    local preferredRouteName = tostring(record and record.waypointRouteName or '')
    local waypoints, routeLabel = collectSpawnRouteWaypoints(map, waypointsFolder, spawnPointName, preferredRouteName)
    self:_debugPathingLog(
        ('enemyId=%d spawn=%s route=%s waypointCount=%d'):format(enemyId, spawnPointName, routeLabel, #waypoints)
    )

    local root = getModelRoot(model)
    if not root then
        self:_debugPathingLog(('enemyId=%d resolveReason=NO_MODEL_ROOT'):format(enemyId))
        self:_resolveEnemy(enemyId)
        return
    end

    record = self._activeEnemies[enemyId]
    local moveSpeed = tonumber(record and record.moveSpeed) or self:_computeEnemyMoveSpeed()
    local pathHeightOffset = tonumber(record and record.pathHeightOffset)
    if pathHeightOffset == nil then
        pathHeightOffset = tonumber(self._config.ENEMY_SPAWN_HEIGHT_OFFSET_STUDS) or 0
    end
    local rootFromPivot = if record and typeof(record.rootFromPivot) == 'CFrame'
        then record.rootFromPivot
        else model:GetPivot():ToObjectSpace(root.CFrame)
    local facingRotationOffset = if record and typeof(record.facingRotationOffset) == 'CFrame'
        then record.facingRotationOffset
        else CFrame.new()
    local shouldRotateTowardPath = self._config.ENEMY_ROTATE_TOWARD_NEXT_WAYPOINT ~= false
    local allowSkinnedMeshRotation = self._config.ENEMY_ROTATE_SKINNED_MESH == true
    if root:IsA('MeshPart') and root.HasSkinnedMesh and not allowSkinnedMeshRotation then
        shouldRotateTowardPath = false
    end
    local resolveReason = 'UNKNOWN'
    local reachedWaypointCount = 0

    for waypointIndex, waypoint in ipairs(waypoints) do
        if not self._running then
            resolveReason = 'SERVICE_STOPPED'
            break
        end
        if self._runId ~= runId then
            resolveReason = 'STALE_RUN'
            break
        end
        if not model.Parent or not root.Parent then
            resolveReason = 'MODEL_REMOVED'
            break
        end
        if not waypoint:IsA('BasePart') then
            resolveReason = 'INVALID_WAYPOINT_INSTANCE'
            break
        end

        local targetPosition = waypoint.Position + Vector3.new(0, pathHeightOffset, 0)
        local segmentStartDistance = (root.Position - targetPosition).Magnitude
        if segmentStartDistance < 0.001 then
            segmentStartDistance = 0.001
        end
        if shouldRotateTowardPath then
            local initialDirection = targetPosition - root.Position
            if initialDirection.Magnitude > 0.001 then
                moveModelRootTo(model, root.Position, initialDirection.Unit, rootFromPivot, facingRotationOffset)
            end
        end
        while
            self._running
            and self._runId == runId
            and model.Parent
            and root.Parent
            and (root.Position - targetPosition).Magnitude > WAYPOINT_REACH_DISTANCE
        do
            local currentPosition = root.Position
            local offset = targetPosition - currentPosition
            local distance = offset.Magnitude
            if distance <= 0 then
                break
            end

            local step = math.min(moveSpeed * MOVE_TICK_SECONDS, distance)
            local nextPosition = currentPosition + (offset.Unit * step)
            local translation = nextPosition - currentPosition
            if translation.Magnitude > 0 then
                model:TranslateBy(translation)
            end
            if shouldRotateTowardPath then
                local lookDirection = offset.Unit
                moveModelRootTo(model, root.Position, lookDirection, rootFromPivot, facingRotationOffset)
            end
            local liveRecord = self._activeEnemies[enemyId]
            if liveRecord and #waypoints > 0 then
                local remainingDistance = (nextPosition - targetPosition).Magnitude
                local segmentCompletion = 1 - (remainingDistance / segmentStartDistance)
                local segmentProgress = math.clamp(segmentCompletion, 0, 1)
                local pathProgress = ((waypointIndex - 1) + segmentProgress) / #waypoints
                liveRecord.pathProgress =
                    math.max(tonumber(liveRecord.pathProgress) or 0, math.clamp(pathProgress, 0, 1))
            end
            task.wait(MOVE_TICK_SECONDS)
        end

        if not self._running then
            resolveReason = 'SERVICE_STOPPED'
            break
        end
        if self._runId ~= runId then
            resolveReason = 'STALE_RUN'
            break
        end
        if not model.Parent or not root.Parent then
            resolveReason = 'MODEL_REMOVED'
            break
        end

        if (root.Position - targetPosition).Magnitude <= WAYPOINT_REACH_DISTANCE then
            local correction = targetPosition - root.Position
            if correction.Magnitude > 0 then
                model:TranslateBy(correction)
            end
            if shouldRotateTowardPath then
                local lookDirection = root.CFrame.LookVector
                if correction.Magnitude > 0 then
                    lookDirection = correction.Unit
                end
                moveModelRootTo(model, root.Position, lookDirection, rootFromPivot, facingRotationOffset)
            end
            reachedWaypointCount = waypointIndex
            local liveRecord = self._activeEnemies[enemyId]
            if liveRecord and #waypoints > 0 then
                local checkpointProgress = waypointIndex / #waypoints
                liveRecord.pathProgress =
                    math.max(tonumber(liveRecord.pathProgress) or 0, math.clamp(checkpointProgress, 0, 1))
            end
            self:_debugPathingLog(
                ('enemyId=%d reachedWaypoint=%d/%d name=%s'):format(enemyId, waypointIndex, #waypoints, waypoint.Name)
            )
        end
    end

    if resolveReason == 'UNKNOWN' then
        if reachedWaypointCount == #waypoints and #waypoints > 0 then
            resolveReason = 'REACHED_LAST_WAYPOINT'
        elseif #waypoints == 0 then
            resolveReason = 'NO_VALID_WAYPOINTS'
        else
            resolveReason = 'INCOMPLETE_PATH'
        end
    end

    record = self._activeEnemies[enemyId]
    self:_debugPathingLog(
        ('enemyId=%d reached=%d/%d resolveReason=%s activeBeforeResolve=%s'):format(
            enemyId,
            reachedWaypointCount,
            #waypoints,
            resolveReason,
            tostring(record ~= nil)
        )
    )

    if
        resolveReason == 'REACHED_LAST_WAYPOINT'
        and self._running
        and self._runId == runId
        and record
        and not record.leakApplied
        and not record.deathApplied
    then
        record.leakApplied = true
        if self._onEnemyLeaked then
            self._onEnemyLeaked(enemyId)
        end
    end

    self:_resolveEnemy(enemyId)
end

function EnemyService:spawnSingleEnemy()
    if not self._running then
        return false, 'SERVICE_NOT_RUNNING'
    end

    local enemyModelsFolder = ServerStorage:FindFirstChild('EnemyModels')
    local map = self:_getActiveMapFolder()
    local enemySpawnsFolder = map and findThroughSameNameWrappers(map, 'EnemySpawns')
    local waypointsFolder = map and findThroughSameNameWrappers(map, 'Waypoints')
    if not enemyModelsFolder or not enemySpawnsFolder then
        return false, 'MISSING_SPAWN_DEPENDENCIES'
    end
    if not waypointsFolder then
        return false, 'MISSING_WAYPOINTS_FOLDER'
    end

    local templates = {}
    for _, child in ipairs(enemyModelsFolder:GetChildren()) do
        if child:IsA('Model') then
            table.insert(templates, child)
        end
    end
    if #templates == 0 then
        return false, 'NO_ENEMY_MODELS'
    end
    sortByNameDeterministic(templates)

    local spawnPoints = enemySpawnsFolder:GetChildren()
    sortByNameDeterministic(spawnPoints)
    local validSpawnPoints = {}
    for _, candidate in ipairs(spawnPoints) do
        if candidate:IsA('BasePart') then
            table.insert(validSpawnPoints, candidate)
        end
    end
    local chosenSpawn: BasePart? = nil
    if #validSpawnPoints > 0 then
        chosenSpawn = validSpawnPoints[self._rng:NextInteger(1, #validSpawnPoints)]
    end
    if not chosenSpawn then
        return false, 'NO_VALID_SPAWN_POINT'
    end

    local waypoints, routeLabel = collectSpawnRouteWaypoints(map, waypointsFolder, chosenSpawn.Name, nil)
    if #waypoints == 0 then
        local childCount = #waypointsFolder:GetChildren()
        local descendantCount = #waypointsFolder:GetDescendants()
        local availableRoutes = formatBranchedRouteNames(waypointsFolder)
        warn(
            ('[EnemyService] NO_VALID_WAYPOINTS debug: spawn=%s route=%s availableRoutes=[%s] folder=%s class=%s children=%d descendants=%d'):format(
                chosenSpawn.Name,
                routeLabel,
                availableRoutes,
                waypointsFolder:GetFullName(),
                waypointsFolder.ClassName,
                childCount,
                descendantCount
            )
        )
        return false, 'NO_VALID_WAYPOINTS_V2'
    end
    self:_debugPathingLog(
        ('spawnCheck spawn=%s route=%s waypointCount=%d orderedPath=%s'):format(
            chosenSpawn.Name,
            routeLabel,
            #waypoints,
            formatWaypointDebugList(waypoints)
        )
    )

    local candidateTemplates = getPreferredTemplateSetForMap(self._activeMapName, templates)
    sortByNameDeterministic(candidateTemplates)
    if #candidateTemplates == 0 then
        warn(
            ('[EnemyService] No enemy templates matched active map "%s". Expected names like "%senemy01".'):format(
                tostring(self._activeMapName),
                string.lower(tostring(self._activeMapName))
            )
        )
        return false, 'NO_MAP_MATCHED_ENEMY_MODELS'
    end
    local selectedTemplate = candidateTemplates[self._rng:NextInteger(1, #candidateTemplates)]

    local enemyModel = selectedTemplate:Clone()
    local root = getModelRoot(enemyModel)
    if not root then
        enemyModel:Destroy()
        return false, 'ENEMY_MODEL_HAS_NO_BASEPART'
    end
    local preparedPartCount = prepareEnemyForPathing(enemyModel)

    enemyModel.Parent = map
    local spawnHeightOffset = resolveTemplateSpawnHeightOffset(self._config, selectedTemplate.Name)
    local facingRotationOffsetDeg = resolveTemplateFacingRotationOffsetDeg(self._config, selectedTemplate.Name)
    local facingRotationOffset = toRotationOffsetCFrame(facingRotationOffsetDeg)
    local spawnCFrame = chosenSpawn.CFrame + Vector3.new(0, spawnHeightOffset, 0)
    enemyModel:PivotTo(spawnCFrame * facingRotationOffset)
    local rootFromPivot = enemyModel:GetPivot():ToObjectSpace(root.CFrame)
    local runtimePathHeightOffset = root.Position.Y - chosenSpawn.Position.Y
    if runtimePathHeightOffset ~= runtimePathHeightOffset then
        runtimePathHeightOffset = spawnHeightOffset
    end
    self:_debugPathingLog(('spawnCheck preparedParts=%d enemyModel=%s'):format(preparedPartCount, enemyModel.Name))
    self._spawnedThisRun += 1
    local spawnOrdinal = self._spawnedThisRun
    local variant = self:_selectEnemyVariant(spawnOrdinal)
    local isElite, eliteHealthMultiplier, eliteSpeedMultiplier, eliteRewardMultiplier, eliteTag =
        self:_getEliteMultipliers(spawnOrdinal)
    local variantConfig = self:_getVariantConfig(variant) or {}
    local healthMultiplier = tonumber(variantConfig.healthMultiplier) or 1
    local speedMultiplier = tonumber(variantConfig.speedMultiplier) or 1
    local rewardMultiplier = tonumber(variantConfig.rewardMultiplier) or 1
    if healthMultiplier < 0.1 then
        healthMultiplier = 0.1
    end
    if speedMultiplier < 0.1 then
        speedMultiplier = 0.1
    end
    if rewardMultiplier < 0.1 then
        rewardMultiplier = 0.1
    end
    healthMultiplier *= eliteHealthMultiplier
    speedMultiplier *= eliteSpeedMultiplier
    rewardMultiplier *= eliteRewardMultiplier

    local baseMaxHealth = self:_computeSpawnEnemyMaxHealth(spawnOrdinal)
    local maxHealth = math.max(1, math.floor(baseMaxHealth * healthMultiplier))
    local health = maxHealth
    local moveSpeed = self:_computeEnemyMoveSpeed(speedMultiplier)
    setModelHealthAttributes(enemyModel, maxHealth, health)
    enemyModel:SetAttribute('EnemyVariant', variant)
    enemyModel:SetAttribute('IsElite', isElite)
    enemyModel:SetAttribute('EliteTag', eliteTag)
    enemyModel:SetAttribute('MoveSpeed', moveSpeed)
    enemyModel:SetAttribute('RewardMultiplier', rewardMultiplier)
    enemyModel:SetAttribute('SpawnPointName', chosenSpawn.Name)
    enemyModel:SetAttribute('WaypointRoute', routeLabel)
    applyEnemyVisualContrast(enemyModel, self._config, variant, isElite)
    local animationTrack = startEnemyWalkAnimation(self._config, enemyModel, selectedTemplate.Name)

    local enemyId = self._nextEnemyId
    self._nextEnemyId += 1

    self._activeEnemies[enemyId] = {
        id = enemyId,
        model = enemyModel,
        leakApplied = false,
        deathApplied = false,
        spawnOrdinal = spawnOrdinal,
        variant = variant,
        isElite = isElite,
        eliteTag = eliteTag,
        rewardMultiplier = rewardMultiplier,
        moveSpeed = moveSpeed,
        maxHealth = maxHealth,
        health = health,
        pathHeightOffset = runtimePathHeightOffset,
        spawnPointName = chosenSpawn.Name,
        waypointRouteName = routeLabel,
        rootFromPivot = rootFromPivot,
        facingRotationOffset = facingRotationOffset,
        pathProgress = 0,
        animationTrack = animationTrack,
    }

    local runId = self._runId
    task.spawn(function()
        self:_moveEnemyAlongWaypoints(enemyId, enemyModel, runId)
    end)

    return true, enemyId
end

function EnemyService:spawnBatch(
    totalCount: number,
    spawnIntervalSeconds: number?,
    shouldContinueCallback,
    onSpawnedCountCallback,
    onSpawnedEnemyCallback
)
    if not self._running then
        return 0, 'SERVICE_NOT_RUNNING'
    end

    local targetCount = math.max(0, math.floor(totalCount or 0))
    local interval = tonumber(spawnIntervalSeconds) or 0
    if interval < 0 then
        interval = 0
    end
    local randomExtraDelayMin = tonumber(self._config.ENEMY_SPAWN_RANDOM_EXTRA_DELAY_MIN_SECONDS) or 0
    local randomExtraDelayMax = tonumber(self._config.ENEMY_SPAWN_RANDOM_EXTRA_DELAY_MAX_SECONDS) or 0
    if randomExtraDelayMin < 0 then
        randomExtraDelayMin = 0
    end
    if randomExtraDelayMax < 0 then
        randomExtraDelayMax = 0
    end
    if randomExtraDelayMax < randomExtraDelayMin then
        randomExtraDelayMax = randomExtraDelayMin
    end

    local spawnedCount = 0
    for _ = 1, targetCount do
        if not self._running then
            return spawnedCount, 'SERVICE_STOPPED'
        end

        if type(shouldContinueCallback) == 'function' and not shouldContinueCallback() then
            return spawnedCount, 'STOPPED_BY_CALLER'
        end

        local ok, result = self:spawnSingleEnemy()
        if not ok then
            return spawnedCount, tostring(result)
        end

        spawnedCount += 1
        if type(onSpawnedCountCallback) == 'function' then
            onSpawnedCountCallback(result, spawnedCount)
        end
        if type(onSpawnedEnemyCallback) == 'function' then
            onSpawnedEnemyCallback(result)
        end

        if spawnedCount < targetCount then
            local randomExtraDelay = 0
            if randomExtraDelayMax > 0 then
                randomExtraDelay = self._rng:NextNumber(randomExtraDelayMin, randomExtraDelayMax)
            end
            local waitSeconds = interval + randomExtraDelay
            if waitSeconds > 0 then
                task.wait(waitSeconds)
            end
        end
    end

    return spawnedCount, nil
end

function EnemyService:applyDamage(enemyId: number, amount: number, source)
    if not self._running then
        return false, 'SERVICE_NOT_RUNNING'
    end

    if type(enemyId) ~= 'number' then
        return false, 'INVALID_ENEMY_ID'
    end

    local rawAmount = tonumber(amount)
    if not rawAmount then
        return false, 'INVALID_DAMAGE_AMOUNT'
    end

    if rawAmount <= 0 then
        return false, 'NON_POSITIVE_DAMAGE'
    end

    local record = self:_getEnemyRecord(enemyId)
    if not record then
        return false, 'ENEMY_NOT_FOUND'
    end

    if record.leakApplied then
        return false, 'ENEMY_ALREADY_LEAKED'
    end
    if record.deathApplied then
        return false, 'ENEMY_ALREADY_DEAD'
    end

    local model = record.model
    if not model or not model.Parent then
        return false, 'ENEMY_MODEL_MISSING'
    end

    local previousHealth = tonumber(record.health) or tonumber(record.maxHealth) or 1
    local maxHealth = tonumber(record.maxHealth) or previousHealth
    local clampedDamage = math.max(0, math.floor(rawAmount))
    if clampedDamage <= 0 then
        return false, 'DAMAGE_TOO_SMALL'
    end

    local nextHealth = math.max(0, previousHealth - clampedDamage)
    record.health = nextHealth
    updateModelHealth(model, nextHealth)

    local deathPayload = nil
    if nextHealth <= 0 then
        record.deathApplied = true
        deathPayload = {
            enemyId = enemyId,
            source = source,
            spawnOrdinal = record.spawnOrdinal,
            variant = record.variant,
            isElite = record.isElite,
            eliteTag = record.eliteTag,
            rewardMultiplier = record.rewardMultiplier,
            maxHealth = maxHealth,
            damageApplied = clampedDamage,
        }
        if self._onEnemyDied then
            self._onEnemyDied(deathPayload)
        end
        self:_resolveEnemy(enemyId)
    end

    return true,
        {
            enemyId = enemyId,
            source = source,
            previousHealth = previousHealth,
            currentHealth = nextHealth,
            maxHealth = maxHealth,
            damageApplied = clampedDamage,
            isDead = nextHealth <= 0,
            death = deathPayload,
        }
end

return EnemyService
