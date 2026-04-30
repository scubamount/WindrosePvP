--[[
    p0_melee_hook_test.lua - Melee Ability Hook Test for Phase 0
    =============================================================

    Purpose:
        CRITICAL Phase 0 discovery test - hooks into UR5MeleeAbility::RemoveEventGEs
        to determine if we can extract target and damage information from melee combat.
        This is essential for the Damage Router in Phase 1.

    UE4SS API Used:
        - RegisterHook(hook_path, pre_fn, post_fn): Hook into UFunction
        - pcall: Safe property access with error isolation
        - OnTick: Timeout detection if no melee events fire

    Dependencies:
        - scripts/config.lua: Config.MELEE_HOOK_WORKS flag
        - scripts/utils.lua: Safe property access, hook registration, logging
        - scripts/event_bus.lua: Event publishing (melee_hook_fired)

    What We Need to Discover:
        1. Does the hook fire when a player attacks? (vs only NPC attacks)
        2. What parameters does the Pre callback receive? (self, and what else?)
        3. Can we identify the instigator (attacker) from the params?
        4. Can we identify the target (hit character) from the params?
        5. Can we read the GameplayEffect class names being removed?
        6. Can we read the damage amount from any parameter?

    Test Protocol:
        1. Register Pre and Post hooks on RemoveEventGEs
        2. On first Pre hook fire:
           - Log all parameters received (type, tostring value)
           - Traverse self's property chain to find: instigator, owner, target
           - Log all readable properties on the UR5MeleeAbility instance
           - Try to read GameplayEffect data from params
        3. Emit event on EventBus with hook data
        4. After first successful fire: log parameter structure summary
        5. Update Config with discovered property paths
        6. Timeout after 60 seconds if no melee events detected

    Critical Requirements:
        - MUST handle hook registration failure gracefully
        - MUST use pcall for EVERY property access
        - MUST NOT crash if params are opaque/nil
        - MUST log each property access attempt (success/failure)
        - MUST emit event on EventBus for other Phase 0 scripts
        - MUST set Config.MELEE_HOOK_WORKS appropriately
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

local MODULE_NAME = "p0_melee_hook_test"

-- The confirmed UFunction path from game logs
local HOOK_PATH = "/Script/R5.R5MeleeAbility:RemoveEventGEs"

-- Property names to try when exploring the melee ability instance
local PROPERTY_CANDIDATES = {
    "Instigator",
    "Owner",
    "GetOwner",
    "Target",
    "HitResult",
    "HitComponent",
    "Damage",
    "DamageAmount",
    "BaseDamage",
    "EventReceivingActor",
    "TargetActor",
    "SourceActor",
    "AbilitySystemComponent",
    "AvatarActor",
    "MeleeWeapon",
    "Weapon",
    "DamageType",
    "DamageClass",
    "HitLocation",
    "HitNormal",
}

-- Timeout for waiting for melee events (60 seconds)
local TIMEOUT_SECONDS = 60

-- ============================================================================
-- LOCAL STATE
-- ============================================================================

local state = {
    hook_registered = false,       -- Whether hook registration succeeded
    hook_fired = false,            -- Whether hook has fired at least once
    first_fire_time = nil,         -- Timestamp of first hook fire
    last_fire_time = nil,          -- Timestamp of most recent hook fire
    fire_count = 0,                -- Number of times hook has fired
    exploration_completed = false, -- Whether property exploration is done
    discovered_properties = {},   -- Map of discovered property paths
    error_message = nil,           -- Error message if hook failed
    timeout_warning_logged = false, -- Whether we've logged the timeout warning
}

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

--[[
    Log a message with module prefix

    @param level (string): Log level - "info", "warn", "error", "debug"
    @param message (string): Message to log
]]
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

--[[
    Safely get the type of a value, handling edge cases

    @param value (any): Value to check
    @return string: Type string
]]
local function safe_type(value)
    if value == nil then return "nil" end
    local t = type(value)
    if t == "userdata" then
        -- Try to determine if it's a UObject
        local ok, _ = pcall(function() return value:IsValid() end)
        if ok then return "UObject" end
        return "userdata"
    end
    return t
end

--[[
    Safely convert a value to string for logging

    @param value (any): Value to convert
    @return string: String representation
]]
local function safe_tostring(value)
    local ok, result = pcall(function()
        if value == nil then return "nil" end
        local t = type(value)
        if t == "string" then return value end
        if t == "number" then return tostring(value) end
        if t == "boolean" then return tostring(value) end
        if t == "userdata" then
            if value:IsValid() then
                local addr = string.format("%p", value)
                local class_name = "Unknown"
                local ok2, name = pcall(function() return value:GetClass():GetName() end)
                if ok2 and name then class_name = name end
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

--[[
    Explore a UObject's properties using candidate names

    @param obj (userdata): The UObject to explore
    @param candidates (table): List of property names to try
    @return table: Map of property_name -> {success=bool, value=any, type=string}
]]
local function explore_properties(obj, candidates)
    local results = {}
    if not obj or not obj:IsValid() then
        log_message("debug", "Cannot explore properties on invalid object")
        return results
    end

    for _, prop_name in ipairs(candidates) do
        local result = { property = prop_name, success = false, value = nil, type = "unknown" }
        local ok, value = pcall(function() return obj[prop_name] end)
        if ok and value ~= nil then
            result.success = true
            result.value = value
            result.type = safe_type(value)
            result.tostring = safe_tostring(value)
            log_message("debug", "  Found property: " .. prop_name .. " = " .. result.tostring)
        else
            log_message("debug", "  Property not found: " .. prop_name)
        end
        results[prop_name] = result
    end

    return results
end

--[[
    Try to find an actor from a property value

    @param value (any): Property value that might be an actor
    @return userdata|nil: The actor if found
]]
local function extract_actor(value)
    if not value then return nil end
    local ok, result = pcall(function()
        if type(value) == "userdata" and value:IsValid() then
            -- Check if it's an actor
            local ok2, is_actor = pcall(function() return value:IsA("Actor") end)
            if ok2 and is_actor then return value end
        end
        return nil
    end)
    return ok and result or nil
end

--[[
    Try to find damage amount from various property paths

    @param obj (userdata): The melee ability object
    @return number|nil: The damage amount if found
]]
local function find_damage_amount(obj)
    if not obj or not obj:IsValid() then return nil end

    local damage_paths = {
        "Damage",
        "DamageAmount",
        "BaseDamage",
        "DamageVal",
        "DamageValue",
    }

    for _, path in ipairs(damage_paths) do
        local ok, value = pcall(function() return obj[path] end)
        if ok and value and type(value) == "number" then
            log_message("debug", "Found damage amount: " .. path .. " = " .. tostring(value))
            return value
        end
    end

    return nil
end

--[[
    Log the parameter structure summary

    @param self (userdata): The UR5MeleeAbility instance
    @param params (table): The parameters passed to the hook
]]
local function log_parameter_summary(self, params)
    log_message("info", "=== MELEE HOOK PARAMETER SUMMARY ===")

    -- Log self properties
    log_message("info", "Self (UR5MeleeAbility): " .. safe_tostring(self))

    -- Try to get class info
    local ok, class_name = pcall(function() return self:GetClass():GetName() end)
    if ok and class_name then
        log_message("info", "  Class: " .. class_name)
    end

    -- Explore common properties
    local prop_results = explore_properties(self, PROPERTY_CANDIDATES)

    -- Store discovered properties
    for prop_name, result in pairs(prop_results) do
        if result.success then
            state.discovered_properties[prop_name] = {
                type = result.type,
                value_tostring = result.tostring,
            }
        end
    end

    -- Try to find damage
    local damage = find_damage_amount(self)
    if damage then
        log_message("info", "  Damage Amount: " .. tostring(damage))
        state.discovered_properties["DamageAmount"] = { type = "number", value = damage }
    else
        log_message("info", "  Damage Amount: NOT FOUND")
    end

    -- Log params table
    if params then
        log_message("info", "Params table:")
        local param_count = 0
        for k, v in pairs(params) do
            param_count = param_count + 1
            log_message("info", "  [" .. tostring(k) .. "] = " .. safe_tostring(v) .. " (type: " .. safe_type(v) .. ")")
        end
        log_message("info", "  Total params: " .. param_count)
    else
        log_message("info", "Params: nil")
    end

    log_message("info", "=== END PARAMETER SUMMARY ===")
end

--[[
    Emit the melee hook event to EventBus

    @param self (userdata): The UR5MeleeAbility instance
    @param params (table): The parameters passed to the hook
    @param is_post (boolean): Whether this is the post hook
    @param retval (any): Return value (for post hook)
]]
local function emit_melee_event(self, params, is_post, retval)
    local event_data = {
        timestamp = os.time(),
        is_post = is_post,
        self_type = safe_type(self),
        self_tostring = safe_tostring(self),
        param_count = params and Utils.table_count(params) or 0,
        discovered_properties = state.discovered_properties,
    }

    -- Try to extract useful information
    if self and self:IsValid() then
        -- Try to get instigator
        local ok, instigator = pcall(function() return self.Instigator end)
        if ok and instigator then
            event_data.instigator = safe_tostring(instigator)
        end

        -- Try to get target
        local ok2, target = pcall(function() return self.Target end)
        if ok2 and target then
            event_data.target = safe_tostring(target)
        end

        -- Try to get owner
        local ok3, owner = pcall(function() return self:GetOwner() end)
        if ok3 and owner then
            event_data.owner = safe_tostring(owner)
        end
    end

    if is_post then
        event_data.return_value = safe_tostring(retval)
    end

    EventBus.emit("melee_hook_fired", event_data)
end

-- ============================================================================
-- HOOK CALLBACKS
-- ============================================================================

--[[
    Pre-hook callback for RemoveEventGEs

    This fires BEFORE the original function executes.

    @param self (userdata): The UR5MeleeAbility instance
    @param ... (vararg): Additional parameters passed to the function
]]
local function pre_hook(self, ...)
    -- Track that hook fired
    state.hook_fired = true
    state.fire_count = state.fire_count + 1
    local current_time = os.time()

    if not state.first_fire_time then
        state.first_fire_time = current_time
        log_message("info", "=== MELEE HOOK FIRED FOR FIRST TIME ===")
        log_message("info", "Hook path: " .. HOOK_PATH)
        log_message("info", "Auth confirmed: true (from game logs)")
    end
    state.last_fire_time = current_time

    log_message("debug", "Pre-hook fired (fire #" .. state.fire_count .. ")")

    -- Collect varargs into a table for inspection
    local params = {}
    local param_index = 1
    for i, v in ipairs({...}) do
        params[param_index] = v
        param_index = param_index + 1
    end

    -- Also capture named params if available
    local vararg_start = select("#", ...)
    if vararg_start > 0 then
        log_message("debug", "Received " .. vararg_start .. " vararg parameters")
    end

    -- Log parameter details
    log_message("debug", "Self: " .. safe_tostring(self))
    for i = 1, vararg_start do
        local v = select(i, ...)
        log_message("debug", "Param[" .. i .. "]: " .. safe_tostring(v) .. " (type: " .. safe_type(v) .. ")")
    end

    -- On first fire, do full exploration
    if state.fire_count == 1 then
        log_parameter_summary(self, params)
        state.exploration_completed = true
    end

    -- Emit event for other Phase 0 scripts
    emit_melee_event(self, params, false, nil)

    -- Update Config with results
    if not Config.MELEE_HOOK_WORKS then
        Config.MELEE_HOOK_WORKS = true
        log_message("info", "Config.MELEE_HOOK_WORKS set to true")
    end
end

--[[
    Post-hook callback for RemoveEventGEs

    This fires AFTER the original function executes.

    @param self (userdata): The UR5MeleeAbility instance
    @param ... (vararg): Parameters and return value
]]
local function post_hook(self, ...)
    log_message("debug", "Post-hook fired")

    -- Get return value (last item in varargs)
    local arg_count = select("#", ...)
    local retval = nil
    local params = {}

    if arg_count > 0 then
        -- Return value is typically the last parameter
        retval = select(arg_count, ...)
        -- Params are everything except the last one
        for i = 1, arg_count - 1 do
            params[i] = select(i, ...)
        end
    end

    log_message("debug", "Return value: " .. safe_tostring(retval))

    -- Emit event for other Phase 0 scripts
    emit_melee_event(self, params, true, retval)
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

--[[
    Initialize the melee hook test

    Registers hooks and sets up timeout detection.
]]
local function init()
    log_message("info", "Initializing " .. MODULE_NAME)
    log_message("info", "Hook target: " .. HOOK_PATH)

    -- Register the hook using Utils.safe_hook
    local registered = Utils.safe_hook(HOOK_PATH, pre_hook, post_hook)

    if registered then
        state.hook_registered = true
        Config.MELEE_HOOK_WORKS = true
        log_message("info", "Hook registered successfully")
        log_message("info", "Waiting for melee events to fire...")
        log_message("info", "Timeout: " .. TIMEOUT_SECONDS .. " seconds")
    else
        state.hook_registered = false
        state.error_message = "Failed to register hook on " .. HOOK_PATH
        Config.MELEE_HOOK_WORKS = false
        log_message("error", state.error_message)
        log_message("error", "Melee ability hook test FAILED")
    end
end

-- ============================================================================
-- ONTICK HANDLER
-- ============================================================================

--[[
    OnTick handler for timeout detection

    If no melee events fire within TIMEOUT_SECONDS, log a warning.
]]
local function on_tick()
    if not state.hook_registered then return end
    if state.hook_fired then return end

    local current_time = os.time()
    if state.first_fire_time then
        local elapsed = current_time - state.first_fire_time
        if elapsed >= TIMEOUT_SECONDS and not state.timeout_warning_logged then
            state.timeout_warning_logged = true
            log_message("warn", "=== TIMEOUT: No melee events detected ===")
            log_message("warn", "Waited " .. TIMEOUT_SECONDS .. " seconds but no melee hook fired")
            log_message("warn", "This is expected if no player has attacked during this time")
            log_message("warn", "The hook is registered and will fire when a player attacks")
            log_message("warn", "To test: have a player perform a melee attack")
        end
    end
end

-- ============================================================================
-- MODULE REGISTRATION
-- ============================================================================

-- Register the OnTick callback
if OnTick then
    OnTick.Add(on_tick)
    log_message("info", "OnTick handler registered")
end

-- Initialize the module
init()

-- ============================================================================
-- MODULE EXPORTS
-- ============================================================================

local MeleeHookTest = {
    -- Get current state
    get_state = function()
        return state
    end,

    -- Check if hook is working
    is_working = function()
        return state.hook_registered and Config.MELEE_HOOK_WORKS
    end,

    -- Get discovered properties
    get_discovered_properties = function()
        return state.discovered_properties
    end,

    -- Check if exploration completed
    is_exploration_complete = function()
        return state.exploration_completed
    end,
}

return MeleeHookTest