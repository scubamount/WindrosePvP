--- WindrosePvP Utility Functions
--- Safe property access, logging, hook wrappers, and self-test harness.

--- @class Utils
--- Utilities for safe property access, logging, UE4SS API wrappers

local Utils = {}

-- ===========================================================================
-- Logging
-- ===========================================================================

--- Log levels: 1=ERROR, 2=WARN, 3=INFO, 4=DEBUG
Utils.LOG_LEVEL = 3

local LEVEL_PREFIXES = {
    [1] = "[PvP ERROR]",
    [2] = "[PvP WARN]",
    [3] = "[PvP INFO]",
    [4] = "[PvP DEBUG]",
}

--- Log a message at the specified level.
--- @param level number 1-4
--- @param message string
function Utils.log(level, message)
    if level <= Utils.LOG_LEVEL then
        local prefix = LEVEL_PREFIXES[level] or "[PvP]"
        print(prefix .. " " .. tostring(message))
    end
end

--- @param msg string
function Utils.error(message) Utils.log(1, message) end

--- @param msg string
function Utils.warn(message) Utils.log(2, message) end

--- @param msg string
function Utils.info(message) Utils.log(3, message) end

--- @param msg string
function Utils.debug(message) Utils.log(4, message) end

-- ===========================================================================
-- Safe Property Access
-- ===========================================================================

--- Safely read a property from a UObject via dot-separated path.
--- @param obj userdata|nil The UObject to read from
--- @param prop_path string Dot-separated property path (e.g., "Health" or "AbilitySystemComponent.AttributeSet.Health")
--- @return any|nil The property value, or nil on any failure
--- @param obj userdata
--- @param path string
--- @return any
function Utils.safe_read(obj, prop_path)
    if not obj then return nil end
    if type(obj) ~= "userdata" then return nil end
    
    local ok, result = pcall(function()
        if not obj:IsValid() then return nil end
        local current = obj
        for part in prop_path:gmatch("[^.]+") do
            current = current[part]
            if current == nil then return nil end
            if type(current) == "userdata" then
                if not current:IsValid() then return nil end
            end
        end
        return current
    end)
    
    if not ok then
        Utils.debug("safe_read failed for path '" .. prop_path .. "': " .. tostring(result))
        return nil
    end
    return result
end

