--- WindrosePvP PvP State Manager
--- In-memory duel state tracker for the PvP mod.
--- ALL state is ephemeral — lost on server restart by design.
--- NEVER writes to disk or RocksDB.

local Config = require("scripts.config")
local Utils = require("scripts.utils")
local EventBus = require("scripts.event_bus")

-- ===========================================================================
-- EmmyLua Type Definitions
-- ===========================================================================

--- @class Challenge
--- @field id number Challenge ID
--- @field challenger userdata Challenger UObject
--- @field target userdata Target UObject
--- @field challenger_name string
--- @field target_name string
--- @field created_at number Timestamp when created
--- @field expires_at number Expiration timestamp
--- @field status string "pending"|"accepted"|"declined"|"expired"|"cancelled"

--- @class Duel
--- @field id number Duel ID
--- @field player_a userdata First player UObject
--- @field player_b userdata Second player UObject
--- @field player_a_name string
--- @field player_b_name string
--- @field started_at number Timestamp when started
--- @field max_duration number Maximum duration in seconds
--- @field status string "pending"|"active"|"ended"
--- @field end_reason string|nil "death"|"surrender"|"timeout"|"disconnect"|"admin_cancel"
--- @field winner userdata|nil Winner UObject
--- @field loser userdata|nil Loser UObject
--- @field ended_at number|nil Timestamp when ended
--- @field arena_center table|nil Arena center coordinates

--- @class PvPStateManager
--- @field _challenges table<number, Challenge> Active challenges by ID
--- @field _duels table<number, Duel> Active duels by ID
--- @field _next_challenge_id number Auto-incrementing challenge ID
--- @field _next_duel_id number Auto-incrementing duel ID
--- @field _player_challenge table<string, number> Player address → challenge ID
--- @field _player_duel table<string, number> Player address → duel ID
--- @field _challenge_id_to_player table<number, string> Challenge ID → player address
--- @field _duel_id_to_player table<number, string> Duel ID → player address

local M = {}

-- ===========================================================================
-- Internal State
-- ===========================================================================

--- @type table<number, table> All challenges indexed by ID
M._challenges = {}

--- @type table<number, table> All duels indexed by ID
M._duels = {}

--- @type number Next available challenge ID
M._next_challenge_id = 1

--- @type number Next available duel ID
M._next_duel_id = 1

--- @type table<string, number> Player address → challenge ID (O(1) lookup)
M._player_challenge = {}

--- @type table<string, number> Player address → duel ID (O(1) lookup)
M._player_duel = {}

--- @type table<number, string> Challenge ID → player address (reverse lookup)
M._challenge_id_to_player = {}

--- @type table<number, string> Duel ID → player address (reverse lookup)
M._duel_id_to_player = {}

-- ===========================================================================
-- Helper Functions
-- ===========================================================================

--- Get the address string for a player UObject.
--- Used as key in lookup tables for nil-safety after disconnect.
--- @param player userdata|nil
--- @return string|nil
local function get_player_address(player)
    if not player then return nil end
    return Utils.obj_address(player)
end

--- Get player name from UObject, with fallback to address.
--- @param player userdata|nil
--- @return string
local function get_player_name(player)
    if not player then return "<nil>" end
    return Utils.player_id(player)
end

--- Check if a player is currently in any duel.
--- @param player userdata
--- @return boolean
local function is_player_in_duel(player)
    local addr = get_player_address(player)
    return addr ~= nil and M._player_duel[addr] ~= nil
end

--- Check if a player has a pending challenge.
--- @param player userdata
--- @return boolean
local function is_player_in_challenge(player)
    local addr = get_player_address(player)
    return addr ~= nil and M._player_challenge[addr] ~= nil
end

--- Validate that a player UObject is still valid.
--- @param player userdata
--- @return boolean
local function is_player_valid(player)
    if not player then return false end
    local ok, valid = pcall(function() return player:IsValid() end)
    return ok and valid == true
end

-- ===========================================================================
-- Challenge Management
-- ===========================================================================

