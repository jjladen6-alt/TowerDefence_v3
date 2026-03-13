local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ServerStorage = game:GetService('ServerStorage')
local Workspace = game:GetService('Workspace')

local WorldContractValidator = {}

local REQUIRED_WORKSPACE_ROOT_PATHS = {
    { path = 'lobby/queuepadbrown', className = 'BasePart' },
    { path = 'lobby/queuepadgreen', className = 'BasePart' },
    { path = 'lobby/queuepadred', className = 'BasePart' },
    { path = 'lobby/queuepadyellow', className = 'BasePart' },
    { path = 'lobby/SpawnLocation', className = 'BasePart' },
}

local REQUIRED_MAP_RELATIVE_PATHS = {
    { path = 'spawn1', className = 'BasePart' },
    { path = 'EnemySpawns', className = 'Folder' },
    { path = 'Waypoints', className = 'Folder' },
    { path = 'Base/Core', className = 'BasePart' },
}

local REQUIRED_SERVER_STORAGE_PATHS = {
    { path = 'EnemyModels', className = 'Folder' },
}

local SUPPORTED_MISSION_TYPES = {
    kills = true,
    no_leak = true,
    round_clear = true,
}

local function parseWaypointOrder(name: string): number?
    local direct = tonumber(name)
    if direct then
        return direct
    end
    local suffix = string.match(string.upper(name), '^WP(%d+)$')
    if suffix then
        return tonumber(suffix)
    end
    return nil
end

local function validateWaypointContract(errors: { string }, waypointsFolder: Instance?, mapName: string)
    if not waypointsFolder or not waypointsFolder:IsA('Folder') then
        return
    end

    local orderedParts = {}
    local seenOrders = {}
    for _, descendant in ipairs(waypointsFolder:GetDescendants()) do
        if descendant:IsA('BasePart') then
            local order = parseWaypointOrder(descendant.Name)
            if order then
                if seenOrders[order] then
                    table.insert(
                        errors,
                        ('Workspace/%s/Waypoints has duplicate waypoint order %d (%s and %s).'):format(
                            mapName,
                            order,
                            seenOrders[order],
                            descendant:GetFullName()
                        )
                    )
                else
                    seenOrders[order] = descendant:GetFullName()
                end
                table.insert(orderedParts, {
                    part = descendant,
                    order = order,
                })
            end
        end
    end

    if #orderedParts == 0 then
        table.insert(errors, ('Workspace/%s/Waypoints has no valid numeric/wp-prefixed waypoint parts.'):format(mapName))
        return
    end

    table.sort(orderedParts, function(a, b)
        return a.order < b.order
    end)

    local previous = 0
    for _, entry in ipairs(orderedParts) do
        if entry.order < 1 then
            table.insert(
                errors,
                ('Waypoint order must start at 1+, found %d (%s).'):format(entry.order, entry.part:GetFullName())
            )
        end
        if previous > 0 and (entry.order - previous) > 1 then
            table.insert(
                errors,
                ('Waypoint order gap detected between %d and %d in Workspace/%s/Waypoints.'):format(
                    previous,
                    entry.order,
                    mapName
                )
            )
        end
        previous = entry.order
    end
end

local function getImplementedStageIds(gameConfig): { string }
    local stageIds = {}
    local seen = {}

    local stageOptions = type(gameConfig) == 'table' and gameConfig.STAGE_SELECTION_OPTIONS or nil
    if type(stageOptions) == 'table' then
        for _, stage in ipairs(stageOptions) do
            if type(stage) == 'table' and stage.implemented ~= false then
                local stageId = stage.stageId
                if type(stageId) == 'string' and stageId ~= '' and not seen[stageId] then
                    seen[stageId] = true
                    table.insert(stageIds, stageId)
                end
            end
        end
    end

    if #stageIds == 0 then
        table.insert(stageIds, tostring((type(gameConfig) == 'table' and gameConfig.DEFAULT_STAGE_ID) or 'brown'))
    end

    return stageIds
end

local function resolveWrapperContainer(instance: Instance): Instance?
    local wrapped = instance:FindFirstChild(instance.Name)
    if wrapped and (wrapped:IsA('Model') or wrapped:IsA('Folder')) then
        return wrapped
    end
    for _, child in ipairs(instance:GetChildren()) do
        if (child:IsA('Model') or child:IsA('Folder')) and string.lower(child.Name) == string.lower(instance.Name) then
            return child
        end
    end
    return nil
end

local function findChildThroughWrappers(current: Instance, segment: string): Instance?
    local nextInstance = current:FindFirstChild(segment)
    if nextInstance then
        return nextInstance
    end

    local visited = {}
    local cursor = current
    while cursor and not visited[cursor] do
        visited[cursor] = true
        local wrapped = resolveWrapperContainer(cursor)
        if not wrapped then
            return nil
        end
        nextInstance = wrapped:FindFirstChild(segment)
        if nextInstance then
            return nextInstance
        end
        cursor = wrapped
    end

    return nil
