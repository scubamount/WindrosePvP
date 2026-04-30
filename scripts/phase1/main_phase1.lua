---=====================================================================
-- WindrosePvP Phase 1 Orchestrator
-- 
-- Purpose: Main entry point that initializes all Phase 1 modules in the
--          correct dependency order and provides the OnTick callback.
--
-- Dependencies: All Phase 1 modules must be loaded via require() before
--              this orchestrator runs.
--
-- Module Dependency Graph (L = Layer):
--   L1: Config, Utils, EventBus (foundational - loaded via require)
--   L2: PvPStateManager (no Phase1 dependencies)
--   L3: HealthManager (depends on PvPStateManager)
--   L3: DuelRequest (depends on PvPStateManager + HealthManager)
--   L3: AreaRestriction (depends on PvPStateManager)
--   L4: DamageRouter (depends on all above)
--
-- Note: This runs on UE 5.6.1 dedicated server via UE4SS Lua mod.
---=====================================================================

--=====================================================================
-- SECTION: Module Dependencies
--=====================================================================
-- These are loaded at script load time (before init is called).
-- Order matters here only for require() resolution, not initialization.

local Config = require("scripts.config")
local Utils = require("scripts.utils")
local EventBus = require("scripts.event_bus")

-- Phase 1 modules (L2-L4)
local PvPStateManager = require("scripts.phase1.pvp_state_manager")
local HealthManager = require("scripts.phase1.health_manager")
local DuelRequest = require("scripts.phase1.duel_request")
local AreaRestriction = require("scripts.phase1.area_restriction")
local DamageRouter = require("scripts.phase1.damage_router")

--=====================================================================
-- SECTION: Module Definition
--=====================================================================

local M = {}

--=====================================================================
-- SECTION: Initialization
--=====================================================================
-- Initializes all Phase 1 modules in dependency order.
--
-- CRITICAL: The order below must be maintained to ensure all modules
--           are initialized after their dependencies.
--
-- Initialization Order:
--   1. Config - Already loaded via require() above
--   2. Utils + EventBus - Already loaded via require() above
--   3. PvPStateManager - L2, no Phase1 module dependencies
--   4. HealthManager - L3, depends on PvPStateManager
--   5. DuelRequest - L3, depends on PvPStateManager + HealthManager
--   6. AreaRestriction - L3, depends on PvPStateManager
--   7. DamageRouter - L4, depends on all above
--
-- Each module's init() function should:
--   - Register any required event handlers with EventBus
--   - Initialize internal state
--   - Set up any necessary game hooks
--   - Log initialization status
---
function M.init()
    Utils.info("Initializing WindrosePvP Phase 1 modules...")
    
    -- Layer 2: PvPStateManager (foundational for other modules)
    -- Handles player PvP state tracking (InCombat, InDuel, etc.)
    PvPStateManager.init()
    
    -- Layer 3: HealthManager
    -- Manages health property syncing, depends on PvPStateManager
    -- for determining which players to track
    HealthManager.init()
    
    -- Layer 3: DuelRequest
    -- Handles duel request system, depends on both PvPStateManager
    -- (for state checks) and HealthManager (for duel health setup)
    DuelRequest.init()
    
    -- Layer 3: AreaRestriction
    -- Enforces arena boundaries, depends on PvPStateManager
    -- for tracking who is in the arena
    AreaRestriction.init()
    
    -- Layer 4: DamageRouter
    -- Routes damage based on PvP state, depends on all above
    -- (must be last to ensure all state is properly tracked)
    DamageRouter.init()
    
    Utils.info("=== WindrosePvP Phase 1 initialized ===")
end

--=====================================================================
-- SECTION: OnTick Handler
--=====================================================================
-- Called every game tick (typically 30-60 times per second).
-- Ticks all modules that require per-frame updates.
--
-- Modules are ticked in dependency order (same as init):
--   1. PvPStateManager - Updates player state timers, cleans up stale states
--   2. HealthManager - Processes health sync queue, handles regen
--   3. AreaRestriction - Checks player positions, enforces boundaries
--   4. DamageRouter - Processes damage queue, applies PvP modifiers
--
-- Note: DuelRequest has no on_tick - it's event-driven only.
--
-- @param dt (number) Delta time in seconds since last tick
---
function M.on_tick(dt)
    -- Layer 2: Update PvP state tracking
    PvPStateManager.on_tick(dt)
    
    -- Layer 3: Update health management
    HealthManager.on_tick(dt)
    
    -- Layer 3: Update area restriction enforcement
    AreaRestriction.on_tick(dt)
    
    -- Layer 4: Process damage routing (depends on all above)
    DamageRouter.on_tick(dt)
    
    -- DuelRequest has no per-tick logic (event-driven)
end

--=====================================================================
-- SECTION: Status Reporting
--=====================================================================
-- Returns current status of all Phase 1 modules.
-- Used for RCON "pvp_status" command and debugging.
--
-- @return (table) Status table containing:
--   - phase: Current phase identifier ("Phase 1")
--   - state_manager: PvPStateManager status
--   - health: HealthManager status
--   - area: AreaRestriction arena info
--   - damage_router: DamageRouter statistics
--   - config: Key configuration values
---
function M.get_status()
    return {
        phase = "Phase 1",
        
        -- PvP state tracking status
        state_manager = PvPStateManager.get_status(),
        
        -- Health management status
        health = HealthManager.get_status(),
        
        -- Arena boundary info
        area = AreaRestriction.get_arena_info(),
        
        -- Damage routing statistics
        damage_router = DamageRouter.get_stats(),
        
        -- Key config values for reference
        config = {
            health_property = Config.HEALTH_PROPERTY_NAME,
            arena_center = Config.ARENA_CENTER,
            arena_radius = Config.ARENA_RADIUS,
        }
    }
end

--=====================================================================
-- SECTION: Shutdown & Cleanup
--=====================================================================
-- Cleanup all Phase 1 modules in reverse dependency order (L4→L2).
-- Called by init.lua on mod shutdown/reload.
function M.shutdown()
    Utils.info("=== WindrosePvP Phase 1 shutting down ===")

    -- Layer 4: DamageRouter (depends on all below)
    if DamageRouter and DamageRouter.destroy then
        DamageRouter.destroy()
        Utils.info("  DamageRouter destroyed")
    end

    -- Layer 3: AreaRestriction
    if AreaRestriction and AreaRestriction.destroy then
        AreaRestriction.destroy()
        Utils.info("  AreaRestriction destroyed")
    end

    -- Layer 3: DuelRequest
    if DuelRequest and DuelRequest.destroy then
        DuelRequest.destroy()
        Utils.info("  DuelRequest destroyed")
    end

    -- Layer 3: HealthManager
    if HealthManager and HealthManager.destroy then
        HealthManager.destroy()
        Utils.info("  HealthManager destroyed")
    end

    -- Layer 2: PvPStateManager
    if PvPStateManager and PvPStateManager.destroy then
        PvPStateManager.destroy()
        Utils.info("  PvPStateManager destroyed")
    end

    -- Clear EventBus listeners
    EventBus.clear_all()
    Utils.info("  EventBus cleared")

    Utils.info("=== WindrosePvP Phase 1 shutdown complete ===")
end

--=====================================================================
-- SECTION: Module Exports
--=====================================================================

M.shutdown = M.shutdown

return M