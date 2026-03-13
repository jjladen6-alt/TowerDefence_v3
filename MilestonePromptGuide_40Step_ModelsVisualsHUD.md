# TowerDefence_v3 Milestone Prompt Guide (40 Steps) - Tower Models + Visual HUD Track

Last updated: 2026-03-08

This roadmap is the canonical build track for tower model quality, visual readability, and HUD flows that support model/combat interactions. It targets the desired player experience of `Play -> Stage -> Ready`, readable placement controls, clear in-wave combat framing, and strong selected-tower controls.

## Global Rules

1. Read `towerdefenceguidelines.md` before each implementation step.
2. Keep gameplay server-authoritative; clients send intent only.
3. Keep all network contracts in `src/shared/Net.luau`.
4. Keep all tunables in `src/shared/GameConfig.luau`.
5. Keep explicit `start()` and `stop()` lifecycle boundaries.
6. Do not skip hard stops. Fix blockers before continuing.

---

## Experience Targets (Reference Alignment)

- Clear match-entry CTA chain: `Play` -> `Stage` -> `Ready`.
- Placement readability: range ring, valid/invalid ghost, and explicit place/rotate/cancel controls.
- Combat readability: visible wave/base/timer strip with game speed and auto-skip state.
- Tower interaction quality: selected tower card with sell, target priority, and upgrade clarity.
- Bright stylized look with controlled FX noise and tactical contrast.

---

## Milestone 1 - Visual Direction And Tower Model Baseline (Steps 1-5)

### Step 1 - Establish visual direction baseline
- Define a compact visual style sheet for saturation, glow usage, contrast hierarchy, and readability priorities.

### Step 2 - Define canonical tower model spec
- Standardize tower model requirements (pivot at base center, orientation, scale, naming, required attachments).

### Step 3 - Normalize tower model storage schema
- Standardize folder and model layout in `ServerStorage/TowerModels` for deterministic lookup and validation.

### Step 4 - Add model import hygiene checks
- Add validation for script stripping, required part presence, and attachment contract completeness on imported tower assets.

### Step 5 - Hard Stop (Milestone 1)
- Verify all current base towers satisfy schema and load cleanly in runtime.
- Verify failed imports produce actionable diagnostics.
- Log PASS/FAIL evidence in `PROGRESS.md`.

---

## Milestone 2 - Lobby CTA And Match Entry HUD (Steps 6-10)

### Step 6 - Implement prominent Play CTA treatment
- Add a high-visibility `Play` affordance pattern in world/HUD with clear active/inactive feedback.

### Step 7 - Build Stage selection modal flow
- Implement `Stage` panel structure (stage list, act list, locks, rewards preview, state labels).

### Step 8 - Build Ready flow status surfaces
- Implement `Ready` interaction state with queue/roster indicators and deterministic lock messaging.

### Step 9 - Add match-entry transition messaging
- Add concise reason-coded transition and failure feedback from lobby flow into combat load.

### Step 10 - Hard Stop (Milestone 2)
- Verify first-time user flow `Play -> Stage -> Ready` is clear and deterministic.
- Verify lock/failure states remain readable and non-ambiguous.
- Log PASS/FAIL evidence in `PROGRESS.md`.

---

## Milestone 3 - Placement UX And Preview Visuals (Steps 11-15)

### Step 11 - Build placement ghost validity states
- Add visible valid/invalid placement ghost visuals (material, color, opacity, edge emphasis).

### Step 12 - Add range and footprint previews
- Show range ring and footprint preview tied to selected tower type and rotation.

### Step 13 - Add explicit placement controls HUD
- Add on-screen place/rotate/cancel controls with desktop key prompts and touch parity.

### Step 14 - Add precise invalid-placement feedback
- Map server reject reason codes to concise near-cursor/tap guidance copy.

### Step 15 - Hard Stop (Milestone 3)
- Verify invalid local placement submits are reduced.
- Verify controls are understandable on desktop and touch without extra notes.
- Log PASS/FAIL evidence in `PROGRESS.md`.

---

## Milestone 4 - Combat HUD Framing And Wave Readability (Steps 16-20)

### Step 16 - Build top combat status strip
- Add/normalize wave number, base health, countdown, and current mode in a persistent top strip.

### Step 17 - Add game-speed and auto-skip clarity
- Present speed controls and auto-skip state with clear active indicators and phase-safe behavior.

### Step 18 - Improve lane and spawn readability cues
- Add clean lane emphasis and spawn readability cues that do not obscure path visibility.

### Step 19 - Enforce visual priority hierarchy in combat
- Ensure critical tactical info (base danger, elites, selected tower context) has higher prominence than decorative FX.

### Step 20 - Hard Stop (Milestone 4)
- Verify wave progression is readable at a glance during dense encounters.
- Verify no key combat controls are visually hidden or ambiguous.
- Log PASS/FAIL evidence in `PROGRESS.md`.