end

local function ensurePath(root: Instance, slashPath: string, className: string)
    local current = root
    local segments = {}
    for segment in string.gmatch(slashPath, '[^/]+') do
        table.insert(segments, segment)
    end

    for index, segment in ipairs(segments) do
        local child = current:FindFirstChild(segment)
        if not child then
            local isLeaf = index == #segments
            if not isLeaf then
                local createdFolder = Instance.new('Folder')
                createdFolder.Name = segment
                createdFolder.Parent = current
                child = createdFolder
            elseif className == 'Folder' then
                local createdFolder = Instance.new('Folder')
                createdFolder.Name = segment
                createdFolder.Parent = current
                child = createdFolder
            elseif className == 'BasePart' then
                local createdPart = Instance.new('Part')
                createdPart.Name = segment
                createdPart.Anchored = true
                createdPart.CanCollide = false
                createdPart.Size = Vector3.new(8, 1, 8)
                createdPart.CFrame = CFrame.new(0, 8, 0)
                createdPart.Parent = current
                child = createdPart
            end
        end
        if not child then
            return
        end
        current = child
    end
end

local function hasAnyDescendantBasePart(root: Instance): boolean
    for _, descendant in ipairs(root:GetDescendants()) do
        if descendant:IsA('BasePart') then
            return true
        end
    end
    return false
end

local function ensureStageBootstrapParts(stageRoot: Instance)
    local enemySpawns = findChildThroughWrappers(stageRoot, 'EnemySpawns')
    if enemySpawns and enemySpawns:IsA('Folder') and not hasAnyDescendantBasePart(enemySpawns) then
        local spawnPart = Instance.new('Part')
        spawnPart.Name = 'SpawnA'
        spawnPart.Anchored = true
        spawnPart.CanCollide = false
        spawnPart.Size = Vector3.new(6, 1, 6)
        spawnPart.CFrame = CFrame.new(0, 4, 0)
        spawnPart.Parent = enemySpawns
    end

    local waypoints = findChildThroughWrappers(stageRoot, 'Waypoints')
    local hasValidWaypoint = false
    if waypoints and waypoints:IsA('Folder') then
        for _, descendant in ipairs(waypoints:GetDescendants()) do
            if descendant:IsA('BasePart') and parseWaypointOrder(descendant.Name) then
                hasValidWaypoint = true
                break
            end
        end
    end
    if waypoints and waypoints:IsA('Folder') and not hasValidWaypoint then
        local wp1 = Instance.new('Part')
        wp1.Name = '1'
        wp1.Anchored = true
        wp1.CanCollide = false
        wp1.Size = Vector3.new(4, 1, 4)
        wp1.CFrame = CFrame.new(0, 4, 0)
        wp1.Parent = waypoints

        local wp2 = Instance.new('Part')
        wp2.Name = '2'
        wp2.Anchored = true
        wp2.CanCollide = false
        wp2.Size = Vector3.new(4, 1, 4)
        wp2.CFrame = CFrame.new(40, 4, 0)
        wp2.Parent = waypoints
    end
end

local function getPath(root: Instance, slashPath: string): Instance?
    local current = root

    for segment in string.gmatch(slashPath, '[^/]+') do
        -- Some imported .rbxmx assets wrap content in repeated same-name containers.
        -- Allow traversal through those wrappers while resolving strict contract paths.
        local nextInstance = findChildThroughWrappers(current, segment)
        current = nextInstance
        if not current then
            return nil
        end
    end

    return current
end

local function ensureWorkspaceContracts(gameConfig)
    for _, requirement in ipairs(REQUIRED_WORKSPACE_ROOT_PATHS) do
        if not getPath(Workspace, requirement.path) then
            ensurePath(Workspace, requirement.path, requirement.className)
        end
    end

    local stageIds = getImplementedStageIds(gameConfig)
    for _, stageId in ipairs(stageIds) do
        local stageRoot = Workspace:FindFirstChild(stageId)
        if stageRoot then
            for _, requirement in ipairs(REQUIRED_MAP_RELATIVE_PATHS) do
                local fullPath = ('%s/%s'):format(stageId, requirement.path)
                if not getPath(Workspace, fullPath) then
                    ensurePath(stageRoot, requirement.path, requirement.className)
                end
            end
            ensureStageBootstrapParts(stageRoot)
        end
    end
end

