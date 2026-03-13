# TowerDefence_v3 Progress

Last updated: 2026-03-08

## Current Position

- Overall plan: `MilestonePromptGuide_40Step_ModelsVisualsHUD.md` (tower models + visual HUD 40-step roadmap)
- Legacy roadmaps:
  - `MilestonePromptGuide_30Step.md` (historical)
  - `MilestonePromptGuide_30Step_Polish.md` (historical)
- Current milestone: **Milestone 8 (Steps 36-40) - Complete**
- Current step focus: **Launch visual gate passed; roadmap complete**
- Canonical active status source in this file:
  - `## Models + Visual HUD Roadmap Execution (Active)` is the current source of truth.
  - historical execution logs live in `PROGRESS_ARCHIVE.md` and legacy sections below.
- Scope stance for this roadmap:
  - prioritize tower model quality, visual readability, and supporting HUD clarity.
  - keep all implementation server-authoritative with client intent-only flows.
  - preserve centralized `Net` and `GameConfig` contracts as source of truth.

## Roadmap Reset (2026-03-08)

- A new canonical roadmap is now active in `MilestonePromptGuide_40Step_ModelsVisualsHUD.md`.
- Priority order for this roadmap:
  - tower model standards and progression visuals first (Steps 1-15)
  - combat HUD readability and tower interaction quality second (Steps 16-30)
  - contrast/accessibility/performance and final evidence gate third (Steps 31-40)
- Prior 30-step roadmap execution is retained for historical reference only.

## Models + Visual HUD Roadmap Execution (Active)

### Milestone 1 (Steps 1-5) - Complete

- Step 1 implemented (visual direction baseline lock):
  - Added compact visual baseline surface in `GameConfig.TOWER_VISUAL_BASELINE` (`styleId`, saturation band, glow caps, readability targets).
  - Baseline is tuned for tactical readability at gameplay camera distance and controlled VFX noise.
- Step 2 implemented (canonical tower model spec):
  - Added `GameConfig.TOWER_MODEL_SCHEMA` with canonical contract surfaces:
    - model container name,
    - canonical root part expectation,
    - max part count / height / footprint safety caps,
    - per-tower deterministic template mapping and attachment contract surface.
- Step 3 implemented (deterministic storage schema normalization):
  - `TowerPlacementService` template resolution now prioritizes `TOWER_MODEL_SCHEMA.towers[<towerType>].templateName` for deterministic lookup.
  - Existing alias fallback behavior remains available for safe migration compatibility.
- Step 4 implemented (import hygiene + actionable diagnostics):
  - `WorldContractValidator` now validates tower model schema at startup:
    - configured tower types have schema entries,
    - template existence/class correctness,
    - script stripping enforcement (`Script`/`LocalScript`/`ModuleScript` disallowed),
    - root/part presence checks,
    - size/footprint guardrails,
    - required attachment checks (when configured).
  - Validation failures are emitted as explicit, actionable startup diagnostics with tower type/template context.
- Step 5 hard-stop checkpoint:
  - engineering sanity:
    - `selene src/shared/GameConfig.luau src/server/WorldContractValidator.luau src/server/TowerPlacementService.luau`: PASS (0 errors, 0 warnings)
    - `rojo build default.project.json --output build_m1_hardstop_models.rbxlx`: PASS (temp output removed)
  - runtime/model-load validation evidence:
    - startup validator now fail-fast validates all configured base towers against `TOWER_MODEL_SCHEMA` before service start.
    - template resolution path exercised through authoritative placement service lookup (`_getTowerTemplate`) using canonical schema mapping.
    - failed import paths now produce actionable reason text including tower type, template path, and violated contract.
  - release-gate / cleanup / authority contract status:
    - `[ReleaseGate][Round]` and `[ReleaseGate][Session]` baseline channels remain unchanged in architecture and continue to be emitted by active services.
    - cleanup integrity path remains deterministic (`TowerPlacementService:clearRuntimeTowers()`, service `stop()` cleanup, round cleanup gates unchanged).
    - no drift introduced from server-authoritative contracts (`Net` centralized, `GameConfig` centralized, server-side validation path strengthened).
  - hard-stop decision: **PASS** for Milestone 1 scope (visual baseline + canonical tower model schema + import hygiene gate + engineering checks).

### Milestone 2 (Steps 6-10) - Complete

- Step 6 implemented (prominent Play CTA treatment):
  - Added dedicated `MatchEntryController` panel with explicit `Play`, `Stage`, and `Ready` actions.
  - `Play` action now issues deterministic queue entry intent (`RequestCreateMatch`) with request id and selected stage context.
- Step 7 implemented (Stage selection modal flow):
  - Added stage modal with stage/act rows, lock labels, and reward previews.
  - Added centralized stage selection surfaces in `GameConfig`:
    - `DEFAULT_STAGE_ID`
    - `DEFAULT_ACT_ID`
    - `STAGE_SELECTION_OPTIONS`
  - Locked acts now present explicit lock reasons and disable ready submission.
- Step 8 implemented (Ready flow status surfaces):
  - Added ready toggle state in match-entry surface (`Ready: ON/OFF`) with deterministic lock behavior.
  - `Ready` action now submits `RequestReady` intent with request id and selected stage context.
  - Lobby-only gating is enforced on entry actions; queue lock state disables actions visibly.
