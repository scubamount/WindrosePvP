--[[
p0_boarding_lifecycle.lua - Boarding Battle Lifecycle Explorer for Phase 0
==========================================================================

Purpose:
Phase 0 discovery script to map the state machine of AR5BoardingBattleNew,
the boarding battle system in Windrose. Boarding is a natural PvP arena
candidate — this script explores whether we can hook into and monitor
boarding battles for PvP integration.

UE4SS API Used:
- NotifyOnNewObject(class_name, callback): Detect boarding battle creation
- RegisterHook(hook_path, pre_fn, post_fn): Hook into ability activation
- OnTick.Add(callback): Poll boarding battle objects for state changes
- pcall: Safe property access with error isolation
- FindFirstOf, FindAllOf: Locate boarding objects

Dependencies:
- scripts/config.lua: Config.BOARDING_HOOK_WORKS flag, class names, hook paths
- scripts/utils.lua: Safe property access, hook registration, logging, self-tests
- scripts/event_bus.lua: Event publishing (boarding events)

Confirmed Boarding Classes:
- AR5BoardingBattleNew — boarding battle manager (main target)
- UR5BoardingLinkTargetAbility::ActivateAbility — confirmed from game logs
- UR5BoardingComponent / R5BoardingParticipantComponent

What We Need to Discover:
1. Does NotifyOnNewObject detect AR5BoardingBattleNew creation?
2. What properties exist on the boarding battle object?
3. What is the state machine structure? (BattleState, Phase, Status, etc.)
4. Can we identify participants? (ParticipantA, ParticipantB)
5. Can we identify ships involved? (BoardingShip, TargetShip)
6. Does the ActivateAbility hook fire?
7. What parameters does ActivateAbility receive?
8. Can we detect battle start/end/winner/loser?

Test Protocol:
1. Register NotifyOnNewObject for "R5BoardingBattleNew" with fallbacks
2. Register hook on R5BoardingLinkTargetAbility:ActivateAbility
3. On new object callback:
   - Log creation with timestamp
   - Enumerate all readable properties
   - Set up OnTick polling for this object
4. On ActivateAbility hook:
   - Log all parameters
   - Identify ships/participants involved
5. OnTick:
   - Poll boarding battle objects for state changes
   - Log each property change with timestamp
6. Try polling candidate properties (all pcall-wrapped):
   - "BattleState", "Phase", "State", "Status", "bIsActive"
   - "Winner", "Loser", "WinningTeam", "Result"
   - "ParticipantA", "ParticipantB"
   - "BoardingShip", "TargetShip"
7. Set Config.BOARDING_HOOK_WORKS based on results
8. Output lifecycle state diagram (as text) and structured Phase 0 report
9. Recommend whether boarding can serve as PvP arena
10. Self-test registration in Utils

Critical Requirements:
- MUST handle registration failures gracefully
- MUST use pcall for EVERY property access
- MUST NOT crash if objects are nil/invalid
- MUST log each property access attempt
- MUST emit events on EventBus (using EventBus.emit, NOT .publish)
- MUST set Config.BOARDING_HOOK_WORKS appropriately
- MUST provide clear PvP arena recommendation
- MUST use OnTick.Add for tick registration (NOT RegisterTick)
]]

-- ============================================================================
-- DEPENDENCY IMPORTS
-- ============================================================================

local Config = require("scripts.config")
local Utils = require("scripts.utils")
local EventBus = require("scripts.event_bus")

-- ============================================================================
-- MODULE CONFIGURATION
-- ============================================================================

local MODULE_NAME = "p0_boarding_lifecycle"

--- Class names to try for NotifyOnNewObject (in order of preference).
--- The primary name "R5BoardingBattleNew" matches Config.CLASS_NAMES.BOARDING_BATTLE.
--- Fallbacks cover alternative UE naming conventions (A-prefix, short form, etc.).
local BOARDING_BATTLE_CLASSES = {
    "R5BoardingBattleNew",       -- Primary: matches Config.CLASS_NAMES.BOARDING_BATTLE
    "AR5BoardingBattleNew",      -- Alternative: UE often prefixes A for Actor-derived
    "BoardingBattleNew",         -- Short form: sometimes UE4SS strips module prefix
    "R5BoardingBattle",          -- Legacy: without "New" suffix
    "AR5BoardingBattle",         -- Legacy with A-prefix
}

--- UFunction hook paths for boarding ability activation.
--- The primary path is confirmed from game logs; fallbacks cover naming variants.
local BOARDING_HOOK_PATHS = {
    "/Script/R5.R5BoardingLinkTargetAbility:ActivateAbility",  -- Confirmed from game logs
    "/Script/R5.R5BoardingAbility:ActivateAbility",            -- Shorter class name variant
    "/Script/R5.R5BoardingBattleAbility:ActivateAbility",      -- Battle-specific ability variant
}

--- Property candidates to poll for state changes (all pcall-wrapped).
--- Grouped by category: state indicators, outcomes, participants, ships, timing.
local STATE_PROPERTIES = {
    -- Primary state indicators — these reveal the battle's current phase
    "BattleState",
    "Phase",
    "State",
    "Status",
    "bIsActive",
    "IsActive",

    -- Outcome properties — who won/lost, what was the result
    "Winner",
    "Loser",
    "WinningTeam",
    "Result",
    "BattleResult",

    -- Participant references — the two sides of the boarding action
    "ParticipantA",
    "ParticipantB",
    "Participants",
    "Player1",
    "Player2",

    -- Ship references — the vessels involved in boarding
    "BoardingShip",
    "TargetShip",
    "AttackerShip",
    "DefenderShip",
    "ShipA",
    "ShipB",

    -- Timing and progress — how far along the battle is
    "StartTime",
    "EndTime",
    "Duration",
    "ElapsedTime",
    "TimeRemaining",
    "Progress",
    "PhaseProgress",

    -- Additional state flags — boolean indicators of battle lifecycle
    "bIsInProgress",
    "bHasStarted",
    "bHasEnded",
    "bIsFinished",
    "CurrentPhase",
    "NextPhase",
}

