local async = require("openmw.async")
local core = require("openmw.core")
local input = require("openmw.input")
local self = require("openmw.self")
local types = require("openmw.types")

local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_compiler")

local state = {
    backend = "INIT",
    handshake_timer = nil,
    pending = {},
    running = false,
}

local function assertLine(ok, label)
    if ok then
        log.info("PASS " .. label)
    else
        log.error("FAIL " .. label)
    end
end

local function firstSpellId()
    for spell_id in pairs(core.magic.spells.records) do
        return spell_id
    end
    return nil
end

local function nextRequestId(prefix)
    return string.format("%s-%d", prefix, os.time() + math.random(1, 100000))
end

local function compile(recipe, request_id)
    core.sendGlobalEvent(events.COMPILE_RECIPE, {
        actor = self,
        actor_id = self.recordId,
        recipe = recipe,
        request_id = request_id,
    })
end

local function waitForResult(request_id, timeout_seconds, callback)
    state.pending[request_id] = callback
    async:newUnsavableSimulationTimer(timeout_seconds, function()
        if state.pending[request_id] then
            local cb = state.pending[request_id]
            state.pending[request_id] = nil
            cb({ ok = false, error = "timeout" })
        end
    end)
end

local function runSmoke()
    if state.running then
        log.warn("smoke run already in progress")
        return
    end

    if state.backend ~= "READY" then
        log.warn("smoke run skipped: backend is not READY")
        return
    end

    local base_spell_id = firstSpellId()
    if not base_spell_id then
        log.error("no base spell available; aborting smoke")
        return
    end

    state.running = true
    log.info("starting smoke compiler run")

    local trivial_recipe = {
        nodes = {
            { kind = "emitter", base_spell_id = base_spell_id },
        },
    }

    local multicast_recipe = {
        nodes = {
            { kind = "emitter", base_spell_id = base_spell_id, payload = {
                { opcode = "Multicast", params = { count = 3 } },
                { opcode = "Spread", params = { arc = 90 } },
                { kind = "emitter", base_spell_id = base_spell_id },
            } },
        },
    }

    local invalid_nested_recipe = {
        nodes = {
            { kind = "emitter", base_spell_id = base_spell_id, payload = {
                { opcode = "Trigger" },
                { opcode = "Timer", params = { seconds = 9999 } },
            } },
        },
    }

    local req1 = nextRequestId("smoke-trivial")
    compile(trivial_recipe, req1)
    waitForResult(req1, 3, function(result1)
        assertLine(result1.ok, "trivial recipe compiles")
        assertLine(type(result1.spell_id) == "string" and result1.spell_id ~= "", "trivial compile returns front-end spell_id")
        local spellbook_has = result1.spell_id and types.Actor.spells(self):has(result1.spell_id)
        assertLine(spellbook_has == true, "front-end spell added to spellbook")

        local req2 = nextRequestId("smoke-cache")
        compile(trivial_recipe, req2)
        waitForResult(req2, 3, function(result2)
            assertLine(result2.ok, "identical recipe recompiles")
            assertLine(result1.recipe_id == result2.recipe_id, "identical recipe_id is stable")
            assertLine(result2.reused == true, "identical recipe reuses cache")

            local req3 = nextRequestId("smoke-multicast")
            compile(multicast_recipe, req3)
            waitForResult(req3, 3, function(result3)
                assertLine(result3.ok, "multicast recipe compiles")

                local req4 = nextRequestId("smoke-invalid")
                compile(invalid_nested_recipe, req4)
                waitForResult(req4, 3, function(result4)
                    assertLine(result4.ok == false, "invalid nested-trigger recipe rejected")
                    assertLine(type(result4.errors) == "table" and #result4.errors > 0, "invalid recipe returns readable errors")
                    log.info("smoke compiler run complete")
                    state.running = false
                end)
            end)
        end)
    end)
end

local function requestBackend()
    state.backend = "PENDING"
    core.sendGlobalEvent(events.CHECK_BACKEND, nil)
    state.handshake_timer = async:newUnsavableSimulationTimer(3, function()
        if state.backend == "PENDING" then
            state.backend = "UNAVAILABLE"
            log.warn("backend timeout after 3 seconds")
        end
    end)
end

local function onKeyPress(key)
    local symbol = key.symbol and string.lower(key.symbol) or ""
    if symbol == "u" or key.code == input.KEY.U then
        log.debug("handled smoke hotkey")
        runSmoke()
        return false
    end
    return true
end

return {
    engineHandlers = {
        onFrame = function()
            if state.backend == "INIT" then
                requestBackend()
            end
        end,
        onKeyPress = onKeyPress,
    },
    eventHandlers = {
        [events.BACKEND_READY] = function()
            if state.handshake_timer then
                state.handshake_timer:cancel()
                state.handshake_timer = nil
            end
            state.backend = "READY"
            log.info("backend ready for smoke harness")
        end,
        [events.BACKEND_UNAVAILABLE] = function(payload)
            if state.handshake_timer then
                state.handshake_timer:cancel()
                state.handshake_timer = nil
            end
            state.backend = "UNAVAILABLE"
            log.warn("backend unavailable: " .. tostring(payload and payload.reason))
        end,
        [events.COMPILE_RESULT] = function(payload)
            if not payload or not payload.request_id then
                return
            end
            local cb = state.pending[payload.request_id]
            if not cb then
                return
            end
            state.pending[payload.request_id] = nil
            cb(payload)
        end,
    },
}
