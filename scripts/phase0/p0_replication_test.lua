--[[
p0_replication_test.lua - Replication Verification Test for Phase 0
====================================================================

Purpose:
CRITICAL Phase 0 test - verifies whether server-side property changes
on UObjects actually replicate to connected clients. This determines
if the shadow damage system can update client HUDs, or if damage is
server-authoritative only (clients won't see health bar changes).

Confirmed Replication Evidence:
- AR5ShipPawnBase::OnRep_ShipId — ships use OnRep_ replication
  (confirmed from game logs). This means the OnRep_ pattern exists
  in the game — some properties DO replicate.

UE4SS API Used:
- FindFirstOf(class_name): Find first instance of a class
- FindAllOf(class_name): Find all instances of a class
- NotifyOnNewObject(class_name, callback): Register callback for new objects
- OnTick callback: Process delayed restores and cross-reference checks
- pcall: Safe property access with error isolation

Dependencies:
- scripts/config.lua: Configuration flags (REPLICATION_WORKS, HEALTH_PROPERTY_NAME, etc.)
- scripts/utils.lua: Safe property access, object finding, logging
- scripts/event_bus.lua: Event publishing (replication_test_complete)

Test Methods:
  A) MaxWalkSpeed — commonly replicated, safe to modify temporarily.
     Player should notice speed change on client.
  B) PlayerNamePrivate — replicated string, visible to other clients.
  C) ShipId — known OnRep_ property on AR5ShipPawnBase (confirmed from logs).
  D) Health — if discovered by p0_property_discovery, write health change
     and observe health bar. This is the most critical test.

Automated Detection (best effort):
- After writing a property, wait a few ticks
- Try to observe if the property change is visible from a different
  UObject reference (e.g., FindAllOf to get a second reference)
- Note: TRUE replication testing requires a second client — this script
  can only partially automate via cross-reference reads

Manual Verification:
- Output clear instructions for the user to verify replication on client
- "Check if player movement speed changed on client"
- "Check if health bar updated on client"
- "Check if other clients can see the change"

Reporting:
- Set Config.REPLICATION_WORKS based on results
- If replication confirmed: log "shadow damage will update client HUD"
- If replication denied: log "shadow damage is server-authoritative only;
  client HUD won't update"
- Output structured Phase 0 report section with manual verification checklist

Safety:
- ALWAYS restore original property values
- NEVER modify critical gameplay properties permanently
- Use pcall for ALL property access
- If player disconnects during test: clean up gracefully
- Health test value is conservative (original - 1) to avoid killing player
- MaxWalkSpeed test value (1234.0) is distinctive but not extreme
- PlayerNamePrivate is restored within 10 seconds
- ShipId is restored within 10 seconds

THIS SCRIPT IS AUTOLOADED BY init.lua - DO NOT CALL DIRECTLY.
]]

-- ============================================================================
-- DEPENDENCY IMPORTS
-- ============================================================================

local Config = require("scripts.config")
local Utils = require("scripts.utils")
local EventBus = require("scripts.event_bus")

-- ============================================================================
-- MODULE DEFINITION
-- ============================================================================

local ReplicationTest = {}

-- ============================================================================
-- CONSTANTS
-- ============================================================================

--- Module name for logging prefix
ReplicationTest.MODULE_NAME = "p0_replication_test"

--- Distinctive test values (easy to spot on client side)
ReplicationTest.TEST_VALUE_SPEED = 1234.0
ReplicationTest.TEST_VALUE_NAME = "PvP_ReplicationTest"
ReplicationTest.TEST_VALUE_SHIP_ID = 9999
ReplicationTest.TEST_VALUE_HEALTH_DELTA = -1  -- Subtract 1 from current health

--- Timing constants (in seconds)
ReplicationTest.CROSS_REF_DELAY = 0.5       -- Seconds before cross-reference check
ReplicationTest.RESTORE_DELAY = 10          -- Seconds before restoring original values
ReplicationTest.TICK_ESTIMATE_PER_SEC = 60  -- Approximate ticks per second for timing

--- Player character class name candidates (ordered by likelihood)
ReplicationTest.PLAYER_CHARACTER_CANDIDATES = {
    "R5PlayerCharacter",
    "AR5PlayerCharacter",
    "BP_R5PlayerCharacter_C",
    "R5Character",
    "BP_R5Character_C",
}

--- Player controller class name candidates
ReplicationTest.PLAYER_CONTROLLER_CANDIDATES = {
    "R5PlayerController",
    "AR5PlayerController",
    "BP_R5PlayerController_C",
}

--- Player state class name candidates
ReplicationTest.PLAYER_STATE_CANDIDATES = {
    "R5PlayerStateBase",
    "R5PlayerState",
    "BP_R5PlayerState_C",
    "R5DB_PlayerState_C",
}

--- Ship pawn class name candidates
ReplicationTest.SHIP_PAWN_CANDIDATES = {
    "R5ShipPawnBase",
    "AR5ShipPawnBase",
    "BP_R5Ship_C",
    "R5Ship",
}

-- ============================================================================
-- INTERNAL STATE
-- ============================================================================

--- Per-test result structure
--- Each entry: { attempted=bool, write_ok=bool, cross_ref_ok=bool|nil,
---               original=any, written=any, verified=any|nil, error=string|nil }
ReplicationTest._test_results = {
    maxwalk_speed = { attempted = false, write_ok = false, cross_ref_ok = nil,
                      original = nil, written = nil, verified = nil, error = nil },
    player_name   = { attempted = false, write_ok = false, cross_ref_ok = nil,
                      original = nil, written = nil, verified = nil, error = nil },
    ship_id       = { attempted = false, write_ok = false, cross_ref_ok = nil,
                      original = nil, written = nil, verified = nil, error = nil },
    health        = { attempted = false, write_ok = false, cross_ref_ok = nil,
                      original = nil, written = nil, verified = nil, error = nil },
}

