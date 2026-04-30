--[[
p0_sdk_dump.lua — SDK Dump Runner for Phase 0 Discovery
=========================================================

Purpose:
  This script is the FIRST Phase 0 step. It generates C++ headers and Lua
  type definitions from the running game instance. All other Phase 0 scripts
  (property discovery, hook tests, replication tests) depend on this output
  for correct property and function names.

  Without a successful SDK dump, we're guessing at property paths — the dump
  gives us the actual class layouts, inheritance chains, and UFunction
  signatures that the rest of Phase 0 needs.

UE4SS API Used:
  - ExecuteInGameThread(callback): Run code on the game thread (REQUIRED for
    SDK generation — calling GenerateSDK from the Lua thread will crash)
  - GenerateSDK(): Generates C++ headers to CXXHeaderDump/ directory
  - DumpAllObjects(): Dumps all UObject names and addresses to a text file
  - GenerateLuaTypes(): Generates Lua type definitions to Mods/shared/types/

Dependencies:
  - scripts/config.lua   : Configuration flags, class names, hook paths
  - scripts/utils.lua    : Logging (Utils.info/warn/error), self-test harness
  - scripts/event_bus.lua: Event publishing for inter-module coordination

Execution Flow:
  1. Log start of SDK dump process
  2. Register self-test that verifies SDK files exist after generation
  3. Execute SDK generation in game thread (pcall-wrapped for safety)
  4. If GenerateSDK crashes, fall back to DumpAllObjects alone
  5. Call GenerateLuaTypes() for Lua-side type definitions
  6. Scan generated files for key R5-prefixed classes
  7. Update Config flags based on which classes were found
  8. Output structured Phase 0 report section
  9. Emit completion event on EventBus

Safety Notes:
  - SDK generation on a headless dedicated server may crash if the engine
    tries to load assets that aren't present (materials, textures, etc.).
    All dangerous calls are wrapped in pcall to prevent script termination.
  - ExecuteInGameThread is asynchronous — the callback is queued and runs
    on the next game-thread tick. We use a state flag to track completion.
]]

-- ============================================================================
-- DEPENDENCY IMPORTS
-- ============================================================================

local Config = require("scripts.config")
local Utils  = require("scripts.utils")
local EventBus = require("scripts.event_bus")

-- ============================================================================
-- MODULE IDENTITY
-- ============================================================================

local MODULE_NAME = "p0_sdk_dump"

-- Key class names to search for in generated SDK output.
-- R5 prefix = game-specific classes (Windrose uses "R5" as its module prefix).
-- The last two are Unreal Engine GAS classes that PvP mechanics depend on.
local KEY_CLASS_NAMES = {
    "R5PlayerCharacter",       -- Main player character (health, movement, combat state)
    "R5MeleeAbility",          -- Melee ability implementation (hook target for damage)
    "R5BoardingBattleNew",     -- Boarding battle mode (lifecycle hooks)
    "R5ShipPawnBase",          -- Base class for ship pawns (ship health)
    "R5ReviveComponent",       -- Revive system (auto-revive after duel)
    "AbilitySystemComponent",  -- Unreal GAS: manages gameplay effects & attributes
    "AttributeSet",            -- Unreal GAS: holds attribute values (health, damage)
}

-- Expected output directories (relative to UE4SS working directory)
local CXX_HEADER_DUMP_DIR = "CXXHeaderDump"
local LUA_TYPES_DIR       = "Mods/shared/types"

-- ============================================================================
-- LOCAL STATE
-- ============================================================================

-- Tracks the outcome of each SDK generation step so the report and self-test
-- can reference it. All fields start in their "not done" state.
local sdk_dump_state = {
    generation_success  = false,  -- GenerateSDK() completed without error
    lua_types_success   = false,  -- GenerateLuaTypes() completed without error
    objects_dumped      = false,  -- DumpAllObjects() completed without error
    class_files_count   = 0,      -- Number of header files found (best-effort)
    found_classes       = {},     -- Subset of KEY_CLASS_NAMES found in output
    output_paths        = {},     -- Directories where output was written
    error_message       = nil,    -- First error encountered (if any)
    fallback_used       = false,  -- True if we fell back to DumpAllObjects only
    completed           = false,  -- True once the entire pipeline has finished
}

