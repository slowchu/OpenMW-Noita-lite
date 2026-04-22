local storage = require("openmw.storage")

local log = {}

local LEVELS = {
    debug = 1,
    info = 2,
    warn = 3,
    error = 4,
}

local section = storage.globalSection("SpellforgeSettings")
local SETTINGS_KEY = "log_level"

local function resolveLevel(level)
    local candidate = level or section:get(SETTINGS_KEY)
    if type(candidate) ~= "string" then
        return "info"
    end

    local normalized = string.lower(candidate)
    if LEVELS[normalized] then
        return normalized
    end

    return "info"
end

local function emit(level, module_name, message)
    local current_level = resolveLevel()
    if LEVELS[level] < LEVELS[current_level] then
        return
    end

    print(string.format("[spellforge][%s][%s] %s", module_name, string.upper(level), tostring(message)))
end

function log.setLevel(level)
    local normalized = resolveLevel(level)
    section:set(SETTINGS_KEY, normalized)
end

function log.new(module_name)
    return {
        debug = function(msg) emit("debug", module_name, msg) end,
        info = function(msg) emit("info", module_name, msg) end,
        warn = function(msg) emit("warn", module_name, msg) end,
        error = function(msg) emit("error", module_name, msg) end,
    }
end

return log
