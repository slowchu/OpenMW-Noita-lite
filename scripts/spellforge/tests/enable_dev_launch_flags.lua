local storage = require("openmw.storage")

local log = require("scripts.spellforge.shared.log").new("tests.enable_dev_launch_flags")

local dev_section = storage.globalSection("SpellforgeDev")
local log_section = storage.globalSection("SpellforgeSettings")

local state = {
    applied = false,
    failed = false,
}

local function ensureInfoLogs()
    local current = log_section:get("log_level")
    if current ~= "debug" and current ~= "info" then
        log_section:set("log_level", "info")
    end
end

local function setDevTrue(key)
    if dev_section:get(key) ~= true then
        dev_section:set(key, true)
    end
end

local function apply()
    if state.applied or state.failed then
        return
    end

    local ok, err = pcall(function()
        ensureInfoLogs()
        setDevTrue("enable_smoke_tests")
        setDevTrue("enable_dev_launch")
        setDevTrue("enable_live_2_2c_runtime")
        setDevTrue("enable_live_multicast")
        setDevTrue("enable_live_spread_burst")
        setDevTrue("enable_live_trigger")
        setDevTrue("enable_live_timer")
        setDevTrue("enable_live_speed_plus")
        setDevTrue("enable_live_size_plus")
        setDevTrue("enable_live_payload_multicast_v0")
        setDevTrue("enable_live_payload_pattern_v0")
        setDevTrue("enable_live_nested_trigger_timer_v1")
        setDevTrue("enable_live_nested_final_fanout_v0")
        setDevTrue("enable_live_chain_audit_v0")
        setDevTrue("enable_live_chain_runtime_v0")
        setDevTrue("enable_live_bounce_v0")
        setDevTrue("enable_live_pierce_v0")
        setDevTrue("enable_live_homing_v0")
        setDevTrue("enable_live_soft_homing_v0")
        setDevTrue("enable_live_soft_homing_probe")
        setDevTrue("enable_live_chain_multicast_v0")
        setDevTrue("enable_chaos_budget_v0")
    end)
    if not ok then
        state.failed = true
        log.error(string.format("failed to enable dev launch flags: %s", tostring(err)))
        return
    end

    state.applied = true
    log.info("enabled SpellforgeDev.enable_smoke_tests, SpellforgeDev.enable_dev_launch, SpellforgeDev.enable_live_2_2c_runtime, SpellforgeDev.enable_live_multicast, SpellforgeDev.enable_live_spread_burst, SpellforgeDev.enable_live_trigger, SpellforgeDev.enable_live_timer, SpellforgeDev.enable_live_speed_plus, SpellforgeDev.enable_live_size_plus, SpellforgeDev.enable_live_payload_multicast_v0, SpellforgeDev.enable_live_payload_pattern_v0, SpellforgeDev.enable_live_nested_trigger_timer_v1, SpellforgeDev.enable_live_nested_final_fanout_v0, SpellforgeDev.enable_live_chain_audit_v0, SpellforgeDev.enable_live_chain_runtime_v0, SpellforgeDev.enable_live_bounce_v0, SpellforgeDev.enable_live_pierce_v0, SpellforgeDev.enable_live_homing_v0, SpellforgeDev.enable_live_soft_homing_v0, SpellforgeDev.enable_live_soft_homing_probe, SpellforgeDev.enable_live_chain_multicast_v0, and SpellforgeDev.enable_chaos_budget_v0; IR runtime adapters are preferred automatically under their matching live gates")
end

return {
    engineHandlers = {
        onUpdate = apply,
    },
}