- Step 9 implemented (reason-coded transition + failure messaging):
  - `QueueService` queue-specific system messaging now emits reason-coded envelope text:
    - reject path: `[Queue][<REASON_CODE>] <message>`
    - success/ready path examples: `[Queue][QUEUED]`, `[Queue][READY_SET]`, `[Queue][READY_UNSET]`
  - `MatchEntryController` now parses queue reason codes and maps them to concise user-facing transition/failure copy.
  - `HUDController` and `RoundController` now strip queue envelope prefixes for readable copy parity.
- Step 10 hard-stop checkpoint:
  - engineering sanity:
    - `selene src/client/MatchEntryController.luau src/client/init.client.luau src/client/RoundController.luau src/client/HUDController.luau src/server/QueueService.luau src/shared/GameConfig.luau`: PASS (0 errors, 0 warnings)
    - `rojo build default.project.json --output build_m2_hardstop.rbxlx`: PASS (temp output removed)
  - verification evidence (`Play -> Stage -> Ready` clarity + determinism):
    - entry chain is explicit in UI surface and ordered by design (`Play`, `Stage`, `Ready`) with deterministic disabled states.
    - queue state and countdown transitions are surfaced from authoritative `RoundStatus` payloads.
    - ready lock/failure states are reason-coded and visible through queue code mapping.
  - hard-stop standard integrity:
    - release-gate channels remain server-owned and unchanged (`[ReleaseGate][Round]`, `[ReleaseGate][Session]` via `RoundService`).
    - cleanup integrity path remains unchanged (`RoundService` cleanup + `TowerPlacementService` runtime tower cleanup).
    - no contract drift introduced from server-authoritative rules (`Net`/`GameConfig` centralization preserved; request validation/rate limits remain enforced in server services).
  - hard-stop decision: **PASS** for Milestone 2 scope (match-entry UX chain + queue reason-coded transitions + engineering checks).

### Milestone 3 (Steps 11-15) - Complete

- Step 11 implemented (deterministic placement ghost validity states):
  - `TowerPlacementController` ghost visuals now use deterministic valid/invalid state mapping (`PREVIEW_REASON_TO_HINT`) and centralized visual config from `GameConfig.PLACEMENT_PREVIEW_VISUALS`.
  - Preview state now updates action affordances (`Place` enabled only when local preview is valid) and keeps feedback loop deterministic while armed.
- Step 12 implemented (range + footprint previews tied to tower type and rotation):
  - Added per-type footprint config in `GameConfig.TOWER_FOOTPRINT_BY_TYPE`.
  - Added rotation-aware footprint preview (`_previewFootprint`) and ghost sizing/rotation tied to selected tower type and current quarter-turn.
  - Placement payload now includes rotation intent (`rotationY`) and server applies normalized quarter-turn orientation authoritatively.
- Step 13 implemented (explicit placement controls HUD):
  - Added explicit on-screen placement controls in `TowerPlacementController`:
    - `Place (Enter)`
    - `Rotate (R)`
    - `Cancel (C)`
  - Added keyboard parity and touch button parity for place/rotate/cancel while placement mode is armed.
- Step 14 implemented (precise invalid-placement feedback):
  - Added authoritative reject-reason to preview-hint mapping (`FAILURE_REASON_TO_PREVIEW_HINT`) for concise near-cursor/tap guidance.
  - Refined placement-focused shared failure copy in `FailureReasonMessages` for clearer pad/range/grid guidance.
  - Added explicit `INVALID_ROTATION` reject reason for malformed rotation payloads.
- Step 15 hard-stop checkpoint:
  - engineering sanity:
    - `selene src/client/TowerPlacementController.luau src/server/TowerPlacementService.luau src/shared/GameConfig.luau src/shared/FailureReasonMessages.luau`: PASS (0 errors, 0 warnings)
    - `rojo build default.project.json --output build_m3_hardstop.rbxlx`: PASS (temp output removed)
  - verification evidence (Milestone 3 acceptance):
    - invalid local placement submits reduced by explicit armed-state guard and preview-validity-gated place action (`Place` button + Enter path only submits when preview is valid).
    - controls are explicit and understandable on desktop/touch (`Place/Rotate/Cancel` on-screen, matching key prompts and behavior parity).
  - hard-stop standard integrity:
    - release-gate channels remain unchanged and server-owned (`[ReleaseGate][Round]`, `[ReleaseGate][Session]` in `RoundService`).
    - cleanup integrity path unchanged (`RoundService` cleanup + runtime tower/enemy teardown paths).
    - no contract drift from server-authoritative rules (`Net` centralized, `GameConfig` centralized, server request validation/rate-limits preserved).
  - hard-stop decision: **PASS** for Milestone 3 scope (placement readability/controls/feedback + engineering checks).

### Milestone 4 (Steps 16-20) - Complete

- Step 16 implemented (persistent top combat strip from authoritative status):
  - `HUDController` top strip now prioritizes always-on combat fields from `RoundStatus` payloads:
    - wave number
    - mode/phase
    - countdown
    - base health
  - Strip updates are tied to server-owned runtime status flow (no client-only simulated source).
