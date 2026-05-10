local async = require("openmw.async")
local camera = require("openmw.camera")
local core = require("openmw.core")
local nearby = require("openmw.nearby")
local self = require("openmw.self")
local util = require("openmw.util")

local dev = require("scripts.spellforge.shared.dev")
local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_dev_launch")
local smoke_keys = require("scripts.spellforge.tests.smoke_keys")

local state = {
    backend = "INIT",
    handshake_timer = nil,
    running = false,
    skip_logged = false,
    ready_logged = false,
    pending_launch = {},
    pending_hit = {},
    pending_lookup = {},
    pending_perf = {},
    expected_recipe_id = nil,
    expected_slot_id = nil,
    expected_helper_engine_id = nil,
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
    local start_pos = camera.getPosition()
    local hit_object = nil
    local ray = nearby.castRay(start_pos, start_pos + (direction * 2000), { ignore = self })
    if ray and ray.hit and ray.hitObject then
        hit_object = ray.hitObject
    end

    return start_pos, direction, hit_object
end

local function beginUnknownLookupProbe()
    local lookup_request_id = nextRequestId("smoke-dev-launch-lookup")
    waitFor(state.pending_lookup, lookup_request_id, 3, function(result)
        local ok = result and result.ok == false and type(result.error) == "string"
            and string.find(result.error, "metadata not found", 1, true) ~= nil
        assertLine(ok, "unknown helper lookup fails readably", result and result.error)
    end)
    core.sendGlobalEvent(events.DEV_LAUNCH_PROBE_UNKNOWN_HELPER, {
        sender = self.object,
        request_id = lookup_request_id,
        engine_id = "spellforge_unknown_helper_for_smoke_dev_launch",
    })
end

local function runSmoke()
    if not dev.smokeTestsEnabled() then
        return
    end
    if not dev.devLaunchEnabled() then
        log.info(string.format("SKIP smoke dev launch: enable %s", dev.devLaunchSettingKey()))
        return
    end
    if state.running then
        log.warn("smoke dev launch already in progress")
        return
    end
    if state.backend ~= "READY" then
        log.warn("smoke dev launch skipped: backend is not READY")
        return
    end

    log.info("smoke dev launch hotkey accepted")
    state.running = true
    state.expected_recipe_id = nil
    state.expected_slot_id = nil
    state.expected_helper_engine_id = nil

    local start_pos, direction, hit_object = currentLaunchAim()
    local launch_request_id = nextRequestId("smoke-dev-launch")
    waitFor(state.pending_launch, launch_request_id, 5, function(result)
        assertLine(result and result.ok == true, "dev launch simple emitter request ok", result and result.error)
        if not result or result.ok ~= true then
            state.running = false
            return
        end

        state.expected_recipe_id = result.recipe_id
        state.expected_slot_id = result.slot_id
        state.expected_helper_engine_id = result.helper_engine_id

        assertLine(result.slot_count == 1, "simple Fire Damage plan has one slot")
        assertLine(result.helper_record_count == 1, "simple Fire Damage plan has one helper record")
        assertLine(string.lower(tostring(result.effect_id)) == "firedamage", "helper record effect id=firedamage")
        assertLine(result.job_kind == "dev_launch_helper", "dev launch job kind is dev-only")
        assertLine(result.job_status == "complete", "dev launch job completes when SFP accepts launch", result.job_status)
        assertLine(result.launch_accepted == true, "SFP launch accepted through dev path")

        beginUnknownLookupProbe()
        log.info("manual hit required: aim at a valid target/surface; waiting for helper hit routing")

        waitFor(state.pending_hit, launch_request_id, 30, function(hit)
            local mapped = hit and hit.ok == true
                and hit.recipe_id == state.expected_recipe_id
                and hit.slot_id == state.expected_slot_id
                and hit.helper_engine_id == state.expected_helper_engine_id
            assertLine(mapped, "helper hit routes to expected recipe_id + slot_id", hit and hit.error)
            assertLine(hit and string.lower(tostring(hit.effect_id)) == "firedamage", "helper hit effect summary is firedamage")
            log.info("smoke dev launch run complete")
            state.running = false
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

local function runPerformanceSmoke()
    if not dev.smokeTestsEnabled() then
        return
    end
    if not dev.devLaunchEnabled() then
        log.info(string.format("SKIP smoke performance stress: enable %s", dev.devLaunchSettingKey()))
        return
    end
    if state.running then
        log.warn("smoke dev launch already in progress")
        return
    end
    if state.backend ~= "READY" then
        log.warn("smoke performance stress skipped: backend is not READY")
        return
    end

    log.info("smoke performance stress logical fast-forward hotkey accepted; not a real Timer delay test")
    state.running = true

    local start_pos, direction, hit_object = currentLaunchAim()
    local request_id = nextRequestId("smoke-perf-stress")
    waitFor(state.pending_perf, request_id, 8, function(result)
        assertLine(result and result.ok == true, "performance stress request ok", result and result.error)
        if not result or result.ok ~= true then
            state.running = false
            return
        end

        assertLine(result.slot_count == 25, "performance stress plan has 25 slots")
        assertLine(result.helper_record_count == 25, "performance stress plan has 25 helper records")
        assertLine(result.source_job_count == 1, "performance stress launches one Fireball source")
        assertLine(result.timer_payload_job_count == 8, "performance stress launches eight Timer/Burst Frostball payloads")
        assertLine(result.trigger_payload_job_count == 16, "performance stress launches sixteen Trigger Fire payloads")
        assertLine(result.total_job_count == 25, "performance stress enqueues 25 total jobs")
        assertLine(result.launch_accepted_count == 25, "performance stress SFP accepts all 25 helper launches")
        assertLine(tonumber(result.timer_seconds) == 1, "performance stress uses Timer 1s")
        assertLine(tonumber(result.timer_delay_ticks) ~= nil and tonumber(result.timer_delay_ticks) > 0, "performance stress uses bounded Timer delay ticks")
        assertLine(result.fast_forward_semantics == "logical_orchestrator_tick_fast_forward", "performance stress is labeled as logical orchestrator tick fast-forward")
        assertLine(result.real_delay_test == false, "performance stress does not claim a real Timer delay test")
        assertLine(result.burst_metadata_exists == true, "performance stress preserves Burst metadata")
        assertLine(result.multicast_metadata_exists == true, "performance stress preserves Multicast metadata")
        assertLine(result.burst_direction_count == 8, "performance stress computes eight Burst directions")
        assertLine(result.queue_drained == true, "performance stress queue drains")

        log.info(string.format(
            "performance stress summary recipe_id=%s shape=%s total_jobs=%s accepted=%s timer_delay_ticks=%s burst_dirs=%s elapsed_ticks=%s fast_forward=%s real_delay_test=%s",
            tostring(result.recipe_id),
            tostring(result.performance_shape),
            tostring(result.total_job_count),
            tostring(result.launch_accepted_count),
            tostring(result.timer_delay_ticks),
            tostring(result.burst_direction_count),
            tostring(result.elapsed_ticks),
            tostring(result.fast_forward_semantics),
            tostring(result.real_delay_test)
        ))
        state.running = false
    end)

    core.sendGlobalEvent(events.DEV_LAUNCH_PERF_STRESS, {
        sender = self.object,
        actor = self,
        request_id = request_id,
        start_pos = start_pos,
        direction = direction,
        hit_object = hit_object,
    })
end

local function onKeyPress(key)
    if not dev.smokeTestsEnabled() then
        return true
    end
    if smoke_keys.matches(key, "num0") then
        runPerformanceSmoke()
        return false
    end
    if smoke_keys.matches(key, "plus") then
        if not dev.devLaunchEnabled() then
            log.info(string.format("SKIP smoke dev launch: enable %s", dev.devLaunchSettingKey()))
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
                    log.info(string.format("SKIP smoke dev launch: enable %s", dev.devLaunchSettingKey()))
                end
                return
            end
            if state.backend == "INIT" then
                requestBackend()
            elseif state.backend == "READY" and not state.ready_logged then
                state.ready_logged = true
                log.info("smoke dev launch ready: aim at a valid target/surface and press Numpad 0 for performance stress; press Numpad + for the single-helper dev launch")
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
        [events.DEV_LAUNCH_LOOKUP_RESULT] = function(payload)
            local request_id = payload and payload.request_id
            local cb = request_id and state.pending_lookup[request_id]
            if cb then
                state.pending_lookup[request_id] = nil
                cb(payload)
            end
        end,
        [events.DEV_LAUNCH_PERF_STRESS_RESULT] = function(payload)
            local request_id = payload and payload.request_id
            local cb = request_id and state.pending_perf[request_id]
            if cb then
                state.pending_perf[request_id] = nil
                cb(payload)
            end
        end,
    },
}