--- Timeout for waiting for boarding events (120 seconds — boarding is rare).
--- After this time, the exploration completes with whatever data was gathered.
local TIMEOUT_SECONDS = 120

--- Polling interval for OnTick (every 1 second).
--- Boarding state changes are not frame-critical, so 1s is sufficient.
local POLL_INTERVAL = 1.0

-- ============================================================================
-- LOCAL STATE
-- ============================================================================

--- Internal state for the module. All mutable tracking data lives here.
local state = {
    -- Registration status: which callbacks were successfully registered
    notify_registered = false,       -- Whether NotifyOnNewObject succeeded
    hook_registered = false,         -- Whether ActivateAbility hook succeeded
    registered_class = nil,          -- The class name that worked for NotifyOnNewObject
    registered_hook_path = nil,      -- The hook path that worked for RegisterHook

    -- Discovery tracking: what we've observed
    battle_objects = {},             -- Map of address -> {obj, last_state, first_seen, state_history}
    hook_fired = false,              -- Whether ActivateAbility hook has fired at least once
    first_fire_time = nil,           -- Timestamp of first hook fire
    last_fire_time = nil,            -- Timestamp of most recent hook fire
    fire_count = 0,                  -- Total number of times hook has fired

    -- Property discovery: what properties exist on boarding battle objects
    discovered_properties = {},      -- Map of property_name -> {readable, type, sample_value}
    state_machine_mapped = false,    -- Whether we've mapped enough of the state machine
    state_transitions = {},          -- Log of observed state transitions {from, to, prop, timestamp}

    -- Results: final assessment
    exploration_completed = false,   -- Whether the exploration phase is done
    error_message = nil,             -- Error message if something critical failed
    pvp_arena_recommendation = nil,  -- Final PvP arena recommendation string

    -- Timing: for throttling and timeout
    start_time = nil,                -- When init() was called
    last_poll_time = nil,            -- When we last polled battle objects
}

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

--- Log a message with the module name prefix.
--- Routes to the appropriate Utils log level function.
--- @param level string  Log level: "info", "warn", "error", "debug"
--- @param message string  Message to log
local function log_message(level, message)
    local full_message = MODULE_NAME .. ": " .. message
    if level == "error" then
        Utils.error(full_message)
    elseif level == "warn" then
        Utils.warn(full_message)
    elseif level == "debug" then
        Utils.debug(full_message)
    else
        Utils.info(full_message)
    end
end

--- Safely determine the type of a value, with special handling for UObjects.
--- For userdata values, attempts to call :IsValid() to distinguish UObjects
--- from opaque userdata (like FGameplayAbilitySpecHandle, etc.).
--- @param value any  Value to check
--- @return string  Type string: "nil", "string", "number", "boolean", "table", "UObject", "userdata"
local function safe_type(value)
    if value == nil then return "nil" end
    local t = type(value)
    if t == "userdata" then
        -- Try to determine if it's a UObject by checking for :IsValid()
        local ok, _ = pcall(function() return value:IsValid() end)
        if ok then return "UObject" end
        return "userdata"  -- Opaque userdata (struct, handle, etc.)
    end
    return t
end

--- Safely convert a value to a descriptive string for logging.
--- For UObjects, includes class name and memory address.
--- For tables, includes entry count.
--- All access is pcall-wrapped to prevent crashes on exotic types.
--- @param value any  Value to convert
--- @return string  Human-readable string representation
local function safe_tostring(value)
    local ok, result = pcall(function()
        if value == nil then return "nil" end
        local t = type(value)
        if t == "string" then return value end
        if t == "number" then return tostring(value) end
        if t == "boolean" then return tostring(value) end
        if t == "userdata" then
            -- Try to get UObject details
            local valid_ok, is_valid = pcall(function() return value:IsValid() end)
            if valid_ok and is_valid then
                local addr = string.format("%p", value)
                local class_name = "Unknown"
                local class_ok, name = pcall(function() return value:GetClass():GetName() end)
                if class_ok and name then class_name = name end
                return string.format("UObject[%s]@%s", class_name, addr)
            else
                return "UObject[Invalid]"
            end
        end
        if t == "table" then
            local count = 0
            for _ in pairs(value) do count = count + 1 end
            return "table[" .. count .. " entries]"
        end
        return tostring(value)
    end)
    return ok and result or "<tostring error>"
end

--- Safely enumerate properties on a UObject using UE4SS reflection.
--- First tries GetAll() for full reflection, then falls back to probing
--- known candidate property names from STATE_PROPERTIES.
--- @param obj userdata  UObject to enumerate
--- @return table  Map of property_name -> {readable=bool, type=string, sample_value=any}
local function enumerate_properties(obj)
    local properties = {}

    if not obj then return properties end
    local valid_ok, is_valid = pcall(function() return obj:IsValid() end)
    if not valid_ok or not is_valid then return properties end

    -- Strategy 1: Try GetAll() for full UE4SS reflection
    local ok, result = pcall(function()
        local all_props = obj:GetAll()
        if all_props then
            for _, prop in ipairs(all_props) do
                if prop and prop.Name then
                    properties[prop.Name] = {
                        readable = true,
                        type = prop.Type or "unknown",
                        sample_value = nil,  -- Will be populated by polling
                    }
                end
            end
        end
    end)

    if not ok then
        log_message("debug", "GetAll() failed or unavailable: " .. tostring(result))
    end

    -- Strategy 2: Fallback — probe known candidate property names directly
    -- This is always done to supplement GetAll() results with actual values
    for _, prop_name in ipairs(STATE_PROPERTIES) do
        local value = Utils.safe_read(obj, prop_name)
        if value ~= nil then
            properties[prop_name] = {
                readable = true,
                type = safe_type(value),
                sample_value = value,
            }
        end
    end

    return properties
