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
        setDevTrue("enable_live_2_2c_simple_dispatch")
    end)
    if not ok then
        state.failed = true
        log.error(string.format("failed to enable dev launch flags: %s", tostring(err)))
        return
    end

    state.applied = true
    log.info("enabled SpellforgeDev.enable_smoke_tests, SpellforgeDev.enable_dev_launch, and SpellforgeDev.enable_live_2_2c_simple_dispatch")
end

return {
    engineHandlers = {
        onUpdate = apply,
    },
}
