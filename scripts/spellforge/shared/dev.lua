local storage = require("openmw.storage")

local dev = {}

local section = storage.globalSection("SpellforgeDev")
local KEY_ENABLE_SMOKE_TESTS = "enable_smoke_tests"
local KEY_ENABLE_DEV_HOTKEYS = "enable_dev_hotkeys"
local KEY_ENABLE_DEBUG_LAUNCH = "enable_debug_launch"
local KEY_ENABLE_DEV_LAUNCH = "enable_dev_launch"
local KEY_ENABLE_LIVE_2_2C_SIMPLE_DISPATCH = "enable_live_2_2c_simple_dispatch"

local DEFAULT_ENABLE_SMOKE_TESTS = false
local DEFAULT_ENABLE_DEV_HOTKEYS = false
local DEFAULT_ENABLE_DEBUG_LAUNCH = false
local DEFAULT_ENABLE_DEV_LAUNCH = false
local DEFAULT_ENABLE_LIVE_2_2C_SIMPLE_DISPATCH = false

local function readBoolean(key, default_value)
    local value = section:get(key)
    if value == nil then
        return default_value
    end
    return value == true
end

function dev.smokeTestsEnabled()
    return readBoolean(KEY_ENABLE_SMOKE_TESTS, DEFAULT_ENABLE_SMOKE_TESTS)
end

function dev.devHotkeysEnabled()
    return readBoolean(KEY_ENABLE_DEV_HOTKEYS, DEFAULT_ENABLE_DEV_HOTKEYS)
end

function dev.debugLaunchEnabled()
    return dev.devHotkeysEnabled() and readBoolean(KEY_ENABLE_DEBUG_LAUNCH, DEFAULT_ENABLE_DEBUG_LAUNCH)
end

function dev.devLaunchEnabled()
    return readBoolean(KEY_ENABLE_DEV_LAUNCH, DEFAULT_ENABLE_DEV_LAUNCH)
end

function dev.liveSimpleDispatchEnabled()
    return readBoolean(KEY_ENABLE_LIVE_2_2C_SIMPLE_DISPATCH, DEFAULT_ENABLE_LIVE_2_2C_SIMPLE_DISPATCH)
end

function dev.smokeTestsSettingKey()
    return "SpellforgeDev.enable_smoke_tests"
end

function dev.devHotkeysSettingKey()
    return "SpellforgeDev.enable_dev_hotkeys"
end

function dev.debugLaunchSettingKey()
    return "SpellforgeDev.enable_debug_launch"
end

function dev.devLaunchSettingKey()
    return "SpellforgeDev.enable_dev_launch"
end

function dev.liveSimpleDispatchSettingKey()
    return "SpellforgeDev.enable_live_2_2c_simple_dispatch"
end

return dev
