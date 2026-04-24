local input = require("openmw.input")

local parser = require("scripts.spellforge.global.parser")
local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_parser")
local dev = require("scripts.spellforge.shared.dev")

local state = {
    ran = false,
}

local function assertLine(ok, label, detail)
    if ok then
        log.info("PASS " .. label)
    else
        log.error("FAIL " .. label .. (detail and (" :: " .. detail) or ""))
    end
end

local function hasErrorContaining(result, needle)
    for _, err in ipairs(result and result.errors or {}) do
        local msg = err and err.message or ""
        if type(msg) == "string" and string.find(string.lower(msg), string.lower(needle), 1, true) then
            return true
        end
    end
    return false
end

local OP = {
    multicast = "spellforge_multicast",
    spread = "spellforge_spread",
    burst = "spellforge_burst",
    trigger = "spellforge_trigger",
    timer = "spellforge_timer",
}

local function run()
    if not dev.smokeTestsEnabled() then
        return
    end
    local cases = {
        {
            label = "single emitter",
            effects = {
                { id = "firedamage", range = 2 },
            },
            expect_ok = true,
            check = function(result)
                return result.ok and #result.groups == 1 and #result.groups[1].effects == 1
            end,
        },
        {
            label = "compatible target emitters",
            effects = {
                { id = "firedamage", range = 2 },
                { id = "frostdamage", range = 2 },
            },
            expect_ok = true,
            check = function(result)
                return result.ok and #result.groups == 1 and #result.groups[1].effects == 2
            end,
        },
        {
            label = "range break",
            effects = {
                { id = "firedamage", range = 2 },
                { id = "shield", range = 0 },
            },
            expect_ok = true,
            check = function(result)
                return result.ok and #result.groups == 2
            end,
        },
        {
            label = "prefix binding multicast",
            effects = {
                { id = OP.multicast, params = { count = 3 } },
                { id = "firedamage", range = 2 },
            },
            expect_ok = true,
            check = function(result)
                local g = result.groups and result.groups[1]
                return g and #g.prefix_ops == 1 and g.prefix_ops[1].opcode == "Multicast"
            end,
        },
        {
            label = "multicast consumes next group only",
            effects = {
                { id = OP.multicast, params = { count = 3 } },
                { id = "firedamage", range = 2 },
                { id = "shield", range = 0 },
            },
            expect_ok = true,
            check = function(result)
                local g1 = result.groups and result.groups[1]
                local g2 = result.groups and result.groups[2]
                return g1 and g2 and #g1.prefix_ops == 1 and #g2.prefix_ops == 0
            end,
        },
        {
            label = "pattern valid burst+multicast",
            effects = {
                { id = OP.burst, params = { count = 4 } },
                { id = OP.multicast, params = { count = 5 } },
                { id = "firedamage", range = 2 },
            },
            expect_ok = true,
            check = function(result)
                local g = result.groups and result.groups[1]
                return g and #g.prefix_ops == 2 and g.prefix_ops[1].opcode == "Burst" and g.prefix_ops[2].opcode == "Multicast"
            end,
        },
        {
            label = "pattern invalid burst without multicast",
            effects = {
                { id = OP.burst, params = { count = 4 } },
                { id = "firedamage", range = 2 },
            },
            expect_ok = false,
            check = function(result)
                return (not result.ok) and hasErrorContaining(result, "requires Multicast")
            end,
        },
        {
            label = "trigger binding",
            effects = {
                { id = "firedamage", range = 2 },
                { id = OP.trigger },
                { id = "frostdamage", range = 2 },
            },
            expect_ok = true,
            check = function(result)
                local g = result.groups and result.groups[1]
                return g and #g.postfix_ops == 1 and g.postfix_ops[1].opcode == "Trigger" and g.payload ~= nil
            end,
        },
        {
            label = "trigger invalid no previous emitter",
            effects = {
                { id = OP.trigger },
                { id = "firedamage", range = 2 },
            },
            expect_ok = false,
            check = function(result)
                return (not result.ok) and hasErrorContaining(result, "no preceding emitter group")
            end,
        },
        {
            label = "timer valid",
            effects = {
                { id = "firedamage", range = 2 },
                { id = OP.timer, params = { seconds = 1.0 } },
                { id = "frostdamage", range = 2 },
            },
            expect_ok = true,
            check = function(result)
                local g = result.groups and result.groups[1]
                return g and #g.postfix_ops == 1 and g.postfix_ops[1].opcode == "Timer"
            end,
        },
        {
            label = "timer invalid duration",
            effects = {
                { id = "firedamage", range = 2 },
                { id = OP.timer, params = { seconds = 0.1 } },
            },
            expect_ok = false,
            check = function(result)
                return (not result.ok) and hasErrorContaining(result, "Timer.seconds")
            end,
        },
        {
            label = "emission cap sanity",
            effects = {
                { id = OP.multicast, params = { count = 8 } },
                { id = OP.multicast, params = { count = 8 } },
                { id = "firedamage", range = 2 },
            },
            expect_ok = false,
            check = function(result)
                return (not result.ok) and hasErrorContaining(result, "MAX_PROJECTILES_PER_CAST")
            end,
        },
    }

    for _, case in ipairs(cases) do
        local result = parser.parseEffectList(case.effects)
        local ok = case.check(result)
        assertLine(ok, case.label, result and result.errors and result.errors[1] and result.errors[1].message)
    end

    log.info("smoke parser run complete")
end

return {
    engineHandlers = {
        onFrame = function()
            if state.ran then
                return
            end
            state.ran = true
            run()
        end,
        onKeyPress = function(key)
            local symbol = key.symbol and string.lower(key.symbol) or ""
            if symbol == "p" or key.code == input.KEY.P then
                run()
                return false
            end
            return true
        end,
    },
    eventHandlers = {
        [events.BACKEND_READY] = function() end,
    },
}