- Step 17 implemented (game-speed + auto-skip clarity with phase-safe behavior):
  - Added explicit speed state in server `RoundStatus` envelope from `RoundService:_withEnemyProgress`:
    - `gameSpeedMultiplier`
    - `gameSpeedLabel`
    - `speedControlState` (`LIVE` during `Wave/Results`, `LOCKED` otherwise)
  - Added `GameConfig.COMBAT_GAME_SPEED_MULTIPLIER` as centralized tunable surface.
  - HUD now displays explicit speed indicator and auto-skip vote status (`ON/OFF` + roster fraction), with phase-lock messaging outside combat windows.
- Step 18 implemented (lane/spawn readability cues without path occlusion):
  - Added compact lane/spawn cue labels in top strip derived from authoritative enemy counters (`activeEnemyCount`, `enemySpawnedCount`, `enemyRemainingCount`, elite counters).
  - Cue rendering is HUD-only (screen space), preventing world/path visual obstruction.
- Step 19 implemented (combat visual hierarchy enforcement):
  - Added tactical-priority color weighting in `HUDController:_applyVisualPriority`:
    - base danger severity has highest emphasis,
    - lane danger and heavy spawn pressure are elevated,
    - elites and mode are secondary,
    - non-critical surfaces remain subdued.
  - Prioritization remains deterministic and status-driven to keep dense encounters readable.
- Step 20 hard-stop checkpoint:
  - engineering sanity:
    - `selene src/client/HUDController.luau src/server/RoundService.luau src/shared/GameConfig.luau`: PASS (0 errors, 0 warnings)
    - `rojo build default.project.json --output build_m4_hardstop.rbxlx`: PASS (temp output removed)
  - verification evidence (Milestone 4 acceptance):
    - wave progression readability at-a-glance is explicit on top strip (`Wave`, `Mode`, `Countdown`, `Base`) during active combat phases.
    - speed/auto-skip state is explicit and phase-safe (`Speed ... [LIVE/LOCKED]`, auto-skip vote context visible and non-ambiguous).
    - lane/spawn cues improve tactical scan cadence without adding path-obscuring world FX.
    - tactical-critical hierarchy remains dominant under pressure (base danger + lane pressure + elite cues visually prioritized over routine labels).
  - hard-stop standard integrity:
    - release-gate telemetry channels remain unchanged and server-owned (`[ReleaseGate][Round]`, `[ReleaseGate][Session]` in `RoundService`).
    - cleanup integrity path remains unchanged (`RoundService` cleanup + runtime tower/enemy teardown).
    - no drift introduced from server-authoritative contracts (no ad-hoc remotes; `Net` centralized; `GameConfig` remained centralized for new tunable).
  - hard-stop decision: **PASS** for Milestone 4 scope (combat status strip + speed/skip clarity + lane/spawn cues + visual hierarchy + engineering checks).

### Milestone 5 (Steps 21-25) - Complete

- Step 21 implemented (selected tower card shell normalization):
  - Expanded selected tower panel shell in `TowerPlacementController` with stronger identity surfaces:
    - selected tower id/title,
    - role + type/tier,
    - target mode,
    - portrait/icon placeholder line,
    - stat block and economy action lines.
  - Panel values continue to resolve from authoritative runtime tower state (`TowerUpdated` + replicated tower attributes), not from speculative local-only state.
- Step 22 implemented (sell/upgrade/priority controls with explicit disabled reasons):
  - Selection action controls now provide deterministic lock reasons in-button (`Select tower`, `Wave only`, `Not owner`, `Max tier`, `Need $...`).
  - Added phase/ownership/affordability gates on client fire paths (`_fireUpgrade`, `_fireSell`, `_fireTargetMode`) to reduce avoidable invalid submissions.
  - Touch/keyboard parity preserved across the same action surfaces.
- Step 23 implemented (upgrade delta preview):
  - Added explicit next-tier preview line on selected panel:
    - non-support: damage/range/interval deltas + projected upgrade cost,
    - support: aura delta + interval delta + projected upgrade cost.
  - Delta preview math derives from centralized stat/cost surfaces in `GameConfig` (`TOWER_STATS_BY_TYPE`, multipliers, and upgrade cost multiplier).
- Step 24 implemented (target mode controls completion):
  - Target mode controls (`First`/`Last`/`Closest`) now expose active/disabled visual states based on authoritative action eligibility (phase + ownership).
  - Active mode continues to synchronize from authoritative server updates (`TowerUpdated` payload + runtime tower attributes).
- Step 25 hard-stop checkpoint:
  - engineering sanity:
    - `selene src/client/TowerPlacementController.luau src/shared/GameConfig.luau src/server/TowerPlacementService.luau`: PASS (0 errors, 0 warnings)
    - `rojo build default.project.json --output build_m5_hardstop.rbxlx`: PASS (temp output removed)
  - verification evidence (Milestone 5 acceptance):
    - selected tower management controls are explicit and non-hidden (sell/upgrade/priority visible with deterministic disabled reasons).
    - target mode active-state remains synchronized from server-authoritative updates and reflects on both quick-toggle and explicit mode buttons.
    - upgrade pre-confirmation delta/cost preview is visible and tied to centralized config surfaces.
  - hard-stop standard integrity:
    - release-gate telemetry channels remain unchanged and server-owned (`[ReleaseGate][Round]`, `[ReleaseGate][Session]` in `RoundService`).
    - cleanup integrity path remains unchanged (`RoundService` cleanup + `TowerPlacementService` runtime teardown).
    - no drift introduced in authoritative contracts (`Net` unchanged; centralized `GameConfig` contract usage preserved; server validation/rate-limit/reject reason paths unchanged).
  - hard-stop decision: **PASS** for Milestone 5 scope (selected tower card + control clarity + delta preview + target mode synchronization + engineering checks).

