--- WindrosePvP Duel Request System
--- RCON command handler for all PvP duel operations.
---
--- RCON commands (all require player name as first argument):
--- - pvp_challenge <your_name> <target_name> - Challenge a player to a duel
--- - pvp_accept <your_name> - Accept a pending challenge
--- - pvp_decline <your_name> - Decline a pending challenge
--- - pvp_surrender <your_name> - Surrender from current duel
--- - pvp_status - Show current PvP status
--- - pvp_health [player_name] - Show health of player(s)
--- - pvp_duels - List all active duels
--- - pvp_cancel <duel_id> - Admin: cancel a specific duel
--- - pvp_test - Run all self-tests
--- - pvp_config [key] [value] - View or modify config
---
--- @require Config - Module configuration
--- @require Utils - Safe property access and logging
--- @require EventBus - Internal pub/sub for events
--- @require PvPStateManager - PvP duel state management
--- @require HealthManager - Player health tracking (optional)

local Config = require("scripts.config")
local Utils = require("scripts.utils")
local EventBus = require("scripts.event_bus")
local PvPStateManager = require("scripts.phase1.pvp_state_manager")

-- HealthManager may not be loaded yet - handle gracefully
local HealthManager = nil
local function get_health_manager()
    if not HealthManager then
        pcall(function()
            HealthManager = require("scripts.phase1.health_manager")
        end)
    end
    return HealthManager
end

local M = {}

-- ===========================================================================
-- Private State
-- ===========================================================================

--- Whether commands are registered
M._commands_registered = false

--- Whether windroseplus API is available
M._wp_available = false

--- EventBus subscription IDs for cleanup
M._subscriptions = {}

-- Lookup tables for player name → UObject resolution
M._player_name_cache = {}

-- ===========================================================================
-- Player Name Resolution
-- ===========================================================================

--- Clear player name cache (call periodically)
function M._clear_cache()
    M._player_name_cache = {}
end

--- Update cache with current online players
function M._update_cache()
    local all_players = Utils.find_all_of(Config.CLASS_NAMES.PLAYER_CHARACTER)
    if not all_players then return end

    for _, player in pairs(all_players) do
        if player and player:IsValid() then
            local name = Utils.player_id(player)
            if name and name ~= "<nil>" and name ~= "<unknown>" then
                M._player_name_cache[name:lower()] = player
            end
        end
    end
end

--- Find a player UObject by their in-game name.
--- Case-insensitive lookup from cache.
--- @param name string Player name to find
--- @return userdata|nil Player UObject, or nil if not found
function M.find_player_by_name(name)
    if not name or #name == 0 then return nil end

    -- Update cache before lookup
    M._update_cache()

    -- Case-insensitive lookup
    local player = M._player_name_cache[name:lower()]
    if player and player:IsValid() then
        return player
    end

    -- Fallback: scan all players directly
    local all_players = Utils.find_all_of(Config.CLASS_NAMES.PLAYER_CHARACTER)
    if not all_players then return nil end

    for _, player in pairs(all_players) do
        if player and player:IsValid() then
            local player_name = Utils.player_id(player)
            if player_name and player_name:lower() == name:lower() then
                return player
            end
        end
    end

    return nil
end

