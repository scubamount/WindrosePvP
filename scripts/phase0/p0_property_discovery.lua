--[[
p0_property_discovery.lua - Property Enumeration for Phase 0 Discovery
========================================================================

Purpose:
Enumerates all reflected properties on key game classes to discover
health/damage property names. The game uses UE's Gameplay Ability System
(GAS), so health may be stored in an AttributeSet as FGameplayAttributeData
(struct with BaseValue + CurrentValue).

UE4SS API Used:
- FindFirstOf("ClassName"): Find first instance of a class
- FindAllOf("ClassName"): Find all instances of a class
- object.PropertyName: Direct property access (chain-able)
- object:IsValid(): Check if UObject is still valid
- object:GetPropertyList(): Reflection API to enumerate properties
- NotifyOnNewObject(class_name, callback): Register callback for new objects

Dependencies:
- scripts/config.lua: Configuration flags and class names
- scripts/utils.lua: Safe property access, object finding, logging, probe_property
- scripts/event_bus.lua: Event publishing for Phase 0 events

Strategy:
1. For each key class, try multiple naming variants (R5X, AR5X, BP_R5X_C)
2. If instance found, enumerate all accessible properties via reflection
3. Brute-force probe health-related property candidates
4. Special handling for FGameplayAttributeData (CurrentValue / BaseValue)
5. Update Config with discovered health property info
6. If no player connected yet, register NotifyOnNewObject to retry later

Output:
- Structured Phase 0 report with all discovered properties
- Config.HEALTH_PROPERTY_NAME, Config.HEALTH_PROPERTY_PATH,
  Config.HEALTH_IS_ATTRIBUTE_DATA, Config.MAX_HEALTH_PROPERTY_NAME,
  Config.SHIP_HEALTH_PROPERTY_NAME updated on success
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

local MODULE_NAME = "p0_property_discovery"

--- Maximum number of properties to log per object (prevents log spam)
local MAX_PROPS_LOGGED = 50

-- ============================================================================
-- CLASS NAME VARIANTS
-- Multiple naming conventions exist in UE4: raw C++ class, A-prefixed
-- (AActor subclass), U-prefixed (UObject subclass), Blueprint-generated
-- _C suffix. Try all of them per class.
-- ============================================================================

local CLASS_VARIANTS = {
    PLAYER_CHARACTER = {
        "R5PlayerCharacter",
        "AR5PlayerCharacter",
        "BP_R5PlayerCharacter_C",
        "BP_R5Character_C",
    },
    PLAYER_STATE = {
        "R5PlayerStateBase",
        "AR5PlayerStateBase",
        "R5PlayerState",
        "AR5PlayerState",
        "BP_R5PlayerState_C",
    },
    SHIP_PAWN = {
        "R5ShipPawnBase",
        "AR5ShipPawnBase",
        "BP_R5ShipPawnBase_C",
    },
    REVIVE_COMPONENT = {
        "R5ReviveComponent",
        "UR5ReviveComponent",
        "BP_R5ReviveComponent_C",
    },
    ABILITY_SYSTEM_COMPONENT = {
        "AbilitySystemComponent",
        "UAbilitySystemComponent",
        "BP_AbilitySystemComponent_C",
    },
    MELEE_ABILITY = {
        "R5MeleeAbility",
        "UR5MeleeAbility",
        "BP_R5MeleeAbility_C",
    },
}

-- ============================================================================
-- HEALTH PROPERTY CANDIDATES
-- Ordered by likelihood. Each entry is a dot-separated path that will be
-- probed via Utils.safe_read. GAS AttributeSet paths are tried after
-- direct properties.
-- ============================================================================

local HEALTH_CANDIDATES = {
    -- Direct properties on the player character
    "Health",
    "CurrentHealth",
    "HP",
    "HitPoints",
    "Vitality",
    "Life",
    "Damage",           -- sometimes health is named inversely
    "MaxHealth",

    -- GAS AttributeSet paths (common in UE5 GAS games)
    "AbilitySystemComponent.AttributeSet.Health",
    "AbilitySystemComponent.AttributeSet.CurrentHealth",
    "AbilitySystemComponent.AttributeSet.HP",
    "AbilitySystemComponent.AttributeSet.HitPoints",
    "AbilitySystemComponent.AttributeSet.Vitality",

    -- Component-based paths
    "HealthComponent.Health",
    "HealthComponent.CurrentHealth",
    "HealthComponent.HP",
    "HealthComponent.HitPoints",
    "HealthComponent.Vitality",

    -- Revive component paths
    "ReviveComponent.Health",
    "ReviveComponent.CurrentHealth",
}

-- FGameplayAttributeData sub-property paths to try when a candidate
-- returns a userdata (struct) instead of a number
local ATTRIBUTE_DATA_SUBPATHS = {
    "CurrentValue",
    "BaseValue",
}

-- Max health property candidates (probed after main health is found)
local MAX_HEALTH_CANDIDATES = {
    "MaxHealth",
    "MaximumHealth",
    "MaxHP",
    "MaxHitPoints",
    "MaxVitality",
    "AbilitySystemComponent.AttributeSet.MaxHealth",
    "AbilitySystemComponent.AttributeSet.MaximumHealth",
    "HealthComponent.MaxHealth",
}

-- Ship health property candidates
local SHIP_HEALTH_CANDIDATES = {
    "Health",
    "CurrentHealth",
    "HullHealth",
    "HullIntegrity",
    "ShipHealth",
    "HullHitPoints",
    "Damage",
    "MaxHealth",
    "AbilitySystemComponent.AttributeSet.Health",
    "AbilitySystemComponent.AttributeSet.HullHealth",
}

-- Revive/downed property candidates
local REVIVE_CANDIDATES = {
    "IsDowned",
    "bIsDowned",
    "IsDead",
    "bIsDead",
    "Downed",
    "Health",
    "CurrentHealth",
    "ReviveHealth",
    "ReviveProgress",
}

-- ============================================================================
-- LOCAL STATE
-- ============================================================================

local discovery_state = {
    -- Per-class discovery results
    classes = {},           -- { [class_key] = { found = bool, variant = str, obj = userdata|nil, properties = {} } }

    -- Health discovery results
    health_found = false,
    health_path = nil,      -- The full dot-path that worked
    health_value = nil,     -- The value read at that path
    health_is_attr_data = false,  -- True if FGameplayAttributeData
    health_attr_data_subpath = nil, -- "CurrentValue" or "BaseValue"

    -- Max health discovery results
    max_health_found = false,
    max_health_path = nil,
    max_health_value = nil,

    -- Ship health discovery results
    ship_health_found = false,
    ship_health_path = nil,
    ship_health_value = nil,

    -- Revive/downed discovery results
    revive_found = false,
    revive_path = nil,
    revive_value = nil,

    -- Property enumeration results (all discovered property names per class)
    all_properties = {},    -- { [class_key] = { [name] = type_string } }

    -- Deferred retry state
    retry_registered = false,

    -- Completion flag
    discovery_complete = false,

    -- Error messages
    errors = {},
}

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

--[[ Log a message with module prefix ]]
local function log(level, message)
    local prefixed = MODULE_NAME .. ": " .. tostring(message)
    if level == "error" then
        Utils.error(prefixed)
    elseif level == "warn" then
        Utils.warn(prefixed)
    elseif level == "debug" then
        Utils.debug(prefixed)
    else
        Utils.info(prefixed)
    end
end

--[[ Try to find an instance of a class using multiple naming variants

Tries each variant with Utils.find_first_of (which wraps FindFirstOf in
pcall). Returns the first valid object found along with the variant name
that worked.

@param class_key (string): Logical key (e.g., "PLAYER_CHARACTER")
@param variants (table): List of class name strings to try
@return userdata|nil The found object, or nil
@return string|nil The variant name that worked, or nil
]]
local function find_class_instance(class_key, variants)
    for _, variant in ipairs(variants) do
        log("debug", "Trying FindFirstOf('" .. variant .. "') for " .. class_key)

        local obj = Utils.find_first_of(variant)
        if obj then
            log("info", "Found " .. class_key .. " via variant '" .. variant .. "'")
            return obj, variant
        end
    end

    log("warn", "Class not found: " .. class_key .. " (tried " .. #variants .. " variants)")
    return nil, nil
end

--[[ Attempt to enumerate properties via UE4SS reflection API

Tries multiple reflection strategies in order:
1. object:GetPropertyList() — standard UE4SS property enumeration
2. object:GetUPropertyArray() — alternative reflection API
3. pairs() iteration on the UObject — works on some UE4SS builds
4. Falls back to "no reflection" — candidate probing only

@param obj (userdata): The UObject to enumerate
@param class_key (string): Logical class key for logging
@return table List of { name = string, type = string } entries
]]
local function enumerate_properties_reflection(obj, class_key)
    local properties = {}

    -- Strategy 1: Try GetPropertyList() reflection API
    local ok, prop_list = pcall(function()
        return obj:GetPropertyList()
    end)

    if ok and type(prop_list) == "table" and #prop_list > 0 then
        log("info", class_key .. ": GetPropertyList() returned " .. #prop_list .. " properties")
        for _, prop_entry in ipairs(prop_list) do
            -- GetPropertyList may return strings or {name, type} tables
            if type(prop_entry) == "string" then
                properties[#properties + 1] = { name = prop_entry, type = "unknown" }
            elseif type(prop_entry) == "table" then
                properties[#properties + 1] = {
                    name = tostring(prop_entry.Name or prop_entry.name or prop_entry[1] or "?"),
                    type = tostring(prop_entry.Type or prop_entry.type or prop_entry[2] or "unknown"),
                }
            end
        end
        return properties
    end

    if not ok then
        log("debug", class_key .. ": GetPropertyList() failed: " .. tostring(prop_list))
    else
        log("debug", class_key .. ": GetPropertyList() returned non-table or empty: " .. type(prop_list))
    end

    -- Strategy 2: Try GetUPropertyArray() as fallback
    local ok2, prop_array = pcall(function()
        return obj:GetUPropertyArray()
    end)

    if ok2 and type(prop_array) == "table" and #prop_array > 0 then
        log("info", class_key .. ": GetUPropertyArray() returned " .. #prop_array .. " properties")
        for _, prop_entry in ipairs(prop_array) do
            if type(prop_entry) == "string" then
                properties[#properties + 1] = { name = prop_entry, type = "unknown" }
            elseif type(prop_entry) == "table" then
                properties[#properties + 1] = {
                    name = tostring(prop_entry.Name or prop_entry.name or prop_entry[1] or "?"),
                    type = tostring(prop_entry.Type or prop_entry.type or prop_entry[2] or "unknown"),
                }
            end
        end
        return properties
    end

    if not ok2 then
        log("debug", class_key .. ": GetUPropertyArray() failed: " .. tostring(prop_array))
    end

    -- Strategy 3: Try iterating via pairs on the object metatable
    -- Some UE4SS builds expose __pairs on UObjects
    local ok3, iter_result = pcall(function()
        local results = {}
        for k, v in pairs(obj) do
            if type(k) == "string" then
                local v_type = type(v)
                results[#results + 1] = { name = k, type = v_type }
            end
        end
        return results
    end)

    if ok3 and type(iter_result) == "table" and #iter_result > 0 then
        log("info", class_key .. ": pairs() iteration found " .. #iter_result .. " properties")
        return iter_result
    end

    if not ok3 then
        log("debug", class_key .. ": pairs() iteration failed: " .. tostring(iter_result))
    end

    -- Strategy 4: No reflection available — will rely on brute-force probing
    log("info", class_key .. ": No reflection API available, relying on candidate probing")
    return properties
end

--[[ Probe a list of property candidates on an object

For each candidate path:
1. Try Utils.safe_read(obj, path)
2. If value is nil, skip
3. If value is a number, record it directly
4. If value is userdata, try FGameplayAttributeData sub-paths (.CurrentValue, .BaseValue)
5. If value is a table, check for FGameplayAttributeData-like structure
6. Log result for every candidate (success or failure)

@param obj (userdata): The UObject to probe
@param candidates (table): List of dot-separated property paths
@param class_key (string): Logical class key for logging
@return table List of { path, value, type_name, is_attr_data, attr_subpath } for successes
]]
local function probe_candidates(obj, candidates, class_key)
    local results = {}

    for _, path in ipairs(candidates) do
        local value = Utils.safe_read(obj, path)

        if value == nil then
            log("debug", class_key .. ": probe '" .. path .. "' → nil")
        elseif type(value) == "number" then
            log("info", class_key .. ": probe '" .. path .. "' → number = " .. tostring(value))
            results[#results + 1] = {
                path = path,
                value = value,
                type_name = "number",
                is_attr_data = false,
                attr_subpath = nil,
            }
        elseif type(value) == "userdata" then
            -- Possibly FGameplayAttributeData — try sub-paths
            log("info", class_key .. ": probe '" .. path .. "' → userdata (trying AttributeData sub-paths)")

            for _, sub in ipairs(ATTRIBUTE_DATA_SUBPATHS) do
                local sub_path = path .. "." .. sub
                local sub_value = Utils.safe_read(obj, sub_path)

                if sub_value ~= nil and type(sub_value) == "number" then
                    log("info", class_key .. ": probe '" .. sub_path .. "' → number = " .. tostring(sub_value))
                    results[#results + 1] = {
                        path = path,
                        value = sub_value,
                        type_name = "FGameplayAttributeData",
                        is_attr_data = true,
                        attr_subpath = sub,
                    }
                else
                    log("debug", class_key .. ": probe '" .. sub_path .. "' → " .. type(sub_value))
                end
            end
        elseif type(value) == "table" then
            -- Check if it's an FGameplayAttributeData-like Lua table
            local has_current = value.CurrentValue ~= nil
            local has_base = value.BaseValue ~= nil

            if has_current or has_base then
                log("info", class_key .. ": probe '" .. path .. "' → FGameplayAttributeData-like table"
                    .. (has_current and (" CurrentValue=" .. tostring(value.CurrentValue)) or "")
                    .. (has_base and (" BaseValue=" .. tostring(value.BaseValue)) or ""))

                -- Prefer CurrentValue for the result
                local chosen_val = has_current and value.CurrentValue or value.BaseValue
                local chosen_sub = has_current and "CurrentValue" or "BaseValue"
                results[#results + 1] = {
                    path = path,
                    value = tonumber(chosen_val) or chosen_val,
                    type_name = "FGameplayAttributeData",
                    is_attr_data = true,
                    attr_subpath = chosen_sub,
                }
            else
                log("debug", class_key .. ": probe '" .. path .. "' → table (not AttributeData)")
            end
        elseif type(value) == "boolean" then
            log("info", class_key .. ": probe '" .. path .. "' → boolean = " .. tostring(value))
            results[#results + 1] = {
                path = path,
                value = value,
                type_name = "boolean",
                is_attr_data = false,
                attr_subpath = nil,
            }
        elseif type(value) == "string" then
            log("info", class_key .. ": probe '" .. path .. "' → string = '" .. value .. "'")
            results[#results + 1] = {
                path = path,
                value = value,
                type_name = "string",
                is_attr_data = false,
                attr_subpath = nil,
            }
        else
            log("debug", class_key .. ": probe '" .. path .. "' → " .. type(value))
        end
    end

    return results
end

-- ============================================================================
-- CLASS DISCOVERY
-- ============================================================================

--[[ Discover and enumerate properties for a single class

@param class_key (string): Logical key (e.g., "PLAYER_CHARACTER")
@param variants (table): Class name variants to try
@param health_candidates (table|nil): Health candidates to probe (if applicable)
@return table Class discovery result
]]
local function discover_class(class_key, variants, health_candidates)
    local result = {
        found = false,
        variant = nil,
        obj = nil,
        properties = {},
        health_results = {},
    }

    -- Step 1: Find an instance
    local obj, variant = find_class_instance(class_key, variants)

    if not obj then
        discovery_state.classes[class_key] = result
        return result
    end

    result.found = true
    result.variant = variant
    result.obj = obj

    -- Step 2: Enumerate all accessible properties via reflection
    log("info", "Enumerating properties on " .. class_key .. " (variant: " .. variant .. ")")
    result.properties = enumerate_properties_reflection(obj, class_key)

    -- Store in global state and log each property
    discovery_state.all_properties[class_key] = {}
    local prop_count = 0
    for _, prop in ipairs(result.properties) do
        if prop_count < MAX_PROPS_LOGGED then
            discovery_state.all_properties[class_key][prop.name] = prop.type
            log("info", "  Property: " .. prop.name .. " [" .. prop.type .. "]")
            prop_count = prop_count + 1
        end
    end

    if #result.properties > MAX_PROPS_LOGGED then
        log("info", "  ... and " .. (#result.properties - MAX_PROPS_LOGGED) .. " more properties (truncated)")
    end

    -- Step 3: Probe health-related candidates (if provided)
    if health_candidates then
        log("info", "Probing health candidates on " .. class_key .. "...")
        result.health_results = probe_candidates(obj, health_candidates, class_key)
    end

    discovery_state.classes[class_key] = result
    return result
end

-- ============================================================================
-- HEALTH PROPERTY RESOLUTION
-- ============================================================================

--[[ Process health probe results and update Config

Scans all health_results from player character discovery and picks the
best candidate. Priority:
1. Direct numeric property named "Health" or "CurrentHealth"
2. Any numeric property that looks like a health value (> 0, reasonable range)
3. FGameplayAttributeData with CurrentValue

@param player_result (table): Result from discover_class for PLAYER_CHARACTER
]]
local function resolve_health_property(player_result)
    if not player_result or not player_result.health_results then
        return
    end

    local results = player_result.health_results
    if #results == 0 then
        log("warn", "No health property candidates matched on player character")
        return
    end

    -- Priority: prefer direct number properties, then AttributeData with CurrentValue
    local best_direct = nil
    local best_attr_data = nil

    for _, r in ipairs(results) do
        -- Skip boolean/string results — those aren't health values
        if r.type_name == "number" or r.type_name == "FGameplayAttributeData" then
            -- Sanity: health should be a positive number
            if type(r.value) == "number" and r.value > 0 then
                if not r.is_attr_data then
                    -- Direct number property — high priority
                    -- Prefer "Health" or "CurrentHealth" over "MaxHealth" etc.
                    if not best_direct then
                        best_direct = r
                    elseif r.path == "Health" or r.path == "CurrentHealth" then
                        best_direct = r
                    end
                else
                    -- FGameplayAttributeData — prefer CurrentValue over BaseValue
                    if not best_attr_data then
                        best_attr_data = r
                    elseif r.attr_subpath == "CurrentValue" then
                        best_attr_data = r
                    end
                end
            end
        end
    end

    -- Choose best result: direct > AttributeData
    local chosen = best_direct or best_attr_data

    if not chosen then
        log("warn", "Health candidates returned values but none are valid health numbers")
        return
    end

    -- Update discovery state
    discovery_state.health_found = true
    discovery_state.health_path = chosen.path
    discovery_state.health_value = chosen.value
    discovery_state.health_is_attr_data = chosen.is_attr_data
    discovery_state.health_attr_data_subpath = chosen.attr_subpath

    -- Update Config
    -- HEALTH_PROPERTY_NAME: the leaf property name (last segment of path)
    local leaf_name = chosen.path:match("%.([^%.]+)$") or chosen.path
    Config.HEALTH_PROPERTY_NAME = leaf_name

    -- HEALTH_PROPERTY_PATH: full dot-path if nested, nil if direct
    if chosen.path:find("%.") then
        Config.HEALTH_PROPERTY_PATH = chosen.path
    else
        Config.HEALTH_PROPERTY_PATH = nil
    end

    -- HEALTH_IS_ATTRIBUTE_DATA: true if FGameplayAttributeData
    Config.HEALTH_IS_ATTRIBUTE_DATA = chosen.is_attr_data

    log("info", "HEALTH PROPERTY DISCOVERED:")
    log("info", "  Path: " .. tostring(chosen.path))
    log("info", "  Value: " .. tostring(chosen.value))
    log("info", "  Is AttributeData: " .. tostring(chosen.is_attr_data))
    if chosen.is_attr_data then
        log("info", "  AttributeData sub-path: " .. tostring(chosen.attr_subpath))
    end
end

--[[ Resolve max health property from player character

Probes MAX_HEALTH_CANDIDATES on the player character object.
Skips the path that was already identified as the health property.

@param player_obj (userdata): The player character object
]]
local function resolve_max_health_property(player_obj)
    if not player_obj then return end

    log("info", "Probing max health candidates...")
    local results = probe_candidates(player_obj, MAX_HEALTH_CANDIDATES, "PLAYER_CHARACTER(max)")

    for _, r in ipairs(results) do
        if (r.type_name == "number" or r.type_name == "FGameplayAttributeData")
           and type(r.value) == "number" and r.value > 0 then
            -- Don't pick the same path as the health property
            if r.path ~= discovery_state.health_path then
                discovery_state.max_health_found = true
                discovery_state.max_health_path = r.path
                discovery_state.max_health_value = r.value

                local leaf_name = r.path:match("%.([^%.]+)$") or r.path
                Config.MAX_HEALTH_PROPERTY_NAME = leaf_name

                log("info", "MAX HEALTH PROPERTY DISCOVERED:")
                log("info", "  Path: " .. r.path)
                log("info", "  Value: " .. tostring(r.value))
                return
            end
        end
    end

    log("debug", "No separate max health property found (may be derived or same as health)")
end

--[[ Resolve ship health property from ship pawn

@param ship_result (table): Result from discover_class for SHIP_PAWN
]]
local function resolve_ship_health_property(ship_result)
    if not ship_result or not ship_result.health_results then
        return
    end

    local results = ship_result.health_results

    for _, r in ipairs(results) do
        if (r.type_name == "number" or r.type_name == "FGameplayAttributeData")
           and type(r.value) == "number" and r.value > 0 then
            discovery_state.ship_health_found = true
            discovery_state.ship_health_path = r.path
            discovery_state.ship_health_value = r.value

            local leaf_name = r.path:match("%.([^%.]+)$") or r.path
            Config.SHIP_HEALTH_PROPERTY_NAME = leaf_name

            log("info", "SHIP HEALTH PROPERTY DISCOVERED:")
            log("info", "  Path: " .. r.path)
            log("info", "  Value: " .. tostring(r.value))
            return
        end
    end

    log("debug", "No ship health property found")
end

--[[ Resolve revive/downed property from revive component

Prefers boolean "IsDowned" / "bIsDowned" properties, then falls back
to numeric health-like properties on the revive component.

@param revive_result (table): Result from discover_class for REVIVE_COMPONENT
]]
local function resolve_revive_property(revive_result)
    if not revive_result or not revive_result.health_results then
        return
    end

    local results = revive_result.health_results

    -- Prefer boolean "IsDowned" / "bIsDowned" properties
    for _, r in ipairs(results) do
        if r.type_name == "boolean" then
            discovery_state.revive_found = true
            discovery_state.revive_path = r.path
            discovery_state.revive_value = r.value

            log("info", "REVIVE PROPERTY DISCOVERED:")
            log("info", "  Path: " .. r.path)
            log("info", "  Value: " .. tostring(r.value))
            return
        end
    end

    -- Fall back to numeric health-like properties on revive component
    for _, r in ipairs(results) do
        if (r.type_name == "number" or r.type_name == "FGameplayAttributeData")
           and type(r.value) == "number" then
            discovery_state.revive_found = true
            discovery_state.revive_path = r.path
            discovery_state.revive_value = r.value

            log("info", "REVIVE PROPERTY DISCOVERED (numeric):")
            log("info", "  Path: " .. r.path)
            log("info", "  Value: " .. tostring(r.value))
            return
        end
    end

    log("debug", "No revive/downed property found")
end

-- ============================================================================
-- DEFERRED RETRY (NO PLAYER CONNECTED YET)
-- ============================================================================

--[[ Register NotifyOnNewObject callbacks for player class variants

When no player is connected at script load time, we register callbacks
so property discovery runs when a player joins. Each variant is tried
until one registration succeeds.
]]
local function register_deferred_retry()
    if discovery_state.retry_registered then
        return
    end

    discovery_state.retry_registered = true
    log("info", "No player connected — registering NotifyOnNewObject for deferred discovery")

    local registered_any = false

    for _, variant in ipairs(CLASS_VARIANTS.PLAYER_CHARACTER) do
        local success = Utils.notify_on_new_object(variant, function(new_obj)
            log("info", "Deferred retry: new player object detected via '" .. variant .. "'")

            -- Validate the new object
            local ok, valid = pcall(function()
                return new_obj:IsValid()
            end)

            if not ok or not valid then
                log("warn", "Deferred retry: new player object is not valid, skipping")
                return
            end

            -- Run discovery on the new player (only if not already complete)
            if not discovery_state.discovery_complete then
                run_discovery()
            end
        end)

        if success then
            log("info", "Registered NotifyOnNewObject for '" .. variant .. "'")
            registered_any = true
            -- Only need one successful registration
            break
        end
    end

    if not registered_any then
        log("error", "Could not register NotifyOnNewObject for any player class variant")
        log("error", "Property discovery will NOT run until a player connects and script is reloaded")
    end
end

-- ============================================================================
-- MAIN DISCOVERY LOGIC
-- ============================================================================

--[[ Run the full property discovery process

This is the core function that:
1. Finds instances of each key class
2. Enumerates their properties via reflection
3. Probes health-related candidates with brute-force
4. Resolves the best health property
5. Updates Config flags
6. Outputs the Phase 0 report
7. Emits completion event on EventBus
]]
function run_discovery()
    log("info", "============================================================")
    log("info", "Phase 0 Property Discovery - Starting")
    log("info", "============================================================")

    -- ------------------------------------------------------------------
    -- Step 1: Discover player character (most important class)
    -- ------------------------------------------------------------------
    log("info", "Step 1: Discovering player character...")
    local player_result = discover_class(
        "PLAYER_CHARACTER",
        CLASS_VARIANTS.PLAYER_CHARACTER,
        HEALTH_CANDIDATES
    )

    if not player_result.found then
        log("warn", "No player character instance found")
        log("warn", "Cannot probe health properties without a live player")
        log("warn", "Registering deferred retry via NotifyOnNewObject...")
        register_deferred_retry()

        -- Still try other classes that may exist without a player
        log("info", "Attempting non-player class discovery anyway...")
    end

    -- ------------------------------------------------------------------
    -- Step 2: Discover player state (may hold health in GAS games)
    -- ------------------------------------------------------------------
    log("info", "Step 2: Discovering player state...")
    local state_result = discover_class(
        "PLAYER_STATE",
        CLASS_VARIANTS.PLAYER_STATE,
        HEALTH_CANDIDATES
    )

    -- If player character didn't have health but player state does, use that
    if state_result.found and not discovery_state.health_found then
        resolve_health_property(state_result)
    end

    -- ------------------------------------------------------------------
    -- Step 3: Discover ability system component
    -- ------------------------------------------------------------------
    log("info", "Step 3: Discovering ability system component...")

    -- Try finding ASC via the player object first (most reliable path)
    local asc_obj = nil
    if player_result.found and player_result.obj then
        asc_obj = Utils.safe_read(player_result.obj, "AbilitySystemComponent")
        if asc_obj then
            log("info", "Found AbilitySystemComponent via player object property")
            discovery_state.classes["ABILITY_SYSTEM_COMPONENT"] = {
                found = true,
                variant = "player.AbilitySystemComponent",
                obj = asc_obj,
                properties = {},
                health_results = {},
            }
        end
    end

    -- Fallback: try FindFirstOf with class variants
    if not asc_obj then
        local asc_result = discover_class(
            "ABILITY_SYSTEM_COMPONENT",
            CLASS_VARIANTS.ABILITY_SYSTEM_COMPONENT,
            nil  -- No health candidates directly on ASC
        )
        asc_obj = asc_result.obj
    end

    -- If we still haven't found health, try probing ASC for AttributeSet paths
    if asc_obj and not discovery_state.health_found then
        log("info", "Probing ASC for AttributeSet health paths...")
        local asc_health_candidates = {
            "AttributeSet.Health",
            "AttributeSet.CurrentHealth",
            "AttributeSet.HP",
            "AttributeSet.HitPoints",
            "AttributeSet.Vitality",
            "AttributeSet.MaxHealth",
        }
        local asc_results = probe_candidates(asc_obj, asc_health_candidates, "ABILITY_SYSTEM_COMPONENT")

        -- Try to resolve health from ASC results
        for _, r in ipairs(asc_results) do
            if (r.type_name == "number" or r.type_name == "FGameplayAttributeData")
               and type(r.value) == "number" and r.value > 0 then
                -- Build full path from ASC
                local full_path = "AbilitySystemComponent." .. r.path
                discovery_state.health_found = true
                discovery_state.health_path = full_path
                discovery_state.health_value = r.value
                discovery_state.health_is_attr_data = r.is_attr_data
                discovery_state.health_attr_data_subpath = r.attr_subpath

                local leaf_name = r.path:match("%.([^%.]+)$") or r.path
                Config.HEALTH_PROPERTY_NAME = leaf_name
                Config.HEALTH_PROPERTY_PATH = full_path
                Config.HEALTH_IS_ATTRIBUTE_DATA = r.is_attr_data

                log("info", "HEALTH PROPERTY DISCOVERED via ASC:")
                log("info", "  Path: " .. full_path)
                log("info", "  Value: " .. tostring(r.value))
                log("info", "  Is AttributeData: " .. tostring(r.is_attr_data))
                break
            end
        end
    end

    -- ------------------------------------------------------------------
    -- Step 4: Resolve health property from player character results
    -- ------------------------------------------------------------------
    if player_result.found and not discovery_state.health_found then
        resolve_health_property(player_result)
    end

    -- ------------------------------------------------------------------
    -- Step 5: Discover max health (if player found)
    -- ------------------------------------------------------------------
    log("info", "Step 5: Probing max health property...")
    if player_result.found and player_result.obj then
        resolve_max_health_property(player_result.obj)
    end

    -- ------------------------------------------------------------------
    -- Step 6: Discover ship pawn
    -- ------------------------------------------------------------------
    log("info", "Step 6: Discovering ship pawn...")
    local ship_result = discover_class(
        "SHIP_PAWN",
        CLASS_VARIANTS.SHIP_PAWN,
        SHIP_HEALTH_CANDIDATES
    )
    resolve_ship_health_property(ship_result)

    -- ------------------------------------------------------------------
    -- Step 7: Discover revive component
    -- ------------------------------------------------------------------
    log("info", "Step 7: Discovering revive component...")

    -- Try finding revive component via the player object first
    local revive_obj = nil
    if player_result.found and player_result.obj then
        revive_obj = Utils.safe_read(player_result.obj, "ReviveComponent")
        if revive_obj then
            log("info", "Found ReviveComponent via player object property")
        end
    end

    local revive_result
    if revive_obj then
        revive_result = {
            found = true,
            variant = "player.ReviveComponent",
            obj = revive_obj,
            properties = enumerate_properties_reflection(revive_obj, "REVIVE_COMPONENT"),
            health_results = probe_candidates(revive_obj, REVIVE_CANDIDATES, "REVIVE_COMPONENT"),
        }
        discovery_state.classes["REVIVE_COMPONENT"] = revive_result
    else
        -- Fallback: try FindFirstOf with class variants
        revive_result = discover_class(
            "REVIVE_COMPONENT",
            CLASS_VARIANTS.REVIVE_COMPONENT,
            REVIVE_CANDIDATES
        )
    end
    resolve_revive_property(revive_result)

    -- ------------------------------------------------------------------
    -- Step 8: Discover melee ability (property enumeration only)
    -- ------------------------------------------------------------------
    log("info", "Step 8: Discovering melee ability...")
    discover_class(
        "MELEE_ABILITY",
        CLASS_VARIANTS.MELEE_ABILITY,
        nil  -- No health candidates for melee ability
    )

    -- ------------------------------------------------------------------
    -- Step 9: Final health resolution check
    -- ------------------------------------------------------------------
    if discovery_state.health_found then
        log("info", "============================================================")
        log("info", "HEALTH PROPERTY DISCOVERY: SUCCESS")
        log("info", "============================================================")
        log("info", "  Config.HEALTH_PROPERTY_NAME = " .. tostring(Config.HEALTH_PROPERTY_NAME))
        log("info", "  Config.HEALTH_PROPERTY_PATH = " .. tostring(Config.HEALTH_PROPERTY_PATH))
        log("info", "  Config.HEALTH_IS_ATTRIBUTE_DATA = " .. tostring(Config.HEALTH_IS_ATTRIBUTE_DATA))
        if Config.MAX_HEALTH_PROPERTY_NAME then
            log("info", "  Config.MAX_HEALTH_PROPERTY_NAME = " .. tostring(Config.MAX_HEALTH_PROPERTY_NAME))
        end
        if Config.SHIP_HEALTH_PROPERTY_NAME then
            log("info", "  Config.SHIP_HEALTH_PROPERTY_NAME = " .. tostring(Config.SHIP_HEALTH_PROPERTY_NAME))
        end
    else
        log("error", "============================================================")
        log("error", "HEALTH PROPERTY NOT FOUND")
        log("error", "============================================================")
        log("error", "All health candidates failed on all class variants.")
        log("error", "Manual SDK dump inspection required:")
        log("error", "  1. Check CXXHeaderDump/ for R5PlayerCharacter header")
        log("error", "  2. Look for FGameplayAttributeData or float health fields")
        log("error", "  3. Check AttributeSet sub-class for health attribute names")
        log("error", "  4. Update Config.HEALTH_PROPERTY_NAME manually")
        log("error", "============================================================")
    end

    -- Mark discovery as complete (even if health wasn't found — we tried everything)
    discovery_state.discovery_complete = true

    -- ------------------------------------------------------------------
    -- Step 10: Output Phase 0 report
    -- ------------------------------------------------------------------
    output_phase0_report()

    -- ------------------------------------------------------------------
    -- Step 11: Emit completion event
    -- ------------------------------------------------------------------
    EventBus.emit("phase0_property_discovery_complete", {
        health_found = discovery_state.health_found,
        health_path = discovery_state.health_path,
        health_is_attr_data = discovery_state.health_is_attr_data,
        max_health_found = discovery_state.max_health_found,
        ship_health_found = discovery_state.ship_health_found,
        revive_found = discovery_state.revive_found,
        classes_found = (function()
            local found = {}
            for key, result in pairs(discovery_state.classes) do
                found[key] = result.found
            end
            return found
        end)(),
    })
end

-- ============================================================================
-- PHASE 0 REPORT OUTPUT
-- ============================================================================

--[[ Generate and output the structured Phase 0 Report Section

This creates a comprehensive report of all discovery results that can be
used for debugging and for the Phase 0 discovery document.
]]
function output_phase0_report()
    log("info", "")
    log("info", "============================================================")
    log("info", "PHASE 0 REPORT SECTION: Property Discovery")
    log("info", "============================================================")
    log("info", "")

    -- Class Discovery Summary
    log("info", "Class Discovery Summary:")
    log("info", "------------------------------------------------------------")

    local class_keys = {
        "PLAYER_CHARACTER",
        "PLAYER_STATE",
        "SHIP_PAWN",
        "REVIVE_COMPONENT",
        "ABILITY_SYSTEM_COMPONENT",
        "MELEE_ABILITY",
    }

    for _, key in ipairs(class_keys) do
        local result = discovery_state.classes[key]
        if result then
            local status = result.found and "FOUND" or "NOT FOUND"
            local variant_str = result.variant and (" (variant: " .. result.variant .. ")") or ""
            local prop_count = result.properties and #result.properties or 0
            log("info", string.format("  %-30s %s%s  [%d properties enumerated]",
                key, status, variant_str, prop_count))
        else
            log("info", string.format("  %-30s NOT ATTEMPTED", key))
        end
    end

    log("info", "")

    -- Property Enumeration Details
    log("info", "Property Enumeration Details:")
    log("info", "------------------------------------------------------------")

    for _, key in ipairs(class_keys) do
        local props = discovery_state.all_properties[key]
        if props then
            log("info", "  " .. key .. ":")
            local count = 0
            for name, type_name in pairs(props) do
                log("info", "    " .. name .. " [" .. type_name .. "]")
                count = count + 1
            end
            if count == 0 then
                log("info", "    (no properties enumerated via reflection)")
            end
        end
    end

    log("info", "")

    -- Health Property Results
    log("info", "Health Property Discovery:")
    log("info", "------------------------------------------------------------")

    if discovery_state.health_found then
        log("info", "  Status: FOUND")
        log("info", "  Path: " .. tostring(discovery_state.health_path))
        log("info", "  Value: " .. tostring(discovery_state.health_value))
        log("info", "  Is FGameplayAttributeData: " .. tostring(discovery_state.health_is_attr_data))
        if discovery_state.health_is_attr_data then
            log("info", "  AttributeData sub-path: " .. tostring(discovery_state.health_attr_data_subpath))
        end
        log("info", "  Config.HEALTH_PROPERTY_NAME = " .. tostring(Config.HEALTH_PROPERTY_NAME))
        log("info", "  Config.HEALTH_PROPERTY_PATH = " .. tostring(Config.HEALTH_PROPERTY_PATH))
        log("info", "  Config.HEALTH_IS_ATTRIBUTE_DATA = " .. tostring(Config.HEALTH_IS_ATTRIBUTE_DATA))
    else
        log("info", "  Status: NOT FOUND")
        log("info", "  All candidates failed — manual SDK dump inspection required")
    end

    log("info", "")

    -- Max Health Results
    log("info", "Max Health Property:")
    if discovery_state.max_health_found then
        log("info", "  Status: FOUND")
        log("info", "  Path: " .. tostring(discovery_state.max_health_path))
        log("info", "  Value: " .. tostring(discovery_state.max_health_value))
        log("info", "  Config.MAX_HEALTH_PROPERTY_NAME = " .. tostring(Config.MAX_HEALTH_PROPERTY_NAME))
    else
        log("info", "  Status: NOT FOUND (may be derived or same as health)")
    end

    log("info", "")

    -- Ship Health Results
    log("info", "Ship Health Property:")
    if discovery_state.ship_health_found then
        log("info", "  Status: FOUND")
        log("info", "  Path: " .. tostring(discovery_state.ship_health_path))
        log("info", "  Value: " .. tostring(discovery_state.ship_health_value))
        log("info", "  Config.SHIP_HEALTH_PROPERTY_NAME = " .. tostring(Config.SHIP_HEALTH_PROPERTY_NAME))
    else
        log("info", "  Status: NOT FOUND (no ship instance or no matching property)")
    end

    log("info", "")

    -- Revive Property Results
    log("info", "Revive/Downed Property:")
    if discovery_state.revive_found then
        log("info", "  Status: FOUND")
        log("info", "  Path: " .. tostring(discovery_state.revive_path))
        log("info", "  Value: " .. tostring(discovery_state.revive_value))
    else
        log("info", "  Status: NOT FOUND")
    end

    log("info", "")

    -- Deferred Retry Status
    if discovery_state.retry_registered then
        log("info", "Deferred Retry: REGISTERED (waiting for player to connect)")
    else
        log("info", "Deferred Retry: NOT NEEDED (player was found or discovery complete)")
    end

    log("info", "")

    -- Error Summary
    if #discovery_state.errors > 0 then
        log("info", "Errors Encountered:")
        for _, err in ipairs(discovery_state.errors) do
            log("error", "  " .. err)
        end
        log("info", "")
    end

    log("info", "============================================================")
    log("info", "END PROPERTY DISCOVERY REPORT")
    log("info", "============================================================")
    log("info", "")
end

-- ============================================================================
-- SELF-TEST REGISTRATION
-- ============================================================================

--[[ Register self-tests in Utils harness

These tests verify:
1. Discovery state is properly initialized
2. Config flags are set correctly after discovery
3. Health property path is valid (if found)
4. Class variant data structure is sound
5. Candidate lists are non-empty
]]
local function register_self_tests()
    -- Test 1: State initialization
    Utils.register_test(MODULE_NAME .. "_state_init", function()
        if type(discovery_state) ~= "table" then
            return false
        end
        if type(discovery_state.health_found) ~= "boolean" then
            return false
        end
        if type(discovery_state.discovery_complete) ~= "boolean" then
            return false
        end
        return true
    end)

    -- Test 2: Config consistency (if health was found)
    Utils.register_test(MODULE_NAME .. "_config_consistency", function()
        if not discovery_state.health_found then
            -- If health not found, Config should still have defaults
            return Config.HEALTH_PROPERTY_NAME == nil
                and Config.HEALTH_IS_ATTRIBUTE_DATA == false
        end

        -- If health was found, Config should be updated
        if Config.HEALTH_PROPERTY_NAME == nil then
            return false
        end

        -- If AttributeData, the flag must be true
        if discovery_state.health_is_attr_data and not Config.HEALTH_IS_ATTRIBUTE_DATA then
            return false
        end

        -- If not AttributeData, the flag must be false
        if not discovery_state.health_is_attr_data and Config.HEALTH_IS_ATTRIBUTE_DATA then
            return false
        end

        return true
    end)

    -- Test 3: Health path validity (if found)
    Utils.register_test(MODULE_NAME .. "_health_path_valid", function()
        if not discovery_state.health_found then
            return true  -- Not found is not a failure
        end

        -- Path must be a non-empty string
        if type(discovery_state.health_path) ~= "string" then
            return false
        end
        if #discovery_state.health_path == 0 then
            return false
        end

        -- Value must be a positive number
        if type(discovery_state.health_value) ~= "number" then
            return false
        end
        if discovery_state.health_value <= 0 then
            return false
        end

        return true
    end)

    -- Test 4: Class variant data structure
    Utils.register_test(MODULE_NAME .. "_class_variants_structure", function()
        for key, variants in pairs(CLASS_VARIANTS) do
            if type(key) ~= "string" then return false end
            if type(variants) ~= "table" then return false end
            if #variants == 0 then return false end
            for _, v in ipairs(variants) do
                if type(v) ~= "string" then return false end
            end
        end
        return true
    end)

    -- Test 5: Candidate lists are non-empty
    Utils.register_test(MODULE_NAME .. "_candidates_nonempty", function()
        if #HEALTH_CANDIDATES == 0 then return false end
        if #MAX_HEALTH_CANDIDATES == 0 then return false end
        if #SHIP_HEALTH_CANDIDATES == 0 then return false end
        if #REVIVE_CANDIDATES == 0 then return false end
        if #ATTRIBUTE_DATA_SUBPATHS == 0 then return false end
        return true
    end)

    log("info", "Self-tests registered")
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

--[[ Main entry point

Runs property discovery immediately. If no player is connected,
registers NotifyOnNewObject for deferred retry.
]]
local function init()
    log("info", "============================================================")
    log("info", "Phase 0 Property Discovery - Initializing")
    log("info", "============================================================")

    -- Register self-tests first (so they can verify results later)
    register_self_tests()

    -- Run the discovery process
    run_discovery()

    log("info", "Phase 0 Property Discovery - Initialization complete")
end

-- ============================================================================
-- SCRIPT EXECUTION
-- ============================================================================

init()

-- ============================================================================
-- MODULE RETURN
-- ============================================================================

return {
    state = discovery_state,
    get_state = function()
        return discovery_state
    end,
    run_discovery = function()
        if not discovery_state.discovery_complete then
            run_discovery()
        end
    end,
    -- Expose class variants for other scripts that need to find these classes
    class_variants = CLASS_VARIANTS,
    -- Expose candidate lists for reference
    health_candidates = HEALTH_CANDIDATES,
    max_health_candidates = MAX_HEALTH_CANDIDATES,
    ship_health_candidates = SHIP_HEALTH_CANDIDATES,
    revive_candidates = REVIVE_CANDIDATES,
}
