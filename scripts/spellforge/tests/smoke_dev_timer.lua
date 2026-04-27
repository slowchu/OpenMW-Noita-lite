local async = require("openmw.async")
local camera = require("openmw.camera")
local core = require("openmw.core")
local nearby = require("openmw.nearby")
local self = require("openmw.self")
local util = require("openmw.util")

local dev = require("scripts.spellforge.shared.dev")
local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_dev_timer")
local smoke_keys = require("scripts.spellforge.tests.smoke_keys")

local TIMER_RAYCAST_DISTANCE = 10000

local state = {
    backend = "INIT",
    handshake_timer = nil,
    running = false,
    skip_logged = false,
    ready_logged = false,
    pending_launch = {},
    pending_timer = {},
    pending_hit = {},
    expected_recipe_id = nil,
    expected_frost_slot_set = {},
    expected_frost_slot_count = 0,
    seen_frost_slot_set = {},
    seen_frost_slot_count = 0,
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
            cb({ ok = false, error = "timeout", timeout = true })
        end
    end)
end

local function waitForHits(request_id, timeout_seconds, callback)
    state.pending_hit[request_id] = callback
    async:newUnsavableSimulationTimer(timeout_seconds, function()
        if state.pending_hit[request_id] then
            local cb = state.pending_hit[request_id]
            state.pending_hit[request_id] = nil
            cb({ ok = false, error = "timeout", timeout = true })
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
    local aim_ray = nearby.castRay(start_pos, start_pos + (direction * 2000), { ignore = self })
    if aim_ray and aim_ray.hit and aim_ray.hitObject then
        hit_object = aim_ray.hitObject
    end
    local timer_ray = nearby.castRay(start_pos, start_pos + (direction * TIMER_RAYCAST_DISTANCE), { ignore = self })

    return start_pos, direction, hit_object, {
        available = true,
        hit = timer_ray and timer_ray.hit == true,
        hit_pos = timer_ray and timer_ray.hitPos or nil,
    }
end

local function tableCount(set)
    local count = 0
    for _ in pairs(set or {}) do
        count = count + 1
    end
    return count
end

local function uniqueCount(values)
    local set = {}
    for _, value in ipairs(values or {}) do
        if value ~= nil then
            set[value] = true
        end
    end
    return tableCount(set)
end

local function listHasOnly(effect_ids, expected)
    if type(effect_ids) ~= "table" or #effect_ids == 0 then
        return false
    end
    for _, effect_id in ipairs(effect_ids) do
        if string.lower(tostring(effect_id)) ~= expected then
            return false
        end
    end
    return true
end

local function vectorDistance(a, b)
    if a == nil or b == nil then
        return nil
    end
    local ok, diff = pcall(function()
        return a - b
    end)
    if not ok then
        return nil
    end
    local ok_length, length = pcall(function()
        return diff:length()
    end)
    if ok_length then
        return tonumber(length)
    end
    return nil
end

local function resolutionKindAllowed(kind)
    return kind == "ray_hit" or kind == "midair" or kind == "endpoint_no_raycast"
end

local function timerJobsHaveTravelContext(jobs)
    if type(jobs) ~= "table" or #jobs == 0 then
        return false
    end
    for _, job in ipairs(jobs) do
        if job.timer_start_pos == nil or job.timer_endpoint == nil or job.resolution_pos == nil then
            return false
        end
        if not resolutionKindAllowed(job.resolution_kind) then
            return false
        end
    end
    return true
end

local function timerResolutionDiffersFromStart(jobs)
    if type(jobs) ~= "table" or #jobs == 0 then
        return false
    end
    for _, job in ipairs(jobs) do
        local distance = vectorDistance(job.timer_start_pos, job.resolution_pos)
        if distance == nil or distance <= 1 then
            return false
        end
    end
    return true
end

local function timerPayloadUsesResolution(jobs)
    if type(jobs) ~= "table" or #jobs == 0 then
        return false
    end
    for _, job in ipairs(jobs) do
        local distance = vectorDistance(job.launch_start_pos, job.resolution_pos)
        if distance == nil or distance > 0.01 then
            return false
        end
    end
    return true
end

local function logTimerResolutionInfo(jobs)
    local job = jobs and jobs[1] or nil
    if not job then
        return
    end
    log.info(string.format(
        "Timer travel start_pos=%s endpoint=%s resolution_pos=%s resolution_kind=%s raycast_note=%s",
        tostring(job.timer_start_pos),
        tostring(job.timer_endpoint),
        tostring(job.resolution_pos),
        tostring(job.resolution_kind),
        tostring(job.timer_raycast_note)
    ))
end

local function jobsAllPass(jobs, expected_kind, expected_effect)
    if type(jobs) ~= "table" or #jobs == 0 then
        return false
    end
    for _, job in ipairs(jobs) do
        if job.job_kind ~= expected_kind then
            return false
        end
        if job.job_status ~= "complete" then
            return false
        end
        if job.launch_accepted ~= true then
            return false
        end
        if string.lower(tostring(job.effect_id)) ~= expected_effect then
            return false
        end
    end
    return true
end

local function rememberExpectedFrostSlots(result)
    state.expected_recipe_id = result.recipe_id
    state.expected_frost_slot_set = {}
    state.expected_frost_slot_count = 0
    state.seen_frost_slot_set = {}
    state.seen_frost_slot_count = 0

    for _, slot_id in ipairs(result.timer_payload_slot_ids or {}) do
        if not state.expected_frost_slot_set[slot_id] then
            state.expected_frost_slot_set[slot_id] = true
            state.expected_frost_slot_count = state.expected_frost_slot_count + 1
        end
    end
end

local function handleFrostHit(hit)
    if hit and hit.timeout then
        if state.seen_frost_slot_count > 0 then
            log.warn(string.format(
                "partial Timer Frost hit routing observed count=%d expected=%d; aim at a broad surface/target to catch every payload helper",
                state.seen_frost_slot_count,
                state.expected_frost_slot_count
            ))
            log.info("smoke dev timer run complete")
        else
            assertLine(false, "at least one Timer Frost helper hit routes", hit.error)
        end
        state.running = false
        return true
    end

    local slot_expected = hit and state.expected_frost_slot_set[hit.slot_id] == true
    local recipe_matches = hit and hit.recipe_id == state.expected_recipe_id
    local effect_matches = hit and string.lower(tostring(hit.effect_id)) == "frostdamage"
    assertLine(slot_expected, "Timer Frost helper hit slot is expected", hit and tostring(hit.slot_id))
    assertLine(recipe_matches, "Timer Frost helper hit recipe matches", hit and tostring(hit.recipe_id))
    assertLine(effect_matches, "Timer Frost helper hit effect summary is frostdamage")

    if slot_expected and not state.seen_frost_slot_set[hit.slot_id] then
        state.seen_frost_slot_set[hit.slot_id] = true
        state.seen_frost_slot_count = state.seen_frost_slot_count + 1
        assertLine(true, string.format("Timer Frost helper hit routes distinct slot %d/%d", state.seen_frost_slot_count, state.expected_frost_slot_count))
    end

    if state.seen_frost_slot_count >= state.expected_frost_slot_count then
        assertLine(true, "all Timer Frost helper hits routed to distinct slot_ids")
        log.info("smoke dev timer run complete")
        state.running = false
        return true
    end
    return false
end

local function handleTimerPayloadResult(result, launch_request_id)
    assertLine(result and result.ok == true, "Timer payload result ok", result and result.error)
    if not result or result.ok ~= true then
        state.running = false
        return
    end

    assertLine(result.timer_payload_job_count == 2, "two Timer payload jobs woke")
    assertLine(jobsAllPass(result.timer_jobs, "dev_timer_payload", "frostdamage"), "two Timer payload jobs complete with SFP accepted")
    assertLine(result.frost_payload_launch_accepted_count == 2, "two Frost payload launches accepted by SFP")
    assertLine(uniqueCount(result.timer_payload_helper_engine_ids) == 2, "two unique Frost helper engine IDs launched")
    assertLine(listHasOnly(result.timer_payload_effect_ids, "frostdamage"), "Timer payload helpers carry frostdamage")
    assertLine(timerPayloadUsesResolution(result.timer_jobs), "Timer payload uses computed resolution_pos")
    assertLine(listHasOnly(result.timer_payload_effect_ids, "frostdamage"), "Timer payload effect summary is frostdamage")

    log.info("Timer Frost payload launched; hit watcher is active")
end

local function runSmoke()
    if not dev.smokeTestsEnabled() then
        return
    end
    if not dev.devLaunchEnabled() then
        log.info(string.format("SKIP smoke dev timer: enable %s", dev.devLaunchSettingKey()))
        return
    end
    if state.running then
        log.warn("smoke dev timer already in progress")
        return
    end
    if state.backend ~= "READY" then
        log.warn("smoke dev timer skipped: backend is not READY")
        return
    end

    log.info("smoke dev timer hotkey accepted")
    state.running = true

    local start_pos, direction, hit_object, timer_raycast = currentLaunchAim()
    local launch_request_id = nextRequestId("smoke-dev-timer")
    waitFor(state.pending_launch, launch_request_id, 5, function(result)
        assertLine(result and result.ok == true, "dev Timer request ok", result and result.error)
        if not result or result.ok ~= true then
            state.running = false
            return
        end

        rememberExpectedFrostSlots(result)

        assertLine(result.slot_count == 4, "Multicast x2 Fire Timer Frost plan has four slots")
        assertLine(result.helper_record_count == 4, "Multicast x2 Fire Timer Frost plan has four helper records")
        assertLine(result.source_job_count == 2, "two source Fire launch jobs enqueued")
        assertLine(uniqueCount(result.source_slot_ids) == 2, "two unique Fire source slot_ids expected")
        assertLine(listHasOnly(result.source_effect_ids, "firedamage"), "source helpers carry firedamage")
        assertLine(jobsAllPass(result.source_jobs, "dev_launch_helper", "firedamage"), "two source Fire jobs complete with SFP accepted")
        assertLine(result.source_launch_accepted_count == 2, "SFP launch accepted for each source Fire helper")
        assertLine(result.timer_payload_job_count == 2, "two Timer payload jobs enqueued")
        assertLine(uniqueCount(result.timer_payload_slot_ids) == 2, "two unique Frost payload slot_ids expected")
        assertLine(listHasOnly(result.timer_payload_effect_ids, "frostdamage"), "Timer payload helpers carry frostdamage")
        assertLine(result.timer_jobs_waiting == true, "Timer payload jobs queued/waiting before delay elapses")
        assertLine(result.timer_jobs_complete_before_delay == 0, "Timer payload jobs do not complete before delay")
        assertLine(result.timer_seconds == 1.0, "Timer delay is 1.0 seconds")
        assertLine(result.timer_delay_ticks == 2 and result.timer_ticks_per_second == 2, "Timer delay mapped to two orchestrator ticks")
        logTimerResolutionInfo(result.timer_jobs)
        assertLine(timerJobsHaveTravelContext(result.timer_jobs), "Timer travel endpoint computed")
        assertLine(timerJobsHaveTravelContext(result.timer_jobs), "Timer resolution_pos computed")
        assertLine(timerResolutionDiffersFromStart(result.timer_jobs), "Timer resolution_pos differs from source start_pos")
        assertLine(timerJobsHaveTravelContext(result.timer_jobs), "Timer resolution_kind is ray_hit/midair/endpoint_no_raycast")
        assertLine(result.trigger_job_count == 0, "no Trigger jobs created")
        assertLine(result.chain_job_count == 0, "no Chain jobs created")

        log.info("manual hit required: waiting for delayed Timer Frost launch and hit routing")
        waitForHits(launch_request_id, 35, handleFrostHit)
        waitFor(state.pending_timer, launch_request_id, 5, function(timer_result)
            if not timer_result or timer_result.ok ~= true then
                state.pending_hit[launch_request_id] = nil
            end
            handleTimerPayloadResult(timer_result, launch_request_id)
        end)
    end)

    core.sendGlobalEvent(events.DEV_LAUNCH_TIMER_EMITTER, {
        sender = self.object,
        actor = self,
        request_id = launch_request_id,
        timeout_seconds = 30,
        start_pos = start_pos,
        direction = direction,
        hit_object = hit_object,
        timer_raycast = timer_raycast,
    })
end

local function onKeyPress(key)
    if not dev.smokeTestsEnabled() then
        return true
    end
    if smoke_keys.matches(key, "num2") then
        if not dev.devLaunchEnabled() then
            log.info(string.format("SKIP smoke dev timer: enable %s", dev.devLaunchSettingKey()))
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
                    log.info(string.format("SKIP smoke dev timer: enable %s", dev.devLaunchSettingKey()))
                end
                return
            end
            if state.backend == "INIT" then
                requestBackend()
            elseif state.backend == "READY" and not state.ready_logged then
                state.ready_logged = true
                log.info("smoke dev timer ready: aim at a valid target/surface and press Numpad 2")
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
        [events.DEV_LAUNCH_TIMER_RESULT] = function(payload)
            local request_id = payload and payload.request_id
            local cb = request_id and state.pending_timer[request_id]
            if cb then
                state.pending_timer[request_id] = nil
                cb(payload)
            end
        end,
        [events.DEV_LAUNCH_HIT_OBSERVED] = function(payload)
            local request_id = payload and payload.request_id
            local cb = request_id and state.pending_hit[request_id]
            if cb then
                local done = cb(payload)
                if done then
                    state.pending_hit[request_id] = nil
                end
            end
        end,
    },
}
