local dev = require("scripts.spellforge.shared.dev")
local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("global.sfp_smoke")
local projectile_registry = require("scripts.spellforge.global.projectile_registry")
local sfp_adapter = require("scripts.spellforge.global.sfp_adapter")

local sfp_smoke = {}

local pending_spell_state = {}

local function send(sender, event_name, payload)
    if sender and type(sender.sendEvent) == "function" then
        sender:sendEvent(event_name, payload)
    end
end

local function enabled()
    return dev.smokeTestsEnabled() and dev.devLaunchEnabled()
end

local function disabledResponse(payload, event_name, message)
    send(payload and payload.sender or nil, event_name, {
        request_id = payload and payload.request_id or nil,
        ok = false,
        error = message,
    })
end

local function capabilityPayload(request_id)
    local capabilities = sfp_adapter.capabilities()
    local payload = {
        request_id = request_id,
        ok = true,
        capabilities = capabilities,
        has_launchSpell = capabilities.has_launchSpell,
        has_getSpellState = capabilities.has_getSpellState,
        has_emitProjectileFromObject = capabilities.has_emitProjectileFromObject,
        has_detonateSpellAtPos = capabilities.has_detonateSpellAtPos,
        has_applySpellToActor = capabilities.has_applySpellToActor,
    }
    if capabilities.has_getActiveSpellIds then
        local active = sfp_adapter.getActiveSpellIds()
        payload.getActiveSpellIds_ok = active.ok == true
        if active.ok and type(active.result) == "table" then
            local count = 0
            for _ in pairs(active.result) do
                count = count + 1
            end
            payload.active_spell_id_count = count
        end
        payload.getActiveSpellIds_error = active.ok and nil or active.error
    end
    return payload
end

function sfp_smoke.onCapabilitiesRequest(payload)
    if not enabled() then
        disabledResponse(payload, events.SFP_CAPABILITIES_RESULT, "SFP smoke disabled")
        return
    end
    send(payload and payload.sender or nil, events.SFP_CAPABILITIES_RESULT, capabilityPayload(payload and payload.request_id or nil))
end

function sfp_smoke.onSpellStateRequest(payload)
    if not enabled() then
        disabledResponse(payload, events.SFP_SPELL_STATE_RESULT, "SFP smoke disabled")
        return
    end

    local sender = payload and payload.sender or nil
    local request_id = payload and payload.request_id or nil
    local projectile_id = payload and payload.projectile_id or nil
    local capabilities = sfp_adapter.capabilities()
    if not capabilities.has_getSpellState then
        send(sender, events.SFP_SPELL_STATE_RESULT, {
            request_id = request_id,
            ok = true,
            capability = false,
            skipped = true,
            projectile_id = projectile_id,
            error = "I.MagExp.getSpellState missing",
        })
        return
    end
    if projectile_id == nil then
        send(sender, events.SFP_SPELL_STATE_RESULT, {
            request_id = request_id,
            ok = true,
            capability = false,
            skipped = true,
            error = "projectile_id unavailable",
        })
        return
    end

    local tag = tostring(request_id or ("spellforge_sfp_state_" .. tostring(projectile_id)))
    pending_spell_state[tag] = {
        sender = sender,
        request_id = request_id,
        projectile_id = projectile_id,
    }

    local requested = sfp_adapter.requestSpellState(projectile_id, tag)
    if not requested.ok then
        pending_spell_state[tag] = nil
        send(sender, events.SFP_SPELL_STATE_RESULT, {
            request_id = request_id,
            ok = false,
            capability = requested.capability == true,
            projectile_id = projectile_id,
            error = requested.error,
        })
    end
end

function sfp_smoke.onSpellState(payload)
    local tag = payload and payload.tag or nil
    local pending = tag and pending_spell_state[tag] or nil
    if not pending then
        return
    end
    pending_spell_state[tag] = nil

    projectile_registry.markState(pending.projectile_id, payload)
    send(pending.sender, events.SFP_SPELL_STATE_RESULT, {
        request_id = pending.request_id,
        ok = true,
        capability = true,
        projectile_id = pending.projectile_id,
        state_position = payload and payload.position or nil,
        state_direction = payload and payload.direction or nil,
        state_velocity = payload and payload.velocity or nil,
        state_speed = payload and payload.speed or nil,
        state_spellId = payload and payload.spellId or nil,
        state_isPaused = payload and payload.isPaused or nil,
        state_lifetime = payload and payload.lifetime or nil,
        state_maxLifetime = payload and payload.maxLifetime or nil,
        state_bounceCount = payload and payload.bounceCount or nil,
        has_position = payload and payload.position ~= nil,
        has_direction = payload and payload.direction ~= nil,
        has_velocity = payload and payload.velocity ~= nil,
        has_speed = payload and payload.speed ~= nil,
        has_spellId = payload and payload.spellId ~= nil,
        has_isPaused = payload and payload.isPaused ~= nil,
        has_lifetime = payload and payload.lifetime ~= nil,
        has_maxLifetime = payload and payload.maxLifetime ~= nil,
        has_bounceCount = payload and payload.bounceCount ~= nil,
    })
end

function sfp_smoke.onEmitObjectProbeRequest(payload)
    if not enabled() then
        disabledResponse(payload, events.SFP_EMIT_OBJECT_PROBE_RESULT, "SFP smoke disabled")
        return
    end

    local capabilities = sfp_adapter.capabilities()
    send(payload and payload.sender or nil, events.SFP_EMIT_OBJECT_PROBE_RESULT, {
        request_id = payload and payload.request_id or nil,
        ok = true,
        capability = capabilities.has_emitProjectileFromObject,
        skipped = true,
        reason = capabilities.has_emitProjectileFromObject
            and "emitProjectileFromObject wrapper present; no controlled non-actor source supplied"
            or "I.MagExp.emitProjectileFromObject missing",
    })
    log.debug("emitProjectileFromObject probe completed without launching gameplay projectiles")
end

return sfp_smoke
