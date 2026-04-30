# WindrosePvP - Opt-in PvP Duel System

A server-side Lua mod for Windrose dedicated servers that enables player-versus-player dueling using shadow damage mechanics. Built for UE 5.6.1 dedicated servers with UE4SS.

## Overview

WindrosePvP adds a ** consensual PvP duel system** to Windrose survival servers. Players can challenge each other to duels, with damage redirected through a shadow damage system that doesn't interfere with the game's damage mechanics or anti-cheat.

### Key Features

- **Opt-in Duels**: Both players must consent to duel
- **Shadow Damage**: Damage applied via property modification, not game damage system
- **Auto-Revive**: Losers automatically respawn after duel ends
- **Arena Areas**: Configurable PvP zones
- **Full RCON**: Complete admin control via RCON commands

## Installation

### Server Requirements

- Windrose Dedicated Server (UE 5.6.1)
- UE4SS (Unreal Engine 4 Scripting System) installed
- Lua mod loader enabled

### Install Steps

1. Copy the `WindrosePvP` folder to your server's `Content/Scripts/` directory
2. Ensure UE4SS is installed and running
3. Configure `scripts/config.lua` for your server
4. Restart the server or reload the mod

## Configuration

Edit `scripts/config.lua`:

```lua
-- Core Settings
ARENA_CENTER = { X = 0, Y = 0, Z = 0 },  -- Arena world coordinates
ARENA_RADIUS = 5000,              -- Arena radius in units
DUEL_MAX_DURATION = 600,           -- Max duel duration in seconds (default: 10min)
DUEL_CHALLENGE_TIMEOUT = 60,       -- Challenge expiry in seconds

-- Health Settings  
HEALTH_PROPERTY_PATH = "Health",   -- Property path for player health
HEALTH_IS_ATTRIBUTE_DATA = false, -- Uses FGameplayAttributeData?

-- Revival
AUTO_REVIVE_LOSER = true,         -- Auto-revive loser after duel
AUTO_REVIVE_DELAY = 5.0,          -- Delay before revive

-- Messages
DAMAGE_MESSAGES_ENABLED = true,   -- Show damage numbers
```

## RCON Commands

### Player Commands

| Command | Description |
|---------|-------------|
| `pvp_challenge <your_name> <target>` | Challenge a player to duel |
| `pvp_accept <your_name>` | Accept pending challenge |
| `pvp_decline <your_name>` | Decline challenge |
| `pvp_surrender <your_name>` | Surrender from duel |
| `pvp_status` | Show PvP status |
| `pvp_health [player_name]` | Check player health |
| `pvp_duels` | List active duels |

### Admin Commands

| Command | Description |
|---------|-------------|
| `pvp_cancel <duel_id>` | Cancel a duel |
| `pvp_test` | Run self-tests |
| `pvp_config [key] [value]` | View/modify config |

## Architecture

### Module Structure

```
scripts/
├── init.lua              # Entry point, phase selection
├── config.lua            # Configuration
├── utils.lua            # Utilities, safe property access
├── event_bus.lua        # Internal pub/sub
├── phase0/             # Discovery scripts (run when health property unknown)
│   └── p0_*.lua       # Various discovery tests
└── phase1/             # Core PvP modules
    ├── main_phase1.lua # Orchestrator
    ├── pvp_state_manager.lua    # Duel state tracking
    ├── health_manager.lua    # Shadow damage application
    ├── duel_request.lua    # RCON command handlers
    ├── damage_router.lua  # Damage hook interception
    └── area_restriction.lua # Arena zone enforcement
```

### How It Works

1. **Init**: Mod loads Phase 0 scripts to discover health property
2. **Challenge**: Player runs `pvp_challenge`
3. **Accept**: Target accepts, duel becomes active
4. **Combat**: Damage routed via shadow damage (property modification)
5. **End**: When health reaches 0 or timeout

## Duel Flow

```
[P1] pvp_challenge PlayerA PlayerB
  → Creates pending challenge
[P2] pvp_accept PlayerB
  → Duel becomes active
[P1] attacks P2
  → DamageRouter intercepts attack
  → Applies shadow damage to P2's health property
  → Blocks original damage
[P2] health reaches 0
  → Duel ends
  → Winner announced
  → Loser auto-revived
```

## Shadow Damage System

The mod doesn't use the game's damage pipeline. Instead:

1. Intercepts attacks via UE4SS hooks
2. Reads current health via safe property access
3. Calculates new health (current - damage)
4. Writes health directly to the property
5. Verifies write stuck (handles GAS overwrites)
6. Blocks original damage

This approach:
- Bypasses anti-cheat (no damage system calls)
- Works with any damage type
- Is verifiable and controllable

## Development

### Running Tests

```bash
# In-game RCON
pvp_test
```

### Debug Logs

Enable detailed logging in `config.lua`:
```lua
DEBUG_LOGGING = true
```

Logs appear in server console with `[WindrosePvP]` prefix.

### Adding New Hooks

Edit `damage_router.lua` or `config.lua`:
```lua
HOOK_PATHS = {
    MELEE_REMOVE_EVENT_GES = "/Script/R5MeleeAbility.RemoveEventGEs",
    -- Add new hooks here
}
```

## License

MIT License - See LICENSE file for details.

## Credits

- WindrosePvP Community
- UE4SS team for Lua modding support

## Support

- Issues: GitHub Issues
- Discussions: GitHub Discussions
- Wiki: GitHub Wiki