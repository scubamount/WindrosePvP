--- WindrosePvP Configuration
--- All PvP mod settings, feature flags, and tunable constants.
--- This module is the single source of truth for all config values.

--- @class Config
--- @field MOD_NAME string Mod name
--- @field MOD_VERSION string Mod version
--- @field ARENA_CENTER {X: number, Y: number, Z: number} Arena center
--- @field ARENA_RADIUS number Arena radius
--- @field DUEL_MAX_DURATION number Max duel seconds
--- @field DUEL_CHALLENGE_TIMEOUT number Challenge expiry seconds
--- @field HEALTH_PROPERTY_PATH string|nil Health property path
--- @field MAX_HEALTH_PROPERTY_NAME string|nil Max health property name
--- @field HEALTH_IS_ATTRIBUTE_DATA boolean Whether health uses FGameplayAttributeData
--- @field MAX_CONCURRENT_DUELS number Max concurrent duels
--- @field MIN_HEALTH_TO_DUEL number Min health to start
--- @field MAX_DAMAGE_PER_HIT number Max damage per hit
--- @field HEALTH_REAPPLY_CHECK_DELAY number Ticks before re-apply check
--- @field HEALTH_REAPPLY_MAX_RETRIES number Max re-apply retries
--- @field AUTO_REVIVE_LOSER boolean Auto-revive toggle
--- @field AUTO_REVIVE_DELAY number Revive delay seconds
--- @field DAMAGE_MESSAGES_ENABLED boolean Damage messages toggle
--- @field MELEE_HOOK_WORKS boolean Melee hooks working
--- @field GAS_HOOK_WORKS boolean GAS hooks working
--- @field DEBUG_LOGGING boolean Debug logging toggle

local Config = {}

-- ===========================================================================
-- Mod Identity
-- ===========================================================================
Config.MOD_NAME = "WindrosePvP"
Config.MOD_VERSION = "0.1.0"
Config.MOD_AUTHOR = "WindrosePvP Community"
Config.MOD_DESCRIPTION = "Opt-in PvP duel system for Windrose dedicated servers"

-- ===========================================================================
-- Phase 0 Discovery Results (populated after Phase 0 scripts run)
-- These flags determine which Phase 1 features are active.
-- Set to nil/true/false by Phase 0 scripts; Phase 1 code checks them.
-- ===========================================================================

--- Name of the health property on AR5PlayerCharacter (discovered by p0_property_discovery)
--- Examples: "Health", "CurrentHealth", "HP", "Vitality", or a path like "AttributeSet.Health"
--- Set to nil until Phase 0 discovers it.
Config.HEALTH_PROPERTY_NAME = nil

--- Path to health property if nested (e.g., "AbilitySystemComponent.AttributeSet.Health")
--- If nil, HEALTH_PROPERTY_NAME is used as a direct property on the player character.
Config.HEALTH_PROPERTY_PATH = nil

--- Whether health is stored in FGameplayAttributeData (struct with BaseValue + CurrentValue)
--- If true, writes go to .CurrentValue sub-property.
Config.HEALTH_IS_ATTRIBUTE_DATA = false

--- Name of max health property (may differ from health property)
Config.MAX_HEALTH_PROPERTY_NAME = nil

--- Path to ship health property on AR5ShipPawnBase
Config.SHIP_HEALTH_PROPERTY_NAME = nil

--- GAS recalculation overwrites direct health modifications
--- Set by p0_health_write_test
Config.GAS_OVERWRITE_DETECTED = false

--- UR5MeleeAbility:RemoveEventGEs hook fires successfully
--- Set by p0_melee_hook_test
Config.MELEE_HOOK_WORKS = false

--- At least one GAS UFunction hook fires successfully
--- Set by p0_gas_hook_test
Config.GAS_HOOK_WORKS = false

--- Server-side property changes replicate to clients
--- Set by p0_replication_test
Config.REPLICATION_WORKS = false