local function assertNoDuplicateRemoteNames(remoteNames: { string })
    local seen = {}
    local duplicates = {}

    for _, remoteName in ipairs(remoteNames) do
        if seen[remoteName] then
            duplicates[remoteName] = true
        else
            seen[remoteName] = true
        end
    end

    if next(duplicates) then
        local duplicateNames = {}
        for duplicateName in pairs(duplicates) do
            table.insert(duplicateNames, duplicateName)
        end
        table.sort(duplicateNames)

        error(
            ('[StartupValidation] Duplicate remote names found in Net: %s'):format(table.concat(duplicateNames, ', '))
        )
    end
end

local function validateMultiplierField(errors: { string }, contextLabel: string, value, minValue: number)
    if type(value) ~= 'number' then
        table.insert(errors, ('%s must be a number.'):format(contextLabel))
        return
    end
    if value < minValue then
        table.insert(errors, ('%s must be >= %.2f.'):format(contextLabel, minValue))
    end
end

local function resolveTowerModelContainerName(schema): string
    if type(schema) == 'table' and type(schema.modelContainerName) == 'string' and schema.modelContainerName ~= '' then
        return schema.modelContainerName
    end
    return 'TowerModels'
end

local function getRootPartNameCandidates(schema, towerSpec): { string }
    local candidates = {}
    local seen = {}

    local function pushName(name)
        if type(name) == 'string' and name ~= '' and not seen[name] then
            seen[name] = true
            table.insert(candidates, name)
        end
    end

    if type(towerSpec) == 'table' then
        pushName(towerSpec.rootPartName)
    end
    if type(schema) == 'table' then
        pushName(schema.baseRootPartName)
        if type(schema.rootPartNameCandidates) == 'table' then
            for _, candidateName in ipairs(schema.rootPartNameCandidates) do
                pushName(candidateName)
            end
        end
    end

    pushName('HumanoidRootPart')
    pushName('Body')
    pushName('UpperTorso')
    pushName('Torso')

    return candidates
end

local function resolveTowerModelsContainer(containerName: string): Instance?
    local container = ServerStorage:FindFirstChild(containerName)
    if not container then
        return nil
    end
    local wrapped = resolveWrapperContainer(container)
    if wrapped then
        return wrapped
    end
    return container
end

local function findTowerTemplate(container: Instance, templateName: string): Model?
    local direct = container:FindFirstChild(templateName)
    if direct and direct:IsA('Model') then
        return direct
    end
    for _, descendant in ipairs(container:GetDescendants()) do
        if descendant:IsA('Model') and descendant.Name == templateName then
            return descendant
        end
    end
    return nil
end