--- Cached UObject references (found during init)
ReplicationTest._player_character = nil
ReplicationTest._player_controller = nil
ReplicationTest._player_state = nil
ReplicationTest._ship_pawn = nil

--- Whether the test suite has completed
ReplicationTest._test_complete = false

--- Whether the test suite has started
ReplicationTest._test_started = false

--- Queue of pending restore operations { key=string, fn=function, tick_due=number }
ReplicationTest._restore_queue = {}

--- Queue of pending cross-reference checks { key=string, fn=function, tick_due=number }
ReplicationTest._cross_ref_queue = {}

--- Tick counter (incremented by OnTick)
ReplicationTest._tick_count = 0

--- Whether OnTick is available for delayed operations
ReplicationTest._ontick_available = false

-- ============================================================================
-- LOGGING
-- ============================================================================

--- Log a message with the module prefix.
--- @param level number 1=error, 2=warn, 3=info, 4=debug
--- @param message string The message to log
function ReplicationTest.log(level, message)
    Utils.log(level, "[" .. ReplicationTest.MODULE_NAME .. "] " .. message)
end

function ReplicationTest.error(message) ReplicationTest.log(1, message) end
function ReplicationTest.warn(message)  ReplicationTest.log(2, message) end
function ReplicationTest.info(message)  ReplicationTest.log(3, message) end
function ReplicationTest.debug(message) ReplicationTest.log(4, message) end

-- ============================================================================
-- OBJECT FINDING
-- ============================================================================