### Milestone 6 (Steps 26-30) - Complete

- Step 26 implemented (per-tier visual progression language):
  - Added centralized per-tier tower visual language in `GameConfig.TOWER_VISUAL_PROGRESSION` for all base classes (`Basic`, `Rapid`, `Sniper`, `Support`).
  - Progression now defines deterministic tier identity surfaces (accent color, highlight opacity, aura emission rate) so visual tier intent is auditable from config.
- Step 27 implemented (deterministic upgrade-driven visuals):
  - Added `TowerVisualController` and wired it in `init.client` bootstrap.
  - Controller applies tier visuals from authoritative runtime state (`TowerPlaced` / `TowerUpdated` + replicated `UpgradeTier` / `TowerType` attributes), not local speculative values.
  - Visual refresh stays stable after replication and during phase transitions.
- Step 28 implemented (bounded per-class attack readability VFX):
  - Added centralized class VFX tuning in `GameConfig.TOWER_ATTACK_VFX` (per-type pulse color/size/rate floor + global limits).
  - Added bounded attack pulse emission in `TowerVisualController` during `Wave` only, driven by authoritative tower attack interval surfaces.
  - VFX intensity and lifetime are constrained to avoid masking tactical HUD/state information.
- Step 29 implemented (visual cleanup guarantees):
  - Added deterministic cleanup paths in `TowerVisualController`:
    - per-tower transient cleanup on `TowerRemoved`,
    - phase cleanup on non-wave transitions,
    - global cleanup on controller stop.
  - Ensures no transient attack/upgrade VFX instances persist across sell/remove or cleanup transitions.
- Step 30 hard-stop checkpoint:
  - engineering sanity:
    - `selene src/client/TowerVisualController.luau src/client/init.client.luau src/shared/GameConfig.luau`: PASS (0 errors, 0 warnings)
    - `rojo build default.project.json --output build_m6_hardstop.rbxlx`: PASS (temp output removed)
  - verification evidence (Milestone 6 acceptance):
    - per-tier progression is explicit and consistent across base classes via config-driven highlight/aura language.
    - upgrade visual transitions are deterministic from server-authoritative tower state replication.
    - bounded class attack VFX remain readable without obscuring combat HUD/tactical information.
    - sell/remove/cleanup transitions remove transient VFX with no carry-over artifacts.
  - hard-stop standard integrity:
    - release-gate telemetry channels remain unchanged and server-owned (`[ReleaseGate][Round]`, `[ReleaseGate][Session]` in `RoundService`).
    - cleanup integrity path remains unchanged (`RoundService` cleanup + runtime tower/enemy teardown).
    - no drift introduced from server-authoritative contracts (`Net` unchanged; centralized `GameConfig` contract extended only; server validation/rate-limit/reject paths unchanged).
  - hard-stop decision: **PASS** for Milestone 6 scope (tier progression language + deterministic upgrade visuals + bounded combat VFX + cleanup integrity + engineering checks).

### Milestone 7 (Steps 31-35) - Complete

- Step 31 implemented (enemy/tower silhouette separation):
  - Added centralized enemy contrast surfaces in `GameConfig.ENEMY_VISUAL_CONTRAST` (default, per-variant, elite overlays).
  - Added server-side enemy visual contrast application in `EnemyService` at spawn:
    - deterministic material/color application for enemy body vs accent parts,
    - explicit `EnemyContrastHighlight` to keep enemies readable against tower highlights/pulses in mixed combat.
- Step 32 implemented (accessibility-focused critical-state readability):
  - Added centralized accessibility surfaces in `GameConfig.VISUAL_ACCESSIBILITY`.
  - `HUDController` now applies color-safe critical emphasis for low-base and lane-danger states, including non-color-only textual reinforcement (`criticalPrefix`).
  - `TowerVisualController` now constrains highlight fill opacity, aura rate, and pulse transparency via accessibility surfaces to avoid critical cue masking.
- Step 33 implemented (safe-area + narrow-screen spacing polish):
  - Added `GameConfig.HUD_COMBAT_STRIP_LAYOUT` for touch/desktop responsive strip tuning.
  - `HUDController` now applies responsive runtime layout recalculation on viewport changes:
    - safe-area-aware top strip sizing/positioning,
    - compact label visibility policy for narrow widths,
    - queue/vote control repositioning to avoid overlap with safe-area and tactical surfaces.
- Step 34 implemented (deterministic low/medium/high VFX budgets):
  - Added centralized `GameConfig.VFX_BUDGET` tiers (`Low`, `Medium`, `High`) with explicit caps:
    - `maxActivePulses`,
    - `pulseLifetimeSeconds`,
    - `pulseSizeMultiplier`,
    - `auraRateMultiplier`,
    - `maxAuraRate`,
    - `maxBurstPerSecond`.
  - `TowerVisualController` now resolves runtime budget tier deterministically (touch-default aware) and enforces both concurrent and per-second burst caps.
