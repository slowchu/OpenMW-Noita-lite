local async = require("openmw.async")
local camera = require("openmw.camera")
local core = require("openmw.core")
local input = require("openmw.input")
local nearby = require("openmw.nearby")
local self = require("openmw.self")
local util = require("openmw.util")

local dev = require("scripts.spellforge.shared.dev")
local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_sfp_projectile_state")

local state = {
    backend = "INIT",
    handshake_timer = nil,
    running = false,
    skip_logged = false,
    ready_logged = false,
    pending_capabilities = {},
    pending_launch = {},
    pending_spell_state = {},
    pending_emit_probe = {},
    pending_hit = {},
    capabilities = nil,
    state_done = false,
    hit_done = false,
    expected_recipe_id = nil,
    expected_slot_id = nil,
    expected_helper_engine_id = nil,
}

local function assertLine(ok, label, detail)
    if ok then
        log.info("PASS " .. label)
    else
        log.error("FAIL " .. label .. (detail and (" detail: " .. tostring(detail)) or ""))
    end
end

local function skipLine(label, detail)
    log.info("SKIP " .. label .. (detail and (": " .. tostring(detail)) or ""))
end

local function nextRequestId(prefix)
    return string.format("%s-%d", prefix, os.time() + math.random(1, 100000))
end

local function clearTimer()
    if state.handshake_timer then
        state.handshake_timer:cancel()
        state.handshake_timer = nil
    end
end

local function waitFor(map, request_id, timeout_seconds, callback)
    map[request_id] = callback
    async:newUnsavableSimulationTimer(timeout_seconds, function()
        if map[request_id] then
            local cb = map[request_id]
            map[request_id] = nil
            cb({ ok = false, error = "timeout", timeout = true })
        end
    end)
end

local function requestBackend()
    if not dev.smokeTestsEnabled() then
        return
    end
    state.backend = "PENDING"
    core.sendGlobalEvent(events.CHECK_BACKEND, {
        sender = self.object,
    })
    clearTimer()
    state.handshake_timer = async:newUnsavableSimulationTimer(3, function()
        if state.backend == "PENDING" then
            state.backend = "UNAVAILABLE"
            log.warn("backend timeout after 3 seconds")
        end
    end)
end

local function currentLaunchAim()
    local cp = -camera.getPitch()
    local cy = camera.getYaw()
    local direction = util.vector3(
        math.cos(cp) * math.sin(cy),
        math.cos(cp) * math.cos(cy),
        math.sin(cp)
    )
    local start_pos = camera.getPosition()
    local hit_object = nil
    local ray = nearby.castRay(start_pos, start_pos + (direction * 2000), { ignore = self })
    if ray and ray.hit and ray.hitObject then
        hit_object = ray.hitObject
    end
    return start_pos, direction, hit_object
end

local function boolText(value)
    if value == true then
        return "true"
    elseif value == false then
        return "false"
    end
    return "nil"
end

local function maybeComplete()
    if state.state_done and state.hit_done then
        log.info("smoke SFP projectile state/telemetry run complete")
        state.running = false
    end
end

local function requestCapabilities()
    local request_id = nextRequestId("smoke-sfp-caps")
    waitFor(state.pending_capabilities, request_id, 3, function(result)
        assertLine(result and result.ok == true, "SFP capability probe returned", result and result.error)
        if result and result.ok == true then
            state.capabilities = result.capabilities or {}
            assertLine(state.capabilities.has_launchSpell == true, "SFP launchSpell capability available")
            if state.capabilities.has_getActiveSpellIds == true then
                assertLine(result.getActiveSpellIds_ok == true, "getActiveSpellIds probe returned", result.getActiveSpellIds_error)
            end
            log.info(string.format(
                "SFP capabilities launch=%s projectile_state=%s active_ids=%s emit_object=%s detonate_at_pos=%s apply_actor=%s",
                boolText(state.capabilities.has_launchSpell),
                boolText(state.capabilities.has_getSpellState),
                tostring(result.active_spell_id_count),
                boolText(state.capabilities.has_emitProjectileFromObject),
                boolText(state.capabilities.has_detonateSpellAtPos),
                boolText(state.capabilities.has_applySpellToActor)
            ))
        end
    end)
    core.sendGlobalEvent(events.SFP_CAPABILITIES_REQUEST, {
        sender = self.object,
        request_id = request_id,
    })
end

local function requestEmitObjectProbe()
    local request_id = nextRequestId("smoke-sfp-emit-object")
    waitFor(state.pending_emit_probe, request_id, 3, function(result)
        assertLine(result and result.ok == true, "emitProjectileFromObject capability probe returned", result and result.error)
        if result and result.ok == true then
            assertLine(type(result.capability) == "boolean", "emitProjectileFromObject capability is reported")
            skipLine("emitProjectileFromObject gameplay probe", tostring(result.reason))
        end
    end)
    core.sendGlobalEvent(events.SFP_EMIT_OBJECT_PROBE_REQUEST, {
        sender = self.object,
        request_id = request_id,
    })
