# TowerDefence_v3 Guidelines

Local source-of-truth for this project, aligned to the active 40-step roadmap.

## Canonical References

- Primary implementation guideline: `towerdefenceguidelines.md`
- Active execution roadmap: `MilestonePromptGuide_40Step_ModelsVisualsHUD.md`
- Progress tracker and hard-stop evidence log: `PROGRESS.md`

## Core Rules

- Keep gameplay server-authoritative; clients send intent only.
- Keep all remote contracts centralized in `src/shared/Net.luau`.
- Keep tunables and contract-facing constants centralized in `src/shared/GameConfig.luau`.
- Keep explicit `start()` / `stop()` lifecycle boundaries across services/controllers.
- Validate required world and storage dependencies at startup before match flow begins.
- Enforce payload validation and per-player request rate limits on gameplay remotes.

## Milestone 1 Focus (Steps 1-5)

- Establish visual direction baseline for model readability and HUD clarity.
- Define a canonical tower model spec and deterministic storage schema.
- Add model import hygiene checks with actionable diagnostics.
- Do not advance beyond Step 5 until hard-stop evidence is logged in `PROGRESS.md`.