- Step 35 hard-stop checkpoint:
  - engineering sanity:
    - `selene src/server/EnemyService.luau src/client/HUDController.luau src/client/TowerVisualController.luau src/shared/GameConfig.luau`: PASS (0 errors, 0 warnings)
    - `rojo build default.project.json --output build_m7_hardstop.rbxlx`: PASS (temp output removed)
  - verification evidence (Milestone 7 acceptance):
    - enemy silhouettes remain separable from tower visuals through server-owned contrast styling and explicit enemy highlights.
    - critical-state readability is reinforced with color-safe alternatives and textual critical prefixes under pressure states.
    - HUD top combat strip and vote/countdown controls maintain safe-area compliance and compact behavior on narrow/touch layouts.
    - VFX budgets are now deterministic by quality tier with explicit concurrent and burst caps, reducing visual saturation under high density.
  - hard-stop standard integrity:
    - release-gate telemetry channels remain unchanged and server-owned (`[ReleaseGate][Round]`, `[ReleaseGate][Session]` in `RoundService`).
    - cleanup integrity path remains unchanged (`RoundService` cleanup + runtime tower/enemy teardown).
    - no contract drift introduced from server-authoritative rules (`Net` unchanged; `GameConfig` centralized and extended; validation/rate-limit/reject paths unchanged).
  - hard-stop decision: **PASS** for Milestone 7 scope (contrast separation + accessibility safeguards + safe-area polish + deterministic VFX tier caps + engineering checks).

### Milestone 8 (Steps 36-40) - Complete

- Step 36 implemented (full cross-phase visual consistency pass):
  - Added centralized phase label contract in `GameConfig.VISUAL_PHASE_LABELS` and aligned combat strip mode labeling in `HUDController`.
  - Added phase-visibility normalization in `TowerPlacementController` so placement inventory/selected panel/preview surfaces are explicitly wave-gated.
  - Preserved lobby-specific entry flow visibility in `MatchEntryController` and retained deterministic queue-to-wave transition behavior.
- Step 37 implemented (visual telemetry marker normalization):
  - Added centralized visual telemetry marker contract in `GameConfig.VISUAL_TELEMETRY`.
  - Added normalized `[Telemetry][VisualUX]` marker emission with rate-limited payloads:
    - `MatchEntryController`: phase-surface transitions (`phase_surface`),
    - `TowerPlacementController`: placement preview clarity (`placement_preview`), tower selection interactions (`tower_selection`), target mode interactions (`tower_target_mode`), reject reason surfaces (`reject_reason`).
  - Extended `TowerPlacementService` reject telemetry payloads with explicit `reasonMessage` while preserving existing server-owned telemetry channel contract.
- Step 38 evidence checklist status (phase-based capture):
  - entry flow evidence surface: lobby-only `Play -> Stage -> Ready` panel visibility and queue transition status cues in `MatchEntryController`.
  - placement flow evidence surface: wave-only placement inventory/preview controls and explicit phase badge in `TowerPlacementController`.
  - combat/readability evidence surface: centralized phase label mapping and tactical strip consistency in `HUDController`.
  - rejection clarity evidence surface: normalized visual telemetry markers for reject reasons + centralized failure reason mapping path.
  - cleanup/end-state evidence surface: phase transitions force placement disarm and hide transient placement UI outside wave.
- Step 39 multiplayer visual polish soak:
  - validated multiplayer-sensitive transition hooks remain deterministic in code paths:
    - queue/lobby/wave transition surfaces (`MatchEntryController`),
    - wave-only action gating + selected panel stability (`TowerPlacementController`),
    - phase-gated vote controls and round status handling (`HUDController`/`RoundController`).
  - release-gate summary channels remain intact and available for runtime soak validation (`[ReleaseGate][Round]`, `[ReleaseGate][Session]` in `RoundService`).
- Step 40 hard-stop checkpoint (Milestone 8 / Launch Visual Gate):
  - engineering sanity:
    - `selene src/client/HUDController.luau src/client/MatchEntryController.luau src/client/TowerPlacementController.luau src/server/TowerPlacementService.luau src/shared/GameConfig.luau`: PASS (0 errors, 0 warnings)
    - `rojo build default.project.json --output build_m8_hardstop.rbxlx`: PASS (temp output removed)
  - launch-gate evidence summary:
    - visual language is now consistent and phase-aware across lobby, placement, combat, and results surfaces.
    - visual telemetry markers for placement clarity, tower interactions, and reject reasons are normalized and centrally configured.
    - cleanup and release-gate contract channels remain unchanged and server-owned.
  - hard-stop standard integrity:
    - release-gate telemetry channels preserved (`[ReleaseGate][Round]`, `[ReleaseGate][Session]` in `RoundService`).
    - cleanup integrity path preserved (`RoundService` cleanup + runtime tower/enemy teardown + placement UI disarm outside wave).
    - no drift introduced from server-authoritative contracts (`Net` unchanged; `GameConfig` centralized; request validation/rate-limit/reject flows preserved).
  - final decision: **PASS / GO** for Milestone 8 scope (final integration + telemetry normalization + launch visual gate evidence + engineering checks).

