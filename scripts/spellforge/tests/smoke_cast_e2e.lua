local async = require("openmw.async")
local core = require("openmw.core")
local input = require("openmw.input")
local self = require("openmw.self")
local types = require("openmw.types")

local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_cast_e2e")

local state = {
    backend = "INIT",
    pending_compile = {},
    pending_observe = {},
    running = false,
    root_seen = false,
    payload_seen = false,
}

local function line(ok, text)
    if ok then
        log.info("PASS " .. text)
    else
        log.error("FAIL " .. text)
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

local function waitForResult(table_ref, request_id, timeout, cb)
    table_ref[request_id] = cb
    async:newUnsavableSimulationTimer(timeout, function()
        if table_ref[request_id] then
            local callback = table_ref[request_id]
            table_ref[request_id] = nil
            callback({ ok = false, error = "timeout" })
        end
    end)
end

local function run()
    if state.running then
        return
    end
    if state.backend ~= "READY" then
        log.warn("tests.smoke_cast_e2e backend not ready")
        return
    end

    local base_spell_id = firstKnownSpellId()
    if not base_spell_id then
        log.error("tests.smoke_cast_e2e no base spell")
        return
    end

    state.running = true
    state.root_seen = false
    state.payload_seen = false

    local recipe = {
        nodes = {
            {
                kind = "emitter",
                base_spell_id = base_spell_id,
                payload = {
                    {
                        opcode = "Trigger",
                        payload = {
                            { kind = "terminal", base_spell_id = base_spell_id },
                        },
                    },
                },
            },
        },
    }

    local req = string.format("e2e-compile-%d", os.time())
    core.sendGlobalEvent(events.COMPILE_RECIPE, {
        sender = self.object,
        actor = self,
        request_id = req,
        recipe = recipe,
    })

    waitForResult(state.pending_compile, req, 5, function(res)
        line(res.ok == true, "recipe with Trigger payload compiles")
        if not res.ok then
            state.running = false
            return
        end

        local has_spell = false
        for _, entry in pairs(types.Actor.spells(self)) do
            if entry and entry.id == res.spell_id then
                has_spell = true
            end
        end
        line(has_spell, "compiled spell present in spellbook")

        local observe_id = string.format("e2e-observe-%d", os.time())
        core.sendGlobalEvent(events.BEGIN_CAST_OBSERVE, {
            sender = self.object,
            spell_id = res.spell_id,
            request_id = observe_id,
            timeout_seconds = 30,
        })

        log.info("tests.smoke_cast_e2e ACTION: cast compiled spell now (waits 30s)")
        waitForResult(state.pending_observe, observe_id, 30, function(hit_res)
            line(state.root_seen == true, "observed root hit")
            line(state.payload_seen == true, "observed payload detonation hit")
            local pass = state.root_seen and state.payload_seen and hit_res.ok ~= false
            line(pass, "e2e cast -> root hit -> payload hit")
            if not pass then
                log.error(string.format("DIAG root_seen=%s payload_seen=%s observe_error=%s", tostring(state.root_seen), tostring(state.payload_seen), tostring(hit_res.error)))
            end
            state.running = false
        end)
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
            if symbol == "p" or key.code == input.KEY.P then
                run()
                return false
            end
            return true
        end,
    },
    eventHandlers = {
        [events.BACKEND_READY] = function()
            state.backend = "READY"
            log.info("tests.smoke_cast_e2e backend READY")
        end,
        [events.BACKEND_UNAVAILABLE] = function(payload)
            state.backend = "UNAVAILABLE"
            log.warn(string.format("tests.smoke_cast_e2e backend unavailable: %s", tostring(payload and payload.reason)))
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
                    cb({ ok = false, error = payload.error })
                end
            end
        end,
        [events.CAST_HIT_OBSERVED] = function(payload)
            if payload and payload.matched then
                if not state.root_seen then
                    state.root_seen = true
                else
                    state.payload_seen = true
                end
            end
            local cb = payload and payload.request_id and state.pending_observe[payload.request_id]
            if cb and state.root_seen and state.payload_seen then
                state.pending_observe[payload.request_id] = nil
                cb({ ok = true })
            end
        end,
    },
}
