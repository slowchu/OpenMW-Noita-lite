local core = require("openmw.core")
local interfaces = require("openmw.interfaces")

local compiler = require("scripts.spellforge.global.compiler")
local executor = require("scripts.spellforge.global.executor")
local events = require("scripts.spellforge.shared.events")
local records = require("scripts.spellforge.global.records")
local log = require("scripts.spellforge.shared.log").new("global.init")
local did_records_probe = false

local function isBackendReady()
    return interfaces.MagExp ~= nil
end

local function runSpellsRecordsProbe()
    if did_records_probe then
        return
    end
    did_records_probe = true

    local count = 0
    local first_key, first_value
    for k, v in pairs(core.magic.spells.records) do
        count = count + 1
        if count == 1 then
            first_key, first_value = k, v
        end
        if count >= 3 then
            break
        end
    end
    log.info(string.format(
        "spells.records probe: count>=%d first_key_type=%s first_key=%s first_value_type=%s first_value_id=%s",
        count,
        type(first_key),
        tostring(first_key),
        type(first_value),
        tostring(first_value and first_value.id)
    ))

    local probe_id = first_value and first_value.id or "fireball"
    log.info(string.format(
        "spells.records lookup probe: by_string=%s by_int=%s",
        tostring(core.magic.spells.records[probe_id] ~= nil),
        tostring(core.magic.spells.records[1] ~= nil)
    ))
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
    runSpellsRecordsProbe()

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


local function onQuerySpellMetadata(payload)
    local sender = getSender(payload, events.QUERY_SPELL_METADATA)
    if not sender then
        return
    end

    local spell_id = payload and payload.spell_id
    local recipe_id, entry, root = records.findRootNodeByEngineSpellId(spell_id)
    sender:sendEvent(events.QUERY_SPELL_METADATA_RESULT, {
        request_id = payload and payload.request_id,
        spell_id = spell_id,
        is_spellforge = recipe_id ~= nil,
        recipe_id = recipe_id,
        root_base_spell_id = root and root.base_spell_id or nil,
        root_real_effects = root and root.real_effects or nil,
        frontend_spell_id = entry and entry.frontend_spell_id or nil,
    })
end

return {
    eventHandlers = {
        [events.CHECK_BACKEND] = onCheckBackend,
        [events.COMPILE_RECIPE] = onCompileRecipe,
        [events.DELETE_COMPILED] = onDeleteCompiled,
        [events.QUERY_SPELL_METADATA] = onQuerySpellMetadata,
        [events.CAST_REQUEST] = executor.onCastRequest,
        [events.INTERCEPT_CAST] = executor.onInterceptCast,
        [events.DEBUG_LAUNCH_VANILLA_FIREBALL] = executor.onDebugLaunchVanillaFireball,
        [events.BEGIN_CAST_OBSERVE] = executor.onBeginObserve,
        [events.CAST_DIAG_SIGNAL] = executor.onCastDiagSignal,
        MagExp_OnMagicHit = executor.onMagicHit,
    },
    engineHandlers = {
        -- OpenMW engine handlers docs (global scripts): onPlayerAdded/onUpdate are documented;
        -- there is no documented global onSpellCast handler.
        -- https://openmw.readthedocs.io/en/latest/reference/lua-scripting/engine_handlers.html
        onPlayerAdded = executor.onPlayerAdded,
        onUpdate = executor.onUpdate,
    },
}