end

--- Poll a boarding battle object for state changes across all candidate properties.
--- Compares current values against the previous snapshot and logs any differences.
--- Records state transitions for the lifecycle diagram.
--- @param obj userdata  Boarding battle object to poll
--- @param address string  Object address string (used as tracking key)
--- @return table  Current state snapshot (map of property_name -> value)
local function poll_battle_state(obj, address)
    local current_state = {}
    local prev_state = state.battle_objects[address]
        and state.battle_objects[address].last_state or {}

    -- Poll all candidate properties with pcall-wrapped access
    for _, prop_name in ipairs(STATE_PROPERTIES) do
        local value = Utils.safe_read(obj, prop_name)
        current_state[prop_name] = value

        -- Detect changes from previous state
        local prev_value = prev_state[prop_name]
        if prev_value ~= value then
            -- Log the change with timestamp
            local timestamp = os.date("%H:%M:%S")
            log_message("info", string.format(
                "[%s] State change on %s: %s = %s (was: %s)",
                timestamp, address, prop_name,
                safe_tostring(value), safe_tostring(prev_value)
            ))

            -- Record the transition for the state diagram
            if prev_value ~= nil then  -- Don't record initial reads as transitions
                state.state_transitions[#state.state_transitions + 1] = {
                    prop = prop_name,
                    from = prev_value,
                    to = value,
                    timestamp = os.time(),
                    battle_addr = address,
                }
            end
        end
    end

    return current_state
end

--- Extract ship and participant information from a boarding battle object.
--- Tries multiple property name variants for each piece of information.
--- @param obj userdata  Boarding battle object
--- @return table  Extracted participant info with keys:
---   participant_a, participant_b, boarding_ship, target_ship
local function extract_participants(obj)
    local info = {
        participant_a = nil,
        participant_b = nil,
        boarding_ship = nil,
        target_ship = nil,
    }

    if not obj then return info end
    local valid_ok, is_valid = pcall(function() return obj:IsValid() end)
    if not valid_ok or not is_valid then return info end

    -- Try to read participant properties (primary then fallback names)
    info.participant_a = Utils.safe_read(obj, "ParticipantA")
        or Utils.safe_read(obj, "Player1")

    info.participant_b = Utils.safe_read(obj, "ParticipantB")
        or Utils.safe_read(obj, "Player2")

    -- Try to read ship properties (primary then fallback names)
    info.boarding_ship = Utils.safe_read(obj, "BoardingShip")
        or Utils.safe_read(obj, "AttackerShip")
        or Utils.safe_read(obj, "ShipA")

    info.target_ship = Utils.safe_read(obj, "TargetShip")
        or Utils.safe_read(obj, "DefenderShip")
        or Utils.safe_read(obj, "ShipB")

    return info
end

