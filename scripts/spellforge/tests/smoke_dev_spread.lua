local async = require("openmw.async")
local camera = require("openmw.camera")
local core = require("openmw.core")
local input = require("openmw.input")
local nearby = require("openmw.nearby")
local self = require("openmw.self")
local util = require("openmw.util")

local dev = require("scripts.spellforge.shared.dev")
local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_dev_spread")

local state = {
    backend = "INIT",
    handshake_timer = nil,
    running = false,
    skip_logged = false,
    ready_logged = false,
    pending_launch = {},
    pending_hit = {},
    expected_recipe_id = nil,
    expected_slot_set = {},
    expected_slot_count = 0,
    seen_slot_set = {},
    seen_slot_count = 0,
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

local function listHasOnlyFireDamage(effect_ids)
    if type(effect_ids) ~= "table" or #effect_ids == 0 then
        return false
    end
    for _, effect_id in ipairs(effect_ids) do
        if string.lower(tostring(effect_id)) ~= "firedamage" then
            return false
        end
    end
    return true
end

local function jobsAllPass(jobs)
    if type(jobs) ~= "table" or #jobs ~= 3 then
        return false
    end
    for _, job in ipairs(jobs) do
        if job.job_kind ~= "dev_launch_helper" then
            return false
        end
        if job.job_status ~= "complete" then
            return false
        end
        if job.launch_accepted ~= true then
            return false
        end
        if job.launch_direction == nil then
            return false
        end
        if string.lower(tostring(job.effect_id)) ~= "firedamage" then
            return false
        end
    end
    return true
end

local function rememberExpectedSlots(result)
    state.expected_recipe_id = result.recipe_id
    state.expected_slot_set = {}
    state.expected_slot_count = 0
    state.seen_slot_set = {}
    state.seen_slot_count = 0

    for _, slot_id in ipairs(result.slot_ids or {}) do
        if not state.expected_slot_set[slot_id] then
            state.expected_slot_set[slot_id] = true
            state.expected_slot_count = state.expected_slot_count + 1
        end
    end
end

local function handleHit(hit)
    if hit and hit.timeout then
        if state.seen_slot_count > 0 then
            log.warn(string.format(
                "partial Spread hit routing observed count=%d expected=%d; aim at a broad surface/target to catch every helper",
                state.seen_slot_count,
                state.expected_slot_count
            ))
            log.info("smoke dev Spread run complete")
        else
            assertLine(false, "at least one Spread helper hit routes", hit.error)
        end
        state.running = false
        return true
    end

    local slot_expected = hit and state.expected_slot_set[hit.slot_id] == true
    local recipe_matches = hit and hit.recipe_id == state.expected_recipe_id
    local effect_matches = hit and string.lower(tostring(hit.effect_id)) == "firedamage"
    assertLine(slot_expected, "Spread helper hit slot is expected", hit and tostring(hit.slot_id))
    assertLine(recipe_matches, "Spread helper hit recipe matches", hit and tostring(hit.recipe_id))
    assertLine(effect_matches, "Spread helper hit effect summary is firedamage")

    if slot_expected and not state.seen_slot_set[hit.slot_id] then
        state.seen_slot_set[hit.slot_id] = true
        state.seen_slot_count = state.seen_slot_count + 1
        assertLine(true, string.format("Spread helper hit routes distinct slot %d/%d", state.seen_slot_count, state.expected_slot_count))
    end

    if state.seen_slot_count >= state.expected_slot_count then
        assertLine(true, "all Spread helper hits routed to distinct slot_ids")
        log.info("smoke dev Spread run complete")
        state.running = false
        return true
    end
    return false
end

local function runSmoke()
    if not dev.smokeTestsEnabled() then
        return
    end
    if not dev.devLaunchEnabled() then
        log.info(string.format("SKIP smoke dev Spread: enable %s", dev.devLaunchSettingKey()))
        return
    end
    if state.running then
        log.warn("smoke dev Spread already in progress")
        return
    end
    if state.backend ~= "READY" then
        log.warn("smoke dev Spread skipped: backend is not READY")
        return
    end

    log.info("smoke dev Spread hotkey accepted")
    state.running = true

    local start_pos, direction, hit_object = currentLaunchAim()
    local launch_request_id = nextRequestId("smoke-dev-spread")
    waitFor(state.pending_launch, launch_request_id, 5, function(result)
        assertLine(result and result.ok == true, "dev Spread request ok", result and result.error)
        if not result or result.ok ~= true then
            state.running = false
            return
        end

        rememberExpectedSlots(result)

        assertLine(result.slot_count == 3, "Spread Multicast x3 Fire Damage plan has three slots")
        assertLine(result.helper_record_count == 3, "Spread Multicast x3 Fire Damage plan has three helper records")
        assertLine(result.spread_metadata_exists == true, "Spread metadata exists")
        assertLine(result.multicast_metadata_exists == true, "Multicast metadata exists")
        assertLine(result.spread_direction_count == 3, "three Spread launch directions computed")
        assertLine(uniqueCount(result.spread_direction_keys) == 3, "three Spread launch directions are distinct")
        assertLine(result.spread_deterministic == true, "Spread direction computation is deterministic")
        assertLine(result.spread_rotation_axis == "world_up_yaw", "Spread uses deterministic world-up yaw pattern")
        assertLine(result.job_count == 3, "three dev-only Spread launch jobs enqueued")
        assertLine(tableCount(state.expected_slot_set) == 3, "three unique slot_ids expected")
        assertLine(uniqueCount(result.helper_engine_ids) == 3, "three unique helper engine IDs expected")
        assertLine(listHasOnlyFireDamage(result.effect_ids), "all Spread helper records carry firedamage")
        assertLine(jobsAllPass(result.jobs), "three Spread launch jobs complete with SFP accepted")
        assertLine(result.launch_accepted_count == 3, "SFP launch accepted for each Spread helper")
        assertLine(result.trigger_job_count == 0, "no Trigger jobs created")
        assertLine(result.timer_job_count == 0, "no Timer jobs created")
        assertLine(result.chain_job_count == 0, "no Chain jobs created")
        log.info(string.format(
            "Spread vectors preset=%s angle_degrees=%s offsets=%s directions=%s",
            tostring(result.spread_preset),
            tostring(result.spread_angle_degrees),
            table.concat(result.spread_angle_offsets_degrees or {}, ","),
            table.concat(result.spread_direction_keys or {}, " | ")
        ))

        log.info("manual hit required: aim at a broad valid target/surface; waiting for Spread helper hit routing")
        waitForHits(launch_request_id, 30, handleHit)
    end)

    core.sendGlobalEvent(events.DEV_LAUNCH_SPREAD_EMITTER, {
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
    if symbol == "v" or key.code == input.KEY.V then
        if not dev.devLaunchEnabled() then
            log.info(string.format("SKIP smoke dev Spread: enable %s", dev.devLaunchSettingKey()))
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
                    log.info(string.format("SKIP smoke dev Spread: enable %s", dev.devLaunchSettingKey()))
                end
                return
            end
            if state.backend == "INIT" then
                requestBackend()
            elseif state.backend == "READY" and not state.ready_logged then
                state.ready_logged = true
                log.info("smoke dev Spread ready: aim at a broad valid target/surface and press V")
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
                local done = cb(payload)
                if done then
                    state.pending_hit[request_id] = nil
                end
            end
        end,
    },
}
