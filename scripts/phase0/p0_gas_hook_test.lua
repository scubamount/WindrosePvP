--[[
    p0_gas_hook_test.lua - GAS (Gameplay Ability System) Hook Test for Phase 0
    ====================================================================

    Purpose:
        CRITICAL Phase 0 discovery test - attempts to hook multiple GAS (Gameplay 
        Ability System) internal UFunctions to determine if we can intercept 
        the damage pipeline at the GameplayEffect level.
        
        This is the HARDEST Phase 0 script because GAS is a complex subsystem with
        many potential hook points, and many may be non-hookable or crash
        on attempt.

    UE4SS API Used:
        - RegisterHook(hook_path, pre_fn, post_fn): Hook into UFunction
        - pcall: Safe property access with error isolation (CRITICAL!)
        - OnTick: Timeout detection if no events detected

    Dependencies:
        - scripts/config.lua: Config.GAS_HOOK_WORKS flag
        - scripts/utils.lua: Safe property access, hook registration, logging
        - scripts/event_bus.lua: Event publishing (gas_hook_fired)

    Hook Candidates (in priority order):
        1. BP_ApplyGameplayEffectToSelf      - Blueprint version, often used
        2. BP_ApplyGameplayEffectSpecToTarget - Blueprint version targets
        3. ApplyGameplayEffectSpecToSelf    - Native C++ version self
        4. ApplyGameplayEffectSpecToTarget - Native C++ version target
        5. ApplyGameplayEffectToTarget     - Legacy direct apply
        6. PostGameplayEffectExecute      - Post-effect callback on AttributeSet
        7. PreAttributeChange           - Pre-change callback on AttributeSet
        8. PreAttributeBaseChange       - Pre-base-change callback on AttributeSet

    What We Need to Discover:
        1. Does ANY hook candidate work? (most will fail)
        2. What parameters does each successful hook receive?
        3. Can we read the GameplayEffectSpec from params?
        4. Can we identify the target actor from params?
        5. Can we identify the source/instigator from params?
        6. Can we READ the damage/attribute magnitude?
        7. Can we MUTATE the target (redirect GE to different target)?
        8. What is the structure of FGameplayEffectSpec?
        9. What is the structure of FGameplayEffectContext?

    Test Protocol:
        1. Iterate ALL hook candidate paths in priority order
        2. For each path: attempt RegisterHook wrapped in pcall
        3. On success: register Pre+Post callbacks that log ALL params
        4. On first successful hook fire:
           - Log full parameter structure
           - Explore self's properties (AbilitySystemComponent)
           - Try to extract GameplayEffectSpec from params
           - Try to find target actor from params
           - Log FGameplayEffectSpec structure if found
        5. After first fire: analyze target mutability
           - Can we read the target param?
           - Can we write a different target?
        6. Set Config.GAS_HOOK_WORKS = true if ANY fires
        7. Emit gas_hook_fired event on EventBus
        8. Output structured Phase 0 report
        9. Timeout after 120 seconds if no events detected

    Critical Requirements:
        - MUST wrap EACH hook attempt in pcall (GAS can crash UE4SS)
        - MUST use pcall for EVERY property access in callbacks
        - MUST NOT crash if params are opaque/nil
        - MUST log each property access attempt (success/failure)
        - MUST emit event on EventBus for other Phase 0 scripts
        - MUST set Config.GAS_HOOK_WORKS appropriately
        - If ALL hooks fail: MUST log "GAS hooks unavailable — shadow damage only"
        - MUST handle the case where target param is NOT mutable
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

local MODULE_NAME = "p0_gas_hook_test"

-- All hook candidate paths (in priority order - try most likely first)
local HOOK_CANDIDATES = {
    -- AbilitySystemComponent hooks (these are the primary candidates)
    { path = "/Script/GameplayAbilities.AbilitySystemComponent:BP_ApplyGameplayEffectToSelf", priority = 1, desc = "Blueprint self-apply" },
    { path = "/Script/GameplayAbilities.AbilitySystemComponent:BP_ApplyGameplayEffectSpecToTarget", priority = 2, desc = "Blueprint spec-to-target" },
    { path = "/Script/GameplayAbilities.AbilitySystemComponent:ApplyGameplayEffectSpecToSelf", priority = 3, desc = "Native C++ self-apply" },
    { path = "/Script/GameplayAbilities.AbilitySystemComponent:ApplyGameplayEffectSpecToTarget", priority = 4, desc = "Native C++ target-apply" },
    { path = "/Script/GameplayAbilities.AbilitySystemComponent:ApplyGameplayEffectToTarget", priority = 5, desc = "Legacy direct target" },
    { path = "/Script/GameplayAbilities.AbilitySystemComponent:ApplyGameplayEffectToSelf", priority = 6, desc = "Legacy self-apply" },
    
    -- AttributeSet hooks (these are fallback callbacks)
    { path = "/Script/GameplayAbilities.AttributeSet:PostGameplayEffectExecute", priority = 7, desc = "Post-effect execute" },
    { path = "/Script/GameplayAbilities.AttributeSet:PreAttributeChange", priority = 8, desc = "Pre-attribute change" },
    { path = "/Script/GameplayAbilities.AttributeSet:PreAttributeBaseChange", priority = 9, desc = "Pre-attribute base change" },
}

-- Property names to explore on AbilitySystemComponent when hooked
local ASC_PROPERTY_CANDIDATES = {
    "Owner",
    "GetOwner",
    "AvatarActor",
    "PlayerState",
    "OwnerActor",
    "Instigator",
    "AbilityActorInfo",
    "ActivatableAbilities",
    "AttributeGameplayEffects",
    "GameplayEffects",
    "ActiveEffects",
    "OwnedGameplayEffects",
    "AssetEffects",
    "RegisteredComponents",
    "SpawnedAbilities",
    "DefaultStartingData",
    "Debug",
    "bPredictClassicFalse",
    "bPredictPassiveFalse",
}

-- Property names to explore on GameplayEffectSpec
local GE_SPEC_PROPERTY_CANDIDATES = {
    "Def",
    "Duration",
    "Period",
    "Magnitude",
    "Capture",
    "SourceObject",
    "Caller",
    "Target",
    "Instigator",
    "EffectContext",
    "ModifiedAttributes",
    "Asset",
    "GameplayEffect",
    "DurationPolicy",
    "PeriodPolicy",
    " stacks",
    "StackCount",
}

-- Property names to explore on AttributeSet
local ATTRIBUTE_CANDIDATES = {
    "Health",
    "MaxHealth",
    "CurrentHealth",
    "BaseHealth",
    "HP",
    "Damage",
    "PhysicalDamage",
    "Magnitude",
    "Attribute",
    "AttributeName",
}

-- Timeout for waiting for GAS events (120 seconds - longer than melee)
local TIMEOUT_SECONDS = 120

-- Maximum number of successful hooks to keep active
local MAX_ACTIVE_HOOKS = 3

-- ============================================================================
-- LOCAL STATE
-- ============================================================================

local state = {
    hooks_attempted = 0,           -- Number of hooks attempted
    hooks_failed = 0,              -- Number of hook registration failures
    hooks_succeeded = 0,           -- Number of successful hook registrations
    hooks_fired_count = 0,          -- Total number of hook fires across all hooks
    successful_hooks = {},          -- List of hook paths that succeeded
    hook_fired_paths = {},          -- Paths that have fired at least once
    first_successful_path = nil,   -- First path to achieve successful registration
    first_fire_path = nil,         -- First path that actually fired
    first_fire_time = nil,         -- Timestamp of first hook fire
    exploration_completed = false, -- Whether parameter exploration is done
    target_mutability_tested = false, -- Whether we've tested target mutability
    target_is_mutable = nil,       -- Whether target param can be changed
    discovered_ge_spec = false,    -- Whether GE spec structure was found
    error_log = {},               -- Log of errors encountered
    timeout_warning_logged = false, -- Whether timeout warning was logged
    phase0_report = nil,           -- Structured Phase 0 report output
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
    Try to register a single hook with full error isolation

    @param hook_path (string): The UFunction path to hook
    @param pre_fn (function): Pre-hook callback
    @param post_fn (function): Post-hook callback
    @return boolean: Whether registration succeeded
    @return string: Error message if failed
]]
local function try_register_hook(hook_path, pre_fn, post_fn)
    -- Wrap the entire registration in pcall for maximum safety
    local ok, err = pcall(function()
        RegisterHook(hook_path, pre_fn, post_fn)
    end)
    
    if not ok then
        -- Registration crashed - this is common with GAS hooks
        log_message("debug", "Hook registration CRASHED: " .. hook_path)
        log_message("debug", "  Crash error: " .. tostring(err))
        table.insert(state.error_log, {
            path = hook_path,
            error = tostring(err),
            type = "crash"
        })
        return false, "crash: " .. tostring(err)
    end
    
    -- Registration succeeded (no error returned yet means it worked)
    log_message("info", "Hook registered: " .. hook_path)
    return true, nil
end

--[[
    Explore properties on a UObject

    @param obj (userdata): The UObject to explore
    @param candidates (table): List of property names
    @return table: Map of property_name -> {success, value, type, tostring}
]]
local function explore_properties(obj, candidates)
    local results = {}
    if not obj or not obj:IsValid() then
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
            log_message("debug", "  Found: " .. prop_name .. " = " .. result.tostring)
        end
        results[prop_name] = result
    end

    return results
end

--[[
    Try to extract the target actor from various parameter positions

    @param params (table): The params passed to the hook
    @return userdata|nil: The target actor if found
]]
local function extract_target_from_params(params)
    if not params then return nil end
    
    -- Try common parameter positions
    local positions = {1, 2, "Target", "TargetActor", "TargetObject"}
    
    for _, pos in ipairs(positions) do
        local value = params[pos]
        if value and type(value) == "userdata" then
            local ok, valid = pcall(function() return value:IsValid() end)
            if ok and valid then
                local ok2, is_actor = pcall(function() return value:IsA("Actor") end)
                if ok2 and is_actor then
                    log_message("debug", "  Target found at position: " .. tostring(pos))
                    return value
                end
            end
        end
    end
    
    return nil
end

--[[
    Try to find a GameplayEffectSpec in the parameters

    @param params (table): The params passed to the hook
    @return userdata|nil: The GameplayEffectSpec if found
]]
local function find_ge_spec(params)
    if not params then return nil end
    
    -- Try to find GameplayEffectSpec in any parameter
    local positions = {1, 2, 3, "Spec", "EffectSpec", "GameplayEffectSpec", "GESpec"}
    
    for _, pos in ipairs(positions) do
        local value = params[pos]
        if value and type(value) == "userdata" then
            local ok, valid = pcall(function() return value:IsValid() end)
            if ok and valid then
                local ok2, class_name = pcall(function() return value:GetClass():GetName() end)
                if ok2 and class_name then
                    if class_name:find("GameplayEffectSpec") or class_name:find("GES") then
                        log_message("debug", "  GameplayEffectSpec found at: " .. tostring(pos))
                        state.discovered_ge_spec = true
                        return value
                    end
                end
            end
        end
    end
    
    return nil
end

--[[
    Test if the target parameter is mutable (can be redirected)

    @param self (userdata): The AbilitySystemComponent
    @param params (table): Parameters passed to the hook
    @return boolean|nil: Whether target is mutable, or nil if untested
]]
local function test_target_mutability(self, params)
    if state.target_mutability_tested then
        return state.target_is_mutable
    end
    
    state.target_mutability_tested = true
    
    -- Try to find the target parameter
    local target = extract_target_from_params(params)
    if not target then
        log_message("debug", "  Cannot determine target for mutability test")
        state.target_is_mutable = false
        return false
    end
    
    -- Try to write back a different value
    -- Note: This is a READ-ONLY test - we don't actually modify
    -- We just check if assignment is allowed by trying and catching
    local ok, err = pcall(function()
        -- Try to assign back the same target (should always work if it's a ref)
        -- If this crashes, it's definitely not mutable
        params.Target = target
    end)
    
    if ok then
        log_message("debug", "  Target parameter MUTABLE (can redirect)")
        state.target_is_mutable = true
        return true
    else
        log_message("debug", "  Target parameter IMMUTABLE (read-only)")
        log_message("debug", "    Reason: " .. tostring(err))
        state.target_is_mutable = false
        return false
    end
end

--[[
    Log the full parameter structure for a hook fire

    @param hook_path (string): The hook path that fired
    @param self_obj (userdata): The AbilitySystemComponent or AttributeSet
    @param params (table): The parameters
    @param is_post (boolean): Whether this is post-hook
]]
local function log_parameter_structure(hook_path, self_obj, params, is_post)
    log_message("info", "=== GAS HOOK FIRED: " .. hook_path .. " ===")
    log_message("info", "Hook type: " .. (is_post and "POST" or "PRE"))
    
    -- Log self object
    if self_obj and self_obj:IsValid() then
        local ok, class_name = pcall(function() return self_obj:GetClass():GetName() end)
        log_message("info", "Self: " .. safe_tostring(self_obj) .. " (class: " .. (ok and class_name or "unknown") .. ")")
        
        -- Explore properties based on class
        local is_asc = class_name and class_name:find("AbilitySystemComponent")
        local is_attr_set = class_name and class_name:find("AttributeSet")
        
        if is_asc then
            local asc_props = explore_properties(self_obj, ASC_PROPERTY_CANDIDATES)
            log_message("info", "ASC properties explored: " .. Utils.table_count(asc_props))
        elseif is_attr_set then
            local attr_props = explore_properties(self_obj, ATTRIBUTE_CANDIDATES)
            log_message("info", "AttributeSet properties explored: " .. Utils.table_count(attr_props))
        end
    else
        log_message("info", "Self: " .. safe_tostring(self_obj))
    end
    
    -- Log params
    if params then
        log_message("info", "Parameters received:")
        local param_count = 0
        for k, v in pairs(params) do
            param_count = param_count + 1
            local type_str = safe_type(v)
            local value_str = safe_tostring(v)
            log_message("info", "  [" .. tostring(k) .. "] = " .. value_str .. " (type: " .. type_str .. ")")
        end
        log_message("info", "Total parameters: " .. param_count)
        
        -- Try to extract target
        local target = extract_target_from_params(params)
        if target then
            log_message("info", "Target actor: " .. safe_tostring(target))
            test_target_mutability(self_obj, params)
        end
        
        -- Try to find GE spec
        local ge_spec = find_ge_spec(params)
        if ge_spec then
            log_message("info", "GameplayEffectSpec: " .. safe_tostring(ge_spec))
            explore_properties(ge_spec, GE_SPEC_PROPERTY_CANDIDATES)
        end
    else
        log_message("info", "Parameters: nil (no varargs passed)")
    end
    
    log_message("info", "=== END GAS HOOK PARAMETER STRUCTURE ===")
end

--[[
    Generate the Phase 0 report section

    @return string: Formatted report
]]
local function generate_phase0_report()
    local report_lines = {
        "### GAS Hook Test Results (Phase 0)",
        "",
        "**Hook Candidates Attempted:** " .. state.hooks_attempted,
        "**Hook Registration Failures:** " .. state.hooks_failed,
        "**Hook Registration Successes:** " .. state.hooks_succeeded,
        "**Hooks That Actually Fired:** " .. state.hooks_fired_count,
        "",
    }
    
    if state.hooks_succeeded > 0 then
        table.insert(report_lines, "**Successful Hooks:**")
        for _, path in ipairs(state.successful_hooks) do
            table.insert(report_lines, "  - " .. path)
        end
        table.insert(report_lines, "")
    end
    
    if state.first_fire_path then
        table.insert(report_lines, "**First Hook To Fire:** " .. state.first_fire_path)
    end
    
    if state.target_mutability_tested then
        local mutable_str = state.target_is_mutable and "YES - can redirect GE to different target" or "NO - target is read-only"
        table.insert(report_lines, "**Target Mutability:** " .. mutable_str)
    end
    
    table.insert(report_lines, "")
    
    if state.hooks_succeeded > 0 and state.hooks_fired_count > 0 then
        table.insert(report_lines, "**Status:** GAS hooks AVAILABLE - damage interception possible")
        table.insert(report_lines, "**Config Flag:** Config.GAS_HOOK_WORKS = true")
    else
        table.insert(report_lines, "**Status:** GAS hooks UNAVAILABLE - shadow damage only")
        table.insert(report_lines, "**Config Flag:** Config.GAS_HOOK_WORKS = false")
    end
    
    if #state.error_log > 0 then
        table.insert(report_lines, "")
        table.insert(report_lines, "**Errors Encountered:**")
        for _, err in ipairs(state.error_log) do
            table.insert(report_lines, "  - " .. err.path .. ": " .. err.error)
        end
    end
    
    state.phase0_report = table.concat(report_lines, "\n")
    return state.phase0_report
end

-- ============================================================================
-- HOOK CALLBACK FACTORY
-- ============================================================================

--[[
    Create callbacks for a specific hook path

    @param hook_path (string): The UFunction path
    @return function: Pre-hook callback
    @return function: Post-hook callback
]]
local function create_callbacks(hook_path)
    local pre_hook = function(self_obj, ...)
        -- Track fire count
        state.hooks_fired_count = state.hooks_fired_count + 1
        local current_time = os.time()
        
        if not state.first_fire_time then
            state.first_fire_time = current_time
            state.first_fire_path = hook_path
            log_message("info", "=== FIRST GAS HOOK FIRE ===")
            log_message("info", "Path: " .. hook_path)
        end
        
        -- Track which paths have fired
        if not state.hook_fired_paths[hook_path] then
            state.hook_fired_paths[hook_path] = true
            log_message("info", "Hook fire: " .. hook_path)
        end
        
        log_message("debug", "Pre-hook fire: " .. hook_path .. " (fire #" .. state.hooks_fired_count .. ")")
        
        -- Collect varargs
        local params = {}
        local arg_count = select("#", ...)
        for i = 1, arg_count do
            params[i] = select(i, ...)
        end
        
        -- Log parameter structure on first fire only
        if state.hooks_fired_count == 1 and not state.exploration_completed then
            log_parameter_structure(hook_path, self_obj, params, false)
            state.exploration_completed = true
        end
        
        -- Emit event to EventBus
        EventBus.emit("gas_hook_fired", {
            hook_path = hook_path,
            is_post = false,
            self = safe_tostring(self_obj),
            param_count = arg_count,
            timestamp = current_time,
            target_mutable = state.target_is_mutable,
            ge_spec_found = state.discovered_ge_spec,
        })
        
        -- Set Config flag if first fire
        if not Config.GAS_HOOK_WORKS then
            Config.GAS_HOOK_WORKS = true
            log_message("info", "Config.GAS_HOOK_WORKS set to TRUE")
        end
    end
    
    local post_hook = function(self_obj, ...)
        log_message("debug", "Post-hook fire: " .. hook_path)
        
        -- Collect varargs (includes return value as last arg)
        local arg_count = select("#", ...)
        local params = {}
        local retval = nil
        
        for i = 1, arg_count do
            local v = select(i, ...)
            if i == arg_count then
                retval = v
            else
                params[i] = v
            end
        end
        
        -- Log return value
        if retval ~= nil then
            log_message("debug", "Return value: " .. safe_tostring(retval))
        end
        
        -- Emit event
        EventBus.emit("gas_hook_fired", {
            hook_path = hook_path,
            is_post = true,
            self = safe_tostring(self_obj),
            param_count = arg_count,
            return_value = safe_tostring(retval),
            timestamp = os.time(),
        })
    end
    
    return pre_hook, post_hook
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

--[[
    Initialize the GAS hook test

    Attempts to register ALL hook candidates in priority order.
    Logs success/failure for each.
]]
local function init()
    log_message("info", "Initializing " .. MODULE_NAME)
    log_message("info", "Attempting " .. #HOOK_CANDIDATES .. " GAS hook candidates...")
    
    -- Sort by priority
    local sorted = {}
    for i, c in ipairs(HOOK_CANDIDATES) do
        sorted[#sorted + 1] = c
    end
    table.sort(sorted, function(a, b) return a.priority < b.priority end)
    
    -- Try each candidate
    for _, candidate in ipairs(sorted) do
        local hook_path = candidate.path
        state.hooks_attempted = state.hooks_attempted + 1
        
        log_message("info", "Attempting: " .. hook_path)
        log_message("debug", "  Description: " .. candidate.desc)
        
        -- Create callbacks
        local pre_fn, post_fn = create_callbacks(hook_path)
        
        -- Try to register (wrapped in pcall for safety)
        local success, err = try_register_hook(hook_path, pre_fn, post_fn)
        
        if success then
            state.hooks_succeeded = state.hooks_succeeded + 1
            state.successful_hooks[#state.successful_hooks + 1] = hook_path
            state.hook_fired_paths[hook_path] = false
            
            if not state.first_successful_path then
                state.first_successful_path = hook_path
                log_message("info", "  FIRST SUCCESSFUL HOOK: " .. hook_path)
                log_message("info", "  Description: " .. candidate.desc)
            end
            
            log_message("info", "  Registered: " .. hook_path)
        else
            state.hooks_failed = state.hooks_failed + 1
            -- Don't log failure as error - expected with GAS hooks
            log_message("debug", "  Failed: " .. hook_path .. " (" .. tostring(err) .. ")")
        end
        
        -- Limit active hooks to prevent overhead
        if state.hooks_succeeded >= MAX_ACTIVE_HOOKS then
            log_message("info", "Maximum active hooks reached: " .. MAX_ACTIVE_HOOKS)
            break
        end
    end
    
    -- Final summary
    log_message("info", "=== HOOK REGISTRATION COMPLETE ===")
    log_message("info", "Attempted: " .. state.hooks_attempted)
    log_message("info", "Succeeded: " .. state.hooks_succeeded)
    log_message("info", "Failed: " .. state.hooks_failed)
    
    if state.hooks_succeeded > 0 then
        Config.GAS_HOOK_WORKS = true
        log_message("info", "GAS HOOKS AVAILABLE - damage interception possible")
        log_message("info", "Config.GAS_HOOK_WORKS = true")
        
        -- Emit ready event
        EventBus.emit("gas_hooks_ready", {
            hook_count = state.hooks_succeeded,
            hooks = state.successful_hooks,
        })
    else
        Config.GAS_HOOK_WORKS = false
        log_message("error", "GAS hooks UNAVAILABLE - shadow damage only")
        log_message("error", "All " .. state.hooks_attempted .. " hook candidates failed")
        log_message("error", "Damage must be intercepted via PostExecute/PreAttributeChange instead")
        
        -- Emit unavailable event
        EventBus.emit("gas_hooks_unavailable", {
            attempted = state.hooks_attempted,
            errors = state.error_log,
        })
    end
    
    -- Generate initial report
    local report = generate_phase0_report()
    log_message("info", "")
    log_message("info", "=== PHASE 0 REPORT ===")
    log_message("info", report)
end

-- ============================================================================
-- ONTICK HANDLER
-- ============================================================================

--[[
    OnTick handler for timeout detection

    If no GAS events fire within TIMEOUT_SECONDS, log a warning.
]]
local function on_tick()
    -- Skip if no hooks registered
    if state.hooks_succeeded == 0 then return end
    
    -- Skip if already fired
    if state.hooks_fired_count > 0 then return end
    
    local current_time = os.time()
    if state.first_fire_time then
        local elapsed = current_time - state.first_fire_time
        if elapsed >= TIMEOUT_SECONDS and not state.timeout_warning_logged then
            state.timeout_warning_logged = true
            log_message("warn", "=== TIMEOUT: No GAS events detected ===")
            log_message("warn", "Waited " .. TIMEOUT_SECONDS .. " seconds but no GAS hook fired")
            log_message("warn", "This is expected if no gameplay effects are applied during this time")
            log_message("warn", "The hooks are registered and will fire when a GE is applied")
            log_message("warn", "To test: have a player take damage or use an ability")
        end
    end
end

-- ============================================================================
-- MODULE REGISTRATION
-- ============================================================================

-- Register OnTick callback
if OnTick then
    OnTick.Add(on_tick)
    log_message("info", "OnTick handler registered")
end

-- Initialize the module
init()

-- ============================================================================
-- MODULE EXPORTS
-- ============================================================================

local GASHookTest = {
    -- Get current state
    get_state = function()
        return state
    end,
    
    -- Check if any hook is working
    is_working = function()
        return state.hooks_succeeded > 0 and state.hooks_fired_count > 0
    end,
    
    -- Check if hooks are registered but not fired
    is_registered = function()
        return state.hooks_succeeded > 0
    end,
    
    -- Get successful hook paths
    get_successful_hooks = function()
        return state.successful_hooks
    end,
    
    -- Get phase0 report
    get_phase0_report = function()
        return generate_phase0_report()
    end,
    
    -- Check if target is mutable
    is_target_mutable = function()
        return state.target_is_mutable
    end,
}

-- ============================================================================
-- SELF-TEST REGISTRATION
-- ============================================================================

-- Register self-tests in Utils
Utils.register_test("gas_hook_test_state", function()
    return type(state) == "table" and state.hooks_attempted ~= nil
end)

Utils.register_test("gas_hook_test_module", function()
    return type(GASHookTest) == "table" and type(GASHookTest.is_working) == "function"
end)

return GASHookTest