--- Build a text representation of the discovered boarding battle state machine.
--- Shows discovered properties, observed state transitions, and the inferred
--- lifecycle flow from creation through completion.
--- @return string  State diagram as formatted text
local function build_state_diagram()
    local lines = {
        "╔══════════════════════════════════════════════════════════════╗",
        "║         BOARDING BATTLE STATE MACHINE (Discovered)          ║",
        "╚══════════════════════════════════════════════════════════════╝",
        "",
        "── Discovered Properties ──────────────────────────────────────",
    }

    -- List all discovered readable properties
    local prop_count = 0
    for prop_name, prop_info in pairs(state.discovered_properties) do
        if prop_info.readable then
            prop_count = prop_count + 1
            table.insert(lines, string.format("  %-20s (%s)", prop_name, prop_info.type))
        end
    end

    table.insert(lines, "")
    table.insert(lines, "  Total readable properties: " .. prop_count)
    table.insert(lines, "")

    -- Inferred lifecycle diagram based on what we discovered
    table.insert(lines, "── Inferred Lifecycle ────────────────────────────────────────")
    table.insert(lines, "")

    -- Check which state properties we found to build the diagram
    local has_battle_state = state.discovered_properties["BattleState"]
        and state.discovered_properties["BattleState"].readable
    local has_phase = state.discovered_properties["Phase"]
        and state.discovered_properties["Phase"].readable
    local has_bIsActive = state.discovered_properties["bIsActive"]
        and state.discovered_properties["bIsActive"].readable
    local has_result = state.discovered_properties["Result"]
        and state.discovered_properties["Result"].readable
    local has_winner = state.discovered_properties["Winner"]
        and state.discovered_properties["Winner"].readable

    if has_battle_state or has_phase then
        -- We found state properties — draw a concrete state diagram
        table.insert(lines, "  ┌──────────┐")
        table.insert(lines, "  │ CREATED  │  ← NotifyOnNewObject fires")
        table.insert(lines, "  └────┬─────┘")
        table.insert(lines, "       │")
        if has_battle_state then
            table.insert(lines, "  ┌────▼──────────┐")
            table.insert(lines, "  │ BattleState   │  ← Poll BattleState for transitions")
            table.insert(lines, "  │ changes here  │")
            table.insert(lines, "  └────┬──────────┘")
        end
        if has_phase then
            table.insert(lines, "       │")
            table.insert(lines, "  ┌────▼──────────┐")
            table.insert(lines, "  │ Phase         │  ← Poll Phase for sub-state changes")
            table.insert(lines, "  │ transitions   │")
            table.insert(lines, "  └────┬──────────┘")
        end
        table.insert(lines, "       │")
        if has_result or has_winner then
            table.insert(lines, "  ┌────▼──────────┐")
            table.insert(lines, "  │ RESOLVED      │  ← Result/Winner property set")
            table.insert(lines, "  └────┬──────────┘")
        else
            table.insert(lines, "  ┌────▼──────────┐")
            table.insert(lines, "  │ COMPLETED     │  ← bIsActive → false or object destroyed")
            table.insert(lines, "  └────┬──────────┘")
        end
        table.insert(lines, "       │")
        table.insert(lines, "  ┌────▼──────────┐")
        table.insert(lines, "  │ DESTROYED     │  ← Object becomes invalid")
        table.insert(lines, "  └───────────────┘")
    elseif has_bIsActive then
        -- Only found bIsActive — simpler binary diagram
        table.insert(lines, "  ┌──────────┐     ActivateAbility")
        table.insert(lines, "  │ INACTIVE │────────────────────┐")
        table.insert(lines, "  └──────────┘                    │")
        table.insert(lines, "       ▲                     ┌────▼─────┐")
        table.insert(lines, "       │                     │  ACTIVE  │  bIsActive = true")
        table.insert(lines, "       │                     └────┬─────┘")
        table.insert(lines, "       │                          │")
        table.insert(lines, "       └──────────────────────────┘  bIsActive = false")
    else
        -- No state properties found — show what we know
        table.insert(lines, "  ┌──────────┐")
        table.insert(lines, "  │ CREATED  │  ← NotifyOnNewObject fires")
        table.insert(lines, "  └────┬─────┘")
        table.insert(lines, "       │")
        table.insert(lines, "       ?  (State properties not discovered)")
        table.insert(lines, "       │")
        table.insert(lines, "  ┌────▼─────┐")
        table.insert(lines, "  │ DESTROYED│  ← Object becomes invalid")
        table.insert(lines, "  └──────────┘")
    end

    table.insert(lines, "")

    -- Observed state transitions log
    table.insert(lines, "── Observed State Transitions ────────────────────────────────")

    if #state.state_transitions == 0 then
        table.insert(lines, "  (No state transitions observed during this session)")
    else
        for i, transition in ipairs(state.state_transitions) do
            table.insert(lines, string.format(
                "  [%d] %s: %s → %s  (prop: %s, battle: %s)",
                i,
                os.date("%H:%M:%S", transition.timestamp),
                safe_tostring(transition.from),
                safe_tostring(transition.to),
                transition.prop,
                transition.battle_addr
            ))
        end
    end

    table.insert(lines, "")

    -- Battle objects summary
    table.insert(lines, "── Battle Objects Summary ────────────────────────────────────")

    local battle_count = 0
    for addr, battle_data in pairs(state.battle_objects) do
        battle_count = battle_count + 1
        table.insert(lines, string.format(
            "  Battle #%d: addr=%s, first_seen=%s",
            battle_count, addr,
            os.date("%Y-%m-%d %H:%M:%S", battle_data.first_seen)
        ))

        -- Log key state values from last known state
        local last_state = battle_data.last_state
        if last_state then
            for _, prop in ipairs({
                "BattleState", "Phase", "State", "Status",
                "bIsActive", "Result", "Winner"
            }) do
                if last_state[prop] ~= nil then
                    table.insert(lines, string.format(
                        "    %s = %s", prop, safe_tostring(last_state[prop])
                    ))
                end
            end
        end
    end

    if battle_count == 0 then
        table.insert(lines, "  (No boarding battles observed during this session)")
    end

    table.insert(lines, "")
    table.insert(lines, "Hook Fire Count: " .. state.fire_count)
    table.insert(lines, "First Hook Fire: " ..
        (state.first_fire_time and os.date("%Y-%m-%d %H:%M:%S", state.first_fire_time) or "N/A"))

    return table.concat(lines, "\n")
end

