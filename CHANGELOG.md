# Changelog

All notable changes to WindrosePvP will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2024-01-01

### Added
- Core PvP duel system with challenge/accept/decline flow
- Shadow damage system (property-based health modification)
- Arena zone enforcement with teleport-back
- RCON command interface (pvp_challenge, pvp_accept, pvp_decline, pvp_surrender, pvp_status, pvp_health, pvp_duels, pvp_cancel, pvp_test, pvp_config)
- GAS overwrite detection and re-application
- Auto-revive system for duel losers
- Event bus for inter-module communication
- Phase 0 discovery scripts for server-side property detection
- Comprehensive self-test suite
- Configuration hot-reload via RCON

### Fixed
- duel_request.lua: Fixed crash on challenge creation where `challenge.target` was nil (variable not in scope)
- health_manager.lua: Wrapped all `player:IsValid()` calls in pcall for GC safety
- duel_request.lua: Wrapped all `player:IsValid()` calls in pcall for GC safety
- area_restriction.lua: Wrapped `player:IsValid()` call in pcall for GC safety
- damage_router.lua: Wrapped `target:IsValid()` call in pcall for GC safety
- event_bus.lua: Fixed handler leak where `run_self_tests()` re-registered test handlers on each call
- area_restriction.lua: Fixed WindrosePlus API resolution to use lazy loading instead of eager capture
- damage_router.lua: Fixed missing closing brace in destroy() stats table
- health_manager.lua: Fixed extra `end` block and `goto continue` label (renamed to `goto skip_player`)
- pvp_state_manager.lua: Simplified dead-code disconnect reason logic

### Added
- Project files: `.luarc.json`, `.gitignore`, `LICENSE` (MIT), `CHANGELOG.md`
- EmmyLua type annotations across all Phase 1 modules

### Changed
- Config default: MELEE_HOOK_WORKS = false (set by Phase 0 discovery)
- Config default: GAS_HOOK_WORKS = false (set by Phase 0 discovery)