---

## Milestone 5 - Tower Interaction HUD V1 (Steps 21-25)

### Step 21 - Build selected tower card shell
- Add selected tower panel with name, portrait, level/tier, and core combat stats.

### Step 22 - Wire sell/upgrade/priority controls
- Add explicit sell/priority/upgrade controls with stateful disabled reasons and touch/keyboard hints.

### Step 23 - Add upgrade delta previews
- Show projected stat deltas and cost impact before player confirms upgrade.

### Step 24 - Complete target mode controls
- Expose explicit target mode controls (`First`, `Last`, `Closest`) and active-state feedback.

### Step 25 - Hard Stop (Milestone 5)
- Verify players can manage placed towers without hidden controls.
- Verify target mode state remains synchronized with server-authoritative updates.
- Log PASS/FAIL evidence in `PROGRESS.md`.

---

## Milestone 6 - Tower Upgrade Visual Progression And Combat FX (Steps 26-30)

### Step 26 - Define per-tier visual progression language
- Define tiered model progression for each tower (mesh/accessory/aura identity by tier).

### Step 27 - Implement deterministic upgrade visuals
- Synchronize upgrade visual transitions with server-owned tower state updates.

### Step 28 - Add per-class attack VFX/SFX readability pass
- Add muzzle/projectile/impact feedback per tower class with bounded intensity and timing.

### Step 29 - Guarantee cleanup of visuals on remove/sell
- Ensure sold/removed towers clear all attached effects, emitters, and temporary visuals.

### Step 30 - Hard Stop (Milestone 6)
- Verify tier progression is obvious and consistent across tower classes.
- Verify no lingering upgrade/combat effects remain after sell/remove.
- Log PASS/FAIL evidence in `PROGRESS.md`.

---

## Milestone 7 - Contrast, Accessibility, And Performance Safety (Steps 31-35)

### Step 31 - Improve enemy vs tower contrast
- Tune materials/colors/outlines so enemies and tower effects remain separable in mixed combat.

### Step 32 - Add accessibility-focused color/effect checks
- Validate critical states with color-safe alternatives and effect-intensity constraints.

### Step 33 - Apply safe-area and mobile spacing polish
- Ensure major HUD surfaces fit safe areas and avoid overlap on narrow/notched screens.

### Step 34 - Add VFX budget tiers
- Add low/medium/high quality caps for particles/trails and enforce peak burst limits.

### Step 35 - Hard Stop (Milestone 7)
- Verify readability and FPS remain within target under high tower/enemy density.
- Verify mobile and desktop retain tactical clarity parity.
- Log PASS/FAIL evidence in `PROGRESS.md`.

---

## Milestone 8 - Final Integration, Evidence, And Release Visual Gate (Steps 36-40)

### Step 36 - Run full visual consistency pass
- Verify style and clarity consistency across lobby, placement, combat, and results surfaces.

### Step 37 - Normalize visual telemetry markers
- Ensure consistent visual telemetry for placement clarity, tower panel interactions, and rejection reasons.

### Step 38 - Execute phase-based evidence capture checklist
- Capture screenshots/video evidence for entry flow, placement, combat, upgrades, and end-state cleanup.

### Step 39 - Run multiplayer visual polish soak
- Validate queue-to-wave transitions, panel stability, and clarity in multiplayer sessions.

### Step 40 - Hard Stop (Milestone 8 / Launch Visual Gate)
- Confirm go/no-go based on clarity, determinism, and visual performance evidence.
- Confirm release-gate and cleanup checks remain PASS.
- Record final decision and evidence in `PROGRESS.md`.

---

## Hard-Stop Standard (Apply At Steps 5, 10, 15, 20, 25, 30, 35, 40)

- Capture `[ReleaseGate][Round]` and `[ReleaseGate][Session]` evidence.
- Capture visual milestone evidence (screenshots/videos and concise validation notes).
- Verify cleanup integrity (towers/enemies/round entities reset correctly).
- Verify no drift from server-authoritative contract rules (`Net`, `GameConfig`, request validation).
- Log PASS/FAIL with concise evidence in `PROGRESS.md` before advancing.

---

## Suggested Execution Prompt Template

Use this each step:

```text
Read towerdefenceguidelines.md first.
Implement only Step <N> from MilestonePromptGuide_40Step_ModelsVisualsHUD.md.
Keep server-authoritative contracts and Net/GameConfig centralization.
Do not skip hard-stop gates.
Update PROGRESS.md with evidence at hard stops.
```

## Done Criteria For This Guide

- Exactly 40 implementation steps are present.
- Hard stop appears after every 5 steps.
- Scope prioritizes tower models, visual readability, and HUD support flows.
- All milestone goals preserve deterministic, server-authoritative behavior.
