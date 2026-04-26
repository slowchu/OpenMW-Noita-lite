local async = require("openmw.async")
local camera = require("openmw.camera")
local core = require("openmw.core")
local input = require("openmw.input")
local self = require("openmw.self")
local util = require("openmw.util")

local dev = require("scripts.spellforge.shared.dev")
local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_helper_hit_idempotency")

local state = {
    backend = "INIT",
    handshake_timer = nil,
    running = false,
    skip_logged = false,
    ready_logged = false,
    pending_probe = {},
}

local function assertLine(ok, label, detail)
    if ok then
        log.info("PASS " .. label)
    else
        log.error("FAIL " .. label .. (detail and (" detail: " .. detail) or ""))
    end
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

local function waitFor(map, request_id, timeout_seconds, callback)
    map[request_id] = callback
    async:newUnsavableSimulationTimer(timeout_seconds, function()
        if map[request_id] then
            local cb = map[request_id]
            map[request_id] = nil
            cb({ ok = false, error = "timeout" })
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
    return camera.getPosition(), direction
end

local function runSmoke()
    if not dev.smokeTestsEnabled() then
        return
    end
    if not dev.devLaunchEnabled() then
        log.info(string.format("SKIP smoke helper-hit idempotency: enable %s", dev.devLaunchSettingKey()))
        return
    end
    if state.running then
        log.warn("smoke helper-hit idempotency already in progress")
        return
    end
    if state.backend ~= "READY" then
        log.warn("smoke helper-hit idempotency skipped: backend is not READY")
        return
    end

    log.info("smoke helper-hit idempotency hotkey accepted")
    state.running = true
    local start_pos, direction = currentLaunchAim()
    local request_id = nextRequestId("smoke-helper-hit-idempotency")
    waitFor(state.pending_probe, request_id, 5, function(result)
        assertLine(result and result.ok == true, "helper-hit idempotency probe ok", result and result.error)
        if not result or result.ok ~= true then
            state.running = false
            return
        end

        assertLine(result.helper_spellid_routing_ok == true, "helper spellId routing still works")
        assertLine(result.projectile_routing_ok == true, "projectile_id route is accepted when present")
        assertLine(result.projectile_only_routing_ok == true, "projectile_id-only routing maps to helper metadata")
        assertLine(result.projectile_duplicate_first_hit == true, "first projectile hit is marked first")
        assertLine(result.projectile_duplicate_second_first_hit == false, "duplicate projectile hit is not first")
        assertLine(result.projectile_duplicate_hit_key_stable == true, "duplicate projectile hit keeps the same hit_key")
        assertLine(result.projectile_duplicate_previous_hit_key_matches == true, "duplicate projectile hit exposes previous hit record")
        assertLine(result.projectile_trigger_after_first_count == 1, "first projectile hit enqueues one Trigger payload job")
        assertLine(result.projectile_trigger_after_duplicate_count == 1, "duplicate projectile hit does not enqueue another Trigger payload job")
        assertLine(result.projectile_trigger_after_distinct_projectile_count == 2, "same helper with distinct projectile_id is not treated as duplicate")
        assertLine(result.projectile_duplicate_skipped_count == 1, "duplicate projectile Trigger enqueue is skipped")
        assertLine(result.fallback_routing_ok == true, "spellId fallback routing works without projectile_id")
        assertLine(result.fallback_duplicate_first_hit == true, "first fallback hit is marked first")
        assertLine(result.fallback_duplicate_second_first_hit == false, "duplicate fallback hit is not first")
        assertLine(result.fallback_duplicate_hit_key_stable == true, "duplicate fallback hit keeps the same hit_key")
        assertLine(result.fallback_duplicate_previous_hit_key_matches == true, "duplicate fallback hit exposes previous hit record")
        assertLine(result.fallback_trigger_after_first_count == 1, "first fallback hit enqueues one Trigger payload job")
        assertLine(result.fallback_trigger_after_duplicate_count == 1, "duplicate fallback hit does not enqueue another Trigger payload job")
        assertLine(result.fallback_duplicate_skipped_count == 1, "duplicate fallback Trigger enqueue is skipped")
        assertLine(result.multicast_distinct_count == result.multicast_expected_count, "distinct Multicast source slots enqueue independently")
        assertLine(result.multicast_duplicate_skipped_count == 0, "distinct Multicast slots are not treated as duplicates")
        assertLine(result.timer_hit_driven_payload_enqueue == false, "Timer payload enqueue is not hit-driven")
        log.info("smoke helper-hit idempotency run complete")
        state.running = false
    end)

    core.sendGlobalEvent(events.DEV_HELPER_HIT_IDEMPOTENCY_PROBE, {
        sender = self.object,
        actor = self,
        request_id = request_id,
        start_pos = start_pos,
        direction = direction,
    })
end

local function onKeyPress(key)
    if not dev.smokeTestsEnabled() then
        return true
    end
    local symbol = key.symbol and string.lower(key.symbol) or ""
    if symbol == "i" or key.code == input.KEY.I then
        if not dev.devLaunchEnabled() then
            log.info(string.format("SKIP smoke helper-hit idempotency: enable %s", dev.devLaunchSettingKey()))
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
                    log.info(string.format("SKIP smoke helper-hit idempotency: enable %s", dev.devLaunchSettingKey()))
                end
                return
            end
            if state.backend == "INIT" then
                requestBackend()
            elseif state.backend == "READY" and not state.ready_logged then
                state.ready_logged = true
                log.info("smoke helper-hit idempotency ready: press I")
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
        [events.DEV_HELPER_HIT_IDEMPOTENCY_RESULT] = function(payload)
            local request_id = payload and payload.request_id
            local cb = request_id and state.pending_probe[request_id]
            if cb then
                state.pending_probe[request_id] = nil
                cb(payload)
            end
        end,
    },
}
