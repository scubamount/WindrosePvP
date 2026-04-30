# WindrosePvP Client UI Specification

## Widget 1: WBP_DuelInvite

### Purpose
Display a duel invitation popup when another player challenges you.

### Layout
```
┌─────────────────────────────────────┐
│  ⚔ PvP Duel Invitation              │
├─────────────────────────────────────┤
│                                 │
│  PlayerName has challenged you     │
│  to a duel!                    │
│                                 │
│  Time left: 45s                │
│                                 │
│  [  ACCEPT  ]  [  DECLINE  ]  │
│                                 │
└─────────────────────────────────────┘
```

### Properties
- `ChallengerName` (Text) — set when widget is created
- `TimeRemaining` (float) — counts down from 60s
- `OnAccept` (Event) — fires when Accept clicked
- `OnDecline` (Event) — fires when Decline clicked

### Behavior
1. Created when server sends system message: `"[PvP] PlayerName has challenged you..."`
2. Auto-destroyed after 60s if no response (timeout)
3. Accept → Execute RCON command: `pvp_accept <my_name>`
4. Decline → Execute RCON command: `pvp_decline <my_name>`

### RCON Integration
```lua
-- Client would need an RCON client (not possible from pak mod alone)
-- Alternative: Server sends the challenge data, client widget reads from a shared file
-- Or: Widget is purely cosmetic, all logic handled server-side
```

---

## Widget 2: WBP_PvPHealthBar

### Purpose
Show opponent's current health during an active duel.

### Layout
```
┌─────────────────────────────────────┐
│ OpponentName        75 / 100 HP  │
│ ████████████████░░░░░       │
│                                 │
└─────────────────────────────────────┘
```

### Properties
- `OpponentName` (Text)
- `CurrentHealth` (float)
- `MaxHealth` (float)
- `HealthPercent` (float, 0.0-1.0) — drives the bar fill

### Behavior
1. Shown when duel starts (server sends `duel_created` event via system message)
2. Updates health bar when damage is applied (via system messages: `"[PvP] X hit Y for Z damage (W HP remaining)"`)
3. Hidden when duel ends

### Update Methods
- **Method A**: Parse system messages from server (if pak mod can intercept chat)
- **Method B**: Periodic RCON `pvp_health <opponent>` polling
- **Method C**: Server writes health to a shared file that the pak mod reads

---

## Widget 3: WBP_PvPScoreboard

### Purpose
Show duel statistics during an active duel.

### Layout
```
┌─────────────────────────────────────┐
│  ⚔ PvP Duel — 2:34 elapsed     │
├─────────────────────────────────────┤
│  PlayerNameA    ♥ 3    ☠ 1    │
│  PlayerNameB    ♥ 1    ☠ 3    │
│                                 │
│  Status: In Progress...          │
└─────────────────────────────────────┘
```

### Properties
- `PlayerAName`, `PlayerBName` (Text)
- `PlayerAKills`, `PlayerBKills` (int)
- `PlayerADeaths`, `PlayerBDeaths` (int)
- `DuelDuration` (Text, formatted "M:SS")
- `DuelStatus` (Text: "In Progress", "PlayerA Wins!", etc.)

### Behavior
- Updated via server system messages
- Session-only (no persistence)
- Auto-hidden when duel ends

---

## Widget 4: WBP_ArenaIndicator

### Purpose
Visual indicator when entering the PvP arena zone.

### Layout
```
┌─────────────────────────────────────┐
│  ⚠ ARENA BOUNDARY              │
│  Stay within the marked area!    │
│  Distance: 42m / 50m            │
└─────────────────────────────────────┘
```

### Properties
- `DistanceToCenter` (float)
- `ArenaRadius` (float)
- `IsInsideArena` (bool) — controls visibility

### Behavior
- Shown when player position is within `ARENA_RADIUS` of `ARENA_CENTER`
- Updates distance in real-time (if pak mod can read player position)
- Hidden when player leaves arena or duel ends

### Note
This widget is optional — the server handles arena enforcement via teleport-back. This is visual feedback only.

---

## Color Scheme
- Primary: `#C8102E` (Windrose red)
- Secondary: `#1E3A5F` (Windrose blue)
- Health bar: Green (100-50%), Yellow (50-25%), Red (<25%)
- Background: Semi-transparent dark (#00000080)

## Font
- Primary: Use Windrose's default font (match game UI)
- Size: 14-16pt for body text, 18-24pt for headers

## Implementation Priority
1. **WBP_DuelInvite** — Highest priority, core PvP UX
2. **WBP_PvPHealthBar** — Second priority, essential during duel
3. **WBP_PvPScoreboard** — Nice-to-have, enhances experience
4. **WBP_ArenaIndicator** — Lowest priority, optional visual