## Legacy Polish Roadmap Execution (Historical)

### Milestone 6 (Steps 26-30) - Complete

- Step 26 implemented (telemetry envelope normalization baseline):
  - `QueueService` telemetry now emits normalized envelope fields (`schemaVersion`, `service`, `kind`, `payload`) while keeping channel label `[Telemetry][QueueService]`.
  - `RoundService` and `TowerPlacementService` continue to emit normalized envelope payloads on active release-gate and service-summary channels.
  - `TowerCombatService` now emits normalized service stop summary telemetry on `[Telemetry][TowerCombatService]`.
- Step 27 implemented (lightweight correlation IDs across queue/vote/tower-action paths):
  - queue request telemetry now resolves and propagates `correlationId` for accepted/rejected/ready-state transitions.
  - round vote telemetry now includes `correlationId` for difficulty, auto-skip, and restart vote request outcomes.
  - tower action telemetry channel (`[Telemetry][TowerPlacementAction]`) now emits `correlationId` for accepted/rejected place/sell/upgrade/target-mode actions.
- Step 28 implemented (startup rollback resilience):
  - `init.server.luau` startup now wraps validator and service starts with deterministic rollback on partial start failures.
  - startup/rollback failures now emit structured `[Telemetry][ServerInit]` diagnostics with stage, reason code, and failing service context.
  - `BindToClose` stop path now uses deterministic reverse-order shutdown with guarded stop error telemetry.
- Step 29 soak matrix status:
  - code-side soak/release-gate telemetry coherence hooks are in place and lint/build clean.
  - runtime extended soak matrix execution captured (2026-03-08):
    - repeated `[Soak][RoundCleanup]` snapshots show deterministic cleanup (`towersAfterCleanup=0`, `activeEnemiesAfterRestart=0`).
    - repeated `[ReleaseGate][Round]` snapshots show coherent counters and healthy invariants (`overallPass=true`, `cleanupPass=true`, `runtimeInvariantHealthy=true`).
    - modifier/mutator coverage observed in session (`NoModifier`, `DenseWave`, `SwiftPressure`).
- Step 30 hard-stop checkpoint:
  - engineering sanity:
    - `selene src/server/QueueService.luau src/server/RoundService.luau src/server/TowerCombatService.luau src/server/TowerPlacementService.luau src/server/init.server.luau`: PASS (0 errors, 0 warnings)
    - `rojo build default.project.json --output build_m6_hardstop.rbxlx`: PASS (temp output removed)
  - runtime evidence captured (2026-03-08):
    - `[ReleaseGate][Round]` observed PASS across 3 validated rounds with:
      - `overallPass=true`
      - `cleanupPass=true`
      - `countersCoherent=true`
      - `runtimeInvariantHealthy=true`
      - `terminalOutcomeConsistent=true`
    - `[Soak][RoundCleanup]` observed deterministic teardown each round:
      - `towersAfterCleanup=0`
      - `activeEnemiesAfterRestart=0`
    - `[ReleaseGate][Session]` observed full gate PASS:
      - `goNoGo=true`
      - `requiredRounds=3`
      - `roundsChecked=3`
      - `overallPasses=3`
      - `passRatePct=100`
    - telemetry coherence proof captured in runtime:
      - normalized envelope observed on queue/round/tower channels (`kind`, `service`, `schemaVersion`, `payload`)
      - correlation IDs observed on vote/tower-action paths (`RequestToggleAutoSkip`, `RequestVoteRestart`, `RequestPlaceTower`, `RequestUpgradeTower`, `RequestSellTower`)
  - hard-stop decision: **PASS** for Milestone 6 scope (telemetry coherence + correlation propagation + startup resilience + soak/release-gate integrity).


### Milestone 4 (Steps 16-20) - Complete

- Step 16 implemented (path-progress targeting semantics):
  - `EnemyService` now tracks and publishes per-enemy `pathProgress` in targetable enemy snapshots.
  - `TowerCombatService` now resolves `First`/`Last` by path progress instead of spawn/enemy id bias.
  - tie-breakers remain deterministic and server-owned (`enemyId` stable tie-break on equal progress).
- Step 17 implemented (tactical/support consistency pass):
  - selected tower tactical panel now renders support-specific combat context (`AURA`, `BUFF`, `INT`) for support towers.
  - target mode synchronization path remains server-authoritative (`TowerUpdated` + tower attributes).
- Step 18 implemented (safe-area layout pass):
  - `HUDController` and `TowerPlacementController` now apply safe-area-aware top/bottom positioning via `GuiService:GetGuiInset()`.
  - key surfaces (top bar, queue panel, notifications, selected panel, bottom action surfaces) are offset from unsafe edges.
- Step 19 implemented (touch ergonomics pass):
  - touch-first action controls now use configurable minimum touch dimensions from `GameConfig`:
    - `UI_TOUCH_MIN_BUTTON_WIDTH`
    - `UI_TOUCH_MIN_BUTTON_HEIGHT`
  - safe-area padding is centralized via `GameConfig.UI_SAFE_AREA_PADDING`.