--- Boarding battle lifecycle is mappable via hooks
--- Set by p0_boarding_lifecycle
Config.BOARDING_HOOK_WORKS = false

-- ===========================================================================
-- PvP Rules
-- ===========================================================================

--- Seconds before an unaccepted challenge expires
Config.DUEL_CHALLENGE_TIMEOUT = 60

--- Maximum duel duration in seconds (auto-end after this)
Config.DUEL_MAX_DURATION = 600

--- Maximum concurrent duels on one server
Config.MAX_CONCURRENT_DUELS = 4

--- Maximum shadow damage per single hit (safety cap)
Config.MAX_DAMAGE_PER_HIT = 100

--- Minimum health to start a duel (reject if player is below this)
Config.MIN_HEALTH_TO_DUEL = 50

--- Whether to auto-revive the loser after a duel ends
Config.AUTO_REVIVE_LOSER = true

--- Seconds to wait before auto-reviving (lets downed animation play)
Config.AUTO_REVIVE_DELAY = 3

-- ===========================================================================
-- Arena Configuration
-- ===========================================================================

--- Arena center coordinates (UE world space units)
--- Admin should modify this for their server's preferred arena location.
Config.ARENA_CENTER = { X = 0, Y = 0, Z = 0 }

--- Arena radius in UE units (1 UE unit ≈ 1cm, so 5000 = 50m)
Config.ARENA_RADIUS = 5000

--- Whether to enforce arena boundaries (teleport players back if they leave)
Config.ARENA_ENFORCE_BOUNDARY = true

--- Seconds between arena boundary checks (OnTick interval)
Config.ARENA_CHECK_INTERVAL = 1.0

--- Maximum distance a duelist can be from arena center before being teleported back
Config.ARENA_LEASH_DISTANCE = 5500

-- ===========================================================================
-- RCON / Command Configuration
-- ===========================================================================

--- Prefix for all RCON commands
Config.RCON_PREFIX = "pvp_"

--- Available RCON commands (for documentation and validation)
Config.RCON_COMMANDS = {
    "pvp_challenge",
    "pvp_accept",
    "pvp_decline",
    "pvp_surrender",
    "pvp_status",
    "pvp_health",
    "pvp_duels",
    "pvp_cancel",
    "pvp_test",
    "pvp_config",
}

-- ===========================================================================
-- Damage Feedback
-- ===========================================================================

--- Send a system message for each PvP hit
Config.DAMAGE_MESSAGES_ENABLED = true

--- Message template for damage hits
--- Available placeholders: {source}, {target}, {damage}, {remaining}
Config.DAMAGE_MESSAGE_TEMPLATE = "[PvP] {source} hit {target} for {damage} damage ({remaining} HP remaining)"

--- Message when a duel ends
Config.DUEL_END_MESSAGE_TEMPLATE = "[PvP] Duel ended: {winner} defeated {loser}!"

--- Message when a duel challenge is sent
Config.CHALLENGE_MESSAGE_TEMPLATE = "[PvP] {challenger} has challenged {target} to a duel! Type pvp_accept to accept."

-- ===========================================================================
-- Safety & Persistence
-- ===========================================================================

--- Storage mode: "memory" ONLY. NEVER change to "file" or "rocksdb".
--- PvP state is ephemeral — lost on server restart.
Config.STORAGE_MODE = "memory"

--- Auto-purge stale duels after this many seconds
Config.STATE_TTL_SECONDS = 7200

--- Maximum retries to re-apply health if GAS overwrites it
Config.HEALTH_REAPPLY_MAX_RETRIES = 3

--- Ticks to wait before checking if GAS overwrote health
Config.HEALTH_REAPPLY_CHECK_DELAY = 2

--- Whether to log all property access attempts (verbose, for debugging)
Config.DEBUG_PROPERTY_ACCESS = false

--- Whether to log all hook fires (very verbose, for debugging)
Config.DEBUG_HOOK_LOGGING = false

