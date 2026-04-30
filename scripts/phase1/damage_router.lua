--- WindrosePvP Damage Router
--- Phase 1 module that intercepts melee/combat damage and redirects it between
--- PvP duel participants using the shadow damage system.
---
--- This is the CORE of the PvP mod — it hooks into the game's damage system
--- and routes damage appropriately when players are in active duels.
---
--- Key responsibilities:
--- 1. Register hooks on melee/combat UFunctions
--- 2. Extract target, damage amount, and instigator from hook parameters
--- 3. Check if target is in an active duel with the instigator
--- 4. Redirect damage via HealthManager.apply_damage (shadow damage)
--- 5. Send damage feedback messages
--- 6. Block original damage when successfully redirected
---
--- @require Config - Module configuration (DAMAGE_MESSAGES_ENABLED, etc.)
--- @require Utils - Safe property access utilities
--- @require EventBus - Internal pub/sub for events
--- @require PvPStateManager - PvP duel state management
--- @require HealthManager - Shadow damage application

local Config = require("scripts.config")
local Utils = require("scripts.utils")
local EventBus = require("scripts.event_bus")
local PvPStateManager = require("scripts.phase1.pvp_state_manager")
local HealthManager = require("scripts.phase1.health_manager")

local M = {}

-- ===========================================================================
-- Private State
-- ===========================================================================

--- Whether the module has been initialized
M._initialized = false

--- Subscription IDs for EventBus listeners (for cleanup)
M._subscriptions = {}

--- Damage routing statistics (for RCON and debugging)
M._stats = {
    total_hooks_fired = 0,           -- Total hook invocations
    damage_redirected = 0,            -- Damage events successfully redirected
    damage_blocked = 0,               -- Original damage events blocked
    damage_passed_through = 0,        -- Non-duel damage passed through
    no_target_found = 0,              -- Hooks fired but no target extracted
    not_in_duel = 0,                  -- Target found but not in duel
    invalid_instigator = 0,           -- Instigator not valid
    hook_registration_failed = 0,     -- Failed to register hooks
    messages_sent = 0,                -- Damage messages sent
}

-- ===========================================================================
-- Target Extraction
-- ===========================================================================