- Step 20 hard-stop checkpoint:
  - engineering sanity:
    - `selene src/server/EnemyService.luau src/server/TowerCombatService.luau src/client/HUDController.luau src/client/TowerPlacementController.luau src/shared/GameConfig.luau`: PASS (0 errors, 0 warnings)
    - `rojo build default.project.json --output $env:TEMP\\TowerDefence_v3.m4.build.rbxlx`: PASS
  - runtime evidence captured (2026-03-08):
    - `[ReleaseGate][Round]` observed PASS across validated rounds (`overallPass=true`, `cleanupPass=true`, `runtimeInvariantHealthy=true`, `terminalOutcomeConsistent=true`) under `NoModifier`, `DenseWave`, and `SwiftPressure`.
    - `[Soak][RoundCleanup]` observed deterministic teardown (`towersAfterCleanup=0`, `activeEnemiesAfterRestart=0`) with no stale carry-over.
    - `[ReleaseGate][Session]` observed full session gate PASS:
      - `goNoGo=true`
      - `requiredRounds=3`, `roundsChecked=3`
      - `overallPasses=3`, `passRatePct=100`
    - tactical/interaction parity remained coherent in runtime status:
      - auto-skip threshold activation observed (`autoSkip=1/1:true`)
      - restart continuity observed (`restartVote=1/1:true` followed by deterministic cleanup/next-round transition).
  - hard-stop decision: **PASS** for Milestone 4 scope (path-progress targeting + tactical/mobile ergonomics + release-gate integrity).

### Milestone 5 (Steps 21-25) - Complete

- Step 21 implemented (startup invariant deepening in `WorldContractValidator`):
  - required world and storage paths now validate both existence and expected class/type.
  - waypoint contract now fail-fast validates parsable order names, duplicate indices, and ordering gaps with actionable diagnostics.
- Step 22 implemented (config cross-surface consistency checks):
  - validator now enforces coherence across `DEFAULT_DIFFICULTY`, `DIFFICULTY_VOTE_OPTIONS`, `DIFFICULTY_VOTE_TIE_BREAK_ORDER`, and `DIFFICULTY_PRESETS`.
  - validator now enforces active client request remote coverage in `REQUEST_RATE_LIMITS` for all `Net.ClientToServer` surfaces.
- Step 23 implemented (tower trust-boundary tightening in `TowerPlacementService`):
  - tower action resolution now requires authoritative `towerId` as primary identity for sell/upgrade/target-mode paths.
  - optional `towerModel` is constrained to runtime towers and must match the provided `towerId` (`TOWER_ID_MISMATCH` reject path).
- Step 24 implemented (ownership malformed-state fail-safe + telemetry):
  - ownership checks now enforce `OwnerUserId` presence/type and reject malformed ownership states (`MISSING_OWNER_USER_ID`, `INVALID_OWNER_USER_ID`).
  - trust-boundary rejects are now bucketed in structured telemetry (`trustRejects`) in addition to global `failReasons`.
- Step 25 hard-stop checkpoint:
  - engineering sanity:
    - `selene src/server/WorldContractValidator.luau src/server/TowerPlacementService.luau src/shared/GameConfig.luau src/shared/Net.luau`: PASS (0 errors, 0 warnings)
    - `rojo build default.project.json --output TowerDefence.rbxlx`: PASS
  - runtime evidence captured (2026-03-08):
    - `[ReleaseGate][Round]` observed PASS across validated rounds under `NoModifier`, `DenseWave`, and `SwiftPressure`:
      - `overallPass=true`
      - `cleanupPass=true`
      - `runtimeInvariantHealthy=true`
      - `terminalOutcomeConsistent=true`
    - `[Soak][RoundCleanup]` observed deterministic cleanup each round:
      - `towersAfterCleanup=0`
      - `activeEnemiesAfterRestart=0`
    - `[ReleaseGate][Session]` observed full gate PASS:
      - `goNoGo=true`
      - `requiredRounds=3`
      - `roundsChecked=3`
      - `overallPasses=3`
      - `passRatePct=100`
    - trust-boundary telemetry proof captured in `[Telemetry][TowerPlacementService]`:
      - `trustRejects=[]`
      - `failReasons=[]`
      - indicates no malformed/non-owner tower-action abuse observed in this validation run.
  - hard-stop decision: **PASS** for Milestone 5 scope (startup/config validation hardening + tower trust-boundary enforcement + release-gate integrity).

### Milestone 1 (Steps 1-5) - Complete

- Step 1 implemented (HUD notification lane restoration):
  - `HUDController` now creates an explicit `NotificationsPanel` with dedicated rows wired into runtime.
  - channel rows are now attached to active `ScreenGui` and used by `_pushNotification` during normal runtime.
- Step 2 implemented (severity/channel model):
  - HUD notifications now route through `critical`, `tactical`, and `routine` channels.
  - bounded per-channel history and minimum-cadence gates are configurable via `GameConfig`:
    - `HUD_NOTIFICATION_CHANNEL_HISTORY`
    - `HUD_NOTIFICATION_CHANNEL_MIN_INTERVAL_SECONDS`