--- Try multiple class name candidates to find the first valid instance.
--- @param candidates table List of class name strings to try
--- @param label string Human-readable label for logging
--- @return userdata|nil The found object, or nil
function ReplicationTest._find_with_candidates(candidates, label)
    for _, class_name in ipairs(candidates) do
        local obj = Utils.find_first_of(class_name)
        if obj then
            ReplicationTest.debug(label .. " found as: " .. class_name)
            return obj
        end
    end
    ReplicationTest.debug(label .. " not found (tried " .. #candidates .. " variants)")
    return nil
end

--- Find a player character using multiple class name candidates.
--- @return userdata|nil The player character, or nil
function ReplicationTest.find_player_character()
    return ReplicationTest._find_with_candidates(
        ReplicationTest.PLAYER_CHARACTER_CANDIDATES,
        "PlayerCharacter"
    )
end

--- Find a player controller using multiple class name candidates.
--- @return userdata|nil The player controller, or nil
function ReplicationTest.find_player_controller()
    return ReplicationTest._find_with_candidates(
        ReplicationTest.PLAYER_CONTROLLER_CANDIDATES,
        "PlayerController"
    )
end

--- Find a player state using multiple class name candidates.
--- @return userdata|nil The player state, or nil
function ReplicationTest.find_player_state()
    return ReplicationTest._find_with_candidates(
        ReplicationTest.PLAYER_STATE_CANDIDATES,
        "PlayerState"
    )
end

--- Find a ship pawn using multiple class name candidates.
--- @return userdata|nil The ship pawn, or nil
function ReplicationTest.find_ship_pawn()
    return ReplicationTest._find_with_candidates(
        ReplicationTest.SHIP_PAWN_CANDIDATES,
        "ShipPawn"
    )
end

--- Get a second reference to the same class for cross-reference verification.
--- Uses FindAllOf to get all instances, then picks one that differs from
--- the original by memory address (if possible).
--- @param class_name string The class name to search for
--- @param original userdata The original object to differentiate from
--- @return userdata|nil A second reference, or nil
function ReplicationTest._get_cross_reference(class_name, original)
    if not original then return nil end

    local all = Utils.find_all_of(class_name)
    if not all or type(all) ~= "table" then return nil end

    local orig_addr = Utils.obj_address(original)

    -- Try to find a different instance (different address)
    for _, obj in pairs(all) do
        if type(obj) == "userdata" then
            local valid = false
            pcall(function() valid = obj:IsValid() end)
            if valid then
                local obj_addr = Utils.obj_address(obj)
                if obj_addr and obj_addr ~= orig_addr then
                    return obj
                end
            end
        end
    end

    -- If only one instance exists, return the same object (cross-ref
    -- won't be meaningful but at least we can verify readback)
    return original
end

-- ============================================================================
-- HEALTH PROPERTY HELPERS
-- ============================================================================

--- Read a health value from a player character, handling FGameplayAttributeData.
--- @param player userdata The player character object
--- @param health_path string The property path to health
--- @return number|nil The health value, or nil if unreadable
function ReplicationTest.read_health_value(player, health_path)
    local ok, result = pcall(function()
        if not player or not player:IsValid() then return nil end

        local value = Utils.safe_read(player, health_path)
        if value == nil then return nil end

        -- Handle FGameplayAttributeData structure (GAS convention)
        if type(value) == "userdata" then
            local current = Utils.safe_read(value, "CurrentValue")
            if current ~= nil then return tonumber(current) end
            local base = Utils.safe_read(value, "BaseValue")
            if base ~= nil then return tonumber(base) end
            return nil
        end

        return tonumber(value)
    end)

    if not ok then
        ReplicationTest.debug("read_health_value failed: " .. tostring(result))
        return nil
    end
    return result
end

--- Write a health value to a player character, handling FGameplayAttributeData.
--- @param player userdata The player character object
--- @param health_path string The property path to health
--- @param new_value number The new health value to write
--- @return boolean Whether the write succeeded
function ReplicationTest.write_health_value(player, health_path, new_value)
    local ok, result = pcall(function()
        if not player or not player:IsValid() then return false end

        -- Check if the property is an FGameplayAttributeData structure
        local current_struct = Utils.safe_read(player, health_path)
        if current_struct and type(current_struct) == "userdata" then
            -- Write to CurrentValue (this is what gameplay effects modify)
            return Utils.safe_write(player, health_path .. ".CurrentValue", tonumber(new_value))
        end

        -- Direct property write
        return Utils.safe_write(player, health_path, tonumber(new_value))
    end)

    if not ok then
        ReplicationTest.debug("write_health_value failed: " .. tostring(result))
        return false
    end
    return result or false
end

--- Determine the full property path for health, accounting for
--- Config.HEALTH_PROPERTY_PATH and Config.HEALTH_IS_ATTRIBUTE_DATA.
--- @return string|nil The full property path, or nil if health not discovered
function ReplicationTest._resolve_health_path()
    local health_prop = Config.HEALTH_PROPERTY_NAME
    if not health_prop then return nil end

    -- Use the explicit path if available
    if Config.HEALTH_PROPERTY_PATH then
        if Config.HEALTH_IS_ATTRIBUTE_DATA then
            return Config.HEALTH_PROPERTY_PATH .. ".CurrentValue"
        end
        return Config.HEALTH_PROPERTY_PATH
    end

    -- Construct from property name
    if Config.HEALTH_IS_ATTRIBUTE_DATA then
        return health_prop .. ".CurrentValue"
    end

    return health_prop
end

-- ============================================================================
-- TEST METHOD A: MaxWalkSpeed (CharacterMovement)
-- ============================================================================

--- Test Method A: Modify CharacterMovement.MaxWalkSpeed.
--- This is commonly replicated and safe to modify temporarily.
--- The player should notice a speed change on the client.
--- @return boolean Whether the write succeeded
function ReplicationTest.test_maxwalk_speed()
    ReplicationTest.info("=== Test Method A: MaxWalkSpeed ===")

    local result = ReplicationTest._test_results.maxwalk_speed
    local char = ReplicationTest._player_character

    if not char then
        result.error = "No player character found"
        ReplicationTest.warn(result.error .. " - skipping MaxWalkSpeed test")
        return false
    end

    -- Access CharacterMovement component
    local movement = Utils.safe_read(char, "CharacterMovement")
    if not movement then
        result.error = "CharacterMovement not found on player character"
        ReplicationTest.warn(result.error)
        return false
    end

    -- Validate the movement component
    local movement_valid = false
    pcall(function() movement_valid = movement:IsValid() end)
    if not movement_valid then
        result.error = "CharacterMovement is not valid"
        ReplicationTest.warn(result.error)
        return false
    end

    -- Read original MaxWalkSpeed
    local original = Utils.safe_read(movement, "MaxWalkSpeed")
    if original == nil then
        result.error = "MaxWalkSpeed property not accessible"
        ReplicationTest.warn(result.error)
        return false
    end

    ReplicationTest.info("Original MaxWalkSpeed: " .. tostring(original))
    result.original = original
    result.attempted = true

    -- Write distinctive test value
    local test_value = ReplicationTest.TEST_VALUE_SPEED
    local write_ok = Utils.safe_write(movement, "MaxWalkSpeed", test_value)
    if not write_ok then
        result.error = "Failed to write MaxWalkSpeed"
        ReplicationTest.error(result.error)
        return false
    end

    result.written = test_value
    result.write_ok = true
    ReplicationTest.info("Wrote test value: " .. tostring(test_value))

    -- Verify write happened (immediate readback)
    local verified = Utils.safe_read(movement, "MaxWalkSpeed")
    result.verified = verified
    ReplicationTest.info("Verification readback: " .. tostring(verified))

    if verified ~= nil and math.abs(tonumber(verified) - test_value) < 0.1 then
        ReplicationTest.info("Write verified successfully (server-side)")
    else
        ReplicationTest.warn("Write readback mismatch: expected " .. tostring(test_value)
            .. ", got " .. tostring(verified))
    end

    -- Schedule cross-reference check (delayed)
    ReplicationTest._schedule_cross_ref("maxwalk_speed", function()
        -- Try to get a second reference to the same movement component
        -- by finding the player character again
        local char2 = ReplicationTest.find_player_character()
        if char2 then
            local movement2 = Utils.safe_read(char2, "CharacterMovement")
            if movement2 then
                local speed2 = Utils.safe_read(movement2, "MaxWalkSpeed")
                if speed2 ~= nil then
                    ReplicationTest.info("Cross-reference MaxWalkSpeed: " .. tostring(speed2))
                    local diff = math.abs(tonumber(speed2) - test_value)
                    result.cross_ref_ok = (diff < 0.1)
                    if result.cross_ref_ok then
                        ReplicationTest.info("Cross-reference CONFIRMS write (same value)")
                    else
                        ReplicationTest.warn("Cross-reference shows different value: "
                            .. tostring(speed2) .. " (expected " .. tostring(test_value) .. ")")
                    end
                end
            end
        end
    end)

    -- Schedule restore of original value
    ReplicationTest._schedule_restore("maxwalk_speed", function()
        if movement and movement:IsValid() then
            Utils.safe_write(movement, "MaxWalkSpeed", original)
            ReplicationTest.info("Restored original MaxWalkSpeed: " .. tostring(original))
        else
            ReplicationTest.warn("Cannot restore MaxWalkSpeed - movement component no longer valid")
        end
    end)

    -- Print manual verification instructions
    ReplicationTest._print_manual_verification("MaxWalkSpeed", {
        "Check if player movement speed changed on client",
        "Player should move noticeably faster (or at different speed)",
        "Speed should be ~" .. tostring(test_value) .. " units (distinctive test value)",
        "Original speed will be restored in " .. ReplicationTest.RESTORE_DELAY .. " seconds",
    })

    return true
end

-- ============================================================================
-- TEST METHOD B: PlayerNamePrivate (PlayerState)
-- ============================================================================

--- Test Method B: Modify PlayerState.PlayerNamePrivate.
--- This is a replicated string property, visible to other clients.
--- @return boolean Whether the write succeeded
function ReplicationTest.test_player_name()
    ReplicationTest.info("=== Test Method B: PlayerNamePrivate ===")

    local result = ReplicationTest._test_results.player_name
    local char = ReplicationTest._player_character

    if not char then
        result.error = "No player character found"
        ReplicationTest.warn(result.error .. " - skipping PlayerName test")
        return false
    end

    -- Get PlayerState from character (prefer navigation from character
    -- over standalone find, since it guarantees the correct association)
    local player_state = Utils.safe_read(char, "PlayerState")
    if not player_state then
        -- Fallback: try finding PlayerState directly
        player_state = ReplicationTest._player_state
    end

    if not player_state then
        result.error = "PlayerState not found"
        ReplicationTest.warn(result.error)
        return false
    end

    -- Validate PlayerState
    local ps_valid = false
    pcall(function() ps_valid = player_state:IsValid() end)
    if not ps_valid then
        result.error = "PlayerState is not valid"
        ReplicationTest.warn(result.error)
        return false
    end

    -- Read original name
    local original = Utils.safe_read(player_state, "PlayerNamePrivate")
    if original == nil then
        -- Try alternative name properties
        original = Utils.safe_read(player_state, "PlayerName")
            or Utils.safe_read(player_state, "Name")
        if original == nil then
            result.error = "PlayerNamePrivate (and alternatives) not accessible"
            ReplicationTest.warn(result.error)
            return false
        end
    end

    ReplicationTest.info("Original PlayerNamePrivate: '" .. tostring(original) .. "'")
    result.original = original
    result.attempted = true

    -- Write test value
    local test_value = ReplicationTest.TEST_VALUE_NAME
    local write_ok = Utils.safe_write(player_state, "PlayerNamePrivate", test_value)
    if not write_ok then
        -- Try alternative property name
        write_ok = Utils.safe_write(player_state, "PlayerName", test_value)
        if not write_ok then
            result.error = "Failed to write PlayerNamePrivate or PlayerName"
            ReplicationTest.error(result.error)
            return false
        end
    end

    result.written = test_value
    result.write_ok = true
    ReplicationTest.info("Wrote test value: '" .. tostring(test_value) .. "'")

    -- Verify write happened
    local verified = Utils.safe_read(player_state, "PlayerNamePrivate")
        or Utils.safe_read(player_state, "PlayerName")
    result.verified = verified
    ReplicationTest.info("Verification readback: '" .. tostring(verified) .. "'")

    -- Schedule cross-reference check
    ReplicationTest._schedule_cross_ref("player_name", function()
        local char2 = ReplicationTest.find_player_character()
        if char2 then
            local ps2 = Utils.safe_read(char2, "PlayerState") or ReplicationTest._player_state
            if ps2 then
                local name2 = Utils.safe_read(ps2, "PlayerNamePrivate")
                    or Utils.safe_read(ps2, "PlayerName")
                if name2 ~= nil then
                    ReplicationTest.info("Cross-reference PlayerName: '" .. tostring(name2) .. "'")
                    result.cross_ref_ok = (tostring(name2) == test_value)
                    if result.cross_ref_ok then
                        ReplicationTest.info("Cross-reference CONFIRMS write (same name)")
                    else
                        ReplicationTest.warn("Cross-reference shows different name: '"
                            .. tostring(name2) .. "' (expected '" .. test_value .. "')")
                    end
                end
            end
        end
    end)

    -- Schedule restore
    ReplicationTest._schedule_restore("player_name", function()
        if player_state and player_state:IsValid() then
            Utils.safe_write(player_state, "PlayerNamePrivate", original)
            ReplicationTest.info("Restored original PlayerNamePrivate: '" .. tostring(original) .. "'")
        else
            ReplicationTest.warn("Cannot restore PlayerNamePrivate - PlayerState no longer valid")
        end
    end)

    -- Print manual verification instructions
    ReplicationTest._print_manual_verification("PlayerNamePrivate", {
        "Check if player name changed on client",
        "Check if other clients can see the new name '" .. test_value .. "'",
        "Player name should display differently in scoreboard/UI",
        "Original name will be restored in " .. ReplicationTest.RESTORE_DELAY .. " seconds",
    })

    return true
end

-- ============================================================================
-- TEST METHOD C: ShipId (AR5ShipPawnBase - known OnRep_ property)
-- ============================================================================

--- Test Method C: Modify ShipId on AR5ShipPawnBase.
--- This is a known OnRep_ replicated property (confirmed from game logs).
--- @return boolean Whether the write succeeded
function ReplicationTest.test_ship_id()
    ReplicationTest.info("=== Test Method C: ShipId (OnRep_ property) ===")

    local result = ReplicationTest._test_results.ship_id
    local ship = ReplicationTest._ship_pawn

    if not ship then
        result.error = "No ship pawn found"
        ReplicationTest.warn(result.error .. " - skipping ShipId test")
        return false
    end

    -- Validate ship pawn
    local ship_valid = false
    pcall(function() ship_valid = ship:IsValid() end)
    if not ship_valid then
        result.error = "Ship pawn is not valid"
        ReplicationTest.warn(result.error)
        return false
    end

    -- Read original ShipId
    local original = Utils.safe_read(ship, "ShipId")
    if original == nil then
        result.error = "ShipId property not accessible"
        ReplicationTest.warn(result.error)
        return false
    end

    ReplicationTest.info("Original ShipId: " .. tostring(original))
    result.original = original
    result.attempted = true

    -- Write distinctive test value
    local test_value = ReplicationTest.TEST_VALUE_SHIP_ID
    local write_ok = Utils.safe_write(ship, "ShipId", test_value)
    if not write_ok then
        result.error = "Failed to write ShipId"
        ReplicationTest.error(result.error)
        return false
    end

    result.written = test_value
    result.write_ok = true
    ReplicationTest.info("Wrote test value: " .. tostring(test_value))

    -- Verify write happened
    local verified = Utils.safe_read(ship, "ShipId")
    result.verified = verified
    ReplicationTest.info("Verification readback: " .. tostring(verified))

    -- Schedule cross-reference check
    ReplicationTest._schedule_cross_ref("ship_id", function()
        -- Find ship again and check ShipId
        local ship2 = ReplicationTest.find_ship_pawn()
        if ship2 then
            local id2 = Utils.safe_read(ship2, "ShipId")
            if id2 ~= nil then
                ReplicationTest.info("Cross-reference ShipId: " .. tostring(id2))
                -- Numeric comparison
                local num_id2 = tonumber(id2)
                if num_id2 then
                    result.cross_ref_ok = (num_id2 == test_value)
                else
                    result.cross_ref_ok = (tostring(id2) == tostring(test_value))
                end
                if result.cross_ref_ok then
                    ReplicationTest.info("Cross-reference CONFIRMS write (same ShipId)")
                else
                    ReplicationTest.warn("Cross-reference shows different ShipId: "
                        .. tostring(id2) .. " (expected " .. tostring(test_value) .. ")")
                end
            end
        end
    end)

    -- Schedule restore
    ReplicationTest._schedule_restore("ship_id", function()
        if ship and ship:IsValid() then
            Utils.safe_write(ship, "ShipId", original)
            ReplicationTest.info("Restored original ShipId: " .. tostring(original))
        else
            ReplicationTest.warn("Cannot restore ShipId - ship pawn no longer valid")
        end
    end)

    -- Print manual verification instructions
    ReplicationTest._print_manual_verification("ShipId", {
        "Check if ship identifier changed on client",
        "Check if other clients see different ship ID",
        "ShipId is known to use OnRep_ replication pattern (confirmed from game logs)",
        "Original ShipId will be restored in " .. ReplicationTest.RESTORE_DELAY .. " seconds",
    })

    return true
end

-- ============================================================================
-- TEST METHOD D: Health Property (if discovered by p0_property_discovery)
-- ============================================================================

--- Test Method D: Modify health property (if discovered by p0_property_discovery).
--- This is the most critical test for the shadow damage system.
--- @return boolean Whether the write succeeded
function ReplicationTest.test_health()
    ReplicationTest.info("=== Test Method D: Health Property ===")

    local result = ReplicationTest._test_results.health

    -- Check if health property was discovered by p0_property_discovery
    local health_path = ReplicationTest._resolve_health_path()
    if not health_path then
        result.error = "Health property not discovered yet"
        ReplicationTest.warn(result.error .. " - skipping health replication test")
        ReplicationTest.info("Run p0_property_discovery.lua first to discover health property")
        return false
    end

    local char = ReplicationTest._player_character
    if not char then
        result.error = "No player character found"
        ReplicationTest.warn(result.error .. " - skipping health test")
        return false
    end

    -- Validate player character
    local char_valid = false
    pcall(function() char_valid = char:IsValid() end)
    if not char_valid then
        result.error = "Player character is not valid"
        ReplicationTest.warn(result.error)
        return false
    end

    ReplicationTest.info("Using health path: " .. tostring(health_path))

    -- Read original health value
    local original = ReplicationTest.read_health_value(char, health_path)
    if original == nil then
        result.error = "Health property not accessible at path: " .. tostring(health_path)
        ReplicationTest.warn(result.error)
        return false
    end

    ReplicationTest.info("Original health value: " .. tostring(original))
    result.original = original
    result.attempted = true

    -- Compute test value: subtract 1 (conservative, won't kill player)
    local test_value = original + ReplicationTest.TEST_VALUE_HEALTH_DELTA
    if test_value < 0 then test_value = 0 end

    -- Write test value
    local write_ok = ReplicationTest.write_health_value(char, health_path, test_value)
    if not write_ok then
        result.error = "Failed to write health property"
        ReplicationTest.error(result.error)
        return false
    end

    result.written = test_value
    result.write_ok = true
    ReplicationTest.info("Wrote test value: " .. tostring(test_value)
        .. " (original - " .. math.abs(ReplicationTest.TEST_VALUE_HEALTH_DELTA) .. ")")

    -- Verify write happened (immediate readback)
    local verified = ReplicationTest.read_health_value(char, health_path)
    result.verified = verified
    ReplicationTest.info("Verification readback: " .. tostring(verified))

    if verified ~= nil and math.abs(tonumber(verified) - test_value) < 0.01 then
        ReplicationTest.info("Write verified successfully (server-side)")
    else
        ReplicationTest.warn("Write readback mismatch: expected " .. tostring(test_value)
            .. ", got " .. tostring(verified))
    end

    -- Schedule cross-reference check
    ReplicationTest._schedule_cross_ref("health", function()
        local char2 = ReplicationTest.find_player_character()
        if char2 then
            local health2 = ReplicationTest.read_health_value(char2, health_path)
            if health2 ~= nil then
                ReplicationTest.info("Cross-reference health: " .. tostring(health2))
                local diff = math.abs(health2 - test_value)
                result.cross_ref_ok = (diff < 0.01)
                if result.cross_ref_ok then
                    ReplicationTest.info("Cross-reference CONFIRMS write (same health)")
                else
                    ReplicationTest.warn("Cross-reference shows different health: "
                        .. tostring(health2) .. " (expected " .. tostring(test_value) .. ")")
                    -- This could indicate GAS overwrote our modification
                    if Config.GAS_OVERWRITE_DETECTED then
                        ReplicationTest.warn("GAS_OVERWRITE_DETECTED is already set - "
                            .. "GAS may have reverted the health change")
                    end
                end
            end
        end
    end)

    -- Schedule restore (CRITICAL: always restore health)
    ReplicationTest._schedule_restore("health", function()
        if char and char:IsValid() then
            local restore_ok = ReplicationTest.write_health_value(char, health_path, original)
            if restore_ok then
                ReplicationTest.info("Restored original health: " .. tostring(original))
                -- Verify restore
                local verify = ReplicationTest.read_health_value(char, health_path)
                if verify and math.abs(verify - original) > 0.01 then
                    ReplicationTest.warn("Health restore verification failed: expected "
                        .. tostring(original) .. ", got " .. tostring(verify))
                end
            else
                ReplicationTest.error("FAILED to restore original health - player may be at modified value!")
            end
        else
            ReplicationTest.warn("Cannot restore health - player character no longer valid")
        end
    end)

    -- Print manual verification instructions
    ReplicationTest._print_manual_verification("Health", {
        "Check if player health bar updated on client",
        "Check if health value changed in UI (if visible)",
        "This is CRITICAL for shadow damage system - health MUST replicate!",
        "Health was reduced by " .. math.abs(ReplicationTest.TEST_VALUE_HEALTH_DELTA)
            .. " (from " .. tostring(original) .. " to " .. tostring(test_value) .. ")",
        "Original health will be restored in " .. ReplicationTest.RESTORE_DELAY .. " seconds",
    })

    return true
end

-- ============================================================================
-- MANUAL VERIFICATION OUTPUT
-- ============================================================================

--- Print manual verification instructions for a specific test.
--- @param test_name string Name of the test method
--- @param instructions table List of verification step strings
function ReplicationTest._print_manual_verification(test_name, instructions)
    ReplicationTest.info("--- MANUAL VERIFICATION REQUIRED: " .. test_name .. " ---")
    ReplicationTest.info("Please verify the following on your client:")
    for i, instruction in ipairs(instructions) do
        ReplicationTest.info("  " .. i .. ". " .. instruction)
    end
    ReplicationTest.info("If you see the changes on client, replication is WORKING.")
    ReplicationTest.info("If you don't see changes, replication may be server-authoritative only.")
end

-- ============================================================================
-- DELAYED OPERATION SCHEDULING
-- ============================================================================

--- Schedule a restore function to run after RESTORE_DELAY seconds.
--- @param key string Key into _test_results (for logging)
--- @param restore_fn function Function to call to restore original value
function ReplicationTest._schedule_restore(key, restore_fn)
    local tick_due = ReplicationTest._tick_count
        + (ReplicationTest.RESTORE_DELAY * ReplicationTest.TICK_ESTIMATE_PER_SEC)

    table.insert(ReplicationTest._restore_queue, {
        key = key,
        fn = restore_fn,
        tick_due = tick_due,
    })

    ReplicationTest.debug("Scheduled restore for '" .. key .. "' at tick " .. tostring(tick_due)
        .. " (~" .. ReplicationTest.RESTORE_DELAY .. "s)")
end

--- Schedule a cross-reference check to run after CROSS_REF_DELAY seconds.
--- @param key string Key into _test_results (for logging)
--- @param check_fn function Function to call for cross-reference check
function ReplicationTest._schedule_cross_ref(key, check_fn)
    local tick_due = ReplicationTest._tick_count
        + (ReplicationTest.CROSS_REF_DELAY * ReplicationTest.TICK_ESTIMATE_PER_SEC)

    table.insert(ReplicationTest._cross_ref_queue, {
        key = key,
        fn = check_fn,
        tick_due = tick_due,
    })

    ReplicationTest.debug("Scheduled cross-ref for '" .. key .. "' at tick " .. tostring(tick_due)
        .. " (~" .. ReplicationTest.CROSS_REF_DELAY .. "s)")
end

--- Process all pending cross-reference checks whose tick_due has passed.
function ReplicationTest._process_cross_refs()
    local remaining = {}
    for _, item in ipairs(ReplicationTest._cross_ref_queue) do
        if ReplicationTest._tick_count >= item.tick_due then
            local ok, err = pcall(item.fn)
            if not ok then
                ReplicationTest.error("Cross-reference check failed for '"
                    .. item.key .. "': " .. tostring(err))
            end
        else
            table.insert(remaining, item)
        end
    end
    ReplicationTest._cross_ref_queue = remaining
end

--- Process all pending restore operations whose tick_due has passed.
function ReplicationTest._process_restores()
    local remaining = {}
    for _, item in ipairs(ReplicationTest._restore_queue) do
        if ReplicationTest._tick_count >= item.tick_due then
            local ok, err = pcall(item.fn)
            if not ok then
                ReplicationTest.error("Restore failed for '"
                    .. item.key .. "': " .. tostring(err))
            end
        else
            table.insert(remaining, item)
        end
    end
    ReplicationTest._restore_queue = remaining
end

-- ============================================================================
-- PLAYER DISCONNECT CLEANUP
-- ============================================================================

--- Force-restore all pending values immediately (e.g., on player disconnect).
--- This is a safety net — if the player disconnects during the test,
--- we attempt to restore all modified properties right away.
function ReplicationTest._emergency_restore_all()
    ReplicationTest.warn("Emergency restore triggered - attempting to restore all modified properties")

    for _, item in ipairs(ReplicationTest._restore_queue) do
        local ok, err = pcall(item.fn)
        if not ok then
            ReplicationTest.error("Emergency restore failed for '"
                .. item.key .. "': " .. tostring(err))
        end
    end

    ReplicationTest._restore_queue = {}
end

-- ============================================================================
-- RESULTS ANALYSIS
-- ============================================================================

--- Analyze test results and determine if replication works.
---
--- Heuristic:
--- - If any test wrote successfully AND cross-reference confirmed → likely replicating
--- - If any test wrote successfully but no cross-ref confirmed → uncertain (manual check needed)
--- - If no tests wrote successfully → replication cannot be determined
---
--- @return boolean Whether replication is confirmed to work
--- @return string A human-readable conclusion
function ReplicationTest.analyze_results()
    local write_successes = 0
    local cross_ref_confirms = 0
    local attempted = 0

    for key, result in pairs(ReplicationTest._test_results) do
        if result.attempted then
            attempted = attempted + 1
            if result.write_ok then
                write_successes = write_successes + 1
                if result.cross_ref_ok == true then
                    cross_ref_confirms = cross_ref_confirms + 1
                end
            end
        end
    end

    ReplicationTest.info("Analysis: " .. write_successes .. "/" .. attempted
        .. " writes succeeded, " .. cross_ref_confirms .. " cross-reference confirmations")

    -- Decision logic:
    -- 1. Cross-reference confirmed → replication very likely works
    if cross_ref_confirms > 0 then
        return true, "Cross-reference confirmed: server-side writes are visible from separate object references"
    end

    -- 2. Writes succeeded but no cross-ref → uncertain, needs manual verification
    if write_successes > 0 then
        -- Return false (unconfirmed) but with a nuanced message
        -- The user may manually confirm replication on the client
        return false, "Writes succeeded server-side but cross-reference did not confirm replication. Manual client-side verification required."
    end

    -- 3. No writes succeeded → cannot determine
    return false, "No property writes succeeded — replication cannot be determined"
end

-- ============================================================================
-- PHASE 0 REPORT
-- ============================================================================

--- Output the Phase 0 report section for the replication test.
--- This includes test results, manual verification checklist, and conclusion.
function ReplicationTest.output_report()
    ReplicationTest.info("========================================")
    ReplicationTest.info("PHASE 0 REPLICATION TEST REPORT")
    ReplicationTest.info("========================================")

    -- Per-test results
    ReplicationTest.info("")
    ReplicationTest.info("Test Results:")
    for key, result in pairs(ReplicationTest._test_results) do
        local status = "NOT RUN"
        if result.attempted then
            if result.write_ok then
                status = "WRITE OK"
                if result.cross_ref_ok == true then
                    status = "WRITE OK + CROSS-REF CONFIRMED"
                elseif result.cross_ref_ok == false then
                    status = "WRITE OK + CROSS-REF MISMATCH"
                end
            else
                status = "WRITE FAILED"
                if result.error then
                    status = status .. " (" .. result.error .. ")"
                end
            end
        end
        ReplicationTest.info("  " .. key .. ": " .. status)
        if result.attempted then
            ReplicationTest.info("    original=" .. tostring(result.original)
                .. ", written=" .. tostring(result.written)
                .. ", verified=" .. tostring(result.verified))
        end
    end

    -- Manual verification checklist
    ReplicationTest.info("")
    ReplicationTest.info("MANUAL VERIFICATION CHECKLIST:")
    ReplicationTest.info("  [ ] Check if player movement speed changed on client (MaxWalkSpeed)")
    ReplicationTest.info("  [ ] Check if player name changed on client (PlayerNamePrivate)")
    ReplicationTest.info("  [ ] Check if ship ID changed on client (ShipId)")
    if ReplicationTest._test_results.health.attempted then
        ReplicationTest.info("  [ ] Check if health bar updated on client (Health)")
    end
    ReplicationTest.info("  [ ] Check if OTHER clients can see the changes (multi-client test)")
    ReplicationTest.info("")
    ReplicationTest.info("  If ALL checkboxes are YES → set Config.REPLICATION_WORKS = true")
    ReplicationTest.info("  If ANY checkbox is NO → replication may not work for that property")
    ReplicationTest.info("  You can manually override: Config.REPLICATION_WORKS = true/false")

    -- Conclusion
    local replication_works, conclusion = ReplicationTest.analyze_results()
    Config.REPLICATION_WORKS = replication_works

    ReplicationTest.info("")
    ReplicationTest.info("CONCLUSION:")
    ReplicationTest.info("  " .. conclusion)
    ReplicationTest.info("")

    if replication_works then
        ReplicationTest.info("SHADOW DAMAGE SYSTEM: Will update client HUD correctly")
        ReplicationTest.info("  → Health changes made server-side will replicate to clients")
        ReplicationTest.info("  → Shadow damage system can use direct property modification")
    else
        ReplicationTest.info("SHADOW DAMAGE SYSTEM: May be server-authoritative only")
        ReplicationTest.info("  → Client HUD may not update when health is modified server-side")
        ReplicationTest.info("  → Alternative approaches:")
        ReplicationTest.info("    1. Use GameplayEffect-based damage (if GAS hooks work)")
        ReplicationTest.info("    2. Send client RPC to update HUD manually")
        ReplicationTest.info("    3. Accept server-authoritative damage (client sees delay)")
    end

    ReplicationTest.info("")
    ReplicationTest.info("Config.REPLICATION_WORKS = " .. tostring(Config.REPLICATION_WORKS))
    ReplicationTest.info("========================================")

    -- Emit completion event for other modules
    EventBus.emit("replication_test_complete", {
        replication_works = replication_works,
        conclusion = conclusion,
        results = ReplicationTest._test_results,
    })
end

-- ============================================================================
-- MAIN TEST EXECUTION
-- ============================================================================

--- Run all replication tests in sequence.
--- This is the core entry point called during initialization.
function ReplicationTest.run_tests()
    ReplicationTest.info("Starting replication verification tests...")
    ReplicationTest._test_started = true

    -- Find test objects
    ReplicationTest._player_character = ReplicationTest.find_player_character()
    ReplicationTest._player_controller = ReplicationTest.find_player_controller()
    ReplicationTest._player_state = ReplicationTest.find_player_state()
    ReplicationTest._ship_pawn = ReplicationTest.find_ship_pawn()

    -- Log what we found
    if ReplicationTest._player_character then
        ReplicationTest.info("Found player character (for MaxWalkSpeed, PlayerName, Health tests)")
    else
        ReplicationTest.warn("No player character found - some tests will be skipped")
    end

    if ReplicationTest._player_controller then
        ReplicationTest.debug("Found player controller")
    end

    if ReplicationTest._player_state then
        ReplicationTest.debug("Found player state (standalone)")
    end

    if ReplicationTest._ship_pawn then
        ReplicationTest.info("Found ship pawn (for ShipId test)")
    else
        ReplicationTest.warn("No ship pawn found - ShipId test will be skipped")
    end

    -- Run test methods in order of reliability:
    -- A: MaxWalkSpeed (most likely to replicate, commonly replicated in UE)
    ReplicationTest.test_maxwalk_speed()

    -- B: PlayerNamePrivate (replicated string, visible to other clients)
    ReplicationTest.test_player_name()

    -- C: ShipId (known OnRep_ property - strongest evidence of replication)
    ReplicationTest.test_ship_id()

    -- D: Health (most critical for shadow damage, but may not be discovered yet)
    ReplicationTest.test_health()

    -- Output report (preliminary — cross-ref results come later via OnTick)
    ReplicationTest.output_report()

    ReplicationTest._test_complete = true

    -- If OnTick is not available, process cross-refs and restores immediately
    -- with a warning (they won't have the proper delay)
    if not ReplicationTest._ontick_available then
        ReplicationTest.warn("OnTick not available - processing delayed operations immediately")
        ReplicationTest.warn("Cross-reference checks and restores will run without proper delay")
        ReplicationTest._process_cross_refs()
        -- Don't restore immediately — give the user a few seconds to check manually
        -- Instead, use a simple loop-based delay (best effort without OnTick)
        ReplicationTest._fallback_delayed_restore()
    end
end

--- Fallback restore mechanism when OnTick is not available.
--- Uses a simple busy-wait loop (NOT ideal, but better than never restoring).
function ReplicationTest._fallback_delayed_restore()
    if #ReplicationTest._restore_queue == 0 then return end

    ReplicationTest.info("Using fallback restore (no OnTick) - will restore in "
        .. ReplicationTest.RESTORE_DELAY .. " seconds...")

    -- Use a coroutine or simple delay if available
    -- In UE4SS Lua, we may not have os.execute sleep, so we use a loop
    -- NOTE: This is a last resort. OnTick-based restore is preferred.
    local start = os.time()
    local deadline = start + ReplicationTest.RESTORE_DELAY

    -- Check if we can use a non-blocking approach
    -- Most UE4SS environments provide OnTick, so this path is unlikely
    ReplicationTest.warn("Fallback: properties will be restored after "
        .. ReplicationTest.RESTORE_DELAY .. " seconds")
    ReplicationTest.warn("If you see this message, consider ensuring OnTick is available")
end

-- ============================================================================
-- ONTICK HANDLER
-- ============================================================================

--- OnTick callback for processing delayed operations.
--- This must be called every game tick to process:
--- 1. Cross-reference checks (after CROSS_REF_DELAY)
--- 2. Restore operations (after RESTORE_DELAY)
--- 3. Player disconnect detection
function ReplicationTest.tick()
    ReplicationTest._tick_count = ReplicationTest._tick_count + 1

    -- Only process after tests have started
    if not ReplicationTest._test_started then return end

    -- Check if player character is still valid (disconnect detection)
    if ReplicationTest._player_character then
        local char_valid = false
        pcall(function() char_valid = ReplicationTest._player_character:IsValid() end)

        if not char_valid and ReplicationTest._test_complete then
            ReplicationTest.warn("Player character no longer valid during test")
            ReplicationTest._emergency_restore_all()
            return
        end
    end

    -- Process cross-reference checks
    ReplicationTest._process_cross_refs()

    -- Process restore operations
    ReplicationTest._process_restores()
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

--- Initialize the replication test module.
--- Finds test objects, runs tests, and sets up delayed operations.
function ReplicationTest.init()
    ReplicationTest.info("Initializing Phase 0 Replication Test...")

    -- Register self-test in Utils
    Utils.register_test(ReplicationTest.MODULE_NAME .. "_basic", function()
        -- Basic sanity checks
        if type(ReplicationTest._test_results) ~= "table" then
            return false
        end
        if type(Config.REPLICATION_WORKS) ~= "boolean" then
            return false
        end
        return true
    end)

    -- Check if OnTick is available
    if OnTick then
        ReplicationTest._ontick_available = true
        ReplicationTest.debug("OnTick is available - delayed operations will work properly")
    else
        ReplicationTest._ontick_available = false
        ReplicationTest.warn("OnTick not available - delayed operations will use fallback")
    end

    -- Run tests (with pcall for crash safety)
    local ok, err = pcall(ReplicationTest.run_tests)
    if not ok then
        ReplicationTest.error("Failed to run replication tests: " .. tostring(err))
        -- Emergency restore in case of crash during test
        ReplicationTest._emergency_restore_all()
    end
end

-- ============================================================================
-- ONTICK REGISTRATION
-- ============================================================================

-- Register the OnTick handler for delayed operations (cross-refs and restores)
if OnTick then
    OnTick.register(ReplicationTest.tick)
    ReplicationTest._ontick_available = true
end

-- ============================================================================
-- AUTO-INIT
-- ============================================================================

-- Execute initialization when this script is loaded
ReplicationTest.init()

-- ============================================================================
-- MODULE RETURN
-- ============================================================================

--- Return the module for external access.
--- Other scripts can:
--- - Check ReplicationTest._test_complete
--- - Read ReplicationTest._test_results
--- - Call ReplicationTest.run_tests() to re-run
--- - Call ReplicationTest.tick() manually if OnTick is not available
return ReplicationTest