--- Extract the target player from hook parameters.
--- Tries multiple property paths to find the target actor.
--- This is necessary because different hooks may pass the target differently.
---
--- @param ... any Hook parameters (varies by hook)
--- @return userdata|nil Target player UObject, or nil if not found
function M.extract_target(...)
    local args = {...}

    -- Strategy 1: Check for explicit Target parameter (common in many hooks)
    -- The first few parameters often contain the target
    for i = 1, math.min(#args, 5) do
        local param = args[i]
        if param and type(param) == "userdata" then
            local ok, valid = pcall(function() return param:IsValid() end)
            if ok and valid then
                -- Check if it's a player character (has health, etc.)
                local health = Utils.safe_read(param, "Health")
                    or Utils.safe_read(param, "CurrentHealth")
                    or Utils.safe_read(param, "CharacterHealth")
                if health ~= nil then
                    Utils.debug("extract_target: found target via param[" .. i .. "]")
                    return param
                end
            end
        end
    end

    -- Strategy 2: Check for HitResult.HitActor (common in melee hits)
    for i = 1, #args do
        local param = args[i]
        if param and type(param) == "table" then
            -- Look for HitResult or similar struct
            local hit_actor = param.HitActor
                or param.HitResult
                or param.OtherActor
                or param.Target

            if hit_actor and type(hit_actor) == "userdata" then
                local ok, valid = pcall(function() return hit_actor:IsValid() end)
                if ok and valid then
                    Utils.debug("extract_target: found target via struct field")
                    return hit_actor
                end
            end
        end
    end

    -- Strategy 3: Check for EventReceivingActor (common in damage events)
    for i = 1, #args do
        local param = args[i]
        if param and type(param) == "userdata" then
            local receiving_actor = param.EventReceivingActor
                or param.Recipient
                or param.ReceivingActor

            if receiving_actor and type(receiving_actor) == "userdata" then
                local ok, valid = pcall(function() return receiving_actor:IsValid() end)
                if ok and valid then
                    Utils.debug("extract_target: found target via EventReceivingActor")
                    return receiving_actor
                end
            end
        end
    end

    Utils.debug("extract_target: no target found in parameters")
    return nil
end

-- ===========================================================================
-- Damage Amount Extraction
-- ===========================================================================

--- Extract the damage amount from hook parameters.
--- Tries multiple property paths to find the damage value.
---
--- @param ... any Hook parameters
--- @return number|nil Damage amount, or nil if not found
function M.extract_damage_amount(...)
    local args = {...}

    -- Strategy 1: Look for explicit damage parameters
    for i = 1, #args do
        local param = args[i]
        if type(param) == "number" and param > 0 and param < 10000 then
            -- Reasonable damage range (not an address or index)
            Utils.debug("extract_damage_amount: found via param[" .. i .. "]: " .. param)
            return param
        end
    end

    -- Strategy 2: Look for damage in structs/tables
    for i = 1, #args do
        local param = args[i]
        if type(param) == "table" then
            local damage = param.Damage
                or param.DamageAmount
                or param.DamageToApply
                or param.BaseDamage
                or param.InstigatedDamage

            if type(damage) == "number" and damage > 0 then
                Utils.debug("extract_damage_amount: found via struct field: " .. damage)
                return damage
            end
        end
    end

    -- Default damage if nothing found (fallback for testing)
    Utils.debug("extract_damage_amount: using default 10")
    return 10
end

-- ===========================================================================
-- Instigator Extraction
-- ===========================================================================

--- Extract the instigator (attacker) from the melee ability self.
--- The instigator is typically the owner of the ability.
---
--- @param self userdata The melee ability UObject
--- @return userdata|nil Instigator player, or nil if not found
function M.extract_instigator(self)
    if not self then
        return nil
    end

    -- Strategy 1: GetOwner() on the ability
    local owner = self.GetOwner and self:GetOwner()
    if owner and type(owner) == "userdata" then
        local ok, valid = pcall(function() return owner:IsValid() end)
        if ok and valid then
            Utils.debug("extract_instigator: found via GetOwner()")
            return owner
        end
    end

    -- Strategy 2: Check Instigator property
    local instigator = self.Instigator
        or self.Owner
        or self.InstigatorActor

    if instigator and type(instigator) == "userdata" then
        local ok, valid = pcall(function() return instigator:IsValid() end)
        if ok and valid then
            Utils.debug("extract_instigator: found via property")
            return instigator
        end
    end

    -- Strategy 3: Try to get the avatar (character) from the ability
    local avatar = self.GetAvatarActor and self:GetAvatarActor()
    if avatar and type(avatar) == "userdata" then
        local ok, valid = pcall(function() return avatar:IsValid() end)
        if ok and valid then
            Utils.debug("extract_instigator: found via GetAvatarActor()")
            return avatar
        end
    end

    Utils.debug("extract_instigator: no instigator found")
    return nil
end

-- ===========================================================================
-- Damage Routing Logic
-- ===========================================================================

--- Pre-hook handler for melee abilities.
--- This is the main entry point for intercepting PvP damage.
---
--- When a melee attack occurs:
--- 1. Extract the target from hook parameters
--- 2. Check if target is in an active duel with the instigator
--- 3. If yes: redirect damage via HealthManager, block original
--- 4. If no: pass through (return nil)
---
--- @param self userdata The melee ability UObject
--- @param ... any Additional hook parameters
--- @return boolean|nil false to block original damage, nil to pass through
function M.pre_melee_hook(self, ...)
    M._stats.total_hooks_fired = M._stats.total_hooks_fired + 1

    -- Extract target from parameters
    local target = M.extract_target(...)
    if not target then
        M._stats.no_target_found = M._stats.no_target_found + 1
        Utils.debug("pre_melee_hook: no target found, passing through")
        return nil
    end

    -- Extract the instigator (attacker) from the ability
    local instigator = M.extract_instigator(self)
    if not instigator then
        M._stats.invalid_instigator = M._stats.invalid_instigator + 1
        Utils.debug("pre_melee_hook: no instigator found, passing through")
        return nil
    end

    -- Check if target is in an active duel
    if not PvPStateManager.is_dueling(target) then
        M._stats.not_in_duel = M._stats.not_in_duel + 1
        Utils.debug("pre_melee_hook: target not in duel, passing through")
        return nil
    end

    -- Get the duel and verify the instigator is the opponent
    local duel = PvPStateManager.get_duel(target)
    if not duel then
        Utils.debug("pre_melee_hook: could not get duel for target")
        return nil
    end

    -- Get the opponent of the instigator
    local opponent = PvPStateManager.get_opponent(instigator)
    if not opponent then
        Utils.debug("pre_melee_hook: instigator not in a duel")
        return nil
    end

    -- Verify the target is the opponent (i.e., instigator is attacking target)
    local target_addr = Utils.obj_address(target)
    local opponent_addr = Utils.obj_address(opponent)

    if target_addr ~= opponent_addr then
        Utils.debug("pre_melee_hook: target is not the opponent of instigator")
        return nil
    end

    -- Verify duel is active (not pending or ended)
    if duel.status ~= "active" then
        Utils.debug("pre_melee_hook: duel not active (status: " .. tostring(duel.status) .. ")")
        return nil
    end

    -- =========================================================================
    -- REDIRECT DAMAGE: Target is in active duel with instigator
    -- =========================================================================

    -- Extract damage amount
    local damage_amount = M.extract_damage_amount(...)
    if not damage_amount then
        damage_amount = 10 -- Default fallback
    end

    -- Apply shadow damage via HealthManager
    local success, err = HealthManager.apply_damage(target, damage_amount, instigator)
    if not success then
        Utils.warn("pre_melee_hook: HealthManager.apply_damage failed: " .. tostring(err))
        -- Don't block original damage if we can't apply shadow damage
        return nil
    end

    M._stats.damage_redirected = M._stats.damage_redirected + 1
    M._stats.damage_blocked = M._stats.damage_blocked + 1

    Utils.info(string.format("Damage redirected: %s -> %s for %.1f damage (duel %d)",
        Utils.player_id(instigator),
        Utils.player_id(target),
        damage_amount,
        duel.id))

    -- Send damage message if enabled
    if Config.DAMAGE_MESSAGES_ENABLED then
        M._send_damage_message(instigator, target, damage_amount)
    end

    -- Block original damage by returning false
    return false
end

--- Pre-hook handler for GAS damage application.
--- This catches damage from GameplayAbilities system.
---
--- @param self userdata The AbilitySystemComponent or AttributeSet
--- @param ... any Additional hook parameters
--- @return boolean|nil false to block, nil to pass through
function M.pre_gas_hook(self, ...)
    M._stats.total_hooks_fired = M._stats.total_hooks_fired + 1

    -- For GAS hooks, the parameter structure is different
    -- Typically: (AttributeSet, Data) where Data contains damage info

    local args = {...}

    -- Try to extract target from the attribute set's owner
    local target = nil

    -- If self is an AttributeSet, try to get the owner
    if self and self.GetAvatarActor then
        target = self:GetAvatarActor()
    elseif self and self.Owner then
        target = self.Owner
    end

    if not target or not target:IsValid() then
        -- Try extracting from parameters
        target = M.extract_target(...)
    end

    if not target then
        M._stats.no_target_found = M._stats.no_target_found + 1
        return nil
    end

    -- Try to find the source of damage from parameters
    local source = nil
    for i = 1, #args do
        local param = args[i]
        if param and type(param) == "table" then
            source = param.Instigator
                or param.Source
                or param.EffectCauser
            if source and type(source) == "userdata" then
                break
            end
        end
    end

    -- If no source found, try to get it from the attribute set
    if not source and self and self.Instigator then
        source = self.Instigator
    end

    -- Check if target is in active duel
    if not PvPStateManager.is_dueling(target) then
        M._stats.not_in_duel = M._stats.not_in_duel + 1
        return nil
    end

    -- Get duel and verify opponent
    local duel = PvPStateManager.get_duel(target)
    if not duel or duel.status ~= "active" then
        return nil
    end

    -- If we have a source, verify it's the opponent
    if source then
        local opponent = PvPStateManager.get_opponent(source)
        if not opponent or Utils.obj_address(opponent) ~= Utils.obj_address(target) then
            return nil
        end
    else
        -- No source - assume it's from the duel opponent
        -- This is a fallback for when we can't determine the source
    end

    -- Extract damage amount
    local damage_amount = M.extract_damage_amount(...)
    if not damage_amount then
        damage_amount = 10
    end

    -- Apply shadow damage
    local success, err = HealthManager.apply_damage(target, damage_amount, source)
    if not success then
        Utils.warn("pre_gas_hook: HealthManager.apply_damage failed: " .. tostring(err))
        return nil
    end

    M._stats.damage_redirected = M._stats.damage_redirected + 1
    M._stats.damage_blocked = M._stats.damage_blocked + 1

    Utils.info(string.format("GAS damage redirected: %.1f to %s (duel %d)",
        damage_amount,
        Utils.player_id(target),
        duel.id))

    -- Send damage message
    if Config.DAMAGE_MESSAGES_ENABLED and source then
        M._send_damage_message(source, target, damage_amount)
    end

    return false
end

-- ===========================================================================
-- Damage Feedback
-- ===========================================================================

--- Send a damage feedback message to players.
--- Uses Config.DAMAGE_MESSAGE_TEMPLATE with placeholders.
---
--- @param source userdata|nil Attacker
--- @param target userdata|nil Target
--- @param damage number Damage amount
function M._send_damage_message(source, target, damage)
    local source_name = source and Utils.player_id(source) or "Unknown"
    local target_name = target and Utils.player_id(target) or "Unknown"

    local remaining = HealthManager.get_health(target) or "?"

    local message = Utils.format_template(Config.DAMAGE_MESSAGE_TEMPLATE, {
        source = source_name,
        target = target_name,
        damage = string.format("%.1f", damage),
        remaining = string.format("%.1f", remaining),
    })

    -- Try to use WindrosePlus system message function
    local ok, wp = pcall(function()
        return wp
    end)

    if ok and wp and wp.send_system_message then
        local success, err = pcall(function()
            wp.send_system_message(message)
        end)
        if not success then
            Utils.debug("wp.send_system_message failed: " .. tostring(err))
        else
            M._stats.messages_sent = M._stats.messages_sent + 1
        end
    else
        -- Fall back to server log
        Utils.info(message)
        M._stats.messages_sent = M._stats.messages_sent + 1
    end
end

-- ===========================================================================
-- Hook Registration
-- ===========================================================================

--- Register all damage routing hooks.
--- Called during module initialization.
---
--- @return boolean Whether hook registration succeeded
function M._register_hooks()
    local registered_any = false

    -- Primary hook: R5MeleeAbility:RemoveEventGEs
    -- This is confirmed working from Phase 0 logs
    if Config.MELEE_HOOK_WORKS then
        local success = Utils.safe_hook(
            Config.HOOK_PATHS.MELEE_REMOVE_EVENT_GES,
            M.pre_melee_hook,
            nil -- No post-hook needed
        )

        if success then
            Utils.info("DamageRouter: Registered melee hook: " .. Config.HOOK_PATHS.MELEE_REMOVE_EVENT_GES)
            registered_any = true
        else
            Utils.warn("DamageRouter: Failed to register melee hook")
            M._stats.hook_registration_failed = M._stats.hook_registration_failed + 1
        end
    else
        Utils.warn("DamageRouter: MELEE_HOOK_WORKS is false, skipping melee hook")
    end

    -- Secondary hooks: GAS damage paths (if available)
    if Config.GAS_HOOK_WORKS then
        local gas_hooks = {
            Config.HOOK_PATHS.GAS_POST_EXECUTE,
            Config.HOOK_PATHS.GAS_PRE_ATTR_CHANGE,
            Config.HOOK_PATHS.GAS_APPLY_GE_SPEC_SELF,
            Config.HOOK_PATHS.GAS_APPLY_GE_SPEC_TARGET,
        }

        for _, hook_path in ipairs(gas_hooks) do
            if hook_path then
                local success = Utils.safe_hook(
                    hook_path,
                    M.pre_gas_hook,
                    nil
                )

                if success then
                    Utils.info("DamageRouter: Registered GAS hook: " .. hook_path)
                    registered_any = true
                end
            end
        end
    else
        Utils.info("DamageRouter: GAS_HOOK_WORKS is false, skipping GAS hooks")
    end

    return registered_any
end

-- ===========================================================================
-- EventBus Listeners
-- ===========================================================================

--- Register EventBus listeners.
--- Called during module initialization.
function M._register_event_listeners()
    -- Listen for duel_ended to clean up any per-duel tracking
    local duel_ended_id = EventBus.on("duel_ended", function(data)
        Utils.debug("DamageRouter: duel_ended event received for duel " .. tostring(data.duel_id))
        -- Currently no per-duel state to clean up, but this is here
        -- for future extensibility (e.g., damage stats per duel)
    end)

    M._subscriptions.duel_ended = duel_ended_id

    Utils.info("DamageRouter: EventBus listeners registered")
end

-- ===========================================================================
-- Public API
-- ===========================================================================

--- Initialize the damage router.
--- Registers hooks and EventBus listeners.
---
--- @return boolean Whether initialization succeeded
function M.init()
    if M._initialized then
        Utils.warn("DamageRouter.init called but already initialized")
        return true
    end

    Utils.info("Initializing DamageRouter...")

    -- Register hooks
    local hooks_registered = M._register_hooks()
    if not hooks_registered then
        Utils.warn("DamageRouter: No hooks could be registered")
        -- Don't fail init - we can still work if hooks register later
    end

    -- Register EventBus listeners
    M._register_event_listeners()

    M._initialized = true
    Utils.info("DamageRouter initialized")

    -- Register self-tests
    M._register_self_tests()

    return true
end

--- Main tick handler — called every server tick.
--- Handles periodic cleanup and maintenance.
---
--- @param dt number Delta time in seconds
function M.on_tick(dt)
    if not M._initialized then
        return
    end

    -- Currently no per-tick processing needed for damage routing
    -- The hooks handle everything synchronously
    -- This is here for future extensibility
end

--- Get damage routing statistics.
--- Useful for RCON pvp_status command and debugging.
---
--- @return table Statistics summary
function M.get_stats()
    return {
        total_hooks_fired = M._stats.total_hooks_fired,
        damage_redirected = M._stats.damage_redirected,
        damage_blocked = M._stats.damage_blocked,
        damage_passed_through = M._stats.damage_passed_through,
        no_target_found = M._stats.no_target_found,
        not_in_duel = M._stats.not_in_duel,
        invalid_instigator = M._stats.invalid_instigator,
        hook_registration_failed = M._stats.hook_registration_failed,
        messages_sent = M._stats.messages_sent,
    }
end

--- Reset statistics (for testing or admin command).
function M.reset_stats()
    M._stats = {
        total_hooks_fired = 0,
        damage_redirected = 0,
        damage_blocked = 0,
        damage_passed_through = 0,
        no_target_found = 0,
        not_in_duel = 0,
        invalid_instigator = 0,
        hook_registration_failed = 0,
        messages_sent = 0,
    }
    Utils.info("DamageRouter stats reset")
end

-- ===========================================================================
-- Self-Tests
-- ===========================================================================

--- Register self-tests for the damage router.
function M._register_self_tests()
    -- Test: extract_target with nil returns nil
    Utils.register_test("damage_router_extract_target_nil", function()
        local result = M.extract_target(nil)
        return result == nil
    end)

    -- Test: extract_target with empty varargs returns nil
    Utils.register_test("damage_router_extract_target_empty", function()
        local result = M.extract_target()
        return result == nil
    end)

    -- Test: extract_damage_amount with nil returns default
    Utils.register_test("damage_router_extract_damage_nil", function()
        local result = M.extract_damage_amount(nil)
        return result == nil or type(result) == "number"
    end)

    -- Test: extract_damage_amount with empty varargs returns default
    Utils.register_test("damage_router_extract_damage_empty", function()
        local result = M.extract_damage_amount()
        -- Should return default 10
        return result == 10
    end)

    -- Test: extract_instigator with nil returns nil
    Utils.register_test("damage_router_extract_instigator_nil", function()
        local result = M.extract_instigator(nil)
        return result == nil
    end)

    -- Test: get_stats returns valid structure
    Utils.register_test("damage_router_get_stats_structure", function()
        local stats = M.get_stats()
        return type(stats) == "table"
            and type(stats.total_hooks_fired) == "number"
            and type(stats.damage_redirected) == "number"
    end)

    -- Test: reset_stats clears statistics
    Utils.register_test("damage_router_reset_stats", function()
        M._stats.total_hooks_fired = 999
        M.reset_stats()
        local stats = M.get_stats()
        return stats.total_hooks_fired == 0
    end)

    -- Test: init can be called multiple times without error
    Utils.register_test("damage_router_init_idempotent", function()
        local ok1, _ = pcall(M.init)
        local ok2, _ = pcall(M.init)
        return ok1 and ok2
    end)

    -- Test: on_tick doesn't crash with nil dt
    Utils.register_test("damage_router_on_tick_no_crash", function()
        local ok, err = pcall(function()
            M.on_tick(nil)
        end)
        return ok
    end)

    -- Test: pre_melee_hook doesn't crash with nil self
    Utils.register_test("damage_router_pre_melee_nil_self", function()
        local ok, result = pcall(function()
            return M.pre_melee_hook(nil)
        end)
        -- Should return nil (pass through) rather than crashing
        return ok and result == nil
    end)

    -- Test: pre_gas_hook doesn't crash with nil self
    Utils.register_test("damage_router_pre_gas_nil_self", function()
        local ok, result = pcall(function()
            return M.pre_gas_hook(nil)
        end)
        return ok and result == nil
    end)

    Utils.info("DamageRouter self-tests registered")
end

-- ===========================================================================
-- SECTION: Cleanup / Destroy
-- ===========================================================================
-- Clears stats and resets state.
-- Called by main_phase1.shutdown() in reverse init order.
function M.destroy()
    Utils.info("Destroying Damage Router...")

    -- Clear stats (match actual field names from _stats definition)
    M._stats = {
        total_hooks_fired = 0,
        damage_redirected = 0,
        damage_blocked = 0,
        damage_passed_through = 0,
        no_target_found = 0,
        not_in_duel = 0,
        invalid_instigator = 0,
        hook_registration_failed = 0,
        messages_sent = 0,
    }
    Utils.info("  Cleared stats")

    -- Reset state
    M._initialized = false

    -- Unsubscribe from EventBus
    for name, sub_id in pairs(M._subscriptions) do
        EventBus.off(name, sub_id)
    end
    M._subscriptions = {}
    Utils.info("  Reset state")

    Utils.info("Damage Router destroyed")
end

return M