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
local KEY_ENABLE_LIVE_PAYLOAD_MULTICAST = "enable_live_payload_multicast_v0"
local KEY_ENABLE_LIVE_PAYLOAD_PATTERN = "enable_live_payload_pattern_v0"
local KEY_ENABLE_LIVE_NESTED_TRIGGER_TIMER = "enable_live_nested_trigger_timer_v1"
local KEY_ENABLE_LIVE_NESTED_FINAL_FANOUT = "enable_live_nested_final_fanout_v0"
local KEY_ENABLE_LIVE_CHAIN_AUDIT = "enable_live_chain_audit_v0"
local KEY_ENABLE_LIVE_CHAIN_RUNTIME = "enable_live_chain_runtime_v0"
local KEY_ENABLE_LIVE_BOUNCE = "enable_live_bounce_v0"
local KEY_ENABLE_LIVE_HOMING = "enable_live_homing_v0"
local KEY_ENABLE_LIVE_SOFT_HOMING = "enable_live_soft_homing_v0"
local KEY_ENABLE_LIVE_SOFT_HOMING_PROBE = "enable_live_soft_homing_probe"
local KEY_ENABLE_LIVE_CHAIN_MULTICAST = "enable_live_chain_multicast_v0"
local KEY_ENABLE_CHAOS_BUDGET = "enable_chaos_budget_v0"

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
local DEFAULT_ENABLE_LIVE_PAYLOAD_MULTICAST = false
local DEFAULT_ENABLE_LIVE_PAYLOAD_PATTERN = false
local DEFAULT_ENABLE_LIVE_NESTED_TRIGGER_TIMER = false
local DEFAULT_ENABLE_LIVE_NESTED_FINAL_FANOUT = false
local DEFAULT_ENABLE_LIVE_CHAIN_AUDIT = false
local DEFAULT_ENABLE_LIVE_CHAIN_RUNTIME = false
local DEFAULT_ENABLE_LIVE_BOUNCE = false
local DEFAULT_ENABLE_LIVE_HOMING = false
local DEFAULT_ENABLE_LIVE_SOFT_HOMING = false
local DEFAULT_ENABLE_LIVE_SOFT_HOMING_PROBE = false
local DEFAULT_ENABLE_LIVE_CHAIN_MULTICAST = false
local DEFAULT_ENABLE_CHAOS_BUDGET = false

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

function dev.livePayloadMulticastEnabled()
    return readBoolean(KEY_ENABLE_LIVE_PAYLOAD_MULTICAST, DEFAULT_ENABLE_LIVE_PAYLOAD_MULTICAST)
end

function dev.livePayloadPatternEnabled()
    return readBoolean(KEY_ENABLE_LIVE_PAYLOAD_PATTERN, DEFAULT_ENABLE_LIVE_PAYLOAD_PATTERN)
end

function dev.liveNestedTriggerTimerEnabled()
    return readBoolean(KEY_ENABLE_LIVE_NESTED_TRIGGER_TIMER, DEFAULT_ENABLE_LIVE_NESTED_TRIGGER_TIMER)
end

function dev.liveNestedFinalFanoutEnabled()
    return readBoolean(KEY_ENABLE_LIVE_NESTED_FINAL_FANOUT, DEFAULT_ENABLE_LIVE_NESTED_FINAL_FANOUT)
end

function dev.liveChainAuditEnabled()
    return readBoolean(KEY_ENABLE_LIVE_CHAIN_AUDIT, DEFAULT_ENABLE_LIVE_CHAIN_AUDIT)
end

function dev.liveChainRuntimeEnabled()
    return readBoolean(KEY_ENABLE_LIVE_CHAIN_RUNTIME, DEFAULT_ENABLE_LIVE_CHAIN_RUNTIME)
end

function dev.liveBounceEnabled()
    return readBoolean(KEY_ENABLE_LIVE_BOUNCE, DEFAULT_ENABLE_LIVE_BOUNCE)
end

function dev.liveHomingEnabled()
    return readBoolean(KEY_ENABLE_LIVE_HOMING, DEFAULT_ENABLE_LIVE_HOMING)
end

function dev.liveSoftHomingEnabled()
    return readBoolean(KEY_ENABLE_LIVE_SOFT_HOMING, DEFAULT_ENABLE_LIVE_SOFT_HOMING)
end

function dev.liveSoftHomingProbeEnabled()
    return readBoolean(KEY_ENABLE_LIVE_SOFT_HOMING_PROBE, DEFAULT_ENABLE_LIVE_SOFT_HOMING_PROBE)
end

function dev.liveChainMulticastEnabled()
    return readBoolean(KEY_ENABLE_LIVE_CHAIN_MULTICAST, DEFAULT_ENABLE_LIVE_CHAIN_MULTICAST)
end

function dev.chaosBudgetEnabled()
    return readBoolean(KEY_ENABLE_CHAOS_BUDGET, DEFAULT_ENABLE_CHAOS_BUDGET)
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

function dev.livePayloadMulticastSettingKey()
    return "SpellforgeDev.enable_live_payload_multicast_v0"
end

function dev.livePayloadPatternSettingKey()
    return "SpellforgeDev.enable_live_payload_pattern_v0"
end

function dev.liveNestedTriggerTimerSettingKey()
    return "SpellforgeDev.enable_live_nested_trigger_timer_v1"
end

function dev.liveNestedFinalFanoutSettingKey()
    return "SpellforgeDev.enable_live_nested_final_fanout_v0"
end

function dev.liveChainAuditSettingKey()
    return "SpellforgeDev.enable_live_chain_audit_v0"
end

function dev.liveChainRuntimeSettingKey()
    return "SpellforgeDev.enable_live_chain_runtime_v0"
end

function dev.liveBounceSettingKey()
    return "SpellforgeDev.enable_live_bounce_v0"
end

function dev.liveHomingSettingKey()
    return "SpellforgeDev.enable_live_homing_v0"
end

function dev.liveSoftHomingSettingKey()
    return "SpellforgeDev.enable_live_soft_homing_v0"
end

function dev.liveSoftHomingProbeSettingKey()
    return "SpellforgeDev.enable_live_soft_homing_probe"
end

function dev.liveChainMulticastSettingKey()
    return "SpellforgeDev.enable_live_chain_multicast_v0"
end

function dev.chaosBudgetSettingKey()
    return "SpellforgeDev.enable_chaos_budget_v0"
end

return dev