local function validateTowerModelSchema(GameConfigModule, errors: { string })
    local schema = GameConfigModule.TOWER_MODEL_SCHEMA
    if type(schema) ~= 'table' then
        table.insert(errors, 'GameConfig.TOWER_MODEL_SCHEMA must be a table.')
        return
    end

    local containerName = resolveTowerModelContainerName(schema)
    local towerModelsContainer = resolveTowerModelsContainer(containerName)
    if not towerModelsContainer then
        table.insert(errors, ('ServerStorage/%s is missing for tower model schema validation.'):format(containerName))
        return
    end
    if not (towerModelsContainer:IsA('Folder') or towerModelsContainer:IsA('Model')) then
        table.insert(
            errors,
            ('ServerStorage/%s must be a Folder or Model (found %s).'):format(
                containerName,
                towerModelsContainer.ClassName
            )
        )
        return
    end

    local towers = schema.towers
    if type(towers) ~= 'table' or next(towers) == nil then
        table.insert(errors, 'GameConfig.TOWER_MODEL_SCHEMA.towers must be a non-empty table.')
        return
    end

    local configuredTowerCosts = GameConfigModule.TOWER_COSTS
    if type(configuredTowerCosts) == 'table' then
        for towerType in pairs(configuredTowerCosts) do
            if type(towers[towerType]) ~= 'table' then
                table.insert(
                    errors,
                    ('GameConfig.TOWER_MODEL_SCHEMA.towers is missing entry for configured tower type "%s".'):format(
                        towerType
                    )
                )
            end
        end
    end

    local maxModelParts = tonumber(schema.maxModelParts) or 64
    local maxModelHeight = tonumber(schema.maxModelHeight) or 24
    local maxModelFootprint = tonumber(schema.maxModelFootprint) or 16
    if maxModelParts < 1 then
        maxModelParts = 1
    end
    if maxModelHeight < 1 then
        maxModelHeight = 1
    end
    if maxModelFootprint < 1 then
        maxModelFootprint = 1
    end

    for towerType, towerSpec in pairs(towers) do
        if type(towerType) ~= 'string' or towerType == '' then
            table.insert(errors, 'GameConfig.TOWER_MODEL_SCHEMA.towers has a non-string tower key.')
        elseif type(towerSpec) ~= 'table' then
            table.insert(errors, ('GameConfig.TOWER_MODEL_SCHEMA.towers.%s must be a table.'):format(towerType))
        else
            local templateName = towerSpec.templateName
            if type(templateName) ~= 'string' or templateName == '' then
                table.insert(
                    errors,
                    ('GameConfig.TOWER_MODEL_SCHEMA.towers.%s.templateName must be a non-empty string.'):format(
                        towerType
                    )
                )
            else
                local template = findTowerTemplate(towerModelsContainer, templateName)
                if not template then
                    local aliasName = nil
                    if type(GameConfigModule.TOWER_TEMPLATE_ALIASES) == 'table' then
                        aliasName = GameConfigModule.TOWER_TEMPLATE_ALIASES[towerType]
                    end
                    local aliasTemplate = if type(aliasName) == 'string' and aliasName ~= ''
                        then findTowerTemplate(towerModelsContainer, aliasName)
                        else nil
                    if aliasTemplate and aliasTemplate:IsA('Model') then
                        template = aliasTemplate
                        templateName = aliasName
                    else
                        table.insert(
                            errors,
                            ('Tower model missing for %s: expected ServerStorage/%s/%s.'):format(
                                towerType,
                                containerName,
                                templateName
                            )
                        )
                    end
                end
                if template and not template:IsA('Model') then
                    table.insert(
                        errors,
                        ('Tower model schema violation for %s: ServerStorage/%s/%s must be a Model (found %s).'):format(
                            towerType,
                            containerName,
                            templateName,
                            template.ClassName
                        )
                    )
                elseif template then
                    local scriptViolations = {}
                    local partCount = 0
                    local firstBasePart = nil
                    local canonicalRootPart = nil
                    local rootPartCandidates = getRootPartNameCandidates(schema, towerSpec)
                    for _, descendant in ipairs(template:GetDescendants()) do
                        if
                            descendant:IsA('Script')
                            or descendant:IsA('LocalScript')
                            or descendant:IsA('ModuleScript')
                        then
                            table.insert(scriptViolations, descendant:GetFullName())
                        end
                        if descendant:IsA('BasePart') then
                            partCount += 1
                            if not firstBasePart then
                                firstBasePart = descendant
                            end
                            for _, rootPartName in ipairs(rootPartCandidates) do
                                if descendant.Name == rootPartName then
                                    canonicalRootPart = descendant
                                    break
                                end
                            end
                        end
                    end

                    if #scriptViolations > 0 then
                        table.sort(scriptViolations)
                        table.insert(
                            errors,
                            ('Tower model import hygiene violation for %s (%s): remove embedded scripts (%s).'):format(
                                towerType,
                                templateName,
                                table.concat(scriptViolations, ', ')
                            )
                        )
                    end

                    if partCount == 0 then
                        table.insert(
                            errors,
                            ('Tower model schema violation for %s (%s): model must contain at least one BasePart.'):format(
                                towerType,
                                templateName
                            )
                        )
                    elseif partCount > maxModelParts then
                        table.insert(
                            errors,
                            ('Tower model schema violation for %s (%s): part count %d exceeds maxModelParts=%d.'):format(
                                towerType,
                                templateName,
                                partCount,
                                maxModelParts
                            )
                        )
                    end

                    local primaryPart = template.PrimaryPart or canonicalRootPart or firstBasePart
                    if not primaryPart then
                        table.insert(
                            errors,
                            ('Tower model schema violation for %s (%s): primary/root part could not be resolved.'):format(
                                towerType,
                                templateName
                            )
                        )
                    end

                    if #rootPartCandidates > 0 and not canonicalRootPart then
                        table.insert(
                            errors,
                            ('Tower model schema violation for %s (%s): none of required root parts were found (%s).'):format(
                                towerType,
                                templateName,
                                table.concat(rootPartCandidates, ', ')
                            )
                        )
                    end

                    local extentsSize = template:GetExtentsSize()
                    if extentsSize.Y > maxModelHeight then
                        table.insert(
                            errors,
                            ('Tower model schema violation for %s (%s): height %.2f exceeds maxModelHeight=%.2f.'):format(
                                towerType,
                                templateName,
                                extentsSize.Y,
                                maxModelHeight
                            )
                        )
                    end
                    if extentsSize.X > maxModelFootprint or extentsSize.Z > maxModelFootprint then
                        table.insert(
                            errors,
                            ('Tower model schema violation for %s (%s): footprint %.2fx%.2f exceeds maxModelFootprint=%.2f.'):format(
                                towerType,
                                templateName,
                                extentsSize.X,
                                extentsSize.Z,
                                maxModelFootprint
                            )
                        )
                    end

                    local requiredAttachments = towerSpec.requiredAttachments
                    if requiredAttachments ~= nil and type(requiredAttachments) ~= 'table' then
                        table.insert(
                            errors,
                            ('GameConfig.TOWER_MODEL_SCHEMA.towers.%s.requiredAttachments must be an array when provided.'):format(
                                towerType
                            )
                        )
                    elseif type(requiredAttachments) == 'table' then
                        for index, attachmentName in ipairs(requiredAttachments) do
                            if type(attachmentName) ~= 'string' or attachmentName == '' then
                                table.insert(
                                    errors,
                                    ('GameConfig.TOWER_MODEL_SCHEMA.towers.%s.requiredAttachments[%d] must be a non-empty string.'):format(
                                        towerType,
                                        index
                                    )
                                )
                            else
                                local attachmentFound = false
                                for _, descendant in ipairs(template:GetDescendants()) do
                                    if descendant:IsA('Attachment') and descendant.Name == attachmentName then
                                        attachmentFound = true
                                        break
                                    end
                                end
                                if not attachmentFound then
                                    table.insert(
                                        errors,
                                        ('Tower model schema violation for %s (%s): missing required Attachment "%s".'):format(
                                            towerType,
                                            templateName,
                                            attachmentName
                                        )
                                    )
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function validateGameConfig(GameConfigModule, NetModule, errors: { string })
    local difficultyVoteOptions = GameConfigModule.DIFFICULTY_VOTE_OPTIONS
    local defaultDifficulty = GameConfigModule.DEFAULT_DIFFICULTY
    local tieBreakOrder = GameConfigModule.DIFFICULTY_VOTE_TIE_BREAK_ORDER
    local difficultyPresets = GameConfigModule.DIFFICULTY_PRESETS
    if type(difficultyVoteOptions) ~= 'table' or next(difficultyVoteOptions) == nil then
        table.insert(errors, 'GameConfig.DIFFICULTY_VOTE_OPTIONS must be a non-empty table.')
    end
    if type(defaultDifficulty) ~= 'string' or defaultDifficulty == '' then
        table.insert(errors, 'GameConfig.DEFAULT_DIFFICULTY must be a non-empty string.')
    end
    if type(tieBreakOrder) ~= 'table' or #tieBreakOrder == 0 then
        table.insert(errors, 'GameConfig.DIFFICULTY_VOTE_TIE_BREAK_ORDER must be a non-empty array.')
    end
    if type(difficultyPresets) ~= 'table' or next(difficultyPresets) == nil then
        table.insert(errors, 'GameConfig.DIFFICULTY_PRESETS must be a non-empty table.')
    else
        local requiredPresetFields = {
            'enemyCountMultiplier',
            'spawnIntervalMultiplier',
            'enemyHealthMultiplier',
            'enemyMoveSpeedMultiplier',
            'roundDurationMultiplier',
            'killRewardMultiplier',
            'roundRewardMultiplier',
            'towerCostMultiplier',
            'upgradeCostMultiplier',
            'sellRefundMultiplier',
        }
        for presetName, preset in pairs(difficultyPresets) do
            if type(presetName) ~= 'string' or presetName == '' then
                table.insert(errors, 'GameConfig.DIFFICULTY_PRESETS has a non-string key.')
            elseif type(preset) ~= 'table' then
                table.insert(errors, ('GameConfig.DIFFICULTY_PRESETS.%s must be a table.'):format(presetName))
            else
                for _, fieldName in ipairs(requiredPresetFields) do
                    validateMultiplierField(
                        errors,
                        ('GameConfig.DIFFICULTY_PRESETS.%s.%s'):format(presetName, fieldName),
                        preset[fieldName],
                        if fieldName == 'sellRefundMultiplier' then 0 else 0.1
                    )
                end
            end
        end
    end
    if type(difficultyVoteOptions) == 'table' then
        for optionName, optionValue in pairs(difficultyVoteOptions) do
            if type(optionName) ~= 'string' or optionName == '' then
                table.insert(errors, 'GameConfig.DIFFICULTY_VOTE_OPTIONS has a non-string key.')
            elseif type(optionValue) ~= 'table' then
                table.insert(errors, ('GameConfig.DIFFICULTY_VOTE_OPTIONS.%s must be a table.'):format(optionName))
            elseif type(difficultyPresets) == 'table' and type(difficultyPresets[optionName]) ~= 'table' then
                table.insert(
                    errors,
                    ('GameConfig.DIFFICULTY_PRESETS is missing option preset "%s" from DIFFICULTY_VOTE_OPTIONS.'):format(
                        optionName
                    )
                )
            end
        end
    end
    if type(defaultDifficulty) == 'string' and defaultDifficulty ~= '' then
        if type(difficultyVoteOptions) == 'table' and difficultyVoteOptions[defaultDifficulty] == nil then
            table.insert(
                errors,
                ('GameConfig.DEFAULT_DIFFICULTY "%s" is missing from DIFFICULTY_VOTE_OPTIONS.'):format(
                    defaultDifficulty
                )
            )
        end
        if type(difficultyPresets) == 'table' and type(difficultyPresets[defaultDifficulty]) ~= 'table' then
            table.insert(
                errors,
                ('GameConfig.DEFAULT_DIFFICULTY "%s" is missing from DIFFICULTY_PRESETS.'):format(defaultDifficulty)
            )
        end
    end
    if type(tieBreakOrder) == 'table' then
        local seenTieBreak = {}
        for index, optionName in ipairs(tieBreakOrder) do
            if type(optionName) ~= 'string' or optionName == '' then
                table.insert(
                    errors,
                    ('GameConfig.DIFFICULTY_VOTE_TIE_BREAK_ORDER[%d] must be a non-empty string.'):format(index)
                )
            else
                if seenTieBreak[optionName] then
                    table.insert(
                        errors,
                        ('GameConfig.DIFFICULTY_VOTE_TIE_BREAK_ORDER contains duplicate "%s".'):format(optionName)
                    )
                end
                seenTieBreak[optionName] = true
                if type(difficultyVoteOptions) == 'table' and difficultyVoteOptions[optionName] == nil then
                    table.insert(
                        errors,
                        ('GameConfig.DIFFICULTY_VOTE_TIE_BREAK_ORDER references unknown option "%s".'):format(
                            optionName
                        )
                    )
                end
            end
        end
        if type(difficultyVoteOptions) == 'table' then
            for optionName in pairs(difficultyVoteOptions) do
                if not seenTieBreak[optionName] then
                    table.insert(
                        errors,
                        ('GameConfig.DIFFICULTY_VOTE_TIE_BREAK_ORDER missing option "%s".'):format(optionName)
                    )
                end
            end
        end
    end

    local mutators = GameConfigModule.ROUND_MUTATORS
    local mutatorRotation = GameConfigModule.ROUND_MUTATOR_ROTATION
    if type(mutators) ~= 'table' or next(mutators) == nil then
        table.insert(errors, 'GameConfig.ROUND_MUTATORS must be a non-empty table.')
    end
    if type(mutatorRotation) ~= 'table' or #mutatorRotation == 0 then
        table.insert(errors, 'GameConfig.ROUND_MUTATOR_ROTATION must be a non-empty array.')
    else
        for index, mutatorName in ipairs(mutatorRotation) do
            if type(mutatorName) ~= 'string' or mutatorName == '' then
                table.insert(
                    errors,
                    ('GameConfig.ROUND_MUTATOR_ROTATION[%d] must be a non-empty string.'):format(index)
                )
            elseif type(mutators) == 'table' and type(mutators[mutatorName]) ~= 'table' then
                table.insert(errors, ('GameConfig.ROUND_MUTATORS is missing rotation entry "%s".'):format(mutatorName))
            end
        end
    end

    if type(mutators) == 'table' then
        for mutatorName, mutator in pairs(mutators) do
            if type(mutatorName) ~= 'string' or mutatorName == '' then
                table.insert(errors, 'GameConfig.ROUND_MUTATORS has a non-string key.')
            elseif type(mutator) ~= 'table' then
                table.insert(errors, ('GameConfig.ROUND_MUTATORS.%s must be a table.'):format(mutatorName))
            else
                validateMultiplierField(
                    errors,
                    ('GameConfig.ROUND_MUTATORS.%s.enemyCountMultiplier'):format(mutatorName),
                    mutator.enemyCountMultiplier,
                    0.1
                )
                validateMultiplierField(
                    errors,
                    ('GameConfig.ROUND_MUTATORS.%s.spawnIntervalMultiplier'):format(mutatorName),
                    mutator.spawnIntervalMultiplier,
                    0.1
                )
                validateMultiplierField(
                    errors,
                    ('GameConfig.ROUND_MUTATORS.%s.enemyHealthMultiplier'):format(mutatorName),
                    mutator.enemyHealthMultiplier,
                    0.1
                )
                validateMultiplierField(
                    errors,
                    ('GameConfig.ROUND_MUTATORS.%s.enemyMoveSpeedMultiplier'):format(mutatorName),
                    mutator.enemyMoveSpeedMultiplier,
                    0.1
                )
            end
        end
    end

    local missions = GameConfigModule.MISSION_DEFINITIONS
    if type(missions) ~= 'table' or #missions == 0 then
        table.insert(errors, 'GameConfig.MISSION_DEFINITIONS must be a non-empty array.')
    else
        local missionIds = {}
        for index, mission in ipairs(missions) do
            if type(mission) ~= 'table' then
                table.insert(errors, ('GameConfig.MISSION_DEFINITIONS[%d] must be a table.'):format(index))
            else
                local missionId = mission.id
                local missionType = mission.missionType
                local required = mission.required
                local reward = mission.reward
                if type(missionId) ~= 'string' or missionId == '' then
                    table.insert(
                        errors,
                        ('GameConfig.MISSION_DEFINITIONS[%d].id must be a non-empty string.'):format(index)
                    )
                elseif missionIds[missionId] then
                    table.insert(errors, ('GameConfig.MISSION_DEFINITIONS has duplicate id "%s".'):format(missionId))
                else
                    missionIds[missionId] = true
                end
                if type(missionType) ~= 'string' or not SUPPORTED_MISSION_TYPES[missionType] then
                    table.insert(
                        errors,
                        ('GameConfig.MISSION_DEFINITIONS[%d].missionType must be one of kills/no_leak/round_clear.'):format(
                            index
                        )
                    )
                end
                if type(required) ~= 'number' or required < 1 then
                    table.insert(errors, ('GameConfig.MISSION_DEFINITIONS[%d].required must be >= 1.'):format(index))
                end
                if type(reward) ~= 'number' or reward < 0 then
                    table.insert(errors, ('GameConfig.MISSION_DEFINITIONS[%d].reward must be >= 0.'):format(index))
                end
            end
        end
    end

    local requestRateLimits = GameConfigModule.REQUEST_RATE_LIMITS
    if type(requestRateLimits) ~= 'table' then
        table.insert(errors, 'GameConfig.REQUEST_RATE_LIMITS must be a table.')
    else
        for requestName, rateConfig in pairs(requestRateLimits) do
            if type(requestName) ~= 'string' or requestName == '' then
                table.insert(errors, 'GameConfig.REQUEST_RATE_LIMITS has a non-string key.')
            elseif type(rateConfig) ~= 'table' then
                table.insert(errors, ('GameConfig.REQUEST_RATE_LIMITS.%s must be a table.'):format(requestName))
            else
                if type(rateConfig.maxRequests) ~= 'number' or rateConfig.maxRequests <= 0 then
                    table.insert(
                        errors,
                        ('GameConfig.REQUEST_RATE_LIMITS.%s.maxRequests must be > 0.'):format(requestName)
                    )
                end
                if type(rateConfig.perSeconds) ~= 'number' or rateConfig.perSeconds <= 0 then
                    table.insert(
                        errors,
                        ('GameConfig.REQUEST_RATE_LIMITS.%s.perSeconds must be > 0.'):format(requestName)
                    )
                end
            end
        end
    end

    local placementSurfaceMode = GameConfigModule.PLACEMENT_SURFACE_MODE
    if placementSurfaceMode ~= nil and type(placementSurfaceMode) ~= 'string' then
        table.insert(errors, 'GameConfig.PLACEMENT_SURFACE_MODE must be a string when provided.')
    end
    local placementAllowTerrain = GameConfigModule.PLACEMENT_ALLOW_TERRAIN
    if placementAllowTerrain ~= nil and type(placementAllowTerrain) ~= 'boolean' then
        table.insert(errors, 'GameConfig.PLACEMENT_ALLOW_TERRAIN must be a boolean when provided.')
    end

    local blockedTags = GameConfigModule.PLACEMENT_BLOCKED_TAGS
    if blockedTags ~= nil and type(blockedTags) ~= 'table' then
        table.insert(errors, 'GameConfig.PLACEMENT_BLOCKED_TAGS must be an array when provided.')
    elseif type(blockedTags) == 'table' then
        for index, tagName in ipairs(blockedTags) do
            if type(tagName) ~= 'string' or tagName == '' then
                table.insert(errors, ('GameConfig.PLACEMENT_BLOCKED_TAGS[%d] must be a non-empty string.'):format(index))
            end
        end
    end

    local blockedFolderNames = GameConfigModule.PLACEMENT_BLOCKED_FOLDER_NAMES
    if blockedFolderNames ~= nil and type(blockedFolderNames) ~= 'table' then
        table.insert(errors, 'GameConfig.PLACEMENT_BLOCKED_FOLDER_NAMES must be an array when provided.')
    elseif type(blockedFolderNames) == 'table' then
        for index, folderName in ipairs(blockedFolderNames) do
            if type(folderName) ~= 'string' or folderName == '' then
                table.insert(
                    errors,
                    ('GameConfig.PLACEMENT_BLOCKED_FOLDER_NAMES[%d] must be a non-empty string.'):format(index)
                )
            end
        end
    end

    local clientToServer = NetModule and NetModule.ClientToServer
    if type(clientToServer) == 'table' then
        if type(requestRateLimits) ~= 'table' then
            table.insert(errors, 'GameConfig.REQUEST_RATE_LIMITS must be configured for client request remotes.')
        else
            for requestName in pairs(clientToServer) do
                if type(requestRateLimits[requestName]) ~= 'table' then
                    table.insert(
                        errors,
                        ('GameConfig.REQUEST_RATE_LIMITS is missing active request surface "%s".'):format(requestName)
                    )
                end
            end
        end
    end
