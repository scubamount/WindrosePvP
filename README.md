# WindrosePvP - Opt-in PvP Duel System for Windrose

A server-side Lua mod for Windrose dedicated servers that enables consensual player-versus-player dueling through shadow damage mechanics. Built for UE 5.6.1 dedicated servers with UE4SS (Unreal Engine 4 Scripting System).

## Table of Contents

1. [Overview](#overview)
2. [Features](#features)
3. [Architecture](#architecture)
4. [Installation](#installation)
5. [Configuration](#configuration)
6. [RCON Commands](#rcon-commands)
7. [Duel Flow](#duel-flow)
8. [Shadow Damage System](#shadow-damage-system)
9. [Module Documentation](#module-documentation)
10. [Development](#development)
11. [Troubleshooting](#troubleshooting)
12. [API Reference](#api-reference)
13. [License](#license)

---

## Overview

WindrosePvP is a server-side PvP mod that enables consensual dueling between players on Windrose survival servers. Unlike traditional PvP systems that modify the game's damage pipeline, WindrosePvP uses a **shadow damage system** that applies damage through direct property modification, ensuring compatibility with the game's anti-cheat and damage mechanics.

### What is Shadow Damage?

Shadow damage is a technique where the mod:
1. Intercepts combat events via UE4SS hooks
2. Applies damage directly to the player's health property
3. Blocks the original damage from the game

This approach ensures:
- **Anti-cheat compatibility**: No damage system calls that could trigger anti-cheat
- **Verifiable damage**: All damage is calculated and applied by the mod
- **Universal compatibility**: Works with any damage type (melee, ranged, explosive, etc.)

### Target Use Cases

- **Private servers**: Server operators who want controlled PvP
- **Events**: Organized PvP tournaments and battles
- **Clan wars**: Consensual clan versus clan combat
- **Practice**: Players practicing combat in safe duels

---

## Features

### Core Features

| Feature | Description |
|---------|-------------|
| **Opt-in Duels** | Both players must consent to duel - no forced PvP |
| **Challenge System** | In-game challenge/accept/decline workflow |
| **Shadow Damage** | Property-based damage application |
| **Auto-Revive** | Automatic respawn after duel ends |
| **Arena Zones** | Configurable PvP areas |
| **Full RCON** | Complete admin control via RCON |
| **Timeout Handling** | Auto-end duels after duration limit |
| **Surrender** | Players can surrender mid-duel |

### RCON Features

| Feature | Description |
|---------|-------------|
| **Status Dashboard** | View all active duels and challenges |
| **Health Checking** | Real-time health monitoring |
| **Config Hot-Reload** | Modify settings without restart |
| **Self-Tests** | Built-in diagnostic tests |
| **Statistics** | Damage routing stats |

### Configuration Options

- Arena center and radius
- Duel duration limits
- Challenge timeouts
- Auto-revive toggle and delay
- Damage message display
- Debug logging levels
- Custom health property paths

---

## Architecture

### Module Structure

```
WindrosePvP/
├── mod.json                  # Mod manifest
├── README.md               # This file
├── Content/               # Client-side UI (pak mod)
│   ├── pak_manifest.json
│   └── ui_spec.md
└── scripts/
    ├── init.lua           # Entry point, phase routing
    ├── config.lua        # Configuration
    ├── utils.lua        # Utilities, safe property access
    ├── event_bus.lua    # Internal pub/sub events
    ├── phase0/         # Discovery scripts
    │   ├── p0_sdk_dump.lua
    │   ├── p0_property_discovery.lua
    │   ├── p0_health_write_test.lua
    │   ├── p0_melee_hook_test.lua
    │   ├── p0_gas_hook_test.lua
    │   ├── p0_replication_test.lua
    │   └── p0_boarding_lifecycle.lua
    └── phase1/          # Core PvP modules
        ├── main_phase1.lua        # Orchestrator
        ├── pvp_state_manager.lua   # Duel/challenge state
        ├── health_manager.lua      # Shadow damage application
        ├── duel_request.lua       # RCON command handlers
        ├── damage_router.lua     # Combat hook interception
        └── area_restriction.lua # Arena zone enforcement
```

### Phase System

The mod uses a two-phase initialization system:

#### Phase 0: Discovery

Runs when the health property path is unknown. Includes various discovery scripts to locate the correct health property path in the game's memory.

**Scripts** (run in order):
1. `p0_sdk_dump` - Dump SDK structures
2. `p0_property_discovery` - Find health property
3. `p0_health_write_test` - Test property write
4. `p0_melee_hook_test` - Test melee hooks
5. `p0_gas_hook_test` - Test GAS hooks
6. `p0_replication_test` - Test replication
7. `p0_boarding_lifecycle` - Track boarding events

#### Phase 1: Core PvP

Loads all core PvP modules after health property is discovered.

**Dependency Order**:
```
L1: Config, Utils, EventBus (foundational)
    ↓
L2: PvPStateManager (no dependencies)
    ↓
L3: HealthManager → PvPStateManager
    ↓
L3: DuelRequest → PvPStateManager + HealthManager
    ↓
L3: AreaRestriction → PvPStateManager
    ↓
L4: DamageRouter → All above
```

### Data Flow

```
Player Input (RCON)
       ↓
DuelRequest.cmd_*()
       ↓
PvPStateManager (state)
       ↓
Challenge Created → EventBus.emit("challenge_created")
       ↓
Target Accepts → EventBus.emit("challenge_resolved")
       ↓
Duel Active → EventBus.emit("duel_created")
       ↓
Combat Event → DamageRouter.pre_melee_hook()
       ↓
PvPStateManager.is_dueling() ← Check duel state
       ↓
HealthManager.apply_damage() ← Shadow damage
       ↓
EventBus.emit("damage_applied")
       ↓
Health reaches 0 → EventBus.emit("player_died")
       ↓
Duel Ends → EventBus.emit("duel_ended")
       ↓
Auto-Revive (if enabled)
```

---

## Installation

### Server Requirements

| Requirement | Version | Notes |
|-------------|---------|-------|
| Windrose Server | UE 5.6.1 | Dedicated server |
| UE4SS | Latest | Lua mod loader |
| Lua Support | 5.3+ | Built into UE4SS |

### Prerequisites

1. **UE4SS Installation**
   
   Ensure UE4SS is installed and working:
   ```
   Content/Scripts/UE4SS.lua
   ```

2. **Server Access**
   
   Ensure RCON or console access for:
   - Loading/unloading the mod
   - Running RCON commands
   - Viewing server logs

### Install Steps

#### Step 1: Copy Files

Copy the entire `WindrosePvP` folder to your server's `Content/Scripts/` directory:

```
Windrose/
└── Content/
    └── Scripts/
        └── WindrosePvP/     ← Copy this folder
            ├── mod.json
            ├── scripts/
            │   ├── init.lua
            │   └── ...
            └── Content/
```

#### Step 2: Configure

Edit `scripts/config.lua` for your server:

```lua
-- REQUIRED: World coordinates for arena center
ARENA_CENTER = { X = 0, Y = 0, Z = 0 }

-- OPTIONAL: Property path for player health
-- Leave nil for Phase 0 discovery
HEALTH_PROPERTY_PATH = nil

-- OPTIONAL: Server-specific settings
ARENA_RADIUS = 5000
DUEL_MAX_DURATION = 600
DUEL_CHALLENGE_TIMEOUT = 60
AUTO_REVIVE_LOSER = true
AUTO_REVIVE_DELAY = 5.0
```

#### Step 3: Load the Mod

In server console or RCON:

```
lua_load WindrosePvP
```

Or restart the server to auto-load.

#### Step 4: Verify

Check server logs for:
```
[WindrosePvP] === WindrosePvP Mod v0.1.0 initializing ===
[WindrosePvP] Phase 0: Running discovery scripts...
```
or
```
[WindrosePvP] Phase 1: Loading core PvP modules...
[WindrosePvP] WindrosePvP Phase 1 initialized successfully
```

### Client-Side Pak (Optional)

For UI (challenge dialogs, health bars), build a separate pak:

1. Create UMG widgets per `Content/ui_spec.md`
2. Cook and package with UE Editor
3. Place in `Content/Paks/`

---

## Configuration

### Complete Configuration Reference

```lua
-- ===========================================================================
-- WindrosePvP Configuration
-- ===========================================================================

-- ===========================================================================
-- SECTION: Core Settings
-- ===========================================================================

MOD_NAME = "WindrosePvP"
MOD_VERSION = "0.1.0"

-- ===========================================================================
-- SECTION: Arena
-- ===========================================================================

--- World coordinates for PvP arena center
--- @type {X: number, Y: number, Z: number}
ARENA_CENTER = { X = 0, Y = 0, Z = 0 }

--- Arena radius in world units
--- @type number
ARENA_RADIUS = 5000

-- ===========================================================================
-- SECTION: Timing
-- ===========================================================================

--- Maximum duel duration in seconds
--- @type number
DUEL_MAX_DURATION = 600  -- 10 minutes

--- Challenge expiry in seconds
--- @type number  
DUEL_CHALLENGE_TIMEOUT = 60  -- 1 minute

-- ===========================================================================
-- SECTION: Health Property
-- ===========================================================================

--- Property path for player health (nil = auto-discovery)
--- @type string|nil
HEALTH_PROPERTY_PATH = nil

--- Property path for max health
--- @type string|nil
MAX_HEALTH_PROPERTY_NAME = nil

--- Whether health uses FGameplayAttributeData
--- @type boolean
HEALTH_IS_ATTRIBUTE_DATA = false

-- ===========================================================================
-- SECTION: Limits
-- ===========================================================================

--- Maximum concurrent duels
--- @type number
MAX_CONCURRENT_DUELS = 10

--- Minimum health to start duel
--- @type number
MIN_HEALTH_TO_DUEL = 1

--- Maximum damage per hit (safety cap)
--- @type number
MAX_DAMAGE_PER_HIT = 100

--- Ticks to wait before re-applying health after GAS overwrite
--- @type number
HEALTH_REAPPLY_CHECK_DELAY = 10

--- Maximum re-apply retries before giving up
--- @type number
HEALTH_REAPPLY_MAX_RETRIES = 3

-- ===========================================================================
-- SECTION: Revival
-- ===========================================================================

--- Auto-revive loser after duel
--- @type boolean
AUTO_REVIVE_LOSER = true

--- Delay before revive in seconds
--- @type number
AUTO_REVIVE_DELAY = 5.0

-- ===========================================================================
-- SECTION: Messages
-- ===========================================================================

--- Enable damage feedback messages
--- @type boolean
DAMAGE_MESSAGES_ENABLED = true

-- ===========================================================================
-- SECTION: Hooks
-- ===========================================================================

--- Whether melee hooks are working
--- @type boolean
MELEE_HOOK_WORKS = true

--- Whether GAS hooks are working
--- @type boolean
GAS_HOOK_WORKS = false

-- ===========================================================================
-- SECTION: Debug
-- ===========================================================================

--- Enable debug logging
--- @type boolean
DEBUG_LOGGING = false
```

### Hot-Reload Configuration

To change settings without restarting:

```bash
# View current config
pvp_config

# View specific key
pvp_config ARENA_RADIUS

# Set new value
pvp_config ARENA_RADIUS 10000
```

---

## RCON Commands

### Player Commands

#### `pvp_challenge <your_name> <target_name>`

Challenge a player to a duel.

**Usage**: `pvp_challenge PlayerA PlayerB`

**Parameters**:
- `your_name` - Your in-game name
- `target_name` - Player you're challenging

**Returns**:
- Success: Challenge sent message
- Error: Specific error message

**Example**:
```
> pvp_challenge Soldier Wolf
Challenge sent to Wolf (Challenge ID: 1)
Wolf must use pvp_accept to accept
```

---

#### `pvp_accept <your_name>`

Accept a pending challenge.

**Usage**: `pvp_accept PlayerB`

**Parameters**:
- `your_name` - Your in-game name

**Example**:
```
> pvp_accept Wolf
Duel accepted! You are now dueling Soldier (Duel ID: 1)
Fight to the death!
```

---

#### `pvp_decline <your_name>`

Decline a pending challenge.

**Usage**: `pvp_decline PlayerB`

**Example**:
```
> pvp_decline Wolf
Challenge declined
```

---

#### `pvp_surrender <your_name>`

Surrender from your current duel.

**Usage**: `pvp_surrender PlayerName`

**Example**:
```
> pvp_surrender Wolf
You surrendered. Soldier wins the duel!
```

---

#### `pvp_status`

Show current PvP status overview.

**Usage**: `pvp_status`

**Output includes**:
- Active duel count
- Pending challenge count
- Total duels ever

**Example**:
```
=== WindrosePvP Status ===
Active Duels: 1 / 10
Pending Challenges: 0
Total Duels Ever: 5

Active Duels:
  [1] Soldier vs Wolf (active, 120s elapsed)
```

---

#### `pvp_health [player_name]`

Show health of dueling players.

**Usage**: 
- `pvp_health` - All dueling players
- `pvp_health PlayerName` - Specific player

**Example**:
```
> pvp_health
=== Duelling Players Health ===
Wolf: 45.0 / 100.0
Soldier: 80.0 / 100.0
```

---

#### `pvp_duels`

List all active duels with details.

**Usage**: `pvp_duels`

**Example**:
```
> pvp_duels
=== Active Duels ===
[1] Soldier vs Wolf
  Status: active
  Duration: 2m 15s
```

---

### Admin Commands

#### `pvp_cancel <duel_id>`

Cancel a specific duel (admin only).

**Usage**: `pvp_cancel 1`

**Example**:
```
> pvp_cancel 1
Duel 1 cancelled by admin
```

---

#### `pvp_test`

Run all self-tests for diagnostics.

**Usage**: `pvp_test`

**Output**: Test results for each module

---

#### `pvp_config [key] [value]`

View or modify configuration.

**Usage**:
- `pvp_config` - All config
- `pvp_config KEY` - Single value
- `pvp_config KEY VALUE` - Set value

---

## Duel Flow

### Complete Duel Lifecycle

```
┌─────────────────────────────────────────────────────────────────────┐
│ 1. IDLE STATE                                                      │
│    - No active duels                                               │
│    - Players going about their business                             │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 2. CHALLENGE CREATED                                              │
│    [P1] pvp_challenge P1 P2                                       │
│    → PvPStateManager.create_challenge()                           │
│    → EventBus.emit("challenge_created")                         │
│    → Challenge stored with 60s timeout                           │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 3. CHALLENGE PENDING                                              │
│    - P2 receives system message                                   │
│    - P2 has 60s to accept                                       │
│    [P2] pvp_accept P2                                           │
│    → PvPStateManager.accept_challenge()                          │
│    → EventBus.emit("challenge_resolved")                        │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 4. DUEL ACTIVE                                                   │
│    - Both players now in PvP combat                              │
│    - DamageRouter hooks active                                   │
│    - Timer started                                             │
│    - Any combat damage → shadow damage                          │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼ (any of these conditions)
    ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
    │ Health = 0   │  │ Surrender    │  │ Timeout    │
    │ (kill)       │  │             │  │ (600s)     │
    └──────────────┘  └──────────────┘  └──────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 5. DUEL ENDED                                                   │
│    - Winner determined                                         │
│    - EventBus.emit("duel_ended")                              │
│    - Loser auto-revived (if enabled)                           │
│    - Statistics updated                                       │
└─────────────────────────────────────────────────────────────────────┘
```

### Example Duel Session

**Terminal 1 (Soldier)**:
```bash
> pvp_challenge Soldier Wolf
Challenge sent to Wolf (Challenge ID: 1)
Wolf must use pvp_accept to accept
```

**Terminal 2 (Wolf)**:
```bash
# Gets challenge notification
PvP Duel challenge from Soldier!
# Accepts
> pvp_accept Wolf
Duel accepted! You are now dueling Soldier (Duel ID: 1)
Fight to the death!
```

**Combat begins** - damage now redirected between them:

```
# Player attacks
[WindrosePvP] Damage redirected: Soldier -> Wolf for 25.0 damage (duel 1)
# Health update message
Wolf took 25.0 damage! Health: 75.0 / 100.0
```

**Duel ends**:
```
[WindrosePvP] Duel ended: Wolf wins!
# Auto-revive Soldier after 5s
[WindrosePvP] Auto-revived Soldier to 50.0 HP
```

---

## Shadow Damage System

### How Shadow Damage Works

Unlike traditional damage systems that call `TakeDamage()` or similar UFunctions, shadow damage directly modifies the player's health property:

```
Traditional Damage:
  Attack → UFunction::TakeDamage() → Health modification → Anti-cheat sees damage call

Shadow Damage:
  Attack intercepted → Read health property → Calculate new health → Write property → Block original
```

### Implementation Details

#### Step 1: Hook Registration

```lua
-- In damage_router.lua
Config.HOOK_PATHS = {
    MELEE_REMOVE_EVENT_GES = "/Script/R5MeleeAbility.RemoveEventGEs",
}

-- Register hook
Utils.safe_hook(Config.HOOK_PATHS.MELEE_REMOVE_EVENT_GES, pre_melee_hook)
```

#### Step 2: Intercept Damage

```lua
function pre_melee_hook(self, ...)
    -- Extract target, instigator, damage from hook params
    local target = M.extract_target(...)
    local damage = M.extract_damage_amount(...)
    local instigator = M.extract_instigator(self)
    
    -- Check if duel exists
    if PvPStateManager.is_dueling(target) then
        -- Verify opponent matches
        local opponent = PvPStateManager.get_opponent(instigator)
        if Utils.obj_address(target) == Utils.obj_address(opponent) then
            -- REDIRECT DAMAGE
            return false  -- Block original
        end
    end
    
    return nil  -- Allow through
end
```

#### Step 3: Apply Shadow Damage

```lua
-- In health_manager.lua
function apply_damage(player, amount, source)
    -- Read current health
    local current = get_health(player)
    
    -- Calculate new health
    local new = current - amount
    
    -- Write directly to property
    safe_write(player, HEALTH_PROPERTY_PATH, new)
    
    -- Track for GAS overwrite detection
    _pending_writes[addr] = { expected = new, tick = _tick }
    
    return true
end
```

### Handling GAS Overwrites

Gameplay Ability System (GAS) may overwrite health modifications. The mod handles this:

```lua
on_tick(dt)
    for addr, pending in pairs(_pending_writes) do
        if _tick - pending.tick >= HEALTH_REAPPLY_CHECK_DELAY then
            local actual = get_health(player)
            if math.abs(actual - pending.expected) > 0.01 then
                -- GAS overwrote!
                -- Re-apply up to HEALTH_REAPPLY_MAX_RETRIES times
                if pending.retries < MAX_RETRIES then
                    safe_write(player, health_path, pending.expected)
                    pending.retries = pending.retries + 1
                else
                    -- Give up - GAS is dominant
                end
            else
                -- Write stuck - clear pending
            end
        end
    end
end
```

---

## Module Documentation

### init.lua

Main entry point. Routes to Phase 0 or Phase 1 based on Config.

**Exports**:
- `init()` - Initialize mod
- `shutdown()` - Cleanup mod
- `get_initialization_phase()` - Get current phase
- `is_initialized()` - Check init state

---

### config.lua

Configuration module. All settings centralized here.

**Key Exports**:
- `Config` table with all settings
- `Config.apply_overrides()` - Hot-reload settings

---

### utils.lua

Safe property access utilities.

**Key Functions**:
- `Utils.safe_read(obj, path)` - Safe property read
- `Utils.safe_write(obj, path, value)` - Safe property write
- `Utils.obj_address(obj)` - Get memory address
- `Utils.player_id(obj)` - Get player name
- `Utils.find_all_of(class)` - Find all objects of class
- `Utils.format_template(template, data)` - Format messages

---

### event_bus.lua

Internal pub/sub for module communication.

**Functions**:
- `EventBus.on(event, callback)` - Subscribe
- `EventBus.emit(event, data)` - Emit event
- `EventBus.off(event, id)` - Unsubscribe

**Events**:
- `challenge_created`
- `challenge_resolved`
- `duel_created`
- `duel_ended`
- `damage_applied`
- `player_died`
- `player_revived`
- `gas_overwrite_detected`
- `gas_dominant`

---

### phase1/main_phase1.lua

Orchestrator. Initializes all Phase 1 modules in dependency order.

**Exports**:
- `init()` - Initialize all modules
- `on_tick(dt)` - Tick handler
- `shutdown()` - Cleanup all modules

---

### phase1/pvp_state_manager.lua

Manages duel and challenge state in memory.

**Exports**:
- `create_challenge(challenger, target)` - Create challenge
- `accept_challenge(id)` - Accept challenge
- `decline_challenge(id)` - Decline challenge
- `get_duel(player)` - Get player's duel
- `get_opponent(player)` - Get opponent
- `is_dueling(player)` - Check if in duel
- `get_status()` - Get global status
- `get_active_duels()` - List active duels

---

### phase1/health_manager.lua

Handles shadow damage application.

**Exports**:
- `get_health(player)` - Read health
- `get_max_health(player)` - Read max health
- `set_health(player, value)` - Set health
- `apply_damage(player, amount, source)` - Apply damage
- `heal_player(player, amount)` - Heal player
- `is_dead(player)` - Check death
- `on_tick(dt)` - Process queues

---

### phase1/duel_request.lua

RCON command handlers.

**Exports**:
- `init()` - Register commands
- `find_player_by_name(name)` - Resolve name to player
- `get_online_players()` - List players

**Commands**:
- `pvp_challenge`
- `pvp_accept`
- `pvp_decline`
- `pvp_surrender`
- `pvp_status`
- `pvp_health`
- `pvp_duels`
- `pvp_cancel`
- `pvp_test`
- `pvp_config`

---

### phase1/damage_router.lua

Hooks combat events and routes damage.

**Exports**:
- `init()` - Register hooks
- `on_tick(dt)` - Tick handler
- `pre_melee_hook(self, ...)` - Melee hook handler
- `pre_gas_hook(self, ...)` - GAS hook handler
- `get_stats()` - Get routing statistics
- `reset_stats()` - Reset stats

---

### phase1/area_restriction.lua

Enforces arena boundaries.

**Exports**:
- `init()` - Start restriction monitoring
- `on_tick(dt)` - Check player positions
- `check_arena_bounds(pos)` - Check if in arena

---

## Development

### Running Self-Tests

```bash
> pvp_test
=== WindrosePvP Self-Tests ===
Utils: 10 passed, 0 failed
EventBus: 5 passed, 0 failed
PvPStateManager: Built-in tests run on module load
HealthManager: 8 passed, 0 failed
DuelRequest: 10 passed, 0 failed
DamageRouter: 10 passed, 0 failed
```

### Debug Logging

Enable in `config.lua`:
```lua
DEBUG_LOGGING = true
```

Logs appear with `[WindrosePvP]` prefix.

### Adding New Hooks

1. Edit `config.lua`:
```lua
HOOK_PATHS = {
    MELEE_REMOVE_EVENT_GES = "/Script/R5MeleeAbility.RemoveEventGEs",
    YOUR_NEW_HOOK = "/Script/YourClass.YourFunction",
}
```

2. Register in `damage_router.lua`:
```lua
function M._register_hooks()
    Utils.safe_hook(Config.HOOK_PATHS.YOUR_NEW_HOOK, pre_hook_fn)
end
```

### Testing Locally

```bash
# Challenge yourself (for testing only)
pvp_challenge TestPlayer TargetPlayer
# Note: Will error - can't challenge yourself

# Test non-player target
pvp_challenge Admin NPC  # If NPC exists
```

---

## Troubleshooting

### Common Issues

#### Issue: "Phase 0 still running"

**Cause**: `HEALTH_PROPERTY_PATH` not set in config

**Solution**: 
- Run Phase 0 discovery scripts first
- Set `HEALTH_PROPERTY_PATH` manually after discovery

---

#### Issue: "Challenge sent but target can't accept"

**Cause**: Target not online or name mismatch

**Solution**:
- Verify target is online: `pvp_status`
- Use exact case-sensitive name

---

#### Issue: "GAS overwrote damage"

**Cause**: Game's GAS is re-applying health

**Solution**:
- Automatic re-apply is enabled
- If persistent, may need different health property

---

#### Issue: "No hooks firing"

**Cause**: Hook path incorrect or hook disabled

**Solution**:
- Enable debug logging
- Check logs for hook registration
- Verify hook path in config.lua

---

### Log Messages

| Log | Meaning |
|-----|---------|
| `[WindrosePvP] Phase 0: Running discovery scripts` | Discovery phase active |
| `[WindrosePvP] Phase 1: Loading core PvP modules` | Core phase active |
| `[WindrosePvP] Damage redirected: A -> B for X` | Damage applied |
| `[WindrosePvP] Duel ended: X wins` | Duel completed |
| `GAS overwrite detected!` | GAS conflict (handled) |

### Getting Help

1. Check `pvp_status` for overall state
2. Run `pvp_test` for diagnostics
3. Enable `DEBUG_LOGGING` in config
4. Check server logs for full context

---

## API Reference

### Global Functions

| Function | Module | Description |
|----------|-------|-------------|
| `init()` | init | Initialize mod |
| `shutdown()` | init | Shutdown mod |
| `get_status()` | pvp_state_manager | Get PvP status |
| `create_challenge()` | pvp_state_manager | Create challenge |
| `accept_challenge()` | pvp_state_manager | Accept challenge |
| `apply_damage()` | health_manager | Apply damage |
| `get_health()` | health_manager | Get health |
| `register_test()` | utils | Register test |

### Events

| Event | Data | Fired When |
|-------|------|-----------|
| `challenge_created` | `{challenger, target, id}` | Challenge made |
| `challenge_resolved` | `{id, status}` | Accept/decline |
| `duel_created` | `{duel_id, player_a, player_b}` | Duel started |
| `duel_ended` | `{duel_id, winner, loser, reason}` | Duel ended |
| `damage_applied` | `{source, target, amount}` | Damage done |
| `player_died` | `{player, killer}` | Player death |
| `player_revived` | `{player, health}` | Auto-revive |

---

## License

MIT License

Copyright (c) 2024 WindrosePvP Community

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Credits

- **WindrosePvP Community** - Development and testing
- **UE4SS Team** - Lua modding framework
- **Windrose** - Game server