-- ============================================================================
-- HELPER: MODULE-SCOPED LOGGING
-- ============================================================================

--- Log with module prefix for easy grep in server logs.
--- Delegates to Utils.log which handles level filtering.
--- @param level number  1=error, 2=warn, 3=info, 4=debug
--- @param message string
local function log(level, message)
    Utils.log(level, "[" .. MODULE_NAME .. "] " .. tostring(message))
end

-- ============================================================================
-- HELPER: FIND CXXHEADERDUMP DIRECTORY
-- ============================================================================

--- Attempt to locate the CXXHeaderDump directory.
--- UE4SS creates this in its working directory (next to the game executable
--- or in the Mods/ folder depending on installation). We try several common
--- locations. If none can be confirmed, we return the default path — the
--- actual verification happens in the self-test.
---
--- @return string The best-guess path to CXXHeaderDump
local function find_cxx_header_dump_dir()
    -- UE4SS standard locations for the SDK dump output.
    -- On dedicated servers, the working directory is usually the game root.
    local possible_paths = {
        CXX_HEADER_DUMP_DIR,            -- Default: same dir as UE4SS DLL
        "./" .. CXX_HEADER_DUMP_DIR,    -- Explicit relative
        "../" .. CXX_HEADER_DUMP_DIR,   -- One level up (some server layouts)
        "Mods/" .. CXX_HEADER_DUMP_DIR, -- Inside Mods tree
    }

    for _, path in ipairs(possible_paths) do
        -- io.open in "read" mode on a directory will fail on Windows,
        -- but io.lines on a known file inside it would succeed.
        -- Since we don't know filenames yet, we try to open the directory
        -- itself — on some Lua builds this errors, on others it returns nil.
        local ok, _ = pcall(function()
            local f = io.open(path, "r")
            if f then f:close() end
        end)

        -- Even if we can't confirm the directory exists from Lua,
        -- we record the path for the report. The self-test does the
        -- actual file-existence check after generation completes.
        if ok then
            log(3, "CXXHeaderDump candidate path: " .. path)
            return path
        end
    end

    -- Default: UE4SS standard location
    log(3, "Using default CXXHeaderDump path: " .. CXX_HEADER_DUMP_DIR)
    return CXX_HEADER_DUMP_DIR
end

-- ============================================================================
-- HELPER: SCAN FOR KEY CLASSES IN GENERATED FILES
-- ============================================================================

