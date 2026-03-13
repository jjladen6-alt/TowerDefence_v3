# Tower Defence Guidelines

Canonical Tower Defence baseline for this repository.

## Scope And Status

- System baseline: `TowerDefenseStarter`
- Status: `Active/Stable`
- Source scope: consolidated from Active/Stable Tower Defence guideline docs only

## Core Architecture Rules

- Keep gameplay server-authoritative; clients send intent only.
- Keep one shared remote contract registry in `src/shared/Net.luau`.
- Keep gameplay tuning and limits in `src/shared/GameConfig.luau`.
- Keep explicit `start()` and `stop()` lifecycle methods in services/controllers.
- Validate required world/map dependencies at startup before gameplay begins.
- Enforce request validation and per-player rate limits for gameplay remotes.

## Canonical Server Services

- `src/server/RoundService.luau`
- `src/server/EnemyService.luau`
- `src/server/TowerPlacementService.luau`
- Optional in first playable:
  - `src/server/TowerCombatService.luau`
  - `src/server/EconomyService.luau`
  - `src/server/DataService.luau`

## Canonical Client Controllers

- `src/client/RoundController.luau`
- `src/client/HUDController.luau`
- `src/client/TowerPlacementController.luau`

## Required World And Storage Dependencies

- `Workspace/lobby/queuepadbrown`
- `Workspace/lobby/queuepadgreen`
- `Workspace/lobby/queuepadred`
- `Workspace/lobby/queuepadyellow`
- `Workspace/brown/spawn1`
- `Workspace/brown/EnemySpawns`
- `Workspace/brown/Waypoints`
- `Workspace/brown/Base/Core`
- `ServerStorage/EnemyModels`
- `ServerStorage/TowerModels`

## Workspace Hierarchy Contract (ColorMaps/Lobby)

- Keep one canonical root per stage in `Workspace`:
  - `Workspace/brown`
  - `Workspace/green`
  - `Workspace/red`
  - `Workspace/yellow`
  - `Workspace/lobby`
- Put required gameplay nodes directly under each canonical root (or stable child folders):
  - Stage roots must expose `spawn1`, `EnemySpawns`, `Waypoints`, and `Base/Core`.
  - Lobby root must expose `queuepadbrown`, `queuepadgreen`, `queuepadred`, `queuepadyellow`, and `SpawnLocation`.
- Avoid same-name nested wrappers like `green/Green` or `lobby/lobby/lobby` in authored assets.
  - These wrappers may appear from `.rbxmx` import/export workflows and can break direct path assumptions.
  - Normalize hierarchy after import: keep one root, move gameplay nodes to expected paths, delete wrappers.
- Queue flow uses color pads under `Workspace/lobby` (for example `queuepadbrown`); stage destination is selected by pad color + stage/act selection.
  - Selecting `green` must resolve to `stageId = "green"` at roster lock and wave start.
  - Recommended smoke check: log/verify locked stage selection before teleport and first spawn.

## Config Surface (GameConfig)

Keep live values centralized in `GameConfig`:

- Round pacing:
  - `LOBBY_DURATION`
  - `ROUND_DURATION`
  - `RESULTS_DURATION`
- Enemy pacing:
  - `ENEMY_PER_WAVE`
  - `ENEMY_SPAWN_INTERVAL_SECONDS`
  - `ENEMY_MOVE_SPEED`
- Tower baseline:
  - `TOWER_COSTS`
  - `TOWER_DEFAULT_RANGE`
  - `TOWER_DEFAULT_DAMAGE`
  - `TOWER_ATTACK_INTERVAL_SECONDS`
- Placement constraints:
  - `TOWER_PLACEMENT_GRID_SIZE`
  - `TOWER_MAX_PLACE_DISTANCE`
  - `TOWER_SELL_REFUND_RATIO`
- Remote safety:
  - gameplay request rate limit table (`REQUEST_RATE_LIMITS` or equivalent)
- Progression milestones:
  - kills, waves, and round-clear milestone groups

## Net Contract IDs

Source of truth: `src/shared/Net.luau`

### Client -> Server

- `RequestCreateMatch`
- `RequestReady`
- `RequestVoteDifficulty`
- `RequestPlaceTower`
- `RequestUpgradeTower`
- `RequestSellTower`
- `RequestSetTowerTargetMode`
- `RequestVoteRestart`

### Server -> Client

- `RoundStatus`
- `TowerPlaced`
- `TowerUpdated`
- `TowerRemoved`
- `TowerPlacementFailed`
- `SystemMessage`
- `EconomyUpdated`

## Contract Enforcement Rules

- Validate payload shape and required fields.
- Validate ownership, affordability, phase, and world constraints server-side.
- Reject invalid requests with structured reason codes.
- Never trust client-derived gameplay state.

## Startup Boot Flow

1. Load `Net` and `GameConfig`.
2. Validate required world markers/folders and storage dependencies.
3. Create/refresh `ReplicatedStorage/Remotes` from `Net` before client controllers depend on it.
4. Start lobby/round orchestration from `RoundService`.
5. Spawn enemies through `EnemyService` using deterministic progression.
6. Accept tower actions through `TowerPlacementService` with strict server checks.
7. Broadcast state updates to clients through declared `Net` events only.
8. Run explicit cleanup on round end and on server/service shutdown.

## Validation Checklist

- Lobby queue only admits eligible players.
- Enemies spawn and follow waypoint order deterministically.
- Base damage/leak outcomes are server-side only.
- Placement only succeeds on valid pads/grid cells and valid phases.
- Invalid actions return clear failure reasons (for example, via `TowerPlacementFailed`).
- Upgrade/sell/target mode requests enforce ownership and rate limits.
- Connections/runtime entities are cleaned up on round end and stop.
- Desktop and touch flows both pass smoke checks for core interactions.
- Imported map/model assets contain no runtime scripts unless explicitly reviewed and approved.

## Imported Asset Hygiene

- Treat Toolbox/imported map assets as untrusted by default.
- Strip embedded `Script`, `LocalScript`, and `ModuleScript` instances from imported environment assets before playtests.
- Keep enemy/tower models lean in early milestones; avoid bundled AI/state machine scripts if behavior is driven by project services.
- If an imported script is intentionally retained, document why and validate that it does not create remotes, call unsafe `require`, or override gameplay authority.

## Rojo + Collaboration Guardrails

- Prefer solo sync sessions when using Rojo serve; avoid Team Create live editing during active sync.
- If Team Create is required, keep one sync owner and avoid concurrent edits to Rojo-managed branches.
- On repeated Rojo reconcile errors, restart Studio and `rojo serve`, then re-sync from a clean session.

## Mobile Stance (Practical, Not Strict Mobile-First)

- Keep gameplay and validation parity between desktop and mobile.
- Require touch usability for core actions (queue, placement, upgrades, sell).
- Do not require full mobile-first UX patterns before first playable.
- Add mobile-specific UI polish iteratively after core loop and server validation are stable.

## Excluded Sources (Intentional)

The following were intentionally excluded from this file to keep it Active/Stable only:

- Active/WIP or legacy/experimental guideline systems
- project reference or transfer docs not marked as canonical Active/Stable guideline sources
- broad non-Tower Defence repository guidelines
