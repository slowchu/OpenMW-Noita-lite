local async = require("openmw.async")
local core = require("openmw.core")
local input = require("openmw.input")
local self = require("openmw.self")

local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("player.init")

local state = {
    backend = "INIT",
    handshake_timer = nil,
    unavailable_logged = false,
}

local function firstKnownSpellId()
    for spell_id in pairs(core.magic.spells.records) do
        return spell_id
    end
    return nil
end

local function cancelHandshakeTimer()
    if state.handshake_timer then
        state.handshake_timer:cancel()
        state.handshake_timer = nil
    end
end

local function requestBackend()
    state.backend = "PENDING"
    core.sendGlobalEvent(events.CHECK_BACKEND, {
        sender = self.object,
    })

    cancelHandshakeTimer()
    state.handshake_timer = async:newUnsavableSimulationTimer(3, function()
        if state.backend == "PENDING" then
            state.backend = "UNAVAILABLE"
            if not state.unavailable_logged then
                log.warn("backend handshake timeout after 3 seconds")
                state.unavailable_logged = true
            end
        end
    end)
end

local function compileHardcodedRecipe()
    if state.backend ~= "READY" then
        if not state.unavailable_logged then
            log.warn("compile hotkey ignored: backend not ready")
            state.unavailable_logged = true
        end
        return
    end

    local base_spell_id = firstKnownSpellId()
    if not base_spell_id then
        log.error("compile hotkey failed: no base spell IDs available")
        return
    end

    local request_id = string.format("dev-%d", os.time())
    local recipe = {
        nodes = {
            { kind = "emitter", base_spell_id = base_spell_id },
        },
    }

    core.sendGlobalEvent(events.COMPILE_RECIPE, {
        sender = self.object,
        actor = self,
        actor_id = self.recordId,
        request_id = request_id,
        recipe = recipe,
    })
    log.debug(string.format("compile request sent request_id=%s", request_id))
end

local function onBackendReady(payload)
    cancelHandshakeTimer()
    state.backend = "READY"
    state.unavailable_logged = false
    log.info(string.format("backend ready version=%s", tostring(payload and payload.backend_version)))
end

local function onBackendUnavailable(payload)
    cancelHandshakeTimer()
    state.backend = "UNAVAILABLE"
    if not state.unavailable_logged then
        log.warn(string.format("backend unavailable: %s", tostring(payload and payload.reason)))
        state.unavailable_logged = true
    end
end

local function onCompileResult(payload)
    if payload.ok then
        log.info(string.format("compile success recipe_id=%s spell_id=%s reused=%s", tostring(payload.recipe_id), tostring(payload.spell_id), tostring(payload.reused)))
    else
        log.error(string.format("compile failed request=%s error=%s", tostring(payload.request_id), tostring(payload.error or "validation failed")))
    end
end

local function onKeyPress(key)
    local symbol = key.symbol and string.lower(key.symbol) or ""
    if symbol == "k" or key.code == input.KEY.K then
        log.debug("handled dev compile hotkey")
        compileHardcodedRecipe()
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
        [events.BACKEND_READY] = onBackendReady,
        [events.BACKEND_UNAVAILABLE] = onBackendUnavailable,
        [events.COMPILE_RESULT] = onCompileResult,
    },
}
