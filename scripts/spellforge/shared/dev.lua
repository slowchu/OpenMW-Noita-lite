local storage = require("openmw.storage")

local dev = {}

local section = storage.globalSection("SpellforgeDev")
local KEY_ENABLE_SMOKE_TESTS = "enable_smoke_tests"
local KEY_ENABLE_DEV_HOTKEYS = "enable_dev_hotkeys"
local KEY_ENABLE_DEBUG_LAUNCH = "enable_debug_launch"
local KEY_ENABLE_DEV_LAUNCH = "enable_dev_launch"
local KEY_ENABLE_LIVE_2_2C_RUNTIME = "enable_live_2_2c_runtime"
local KEY_ENABLE_LIVE_MULTICAST = "enable_live_multicast"
local KEY_ENABLE_LIVE_SPREAD_BURST = "enable_live_spread_burst"
local KEY_ENABLE_LIVE_TRIGGER = "enable_live_trigger"
local KEY_ENABLE_LIVE_TIMER = "enable_live_timer"
local KEY_ENABLE_LIVE_SPEED_PLUS = "enable_live_speed_plus"
local KEY_ENABLE_LIVE_SIZE_PLUS = "enable_live_size_plus"

local DEFAULT_ENABLE_SMOKE_TESTS = false
local DEFAULT_ENABLE_DEV_HOTKEYS = false
local DEFAULT_ENABLE_DEBUG_LAUNCH = false
local DEFAULT_ENABLE_DEV_LAUNCH = false
local DEFAULT_ENABLE_LIVE_2_2C_RUNTIME = false
local DEFAULT_ENABLE_LIVE_MULTICAST = false
local DEFAULT_ENABLE_LIVE_SPREAD_BURST = false
local DEFAULT_ENABLE_LIVE_TRIGGER = false
local DEFAULT_ENABLE_LIVE_TIMER = false
local DEFAULT_ENABLE_LIVE_SPEED_PLUS = false
local DEFAULT_ENABLE_LIVE_SIZE_PLUS = false

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
    return readBoolean(KEY_ENABLE_LIVE_2_2C_RUNTIME, DEFAULT_ENABLE_LIVE_2_2C_RUNTIME)
end

function dev.liveMulticastEnabled()
    return readBoolean(KEY_ENABLE_LIVE_MULTICAST, DEFAULT_ENABLE_LIVE_MULTICAST)
end

function dev.liveSpreadBurstEnabled()
    return readBoolean(KEY_ENABLE_LIVE_SPREAD_BURST, DEFAULT_ENABLE_LIVE_SPREAD_BURST)
end

function dev.liveTriggerEnabled()
    return readBoolean(KEY_ENABLE_LIVE_TRIGGER, DEFAULT_ENABLE_LIVE_TRIGGER)
end

function dev.liveTimerEnabled()
    return readBoolean(KEY_ENABLE_LIVE_TIMER, DEFAULT_ENABLE_LIVE_TIMER)
end

function dev.liveSpeedPlusEnabled()
    return readBoolean(KEY_ENABLE_LIVE_SPEED_PLUS, DEFAULT_ENABLE_LIVE_SPEED_PLUS)
end

function dev.liveSizePlusEnabled()
    return readBoolean(KEY_ENABLE_LIVE_SIZE_PLUS, DEFAULT_ENABLE_LIVE_SIZE_PLUS)
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
    return "SpellforgeDev.enable_live_2_2c_runtime"
end

function dev.liveMulticastSettingKey()
    return "SpellforgeDev.enable_live_multicast"
end

function dev.liveSpreadBurstSettingKey()
    return "SpellforgeDev.enable_live_spread_burst"
end

function dev.liveTriggerSettingKey()
    return "SpellforgeDev.enable_live_trigger"
end

function dev.liveTimerSettingKey()
    return "SpellforgeDev.enable_live_timer"
end

function dev.liveSpeedPlusSettingKey()
    return "SpellforgeDev.enable_live_speed_plus"
end

function dev.liveSizePlusSettingKey()
    return "SpellforgeDev.enable_live_size_plus"
end

return dev
