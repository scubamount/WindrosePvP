# WindrosePvP Client Pak Mod

## Overview
This directory contains the client-side UI mod for the WindrosePvP system. Since Windrose's anti-cheat (BaseSDK.dll) blocks client-side UE4SS, all client functionality must be delivered via a `.pak` mod loaded through the game's Content/Paks/ directory.

## Directory Structure

```
Content/
├── README.md              (this file)
├── pak_manifest.json      (describes what the pak contains)
├── ui_spec.md            (detailed UI element specifications)
├── Widgets/             (UMG widget blueprints - built in UE Editor)
├── Textures/            (icons, images for UI)
└── Blueprints/           (helper blueprints if needed)
```

## UI Elements Needed

### 1. WBP_DuelInvite (UMG Widget)
- **Trigger**: When `pvp_challenge <target>` is received
- **Content**: "Player X has challenged you to a duel!" with Accept/Decline buttons
- **Buttons**: 
  - Accept → sends `pvp_accept <your_name>` via RCON
  - Decline → sends `pvp_decline <your_name>` via RCON
- **Auto-timeout**: 60 seconds (matches server Config.DUEL_CHALLENGE_TIMEOUT)

### 2. WBP_PvPHealthBar (UMG Widget)
- **Trigger**: When in an active duel (listen for duel state via periodic check or server message)
- **Content**: Health bar for opponent, showing remaining HP
- **Update**: Via `pvp_health <opponent>` RCON command or server system messages
- **Styling**: Red health bar, numeric HP display, player name

### 3. WBP_PvPScoreboard (UMG Widget)
- **Trigger**: During active duel
- **Content**: Kills/deaths, current duel duration, opponent name
- **Update**: Session-only (ephemeral, matches server state)

### 4. WBP_ArenaIndicator (UMG Widget)
- **Trigger**: When entering PvP arena zone (if zones are implemented)
- **Content**: "You are entering a PvP arena!" with boundary indicator
- **Visual**: Minimap overlay or screen edge indicator showing arena bounds

## Building the Pak

### Prerequisites
1. Unreal Engine 5.6.1 Editor (same version as Windrose)
2. Windrose asset references (may need the game's Content directory for reference)
3. UE4SS pak cooking tools

### Steps
1. Create a new UE project with the same structure as Windrose
2. Build the UMG widgets listed above in the Editor
3. Cook the assets: `UnrealEditor-Cmd.exe MyProject.uproject -run=cook -targetplatform=Win64`
4. Package into .pak: Use UnrealPak tool
5. Place .pak in `Windrose/R5/Content/Paks/` (or mod.io upload)

## mod.io Integration
- Windrose uses mod.io (game IDs 2475, 3992)
- Upload .pak file to mod.io with tag "PvP"
- Users subscribe via in-game mod browser

## Server-Client Communication
Since client UE4SS is blocked, the client mod receives data via:
1. **System messages** (`wp.send_system_message`) — damage numbers, duel events
2. **Periodic RCON polling** — `pvp_status`, `pvp_health` (if client can make HTTP calls to RCON)
3. **Pak-only visual feedback** — health bars update via the widget's own logic once duel state is known

## Current Status
- [ ] WBP_DuelInvite blueprint created
- [ ] WBP_PvPHealthBar blueprint created
- [ ] WBP_PvPScoreboard blueprint created
- [ ] WBP_ArenaIndicator blueprint created
- [ ] Textures created
- [ ] Pak cooked and built
- [ ] mod.io upload

## Note
This client pak mod is a separate workstream from the server Lua mod. The server mod (18 files in `scripts/`) is complete and functional without the client pak — the client pak adds visual UI only.
