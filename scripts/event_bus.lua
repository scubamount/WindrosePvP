--- WindrosePvP Event Bus
--- Internal pub/sub system for inter-module communication.
--- Errors in one handler do not block other handlers.

--- @class EventBus
--- @field _handlers table<string, {id: number, fn: function}[]> Event handler registry
--- @field _next_id number Auto-incrementing handler ID
--- @field _event_log table Ring buffer of recent events
--- @field _event_log_max number Max ring buffer size
--- @field _event_log_index number Current ring buffer index
--- @field _tests_registered boolean Whether test handlers are registered
--- @field _test_results table|nil Self-test results

local EventBus = {}

-- ===========================================================================
-- State
-- ===========================================================================

EventBus._handlers = {}  -- { [event_name] = { {id=number, fn=function}, ... } }
EventBus._next_id = 1
EventBus._event_log = {}  -- Ring buffer of recent events (for debugging)
EventBus._event_log_max = 100
EventBus._event_log_index = 0
EventBus._tests_registered = false

-- ===========================================================================
-- Public API
-- ===========================================================================

--- Subscribe to an event.
--- @param event_name string The event to listen for
--- @param handler_fn function Callback receiving the event data
--- @return number Subscription ID (for unsubscribing)
--- @param event string
--- @param callback function
--- @return number
function EventBus.on(event_name, handler_fn)
    if type(event_name) ~= "string" or type(handler_fn) ~= "function" then
        return -1
    end

    local id = EventBus._next_id
    EventBus._next_id = EventBus._next_id + 1

    EventBus._handlers[event_name] = EventBus._handlers[event_name] or {}
    table.insert(EventBus._handlers[event_name], { id = id, fn = handler_fn })

    return id
end

--- Unsubscribe from an event.
--- @param event_name string The event name
--- @param handler_id number The subscription ID returned by on()
--- @return boolean Whether the handler was found and removed
--- @param event string
--- @param id number
--- @return boolean
function EventBus.off(event_name, handler_id)
    local list = EventBus._handlers[event_name]
    if not list then return false end

    for i, handler in ipairs(list) do
        if handler.id == handler_id then
            table.remove(list, i)
            return true
        end
    end
    return false
end