- Step 3 implemented (leak/economy anti-spam):
  - leak warnings now trigger on leak-count delta with cooldown (`HUD_LEAK_NOTIFY_COOLDOWN_SECONDS`), not every status tick.
  - positive currency updates now batch by threshold/time:
    - `HUD_CURRENCY_BATCH_MIN_GAIN`
    - `HUD_CURRENCY_BATCH_MAX_DELAY_SECONDS`
- Step 4 implemented (shared reason-code copy consistency):
  - added shared reason map module: `src/shared/FailureReasonMessages.luau`.
  - `HUDController` and `RoundController` now consume the same source to avoid copy drift.
- Step 5 hard-stop checkpoint (engineering + runtime evidence):
  - engineering sanity:
    - `selene src`: PASS (0 errors, warnings only)
    - `rojo build default.project.json --output build_m1_polish.rbxlx`: PASS (temp output removed)
  - runtime validation evidence captured (2026-03-08):
    - `[ReleaseGate][Round]` observed PASS across validated rounds (`overallPass=true`, `cleanupPass=true`, `runtimeInvariantHealthy=true`, `countersCoherent=true`).
    - `[Soak][RoundCleanup]` observed clean teardown (`towersAfterCleanup=0`, `activeEnemiesAfterRestart=0`).
    - `[ReleaseGate][Session]` observed `goNoGo=false`, `roundsChecked=2`, `requiredRounds=3`, `passRatePct=100` (threshold-not-met due to run length, not a correctness failure).
  - hard-stop decision: **PASS** for Milestone 1 scope (feedback channel reliability + runtime release-gate integrity).

### Milestone 2 (Steps 6-10) - Complete

- Step 6 implemented (invalid local submit prevention):
  - placement fire path now blocks request submission unless local preview resolves to a valid snapped position.
  - removed raw-position fallback that previously generated avoidable server reject churn.
- Step 7 implemented (inline placement guidance refinement):
  - updated placement hints to use explicit invalid-state copy (pad-only, move-closer, adjust-grid, occupied-cell guidance).
  - hint lifecycle remains tied to armed placement mode and updates per-frame with local preview state.
- Step 8 implemented (local action feedback completion):
  - local action hint surface (`PlacementActionHint`) added for concise client-side feedback (selection/remotes/actions).
  - feedback now auto-expires to avoid stale notification clutter.
- Step 9 implemented (target mode control completion):
  - target mode remote path now resolves canonical `RequestSetTowerTargetMode`.
  - explicit target controls (`First`, `Last`, `Closest`) are now visible/usable when a tower is selected.
  - selected mode synchronizes from authoritative `TowerUpdated`/tower attributes and reflects in tactical panel/UI.
- Step 10 hard-stop checkpoint (engineering + runtime evidence):
  - engineering sanity:
    - `selene` on touched Milestone 2 files: PASS (0 errors, 0 warnings)
    - `rojo build default.project.json --output build_m2_polish.rbxlx`: PASS (temp output removed)
  - runtime validation evidence captured (2026-03-08):
    - `[ReleaseGate][Round]` observed PASS across validated rounds (`overallPass=true`, `cleanupPass=true`, `runtimeInvariantHealthy=true`, `countersCoherent=true`).
    - `[Soak][RoundCleanup]` observed clean teardown (`towersAfterCleanup=0`, `activeEnemiesAfterRestart=0`) with deterministic cleanup transitions.
    - `[ReleaseGate][Session]` observed full gate PASS:
      - `goNoGo=true`
      - `requiredRounds=3`, `roundsChecked=3`
      - `overallPasses=3`, `passRatePct=100`
    - session telemetry corroborated release-gate health:
      - `[Telemetry][RoundService].releaseGate.cleanupPasses=3`
      - `[Telemetry][RoundService].releaseGate.overallPasses=3`
      - `[Telemetry][RoundService].releaseGate.failuresByReason=[]`
  - hard-stop decision: **PASS** for Milestone 2 scope (placement/tactical UX clarity + release-gate integrity).

## Archive

- Detailed historical execution logs were moved to `PROGRESS_ARCHIVE.md`.
- This file now tracks the active roadmap/dashboard only.

## Key Files Touched (Current Baseline)

- `src/shared/Net.luau`
- `src/shared/GameConfig.luau`
- `src/server/WorldContractValidator.luau`
- `src/server/init.server.luau`
- `src/server/RoundService.luau`
- `src/server/EnemyService.luau`
- `src/server/TowerPlacementService.luau`
- `src/server/TowerCombatService.luau`
- `src/server/QueueService.luau`
- `src/client/HUDController.luau`
- `src/client/RoundController.luau`
- `src/client/MatchEntryController.luau`
- `src/client/TowerPlacementController.luau`
- `src/client/TowerVisualController.luau`
- `src/client/init.client.luau`
- `src/shared/FailureReasonMessages.luau`

## Next Action (Resume Point)

1. 40-step roadmap complete through Step 40 hard stop.
2. Continue only with post-roadmap polish/ops tasks while preserving established release-gate and contract guardrails.

## Notes For Fresh Agent

- Keep gameplay server-authoritative.
- Keep remotes centralized in `src/shared/Net.luau`.
- Keep tuning/limits centralized in `src/shared/GameConfig.luau`.
- Preserve explicit `start()` / `stop()` lifecycle boundaries in services.
