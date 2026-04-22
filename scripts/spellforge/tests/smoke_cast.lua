local async = require("openmw.async")
local core = require("openmw.core")
local input = require("openmw.input")
local interfaces = require("openmw.interfaces")
local self = require("openmw.self")
local types = require("openmw.types")

local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_cast")

local state = {
    backend = "INIT",
    handshake_timer = nil,
    pending_compile = {},
    pending_observe = {},
    running = false,
    last_spell_id = nil,
    animation_diag_registered = false,
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
        actor_id = self.recordId,
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

local function castRequest(spell_id, request_id)
    core.sendGlobalEvent(events.CAST_REQUEST, {
        sender = self.object,
        actor = self,
        spell_id = spell_id,
        request_id = request_id,
    })
end

local function waitForCompile(request_id, timeout_seconds, callback)
    state.pending_compile[request_id] = callback
    async:newUnsavableSimulationTimer(timeout_seconds, function()
        if state.pending_compile[request_id] then
            local cb = state.pending_compile[request_id]
            state.pending_compile[request_id] = nil
            cb({ ok = false, error = "compile timeout" })
        end
    end)
end

local function waitForObserve(request_id, timeout_seconds, callback)
    state.pending_observe[request_id] = callback
    async:newUnsavableSimulationTimer(timeout_seconds, function()
        if state.pending_observe[request_id] then
            local cb = state.pending_observe[request_id]
            state.pending_observe[request_id] = nil
            cb({ ok = false, error = "hit timeout" })
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
        log.warn("smoke cast run already in progress")
        return
    end
    if state.backend ~= "READY" then
        log.warn("smoke cast skipped: backend is not READY")
        return
    end

    local base_spell_id = firstKnownSpellId()
    if not base_spell_id then
        log.error("no base spell available; aborting smoke cast")
        return
    end

    state.running = true
    log.info("starting smoke cast run")

    local trivial_recipe = {
        nodes = {
            { kind = "emitter", base_spell_id = base_spell_id },
        },
    }

    local compile_request_id = nextRequestId("smoke-cast-compile")
    compile(trivial_recipe, compile_request_id)
    waitForCompile(compile_request_id, 5, function(compile_result)
        assertLine(compile_result.ok == true, "trivial cast recipe compiles")
        if not compile_result.ok then
            log.error(string.format("  cause[compile]: %s", tostring(compile_result.error)))
            state.running = false
            return
        end

        local has_spell_id = type(compile_result.spell_id) == "string" and compile_result.spell_id ~= ""
        assertLine(has_spell_id, "compile returns front-end engine spell_id")
        if not has_spell_id then
            state.running = false
            return
        end

        local in_spellbook = spellbookHasSpell(self, compile_result.spell_id)
        assertLine(in_spellbook, "compiled spell appears in player spellbook")
        state.last_spell_id = compile_result.spell_id

        local observe_request_id = nextRequestId("smoke-cast-observe")
        beginObserve(compile_result.spell_id, observe_request_id)

        local cast_request_id = nextRequestId("smoke-cast-launch")
        castRequest(compile_result.spell_id, cast_request_id)
        log.info("manual cast fallback: select the compiled spell and cast within 30s (or press I to fire launchSpell request again)")

        waitForObserve(observe_request_id, 30, function(hit_result)
            local ok = hit_result.ok == true and hit_result.matched == true
            assertLine(ok, "MagExp_OnMagicHit observed for compiled spell")
            if not ok then
                log.error(string.format("  cause[observe]: %s", tostring(hit_result.error or "timeout/no matching hit")))
                log.error("  hint: cast the compiled spell manually, then check global.executor MagExp_OnMagicHit logs")
            end
            log.info("smoke cast run complete")
            state.running = false
        end)
    end)
end

local function registerAnimationDiagnostics()
    if state.animation_diag_registered then
        return
    end
    if interfaces.AnimationController == nil or type(interfaces.AnimationController.addTextKeyHandler) ~= "function" then
        log.warn("animation diagnostics unavailable: AnimationController.addTextKeyHandler missing")
        return
    end

    -- OpenMW interface docs: addTextKeyHandler can observe spellcast release text keys.
    -- https://openmw.readthedocs.io/en/latest/reference/lua-scripting/interface_animation.html
    interfaces.AnimationController.addTextKeyHandler("spellcast", function(groupname, key)
        log.info(string.format("local animation text key group=%s key=%s", tostring(groupname), tostring(key)))
        core.sendGlobalEvent(events.CAST_DIAG_SIGNAL, {
            sender = self.object,
            groupname = groupname,
            key = key,
            selected_spell_id = state.last_spell_id,
        })
    end)
    state.animation_diag_registered = true
    log.info("registered local spellcast text-key diagnostics")
end

local function requestBackend()
    state.backend = "PENDING"
    core.sendGlobalEvent(events.CHECK_BACKEND, {
        sender = self.object,
    })
    state.handshake_timer = async:newUnsavableSimulationTimer(3, function()
        if state.backend == "PENDING" then
            state.backend = "UNAVAILABLE"
            log.warn("backend timeout after 3 seconds")
        end
    end)
end

local function onKeyPress(key)
    local symbol = key.symbol and string.lower(key.symbol) or ""
    if symbol == "o" or key.code == input.KEY.O then
        runSmoke()
        return false
    end
    if symbol == "i" or key.code == input.KEY.I then
        if state.last_spell_id then
            castRequest(state.last_spell_id, nextRequestId("smoke-cast-launch-manual"))
            log.info(string.format("manual launch request dispatched spell_id=%s", tostring(state.last_spell_id)))
        else
            log.warn("manual launch request ignored: no compiled spell_id in state")
        end
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
                state.handshake_timer:stop()
                state.handshake_timer = nil
            end
            state.backend = "READY"
            log.info("backend READY")
            registerAnimationDiagnostics()
        end,
        [events.BACKEND_UNAVAILABLE] = function(payload)
            if state.handshake_timer then
                state.handshake_timer:stop()
                state.handshake_timer = nil
            end
            state.backend = "UNAVAILABLE"
            log.warn(string.format("backend unavailable: %s", tostring(payload and payload.reason)))
        end,
        [events.COMPILE_RESULT] = function(payload)
            local request_id = payload and payload.request_id
            local cb = request_id and state.pending_compile[request_id]
            if cb then
                state.pending_compile[request_id] = nil
                cb(payload)
            end
        end,
        [events.CAST_OBSERVE_RESULT] = function(payload)
            local request_id = payload and payload.request_id
            if request_id and state.pending_observe[request_id] and payload and payload.ok == false then
                local cb = state.pending_observe[request_id]
                state.pending_observe[request_id] = nil
                cb({ ok = false, error = payload.error or "observe failed" })
            end
        end,
        [events.CAST_HIT_OBSERVED] = function(payload)
            local request_id = payload and payload.request_id
            local cb = request_id and state.pending_observe[request_id]
            if cb then
                state.pending_observe[request_id] = nil
                cb({ ok = true, matched = payload and payload.matched == true })
            end
        end,
    },
}
