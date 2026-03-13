# TowerDefence_v3

Starter Roblox project scaffolded with Rojo, Wally, Selene, and StyLua.

## Prerequisites

- Aftman (recommended)
- Or manual installs of: Rojo, Wally, Selene, StyLua

## Project Layout

- `default.project.json` - Rojo mapping
- `wally.toml` - package/dependency config
- `selene.toml` - Luau lint config
- `stylua.toml` - formatter config
- `src/client` - client scripts
- `src/server` - server scripts
- `src/shared` - shared modules

## Quick Start

```powershell
aftman install
wally install
rojo serve
```

Then in Roblox Studio:

1. Install/run Rojo plugin.
2. Connect to `localhost:34872`.
3. Run play test.

## Lint & Format

```powershell
selene src
stylua src
```