--- Generate the structured Phase 0 report with PvP arena recommendation.
--- This is the final output of the exploration, summarizing all discoveries
--- and providing a clear recommendation on whether boarding can serve as
--- a PvP arena.
--- @return string  Formatted report
local function generate_report()
    local lines = {
        "============================================================",
        " PHASE 0 REPORT: Boarding Battle Lifecycle Explorer",
        "============================================================",
        "",
        "Module: " .. MODULE_NAME,
        "Timestamp: " .. os.date("%Y-%m-%d %H:%M:%S"),
        "",
        "--- Registration Results ---",
        "NotifyOnNewObject: " ..
            (state.notify_registered and ("SUCCESS (" .. state.registered_class .. ")") or "FAILED"),
        "ActivateAbility Hook: " ..
            (state.hook_registered and ("SUCCESS (" .. state.registered_hook_path .. ")") or "FAILED"),
        "",
        "--- Discovery Results ---",
        "Boarding battles observed: " .. Utils.table_count(state.battle_objects),
        "Hook fires detected: " .. state.fire_count,
        "Properties discovered: " .. Utils.table_count(state.discovered_properties),
        "State transitions observed: " .. #state.state_transitions,
        "State machine mapped: " .. (state.state_machine_mapped and "YES" or "PARTIAL"),
        "",
    }

    -- Add property details
    table.insert(lines, "--- Discovered Properties ---")
    local readable_count = 0
    for prop_name, prop_info in pairs(state.discovered_properties) do
        if prop_info.readable then
            readable_count = readable_count + 1
            table.insert(lines, string.format(
                "  %-20s type=%-10s sample=%s",
                prop_name, prop_info.type, safe_tostring(prop_info.sample_value)
            ))
        end
    end
    table.insert(lines, "Total readable: " .. readable_count)
    table.insert(lines, "")

    -- Add the lifecycle state diagram
    table.insert(lines, build_state_diagram())
    table.insert(lines, "")

    -- PvP Arena Recommendation
    table.insert(lines, "--- PvP Arena Recommendation ---")
    table.insert(lines, "")

    local recommendation = "UNKNOWN"
    local reasoning = {}

    -- Decision logic: assess observability based on what we discovered
    if state.notify_registered and state.hook_registered then
        -- Both registration methods succeeded — good baseline
        local prop_count = Utils.table_count(state.discovered_properties)

        if prop_count >= 5 then
            recommendation = "RECOMMENDED"
            table.insert(reasoning,
                "- Both NotifyOnNewObject and hook registration succeeded")
            table.insert(reasoning,
                string.format("- Discovered %d readable properties on boarding battle objects", prop_count))
            table.insert(reasoning,
                "- State machine structure is observable via polling")
            table.insert(reasoning,
                "- Boarding provides a natural confined PvP space (two ships)")
        else
            recommendation = "CONDITIONAL"
            table.insert(reasoning,
                "- Hooks work but limited property access (" .. prop_count .. " properties found)")
            table.insert(reasoning,
                "- May need alternative property paths or reflection approach")
            table.insert(reasoning,
                "- Boarding confinement still valuable even without full state access")
        end
    elseif state.notify_registered or state.hook_registered then
        -- Only one method succeeded — partial observability
        recommendation = "PARTIAL"
        if state.notify_registered then
            table.insert(reasoning,
                "- NotifyOnNewObject works: can detect boarding battle creation")
        end
        if state.hook_registered then
            table.insert(reasoning,
                "- ActivateAbility hook works: can detect boarding initiation")
        end
        table.insert(reasoning,
            "- Limited observability: cannot fully monitor battle lifecycle")
        table.insert(reasoning,
            "- May need alternative hooks or property paths for full coverage")
    else
        -- Neither method succeeded — cannot observe boarding
        recommendation = "NOT RECOMMENDED"
        table.insert(reasoning,
            "- Neither NotifyOnNewObject nor hook registration succeeded")
        table.insert(reasoning,
            "- Cannot observe boarding battle lifecycle")
        table.insert(reasoning,
            "- Boarding system may use different class names than expected")
    end

    -- Check for specific state properties that are critical for PvP
    local has_state_props = false
    for _, prop in ipairs({"BattleState", "Phase", "State", "Status"}) do
        if state.discovered_properties[prop]
            and state.discovered_properties[prop].readable then
            has_state_props = true
            break
        end
    end

    if has_state_props then
        table.insert(reasoning,
            "- State properties (BattleState/Phase/Status) are readable → can detect battle phases")
    else
        table.insert(reasoning,
            "- State properties not discovered → cannot detect battle phases directly")
        table.insert(reasoning,
            "  (May need to infer state from bIsActive or object validity)")
    end

    -- Check for participant properties — critical for identifying PvP combatants
    local has_participants = false
    for _, prop in ipairs({"ParticipantA", "ParticipantB", "Player1", "Player2"}) do
        if state.discovered_properties[prop]
            and state.discovered_properties[prop].readable then
            has_participants = true
            break
        end
    end

    if has_participants then
        table.insert(reasoning,
            "- Participant properties are readable → can identify PvP combatants")
    else
        table.insert(reasoning,
            "- Participant properties not discovered → cannot directly identify combatants")
        table.insert(reasoning,
            "  (May need to traverse ship → crew → player chain)")
    end

    -- Check for outcome properties — critical for determining duel results
    local has_outcome = false
    for _, prop in ipairs({"Winner", "Loser", "WinningTeam", "Result", "BattleResult"}) do
        if state.discovered_properties[prop]
            and state.discovered_properties[prop].readable then
            has_outcome = true
            break
        end
    end

    if has_outcome then
        table.insert(reasoning,
            "- Outcome properties are readable → can determine battle results")
    else
        table.insert(reasoning,
            "- Outcome properties not discovered → cannot directly determine results")
    end

    -- Boarding-specific PvP advantages
    table.insert(reasoning, "")
    table.insert(reasoning, "Boarding as PvP Arena — Inherent Advantages:")
    table.insert(reasoning,
        "- Natural confinement: boarding restricts players to ship interior")
    table.insert(reasoning,
        "- Two-party structure: attacker vs defender maps to duel format")
    table.insert(reasoning,
        "- Existing game system: no need to create arena geometry from scratch")
    table.insert(reasoning,
        "- Player familiarity: boarding is an existing game mechanic")

    table.insert(lines, "Recommendation: " .. recommendation)
    table.insert(lines, "")
    table.insert(lines, "Reasoning:")
    for _, r in ipairs(reasoning) do
        table.insert(lines, "  " .. r)
    end

    table.insert(lines, "")
    table.insert(lines, "============================================================")

    -- Store recommendation in state for external access
    state.pvp_arena_recommendation = recommendation

    return table.concat(lines, "\n")
end

-- ============================================================================
-- CALLBACK FUNCTIONS
-- ============================================================================

