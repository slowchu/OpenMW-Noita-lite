local async = require("openmw.async")
local core = require("openmw.core")
local input = require("openmw.input")
local self = require("openmw.self")
local types = require("openmw.types")

local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_cast")

local state = {
    backend = "INIT",
    pending_compile = {},
    pending_observe = {},
    running = false,
}

local function assertLine(ok, label)
    if ok then
        log.info("PASS " .. label)
    else
        log.error("FAIL " .. label)
    end
end

local function firstKnownSpellId()
    for _, record in pairs(core.magic.spells.records) do
        if record and type(record.id) == "string" and record.id ~= "" then
            return record.id
        end
    end
    return nil
end

local function nextRequestId(prefix)
    return string.format("%s-%d", prefix, os.time() + math.random(1, 100000))
end

local function compile(recipe, request_id)
    core.sendGlobalEvent(events.COMPILE_RECIPE, {
        sender = self.object,
        actor = self,
        recipe = recipe,
        request_id = request_id,
    })
end

local function beginObserve(spell_id, request_id)
    core.sendGlobalEvent(events.BEGIN_CAST_OBSERVE, {
        sender = self.object,
        spell_id = spell_id,
        request_id = request_id,
        timeout_seconds = 30,
    })
end

local function waitFor(table_ref, request_id, timeout_seconds, callback, timeout_message)
    table_ref[request_id] = callback
    async:newUnsavableSimulationTimer(timeout_seconds, function()
        if table_ref[request_id] then
            local cb = table_ref[request_id]
            table_ref[request_id] = nil
            cb({ ok = false, error = timeout_message })
        end
    end)
end

local function spellbookHasSpell(actor, spell_id)
    local actor_spells = types.Actor.spells(actor)
    for _, entry in pairs(actor_spells) do
        if entry and entry.id == spell_id then
            return true
        end
    end
    return false
end

local function runSmoke()
    if state.running then
        return
    end
    if state.backend ~= "READY" then
        log.warn("tests.smoke_cast backend not ready")
        return
    end

    local base_spell_id = firstKnownSpellId()
    if not base_spell_id then
        log.error("tests.smoke_cast no base spell")
        return
    end

    state.running = true
    log.info("tests.smoke_cast starting")

    local recipe = {
        nodes = {
            { kind = "emitter", base_spell_id = base_spell_id },
        },
    }

    local compile_request_id = nextRequestId("smoke-cast-compile")
    compile(recipe, compile_request_id)
    waitFor(state.pending_compile, compile_request_id, 5, function(compile_result)
        assertLine(compile_result.ok == true, "single-emitter recipe compiles")
        if not compile_result.ok then
            state.running = false
            return
        end

        assertLine(spellbookHasSpell(self, compile_result.spell_id), "compiled marker spell in spellbook")

        local observe_request_id = nextRequestId("smoke-cast-observe")
        beginObserve(compile_result.spell_id, observe_request_id)
        log.info("tests.smoke_cast ACTION: select compiled spell and cast within 30s")

        waitFor(state.pending_observe, observe_request_id, 30, function(hit_result)
            local ok = hit_result.ok == true and hit_result.matched == true
            assertLine(ok, "MagExp_OnMagicHit observed for intercepted cast")
            if not ok then
                log.error(string.format("DIAG %s", tostring(hit_result.error or "no matching hit")))
            end
            log.info("tests.smoke_cast complete")
            state.running = false
        end, "hit timeout")
    end, "compile timeout")
end

return {
    engineHandlers = {
        onFrame = function()
            if state.backend == "INIT" then
                state.backend = "PENDING"
                core.sendGlobalEvent(events.CHECK_BACKEND, { sender = self.object })
            end
        end,
        onKeyPress = function(key)
            local symbol = key.symbol and string.lower(key.symbol) or ""
            if symbol == "o" or key.code == input.KEY.O then
                runSmoke()
                return false
            end
            return true
        end,
    },
    eventHandlers = {
        [events.BACKEND_READY] = function()
            state.backend = "READY"
            log.info("tests.smoke_cast backend READY")
        end,
        [events.BACKEND_UNAVAILABLE] = function(payload)
            state.backend = "UNAVAILABLE"
            log.warn(string.format("tests.smoke_cast backend unavailable: %s", tostring(payload and payload.reason)))
        end,
        [events.COMPILE_RESULT] = function(payload)
            local cb = payload and payload.request_id and state.pending_compile[payload.request_id]
            if cb then
                state.pending_compile[payload.request_id] = nil
                cb(payload)
            end
        end,
        [events.CAST_OBSERVE_RESULT] = function(payload)
            if payload and payload.ok == false then
                local cb = payload.request_id and state.pending_observe[payload.request_id]
                if cb then
                    state.pending_observe[payload.request_id] = nil
                    cb({ ok = false, error = payload.error or "observe failed" })
                end
            end
        end,
        [events.CAST_HIT_OBSERVED] = function(payload)
            local cb = payload and payload.request_id and state.pending_observe[payload.request_id]
            if cb then
                state.pending_observe[payload.request_id] = nil
                cb({ ok = true, matched = payload.matched == true })
            end
        end,
    },
}