--- Safely write a value to a UObject property via dot-separated path.
--- @param obj userdata|nil The UObject to write to
--- @param prop_path string Dot-separated property path
--- @param value any The value to write
--- @return boolean Whether the write succeeded
--- @param obj userdata
--- @param path string
--- @param value any
--- @return boolean
function Utils.safe_write(obj, prop_path, value)
    if not obj then return false end
    if type(obj) ~= "userdata" then return false end
    
    local ok, err = pcall(function()
        if not obj:IsValid() then return end
        
        local parts = {}
        for p in prop_path:gmatch("[^.]+") do
            parts[#parts + 1] = p
        end
        
        local current = obj
        for i = 1, #parts - 1 do
            current = current[parts[i]]
            if current == nil then return end
            if type(current) == "userdata" and not current:IsValid() then return end
        end
        
        current[parts[#parts]] = value
    end)
    
    if not ok then
        Utils.debug("safe_write failed for path '" .. prop_path .. "': " .. tostring(err))
        return false
    end
    return true
end

--- Try multiple property names/path variants to find one that works.
--- @param obj userdata The UObject to probe
--- @param candidates table List of property path strings to try
--- @return string|nil The first path that returns a non-nil value
--- @return any|nil The value read from that path
function Utils.probe_property(obj, candidates)
    for _, path in ipairs(candidates) do
        local value = Utils.safe_read(obj, path)
        if value ~= nil then
            return path, value
        end
    end
    return nil, nil
end

-- ===========================================================================
-- Safe Object Finding
-- ===========================================================================

--- Safely find the first instance of a class.
--- @param class_name string The UE class name (e.g., "R5PlayerCharacter")
--- @return userdata|nil The first found object, or nil
--- @param class string
--- @return userdata|nil
function Utils.find_first_of(class_name)
    local ok, result = pcall(function()
        return FindFirstOf(class_name)
    end)
    if not ok then
        Utils.debug("FindFirstOf('" .. class_name .. "') failed: " .. tostring(result))
        return nil
    end
    if result and type(result) == "userdata" and result:IsValid() then
        return result
    end
    return nil
end

--- Safely find all instances of a class.
--- @param class_name string The UE class name
--- @return table|nil List of found objects, or nil on failure
--- @param class string
--- @return table|nil
function Utils.find_all_of(class_name)
    local ok, result = pcall(function()
        return FindAllOf(class_name)
    end)
    if not ok then
        Utils.debug("FindAllOf('" .. class_name .. "') failed: " .. tostring(result))
        return nil
    end
    return result
end

--- Safely register a NotifyOnNewObject callback.
--- @param class_name string The UE class name to watch
--- @param callback function Callback receiving the new object
--- @return boolean Whether registration succeeded
function Utils.notify_on_new_object(class_name, callback)
    local ok, err = pcall(function()
        NotifyOnNewObject(class_name, function(obj)
            local cb_ok, cb_err = pcall(callback, obj)
            if not cb_ok then
                Utils.error("NotifyOnNewObject callback error for '" .. class_name .. "': " .. tostring(cb_err))
            end
        end)
    end)
    if not ok then
        Utils.warn("NotifyOnNewObject('" .. class_name .. "') failed: " .. tostring(err))
        return false
    end
    return true
end

-- ===========================================================================
-- Safe Hook Registration
-- ===========================================================================

--- Safely register a UFunction hook with error-isolated callbacks.
--- @param hook_path string Full UFunction path (e.g., "/Script/R5.R5MeleeAbility:RemoveEventGEs")
--- @param pre_fn function|nil Pre-hook callback (self, params...) → nil|false
--- @param post_fn function|nil Post-hook callback (self, params..., retval)
--- @return boolean Whether hook registration succeeded
--- @param path string
--- @param callback function
--- @return boolean
function Utils.safe_hook(hook_path, pre_fn, post_fn)
    local wrapped_pre = nil
    if pre_fn then
        wrapped_pre = function(self, ...)
            local ok, result = pcall(pre_fn, self, ...)
            if not ok then
                Utils.error("Hook Pre error: " .. hook_path .. " → " .. tostring(result))
            end
            return result
        end
    end
    
    local wrapped_post = nil
    if post_fn then
        wrapped_post = function(self, ...)
            local ok, err = pcall(post_fn, self, ...)
            if not ok then
                Utils.error("Hook Post error: " .. hook_path .. " → " .. tostring(err))
            end
        end
    end
    
    local ok, err = pcall(function()
        RegisterHook(hook_path, wrapped_pre, wrapped_post)
    end)
    
    if not ok then
        Utils.warn("RegisterHook failed: " .. hook_path .. " → " .. tostring(err))
        return false
    end
    
    Utils.info("Hook registered: " .. hook_path)
    return true
end

--- Try to register hooks for multiple UFunction paths, return first success.
--- @param hook_paths table List of UFunction paths to try
--- @param pre_fn function|nil Pre-hook callback
--- @param post_fn function|nil Post-hook callback
--- @return boolean Whether any hook registration succeeded
--- @return string|nil The path that succeeded
function Utils.try_hook_paths(hook_paths, pre_fn, post_fn)
    for _, path in ipairs(hook_paths) do
        if Utils.safe_hook(path, pre_fn, post_fn) then
            return true, path
        end
    end
    Utils.warn("All hook paths failed for: " .. tostring(hook_paths[1]) .. " (and " .. #hook_paths - 1 .. " alternatives)")
    return false, nil
end

-- ===========================================================================
-- Math Helpers
-- ===========================================================================

--- Calculate 3D distance between two FVector-like tables.
--- @param a table {X, Y, Z}
--- @param b table {X, Y, Z}
--- @return number Distance in UE units
function Utils.distance_3d(a, b)
    if not a or not b then return math.huge end
    local dx = (a.X or 0) - (b.X or 0)
    local dy = (a.Y or 0) - (b.Y or 0)
    local dz = (a.Z or 0) - (b.Z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Clamp a value between min and max.
--- @param value number
--- @param min number
--- @param max number
--- @return number
function Utils.clamp(value, min, max)
    return math.max(min, math.min(max, value))
end

-- ===========================================================================
-- String Helpers
-- ===========================================================================

--- Format a template string with placeholders.
--- @param template string Template with {key} placeholders
--- @param data table Key-value pairs to substitute
--- @return string Formatted string
--- @param template string
--- @param data table
--- @return string
function Utils.format_template(template, data)
    return template:gsub("{(%w+)}", function(key)
        return tostring(data[key] or "{" .. key .. "}")
    end)
end

--- Get a player identifier string from a UObject.
--- Tries common name properties, falls back to address.
--- @param player userdata Player UObject
--- @return string Player identifier
--- @param obj userdata
--- @return string|nil
function Utils.player_id(player)
    if not player then return "<nil>" end
    
    -- Try common name properties
    local name = Utils.safe_read(player, "PlayerNamePrivate")
        or Utils.safe_read(player, "PlayerName")
        or Utils.safe_read(player, "Name")
    
    if name and type(name) == "string" and #name > 0 then
        return name
    end
    
    -- Try PlayerState
    local ps = Utils.safe_read(player, "PlayerState")
    if ps then
        local ps_name = Utils.safe_read(ps, "PlayerNamePrivate")
            or Utils.safe_read(ps, "PlayerName")
        if ps_name and type(ps_name) == "string" and #ps_name > 0 then
            return ps_name
        end
    end
    
    -- Fallback to memory address
    local ok, addr = pcall(function()
        return string.format("%p", player)
    end)
    if ok then return "Player_" .. tostring(addr) end
    
    return "<unknown>"
end

-- ===========================================================================
-- Table Helpers
-- ===========================================================================

--- Count entries in a table (works with non-numeric keys).
--- @param t table
--- @return number
function Utils.table_count(t)
    if not t then return 0 end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

--- Check if a table contains a value.
--- @param t table
--- @param value any
--- @return boolean
function Utils.table_contains(t, value)
    if not t then return false end
    for _, v in pairs(t) do
        if v == value then return true end
    end
    return false
end

--- Get the address of a UObject for use as a table key.
--- @param obj userdata
--- @return string|nil Address string
--- @param obj userdata
--- @return string|nil
function Utils.obj_address(obj)
    if not obj then return nil end
    local ok, addr = pcall(function()
        return string.format("%p", obj)
    end)
    return ok and addr or nil
end

-- ===========================================================================
-- Self-Test Harness
-- ===========================================================================

Utils._tests = {}

--- Register a self-test function.
--- @param name string Test name
--- @param fn function Test function (should return true on success)
--- @param name string
--- @param fn function
--- @return boolean
function Utils.register_test(name, fn)
    Utils._tests[name] = fn
end

--- Run all registered self-tests.
--- @return number passed, number failed
function Utils.run_tests()
    local passed = 0
    local failed = 0
    Utils.info("=== Running PvP Mod Self-Tests ===")
    for name, fn in pairs(Utils._tests) do
        local ok, result = pcall(fn)
        if ok and result then
            passed = passed + 1
            Utils.info("[PASS] " .. name)
        else
            failed = failed + 1
            local err_msg = ok and "returned false/nil" or tostring(result)
            Utils.error("[FAIL] " .. name .. ": " .. err_msg)
        end
    end
    Utils.info(string.format("=== Tests Complete: %d passed, %d failed ===", passed, failed))
    return passed, failed
end

-- ===========================================================================
-- Built-in Self-Tests
-- ===========================================================================

Utils.register_test("safe_read_nil", function()
    return Utils.safe_read(nil, "Foo") == nil
end)

Utils.register_test("safe_write_nil", function()
    return Utils.safe_write(nil, "Foo", 1) == false
end)

Utils.register_test("distance_3d_same_point", function()
    local p = {X = 10, Y = 20, Z = 30}
    return math.abs(Utils.distance_3d(p, p)) < 0.001
end)

Utils.register_test("distance_3d_known", function()
    local a = {X = 0, Y = 0, Z = 0}
    local b = {X = 3, Y = 4, Z = 0}
    return math.abs(Utils.distance_3d(a, b) - 5.0) < 0.001
end)

Utils.register_test("clamp", function()
    return Utils.clamp(5, 0, 10) == 5
        and Utils.clamp(-1, 0, 10) == 0
        and Utils.clamp(15, 0, 10) == 10
end)

Utils.register_test("format_template", function()
    local result = Utils.format_template("Hello {name}!", {name = "World"})
    return result == "Hello World!"
end)

Utils.register_test("format_template_missing", function()
    local result = Utils.format_template("Hello {name}!", {})
    return result == "Hello {name}!"
end)

Utils.register_test("table_count", function()
    return Utils.table_count({a=1, b=2, c=3}) == 3
end)

Utils.register_test("table_contains", function()
    return Utils.table_contains({1, 2, 3}, 2) == true
        and Utils.table_contains({1, 2, 3}, 5) == false
end)

Utils.register_test("probe_property_empty", function()
    local path, val = Utils.probe_property(nil, {"Foo", "Bar"})
    return path == nil and val == nil
end)

return Utils