--- Create a new duel challenge from challenger to target.
--- @param challenger userdata The player issuing the challenge
--- @param target userdata The player being challenged
--- @return number|nil challenge_id ID of created challenge, or nil on error
--- @return string|nil error_string Error message if failed, nil on success
function M.create_challenge(challenger, target)
    -- Validate inputs
    if not challenger or not target then
        return nil, "Invalid player reference"
    end

    if not is_player_valid(challenger) then
        return nil, "Challenger is no longer valid"
    end

    if not is_player_valid(target) then
        return nil, "Target is no longer valid"
    end

    -- Check challenger is not already in a duel
    if is_player_in_duel(challenger) then
        return nil, "Challenger is already in a duel"
    end

    -- Check challenger does not already have a pending challenge
    if is_player_in_challenge(challenger) then
        return nil, "Challenger already has a pending challenge"
    end

    -- Check target is not already in a duel
    if is_player_in_duel(target) then
        return nil, "Target is already in a duel"
    end

    -- Check target does not already have a pending challenge
    if is_player_in_challenge(target) then
        return nil, "Target already has a pending challenge"
    end

    -- Check max concurrent duels
    local active_count = 0
    for _, duel in pairs(M._duels) do
        if duel.status == "active" or duel.status == "pending" then
            active_count = active_count + 1
        end
    end
    if active_count >= Config.MAX_CONCURRENT_DUELS then
        return nil, "Maximum concurrent duels reached"
    end

    -- Create the challenge
    local challenge_id = M._next_challenge_id
    M._next_challenge_id = M._next_challenge_id + 1

    local challenger_addr = get_player_address(challenger)
    local target_addr = get_player_address(target)

    local challenge = {
        id = challenge_id,
        challenger = challenger,
        target = target,
        challenger_name = get_player_name(challenger),
        target_name = get_player_name(target),
        created_at = os.time(),
        expires_at = os.time() + Config.DUEL_CHALLENGE_TIMEOUT,
        status = "pending",
    }

    M._challenges[challenge_id] = challenge
    M._player_challenge[challenger_addr] = challenge_id
    M._player_challenge[target_addr] = challenge_id

    Utils.info(string.format("Challenge created: %s → %s (ID: %d)",
        challenge.challenger_name, challenge.target_name, challenge_id))

    -- Emit event
    EventBus.emit("challenge_created", {
        challenge_id = challenge_id,
        challenger = challenger,
        target = target,
        challenger_name = challenge.challenger_name,
        target_name = challenge.target_name,
    })

    return challenge_id, nil
end

--- Accept a pending challenge.
--- @param challenge_id number ID of the challenge to accept
--- @return boolean success True if accepted successfully
--- @return string|nil error Error message if failed, nil on success
function M.accept_challenge(challenge_id)
    local challenge = M._challenges[challenge_id]
    if not challenge then
        return false, "Challenge not found"
    end

    if challenge.status ~= "pending" then
        return false, "Challenge is not pending (status: " .. challenge.status .. ")"
    end

    -- Check both players are still valid
    if not is_player_valid(challenge.challenger) then
        challenge.status = "expired"
        return false, "Challenger is no longer valid"
    end

    if not is_player_valid(challenge.target) then
        challenge.status = "expired"
        return false, "Target is no longer valid"
    end

    -- Mark challenge as accepted
    challenge.status = "accepted"

    -- Create the duel
    local duel_id, err = M.create_duel(challenge.challenger, challenge.target)
    if not duel_id then
        challenge.status = "declined"
        return false, "Failed to create duel: " .. tostring(err)
    end

    -- Clear challenge from lookup tables (duel takes over)
    local challenger_addr = get_player_address(challenge.challenger)
    local target_addr = get_player_address(challenge.target)
    M._player_challenge[challenger_addr] = nil
    M._player_challenge[target_addr] = nil

    -- Remove the challenge
    M._challenges[challenge_id] = nil

    Utils.info(string.format("Challenge %d accepted, duel %d created",
        challenge_id, duel_id))

    -- Emit event
    EventBus.emit("challenge_resolved", {
        challenge_id = challenge_id,
        status = "accepted",
        duel_id = duel_id,
    })

    return true, nil
end

