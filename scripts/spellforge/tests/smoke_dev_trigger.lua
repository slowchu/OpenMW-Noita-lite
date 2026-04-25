local async = require("openmw.async")
local camera = require("openmw.camera")
local core = require("openmw.core")
local input = require("openmw.input")
local nearby = require("openmw.nearby")
local self = require("openmw.self")
local util = require("openmw.util")

local dev = require("scripts.spellforge.shared.dev")
local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_dev_trigger")

local state = {
    backend = "INIT",
    handshake_timer = nil,
    running = false,
    skip_logged = false,
    ready_logged = false,
    pending_launch = {},
    pending_trigger = {},
    pending_hit = {},
    active_request_id = nil,
    expected_recipe_id = nil,
    expected_count = 0,
    expected_source_slot_set = {},
    expected_payload_slot_set = {},
    seen_source_slot_set = {},
    seen_payload_slot_set = {},
    trigger_result_source_set = {},
    source_hit_count = 0,
    payload_hit_count = 0,
    trigger_result_count = 0,
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

local function waitForStream(map, request_id, timeout_seconds, callback)
    map[request_id] = callback
    async:newUnsavableSimulationTimer(timeout_seconds, function()
        if map[request_id] then
            local cb = map[request_id]
            map[request_id] = nil
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
    local ray = nearby.castRay(start_pos, start_pos + (direction * 2000), { ignore = self })
    if ray and ray.hit and ray.hitObject then
        hit_object = ray.hitObject
    end

    return start_pos, direction, hit_object
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

local function jobsAllPass(jobs, expected_kind, expected_effect, expected_count)
    if type(jobs) ~= "table" or #jobs ~= expected_count then
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

local function jobForPayloadSlot(jobs, payload_slot_id)
    for _, job in ipairs(jobs or {}) do
        if job.slot_id == payload_slot_id then
            return job
        end
    end
    return nil
end

local function resetExpected(result, expected_count)
    state.expected_recipe_id = result.recipe_id
    state.expected_count = expected_count
    state.expected_source_slot_set = {}
    state.expected_payload_slot_set = {}
    state.seen_source_slot_set = {}
    state.seen_payload_slot_set = {}
    state.trigger_result_source_set = {}
    state.source_hit_count = 0
    state.payload_hit_count = 0
    state.trigger_result_count = 0

    for _, slot_id in ipairs(result.source_slot_ids or {}) do
        state.expected_source_slot_set[slot_id] = true
    end
    for _, slot_id in ipairs(result.trigger_payload_slot_ids or {}) do
        state.expected_payload_slot_set[slot_id] = true
    end
end

local function finishRun(message)
    if message then
        log.info(message)
    end
    if state.active_request_id then
        state.pending_launch[state.active_request_id] = nil
        state.pending_trigger[state.active_request_id] = nil
        state.pending_hit[state.active_request_id] = nil
        state.active_request_id = nil
    end
    state.running = false
end

local function maybeFinish()
    if state.trigger_result_count >= state.expected_count and state.payload_hit_count >= state.expected_count then
        assertLine(true, "all Trigger Frost helper hits routed to distinct payload slot_ids")
        finishRun("smoke dev trigger run complete")
        return true
    end
    return false
end

local function handleTriggerResult(result)
    if result and result.timeout then
        assertLine(false, "Trigger payload result received before timeout", result.error)
        finishRun()
        return true
    end

    assertLine(result and result.ok == true, "Trigger payload result ok", result and result.error)
    if not result or result.ok ~= true then
        finishRun()
        return true
    end

    local source_expected = state.expected_source_slot_set[result.source_slot_id] == true
    local payload_expected = state.expected_payload_slot_set[result.payload_slot_id] == true
    local job = jobForPayloadSlot(result.trigger_jobs, result.payload_slot_id)
    local origin_distance = job and vectorDistance(job.launch_start_pos, result.source_hit_pos) or nil

    assertLine(source_expected, "Trigger payload job references expected source_slot_id", tostring(result.source_slot_id))
    assertLine(payload_expected, "Trigger payload job references expected Frost payload slot", tostring(result.payload_slot_id))
    assertLine(result.source_hit_pos ~= nil, "Trigger payload job captured source hitPos")
    assertLine(job ~= nil, "Trigger payload job enqueued")
    assertLine(job and job.job_kind == "dev_trigger_payload", "Trigger payload job kind is dev-only")
    assertLine(job and job.job_status == "complete" and job.launch_accepted == true, "Trigger payload job completes with SFP accepted")
    assertLine(origin_distance ~= nil and origin_distance <= 0.01, "Trigger payload launch origin uses source hitPos")
    assertLine(string.lower(tostring(result.effect_id)) == "frostdamage", "Trigger payload effect summary is frostdamage")

    if source_expected and not state.trigger_result_source_set[result.source_slot_id] then
        state.trigger_result_source_set[result.source_slot_id] = true
        state.trigger_result_count = state.trigger_result_count + 1
        assertLine(true, string.format("Trigger payload launches once for source emission %d/%d", state.trigger_result_count, state.expected_count))
    end

    return maybeFinish()
end

local function handleHit(hit)
    if hit and hit.timeout then
        if state.trigger_result_count > 0 and state.payload_hit_count > 0 then
            log.warn(string.format(
                "partial Trigger hit routing observed source=%d payload=%d expected=%d; aim at a broad surface/target to catch every helper",
                state.source_hit_count,
                state.payload_hit_count,
                state.expected_count
            ))
            finishRun("smoke dev trigger run complete")
        else
            assertLine(false, "Trigger source and payload hits route", hit.error)
            finishRun()
        end
        return true
    end

    local recipe_matches = hit and hit.recipe_id == state.expected_recipe_id
    local effect_id = string.lower(tostring(hit and hit.effect_id))
    if effect_id == "firedamage" then
        local slot_expected = state.expected_source_slot_set[hit.slot_id] == true
        assertLine(slot_expected, "Trigger source Fire hit slot is expected", hit and tostring(hit.slot_id))
        assertLine(recipe_matches, "Trigger source Fire hit recipe matches", hit and tostring(hit and hit.recipe_id))
        assertLine(hit.hit_pos ~= nil, "Trigger source Fire hitPos captured")
        if slot_expected and not state.seen_source_slot_set[hit.slot_id] then
            state.seen_source_slot_set[hit.slot_id] = true
            state.source_hit_count = state.source_hit_count + 1
            assertLine(true, string.format("Trigger source Fire hit routes distinct slot %d/%d", state.source_hit_count, state.expected_count))
        end
    elseif effect_id == "frostdamage" then
        local slot_expected = state.expected_payload_slot_set[hit.slot_id] == true
        assertLine(slot_expected, "Trigger Frost payload hit slot is expected", hit and tostring(hit.slot_id))
        assertLine(recipe_matches, "Trigger Frost payload hit recipe matches", hit and tostring(hit and hit.recipe_id))
        assertLine(true, "Trigger Frost payload hit effect summary is frostdamage")
        if slot_expected and not state.seen_payload_slot_set[hit.slot_id] then
            state.seen_payload_slot_set[hit.slot_id] = true
            state.payload_hit_count = state.payload_hit_count + 1
            assertLine(true, string.format("Trigger Frost payload hit routes distinct slot %d/%d", state.payload_hit_count, state.expected_count))
        end
    end

    return maybeFinish()
end

local function runSmoke(multicast)
    if not dev.smokeTestsEnabled() then
        return
    end
    if not dev.devLaunchEnabled() then
        log.info(string.format("SKIP smoke dev trigger: enable %s", dev.devLaunchSettingKey()))
        return
    end
    if state.running then
        log.warn("smoke dev trigger already in progress")
        return
    end
    if state.backend ~= "READY" then
        log.warn("smoke dev trigger skipped: backend is not READY")
        return
    end

    local expected_count = multicast and 3 or 1
    log.info(multicast and "smoke dev trigger multicast hotkey accepted" or "smoke dev trigger simple hotkey accepted")
    state.running = true

    local start_pos, direction, hit_object = currentLaunchAim()
    local launch_request_id = nextRequestId(multicast and "smoke-dev-trigger-multicast" or "smoke-dev-trigger")
    state.active_request_id = launch_request_id
    waitFor(state.pending_launch, launch_request_id, 5, function(result)
        assertLine(result and result.ok == true, multicast and "dev Trigger multicast request ok" or "dev Trigger request ok", result and result.error)
        if not result or result.ok ~= true then
            finishRun()
            return
        end

        resetExpected(result, expected_count)

        assertLine(result.slot_count == expected_count * 2, "Fire Trigger Frost plan has expected slot count")
        assertLine(result.helper_record_count == expected_count * 2, "Fire Trigger Frost plan has expected helper record count")
        assertLine(result.source_job_count == expected_count, "source Fire launch jobs enqueued")
        assertLine(uniqueCount(result.source_slot_ids) == expected_count, "unique Fire source slot_ids expected")
        assertLine(listHasOnly(result.source_effect_ids, "firedamage"), "source helpers carry firedamage")
        assertLine(jobsAllPass(result.source_jobs, "dev_launch_helper", "firedamage", expected_count), "source Fire jobs complete with SFP accepted")
        assertLine(result.source_launch_accepted_count == expected_count, "SFP launch accepted for each source Fire helper")
        assertLine(uniqueCount(result.trigger_payload_slot_ids) == expected_count, "unique Frost Trigger payload slot_ids expected")
        assertLine(listHasOnly(result.trigger_payload_effect_ids, "frostdamage"), "Trigger payload helpers carry frostdamage")
        assertLine(result.trigger_metadata_exists == true, "Trigger metadata exists")
        assertLine(result.expected_trigger_payload_count == expected_count, "Trigger payload cardinality matches source emissions")
        assertLine(result.timer_job_count == 0, "no Timer jobs created")
        assertLine(result.chain_job_count == 0, "no Chain jobs created")

        log.info("manual hit required: aim at a valid target/surface; waiting for Trigger source and Frost payload routing")
        waitForStream(state.pending_hit, launch_request_id, 45, handleHit)
        waitForStream(state.pending_trigger, launch_request_id, 45, handleTriggerResult)
    end)

    core.sendGlobalEvent(events.DEV_LAUNCH_TRIGGER_EMITTER, {
        sender = self.object,
        actor = self,
        request_id = launch_request_id,
        timeout_seconds = 40,
        start_pos = start_pos,
        direction = direction,
        hit_object = hit_object,
        multicast = multicast == true,
    })
end

local function onKeyPress(key)
    if not dev.smokeTestsEnabled() then
        return true
    end
    local symbol = key.symbol and string.lower(key.symbol) or ""
    if symbol == "g" or key.code == input.KEY.G then
        if not dev.devLaunchEnabled() then
            log.info(string.format("SKIP smoke dev trigger: enable %s", dev.devLaunchSettingKey()))
            return true
        end
        runSmoke(false)
        return false
    elseif symbol == "y" or key.code == input.KEY.Y then
        if not dev.devLaunchEnabled() then
            log.info(string.format("SKIP smoke dev trigger multicast: enable %s", dev.devLaunchSettingKey()))
            return true
        end
        runSmoke(true)
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
                    log.info(string.format("SKIP smoke dev trigger: enable %s", dev.devLaunchSettingKey()))
                end
                return
            end
            if state.backend == "INIT" then
                requestBackend()
            elseif state.backend == "READY" and not state.ready_logged then
                state.ready_logged = true
                log.info("smoke dev trigger ready: aim at a valid target/surface and press G; press Y for Multicast x3 Trigger")
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
        [events.DEV_LAUNCH_TRIGGER_RESULT] = function(payload)
            local request_id = payload and payload.request_id
            local cb = request_id and state.pending_trigger[request_id]
            if cb then
                local done = cb(payload)
                if done then
                    state.pending_trigger[request_id] = nil
                end
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