end

local function requestSpellState(projectile_id)
    if not projectile_id then
        skipLine("getSpellState", "projectile_id unavailable")
        state.state_done = true
        maybeComplete()
        return
    end
    if state.capabilities and state.capabilities.has_getSpellState ~= true then
        skipLine("getSpellState", "capability unavailable")
        state.state_done = true
        maybeComplete()
        return
    end

    local request_id = nextRequestId("smoke-sfp-state")
    waitFor(state.pending_spell_state, request_id, 4, function(result)
        assertLine(result and result.ok == true, "getSpellState response returned", result and result.error)
        if result and result.ok == true and result.capability == true then
            assertLine(result.has_position == true, "getSpellState returns position, if capability available")
            assertLine(result.has_spellId == true or result.has_velocity == true or result.has_direction == true, "getSpellState returns useful projectile fields")
            assertLine(projectile_id == result.projectile_id, "projectile_id maps to recipe_id + slot_id")
        elseif result and result.skipped then
            skipLine("getSpellState", result.error)
        end
        state.state_done = true
        maybeComplete()
    end)
    core.sendGlobalEvent(events.SFP_SPELL_STATE_REQUEST, {
        sender = self.object,
        request_id = request_id,
        projectile_id = projectile_id,
    })
end

local function checkTelemetry(hit)
    assertLine(hit and hit.ok == true, "helper hit routing still works", hit and hit.error)
    local mapped = hit and hit.ok == true
        and hit.recipe_id == state.expected_recipe_id
        and hit.slot_id == state.expected_slot_id
        and hit.helper_engine_id == state.expected_helper_engine_id
    assertLine(mapped, "helper hit routes to expected recipe_id + slot_id")
    if hit.hit_user_data_present == true then
        assertLine(hit.route_source == "userData", "helper hit routing preferred SFP userData")
        assertLine(hit.hit_user_data_schema == "spellforge_sfp_userdata_v1", "hit userData schema is Spellforge v1")
        assertLine(hit.hit_user_data_recipe_id == state.expected_recipe_id, "hit userData carries expected recipe_id")
        assertLine(hit.hit_user_data_slot_id == state.expected_slot_id, "hit userData carries expected slot_id")
        assertLine(hit.hit_user_data_helper_engine_id == state.expected_helper_engine_id, "hit userData carries expected helper_engine_id")
    else
        skipLine("helper hit routing preferred SFP userData", "SFP did not echo userData; spellId fallback was used")
    end

    if not hit or hit.telemetry_has_beta2_fields ~= true then
        skipLine("MagicHit telemetry captured", "Beta2 telemetry fields absent")
        return
    end

    assertLine(type(hit.impactSpeed) == "number" or hit.impactSpeed == nil, "MagicHit impactSpeed is nil-safe number")
    assertLine(type(hit.maxSpeed) == "number" or hit.maxSpeed == nil, "MagicHit maxSpeed is nil-safe number")
    assertLine(type(hit.magMin) == "number" or hit.magMin == nil, "MagicHit magMin is nil-safe number")
    assertLine(type(hit.magMax) == "number" or hit.magMax == nil, "MagicHit magMax is nil-safe number")
    assertLine(type(hit.casterLinked) == "boolean" or hit.casterLinked == nil, "MagicHit casterLinked is nil-safe boolean")
    assertLine(hit.velocity ~= nil or hit.velocity == nil, "MagicHit velocity is nil-safe")
    log.info(string.format(
        "MagicHit telemetry impactSpeed=%s maxSpeed=%s magMin=%s magMax=%s casterLinked=%s projectile_id=%s",
        tostring(hit.impactSpeed),
        tostring(hit.maxSpeed),
        tostring(hit.magMin),
        tostring(hit.magMax),
        tostring(hit.casterLinked),
        tostring(hit.projectile_id)
    ))
end

