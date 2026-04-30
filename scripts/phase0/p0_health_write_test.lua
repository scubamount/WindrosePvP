--[[
p0_health_write_test.lua - Health Property Write Test for Phase 0
====================================================================

Purpose:
CRITICAL Phase 0 test — validates whether the shadow damage system is
viable by attempting to read and write health properties on a live
player character. The game uses GAS (Gameplay Ability System) which
may recalculate attributes, overwriting direct property modifications.

UE4SS API Used:
- FindFirstOf(class_name): Find first instance of a class
- NotifyOnNewObject(class_name, callback): Register callback for new objects
- OnTick callback (via WindrosePlus mod framework): Track time and check for GAS overwrites
- pcall: Safe property access with error isolation

Dependencies:
- scripts/config.lua: Configuration flags (GAS_OVERWRITE_DETECTED, HEALTH_PROPERTY_NAME, etc.)
- scripts/utils.lua: Safe property access, object finding, logging
- scripts/event_bus.lua: Event publishing (gas_overwrite_detected)

Test Protocol:
1. Find a player character (FindFirstOf with fallback names)
2. Read health property (name from Config.HEALTH_PROPERTY_NAME or brute-force candidates)
3. Store original value
4. Write original_value - 1
5. Immediate re-read → verify write succeeded
6. Wait 5 seconds (via OnTick delta-time accumulation)
7. Re-read → check if GAS overwrote our modification
8. If overwritten: log "GAS dominant", set Config.GAS_OVERWRITE_DETECTED = true
9. Restore original health value
10. Report results

GAS Overwrite Detection:
- After writing, track the expected value
- On each OnTick, check if the actual value matches expected
- If mismatch > 0.01: GAS overwrote it
- Log the overwrite with expected vs actual values
- Emit "gas_overwrite_detected" event on EventBus

Critical Requirements:
- MUST restore original health after test (don't leave player at reduced health)
- MUST handle case where health property name is unknown (try all candidates)
- MUST handle case where write appears to succeed but GAS reverts it
- MUST handle FGameplayAttributeData structure (CurrentValue vs BaseValue)
- MUST NOT crash if player disconnects during test
- MUST use pcall for EVERY property access
- The test should run ONCE automatically when a player is found, then not repeat
- If no player is connected: register NotifyOnNewObject and retry when one joins
]]

-- ============================================================================
-- DEPENDENCY IMPORTS
-- ============================================================================

local Config = require("scripts.config")
local Utils  = require("scripts.utils")
local EventBus = require("scripts.event_bus")

-- ============================================================================
-- MODULE CONFIGURATION
-- ============================================================================

local MODULE_NAME = "p0_health_write_test"

--- Duration in seconds to wait after writing before checking for GAS overwrite.
local GAS_MONITOR_DURATION = 5.0

--- Tolerance for floating-point comparison when detecting GAS overwrites.
local GAS_OVERWRITE_TOLERANCE = 0.01

--- Amount to subtract from original health for the write test.
local TEST_DAMAGE_AMOUNT = 1.0

-- Candidate health property names to try if Config.HEALTH_PROPERTY_NAME is nil.
-- Ordered from most likely to least likely for UE5 GAS games.
local HEALTH_PROPERTY_CANDIDATES = {
    -- Direct properties on the player character
    "Health",
    "CurrentHealth",
    "HP",
    "Vitality",
    -- Nested via AttributeSet (common GAS pattern)
    "AttributeSet.Health",
    "AttributeSet.CurrentHealth",
    -- Nested via AbilitySystemComponent
    "AbilitySystemComponent.AttributeSet.Health",
    "AbilitySystemComponent.AttributeSet.CurrentHealth",
    -- Component-based patterns
    "HealthComponent.Health",
    "HealthComponent.CurrentHealth",
}

-- FGameplayAttributeData sub-property candidates.
-- When the health property is a struct, we read/write through these.
local ATTRIBUTE_DATA_SUBPROPS = {
    "CurrentValue",  -- GAS typically modifies this one
    "BaseValue",     -- Fallback: the unmodified base
}

-- Fallback player character class names for FindFirstOf / NotifyOnNewObject.
local PLAYER_CHARACTER_CANDIDATES = {
    Config.CLASS_NAMES and Config.CLASS_NAMES.PLAYER_CHARACTER or "R5PlayerCharacter",
    "BP_R5PlayerCharacter_C",
    "PlayerCharacter",
}

-- ============================================================================
-- LOCAL STATE
-- ============================================================================

--- Internal test state — tracks the entire lifecycle of the write test.
local test_state = {
    -- Lifecycle flags
    test_completed    = false,  -- True once the full protocol has finished
    test_started      = false,  -- True once we've found a player and begun writing
    test_running      = false,  -- True while we're in the monitoring phase

    -- Player reference
    player_found      = false,
    player_object     = nil,    -- userdata reference to the player character

    -- Health property discovery
    health_property_path   = nil,  -- The dot-separated path that yielded a value
    is_attribute_data      = false, -- True if health is an FGameplayAttributeData struct
    attribute_subprop      = nil,   -- "CurrentValue" or "BaseValue" — which sub-prop worked

    -- Test values
    original_health       = nil,   -- Health before we touched it
    written_value         = nil,   -- The value we wrote (original - TEST_DAMAGE_AMOUNT)
    expected_after_write  = nil,   -- What we expect to read back after writing
    write_succeeded       = false, -- Did Utils.safe_write return true?
    immediate_verify      = nil,   -- Health value read immediately after write

    -- GAS overwrite detection
    gas_overwrote         = false,  -- Did GAS revert our modification?
    gas_overwrite_time    = nil,    -- Game-time (seconds) when overwrite was first detected
    gas_overwrite_expected = nil,   -- Expected value at time of overwrite detection
    gas_overwrite_actual   = nil,   -- Actual value at time of overwrite detection
    health_after_5s       = nil,   -- Health value after the 5-second wait

    -- Timing
    monitor_elapsed       = 0.0,   -- Seconds elapsed since monitoring started
    watching_for_overwrite = false, -- Are we in the 5-second monitoring window?

    -- Restoration
    restore_attempted     = false,
    restore_succeeded     = false,

    -- Error tracking
    error_message         = nil,
}

--- Handle for the NotifyOnNewObject registration (so we can avoid re-triggering).
local notify_registered = false

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

--[[ Log a message with the module name prefix.

Uses Utils.log(level, message) — the correct API signature.
@param level number  1=ERROR, 2=WARN, 3=INFO, 4=DEBUG
@param message string
]]
local function log(level, message)
    Utils.log(level, "[" .. MODULE_NAME .. "] " .. tostring(message))
end

--[[ Check whether a UObject is still valid (not garbage-collected or destroyed).

Every property access MUST be guarded by this check to prevent crashes
when a player disconnects mid-test.

@param obj userdata|nil
@return boolean
]]
local function is_valid_object(obj)
    if not obj then return false end
    local ok, valid = pcall(function()
        return obj:IsValid()
    end)
    return ok and valid == true
end

-- ============================================================================
-- PLAYER CHARACTER DISCOVERY
-- ============================================================================

--[[ Find a player character using multiple class name candidates.

Tries each candidate via Utils.find_first_of until one returns a valid object.

@return userdata|nil The player character object, or nil if none found
]]
local function find_player_character()
    for _, class_name in ipairs(PLAYER_CHARACTER_CANDIDATES) do
        log(4, "FindFirstOf: " .. class_name)
        local player = Utils.find_first_of(class_name)
        if player then
            log(3, "Found player character via " .. class_name)
            return player
        end
    end
    return nil
end

-- ============================================================================
-- HEALTH PROPERTY READ / WRITE
-- ============================================================================

--[[ Read a health value from a player character, handling FGameplayAttributeData.

GAS stores attributes as FGameplayAttributeData structs containing:
  - BaseValue:    The unmodified base (set by "set by caller" or init)
  - CurrentValue: The runtime value after GameplayEffects are applied

If the property is a plain number, we return it directly.
If it's a struct, we probe CurrentValue first, then BaseValue.

@param player userdata   The player character UObject
@param health_path string Dot-separated property path (e.g., "AttributeSet.Health")
@return number|nil The health value, or nil if unreadable
@return string|nil The sub-property that worked ("CurrentValue", "BaseValue", or "" for direct)
@return boolean Whether the property is an FGameplayAttributeData struct
]]
local function read_health_value(player, health_path)
    local ok, result = pcall(function()
        if not is_valid_object(player) then return nil, nil, false end

        local value = Utils.safe_read(player, health_path)
        if value == nil then return nil, nil, false end

        -- Case 1: FGameplayAttributeData struct (userdata with sub-properties)
        if type(value) == "userdata" then
            -- Try each sub-property candidate
            for _, subprop in ipairs(ATTRIBUTE_DATA_SUBPROPS) do
                local sub_ok, sub_val = pcall(function()
                    return tonumber(value[subprop])
                end)
                if sub_ok and sub_val ~= nil then
                    return sub_val, subprop, true
                end
            end
            -- Struct exists but no readable sub-property
            log(2, "FGameplayAttributeData at " .. health_path .. " but no readable sub-property")
            return nil, nil, true
        end

        -- Case 2: Direct numeric property
        local num = tonumber(value)
        if num ~= nil then
            return num, "", false
        end

        return nil, nil, false
    end)

    if not ok then
        log(4, "read_health_value pcall failed: " .. tostring(result))
        return nil, nil, false
    end

    return result  -- returns (number|nil, string|nil, boolean)
end

--[[ Write a health value to a player character, handling FGameplayAttributeData.

If the property is an FGameplayAttributeData struct, writes to the
specified sub-property (typically CurrentValue). Otherwise writes
directly to the property.

IMPORTANT: Writing to CurrentValue is the "right" target for shadow
damage because that's what the game reads for gameplay calculations.
However, GAS may recalculate CurrentValue from BaseValue + GameplayEffects,
overwriting our modification. That's exactly what this test detects.

@param player userdata    The player character UObject
@param health_path string  Dot-separated property path
@param new_value number    The new health value to write
@param subprop string|nil  Sub-property for FGameplayAttributeData ("CurrentValue" or "BaseValue")
@param is_attr_data boolean Whether the property is an FGameplayAttributeData struct
@return boolean Whether the write succeeded
]]
local function write_health_value(player, health_path, new_value, subprop, is_attr_data)
    local ok, result = pcall(function()
        if not is_valid_object(player) then return false end

        local write_path
        if is_attr_data and subprop and #subprop > 0 then
            -- Write to the sub-property within the FGameplayAttributeData struct
            write_path = health_path .. "." .. subprop
        else
            -- Direct property write
            write_path = health_path
        end

        return Utils.safe_write(player, write_path, tonumber(new_value))
    end)

    if not ok then
        log(4, "write_health_value pcall failed: " .. tostring(result))
        return false
    end

    return result == true
end

-- ============================================================================
-- HEALTH PROPERTY DISCOVERY
-- ============================================================================

--[[ Discover the health property path on a player character.

Strategy:
1. If Config.HEALTH_PROPERTY_NAME is already set (by a prior Phase 0 script),
   try that first.
2. Otherwise, brute-force probe all HEALTH_PROPERTY_CANDIDATES.
3. For each candidate, also try FGameplayAttributeData sub-properties.

When a working path is found, we populate Config fields so later phases
don't need to re-discover:
  - Config.HEALTH_PROPERTY_NAME
  - Config.HEALTH_PROPERTY_PATH  (if nested)
  - Config.HEALTH_IS_ATTRIBUTE_DATA

@param player userdata  The player character UObject
@return string|nil The working health property path
@return number|nil The health value at that path
@return string|nil The sub-property that worked ("" for direct)
@return boolean Whether it's an FGameplayAttributeData struct
]]
local function discover_health_property(player)
    -- Build the list of paths to try, starting with the configured one
    local candidates = {}

    if Config.HEALTH_PROPERTY_NAME then
        candidates[#candidates + 1] = Config.HEALTH_PROPERTY_NAME
        -- Also try with Config.HEALTH_PROPERTY_PATH if set
        if Config.HEALTH_PROPERTY_PATH then
            candidates[#candidates + 1] = Config.HEALTH_PROPERTY_PATH
        end
    end

    for _, path in ipairs(HEALTH_PROPERTY_CANDIDATES) do
        -- Avoid duplicating the configured path
        if Config.HEALTH_PROPERTY_NAME ~= path then
            candidates[#candidates + 1] = path
        end
    end

    -- Probe each candidate
    for _, path in ipairs(candidates) do
        log(4, "Probing health property: " .. path)
        local value, subprop, is_attr_data = read_health_value(player, path)

        if value ~= nil then
            log(3, "Discovered health property: " .. path
                .. " = " .. tostring(value)
                .. (is_attr_data and (" (FGameplayAttributeData." .. subprop .. ")") or " (direct)"))

            -- Populate Config for downstream scripts
            -- Extract the leaf property name from the path
            local leaf_name = path:match("%.([^%.]+)$") or path
            if Config.HEALTH_PROPERTY_NAME == nil then
                Config.HEALTH_PROPERTY_NAME = leaf_name
            end
            if Config.HEALTH_PROPERTY_PATH == nil and path:find("%.") then
                Config.HEALTH_PROPERTY_PATH = path
            end
            if not Config.HEALTH_IS_ATTRIBUTE_DATA and is_attr_data then
                Config.HEALTH_IS_ATTRIBUTE_DATA = true
            end

            return path, value, subprop, is_attr_data
        end
    end

    return nil, nil, nil, false
end

-- ============================================================================
-- HEALTH RESTORATION
-- ============================================================================

--[[ Restore the player's original health value after the test.

This is a CRITICAL safety requirement — we must never leave a player
at reduced health after our test. We attempt restoration even if the
test failed partway through, and we verify the restoration succeeded.

@return boolean Whether the restore succeeded
]]
local function restore_original_health()
    -- Guard against double-restoration
    if test_state.restore_attempted then
        return test_state.restore_succeeded
    end
    test_state.restore_attempted = true

    -- Validate we have everything we need
    if not test_state.player_object or not test_state.health_property_path then
        log(2, "Cannot restore health: missing player object or property path")
        test_state.restore_succeeded = false
        return false
    end

    if test_state.original_health == nil then
        log(2, "Cannot restore health: original value unknown")
        test_state.restore_succeeded = false
        return false
    end

    -- Check player is still in-game
    if not is_valid_object(test_state.player_object) then
        log(2, "Cannot restore health: player object no longer valid (disconnected?)")
        test_state.restore_succeeded = false
        return false
    end

    -- Attempt the write
    log(3, "Restoring original health: " .. tostring(test_state.original_health))
    local success = write_health_value(
        test_state.player_object,
        test_state.health_property_path,
        test_state.original_health,
        test_state.attribute_subprop,
        test_state.is_attribute_data
    )

    if not success then
        log(1, "Failed to write original health value back")
        test_state.restore_succeeded = false
        return false
    end

    -- Verify the restoration took effect
    local verify_val = read_health_value(
        test_state.player_object,
        test_state.health_property_path
    )

    if verify_val and math.abs(verify_val - test_state.original_health) < GAS_OVERWRITE_TOLERANCE then
        log(3, "Health restored successfully: " .. tostring(verify_val))
        test_state.restore_succeeded = true
        return true
    else
        log(2, "Health restore verification mismatch: expected "
            .. tostring(test_state.original_health)
            .. ", got " .. tostring(verify_val))
        -- Even if verification fails, we tried. GAS may have already
        -- recalculated — that's useful information, not a crash condition.
        test_state.restore_succeeded = false
        return false
    end
end

-- ============================================================================
-- ONTICK HANDLER
-- ============================================================================

--[[ OnTick callback for the 5-second GAS overwrite monitoring window.

This function is called every game tick by the WindrosePlus mod framework.
It handles:
  1. Delta-time accumulation for the 5-second wait
  2. Per-tick health checks against the expected value
  3. GAS overwrite detection (mismatch > tolerance)
  4. Test completion and health restoration

@param delta_time number  Seconds since last tick (provided by the mod framework)
]]
local function on_tick_handler(delta_time)
    -- Skip if test hasn't entered the monitoring phase or is already done
    if not test_state.watching_for_overwrite then
        return
    end

    -- Accumulate elapsed time
    test_state.monitor_elapsed = test_state.monitor_elapsed + (delta_time or 0.0)

    -- Guard: player still valid?
    if not is_valid_object(test_state.player_object) then
        log(2, "Player disconnected during GAS monitoring")
        test_state.error_message = "Player disconnected during monitoring"
        test_state.watching_for_overwrite = false
        test_state.test_completed = true
        -- Can't restore — player is gone
        test_state.restore_succeeded = false
        test_state.restore_attempted = true
        output_phase0_report()
        return
    end

    -- Read current health on this tick
    local current_health = read_health_value(
        test_state.player_object,
        test_state.health_property_path
    )

    if current_health ~= nil and test_state.expected_after_write ~= nil then
        local diff = math.abs(current_health - test_state.expected_after_write)

        -- GAS overwrite detected: actual value diverged from expected
        if diff > GAS_OVERWRITE_TOLERANCE then
            log(3, "GAS OVERWRITE DETECTED during monitoring!")
            log(3, "  Expected: " .. tostring(test_state.expected_after_write))
            log(3, "  Actual:   " .. tostring(current_health))
            log(3, "  Delta:    " .. string.format("%.4f", diff))

            test_state.gas_overwrote = true
            test_state.gas_overwrite_time = test_state.monitor_elapsed
            test_state.gas_overwrite_expected = test_state.expected_after_write
            test_state.gas_overwrite_actual = current_health

            -- Set the Config flag so Phase 1 scripts know
            Config.GAS_OVERWRITE_DETECTED = true

            -- Notify other modules via the event bus
            EventBus.emit("gas_overwrite_detected", {
                expected       = test_state.expected_after_write,
                actual         = current_health,
                difference     = diff,
                elapsed_seconds = test_state.monitor_elapsed,
                property_path  = test_state.health_property_path,
                is_attribute_data = test_state.is_attribute_data,
            })

            -- Stop monitoring — we have our answer
            test_state.watching_for_overwrite = false
            test_state.health_after_5s = current_health
            test_state.test_completed = true

            -- Step 9: Restore original health
            restore_original_health()

            -- Step 10: Report
            output_phase0_report()
            return
        end
    end

    -- Check if the 5-second monitoring window has elapsed
    if test_state.monitor_elapsed >= GAS_MONITOR_DURATION then
        log(3, string.format("%.1f-second monitoring window complete", GAS_MONITOR_DURATION))

        -- Final health read
        test_state.health_after_5s = read_health_value(
            test_state.player_object,
            test_state.health_property_path
        )

        -- Post-wait GAS check (in case overwrite happened between ticks)
        if not test_state.gas_overwrote
            and test_state.health_after_5s ~= nil
            and test_state.expected_after_write ~= nil
        then
            local diff = math.abs(test_state.health_after_5s - test_state.expected_after_write)
            if diff > GAS_OVERWRITE_TOLERANCE then
                log(3, "GAS OVERWRITE DETECTED (post-wait final check)!")
                log(3, "  Expected: " .. tostring(test_state.expected_after_write))
                log(3, "  Actual:   " .. tostring(test_state.health_after_5s))

                test_state.gas_overwrote = true
                test_state.gas_overwrite_time = test_state.monitor_elapsed
                test_state.gas_overwrite_expected = test_state.expected_after_write
                test_state.gas_overwrite_actual = test_state.health_after_5s
                Config.GAS_OVERWRITE_DETECTED = true

                EventBus.emit("gas_overwrite_detected", {
                    expected       = test_state.expected_after_write,
                    actual         = test_state.health_after_5s,
                    difference     = diff,
                    elapsed_seconds = test_state.monitor_elapsed,
                    property_path  = test_state.health_property_path,
                    is_attribute_data = test_state.is_attribute_data,
                })
            end
        end

        -- Monitoring complete
        test_state.watching_for_overwrite = false
        test_state.test_completed = true

        -- Step 9: Restore original health
        restore_original_health()

        -- Step 10: Report
        output_phase0_report()
    end
end

-- ============================================================================
-- PHASE 0 REPORT OUTPUT
-- ============================================================================

--[[ Generate and output the Phase 0 Report Section for the health write test.

This structured report can be copy-pasted into the Phase 0 discovery
document. It includes all test results and their implications for the
shadow damage system architecture.
]]
local function output_phase0_report()
    log(3, "")
    log(3, "============================================================")
    log(3, "PHASE 0 REPORT SECTION: Health Write Test")
    log(3, "============================================================")
    log(3, "")

    -- Overall test status
    local status = test_state.test_completed and "COMPLETED" or "INCOMPLETE"
    log(3, "Test Status: " .. status)

    if test_state.error_message then
        log(1, "  Error: " .. test_state.error_message)
    end

    log(3, "")

    -- Player discovery
    local player_status = test_state.player_found and "FOUND" or "NOT FOUND"
    log(3, "Player Character: " .. player_status)

    if test_state.health_property_path then
        log(3, "  Health Property Path: " .. test_state.health_property_path)
        log(3, "  Is FGameplayAttributeData: " .. tostring(test_state.is_attribute_data))
        if test_state.is_attribute_data and test_state.attribute_subprop then
            log(3, "  Sub-property Used: " .. test_state.attribute_subprop)
        end
    end

    log(3, "")

    -- Test values
    log(3, "Test Values:")
    log(3, "  Original Health:    " .. tostring(test_state.original_health))
    log(3, "  Written Value:      " .. tostring(test_state.written_value))
    log(3, "  Write Succeeded:    " .. tostring(test_state.write_succeeded))
    log(3, "  Immediate Re-read:  " .. tostring(test_state.immediate_verify))

    log(3, "")

    -- GAS overwrite detection
    local gas_status = test_state.gas_overwrote and "DETECTED" or "NOT DETECTED"
    log(3, "GAS Overwrite: " .. gas_status)

    if test_state.gas_overwrote then
        log(3, "  Detected After:     " .. string.format("%.2f", test_state.gas_overwrite_time or 0) .. "s")
        log(3, "  Expected Value:     " .. tostring(test_state.gas_overwrite_expected))
        log(3, "  Actual Value:       " .. tostring(test_state.gas_overwrite_actual))
        log(3, "  Health After 5s:    " .. tostring(test_state.health_after_5s))
        log(3, "  Config.GAS_OVERWRITE_DETECTED = true")
    else
        log(3, "  Health After 5s:    " .. tostring(test_state.health_after_5s))
        log(3, "  Config.GAS_OVERWRITE_DETECTED = false")
    end

    log(3, "")

    -- Health restoration
    local restore_status = test_state.restore_attempted
        and (test_state.restore_succeeded and "SUCCESS" or "FAILED")
        or "NOT ATTEMPTED"
    log(3, "Health Restoration: " .. restore_status)

    log(3, "")

    -- Architecture implications — this is the key output of the test
    log(3, "Shadow Damage System Implications:")
    if test_state.gas_overwrote then
        log(2, "  [!] DIRECT PROPERTY WRITES NOT VIABLE — GAS overwrites modifications")
        log(2, "  → Shadow damage CANNOT use direct property modification")
        log(2, "  → Must use GameplayEffect-based damage application instead")
        log(2, "  → Consider hooking PreAttributeChange / PostGameplayEffectExecute")
        log(2, "  → Or apply damage via AbilitySystemComponent::ApplyGameplayEffectToTarget")
    elseif test_state.write_succeeded then
        log(3, "  [OK] DIRECT PROPERTY WRITES PERSIST — Shadow damage is viable")
        log(3, "  → Shadow damage system can use direct property modification")
        log(3, "  → Still recommend periodic re-application as safety measure")
    else
        log(2, "  [?] WRITE FAILED — Cannot determine GAS behavior")
        log(2, "  → Property may be read-only or access-restricted")
        log(2, "  → Try alternative property paths or GAS hooks")
    end

    log(3, "")
    log(3, "============================================================")
    log(3, "END HEALTH WRITE TEST REPORT")
    log(3, "============================================================")
    log(3, "")

    -- Emit structured completion event for other modules
    EventBus.emit("phase0_health_write_test_complete", {
        success           = test_state.test_completed and not test_state.error_message,
        player_found      = test_state.player_found,
        health_property_path = test_state.health_property_path,
        is_attribute_data = test_state.is_attribute_data,
        attribute_subprop = test_state.attribute_subprop,
        original_health   = test_state.original_health,
        write_succeeded   = test_state.write_succeeded,
        immediate_verify  = test_state.immediate_verify,
        gas_overwrote     = test_state.gas_overwrote,
        gas_overwrite_time = test_state.gas_overwrite_time,
        health_after_5s   = test_state.health_after_5s,
        health_restored   = test_state.restore_succeeded,
        error_message     = test_state.error_message,
    })
end

-- ============================================================================
-- MAIN TEST EXECUTION
-- ============================================================================

--[[ Execute the health write test protocol (Steps 1–6).

This function runs the synchronous portion of the test:
  Step 1: Find player character
  Step 2: Discover health property (with FGameplayAttributeData handling)
  Step 3: Store original health value
  Step 4: Write original_value - TEST_DAMAGE_AMOUNT
  Step 5: Immediate re-read to verify write
  Step 6: Begin 5-second GAS overwrite monitoring (delegated to OnTick)

Steps 7–10 are handled by on_tick_handler:
  Step 7: Re-read after 5 seconds
  Step 8: Detect GAS overwrite and set Config flag
  Step 9: Restore original health
  Step 10: Output report
]]
local function execute_health_write_test()
    -- Guard: only run once
    if test_state.test_started then
        log(4, "Test already started, skipping")
        return
    end
    test_state.test_started = true

    log(3, "Starting health write test protocol...")

    -- ── Step 1: Find player character ──────────────────────────────────
    log(3, "Step 1: Finding player character...")
    local player = find_player_character()

    if not player then
        log(2, "No player character found — cannot run test")
        test_state.error_message = "No player character found"
        test_state.test_completed = true
        output_phase0_report()
        return
    end

    test_state.player_found = true
    test_state.player_object = player
    log(3, "Player found: " .. Utils.player_id(player))

    -- ── Step 2: Discover health property ───────────────────────────────
    log(3, "Step 2: Discovering health property...")
    local health_path, health_value, subprop, is_attr_data = discover_health_property(player)

    if not health_path or health_value == nil then
        log(1, "Could not discover any health property on player character")
        test_state.error_message = "Health property not found — tried "
            .. #HEALTH_PROPERTY_CANDIDATES .. " candidates"
        test_state.test_completed = true
        output_phase0_report()
        return
    end

    test_state.health_property_path = health_path
    test_state.is_attribute_data = is_attr_data
    test_state.attribute_subprop = subprop

    -- ── Step 3: Store original health value ────────────────────────────
    log(3, "Step 3: Storing original health value...")
    test_state.original_health = health_value
    log(3, "  Original health: " .. tostring(test_state.original_health))

    -- Sanity check: health should be a positive number
    if test_state.original_health <= 0 then
        log(2, "Original health is <= 0 — player may be dead, aborting test")
        test_state.error_message = "Original health <= 0 (player dead?)"
        test_state.test_completed = true
        output_phase0_report()
        return
    end

    -- ── Step 4: Write modified health (original - TEST_DAMAGE_AMOUNT) ──
    log(3, "Step 4: Writing modified health...")
    test_state.written_value = math.max(0, test_state.original_health - TEST_DAMAGE_AMOUNT)
    log(3, "  Writing: " .. tostring(test_state.written_value)
        .. " (original " .. tostring(test_state.original_health)
        .. " - " .. tostring(TEST_DAMAGE_AMOUNT) .. ")")

    test_state.write_succeeded = write_health_value(
        player,
        health_path,
        test_state.written_value,
        subprop,
        is_attr_data
    )

    if not test_state.write_succeeded then
        log(1, "Write operation failed — property may be read-only")
        test_state.error_message = "Write operation failed"
        -- Still try to restore (in case a partial write happened)
        restore_original_health()
        test_state.test_completed = true
        output_phase0_report()
        return
    end

    log(3, "  Write succeeded")

    -- ── Step 5: Immediate re-read to verify write ──────────────────────
    log(3, "Step 5: Immediate re-read to verify write...")
    test_state.immediate_verify = read_health_value(player, health_path)

    if test_state.immediate_verify == nil then
        log(1, "Could not read health after write — property may have been destroyed")
        test_state.error_message = "Post-write read returned nil"
        restore_original_health()
        test_state.test_completed = true
        output_phase0_report()
        return
    end

    local immediate_diff = math.abs(test_state.immediate_verify - test_state.written_value)

    if immediate_diff > GAS_OVERWRITE_TOLERANCE then
        -- GAS may have already overwritten our write within the same frame
        log(2, "Immediate verify shows different value!")
        log(2, "  Expected: " .. tostring(test_state.written_value))
        log(2, "  Actual:   " .. tostring(test_state.immediate_verify))
        log(2, "  Delta:    " .. string.format("%.4f", immediate_diff))
        log(2, "  GAS may have overwritten within the same frame")
    else
        log(3, "  Immediate verify passed: " .. tostring(test_state.immediate_verify))
    end

    -- Use the actual verified value as our "expected" for GAS monitoring.
    -- This accounts for any immediate GAS correction.
    test_state.expected_after_write = test_state.immediate_verify

    -- ── Step 6: Begin 5-second GAS overwrite monitoring ────────────────
    log(3, "Step 6: Starting " .. GAS_MONITOR_DURATION .. "-second GAS overwrite monitoring...")
    log(3, "  Expected value: " .. tostring(test_state.expected_after_write))
    log(3, "  Will check every tick for divergence > " .. tostring(GAS_OVERWRITE_TOLERANCE))

    test_state.monitor_elapsed = 0.0
    test_state.watching_for_overwrite = true
    test_state.test_running = true

    -- The on_tick_handler will handle Steps 7–10
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

--[[ Initialize the health write test module.

Entry point called when the script is loaded. It:
1. Registers the self-test in Utils
2. Registers the OnTick handler with the mod framework
3. Attempts to find a player immediately
4. If no player found, registers NotifyOnNewObject to retry when one joins
]]
local function init()
    log(3, "============================================================")
    log(3, "Phase 0 Health Write Test — Initializing")
    log(3, "============================================================")

    -- ── Register self-test ──────────────────────────────────────────────
    -- The self-test verifies that the module loaded correctly and that
    -- the test protocol completed (or at least started).
    Utils.register_test(MODULE_NAME, function()
        -- Basic structural checks
        if type(test_state) ~= "table" then
            return false
        end

        -- If the test completed, verify the critical safety property:
        -- we MUST have attempted to restore the player's health.
        if test_state.test_completed then
            if not test_state.restore_attempted then
                return false
            end
            -- If a player was found and we modified health, restoration
            -- should have been attempted. Success depends on GAS behavior
            -- and player connectivity, so we don't require restore_succeeded.
        end

        -- Config flag should be a boolean after the test runs
        if type(Config.GAS_OVERWRITE_DETECTED) ~= "boolean" then
            return false
        end

        return true
    end)

    -- ── Register OnTick handler ────────────────────────────────────────
    -- The WindrosePlus mod framework provides an OnTick callback that
    -- receives delta_time as a parameter. We register our handler here.
    --
    -- Pattern: the mod framework calls our OnTick function each frame
    -- with (delta_time) as the argument. This gives us accurate timing
    -- for the 5-second monitoring window instead of relying on tick counts.
    if WindrosePlus and WindrosePlus.OnTick then
        WindrosePlus.OnTick(function(delta_time)
            on_tick_handler(delta_time)
        end)
        log(3, "OnTick handler registered via WindrosePlus.OnTick")
    else
        -- Fallback: try global OnTick registration if available
        -- Some UE4SS setups expose OnTick as a global registration function
        local ok, result = pcall(function()
            if OnTick then
                OnTick(function(delta_time)
                    on_tick_handler(delta_time or 0.0)
                end)
                return true
            end
            return false
        end)

        if ok and result then
            log(3, "OnTick handler registered via global OnTick")
        else
            log(2, "No OnTick registration available — GAS monitoring will not work")
            log(2, "The test will still attempt the write, but cannot detect delayed GAS overwrites")
        end
    end

    -- ── Find player or register for new player notification ────────────
    local player = find_player_character()

    if player then
        -- Player already in-game: run the test immediately
        log(3, "Player found at init time, running test...")
        execute_health_write_test()
    else
        -- No player connected yet: watch for new player objects
        log(3, "No player found at init time, registering NotifyOnNewObject...")

        for _, class_name in ipairs(PLAYER_CHARACTER_CANDIDATES) do
            log(4, "  Trying NotifyOnNewObject: " .. class_name)

            local registered = Utils.notify_on_new_object(class_name, function(new_player)
                -- Only trigger the test once
                if test_state.test_started then
                    log(4, "New player joined but test already started, ignoring")
                    return
                end

                if not is_valid_object(new_player) then
                    log(4, "NotifyOnNewObject fired with invalid object, ignoring")
                    return
                end

                log(3, "New player joined: " .. Utils.player_id(new_player))
                test_state.player_object = new_player
                test_state.player_found = true
                execute_health_write_test()
            end)

            if registered then
                log(3, "  Registered for: " .. class_name)
                notify_registered = true
                break
            end
        end

        if not notify_registered then
            log(2, "Could not register NotifyOnNewObject for any player class")
            log(2, "Test will not run until a player is found manually")
            log(2, "Use the run_test() export after a player connects")
        end
    end
end

-- ============================================================================
-- SCRIPT INITIALIZATION
-- ============================================================================

-- Execute initialization
init()

-- ============================================================================
-- MODULE EXPORTS
-- ============================================================================

-- Return module for external access and manual test triggering
return {
    --- Current test state (read-only for external consumers)
    state = test_state,

    --- Get a copy of the current test state
    get_state = function()
        -- Return a shallow copy to prevent external mutation
        local copy = {}
        for k, v in pairs(test_state) do
            copy[k] = v
        end
        return copy
    end,

    --- Manually trigger the test (if it hasn't run yet).
    --- Useful if NotifyOnNewObject failed and a player connects later.
    run_test = function()
        if not test_state.test_started then
            execute_health_write_test()
        else
            log(2, "Test already started, cannot re-run")
        end
    end,

    --- Check if the test has completed
    is_complete = function()
        return test_state.test_completed
    end,

    --- Check if GAS overwrite was detected
    gas_detected = function()
        return test_state.gas_overwrote
    end,
}
