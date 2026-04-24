local storage = require("openmw.storage")

local dev = {}

local section = storage.globalSection("SpellforgeDev")
local KEY_ENABLE_SMOKE_TESTS = "enable_smoke_tests"
local DEFAULT_ENABLE_SMOKE_TESTS = false

function dev.smokeTestsEnabled()
    local value = section:get(KEY_ENABLE_SMOKE_TESTS)
    if value == nil then
        return DEFAULT_ENABLE_SMOKE_TESTS
    end
    return value == true
end

function dev.smokeTestsSettingKey()
    return "SpellforgeDev.enable_smoke_tests"
end

return dev