-- ===========================================================================
-- UE4SS / Game Integration
-- ===========================================================================

--- Game module name for UFunction hooks
Config.GAME_MODULE = "R5"

--- GAS module name for UFunction hooks
Config.GAS_MODULE = "GameplayAbilities"

--- Key game class names (used by FindFirstOf, NotifyOnNewObject)
Config.CLASS_NAMES = {
    PLAYER_CHARACTER = "R5PlayerCharacter",
    PLAYER_CONTROLLER = "R5PlayerController",
    PLAYER_STATE = "R5PlayerStateBase",
    SHIP_PAWN = "R5ShipPawnBase",
    MELEE_ABILITY = "R5MeleeAbility",
    BOARDING_BATTLE = "R5BoardingBattleNew",
    BOARDING_COMPONENT = "R5BoardingComponent",
    REVIVE_COMPONENT = "R5ReviveComponent",
    ABILITY_SYSTEM_COMPONENT = "AbilitySystemComponent",
    GAME_MODE = "R5GameMode",
}

--- UFunction hook paths (constructed from GAME_MODULE + CLASS_NAMES)
Config.HOOK_PATHS = {
    MELEE_REMOVE_EVENT_GES = "/Script/R5.R5MeleeAbility:RemoveEventGEs",
    BOARDING_ACTIVATE = "/Script/R5.R5BoardingLinkTargetAbility:ActivateAbility",
    GAS_APPLY_GE_SELF = "/Script/GameplayAbilities.AbilitySystemComponent:BP_ApplyGameplayEffectToSelf",
    GAS_APPLY_GE_TARGET = "/Script/GameplayAbilities.AbilitySystemComponent:BP_ApplyGameplayEffectSpecToTarget",
    GAS_APPLY_GE_SPEC_SELF = "/Script/GameplayAbilities.AbilitySystemComponent:ApplyGameplayEffectSpecToSelf",
    GAS_APPLY_GE_SPEC_TARGET = "/Script/GameplayAbilities.AbilitySystemComponent:ApplyGameplayEffectSpecToTarget",
    GAS_APPLY_GE_TO_TARGET = "/Script/GameplayAbilities.AbilitySystemComponent:ApplyGameplayEffectToTarget",
    GAS_POST_EXECUTE = "/Script/GameplayAbilities.AttributeSet:PostGameplayEffectExecute",
    GAS_PRE_ATTR_CHANGE = "/Script/GameplayAbilities.AttributeSet:PreAttributeChange",
    GAS_PRE_ATTR_BASE_CHANGE = "/Script/GameplayAbilities.AttributeSet:PreAttributeBaseChange",
}

-- ===========================================================================
-- Utility
-- ===========================================================================

--- Deep-copy a table (for config overrides)
--- @param obj table
--- @return table
function Config.deepcopy(orig)
    local copy
    if type(orig) == "table" then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[Config.deepcopy(orig_key)] = Config.deepcopy(orig_value)
        end
        setmetatable(copy, getmetatable(orig))
    else
        copy = orig
    end
    return copy
end

--- Override config values from a table (for runtime RCON config)
--- Only overrides keys that already exist in Config (no new keys)
--- @param key string
--- @param value string|number|boolean
--- @return boolean, string|nil
function Config.apply_overrides(overrides)
    if type(overrides) ~= "table" then return end
    for key, value in pairs(overrides) do
        if Config[key] ~= nil then
            -- Type check: don't allow changing type of a config value
            if type(Config[key]) == type(value) then
                Config[key] = value
            end
        end
    end
end

--- Get a config value by dot-separated path (e.g., "ARENA_CENTER.X")
--- @return table
function Config.get(path)
    local current = Config
    for part in path:gmatch("[^.]+") do
        if type(current) ~= "table" then return nil end
        current = current[part]
        if current == nil then return nil end
    end
    return current
end

return Config