--- Emit an event to all subscribers.
--- Each handler runs in isolation — errors in one handler do not affect others.
--- @param event_name string The event name
--- @param data any Event data (typically a table)
--- @param event string
--- @param data any
function EventBus.emit(event_name, data)
    local list = EventBus._handlers[event_name]

    -- Log event to ring buffer
    EventBus._event_log_index = (EventBus._event_log_index % EventBus._event_log_max) + 1
    EventBus._event_log[EventBus._event_log_index] = {
        name = event_name,
        data = data,
        timestamp = os.time(),
    }

    if not list or #list == 0 then return end

    -- Execute handlers in registration order
    -- Iterate over a copy to handle mutations during iteration
    local handlers_copy = {}
    for _, h in ipairs(list) do
        handlers_copy[#handlers_copy + 1] = h
    end

    for _, handler in ipairs(handlers_copy) do
        local ok, err = pcall(handler.fn, data)
        if not ok then
            print("[EventBus] Error in handler for '" .. event_name .. "' (id=" .. handler.id .. "): " .. tostring(err))
        end
    end
end

--- Subscribe to an event, but only fire once then auto-unsubscribe.
--- @param event_name string The event to listen for
--- @param handler_fn function Callback
--- @return number Subscription ID
--- @param event string
--- @param callback function
--- @return number
function EventBus.once(event_name, handler_fn)
    local id
    local wrapper = function(data)
        EventBus.off(event_name, id)
        handler_fn(data)
    end
    id = EventBus.on(event_name, wrapper)
    return id
end

--- Remove all handlers for a specific event.
--- @param event_name string
--- @param event string|nil
function EventBus.clear(event_name)
    EventBus._handlers[event_name] = nil
end

--- Remove all handlers for all events.
function EventBus.clear_all()
    EventBus._handlers = {}
end

-- ===========================================================================
-- Debug / Introspection
-- ===========================================================================

--- Get the number of handlers for an event.
--- @param event_name string
--- @return number
function EventBus.handler_count(event_name)
    local list = EventBus._handlers[event_name]
    return list and #list or 0
end

--- Get all event names that have at least one handler.
--- @return table List of event name strings
--- @return string[]
function EventBus.active_events()
    local events = {}
    for name, handlers in pairs(EventBus._handlers) do
        if #handlers > 0 then
            events[#events + 1] = name
        end
    end
    return events
end

--- Get the recent event log (ring buffer contents).
--- @param count number|nil Maximum events to return (default: 20)
--- @return table List of event records {name, data, timestamp}
function EventBus.get_log(count)
    count = count or 20
    local result = {}
    local total = 0
    for _ in pairs(EventBus._event_log) do total = total + 1 end

    local start = EventBus._event_log_index - count + 1
    if start < 1 then start = 1 end

    for i = start, EventBus._event_log_index do
        local idx = ((i - 1) % EventBus._event_log_max) + 1
        local entry = EventBus._event_log[idx]
        if entry then
            result[#result + 1] = entry
        end
    end
    return result
end

-- ===========================================================================
-- Self-Tests
-- ===========================================================================

-- Delayed registration since Utils may not be loaded yet
local function register_tests()
    if EventBus._tests_registered then
        return 0, 0
    end
    EventBus._tests_registered = true

    -- Basic emit/receive
    EventBus._test_results = EventBus._test_results or {}

    local function test_basic()
        local received = nil
        local id = EventBus.on("test_event", function(data)
            received = data
        end)
        EventBus.emit("test_event", {value = 42})
        EventBus.off("test_event", id)
        return received and received.value == 42
    end

    local function test_off()
        local count = 0
        local id = EventBus.on("test_off", function() count = count + 1 end)
        EventBus.emit("test_off", {})
        EventBus.off("test_off", id)
        EventBus.emit("test_off", {})
        return count == 1
    end

    local function test_once()
        local count = 0
        EventBus.once("test_once", function() count = count + 1 end)
        EventBus.emit("test_once", {})
        EventBus.emit("test_once", {})
        return count == 1
    end

    local function test_error_isolation()
        local second_called = false
        EventBus.on("test_error", function() error("intentional") end)
        EventBus.on("test_error", function() second_called = true end)
        EventBus.emit("test_error", {})
        EventBus.clear("test_error")
        return second_called
    end

    local function test_handler_count()
        EventBus.clear("test_count")
        EventBus.on("test_count", function() end)
        EventBus.on("test_count", function() end)
        local count = EventBus.handler_count("test_count")
        EventBus.clear("test_count")
        return count == 2
    end

    local function test_no_handlers()
        -- Emitting to event with no handlers should not crash
        EventBus.emit("nonexistent_event", {})
        return true
    end

    -- Run tests
    local tests = {
        {"basic_emit_receive", test_basic},
        {"off_unsubscribes", test_off},
        {"once_auto_unsubscribes", test_once},
        {"error_isolation", test_error_isolation},
        {"handler_count", test_handler_count},
        {"no_handlers_no_crash", test_no_handlers},
    }

    local passed, failed = 0, 0
    for _, t in ipairs(tests) do
        local name, fn = t[1], t[2]
        local ok, result = pcall(fn)
        if ok and result then
            passed = passed + 1
        else
            failed = failed + 1
            print("[EventBus TEST FAIL] " .. name .. ": " .. tostring(ok and "returned false" or result))
        end
    end
    print(string.format("[EventBus TESTS] %d passed, %d failed", passed, failed))
    return passed, failed
end

--- Run event bus self-tests.
--- @return number passed, number failed
--- @return number, number
function EventBus.run_self_tests()
    return register_tests()
end

return EventBus