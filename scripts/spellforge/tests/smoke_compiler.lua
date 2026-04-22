local async = require("openmw.async")
local core = require("openmw.core")
local input = require("openmw.input")
local self = require("openmw.self")
local types = require("openmw.types")

local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_compiler")

local state = {
    backend = "INIT",
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
        log.warn("tests.smoke_compiler backend not ready")
        return
    end

    local base_spell_id = firstKnownSpellId()
    if not base_spell_id then
        log.error("tests.smoke_compiler no base spell")
        return
    end

    state.running = true
    log.info("tests.smoke_compiler starting")

    local recipe = {
        nodes = {
            { kind = "emitter", base_spell_id = base_spell_id },
        },
    }

    local req = nextRequestId("smoke-compiler")
    compile(recipe, req)
    waitForResult(req, 5, function(result)
        assertLine(result.ok == true, "compiler succeeds")
        assertLine(type(result.spell_id) == "string" and result.spell_id ~= "", "compiler returns engine spell id")
        assertLine(spellbookHasSpell(self, result.spell_id), "frontend marker spell added to spellbook")

        local spell_record = core.magic.spells.records[result.spell_id]
        local effects = spell_record and spell_record.effects or {}
        local marker_only = #effects == 1 and effects[1] and effects[1].id == "spellforge_composed"
        assertLine(marker_only, "compiled spell contains marker effect only")

        log.info("tests.smoke_compiler NOTE: real_effects metadata is stored global-side; validated in runtime dispatch smokes")
        log.info("tests.smoke_compiler complete")
        state.running = false
    end)
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
            log.info("tests.smoke_compiler backend READY")
        end,
        [events.BACKEND_UNAVAILABLE] = function(payload)
            state.backend = "UNAVAILABLE"
            log.warn(string.format("tests.smoke_compiler backend unavailable: %s", tostring(payload and payload.reason)))
        end,
        [events.COMPILE_RESULT] = function(payload)
            local cb = payload and payload.request_id and state.pending[payload.request_id]
            if cb then
                state.pending[payload.request_id] = nil
                cb(payload)
            end
        end,
    },
}