--- Callback for NotifyOnNewObject — fires when a new boarding battle is created.
--- This is the primary detection mechanism for boarding battle lifecycle.
--- @param obj userdata  The newly created boarding battle object
local function on_new_boarding_battle(obj)
    if not obj then
        log_message("warn", "on_new_boarding_battle received nil object")
        return
    end

    local valid_ok, is_valid = pcall(function() return obj:IsValid() end)
    if not valid_ok or not is_valid then
        log_message("warn", "on_new_boarding_battle received invalid object")
        return
    end

    -- Get a stable address for tracking this object
    local addr = Utils.obj_address(obj)
    if not addr then
        addr = tostring(obj)  -- Fallback: use Lua's default tostring
    end

    log_message("info", "=== NEW BOARDING BATTLE DETECTED ===")
    log_message("info", "Object address: " .. addr)

    -- Try to get the class name for confirmation
    local class_ok, class_name = pcall(function() return obj:GetClass():GetName() end)
    if class_ok and class_name then
        log_message("info", "Class: " .. class_name)
    end

    -- Check if we already track this object (avoid duplicate processing)
    if state.battle_objects[addr] then
        log_message("debug", "Already tracking battle object at " .. addr)
        return
    end

    -- Record the new battle object with timestamp
    local now = os.time()
    state.battle_objects[addr] = {
        obj = obj,
        first_seen = now,
        last_state = {},       -- Will be populated by initial poll
        state_history = {},    -- Log of all state snapshots
    }

    log_message("info", "First seen at: " .. os.date("%Y-%m-%d %H:%M:%S", now))

    -- Enumerate properties on this object
    log_message("info", "Enumerating properties on new boarding battle...")
    local properties = enumerate_properties(obj)

    for prop_name, prop_info in pairs(properties) do
        -- Merge into global discovered_properties (may already exist from other battles)
        if not state.discovered_properties[prop_name] then
            state.discovered_properties[prop_name] = prop_info
        end
        if prop_info.readable then
            log_message("debug", string.format(
                "  Property found: %s (%s) = %s",
                prop_name, prop_info.type, safe_tostring(prop_info.sample_value)
            ))
        end
    end

    log_message("info", "Discovered " .. Utils.table_count(properties) .. " properties on this object")

    -- Extract participant and ship information
    local participants = extract_participants(obj)
    log_message("info", "Participant A: " .. safe_tostring(participants.participant_a))
    log_message("info", "Participant B: " .. safe_tostring(participants.participant_b))
    log_message("info", "Boarding Ship: " .. safe_tostring(participants.boarding_ship))
    log_message("info", "Target Ship: " .. safe_tostring(participants.target_ship))

    -- Perform initial state poll to establish baseline
    local current_state = poll_battle_state(obj, addr)
    state.battle_objects[addr].last_state = current_state

    -- Mark state machine as mapped if we have enough readable properties
    if Utils.table_count(state.discovered_properties) >= 5 then
        state.state_machine_mapped = true
    end

    -- Emit event on EventBus for other Phase 0 scripts
    EventBus.emit("boarding_battle_created", {
        object = obj,
        address = addr,
        participants = participants,
        properties = properties,
        timestamp = now,
    })
end

--- Pre-hook callback for R5BoardingLinkTargetAbility::ActivateAbility.
--- Fires BEFORE the original function executes.
--- Logs all parameters and attempts to identify ships/participants.
--- @param self userdata  The ability instance (UR5BoardingLinkTargetAbility)
--- @param ... vararg  Additional parameters passed to ActivateAbility
local function on_activate_pre(self, ...)
    state.hook_fired = true
    state.fire_count = state.fire_count + 1

    local now = os.time()
    if not state.first_fire_time then
        state.first_fire_time = now
    end
    state.last_fire_time = now

    log_message("info", "=== ACTIVATEABILITY HOOK FIRED (#" .. state.fire_count .. ") ===")
    log_message("info", "Timestamp: " .. os.date("%Y-%m-%d %H:%M:%S", now))

    -- Log all parameters received by the hook
    local param_count = select("#", ...)
    log_message("info", "Parameter count: " .. param_count)

    for i = 1, param_count do
        local param = select(i, ...)
        log_message("info", string.format(
            "  Param[%d]: type=%s, value=%s",
            i, safe_type(param), safe_tostring(param)
        ))
    end

    -- Try to extract useful information from the ability instance (self)
    if self then
        local self_valid_ok, self_valid = pcall(function() return self:IsValid() end)
        if self_valid_ok and self_valid then
            -- Log self's class name
            local class_ok, class_name = pcall(function() return self:GetClass():GetName() end)
            if class_ok and class_name then
                log_message("info", "Ability class: " .. class_name)
            end

            -- Probe common ability properties for owner/target/instigator
            local ability_props = {
                "Owner", "GetOwner", "Instigator",
                "AvatarActor", "OwningActor",
                "TargetActor", "Target", "SourceActor",
            }

            for _, prop in ipairs(ability_props) do
                local value = Utils.safe_read(self, prop)
                if value ~= nil then
                    log_message("info", string.format(
                        "  Ability.%s = %s (%s)",
                        prop, safe_tostring(value), safe_type(value)
                    ))
                end
            end

            -- Try to find the associated boarding battle through the ability
            local battle = Utils.safe_read(self, "BoardingBattle")
                or Utils.safe_read(self, "Battle")
                or Utils.safe_read(self, "CurrentBattle")

            if battle then
                local battle_valid_ok, battle_valid = pcall(function()
                    return battle:IsValid()
                end)

                if battle_valid_ok and battle_valid then
                    log_message("info", "Found associated boarding battle: " .. safe_tostring(battle))

                    -- Track this battle if not already known
                    local addr = Utils.obj_address(battle)
                    if addr and not state.battle_objects[addr] then
                        log_message("info", "Auto-discovered boarding battle via ActivateAbility hook")
                        state.battle_objects[addr] = {
                            obj = battle,
                            first_seen = now,
                            last_state = {},
                            state_history = {},
                        }

                        -- Enumerate its properties
                        local properties = enumerate_properties(battle)
                        for prop_name, prop_info in pairs(properties) do
                            if not state.discovered_properties[prop_name] then
                                state.discovered_properties[prop_name] = prop_info
                            end
                        end
                    end
                end
            end
        else
            log_message("debug", "Ability self is invalid or not a UObject")
        end
    end

    -- Emit event on EventBus for other Phase 0 scripts
    EventBus.emit("boarding_activate_fired", {
        self = self,
        fire_count = state.fire_count,
        timestamp = now,
    })
end

--- Post-hook callback for R5BoardingLinkTargetAbility::ActivateAbility.
--- Fires AFTER the original function executes.
--- Primarily for logging — most analysis is done in the pre-hook.
--- @param self userdata  The ability instance
--- @param ... vararg  Parameters and return value
local function on_activate_post(self, ...)
    log_message("debug", "ActivateAbility post-hook fired (fire #" .. state.fire_count .. ")")

    -- Log return value if available
    local arg_count = select("#", ...)
    if arg_count > 0 then
        local retval = select(arg_count, ...)
        log_message("debug", "Return value: " .. safe_tostring(retval))
    end
end

-- ============================================================================
-- ONTICK HANDLER
-- ============================================================================