end

function WorldContractValidator.createOrRefreshRemotes(remoteNames: { string })
    local remotesFolder = ReplicatedStorage:FindFirstChild('Remotes')
    if not remotesFolder then
        remotesFolder = Instance.new('Folder')
        remotesFolder.Name = 'Remotes'
        remotesFolder.Parent = ReplicatedStorage
    end

    local expected = {}
    for _, remoteName in ipairs(remoteNames) do
        expected[remoteName] = true

        local existing = remotesFolder:FindFirstChild(remoteName)
        if existing and not existing:IsA('RemoteEvent') then
            existing:Destroy()
            existing = nil
        end

        if not existing then
            local remoteEvent = Instance.new('RemoteEvent')
            remoteEvent.Name = remoteName
            remoteEvent.Parent = remotesFolder
        end
    end

    for _, child in ipairs(remotesFolder:GetChildren()) do
        if not expected[child.Name] then
            child:Destroy()
        end
    end
end

function WorldContractValidator.validateStartup(NetModule, GameConfigModule)
    local errors = {}

    if type(NetModule) ~= 'table' or type(NetModule.getAllRemoteNames) ~= 'function' then
        table.insert(errors, 'ReplicatedStorage/Shared/Net is missing or invalid.')
    end

    if type(GameConfigModule) ~= 'table' then
        table.insert(errors, 'ReplicatedStorage/Shared/GameConfig is missing or invalid.')
    else
        validateGameConfig(GameConfigModule, NetModule, errors)
        ensureWorkspaceContracts(GameConfigModule)
    end

    for _, requirement in ipairs(REQUIRED_WORKSPACE_ROOT_PATHS) do
        local instance = getPath(Workspace, requirement.path)
        if not instance then
            table.insert(errors, ('Missing Workspace path: Workspace/%s'):format(requirement.path))
        else
            if requirement.className == 'BasePart' then
                if not instance:IsA('BasePart') then
                    table.insert(
                        errors,
                        ('Workspace/%s must be a BasePart (found %s).'):format(requirement.path, instance.ClassName)
                    )
                end
            elseif requirement.className == 'Folder' and not instance:IsA('Folder') then
                table.insert(
                    errors,
                    ('Workspace/%s must be a Folder (found %s).'):format(requirement.path, instance.ClassName)
                )
            end
        end
    end

    local stageIds = getImplementedStageIds(GameConfigModule)
    for _, stageId in ipairs(stageIds) do
        local waypointsFolder = nil
        for _, requirement in ipairs(REQUIRED_MAP_RELATIVE_PATHS) do
            local fullPath = ('%s/%s'):format(stageId, requirement.path)
            local instance = getPath(Workspace, fullPath)
            if not instance then
                table.insert(errors, ('Missing Workspace path: Workspace/%s'):format(fullPath))
            else
                if requirement.path == 'Waypoints' then
                    waypointsFolder = instance
                end
                if requirement.className == 'BasePart' then
                    if not instance:IsA('BasePart') then
                        table.insert(
                            errors,
                            ('Workspace/%s must be a BasePart (found %s).'):format(fullPath, instance.ClassName)
                        )
                    end
                elseif requirement.className == 'Folder' and not instance:IsA('Folder') then
                    table.insert(
                        errors,
                        ('Workspace/%s must be a Folder (found %s).'):format(fullPath, instance.ClassName)
                    )
                end
            end
        end
        validateWaypointContract(errors, waypointsFolder, stageId)
    end

    for _, requirement in ipairs(REQUIRED_SERVER_STORAGE_PATHS) do
        local instance = getPath(ServerStorage, requirement.path)
        if not instance then
            table.insert(errors, ('Missing ServerStorage path: ServerStorage/%s'):format(requirement.path))
        elseif requirement.className == 'Folder' and not instance:IsA('Folder') then
            table.insert(
                errors,
                ('ServerStorage/%s must be a Folder (found %s).'):format(requirement.path, instance.ClassName)
            )
        end
    end

    if type(GameConfigModule) == 'table' then
        validateTowerModelSchema(GameConfigModule, errors)
    end

    if #errors > 0 then
        error(('[StartupValidation] Failed with %d issue(s):\n- %s'):format(#errors, table.concat(errors, '\n- ')))
    end

    local remoteNames = NetModule.getAllRemoteNames()
    assertNoDuplicateRemoteNames(remoteNames)
    WorldContractValidator.createOrRefreshRemotes(remoteNames)
end

return WorldContractValidator