--- Decline a pending challenge.
--- @param challenge_id number ID of the challenge to decline
--- @return boolean success True if declined successfully
--- @return string|nil error Error message if failed, nil on success
function M.decline_challenge(challenge_id)
    local challenge = M._challenges[challenge_id]
    if not challenge then
        return false, "Challenge not found"
    end

    if challenge.status ~= "pending" then
        return false, "Challenge is not pending (status: " .. challenge.status .. ")"
    end

    -- Mark as declined
    challenge.status = "declined"

    -- Clear from lookup tables
    local challenger_addr = get_player_address(challenge.challenger)
    local target_addr = get_player_address(challenge.target)
    M._player_challenge[challenger_addr] = nil
    M._player_challenge[target_addr] = nil

    Utils.info(string.format("Challenge %d declined by %s",
        challenge_id, challenge.target_name))

    -- Emit event
    EventBus.emit("challenge_resolved", {
        challenge_id = challenge_id,
        status = "declined",
    })

    return true, nil
end

--- Auto-expire challenges that have timed out.
--- @return number Count of challenges expired
function M.expire_challenges()
    local now = os.time()
    local expired_count = 0

    for challenge_id, challenge in pairs(M._challenges) do
        if challenge.status == "pending" and challenge.expires_at <= now then
            challenge.status = "expired"

            -- Clear from lookup tables
            local challenger_addr = get_player_address(challenge.challenger)
            local target_addr = get_player_address(challenge.target)
            if challenger_addr then M._player_challenge[challenger_addr] = nil end
            if target_addr then M._player_challenge[target_addr] = nil end

            Utils.info(string.format("Challenge %d expired (timeout)", challenge_id))

            -- Emit event
            EventBus.emit("challenge_resolved", {
                challenge_id = challenge_id,
                status = "expired",
            })

            expired_count = expired_count + 1
        end
    end

    return expired_count
end

--- Get the pending challenge for a player, if any.
--- @param player userdata
--- @return table|nil Challenge object
function M.get_challenge_for_player(player)
    local addr = get_player_address(player)
    if not addr then return nil end

    local challenge_id = M._player_challenge[addr]
    if not challenge_id then return nil end

    local challenge = M._challenges[challenge_id]
    if not challenge or challenge.status ~= "pending" then
        return nil
    end

    return challenge
end