--- OnTick callback — polls all known boarding battle objects for state changes.
--- Throttled to POLL_INTERVAL to avoid excessive CPU usage.
--- Also handles timeout detection: after TIMEOUT_SECONDS, generates the
--- final report and sets Config.BOARDING_HOOK_WORKS.
--- @param delta_time number  Time since last tick in seconds (unused — we use wall clock)
local function on_tick(delta_time)
    local now = os.time()

    -- Throttle: only poll at the configured interval
    if state.last_poll_time and (now - state.last_poll_time) < POLL_INTERVAL then
        return
    end
    state.last_poll_time = now

    -- Poll all known battle objects for state changes
    local poll_count = 0
    for addr, battle_data in pairs(state.battle_objects) do
        local obj = battle_data.obj

        -- Validate the object is still alive
        local valid_ok, is_valid = pcall(function() return obj:IsValid() end)
        if not valid_ok or not is_valid then
            log_message("info", "Battle object " .. addr .. " no longer valid (destroyed)")
            -- Record the destruction as a state transition
            state.state_transitions[#state.state_transitions + 1] = {
                prop = "IsValid",
                from = true,
                to = false,
                timestamp = now,
                battle_addr = addr,
            }
            state.battle_objects[addr] = nil
            goto continue
        end

        -- Poll for state changes
        local current_state = poll_battle_state(obj, addr)
        battle_data.last_state = current_state
        poll_count = poll_count + 1

        ::continue::
    end

    if poll_count > 0 then
        log_message("debug", "Polled " .. poll_count .. " boarding battle objects")
    end

    -- Check for timeout — complete the exploration after the timeout period
    if state.start_time and (now - state.start_time) > TIMEOUT_SECONDS then
        if not state.exploration_completed then
            log_message("warn", "Timeout reached (" .. TIMEOUT_SECONDS
                .. "s) — completing boarding lifecycle exploration")
            state.exploration_completed = true

            -- Generate and log the final report
            local report = generate_report()
            log_message("info", "\n" .. report)

            -- Update Config flag based on what we discovered
            -- BOARDING_HOOK_WORKS is true if we can observe boarding lifecycle
            -- (either through NotifyOnNewObject or hook, with some property access)
            Config.BOARDING_HOOK_WORKS = (state.notify_registered or state.hook_registered)
                and Utils.table_count(state.discovered_properties) > 0
            log_message("info", "Config.BOARDING_HOOK_WORKS = " .. tostring(Config.BOARDING_HOOK_WORKS))

            -- Emit completion event on EventBus
            EventBus.emit("boarding_exploration_complete", {
                recommendation = state.pvp_arena_recommendation,
                properties_discovered = Utils.table_count(state.discovered_properties),
                battles_observed = Utils.table_count(state.battle_objects),
                transitions_observed = #state.state_transitions,
                hook_fires = state.fire_count,
                boarding_hook_works = Config.BOARDING_HOOK_WORKS,
            })
        end
    end
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