local function runSmoke()
    if not dev.smokeTestsEnabled() then
        return
    end
    if not dev.devLaunchEnabled() then
        log.info(string.format("SKIP smoke SFP projectile state: enable %s", dev.devLaunchSettingKey()))
        return
    end
    if state.running then
        log.warn("smoke SFP projectile state already in progress")
        return
    end
    if state.backend ~= "READY" then
        log.warn("smoke SFP projectile state skipped: backend is not READY")
        return
    end

    log.info("smoke SFP projectile state hotkey accepted")
    state.running = true
    state.state_done = false
    state.hit_done = false
    state.expected_recipe_id = nil
    state.expected_slot_id = nil
    state.expected_helper_engine_id = nil

    requestCapabilities()
    requestEmitObjectProbe()

    local start_pos, direction, hit_object = currentLaunchAim()
    local launch_request_id = nextRequestId("smoke-sfp-launch")
    waitFor(state.pending_launch, launch_request_id, 5, function(result)
        assertLine(result and result.ok == true, "dev launch simple emitter request ok", result and result.error)
        if not result or result.ok ~= true then
            state.running = false
            return
        end

        state.expected_recipe_id = result.recipe_id
        state.expected_slot_id = result.slot_id
        state.expected_helper_engine_id = result.helper_engine_id
        assertLine(result.launch_user_data_present == true, "helper launch attached Spellforge userData")
        assertLine(result.launch_user_data_schema == "spellforge_sfp_userdata_v1", "launch userData schema is Spellforge v1")
        assertLine(result.launch_user_data_recipe_id == result.recipe_id, "launch userData carries recipe_id")
        assertLine(result.launch_user_data_slot_id == result.slot_id, "launch userData carries slot_id")
        assertLine(result.launch_user_data_helper_engine_id == result.helper_engine_id, "launch userData carries helper_engine_id")

        if result.launch_returned_projectile == true then
            assertLine(true, "SFP launch returned projectile handle")
        else
            skipLine("SFP launch returned projectile handle", "older SFP or nil return")
        end
        if result.projectile_id then
            assertLine(result.projectile_registered == true, "projectile_id maps to recipe_id + slot_id")
        else
            skipLine("projectile_id maps to recipe_id + slot_id", "projectile_id unavailable")
        end

        requestSpellState(result.projectile_id)
        log.info("manual hit required: aim at a valid target/surface; waiting for MagicHit telemetry")
        waitFor(state.pending_hit, launch_request_id, 30, function(hit)
            checkTelemetry(hit)
            state.hit_done = true
            maybeComplete()
        end)
    end)

    core.sendGlobalEvent(events.DEV_LAUNCH_SIMPLE_EMITTER, {
        sender = self.object,
        actor = self,
        request_id = launch_request_id,
        timeout_seconds = 30,
        start_pos = start_pos,
        direction = direction,
        hit_object = hit_object,
    })
end

local function onKeyPress(key)
    if not dev.smokeTestsEnabled() then
        return true
    end
    local symbol = key.symbol and string.lower(key.symbol) or ""
    if symbol == "j" or key.code == input.KEY.J then
        if not dev.devLaunchEnabled() then
            log.info(string.format("SKIP smoke SFP projectile state: enable %s", dev.devLaunchSettingKey()))
            return true
        end
        runSmoke()
        return false
    end
    return true
end

return {
    engineHandlers = {
        onFrame = function()
            if not dev.smokeTestsEnabled() then
                return
            end
            if not dev.devLaunchEnabled() then
                if not state.skip_logged then
                    state.skip_logged = true
                    log.info(string.format("SKIP smoke SFP projectile state: enable %s", dev.devLaunchSettingKey()))
                end
                return
            end
            if state.backend == "INIT" then
                requestBackend()
            elseif state.backend == "READY" and not state.ready_logged then
                state.ready_logged = true
                log.info("smoke SFP projectile state ready: aim at a valid target/surface and press J")
            end
        end,
        onKeyPress = onKeyPress,
    },
    eventHandlers = {
        [events.BACKEND_READY] = function()
            if not dev.smokeTestsEnabled() or not dev.devLaunchEnabled() then
                return
            end
            clearTimer()
            state.backend = "READY"
            log.debug("backend READY")
        end,
        [events.BACKEND_UNAVAILABLE] = function(payload)
            if not dev.smokeTestsEnabled() or not dev.devLaunchEnabled() then
                return
            end
            clearTimer()
            state.backend = "UNAVAILABLE"
            log.warn(string.format("backend unavailable: %s", tostring(payload and payload.reason)))
        end,
        [events.SFP_CAPABILITIES_RESULT] = function(payload)
            local request_id = payload and payload.request_id
            local cb = request_id and state.pending_capabilities[request_id]
            if cb then
                state.pending_capabilities[request_id] = nil
                cb(payload)
            end
        end,
        [events.SFP_SPELL_STATE_RESULT] = function(payload)
            local request_id = payload and payload.request_id
            local cb = request_id and state.pending_spell_state[request_id]
            if cb then
                state.pending_spell_state[request_id] = nil
                cb(payload)
            end
        end,
        [events.SFP_EMIT_OBJECT_PROBE_RESULT] = function(payload)
            local request_id = payload and payload.request_id
            local cb = request_id and state.pending_emit_probe[request_id]
            if cb then
                state.pending_emit_probe[request_id] = nil
                cb(payload)
            end
        end,
        [events.DEV_LAUNCH_RESULT] = function(payload)
            local request_id = payload and payload.request_id
            local cb = request_id and state.pending_launch[request_id]
            if cb then
                state.pending_launch[request_id] = nil
                cb(payload)
            end
        end,
        [events.DEV_LAUNCH_HIT_OBSERVED] = function(payload)
            local request_id = payload and payload.request_id
            local cb = request_id and state.pending_hit[request_id]
            if cb then
                state.pending_hit[request_id] = nil
                cb(payload)
            end
        end,
    },
}
