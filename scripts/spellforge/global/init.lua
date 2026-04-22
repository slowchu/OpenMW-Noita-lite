local core = require("openmw.core")
local interfaces = require("openmw.interfaces")

local compiler = require("scripts.spellforge.global.compiler")
local events = require("scripts.spellforge.shared.events")
local records = require("scripts.spellforge.global.records")
local log = require("scripts.spellforge.shared.log").new("global.init")

local function isBackendReady()
    return interfaces.MagExp ~= nil
end

local function getSender(payload, event_name)
    if not payload or not payload.sender then
        log.error(string.format("%s missing payload.sender", event_name))
        return nil
    end
    if type(payload.sender.sendEvent) ~= "function" then
        log.error(string.format("%s payload.sender is not event-capable actor", event_name))
        return nil
    end
    return payload.sender
end

local function onCheckBackend(payload)
    local sender = getSender(payload, events.CHECK_BACKEND)
    if not sender then
        return
    end

    if isBackendReady() then
        sender:sendEvent(events.BACKEND_READY, { backend_version = "sfp-unknown" })
        log.info("backend handshake ready")
    else
        sender:sendEvent(events.BACKEND_UNAVAILABLE, { reason = "Spell Framework Plus (I.MagExp) missing" })
        log.warn("backend handshake unavailable")
    end
end

local function onCompileRecipe(payload)
    local sender = getSender(payload, events.COMPILE_RECIPE)
    if not sender then
        return
    end

    if not isBackendReady() then
        sender:sendEvent(events.COMPILE_RESULT, {
            request_id = payload and payload.request_id,
            ok = false,
            error = "Backend unavailable",
        })
        return
    end

    local result = compiler.handleCompileEvent(payload or {})
    sender:sendEvent(events.COMPILE_RESULT, result)
end

local function onDeleteCompiled(payload)
    local deleted = false
    if payload and payload.recipe_id then
        records.put(payload.recipe_id, nil)
        deleted = true
    elseif payload and payload.spell_id then
        deleted = records.deleteBySpellId(payload.spell_id)
    end

    log.info(string.format("delete request handled deleted=%s", tostring(deleted)))
end

return {
    eventHandlers = {
        [events.CHECK_BACKEND] = onCheckBackend,
        [events.COMPILE_RECIPE] = onCompileRecipe,
        [events.DELETE_COMPILED] = onDeleteCompiled,
    },
}