--- Initialize the boarding lifecycle explorer module.
--- Registers NotifyOnNewObject callbacks, UFunction hooks, OnTick polling,
--- and self-tests. This is the main entry point called after dependencies load.
local function init()
    log_message("info", "=== Initializing Boarding Lifecycle Explorer ===")
    state.start_time = os.time()

    -- =====================================================================
    -- Step 1: Register NotifyOnNewObject for boarding battle classes
    -- =====================================================================
    -- Try each class name variant until one succeeds. UE4SS NotifyOnNewObject
    -- requires the exact class name as registered in the UE reflection system.
    log_message("info", "Step 1: Registering NotifyOnNewObject...")

    for _, class_name in ipairs(BOARDING_BATTLE_CLASSES) do
        log_message("debug", "Trying NotifyOnNewObject for: " .. class_name)

        local ok = Utils.notify_on_new_object(class_name, on_new_boarding_battle)
        if ok then
            state.notify_registered = true
            state.registered_class = class_name
            log_message("info", "NotifyOnNewObject registered for: " .. class_name)
            break  -- Stop after first success
        end
    end

    if not state.notify_registered then
        log_message("warn", "NotifyOnNewObject registration failed for all class name variants")
        log_message("warn", "Will attempt to find existing boarding battles via FindFirstOf")
    end

    -- =====================================================================
    -- Step 2: Register hook on ActivateAbility
    -- =====================================================================
    -- The primary hook path is confirmed from game logs. Fallback paths cover
    -- naming variants that might exist in different game versions.
    log_message("info", "Step 2: Registering ActivateAbility hook...")

    local hook_ok, hook_path = Utils.try_hook_paths(
        BOARDING_HOOK_PATHS,
        on_activate_pre,
        on_activate_post
    )

    if hook_ok then
        state.hook_registered = true
        state.registered_hook_path = hook_path
        log_message("info", "ActivateAbility hook registered: " .. hook_path)
    else
        log_message("warn", "ActivateAbility hook registration failed for all path variants")
    end

    -- =====================================================================
    -- Step 3: Try to find existing boarding battles
    -- =====================================================================
    -- NotifyOnNewObject only catches NEW objects. If a boarding battle was
    -- already in progress when the mod loaded, we need FindFirstOf to detect it.
    log_message("info", "Step 3: Searching for existing boarding battles...")

    for _, class_name in ipairs(BOARDING_BATTLE_CLASSES) do
        local existing = Utils.find_first_of(class_name)
        if existing then
            local valid_ok, is_valid = pcall(function() return existing:IsValid() end)
            if valid_ok and is_valid then
                log_message("info", "Found existing boarding battle: " .. class_name)
                on_new_boarding_battle(existing)
                break  -- Only need to process the first one found
            end
        end
    end

    -- Also try FindAllOf to catch multiple active boarding battles
    for _, class_name in ipairs(BOARDING_BATTLE_CLASSES) do
        local all_battles = Utils.find_all_of(class_name)
        if all_battles then
            local count = 0
            for _, battle in ipairs(all_battles) do
                count = count + 1
                -- on_new_boarding_battle handles dedup by address
                on_new_boarding_battle(battle)
            end
            if count > 0 then
                log_message("info", "FindAllOf('" .. class_name .. "') found " .. count .. " instances")
            end
            break  -- Only need the first successful class name
        end
    end

    -- =====================================================================
    -- Step 4: Register OnTick handler for state change polling
    -- =====================================================================
    -- OnTick.Add is the UE4SS Lua API for registering tick callbacks.
    -- We poll at POLL_INTERVAL (1s) rather than every frame for efficiency.
    log_message("info", "Step 4: Registering OnTick handler...")

    if OnTick then
        local ok_tick, err_tick = pcall(function()
            OnTick.Add(on_tick)
        end)

        if ok_tick then
            log_message("info", "OnTick handler registered (poll interval: " .. POLL_INTERVAL .. "s)")
        else
            log_message("warn", "OnTick registration failed: " .. tostring(err_tick))
            log_message("warn", "State change polling will not work — manual polling only")
        end
    else
        log_message("warn", "OnTick API not available — state change polling disabled")
    end

    -- =====================================================================
    -- Step 5: Register self-tests in Utils
    -- =====================================================================
    -- These tests verify that the module initialized correctly and that
    -- the key registration steps succeeded. They can be run via Utils.run_tests().
    log_message("info", "Step 5: Registering self-tests...")

    Utils.register_test("boarding_module_loaded", function()
        -- Verify the module initialized (start_time is set during init)
        return state.start_time ~= nil
    end)

    Utils.register_test("boarding_notify_registered", function()
        -- Verify NotifyOnNewObject registration succeeded
        -- This may be false if the class doesn't exist yet (boarding is rare)
        -- but the test should reflect the actual registration result
        return state.notify_registered == true
    end)

    Utils.register_test("boarding_hook_registered", function()
        -- Verify ActivateAbility hook registration succeeded
        return state.hook_registered == true
    end)

    Utils.register_test("boarding_config_flag_set", function()
        -- Verify Config.BOARDING_HOOK_WORKS is set (even if false)
        -- After exploration completes, this should be true or false (not nil)
        return Config.BOARDING_HOOK_WORKS ~= nil
    end)

    Utils.register_test("boarding_state_table_valid", function()
        -- Verify the internal state table is properly structured
        return type(state.battle_objects) == "table"
            and type(state.discovered_properties) == "table"
            and type(state.state_transitions) == "table"
    end)

    -- =====================================================================
    -- Initialization Summary
    -- =====================================================================
    log_message("info", "=== Boarding Lifecycle Explorer Initialization Complete ===")
    log_message("info", "NotifyOnNewObject: " ..
        (state.notify_registered and ("REGISTERED (" .. state.registered_class .. ")") or "NOT REGISTERED"))
    log_message("info", "ActivateAbility Hook: " ..
        (state.hook_registered and ("REGISTERED (" .. state.registered_hook_path .. ")") or "NOT REGISTERED"))
    log_message("info", "Existing battles found: " .. Utils.table_count(state.battle_objects))
    log_message("info", "Timeout: " .. TIMEOUT_SECONDS .. " seconds")
    log_message("info", "Poll interval: " .. POLL_INTERVAL .. " seconds")
    log_message("info", "Self-tests registered: 5")

    -- Emit initialization event on EventBus
    EventBus.emit("boarding_exploration_started", {
        notify_registered = state.notify_registered,
        hook_registered = state.hook_registered,
        registered_class = state.registered_class,
        registered_hook_path = state.registered_hook_path,
        existing_battles = Utils.table_count(state.battle_objects),
    })
end

-- ============================================================================
-- MODULE EXPORTS
-- ============================================================================

--- The BoardingLifecycle module provides read-only access to exploration state
--- and on-demand report generation. All mutation happens internally via
--- callbacks and OnTick polling.
local BoardingLifecycle = {
    --- Get a copy of the current internal state (for debugging/introspection).
    --- @return table  Current state snapshot
    get_state = function()
        return state
    end,

    --- Get the PvP arena recommendation string.
    --- One of: "RECOMMENDED", "CONDITIONAL", "PARTIAL", "NOT RECOMMENDED", "UNKNOWN"
    --- @return string  Recommendation
    get_recommendation = function()
        return state.pvp_arena_recommendation or "UNKNOWN"
    end,

    --- Check if the exploration phase has completed (timeout reached or manually).
    --- @return boolean
    is_complete = function()
        return state.exploration_completed
    end,

    --- Generate the Phase 0 report on demand.
    --- Includes lifecycle state diagram, discovered properties, and PvP recommendation.
    --- @return string  Formatted report
    generate_report = generate_report,

    --- Get the map of discovered properties.
    --- @return table  Map of property_name -> {readable, type, sample_value}
    get_discovered_properties = function()
        return state.discovered_properties
    end,

    --- Get the map of tracked battle objects.
    --- @return table  Map of address -> {obj, first_seen, last_state, state_history}
    get_battle_objects = function()
        return state.battle_objects
    end,

    --- Get the list of observed state transitions.
    --- @return table  List of {prop, from, to, timestamp, battle_addr}
    get_state_transitions = function()
        return state.state_transitions
    end,

    --- Get the lifecycle state diagram as text.
    --- @return string  State diagram
    get_state_diagram = build_state_diagram,
}

-- ============================================================================
-- AUTO-INITIALIZE
-- ============================================================================

-- Use a GameEngine:Tick hook to defer initialization until the engine is ready.
-- This ensures all other modules (Config, Utils, EventBus) are fully loaded
-- before we start registering callbacks. The init fires on the 2nd engine tick
-- (1st tick is too early — some UE4SS APIs may not be stable yet).
local init_timer = 0
RegisterHook("/Script/Engine.GameEngine:Tick", function()
    init_timer = init_timer + 1
    if init_timer == 2 then
        init()
    end
end)

log_message("info", "Module loaded, deferred init scheduled for engine tick 2")

return BoardingLifecycle
