local GameConfig = {
    -- Step 1 scope lock: one global match loop for all players.
    MATCH_SCOPE = 'GLOBAL',
    BASELINE_STATUS = 'ACTIVE_STABLE',

    LOBBY_DURATION = 15,
    ROUND_DURATION = 180,
    ROUND_DURATION_PER_ROUND = -5,
    ROUND_DURATION_MIN = 120,
    RESULTS_DURATION = 10,
    -- Milestone 4 Step 17: explicit combat-speed surface for HUD clarity.
    COMBAT_GAME_SPEED_MULTIPLIER = 1.0,
    QUEUE_MIN_PLAYERS = 1,
    QUEUE_START_COUNTDOWN_SECONDS = 3,
    QUEUE_TOUCH_DEBOUNCE_SECONDS = 0.15,
    QUEUE_PRESENCE_SAMPLE_INTERVAL_SECONDS = 0.1,
    QUEUE_LEAVE_GRACE_SECONDS = 0.75,
    QUEUE_COUNTDOWN_LEAVE_GRACE_SECONDS = 2.0,
    DEFAULT_DIFFICULTY = 'Normal',
    DIFFICULTY_VOTE_WINDOW_SECONDS = 8,
    DIFFICULTY_VOTE_ENABLED = false,
    DIFFICULTY_SYSTEM_MESSAGES_ENABLED = false,
    DIFFICULTY_VOTE_TIE_BREAK_ORDER = { 'Normal', 'Hard', 'Challenge' },
    DIFFICULTY_VOTE_OPTIONS = {
        Normal = {
            label = 'Normal',
        },
        Hard = {
            label = 'Hard',
        },
        Challenge = {
            label = 'Challenge',
        },
    },
    DIFFICULTY_PRESETS = {
        Normal = {
            enemyCountMultiplier = 1.0,
            spawnIntervalMultiplier = 1.0,
            enemyHealthMultiplier = 1.0,
            enemyMoveSpeedMultiplier = 1.0,
            roundDurationMultiplier = 1.0,
            killRewardMultiplier = 1.0,
            roundRewardMultiplier = 1.0,
            towerCostMultiplier = 1.0,
            upgradeCostMultiplier = 1.0,
            sellRefundMultiplier = 1.0,
            announceText = 'Normal',
        },
        Hard = {
            enemyCountMultiplier = 1.15,
            spawnIntervalMultiplier = 0.92,
            enemyHealthMultiplier = 1.2,
            enemyMoveSpeedMultiplier = 1.08,
            roundDurationMultiplier = 0.94,
            killRewardMultiplier = 1.2,
            roundRewardMultiplier = 1.2,
            towerCostMultiplier = 1.0,
            upgradeCostMultiplier = 1.05,
            sellRefundMultiplier = 0.95,
            announceText = 'Hard',
        },
        Challenge = {
            enemyCountMultiplier = 1.3,
            spawnIntervalMultiplier = 0.86,
            enemyHealthMultiplier = 1.4,
            enemyMoveSpeedMultiplier = 1.14,
            roundDurationMultiplier = 0.88,
            killRewardMultiplier = 1.35,
            roundRewardMultiplier = 1.35,
            towerCostMultiplier = 1.05,
            upgradeCostMultiplier = 1.12,
            sellRefundMultiplier = 0.9,
            announceText = 'Challenge',
        },
    },

    ENEMIES_PER_MATCH = 30,
    ENEMIES_PER_MATCH_PER_ROUND = 1,
    ENEMIES_PER_MATCH_MAX = 60,
    ENEMY_PER_WAVE = 10,
    ENEMY_SPAWN_INTERVAL_SECONDS = 1.0,
    ENEMY_SPAWN_HEIGHT_OFFSET_STUDS = 4,
    ENEMY_MOVE_SPEED = 12,
    ENEMY_MOVE_SPEED_PER_ROUND = 0.2,
    ENEMY_BASE_HEALTH = 40,
    ENEMY_HEALTH_PER_SPAWN = 4,
    ENEMY_HEALTH_PER_ROUND = 3,
    ENEMY_VARIANTS = {
        Normal = {
            unlockRound = 1,
            healthMultiplier = 1.0,
            speedMultiplier = 1.0,
            rewardMultiplier = 1.0,
        },
        Swift = {
            unlockRound = 3,
            healthMultiplier = 0.9,
            speedMultiplier = 1.2,
            rewardMultiplier = 1.1,
        },
        Tank = {
            unlockRound = 5,
            healthMultiplier = 1.4,
            speedMultiplier = 0.82,
            rewardMultiplier = 1.25,
        },
    },
    ENEMY_VARIANT_PROGRESS_BANDS = {
        { minProgress = 0.0, variant = 'Normal' },
        { minProgress = 0.45, variant = 'Swift' },
        { minProgress = 0.8, variant = 'Tank' },
    },
    ENEMY_ELITE = {
        enabled = true,
        unlockRound = 4,
        everySpawnOrdinal = 10,
        healthMultiplier = 1.8,
        speedMultiplier = 0.95,
        rewardMultiplier = 1.6,
        tag = 'Elite',
    },
    ROUND_MODIFIER_ROTATION = { 'NoModifier', 'DenseWave', 'SwiftPressure' },
    ROUND_MODIFIERS = {
        NoModifier = {
            enemyCountMultiplier = 1.0,
            spawnIntervalMultiplier = 1.0,
            enemyHealthMultiplier = 1.0,
            enemyMoveSpeedMultiplier = 1.0,
            announceText = 'No modifier',
        },
        DenseWave = {
            enemyCountMultiplier = 1.2,
            spawnIntervalMultiplier = 0.85,
            enemyHealthMultiplier = 0.95,
            enemyMoveSpeedMultiplier = 1.0,
            announceText = 'DenseWave: more enemies spawn faster.',
        },
        SwiftPressure = {
            enemyCountMultiplier = 1.0,
            spawnIntervalMultiplier = 1.0,
            enemyHealthMultiplier = 0.9,
            enemyMoveSpeedMultiplier = 1.2,
            announceText = 'SwiftPressure: enemies move faster.',
        },
    },
    -- Milestone 5 Step 21: explicit mutator pool surfaces (fallback to ROUND_MODIFIERS when absent).
    ROUND_MUTATOR_ROTATION = { 'NoModifier', 'DenseWave', 'SwiftPressure' },
    ROUND_MUTATORS = {
        NoModifier = {
            enemyCountMultiplier = 1.0,
            spawnIntervalMultiplier = 1.0,
            enemyHealthMultiplier = 1.0,
            enemyMoveSpeedMultiplier = 1.0,
            announceText = 'No modifier',
            threatHint = 'Standard wave pacing.',
        },
        DenseWave = {
            enemyCountMultiplier = 1.2,
            spawnIntervalMultiplier = 0.85,
            enemyHealthMultiplier = 0.95,
            enemyMoveSpeedMultiplier = 1.0,
            announceText = 'DenseWave: more enemies spawn faster.',
            threatHint = 'High density pressure. Build for sustained DPS.',
        },
        SwiftPressure = {
            enemyCountMultiplier = 1.0,
            spawnIntervalMultiplier = 1.0,
            enemyHealthMultiplier = 0.9,
            enemyMoveSpeedMultiplier = 1.2,
            announceText = 'SwiftPressure: enemies move faster.',
            threatHint = 'Fast movers. Prioritize range and coverage.',
        },
    },
    DEBUG_WAYPOINT_PATHING = false,
    BASE_MAX_HEALTH = 100,
    BASE_LEAK_DAMAGE = 20,
    DEBUG_BALANCE_SNAPSHOT = true,
    DEBUG_SOAK_SNAPSHOT = true,
    DEBUG_RELEASE_GATE_SUMMARY = true,
    DEBUG_RUNTIME_INVARIANT_CHECKS = true,
    DEBUG_RUNTIME_INVARIANT_WARNING_COOLDOWN_SECONDS = 5,
    DEBUG_RUNTIME_INVARIANT_BROADCAST_SYSTEM_MESSAGE = true,
    RELEASE_GATE_REQUIRED_ROUNDS = 3,
    RELEASE_GATE_REQUIRED_PASS_RATE_PCT = 100,
    BALANCE_TARGET_SOLO_CLEAR_RATE_MIN_PCT = 40,
    BALANCE_TARGET_SOLO_CLEAR_RATE_MAX_PCT = 60,

    TOWER_COSTS = {
        Basic = 90,
        Rapid = 100,
        Sniper = 130,
        Support = 120,
    },
    -- Milestone 1 Step 1: compact visual baseline for readability and consistency.
    TOWER_VISUAL_BASELINE = {
        styleId = 'BrightStylizedReadable_v1',
        saturationBand = { min = 0.55, max = 0.85 },
        glow = {
            maxNeonPartsPerModel = 2,
            maxParticleEmittersPerModel = 2,
        },
        readability = {
            minContrastVsMap = 0.35,
            targetCameraDistance = 60,
            silhouettePriority = 'High',
        },
    },
    -- Milestone 7 Step 31/32: server-owned enemy/tower contrast + accessibility-safe cues.
    ENEMY_VISUAL_CONTRAST = {
        default = {
            material = 'SmoothPlastic',
            bodyColor = Color3.fromRGB(212, 78, 78),
            accentColor = Color3.fromRGB(255, 194, 120),
            outlineColor = Color3.fromRGB(255, 236, 168),
            fillTransparency = 0.9,
            outlineTransparency = 0.2,
        },
        variants = {
            Normal = {
                bodyColor = Color3.fromRGB(212, 78, 78),
                accentColor = Color3.fromRGB(255, 194, 120),
            },
            Swift = {
                bodyColor = Color3.fromRGB(236, 112, 72),
                accentColor = Color3.fromRGB(255, 214, 126),
            },
            Tank = {
                bodyColor = Color3.fromRGB(170, 68, 118),
                accentColor = Color3.fromRGB(240, 176, 255),
            },
        },
        elite = {
            outlineColor = Color3.fromRGB(255, 238, 142),
            fillTransparency = 0.82,
            outlineTransparency = 0.12,
        },
    },
    -- Milestone 1 Step 2/3: canonical schema for deterministic model resolution.
    TOWER_MODEL_SCHEMA = {
        modelContainerName = 'TowerModels',
        baseRootPartName = 'Body',
        rootPartNameCandidates = { 'Body', 'HumanoidRootPart', 'UpperTorso', 'Torso' },
        maxModelParts = 64,
        maxModelHeight = 24,
        maxModelFootprint = 16,
        requiredAttributes = {},
        towers = {
            Basic = {
                templateName = 'Basic',
                facingPartName = 'Body',
                requiredAttachments = {},
                role = 'General',
            },
            Rapid = {
                templateName = 'Rapid',
                facingPartName = 'HumanoidRootPart',
                requiredAttachments = {},
                role = 'DPS',
            },
            Sniper = {
                templateName = 'Sniper',
                facingPartName = 'Body',
                requiredAttachments = {},
                role = 'Precision',
            },
            Support = {
                templateName = 'Support',
                facingPartName = 'Body',
                requiredAttachments = {},
                role = 'Support',
            },
        },
    },
    -- Allows new tower types to ship before dedicated models are imported.
    TOWER_TEMPLATE_ALIASES = {
        Rapid = 'Basic',
        Sniper = 'Basic',
        Support = 'Basic',
    },
    TOWER_DEFAULT_RANGE = 24,
    TOWER_DEFAULT_DAMAGE = 12,
    TOWER_ATTACK_INTERVAL_SECONDS = 1.0,
    TOWER_COMBAT_TICK_SECONDS = 0.1,
    DEBUG_TOWER_COMBAT = false,
    DEBUG_TOWER_COMBAT_PRINT_INTERVAL_SECONDS = 3,
    DEBUG_TOWER_COMBAT_RESET_ON_WAVE_START = true,
    DEBUG_TOWER_COMBAT_LOG_OUTSIDE_WAVE = false,
    -- Polished enemy-facing behavior (server-authoritative, Y-axis only).
    TOWER_FACING = {
        enabled = true,
        enabledTowerTypes = {
            Rapid = true,
        },
        activeProfile = 'Balanced',
        profiles = {
            Smooth = {
                maxTurnSpeedDegPerSecond = 220,
                minAngleDeltaDeg = 2.5,
                updateIntervalSeconds = 0.12,
            },
            Balanced = {
                maxTurnSpeedDegPerSecond = 300,
                minAngleDeltaDeg = 1.5,
                updateIntervalSeconds = 0.1,
            },
            Snappy = {
                maxTurnSpeedDegPerSecond = 420,
                minAngleDeltaDeg = 0.9,
                updateIntervalSeconds = 0.06,
            },
        },
        -- Optional overrides applied after profile selection.
        maxTurnSpeedDegPerSecond = nil,
        minAngleDeltaDeg = nil,
        updateIntervalSeconds = nil,
    },
    TOWER_MAX_UPGRADE_TIER = 3,
    TOWER_UPGRADE_COST_MULTIPLIER = 1.5,
    TOWER_UPGRADE_DAMAGE_MULTIPLIER = 1.25,
    TOWER_UPGRADE_RANGE_MULTIPLIER = 1.1,
    TOWER_UPGRADE_ATTACK_INTERVAL_MULTIPLIER = 0.92,
    -- Explicit per-type, per-tier combat tables (used before multiplier fallback).
    TOWER_STATS_BY_TYPE = {
        Basic = {
            [0] = { damage = 14, range = 25, attackInterval = 0.95 },
            [1] = { damage = 64, range = 27, attackInterval = 0.9 },
            [2] = { damage = 100, range = 29, attackInterval = 0.8 },
            [3] = { damage = 136, range = 31, attackInterval = 0.72 },
        },
        Rapid = {
            [0] = { damage = 11, range = 22, attackInterval = 0.38 },
            [1] = { damage = 28, range = 24, attackInterval = 0.33 },
            [2] = { damage = 44, range = 26, attackInterval = 0.28 },
            [3] = { damage = 60, range = 27, attackInterval = 0.24 },
        },
        Sniper = {
            [0] = { damage = 34, range = 36, attackInterval = 1.35 },
            [1] = { damage = 78, range = 38, attackInterval = 1.22 },
            [2] = { damage = 124, range = 40, attackInterval = 1.08 },
            [3] = { damage = 170, range = 42, attackInterval = 0.95 },
        },
        Support = {
            [0] = { damage = 0, range = 18, attackInterval = 2.0 },
            [1] = { damage = 0, range = 19, attackInterval = 1.9 },
            [2] = { damage = 0, range = 20, attackInterval = 1.8 },
            [3] = { damage = 0, range = 21, attackInterval = 1.7 },
        },
    },
    -- Milestone 6 Step 26: deterministic per-tier tower visual language.
    TOWER_VISUAL_PROGRESSION = {
        Basic = {
            [0] = {
                accentColor = Color3.fromRGB(110, 190, 255),
                fillTransparency = 0.92,
                outlineTransparency = 0.35,
                auraRate = 0,
            },
            [1] = {
                accentColor = Color3.fromRGB(95, 205, 255),
                fillTransparency = 0.88,
                outlineTransparency = 0.28,
                auraRate = 2,
            },
            [2] = {
                accentColor = Color3.fromRGB(120, 230, 255),
                fillTransparency = 0.84,
                outlineTransparency = 0.22,
                auraRate = 4,
            },
            [3] = {
                accentColor = Color3.fromRGB(150, 245, 255),
                fillTransparency = 0.78,
                outlineTransparency = 0.18,
                auraRate = 6,
            },
        },
        Rapid = {
            [0] = {
                accentColor = Color3.fromRGB(120, 255, 150),
                fillTransparency = 0.92,
                outlineTransparency = 0.35,
                auraRate = 0,
            },
            [1] = {
                accentColor = Color3.fromRGB(110, 255, 140),
                fillTransparency = 0.88,
                outlineTransparency = 0.28,
                auraRate = 3,
            },
            [2] = {
                accentColor = Color3.fromRGB(130, 255, 160),
                fillTransparency = 0.84,
                outlineTransparency = 0.22,
                auraRate = 5,
            },
            [3] = {
                accentColor = Color3.fromRGB(165, 255, 185),
                fillTransparency = 0.78,
                outlineTransparency = 0.18,
                auraRate = 7,
            },
        },
        Sniper = {
            [0] = {
                accentColor = Color3.fromRGB(255, 195, 120),
                fillTransparency = 0.92,
                outlineTransparency = 0.35,
                auraRate = 0,
            },
            [1] = {
                accentColor = Color3.fromRGB(255, 205, 130),
                fillTransparency = 0.88,
                outlineTransparency = 0.28,
                auraRate = 2,
            },
            [2] = {
                accentColor = Color3.fromRGB(255, 220, 145),
                fillTransparency = 0.84,
                outlineTransparency = 0.22,
                auraRate = 4,
            },
            [3] = {
                accentColor = Color3.fromRGB(255, 235, 170),
                fillTransparency = 0.78,
                outlineTransparency = 0.18,
                auraRate = 6,
            },
        },
        Support = {
            [0] = {
                accentColor = Color3.fromRGB(220, 170, 255),
                fillTransparency = 0.92,
                outlineTransparency = 0.35,
                auraRate = 1,
            },
            [1] = {
                accentColor = Color3.fromRGB(225, 175, 255),
                fillTransparency = 0.88,
                outlineTransparency = 0.28,
                auraRate = 3,
            },
            [2] = {
                accentColor = Color3.fromRGB(235, 190, 255),
                fillTransparency = 0.84,
                outlineTransparency = 0.22,
                auraRate = 5,
            },
            [3] = {
                accentColor = Color3.fromRGB(245, 210, 255),
                fillTransparency = 0.78,
                outlineTransparency = 0.18,
                auraRate = 7,
            },
        },
    },
    -- Milestone 6 Step 28/29: bounded class attack VFX surfaces.
    TOWER_ATTACK_VFX = {
        limits = {
            maxActivePulses = 48,
            pulseLifetimeSeconds = 0.18,
        },
        byType = {
            Basic = { pulseColor = Color3.fromRGB(115, 210, 255), pulseSize = 2.8, pulseRateFloor = 0.85 },
            Rapid = { pulseColor = Color3.fromRGB(120, 255, 165), pulseSize = 2.2, pulseRateFloor = 0.24 },
            Sniper = { pulseColor = Color3.fromRGB(255, 210, 150), pulseSize = 3.2, pulseRateFloor = 1.0 },
            Support = { pulseColor = Color3.fromRGB(232, 190, 255), pulseSize = 2.6, pulseRateFloor = 1.5 },
        },
    },
    -- Milestone 7 Step 32/34: accessibility and deterministic VFX quality budgets.
    VISUAL_ACCESSIBILITY = {
        colorSafeCritical = true,
        criticalPrefix = '!!',
        reduceNonCriticalSaturation = true,
        maxTowerHighlightFillOpacity = 0.22,
        maxTowerAuraRate = 7,
        maxPulseTransparency = 0.42,
    },
    VFX_BUDGET = {
        defaultTier = 'Medium',
        touchDefaultTier = 'Low',
        tiers = {
            Low = {
                maxActivePulses = 20,
                pulseLifetimeSeconds = 0.14,
                pulseSizeMultiplier = 0.88,
                auraRateMultiplier = 0.55,
                maxAuraRate = 4,
                maxBurstPerSecond = 14,
            },
            Medium = {
                maxActivePulses = 36,
                pulseLifetimeSeconds = 0.18,
                pulseSizeMultiplier = 1.0,
                auraRateMultiplier = 0.8,
                maxAuraRate = 6,
                maxBurstPerSecond = 22,
            },
            High = {
                maxActivePulses = 52,
                pulseLifetimeSeconds = 0.22,
                pulseSizeMultiplier = 1.08,
                auraRateMultiplier = 1.0,
                maxAuraRate = 8,
                maxBurstPerSecond = 30,
            },
        },
    },
    -- Milestone 8 Step 36/37: cross-phase visual language + telemetry marker contract.
    VISUAL_PHASE_LABELS = {
        Lobby = 'Queue',
        Wave = 'Combat',
        Results = 'Results',
        Cleanup = 'Cleanup',
        Idle = 'Standby',
    },
    VISUAL_TELEMETRY = {
        enabled = true,
        minIntervalSeconds = 0.35,
        markers = {
            phase_surface = 'phase_surface',
            placement_preview = 'placement_preview',
            tower_selection = 'tower_selection',
            tower_target_mode = 'tower_target_mode',
            reject_reason = 'reject_reason',
        },
    },
    SUPPORT_TOWER_AURA_RADIUS_BY_TIER = {
        [0] = 20,
        [1] = 22,
        [2] = 24,
        [3] = 26,
    },
    SUPPORT_TOWER_ATTACK_INTERVAL_MULTIPLIER_BY_TIER = {
        [0] = 0.94,
        [1] = 0.9,
        [2] = 0.86,
        [3] = 0.82,
    },
    -- Cap aggregate support buff so stacked supports cannot break pacing.
    SUPPORT_TOWER_MIN_ATTACK_INTERVAL_MULTIPLIER = 0.75,
    TOWER_ONE_SHOT_EXCLUDED_TYPES = {
        Support = true,
    },
    -- One-shot scaling: upgraded towers are floored to at least this spawn tier's health.
    -- Default 30 means tier 1+ can one-shot the toughest enemy in this 30-enemy match.
    TOWER_ONE_SHOT_ENEMY_SPAWN_ORDINAL = 30,
    TOWER_ONE_SHOT_DAMAGE_BUFFER = 2,

    TOWER_PLACEMENT_GRID_SIZE = 4,
    PLACEMENT_SURFACE_MODE = 'AnySurfaceExceptBlocked',
    PLACEMENT_ALLOW_TERRAIN = true,
    PLACEMENT_BLOCKED_TAGS = {
        'NoBuild',
        'NoTowerPlacement',
        'Path',
        'EnemyPath',
    },
    PLACEMENT_BLOCKED_FOLDER_NAMES = {
        'EnemySpawns',
        'Waypoints',
        'Base',
    },
    TOWER_MAX_PLACE_DISTANCE = 45,
    TOWER_MAX_INTERACT_DISTANCE = 55,
    TOWER_FOOTPRINT_BY_TYPE = {
        Basic = { x = 3, z = 3, y = 4 },
        Rapid = { x = 3, z = 4, y = 4 },
        Sniper = { x = 2, z = 4, y = 5 },
        Support = { x = 4, z = 4, y = 4 },
    },
    PLACEMENT_PREVIEW_VISUALS = {
        validColor = Color3.fromRGB(90, 220, 110),
        invalidColor = Color3.fromRGB(225, 90, 90),
        ghostValidTransparency = 0.5,
        ghostInvalidTransparency = 0.7,
        rangeTransparency = 0.72,
        footprintTransparency = 0.78,
    },
    TOWER_MAX_PER_PLAYER = 25,
    TOWER_MAX_TOTAL = 100,
    TOWER_SELL_REFUND_RATIO = 0.7,
    REQUEST_MAX_PAYLOAD_KEYS = 16,
    WORLD_MAX_ABS_POSITION = 50000,
    REQUEST_DEDUP_WINDOW_SECONDS = 10,
    STARTING_CURRENCY = 350,
    KILL_REWARD = 14,
    KILL_REWARD_PER_ROUND = 3,
    ROUND_REWARD_PER_ROUND = 5,
    ROUND_REWARDS = {
        Victory = 50,
        Defeat = 35,
    },
    -- Milestone 5 Step 23/24: baseline mission framework + reward surfaces.
    MISSION_DEFINITIONS = {
        {
            id = 'clear_round',
            missionType = 'round_clear',
            required = 1,
            reward = 20,
            description = 'Clear the current round.',
        },
        {
            id = 'kill_10',
            missionType = 'kills',
            required = 10,
            reward = 15,
            description = 'Defeat at least 10 enemies this round.',
        },
        {
            id = 'no_leak',
            missionType = 'no_leak',
            required = 1,
            reward = 25,
            description = 'Finish the round with no leaks.',
        },
    },
    DEBUG_CLIENT_EVENT_LOGS = false,
    DEBUG_ROUND_STATUS_LOGS = false,
    DEBUG_ROUND_STATUS_MIN_INTERVAL_SECONDS = 1,
    UI_SAFE_AREA_PADDING = 8,
    UI_TOUCH_MIN_BUTTON_WIDTH = 150,
    UI_TOUCH_MIN_BUTTON_HEIGHT = 48,
    HUD_LAYOUT = {
        topLeftStack = {
            matchEntryPanelWidth = 340,
            matchEntryPanelHeight = 124,
            matchEntryPanelOffsetX = 12,
            matchEntryPanelOffsetY = 15,
            minTopClearanceFromCoreGui = 15,
            coreUiReservedWidth = 190,
            coreUiReservedHeight = 56,
            coreUiReservedGap = 12,
            panelVerticalGap = 10,
            notificationPanelMinTopOffset = 48,
            notificationViewportDropScale = 0.05,
            notificationLeftOffset = 10,
            notificationBottomMargin = 8,
            notificationMinVisibleHeight = 72,
        },
    },
    -- Milestone 7 Step 33: responsive combat strip for narrow/notched screens.
    HUD_COMBAT_STRIP_LAYOUT = {
        desktop = {
            minWidth = 860,
            rightMargin = 14,
            topOffset = 2,
        },
        touch = {
            minWidth = 360,
            rightMargin = 10,
            topOffset = 4,
        },
    },
    -- Inventory/loadout strip tuning.
    -- scale: 1.0 = baseline size, 0.8 = 20% smaller.
    -- dropViewportPct: fraction of screen height to move downward.
    INVENTORY_HUD_LAYOUT = {
        scale = 0.8,
        dropViewportPct = 0.05,
    },
    DEFAULT_STAGE_ID = 'brown',
    DEFAULT_ACT_ID = 'Act1',
    STAGE_SELECTION_OPTIONS = {
        {
            stageId = 'brown',
            stageLabel = 'Brown',
            acts = {
                {
                    actId = 'Act1',
                    actLabel = 'Act 1',
                    unlocked = true,
                    rewardPreview = '+50 clear / +20 missions',
                },
                {
                    actId = 'Act2',
                    actLabel = 'Act 2',
                    unlocked = false,
                    lockReason = 'Unlock after Act 1 clear',
                    rewardPreview = '+70 clear / +35 missions',
                },
            },
        },
        {
            stageId = 'green',
            stageLabel = 'Green',
            acts = {
                {
                    actId = 'Act1',
                    actLabel = 'Act 1',
                    unlocked = true,
                    rewardPreview = '+50 clear / +20 missions',
                },
                {
                    actId = 'Act2',
                    actLabel = 'Act 2',
                    unlocked = false,
                    lockReason = 'Unlock after Act 1 clear',
                    rewardPreview = '+70 clear / +35 missions',
                },
            },
        },
        {
            stageId = 'red',
            stageLabel = 'Red',
            acts = {
                {
                    actId = 'Act1',
                    actLabel = 'Act 1',
                    unlocked = true,
                    rewardPreview = '+50 clear / +20 missions',
                },
                {
                    actId = 'Act2',
                    actLabel = 'Act 2',
                    unlocked = false,
                    lockReason = 'Unlock after Act 1 clear',
                    rewardPreview = '+70 clear / +35 missions',
                },
            },
        },
        {
            stageId = 'yellow',
            stageLabel = 'Yellow',
            acts = {
                {
                    actId = 'Act1',
                    actLabel = 'Act 1',
                    unlocked = true,
                    rewardPreview = '+50 clear / +20 missions',
                },
                {
                    actId = 'Act2',
                    actLabel = 'Act 2',
                    unlocked = false,
                    lockReason = 'Unlock after Act 1 clear',
                    rewardPreview = '+70 clear / +35 missions',
                },
            },
        },
    },
    CLIENT_USE_HUD_CONTROLLER = true,
    HUD_NOTIFICATION_CHANNEL_HISTORY = {
        critical = 2,
        tactical = 2,
        routine = 2,
    },
    HUD_NOTIFICATION_CHANNEL_MIN_INTERVAL_SECONDS = {
        critical = 0.0,
        tactical = 0.2,
        routine = 0.6,
    },
    HUD_LEAK_NOTIFY_COOLDOWN_SECONDS = 1.5,
    HUD_CURRENCY_BATCH_MIN_GAIN = 25,
    HUD_CURRENCY_BATCH_MAX_DELAY_SECONDS = 1.0,

    REQUEST_RATE_LIMITS = {
        RequestCreateMatch = { maxRequests = 2, perSeconds = 5 },
        RequestReady = { maxRequests = 4, perSeconds = 5 },
        RequestVoteDifficulty = { maxRequests = 4, perSeconds = 10 },
        RequestPlaceTower = { maxRequests = 8, perSeconds = 5 },
        RequestUpgradeTower = { maxRequests = 8, perSeconds = 5 },
        RequestSellTower = { maxRequests = 8, perSeconds = 5 },
        RequestSetTowerTargetMode = { maxRequests = 12, perSeconds = 5 },
        RequestVoteRestart = { maxRequests = 4, perSeconds = 10 },
    },

    MILESTONES = {
        Kills = { 10, 50, 100 },
        Waves = { 1, 5, 10 },
        RoundClears = { 1, 3, 5 },
    },
}

return GameConfig