--- Get all online player names.
--- @return table List of player name strings
function M.get_online_players()
    local names = {}
    local all_players = Utils.find_all_of(Config.CLASS_NAMES.PLAYER_CHARACTER)

    if not all_players then return names end

    for _, player in pairs(all_players) do
        if player and player:IsValid() then
            local name = Utils.player_id(player)
            if name and name ~= "<nil>" and name ~= "<unknown>" then
                names[#names + 1] = name
            end
        end
    end

    return names
end

-- ===========================================================================
-- System Messaging
-- ===========================================================================

--- Send a system message to a player via WindrosePlus API.
--- Falls back to log if API not available.
--- @param player userdata|nil Target player (nil = broadcast)
--- @param message string Message to send
function M.send_system_message(player, message)
    if not message then return end

    -- Try WindrosePlus API first
    if M._wp_available and wp and wp.send_system_message then
        local ok, err = pcall(function()
            if player then
                wp.send_system_message(player, message)
            else
                wp.broadcast_system_message(message)
            end
        end)
        if ok then return end
    end

    -- Fallback: log only
    if player then
        local name = Utils.player_id(player)
        Utils.info("[To " .. name .. "] " .. message)
    else
        Utils.info("[Broadcast] " .. message)
    end
end

--- Format a template message with placeholders.
--- @param template string Template with {placeholders}
--- @param data table Key-value pairs
--- @return string Formatted message
function M.format_message(template, data)
    return Utils.format_template(template, data)
end

-- ===========================================================================
-- RCON Command Implementation
-- ===========================================================================

--- pvp_challenge <your_name> <target_name>
--- Challenge a player to a duel.
function M.cmd_challenge(args)
    if #args < 2 then
        return "Usage: pvp_challenge <your_name> <target_name>\n" ..
               "Example: pvp_challenge PlayerA PlayerB"
    end

    local your_name = args[1]
    local target_name = args[2]

    if your_name == target_name then
        return "Error: You cannot challenge yourself"
    end

    -- Find the challenger (your_name)
    local challenger = M.find_player_by_name(your_name)
    if not challenger then
        return "Error: Player '" .. your_name .. "' not found online"
    end

    -- Find the target
    local target = M.find_player_by_name(target_name)
    if not target then
        return "Error: Target player '" .. target_name .. "' not found online"
    end

    -- Ensure both players are valid
    if not challenger:IsValid() then
        return "Error: Your player object is no longer valid"
    end

    if not target:IsValid() then
        return "Error: Target player object is no longer valid"
    end

    -- Validate using PvPStateManager
    local challenge_id, err = PvPStateManager.create_challenge(challenger, target)
    if not challenge_id then
        return "Error: " .. tostring(err)
    end

    -- Send challenge notification to target
    local msg = M.format_message(Config.CHALLENGE_MESSAGE_TEMPLATE, {
        challenger = your_name,
        target = target_name,
    })
    M.send_system_message(challenge.target, msg)

    Utils.info("Challenge created: " .. your_name .. " → " .. target_name .. " (ID: " .. challenge_id .. ")")

    return "Challenge sent to " .. target_name .. " (Challenge ID: " .. challenge_id .. ")\n" ..
           target_name .. " must use pvp_accept to accept"
end

--- pvp_accept <your_name>
--- Accept a pending challenge.
function M.cmd_accept(args)
    if #args < 1 then
        return "Usage: pvp_accept <your_name>\n" ..
               "Example: pvp_accept PlayerB"
    end

    local your_name = args[1]

    -- Find the player
    local player = M.find_player_by_name(your_name)
    if not player then
        return "Error: Player '" .. your_name .. "' not found online"
    end

    -- Get the pending challenge for this player
    local challenge = PvPStateManager.get_challenge_for_player(player)
    if not challenge then
        return "Error: No pending challenge for " .. your_name
    end

    -- Verify the player is the target (not challenger)
    if challenge.target_name:lower() ~= your_name:lower() then
        return "Error: You are the challenger, not the target. Target must accept."
    end

    -- Accept the challenge
    local ok, err = PvPStateManager.accept_challenge(challenge.id)
    if not ok then
        return "Error: " .. tostring(err)
    end

    -- Find the duel that was created
    local duel = PvPStateManager.get_duel(player)
    if not duel then
        return "Challenge accepted, but duel not found"
    end

    -- Notify both players
    local msg = "PvP Duel started! " .. challenge.challenger_name .. " vs " .. challenge.target_name 
    M.send_system_message(challenge.challenger, msg)
    M.send_system_message(challenge.target, msg)

    return "Duel accepted! You are now dueling " .. challenge.challenger_name .. " (Duel ID: " .. duel.id .. ")\n" ..
           "Fight to the death!"
end

--- pvp_decline <your_name>
--- Decline a pending challenge.
function M.cmd_decline(args)
    if #args < 1 then
        return "Usage: pvp_decline <your_name>\n" ..
               "Example: pvp_decline PlayerB"
    end

    local your_name = args[1]

    -- Find the player
    local player = M.find_player_by_name(your_name)
    if not player then
        return "Error: Player '" .. your_name .. "' not found online"
    end

    -- Get the pending challenge
    local challenge = PvPStateManager.get_challenge_for_player(player)
    if not challenge then
        return "Error: No pending challenge to decline"
    end

    -- Verify the player is the target
    if challenge.target_name:lower() ~= your_name:lower() then
        return "Error: Only the challenged player can decline"
    end

    -- Decline the challenge
    local ok, err = PvPStateManager.decline_challenge(challenge.id)
    if not ok then
        return "Error: " .. tostring(err)
    end

    -- Notify challenger
    local msg = "Your challenge to " .. challenge.target_name .. " was declined"
    local challenger = M.find_player_by_name(challenge.challenger_name)
    if challenger then
        M.send_system_message(challenge.challenger, msg)
    end

    return "Challenge declined"
end

--- pvp_surrender <your_name>
--- Surrender from current duel.
function M.cmd_surrender(args)
    if #args < 1 then
        return "Usage: pvp_surrender <your_name>\n" ..
               "Example: pvp_surrender PlayerA"
    end

    local your_name = args[1]

    -- Find the player
    local player = M.find_player_by_name(your_name)
    if not player then
        return "Error: Player '" .. your_name .. "' not found online"
    end

    -- Get the current duel
    local duel = PvPStateManager.get_duel(player)
    if not duel then
        return "Error: You are not in a duel"
    end

    -- Determine opponent
    local opponent = PvPStateManager.get_opponent(player)
    if not opponent then
        return "Error: Could not find opponent"
    end

    local opponent_name = Utils.player_id(opponent)

    -- Verify the player is in this duel
    local player_name_lc = your_name:lower()
    if duel.player_a_name:lower() ~= player_name_lc and duel.player_b_name:lower() ~= player_name_lc then
        return "Error: You are not in this duel"
    end

    -- End duel with surrender
    local ok = PvPStateManager.end_duel(duel.id, opponent, player, "surrender")
    if not ok then
        return "Error: Failed to end duel"
    end

    -- Notify both players
    local msg = "You surrendered! " .. opponent_name .. " wins!"
    M.send_system_message(player, msg)

    local msg2 = your_name .. " surrendered! You win!"
    M.send_system_message(opponent, msg2)

    return "You surrendered. " .. opponent_name .. " wins the duel!"
end

--- pvp_status
--- Show current PvP status.
function M.cmd_status(args)
    local status = PvPStateManager.get_status()

    local lines = {}
    lines[#lines + 1] = "=== WindrosePvP Status ==="
    lines[#lines + 1] = "Active Duels: " .. status.active_duels .. " / " .. status.max_duels
    lines[#lines + 1] = "Pending Challenges: " .. status.pending_challenges
    lines[#lines + 1] = "Total Duels Ever: " .. status.total_duels_ever

    -- List active duels
    if #status.duels > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Active Duels:"
        for _, duel in ipairs(status.duels) do
            local elapsed = os.time() - duel.started_at
            lines[#lines + 1] = string.format("  [%d] %s vs %s (%s, %ds elapsed)",
                duel.id, duel.player_a, duel.player_b, duel.status, elapsed)
        end
    else
        lines[#lines + 1] = ""
        lines[#lines + 1] = "No active duels"
    end

    -- List pending challenges
    if #status.challenges > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Pending Challenges:"
        for _, ch in ipairs(status.challenges) do
            local expires_in = math.max(0, ch.expires_in)
            lines[#lines + 1] = string.format("  [%d] %s → %s (expires in %ds)",
                ch.id, ch.challenger, ch.target, expires_in)
        end
    else
        lines[#lines + 1] = ""
        lines[#lines + 1] = "No pending challenges"
    end

    return table.concat(lines, "\n")
end

--- pvp_health [player_name]
--- Show health of player(s).
function M.cmd_health(args)
    local hm = get_health_manager()

    if #args < 1 then
        -- Show all dueling players' health
        local duels = PvPStateManager.get_active_duels()
        if #duels == 0 then
            return "No active duels. Specify a player name to check health."
        end

        local lines = {}
        lines[#lines + 1] = "=== Duelling Players Health ==="

        for _, duel in ipairs(duels) do
            for _, player_ref in ipairs({"player_a", "player_b"}) do
                local player = duel[player_ref]
                if player and player:IsValid() then
                    local name = Utils.player_id(player)
                    local health = nil

                    if hm and hm.get_health then
                        health = hm.get_health(player)
                    end

                    if health then
                        local max_health = hm and hm.get_max_health and hm.get_max_health(player) or 100
                        lines[#lines + 1] = name .. ": " .. health .. " / " .. max_health
                    else
                        lines[#lines + 1] = name .. ": <health unreadable>"
                    end
                end
            end
        end

        return table.concat(lines, "\n")
    end

    -- Show specific player
    local player_name = args[1]
    local player = M.find_player_by_name(player_name)

    if not player then
        return "Error: Player '" .. player_name .. "' not found online"
    end

    if hm and hm.get_health then
        local health = hm.get_health(player)
        local max_health = hm.get_max_health and hm.get_max_health(player) or nil

        if health then
            if max_health then
                return player_name .. ": " .. health .. " / " .. max_health .. " HP"
            else
                return player_name .. ": " .. health .. " HP"
            end
        else
            return player_name .. ": <health unreadable>"
        end
    else
        return "Error: HealthManager not available"
    end
end

--- pvp_duels
--- List all active duels.
function M.cmd_duels(args)
    local status = PvPStateManager.get_status()

    if #status.duels == 0 then
        return "No active duels"
    end

    local lines = {}
    lines[#lines + 1] = "=== Active Duels ==="

    for _, duel in ipairs(status.duels) do
        local elapsed = os.time() - duel.started_at
        local minutes = math.floor(elapsed / 60)
        local seconds = elapsed % 60

        lines[#lines + 1] = string.format("[%d] %s vs %s", duel.id, duel.player_a, duel.player_b)
        lines[#lines + 1] = "  Status: " .. duel.status
        lines[#lines + 1] = string.format("  Duration: %dm %ds", minutes, seconds)
        lines[#lines + 1] = ""
    end

    return table.concat(lines, "\n")
end

--- pvp_cancel <duel_id>
--- Admin: cancel a specific duel.
function M.cmd_cancel(args)
    if #args < 1 then
        return "Usage: pvp_cancel <duel_id>\n" ..
               "Use pvp_duels to find duel IDs"
    end

    local duel_id = tonumber(args[1])
    if not duel_id then
        return "Error: Invalid duel ID '" .. args[1] .. "'"
    end

    local duel = PvPStateManager.get_duel_by_id(duel_id)
    if not duel then
        return "Error: Duel " .. duel_id .. " not found"
    end

    if duel.status == "ended" then
        return "Error: Duel " .. duel_id .. " already ended"
    end

    -- Cancel the duel
    local ok = PvPStateManager.cancel_duel(duel_id, "admin_cancel")
    if not ok then
        return "Error: Failed to cancel duel"
    end

    return "Duel " .. duel_id .. " cancelled by admin"
end

--- pvp_test
--- Run all self-tests.
function M.cmd_test(args)
    local lines = {}
    lines[#lines + 1] = "=== WindrosePvP Self-Tests ==="

    -- Run Utils tests
    local utils_passed, utils_failed = Utils.run_tests()
    lines[#lines + 1] = string.format("Utils: %d passed, %d failed", utils_passed, utils_failed)

    -- Run EventBus tests
    local eb_passed, eb_failed = EventBus.run_self_tests()
    lines[#lines + 1] = string.format("EventBus: %d passed, %d failed", eb_passed, eb_failed)

    -- Run PvPStateManager tests (if available)
    if PvPStateManager and PvPStateManager.run_self_tests then
        -- PvPStateManager registers its own tests on load
        local pvp_passed, pvp_failed = 0, 0
        lines[#lines + 1] = "PvPStateManager: Built-in tests run on module load"
    end

    -- Run HealthManager tests if available
    local hm = get_health_manager()
    if hm and hm.run_self_tests then
        local hm_passed, hm_failed = hm.run_self_tests()
        lines[#lines + 1] = string.format("HealthManager: %d passed, %d failed", hm_passed, hm_failed)
    end

    -- Run our own tests
    local own_passed, own_failed = M.run_self_tests()
    lines[#lines + 1] = string.format("DuelRequest: %d passed, %d failed", own_passed, own_failed)

    return table.concat(lines, "\n")
end

--- pvp_config [key] [value]
--- View or modify config values.
function M.cmd_config(args)
    if #args < 1 then
        -- Return all config values
        local lines = {}
        lines[#lines + 1] = "=== WindrosePvP Configuration ==="

        -- Core config values
        local keys = {
            "MOD_NAME", "MOD_VERSION",
            "DUEL_CHALLENGE_TIMEOUT", "DUEL_MAX_DURATION",
            "MAX_CONCURRENT_DUELS", "MIN_HEALTH_TO_DUEL",
            "AUTO_REVIVE_LOSER", "AUTO_REVIVE_DELAY",
            "ARENA_CENTER", "ARENA_RADIUS",
            "DAMAGE_MESSAGES_ENABLED",
        }

        for _, key in ipairs(keys) do
            local value = Config[key]
            if type(value) == "table" then
                value = string.format("{X=%s, Y=%s, Z=%s}",
                    tostring(value.X or 0), tostring(value.Y or 0), tostring(value.Z or 0))
            end
            lines[#lines + 1] = key .. " = " .. tostring(value)
        end

        return table.concat(lines, "\n")
    end

    local key = args[1]

    if #args < 2 then
        -- Return specific config value
        local value = Config[key]
        if value == nil then
            return "Error: Unknown config key '" .. key .. "'"
        end

        if type(value) == "table" then
            return key .. " = " .. tostring(value.X or 0) .. ", " ..
                   tostring(value.Y or 0) .. ", " .. tostring(value.Z or 0)
        end

        return key .. " = " .. tostring(value)
    end

    -- Set config value
    local value_str = args[2]
    local current = Config[key]

    if current == nil then
        return "Error: Unknown config key '" .. key .. "'"
    end

    -- Type-coerce the value
    local new_value
    local current_type = type(current)

    if current_type == "number" then
        new_value = tonumber(value_str)
        if not new_value then
            return "Error: '" .. value_str .. "' is not a valid number"
        end
    elseif current_type == "boolean" then
        new_value = (value_str == "true" or value_str == "1")
    elseif current_type == "string" then
        new_value = value_str
    else
        return "Error: Cannot modify config key '" .. key .. "' (type: " .. current_type .. ")"
    end

    Config.apply_overrides({[key] = new_value})

    return key .. " = " .. tostring(new_value) .. " (updated)"
end

-- ===========================================================================
-- Command Registration
-- ===========================================================================

--- Register all RCON commands with WindrosePlus Admin API.
function M.register_commands()
    if M._commands_registered then
        Utils.warn("Commands already registered")
        return
    end

    Utils.info("Registering RCON commands...")

    -- Try WindrosePlus Admin API first
    if Admin and Admin._commands then
        Utils.info("Using WindrosePlus Admin API")

        Admin._commands["pvp_challenge"] = function(args)
            return M.cmd_challenge(args)
        end

        Admin._commands["pvp_accept"] = function(args)
            return M.cmd_accept(args)
        end

        Admin._commands["pvp_decline"] = function(args)
            return M.cmd_decline(args)
        end

        Admin._commands["pvp_surrender"] = function(args)
            return M.cmd_surrender(args)
        end

        Admin._commands["pvp_status"] = function(args)
            return M.cmd_status(args)
        end

        Admin._commands["pvp_health"] = function(args)
            return M.cmd_health(args)
        end

        Admin._commands["pvp_duels"] = function(args)
            return M.cmd_duels(args)
        end

        Admin._commands["pvp_cancel"] = function(args)
            return M.cmd_cancel(args)
        end

        Admin._commands["pvp_test"] = function(args)
            return M.cmd_test(args)
        end

        Admin._commands["pvp_config"] = function(args)
            return M.cmd_config(args)
        end

        M._wp_available = true
        M._commands_registered = true
        Utils.info("RCON commands registered via Admin API")
        return
    end

    -- Fallback: try UE4SS console commands
    -- Note: This may crash on Windrose due to HookProcessConsoleExec issues
    Utils.warn("WindrosePlus Admin API not available, trying RegisterConsoleCommandHandler")

    local function try_register(name, fn)
        local ok, err = pcall(function()
            RegisterConsoleCommandHandler(name, function(exec, cmd, args)
                local result = fn(args)
                return true  -- consumed
            end)
        end)

        if ok then
            Utils.info("Registered console command: " .. name)
            return true
        else
            Utils.warn("Failed to register console command '" .. name .. "': " .. tostring(err))
            return false
        end
    end

    local any_registered = false
    any_registered = try_register("pvp_challenge", M.cmd_challenge) or any_registered
    any_registered = try_register("pvp_accept", M.cmd_accept) or any_registered
    any_registered = try_register("pvp_decline", M.cmd_decline) or any_registered
    any_registered = try_register("pvp_surrender", M.cmd_surrender) or any_registered
    any_registered = try_register("pvp_status", M.cmd_status) or any_registered
    any_registered = try_register("pvp_health", M.cmd_health) or any_registered
    any_registered = try_register("pvp_duels", M.cmd_duels) or any_registered
    any_registered = try_register("pvp_cancel", M.cmd_cancel) or any_registered
    any_registered = try_register("pvp_test", M.cmd_test) or any_registered
    any_registered = try_register("pvp_config", M.cmd_config) or any_registered

    if any_registered then
        M._commands_registered = true
        Utils.info("RCON commands registered via console fallback")
    else
        Utils.error("All RCON command registration methods failed")
        Utils.error("RCON commands will NOT be available")
        Utils.error("Use WindrosePlus HTTP API directly for PvP commands")
    end
end

-- ===========================================================================
-- Event Bus Integration
-- ===========================================================================

local function setup_event_handlers()
    -- Listen for challenge created
    local id1 = EventBus.on("challenge_created", function(data)
        Utils.info("Event: challenge_created " .. data.challenger_name .. " → " .. data.target_name)
    end)
    if id1 then M._subscriptions[#M._subscriptions+1] = {name = "challenge_created", id = id1} end

    -- Listen for challenge resolved
    local id2 = EventBus.on("challenge_resolved", function(data)
        Utils.info("Event: challenge_resolved " .. data.challenge_id .. " = " .. data.status)
    end)
    if id2 then M._subscriptions[#M._subscriptions+1] = {name = "challenge_resolved", id = id2} end

    -- Listen for duel created
    local id3 = EventBus.on("duel_created", function(data)
        Utils.info("Event: duel_created " .. data.duel_id .. " = " .. data.player_a_name .. " vs " .. data.player_b_name)
    end)
    if id3 then M._subscriptions[#M._subscriptions+1] = {name = "duel_created", id = id3} end

    -- Listen for duel ended
    local id4 = EventBus.on("duel_ended", function(data)
        local result = data.winner_name .. " wins!"
        if data.reason == "surrender" then
            result = data.loser_name .. " surrendered"
        elseif data.reason == "timeout" then
            result = "Duel timed out"
        elseif data.reason == "disconnect" then
            result = "Player disconnected"
        end
        Utils.info("Event: duel_ended " .. data.duel_id .. " = " .. result)
    end)
    if id4 then M._subscriptions[#M._subscriptions+1] = {name = "duel_ended", id = id4} end

    Utils.info("Event handlers registered (" .. #M._subscriptions .. " subscriptions)")
end

-- ===========================================================================
-- Cleanup: Unsubscribe all EventBus listeners
-- ===========================================================================
function M.destroy()
    Utils.info("Destroying DuelRequest module...")
    for _, sub in ipairs(M._subscriptions) do
        EventBus.off(sub.name, sub.id)
        Utils.info("  Unsubscribed: " .. sub.name)
    end
    M._subscriptions = {}
    M._commands_registered = false
    M._wp_available = false
    M._player_name_cache = {}
    Utils.info("DuelRequest destroyed")
end

-- ===========================================================================
-- Self-Tests
-- ===========================================================================

function M.run_self_tests()
    local passed = 0
    local failed = 0

    -- Test: find_player_by_name returns nil for empty string
    local function test_find_player_nil()
        return M.find_player_by_name("") == nil
    end

    -- Test: get_online_players returns table
    local function test_get_online_players()
        local players = M.get_online_players()
        return type(players) == "table"
    end

    -- Test: cmd_status returns string
    local function test_cmd_status()
        local result = M.cmd_status({})
        return type(result) == "string" and #result > 0
    end

    -- Test: cmd_duels returns string
    local function test_cmd_duels()
        local result = M.cmd_duels({})
        return type(result) == "string"
    end

    -- Test: cmd_test returns string
    local function test_cmd_test()
        local result = M.cmd_test({})
        return type(result) == "string"
    end

    -- Test: cmd_config with no args returns string
    local function test_cmd_config()
        local result = M.cmd_config({})
        return type(result) == "string" and #result > 0
    end

    -- Test: cmd_config with invalid key returns error
    local function test_cmd_config_invalid()
        local result = M.cmd_config({"INVALID_KEY"})
        return result:match("Error")
    end

    -- Test: cmd_challenge with no args returns usage
    local function test_cmd_challenge_usage()
        local result = M.cmd_challenge({})
        return result:match("Usage")
    end

    -- Test: cmd_accept with no args returns usage
    local function test_cmd_accept_usage()
        local result = M.cmd_accept({})
        return result:match("Usage")
    end

    -- Test: internal state initialized
    local function test_internal_state()
        return M._commands_registered ~= nil
            and M._wp_available ~= nil
            and type(M._player_name_cache) == "table"
    end

    local tests = {
        {"find_player_nil", test_find_player_nil},
        {"get_online_players", test_get_online_players},
        {"cmd_status", test_cmd_status},
        {"cmd_duels", test_cmd_duels},
        {"cmd_test", test_cmd_test},
        {"cmd_config", test_cmd_config},
        {"cmd_config_invalid", test_cmd_config_invalid},
        {"cmd_challenge_usage", test_cmd_challenge_usage},
        {"cmd_accept_usage", test_cmd_accept_usage},
        {"internal_state", test_internal_state},
    }

    for _, t in ipairs(tests) do
        local name, fn = t[1], t[2]
        local ok, result = pcall(fn)
        if ok and result then
            passed = passed + 1
            Utils.debug("[PASS] " .. name)
        else
            failed = failed + 1
            local err = ok and "returned false" or tostring(result)
            Utils.error("[FAIL] " .. name .. ": " .. err)
        end
    end

    return passed, failed
end

-- ===========================================================================
-- Module Initialization
-- ===========================================================================

function M.init()
    Utils.info("Initializing Duel Request System...")

    -- Setup event handlers
    setup_event_handlers()

    -- Register commands
    M.register_commands()

    Utils.info("Duel Request System initialized")
end

-- NOTE: Do NOT auto-init on load. main_phase1.lua handles initialization.
-- If this module is loaded independently for testing, call M.init() manually:
-- local DuelRequest = require("scripts.phase1.duel_request")
-- DuelRequest.init()

return M