-- WindrosePvP Mod Entry Point
-- Loaded by WindrosePvP mod loader (UE4SS Lua mod for Windrose - UE 5.6.1 dedicated server)
-- This is the main entry point that WindrosePlus calls to initialize the mod

local Config = require("scripts.config")
local Utils = require("scripts.utils")
local EventBus = require("scripts.event_bus")

-- Phase 0 discovery scripts - run when HEALTH_PROPERTY_NAME is not yet known
local Phase0Scripts = {
  "scripts.phase0.p0_sdk_dump",
  "scripts.phase0.p0_property_discovery",
  "scripts.phase0.p0_health_write_test",
  "scripts.phase0.p0_melee_hook_test",
  "scripts.phase0.p0_gas_hook_test",
  "scripts.phase0.p0_replication_test",
  "scripts.phase0.p0_boarding_lifecycle",
}

-- File-level reference to main_phase1 (set in init(), visible to register_ontick_callback)
local MainPhase1 = nil

-- Track initialization state
local g_initialized = false
local g_initialization_phase = nil

-- Register OnTick callback for Phase 1 modules
-- Wires a UE4SS hook to call MainPhase1.on_tick(dt) on game ticks
-- Defined BEFORE init() so it is available when init() calls it.
local function register_ontick_callback()
  Utils.info("Wiring OnTick callback for Phase 1...")

  -- Approach 1: Hook PlayerController:Tick (fires every frame for each player)
  local hook_ok = pcall(function()
    RegisterHook("/Script/Engine.PlayerController:Tick", function(self, dt)
      if MainPhase1 and MainPhase1.on_tick then
        pcall(MainPhase1.on_tick, dt or 0.033) -- default ~30fps delta
      end
    end)
  end)

  if hook_ok then
    Utils.info("Registered: PlayerController:Tick hook for OnTick")
  else
    -- Approach 2: Hook ProcessEvent and filter for tick-like calls
    local ok2 = pcall(function()
      RegisterHook("ProcessEvent", function(Object, Function, Params)
        if Function and type(Function) == "string" then
          local fn_lower = Function:lower()
          if fn_lower:find("tick") or fn_lower:find("update") then
            if MainPhase1 and MainPhase1.on_tick then
              pcall(MainPhase1.on_tick, 0.033) -- approximate delta
            end
          end
        end
      end)
    end)

    if ok2 then
      Utils.info("Registered: ProcessEvent hook (tick filtering)")
    else
      Utils.warn("OnTick wiring failed: all approaches failed")
      Utils.info("Phase 1 modules will need to register their own tick methods")
    end
  end
end

-- Main initialization function - called by mod loader
local function init()
  -- Prevent double initialization
  if g_initialized then
    Utils.warn("WindrosePvP: Already initialized, skipping")
    return
  end

  Utils.info("=== WindrosePvP Mod v" .. Config.MOD_VERSION .. " initializing ===")
  Utils.info("Game: Windrose (UE 5.6.1 Dedicated Server)")
  Utils.info("Mod Loader: UE4SS")

  -- Determine which phase to run based on Config
  if not Config.HEALTH_PROPERTY_NAME then
    -- Phase 0: Discovery phase - need to find health property first
    g_initialization_phase = "Phase0"
    Utils.info("Phase 0: Running discovery scripts...")
    Utils.info("Reason: HEALTH_PROPERTY_NAME not set in Config")

    local loaded_count = 0
    local failed_count = 0

    for _, script_name in ipairs(Phase0Scripts) do
      local ok, result = pcall(require, script_name)
      if ok then
        Utils.info("Loaded: " .. script_name)
        loaded_count = loaded_count + 1

        -- Call init on the module if it exists
        if result and result.init then
          local init_ok, init_err = pcall(result.init)
          if not init_ok then
            Utils.warn("Init failed for " .. script_name .. ": " .. tostring(init_err))
          end
        end
      else
        Utils.warn("Failed to load " .. script_name .. ": " .. tostring(result))
        failed_count = failed_count + 1
      end
    end

    Utils.info("Phase 0 loaded: " .. loaded_count .. " successful, " .. failed_count .. " failed")

  else
    -- Phase 1: Core PvP modules - health property is known
    g_initialization_phase = "Phase 1"
    Utils.info("Phase 1: Loading core PvP modules...")
    Utils.info("Health property known: " .. Config.HEALTH_PROPERTY_NAME)

    -- Load main Phase 1 module (assigns to file-level MainPhase1)
    local ok = pcall(function()
      MainPhase1 = require("scripts.phase1.main_phase1")
    end)

    if ok then
      Utils.info("Loaded: scripts.phase1.main_phase1")
      if MainPhase1.init then
        MainPhase1.init()
        Utils.info("MainPhase1.init() completed")
      else
        Utils.warn("MainPhase1.init() not found")
      end
    else
      Utils.error("Failed to load main_phase1: " .. tostring(MainPhase1))
      return
    end

    -- Register OnTick callback for Phase 1 modules
    register_ontick_callback()

    Utils.info("WindrosePvP Phase 1 initialized successfully")
  end

  -- Run self-tests for utilities and event bus
  Utils.info("Running self-tests...")
  Utils.run_tests()
  EventBus.run_self_tests()
  Utils.info("Self-tests completed")

  -- Mark as initialized
  g_initialized = true

  Utils.info("=== WindrosePvP Mod v" .. Config.MOD_VERSION .. " initialization complete (" .. g_initialization_phase .. ") ===")
end

-- Cleanup function for mod reload/unload
local function shutdown()
  Utils.info("WindrosePvP: Shutting down...")

  if g_initialization_phase == "Phase 1" then
    -- Clean up Phase 1 modules (use file-level MainPhase1)
    if MainPhase1 and MainPhase1.shutdown then
      MainPhase1.shutdown()
      Utils.info(" MainPhase1 shutdown complete")
    else
      Utils.warn("MainPhase1 not available for shutdown")
    end
  end

  -- Reset state variables (INSIDE shutdown(), not at module load time)
  g_initialized = false
  g_initialization_phase = nil

  Utils.info("WindrosePvP: Shutdown complete")
end

-- Get initialization state
local function get_initialization_phase()
  return g_initialization_phase
end

-- Check if mod is initialized
local function is_initialized()
  return g_initialized
end

-- Export module functions
local M = {
  init = init,
  shutdown = shutdown,
  get_initialization_phase = get_initialization_phase,
  is_initialized = is_initialized,
}

-- Auto-initialize when this script is loaded
init()

return M