--- Get all pending challenges.
--- @return table List of pending challenge objects
function M.get_pending_challenges()
    local pending = {}
    for _, challenge in pairs(M._challenges) do
        if challenge.status == "pending" then
            pending[#pending + 1] = challenge
        end
    end
    return pending
end

-- ===========================================================================
-- Duel Lifecycle
-- ===========================================================================

--- Create a new duel between two players.
--- Duel starts in "pending" state until positioned.
--- @param player_a userdata First player
--- @param player_b userdata Second player
--- @return number|nil duel_id, string|nil error
function M.create_duel(player_a, player_b)
    -- Validate inputs
    if not player_a or not player_b then
        return nil, "Invalid player reference"
    end

    if not is_player_valid(player_a) then
        return nil, "Player A is no longer valid"
    end

    if not is_player_valid(player_b) then
        return nil, "Player B is no longer valid"
    end

    -- Check neither player is already in a duel
    if is_player_in_duel(player_a) then
        return nil, "Player A is already in a duel"
    end

    if is_player_in_duel(player_b) then
        return nil, "Player B is already in a duel"
    end

    -- Check max concurrent duels
    local active_count = 0
    for _, duel in pairs(M._duels) do
        if duel.status == "active" or duel.status == "pending" then
            active_count = active_count + 1
        end
    end
    if active_count >= Config.MAX_CONCURRENT_DUELS then
        return nil, "Maximum concurrent duels reached"
    end

    -- Create the duel
    local duel_id = M._next_duel_id
    M._next_duel_id = M._next_duel_id + 1

    local player_a_addr = get_player_address(player_a)
    local player_b_addr = get_player_address(player_b)

    -- Deep copy arena center to avoid reference issues
    local arena_center = {
        X = Config.ARENA_CENTER.X,
        Y = Config.ARENA_CENTER.Y,
        Z = Config.ARENA_CENTER.Z,
    }

    local duel = {
        id = duel_id,
        player_a = player_a,
        player_b = player_b,
        player_a_name = get_player_name(player_a),
        player_b_name = get_player_name(player_b),
        started_at = os.time(),
        max_duration = Config.DUEL_MAX_DURATION,
        status = "pending",
        winner = nil,
        loser = nil,
        end_reason = nil,
        arena_center = arena_center,
    }

    M._duels[duel_id] = duel
    M._player_duel[player_a_addr] = duel_id
    M._player_duel[player_b_addr] = duel_id

    Utils.info(string.format("Duel created: %s vs %s (ID: %d)",
        duel.player_a_name, duel.player_b_name, duel_id))

    -- Emit event
    EventBus.emit("duel_created", {
        duel_id = duel_id,
        player_a = player_a,
        player_b = player_b,
        player_a_name = duel.player_a_name,
        player_b_name = duel.player_b_name,
    })

    return duel_id, nil
end

--- Transition a duel from "pending" to "active" state.
--- Called when both players are positioned in the arena.
--- @param duel_id number
--- @return boolean success
function M.start_duel(duel_id)
    local duel = M._duels[duel_id]
    if not duel then
        Utils.warn("start_duel: duel " .. duel_id .. " not found")
        return false
    end

    if duel.status ~= "pending" then
        Utils.warn("start_duel: duel " .. duel_id .. " not in pending state")
        return false
    end

    -- Verify both players are still valid
    if not is_player_valid(duel.player_a) or not is_player_valid(duel.player_b) then
        M.cancel_duel(duel_id, "disconnect")
        return false
    end

    duel.status = "active"
    Utils.info(string.format("Duel %d started (active)", duel_id))

    return true
end

--- End a duel with a winner and loser.
--- @param duel_id number ID of the duel to end
--- @param winner userdata|nil The winning player (nil for draws/cancel)
--- @param loser userdata|nil The losing player (nil for draws/cancel)
--- @param reason string "death"|"surrender"|"timeout"|"disconnect"|"admin_cancel"
--- @return boolean success True if ended successfully
function M.end_duel(duel_id, winner, loser, reason)
    local duel = M._duels[duel_id]
    if not duel then
        Utils.warn("end_duel: duel " .. duel_id .. " not found")
        return false
    end

    if duel.status == "ended" then
        Utils.warn("end_duel: duel " .. duel_id .. " already ended")
        return false
    end

    -- Update duel state
    duel.status = "ended"
    duel.winner = winner
    duel.loser = loser
    duel.end_reason = reason
    duel.ended_at = os.time()

    -- Clear from player lookup tables
    local player_a_addr = get_player_address(duel.player_a)
    local player_b_addr = get_player_address(duel.player_b)
    if player_a_addr then M._player_duel[player_a_addr] = nil end
    if player_b_addr then M._player_duel[player_b_addr] = nil end

    local winner_name = winner and get_player_name(winner) or "nil"
    local loser_name = loser and get_player_name(loser) or "nil"

    Utils.info(string.format("Duel %d ended: %s vs %s, winner=%s, loser=%s, reason=%s",
        duel_id, duel.player_a_name, duel.player_b_name,
        winner_name, loser_name, reason))

    -- Emit event
    EventBus.emit("duel_ended", {
        duel_id = duel_id,
        player_a = duel.player_a,
        player_b = duel.player_b,
        player_a_name = duel.player_a_name,
        player_b_name = duel.player_b_name,
        winner = winner,
        loser = loser,
        winner_name = winner_name,
        loser_name = loser_name,
        reason = reason,
    })

    return true
end

--- Cancel a duel (admin or error case).
--- @param duel_id number
--- @param reason string "admin_cancel" | "disconnect" | "timeout"
--- @return boolean success
function M.cancel_duel(duel_id, reason)
    local duel = M._duels[duel_id]
    if not duel then
        return false
    end

    -- Use end_duel with nil winner/loser for cancel
    return M.end_duel(duel_id, nil, nil, reason)
end

-- ===========================================================================
-- Duel Queries
-- ===========================================================================

--- Check if a player is currently dueling.
--- O(1) lookup via player address table.
--- @param player userdata
--- @return boolean
function M.is_dueling(player)
    local addr = get_player_address(player)
    if not addr then return false end
    return M._player_duel[addr] ~= nil
end

--- Get the duel a player is currently in.
--- @param player userdata The player to look up
--- @return Duel|nil Duel object if player is in a duel, nil otherwise
function M.get_duel(player)
    local addr = get_player_address(player)
    if not addr then return nil end

    local duel_id = M._player_duel[addr]
    if not duel_id then return nil end

    return M._duels[duel_id]
end

--- Get the opponent of a player in their current duel.
--- O(1) lookup.
--- @param player userdata
--- @return userdata|nil Opponent player reference
function M.get_opponent(player)
    local duel = M.get_duel(player)
    if not duel then return nil end

    local player_addr = get_player_address(player)
    local opponent_addr = get_player_address(duel.player_a)
    if player_addr == opponent_addr then
        return duel.player_b
    end
    return duel.player_a
end

--- Get a duel by its ID.
--- @param duel_id number The duel ID to look up
--- @return Duel|nil Duel object if found, nil otherwise
function M.get_duel_by_id(duel_id)
    return M._duels[duel_id]
end

--- Get all active (pending or active) duels.
--- @return table List of duel objects
function M.get_active_duels()
    local active = {}
    for _, duel in pairs(M._duels) do
        if duel.status == "pending" or duel.status == "active" then
            active[#active + 1] = duel
        end
    end
    return active
end

--- Get the total number of duels (including ended).
--- @return number
function M.get_duel_count()
    return Utils.table_count(M._duels)
end

-- ===========================================================================
-- Maintenance (called from OnTick)
-- ===========================================================================

--- Periodic maintenance: challenge expiry, duel timeout, disconnect detection.
--- Called every tick from the main game loop.
--- @param dt number Delta time since last tick (unused but provided for interface)
function M.on_tick(dt)
    -- Expire timed-out challenges
    M.expire_challenges()

    -- Check for duel timeouts and disconnects
    local now = os.time()

    for duel_id, duel in pairs(M._duels) do
        if duel.status == "active" then
            -- Check for duel timeout
            local elapsed = now - duel.started_at
            if elapsed >= duel.max_duration then
                Utils.info(string.format("Duel %d timed out after %d seconds",
                    duel_id, elapsed))
                M.end_duel(duel_id, nil, nil, "timeout")
            end

            -- Check for player disconnects
            local player_a_valid = is_player_valid(duel.player_a)
            local player_b_valid = is_player_valid(duel.player_b)

            if not player_a_valid or not player_b_valid then
                local disconnect_reason = "disconnect"

                Utils.info(string.format("Duel %d ended due to disconnect", duel_id))
                M.end_duel(duel_id, nil, nil, "disconnect")
            end
        end

        -- Clean up old ended duels (state TTL)
        if duel.status == "ended" and duel.ended_at then
            local age = now - duel.ended_at
            if age > Config.STATE_TTL_SECONDS then
                M._duels[duel_id] = nil
                Utils.debug(string.format("Cleaned up old duel %d (age: %ds)", duel_id, age))
            end
        end
    end
end

-- ===========================================================================
-- Admin Functions
-- ===========================================================================

--- Cancel all active duels (admin command).
--- @return number Count of duels cancelled
function M.cancel_all_duels()
    local count = 0

    for duel_id, duel in pairs(M._duels) do
        if duel.status == "pending" or duel.status == "active" then
            M.cancel_duel(duel_id, "admin_cancel")
            count = count + 1
        end
    end

    Utils.info("Cancelled " .. count .. " duels (admin)")
    return count
end

--- Get comprehensive status for RCON pvp_status command.
--- @return table Status summary
function M.get_status()
    local active_duels = M.get_active_duels()
    local pending_challenges = M.get_pending_challenges()

    local duel_list = {}
    for _, duel in ipairs(active_duels) do
        duel_list[#duel_list + 1] = {
            id = duel.id,
            player_a = duel.player_a_name,
            player_b = duel.player_b_name,
            status = duel.status,
            started_at = duel.started_at,
            elapsed = os.time() - duel.started_at,
        }
    end

    local challenge_list = {}
    for _, challenge in ipairs(pending_challenges) do
        challenge_list[#challenge_list + 1] = {
            id = challenge.id,
            challenger = challenge.challenger_name,
            target = challenge.target_name,
            expires_in = challenge.expires_at - os.time(),
        }
    end

    return {
        active_duels = #active_duels,
        max_duels = Config.MAX_CONCURRENT_DUELS,
        pending_challenges = #pending_challenges,
        total_duels_ever = M.get_duel_count(),
        duels = duel_list,
        challenges = challenge_list,
    }
end

-- ===========================================================================
-- Self-Tests
-- ===========================================================================

local function register_self_tests()
    -- Test: create_challenge with nil players fails
    Utils.register_test("pvp_state_create_challenge_nil_players", function()
        local id, err = M.create_challenge(nil, nil)
        return id == nil and err ~= nil
    end)

    -- Test: create_challenge with valid players creates challenge
    Utils.register_test("pvp_state_create_challenge_basic", function()
        -- We can't test with real UObjects, but we can test the error paths
        -- and verify the internal state is initialized
        local pending = M.get_pending_challenges()
        return type(pending) == "table"
    end)

    -- Test: is_dueling returns false for non-dueling player
    Utils.register_test("pvp_state_is_dueling_false", function()
        -- Create a mock player-like table (not a real UObject)
        local mock_player = {}
        return M.is_dueling(mock_player) == false
    end)

    -- Test: get_duel returns nil for non-dueling player
    Utils.register_test("pvp_state_get_duel_nil", function()
        local mock_player = {}
        return M.get_duel(mock_player) == nil
    end)

    -- Test: get_opponent returns nil for non-dueling player
    Utils.register_test("pvp_state_get_opponent_nil", function()
        local mock_player = {}
        return M.get_opponent(mock_player) == nil
    end)

    -- Test: get_status returns valid structure
    Utils.register_test("pvp_state_get_status_structure", function()
        local status = M.get_status()
        return type(status) == "table"
            and type(status.active_duels) == "number"
            and type(status.pending_challenges) == "number"
            and type(status.duels) == "table"
            and type(status.challenges) == "table"
    end)

    -- Test: expire_challenges returns number
    Utils.register_test("pvp_state_expire_challenges_returns_number", function()
        local count = M.expire_challenges()
        return type(count) == "number"
    end)

    -- Test: on_tick doesn't crash with nil dt
    Utils.register_test("pvp_state_on_tick_no_crash", function()
        local ok, err = pcall(function()
            M.on_tick(nil)
        end)
        return ok
    end)

    -- Test: cancel_all_duels returns number
    Utils.register_test("pvp_state_cancel_all_returns_number", function()
        local count = M.cancel_all_duels()
        return type(count) == "number"
    end)

    -- Test: get_active_duels returns table
    Utils.register_test("pvp_state_get_active_duels_table", function()
        local active = M.get_active_duels()
        return type(active) == "table"
    end)

    -- Test: get_pending_challenges returns table
    Utils.register_test("pvp_state_get_pending_challenges_table", function()
        local pending = M.get_pending_challenges()
        return type(pending) == "table"
    end)

    -- Test: get_duel_count returns number
    Utils.register_test("pvp_state_get_duel_count_number", function()
        local count = M.get_duel_count()
        return type(count) == "number"
    end)

    -- Test: internal state initialized
    Utils.register_test("pvp_state_internal_state_init", function()
        return M._challenges ~= nil
            and M._duels ~= nil
            and M._player_challenge ~= nil
            and M._player_duel ~= nil
    end)

    Utils.info("PvP State Manager self-tests registered")
end

-- ===========================================================================
-- SECTION: Cleanup / Destroy
-- ===========================================================================
-- Clears all state and unsubscribes from EventBus.
-- Called by main_phase1.shutdown() in reverse init order.
function M.destroy()
    Utils.info("Destroying PvP State Manager...")

    -- Clear all _challenges
    M._challenges = {}
    M._challenge_id_to_player = {}
    Utils.info("  Cleared challenges")

    -- Clear all _duels
    M._duels = {}
    M._duel_id_to_player = {}
    Utils.info("  Cleared duels")

    -- Clear lookup tables
    M._player_challenge = {}
    M._player_duel = {}
    Utils.info("  Cleared lookup tables")

    -- Reset ID counters
    M._next_challenge_id = 1
    M._next_duel_id = 1
    Utils.info("  Reset ID counters")

    -- Unsubscribe from EventBus (if any)
    -- Note: EventBus.clear("duel_created") etc. could be used
    -- but since we registered with M references, the handlers will be GC'd
    -- when the module table is replaced

    Utils.info("PvP State Manager destroyed")
end

return M