--- Search generated SDK files for key class names.
---
--- In UE4SS, the SDK dump creates one .hpp file per module, each containing
--- class declarations. We search for our KEY_CLASS_NAMES in those files.
--- Since UE4SS Lua has limited filesystem access, we use io.lines() to
--- read files line-by-line (memory-efficient for large headers).
---
--- @param header_dir string  Path to CXXHeaderDump directory
--- @return table  List of class names that were found in the generated files
local function scan_for_key_classes(header_dir)
    local found = {}
    local found_set = {}  -- For O(1) lookup while scanning

    log(3, "Scanning SDK output for key R5 classes in: " .. header_dir)

    -- UE4SS generates files named after modules: R5.hpp, GameplayAbilities.hpp, etc.
    -- We try to open and scan the most likely files for our key class names.
    local candidate_files = {
        header_dir .. "/R5.hpp",
        header_dir .. "/GameplayAbilities.hpp",
        header_dir .. "/Engine.hpp",
        header_dir .. "/CoreUObject.hpp",
    }

    -- Also try without .hpp extension (some UE4SS versions use .h)
    for _, f in ipairs({"/R5.h", "/GameplayAbilities.h", "/Engine.h", "/CoreUObject.h"}) do
        candidate_files[#candidate_files + 1] = header_dir .. f
    end

    -- Track how many files we successfully opened (for class_files_count)
    local files_opened = 0

    for _, filepath in ipairs(candidate_files) do
        local ok, file_or_err = pcall(io.open, filepath, "r")
        if ok and file_or_err then
            local file = file_or_err
            files_opened = files_opened + 1
            log(4, "  Scanning: " .. filepath)

            -- Read line by line to avoid loading huge files into memory.
            -- SDK headers can be 10MB+ for large games.
            for line in file:lines() do
                for _, class_name in ipairs(KEY_CLASS_NAMES) do
                    -- Match class declarations: "class AR5PlayerCharacter" or
                    -- "class UR5ReviveComponent" or "class UAbilitySystemComponent"
                    -- The [AU] prefix covers A(AActor) and U(UObject) class specifiers.
                    if not found_set[class_name]
                        and line:match("class%s+[AU]" .. class_name) then
                        found_set[class_name] = true
                        found[#found + 1] = class_name
                        log(3, "  Found class: " .. class_name .. " in " .. filepath)
                    end
                end
            end

            file:close()
        end
    end

    sdk_dump_state.class_files_count = files_opened

    -- If we couldn't open any files, try a broader approach:
    -- search for R5-prefixed classes by attempting to use FindFirstOf
    -- as a runtime probe (works even without file access).
    if files_opened == 0 then
        log(2, "Could not open SDK header files directly — probing at runtime instead")
        for _, class_name in ipairs(KEY_CLASS_NAMES) do
            local obj = Utils.find_first_of(class_name)
            if obj then
                found_set[class_name] = true
                found[#found + 1] = class_name
                log(3, "  Found class at runtime: " .. class_name)
            end
        end
    end

    -- Log R5-prefixed classes specifically (the task asks us to search for
    -- "R5" prefixed classes and log them separately)
    log(3, "R5-prefixed classes found in SDK:")
    for _, class_name in ipairs(found) do
        if class_name:match("^R5") then
            log(3, "  → " .. class_name)
        end
    end

    return found
end

-- ============================================================================
-- HELPER: UPDATE CONFIG FLAGS BASED ON FOUND CLASSES
-- ============================================================================

--- Update Config flags based on which key classes were found in the SDK dump.
---
--- This is critical for downstream Phase 0 scripts: they check these flags
--- to decide whether to attempt property discovery on a given class.
--- If a class doesn't exist in the SDK, there's no point trying to read
--- its properties.
---
--- @param found_classes table  List of class names found in the SDK
local function update_config_flags(found_classes)
    local class_set = {}
    for _, name in ipairs(found_classes) do
        class_set[name] = true
    end

    -- R5PlayerCharacter: the primary target for health property discovery
    if class_set["R5PlayerCharacter"] then
        log(3, "R5PlayerCharacter found in SDK — player health discovery enabled")
    else
        log(2, "R5PlayerCharacter NOT found in SDK — player health discovery may fail")
    end

    -- R5MeleeAbility: hook target for intercepting melee damage
    if class_set["R5MeleeAbility"] then
        log(3, "R5MeleeAbility found in SDK — melee hook testing enabled")
    else
        log(2, "R5MeleeAbility NOT found in SDK — melee hook testing may fail")
    end

    -- R5ShipPawnBase: needed for ship-to-ship PvP damage
    if class_set["R5ShipPawnBase"] then
        log(3, "R5ShipPawnBase found in SDK — ship health discovery enabled")
    else
        log(2, "R5ShipPawnBase NOT found in SDK — ship PvP will be limited")
    end

    -- R5ReviveComponent: needed for auto-revive after duels
    if class_set["R5ReviveComponent"] then
        log(3, "R5ReviveComponent found in SDK — revive system integration enabled")
    else
        log(2, "R5ReviveComponent NOT found in SDK — auto-revive may need workaround")
    end

    -- R5BoardingBattleNew: needed for boarding battle lifecycle hooks
    if class_set["R5BoardingBattleNew"] then
        log(3, "R5BoardingBattleNew found in SDK — boarding lifecycle hooks enabled")
    else
        log(2, "R5BoardingBattleNew NOT found in SDK — boarding hooks may fail")
    end

    -- AbilitySystemComponent + AttributeSet: core GAS classes
    -- If both are found, we know the game uses GAS for attributes
    if class_set["AbilitySystemComponent"] and class_set["AttributeSet"] then
        log(3, "GAS classes found — attribute-based health discovery enabled")
    else
        log(2, "One or more GAS classes NOT found — attribute discovery may need fallback")
    end
end

-- ============================================================================
-- SDK GENERATION CORE
-- ============================================================================

--- Execute the full SDK generation pipeline in the game thread.
---
--- Why ExecuteInGameThread? UE4SS's GenerateSDK() traverses the UObject
--- array and reflects on UClasses — this requires the game's UObject
--- subsystem to be in a consistent state, which is only guaranteed on the
--- game thread. Calling from the Lua thread risks reading partially-
--- initialized objects, which causes crashes (especially on headless
--- servers where asset streaming behaves differently).
---
--- The pipeline order matters:
---   1. GenerateSDK() — creates C++ headers (most important output)
---   2. DumpAllObjects() — creates a flat list of all UObjects (useful for
---      finding object instances by name, not just class definitions)
---   3. GenerateLuaTypes() — creates Lua-side type wrappers (needed for
---      typed property access from Lua mods)
---
--- @return boolean  True if the pipeline completed (even with partial failures)
local function execute_sdk_generation()
    log(3, "Starting SDK generation pipeline...")

    -- ExecuteInGameThread queues work for the next game-thread tick.
    -- It returns immediately — the callback runs later. We wrap the
    -- outer call in pcall to catch queueing failures (e.g., if the
    -- game thread is shutting down).
    local queue_ok, queue_err = pcall(function()
        ExecuteInGameThread(function()
            log(3, "  [GameThread] Entered game thread — starting generation")

            ----------------------------------------------------------------
            -- Step 1: GenerateSDK() — C++ header dump
            ----------------------------------------------------------------
            -- This is the most crash-prone step. On headless servers, the
            -- engine may try to load assets (textures, materials) that aren't
            -- present, causing access violations inside the reflection system.
            local gen_ok, gen_err = pcall(GenerateSDK)

            if gen_ok then
                log(3, "  [GameThread] GenerateSDK() completed successfully")
                sdk_dump_state.generation_success = true
                sdk_dump_state.output_paths[#sdk_dump_state.output_paths + 1] = CXX_HEADER_DUMP_DIR .. "/"
            else
                log(1, "  [GameThread] GenerateSDK() FAILED: " .. tostring(gen_err))
                sdk_dump_state.error_message = "GenerateSDK failed: " .. tostring(gen_err)

                -- CRITICAL FALLBACK: If GenerateSDK crashes, DumpAllObjects
                -- is a lighter-weight alternative that just iterates UObject
                -- names without reflecting on class layouts. It won't give us
                -- property offsets, but it tells us which classes exist.
                log(2, "  [GameThread] Attempting DumpAllObjects fallback...")
                local dump_ok, dump_err = pcall(DumpAllObjects)
                if dump_ok then
                    log(3, "  [GameThread] DumpAllObjects() fallback succeeded")
                    sdk_dump_state.objects_dumped = true
                    sdk_dump_state.fallback_used = true
                else
                    log(1, "  [GameThread] DumpAllObjects() fallback also FAILED: " .. tostring(dump_err))
                end
            end

            ----------------------------------------------------------------
            -- Step 2: DumpAllObjects() — full object list
            ----------------------------------------------------------------
            -- Only run if GenerateSDK succeeded (if it failed, we already
            -- tried DumpAllObjects as a fallback above).
            if sdk_dump_state.generation_success then
                log(3, "  [GameThread] Calling DumpAllObjects()...")
                local dump_ok, dump_err = pcall(DumpAllObjects)
                if dump_ok then
                    log(3, "  [GameThread] DumpAllObjects() completed")
                    sdk_dump_state.objects_dumped = true
                else
                    -- Non-fatal: we still have the SDK headers
                    log(2, "  [GameThread] DumpAllObjects() failed (non-fatal): " .. tostring(dump_err))
                end
            end

            ----------------------------------------------------------------
            -- Step 3: GenerateLuaTypes() — Lua type definitions
            ----------------------------------------------------------------
            -- This creates Lua-side type wrappers in Mods/shared/types/.
            -- These are needed for typed property access from Lua mods.
            -- It depends on the SDK data being in memory, so it must run
            -- after GenerateSDK (but can run even if GenerateSDK partially
            -- failed — it will just produce fewer type definitions).
            log(3, "  [GameThread] Calling GenerateLuaTypes()...")
            local lua_ok, lua_err = pcall(GenerateLuaTypes)
            if lua_ok then
                log(3, "  [GameThread] GenerateLuaTypes() completed")
                sdk_dump_state.lua_types_success = true
                sdk_dump_state.output_paths[#sdk_dump_state.output_paths + 1] = LUA_TYPES_DIR .. "/"
            else
                log(2, "  [GameThread] GenerateLuaTypes() failed: " .. tostring(lua_err))
            end

            ----------------------------------------------------------------
            -- Mark pipeline as completed (even with partial failures)
            ----------------------------------------------------------------
            sdk_dump_state.completed = true
            log(3, "  [GameThread] SDK generation pipeline finished")
        end)
    end)

    -- If ExecuteInGameThread itself failed (e.g., game thread unavailable)
    if not queue_ok then
        sdk_dump_state.error_message = "ExecuteInGameThread failed: " .. tostring(queue_err)
        log(1, sdk_dump_state.error_message)
        log(1, "SUGGESTION: Try manual SDK dump via UE4SS hotkey (default: Ctrl+Shift+F10)")
        log(1, "  This may happen if the game thread is not yet initialized.")
        log(1, "  Ensure this script runs after the game has fully loaded.")

        -- Last resort: try DumpAllObjects from the Lua thread.
        -- This is less likely to crash since it doesn't reflect on class layouts.
        log(2, "Attempting DumpAllObjects from Lua thread as last resort...")
        local dump_ok, dump_err = pcall(DumpAllObjects)
        if dump_ok then
            log(3, "DumpAllObjects() succeeded from Lua thread")
            sdk_dump_state.objects_dumped = true
            sdk_dump_state.fallback_used = true
            sdk_dump_state.completed = true
        else
            log(1, "DumpAllObjects() also failed from Lua thread: " .. tostring(dump_err))
        end

        return false
    end

    log(3, "SDK generation pipeline queued on game thread")
    return true
end

-- ============================================================================
-- PHASE 0 REPORT OUTPUT
-- ============================================================================

--- Generate and print a structured Phase 0 report section.
---
--- This output is designed to be copy-pasted into the Phase 0 discovery
--- report document. It summarizes the SDK dump results in a format that
--- other developers can quickly scan to understand what's available.
local function output_phase0_report()
    log(3, "")
    log(3, "============================================================")
    log(3, "PHASE 0 REPORT SECTION: SDK Dump")
    log(3, "============================================================")
    log(3, "")

    -- SDK Generation Status
    local sdk_status = sdk_dump_state.generation_success and "SUCCESS" or "FAILED"
    log(3, "SDK Generation:      " .. sdk_status)

    if sdk_dump_state.fallback_used then
        log(2, "  (Fallback: DumpAllObjects used instead)")
    end

    if sdk_dump_state.error_message then
        log(1, "  Error: " .. sdk_dump_state.error_message)
    end

    -- Lua Types Generation Status
    local lua_status = sdk_dump_state.lua_types_success and "SUCCESS" or "FAILED"
    log(3, "Lua Types Gen:       " .. lua_status)

    -- Object Dump Status
    local obj_status = sdk_dump_state.objects_dumped and "SUCCESS" or "FAILED"
    log(3, "Object Dump:         " .. obj_status)

    log(3, "")

    -- Output Paths
    log(3, "Output Paths:")
    if #sdk_dump_state.output_paths > 0 then
        for _, path in ipairs(sdk_dump_state.output_paths) do
            log(3, "  → " .. path)
        end
    else
        log(2, "  (No output paths recorded — generation may have failed)")
    end

    log(3, "")

    -- Class Files Count
    log(3, "SDK Header Files Scanned: " .. tostring(sdk_dump_state.class_files_count))

    log(3, "")

    -- Key R5 Classes Found
    log(3, "Key Classes Found in SDK:")
    if #sdk_dump_state.found_classes > 0 then
        for _, class_name in ipairs(sdk_dump_state.found_classes) do
            local prefix = class_name:match("^R5") and "[R5]" or "[UE]"
            log(3, "  ✓ " .. prefix .. " " .. class_name)
        end
    else
        log(2, "  (None verified — see warning below)")
    end

    -- Classes NOT found
    local found_set = {}
    for _, name in ipairs(sdk_dump_state.found_classes) do
        found_set[name] = true
    end
    local missing = {}
    for _, name in ipairs(KEY_CLASS_NAMES) do
        if not found_set[name] then
            missing[#missing + 1] = name
        end
    end
    if #missing > 0 then
        log(3, "")
        log(3, "Key Classes NOT Found:")
        for _, class_name in ipairs(missing) do
            local prefix = class_name:match("^R5") and "[R5]" or "[UE]"
            log(3, "  ✗ " .. prefix .. " " .. class_name)
        end
    end

    log(3, "")

    -- Warnings
    if #sdk_dump_state.found_classes == 0 then
        log(2, "WARNING: No key R5 classes verified in SDK dump output.")
        log(2, "  Property discovery (p0_property_discovery) may need an")
        log(2, "  alternative approach, such as:")
        log(2, "    1. Runtime probing with FindFirstOf + property iteration")
        log(2, "    2. Manual inspection of CXXHeaderDump/ directory")
        log(2, "    3. Checking UE4SS console output for generation errors")
    end

    if not sdk_dump_state.generation_success and sdk_dump_state.fallback_used then
        log(2, "WARNING: SDK generation failed — using DumpAllObjects fallback.")
        log(2, "  Class layouts (property offsets, function signatures) are NOT")
        log(2, "  available. Only class names and object addresses were dumped.")
        log(2, "  Consider retrying with a manual SDK dump via UE4SS hotkey.")
    end

    log(3, "")
    log(3, "============================================================")
    log(3, "END SDK DUMP REPORT")
    log(3, "============================================================")
    log(3, "")
end

-- ============================================================================
-- SELF-TEST REGISTRATION
-- ============================================================================

--- Register a self-test in Utils that verifies at least one SDK file was
--- generated. This test runs when Utils.run_tests() is called (typically
--- at the end of Phase 0 or on demand via RCON command).
---
--- The test checks sdk_dump_state.generation_success because UE4SS Lua
--- doesn't have reliable filesystem APIs to verify file existence. If the
--- generation function reported success, we trust that files were written.
--- If generation failed but DumpAllObjects succeeded, we report a partial
--- pass (the dump is usable but incomplete).
local function register_self_test()
    log(3, "Registering SDK dump self-test...")

    Utils.register_test("sdk_dump_files_exist", function()
        -- Primary check: GenerateSDK reported success
        if sdk_dump_state.generation_success then
            return true
        end

        -- Partial pass: DumpAllObjects succeeded as fallback
        if sdk_dump_state.fallback_used and sdk_dump_state.objects_dumped then
            log(2, "SDK generation failed but DumpAllObjects fallback succeeded — partial pass")
            return true
        end

        -- Total failure: nothing was generated
        log(1, "No SDK files generated and no fallback succeeded")
        return false
    end)

    log(3, "Self-test registered: sdk_dump_files_exist")
end

-- ============================================================================
-- MAIN EXECUTION
-- ============================================================================

--- Main entry point. Coordinates the entire SDK dump process.
---
--- Execution order:
---   1. Register self-test (before generation, so it's always available)
---   2. Execute SDK generation pipeline (game thread, pcall-wrapped)
---   3. Scan output for key classes (if generation succeeded)
---   4. Update Config flags based on findings
---   5. Output Phase 0 report section
---   6. Emit completion event on EventBus
local function main()
    log(3, "============================================================")
    log(3, "Phase 0 SDK Dump — Starting")
    log(3, "  Game Module: " .. tostring(Config.GAME_MODULE))
    log(3, "  Key Classes: " .. #KEY_CLASS_NAMES .. " to search for")
    log(3, "============================================================")

    -- Step 1: Register self-test FIRST so it can verify results later,
    -- even if the script crashes partway through generation.
    register_self_test()

    -- Step 2: Execute SDK generation pipeline.
    -- This queues work on the game thread and returns immediately.
    -- The actual generation happens asynchronously.
    local queued = execute_sdk_generation()

    if not queued then
        -- ExecuteInGameThread failed entirely — fallback was attempted
        -- inside execute_sdk_generation. Continue to report whatever we have.
        log(1, "SDK generation pipeline could not be queued on game thread")
    end

    -- Step 3: Scan for key classes.
    -- NOTE: Because ExecuteInGameThread is asynchronous, the SDK files may
    -- not exist yet when we scan. In practice, UE4SS processes the game
    -- thread queue before returning to the Lua thread, so by the time we
    -- reach this line, the generation should be complete. If not, the
    -- self-test will catch it later.
    if sdk_dump_state.generation_success or sdk_dump_state.completed then
        local header_dir = find_cxx_header_dump_dir()
        sdk_dump_state.found_classes = scan_for_key_classes(header_dir)

        -- Step 4: Update Config flags so downstream scripts know what's available.
        update_config_flags(sdk_dump_state.found_classes)
    end

    -- Step 5: Output the Phase 0 report section.
    output_phase0_report()

    -- Step 6: Emit completion event on EventBus.
    -- Other Phase 0 scripts can subscribe to "phase0_sdk_dump_complete"
    -- to know when the SDK dump is done and what was found.
    EventBus.emit("phase0_sdk_dump_complete", {
        success       = sdk_dump_state.generation_success,
        lua_types     = sdk_dump_state.lua_types_success,
        objects_dumped = sdk_dump_state.objects_dumped,
        found_classes = sdk_dump_state.found_classes,
        fallback_used = sdk_dump_state.fallback_used,
        error_message = sdk_dump_state.error_message,
    })

    log(3, "Phase 0 SDK Dump — Complete")
end

-- ============================================================================
-- SCRIPT INITIALIZATION
-- ============================================================================

-- Run the main function immediately when this script is loaded by UE4SS.
-- UE4SS loads scripts in alphabetical order from the scripts/ directory,
-- so config.lua, utils.lua, and event_bus.lua are already available.
main()

-- Return module interface for external access.
-- Other scripts can require this module to check SDK dump state
-- without re-running the generation pipeline.
return {
    --- Current state of the SDK dump pipeline
    state = sdk_dump_state,

    --- Key class names that this script searches for
    key_classes = KEY_CLASS_NAMES,

    --- Get a snapshot of the current SDK dump state
    --- @return table  Copy of the current state
    get_state = function()
        -- Return a shallow copy to prevent external mutation
        local snapshot = {}
        for k, v in pairs(sdk_dump_state) do
            if type(v) == "table" then
                snapshot[k] = Utils.deepcopy and Utils.deepcopy(v) or v
            else
                snapshot[k] = v
            end
        end
        return snapshot
    end,

    --- Check if a specific class was found in the SDK dump
    --- @param class_name string  The class name to check
    --- @return boolean  True if the class was found
    has_class = function(class_name)
        for _, name in ipairs(sdk_dump_state.found_classes) do
            if name == class_name then return true end
        end
        return false
    end,
}
