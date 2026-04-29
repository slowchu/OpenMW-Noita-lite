local async = require("openmw.async")
local camera = require("openmw.camera")
local core = require("openmw.core")
local input = require("openmw.input")
local nearby = require("openmw.nearby")
local self = require("openmw.self")
local types = require("openmw.types")
local util = require("openmw.util")

local dev = require("scripts.spellforge.shared.dev")
local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_live_simple_dispatch")
local smoke_keys = require("scripts.spellforge.tests.smoke_keys")

local state = {
    backend = "INIT",
    handshake_timer = nil,
    running = false,
    skip_logged = false,
    ready_logged = false,
    pending_probe = {},
    pending_compile = {},
    pending_observe = {},
    pending_stats = {},
    last_spell_id = nil,
    intercept_seen = false,
    intercept_live_2_2c = false,
    intercept_projectile_registered = false,
    intercept_projectile_id = nil,
    intercept_slot_id = nil,
    intercept_helper_engine_id = nil,
    intercept_dispatch_kind = nil,
    intercept_runtime = nil,
    intercept_fallback = nil,
    intercept_cast_id = nil,
}

local DEBUG_MARKER_RANGE_FROM_ROOT = true

local KNOWN_COMBAT_SPELL_IDS = {
    "fireball",
    "frostball",
    "lightning bolt",
    "fire bite",
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

local function resolveSmokeBaseSpellId()
    for _, spell_id in ipairs(KNOWN_COMBAT_SPELL_IDS) do
        if core.magic.spells.records[spell_id] then
            return spell_id
        end
    end
    return nil
end

local function spellbookHasSpell(actor, spell_id)
    local actor_spells = types.Actor.spells(actor)
    for _, entry in pairs(actor_spells) do
        if entry and entry.id == spell_id then
            return true
        end
    end
    return false
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

local function requestProbe(mode, callback, extra)
    local request_id = nextRequestId("smoke-live-simple-probe")
    waitFor(state.pending_probe, request_id, 5, callback)
    local payload = extra or {}
    payload.sender = self.object
    payload.actor = self
    payload.request_id = request_id
    payload.mode = mode
    local function sendProbe()
        core.sendGlobalEvent(events.LIVE_SIMPLE_DISPATCH_PROBE, payload)
    end
    if type(mode) == "string" and string.sub(mode, 1, 6) == "chaos_" and mode ~= "chaos_budget_report" then
        async:newUnsavableSimulationTimer(0.5, sendProbe)
    else
        sendProbe()
    end
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

local function launchAimPayload(extra)
    local start_pos, direction, hit_object = currentLaunchAim()
    local payload = {}
    for key, value in pairs(extra or {}) do
        payload[key] = value
    end
    payload.start_pos = start_pos
    payload.direction = direction
    payload.hit_object = hit_object
    return payload
end

local function requestTimerDelayCheck(timer_id, expected_payload_count, callback, extra)
    local payload = {}
    for key, value in pairs(extra or {}) do
        payload[key] = value
    end
    payload.timer_id = timer_id
    payload.expected_payload_count = expected_payload_count
    payload.observe_matured = true
    if tonumber(expected_payload_count) ~= nil and tonumber(expected_payload_count) > 8 then
        payload.allow_pending_launch_jobs = true
    end
    if payload.simulate_nested_trigger_hit == true then
        payload.allow_pending_launch_jobs = true
    end
    local delay_seconds = tonumber(payload.delay_seconds) or 1.15
    payload.delay_seconds = nil
    async:newUnsavableSimulationTimer(delay_seconds, function()
        requestProbe("timer_real_delay_check", callback, payload)
    end)
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

local function listCount(values)
    if type(values) ~= "table" then
        return 0
    end
    return #values
end

local function jobsAllComplete(jobs, expected_count)
    if type(jobs) ~= "table" or #jobs ~= expected_count then
        return false
    end
    for _, job in ipairs(jobs) do
        if job.job_status ~= "complete" or job.launch_accepted ~= true then
            return false
        end
    end
    return true
end

local function requestJobsStatus(job_ids, expected_count, callback)
    requestProbe("jobs_status_check", callback, {
        job_ids = job_ids or {},
        expected_count = expected_count,
    })
end

local function waitForJobsComplete(job_ids, expected_count, callback, opts)
    local options = opts or {}
    local attempts = 0
    local max_attempts = tonumber(options.max_attempts) or 24
    local delay_seconds = tonumber(options.delay_seconds) or 0.15

    local function poll()
        attempts = attempts + 1
        requestJobsStatus(job_ids, expected_count, function(result)
            if result and result.all_complete == true then
                callback(result)
                return
            end
            if attempts >= max_attempts then
                callback(result or {
                    ok = false,
                    error = "jobs wait timeout",
                    job_ids = job_ids,
                    expected_count = expected_count,
                })
                return
            end
            async:newUnsavableSimulationTimer(delay_seconds, poll)
        end)
    end

    async:newUnsavableSimulationTimer(delay_seconds, poll)
end

local function jobsCarryMulticastUserData(jobs, expected_count, cast_id)
    if type(jobs) ~= "table" or #jobs ~= expected_count then
        return false
    end
    local seen_slots = {}
    local seen_emissions = {}
    for _, job in ipairs(jobs) do
        local user_data = job.launch_user_data
        if type(user_data) ~= "table"
            or user_data.spellforge ~= true
            or user_data.schema ~= "spellforge_sfp_userdata_v1"
            or user_data.runtime ~= "2.2c_live_helper"
            or user_data.cast_id ~= cast_id
            or user_data.fanout_count ~= expected_count
            or type(user_data.emission_index) ~= "number"
            or type(user_data.slot_id) ~= "string"
            or type(user_data.helper_engine_id) ~= "string" then
            return false
        end
        seen_slots[user_data.slot_id] = true
        seen_emissions[user_data.emission_index] = true
    end
    return tableCount(seen_slots) == expected_count and tableCount(seen_emissions) == expected_count
end

local function jobsCarryPatternUserData(jobs, expected_count, cast_id, pattern_kind)
    if type(jobs) ~= "table" or #jobs ~= expected_count then
        return false
    end
    local seen_patterns = {}
    for _, job in ipairs(jobs) do
        local user_data = job.launch_user_data
        if type(user_data) ~= "table"
            or user_data.spellforge ~= true
            or user_data.schema ~= "spellforge_sfp_userdata_v1"
            or user_data.runtime ~= "2.2c_live_helper"
            or user_data.cast_id ~= cast_id
            or user_data.fanout_count ~= expected_count
            or user_data.pattern_kind ~= pattern_kind
            or user_data.pattern_count ~= expected_count
            or type(user_data.pattern_index) ~= "number"
            or type(user_data.emission_index) ~= "number" then
            return false
        end
        seen_patterns[user_data.pattern_index] = true
    end
    return tableCount(seen_patterns) == expected_count
end

local function jobsCarrySpeedPlusUserData(jobs, expected_count, cast_id)
    if type(jobs) ~= "table" or #jobs ~= expected_count then
        return false
    end
    for _, job in ipairs(jobs) do
        local user_data = job.launch_user_data
        if type(user_data) ~= "table"
            or user_data.spellforge ~= true
            or user_data.schema ~= "spellforge_sfp_userdata_v1"
            or user_data.runtime ~= "2.2c_live_helper"
            or user_data.cast_id ~= cast_id
            or user_data.speed_plus ~= true
            or user_data.speed_plus_mode ~= "initial_speed"
            or user_data.speed_plus_field ~= "speed"
            or type(user_data.speed_plus_base_speed) ~= "number"
            or type(user_data.speed_plus_multiplier) ~= "number"
            or type(user_data.speed_plus_speed) ~= "number"
            or user_data.speed_plus_speed == user_data.speed_plus_base_speed then
            return false
        end
    end
    return true
end

local function jobsCarrySizePlusUserData(jobs, expected_count, cast_id)
    if type(jobs) ~= "table" or #jobs ~= expected_count then
        return false
    end
    for _, job in ipairs(jobs) do
        local user_data = job.launch_user_data
        if type(user_data) ~= "table"
            or user_data.spellforge ~= true
            or user_data.schema ~= "spellforge_sfp_userdata_v1"
            or user_data.runtime ~= "2.2c_live_helper"
            or user_data.cast_id ~= cast_id
            or user_data.size_plus ~= true
            or user_data.size_plus_mode ~= "multiplier"
            or user_data.size_plus_field ~= "effect.area"
            or type(user_data.size_plus_value) ~= "number"
            or type(user_data.size_plus_multiplier) ~= "number"
            or type(user_data.size_plus_base_area) ~= "number"
            or type(user_data.size_plus_area) ~= "number"
            or user_data.size_plus_area <= user_data.size_plus_base_area then
            return false
        end
    end
    return true
end

local function sourceJobCarriesTriggerUserData(result)
    local job = result and result.jobs and result.jobs[1] or nil
    local user_data = job and job.launch_user_data or nil
    return type(user_data) == "table"
        and user_data.spellforge == true
        and user_data.schema == "spellforge_sfp_userdata_v1"
        and user_data.runtime == "2.2c_live_helper"
        and user_data.cast_id == result.cast_id
        and user_data.slot_id == result.slot_id
        and user_data.helper_engine_id == result.helper_engine_id
        and user_data.depth == 0
        and user_data.source_postfix_opcode == "Trigger"
        and user_data.has_trigger_payload == true
        and user_data.trigger_source_slot_id == result.slot_id
        and user_data.trigger_payload_slot_id == result.trigger_payload_slot_id
end

local function payloadUserDataCarriesTrigger(result)
    local user_data = result and result.trigger_payload_launch_user_data or nil
    return type(user_data) == "table"
        and user_data.spellforge == true
        and user_data.schema == "spellforge_sfp_userdata_v1"
        and user_data.runtime == "2.2c_live_helper"
        and user_data.cast_id == result.cast_id
        and user_data.slot_id == result.trigger_payload_slot_id
        and user_data.payload_slot_id == result.trigger_payload_slot_id
        and user_data.source_slot_id == result.slot_id
        and user_data.source_helper_engine_id == result.helper_engine_id
        and user_data.source_postfix_opcode == "Trigger"
        and user_data.depth == 1
        and type(user_data.trigger_route) == "string"
end

local function sourceJobCarriesTimerUserData(result)
    local job = result and result.source_jobs and result.source_jobs[1] or nil
    local user_data = job and job.launch_user_data or nil
    return type(user_data) == "table"
        and user_data.spellforge == true
        and user_data.schema == "spellforge_sfp_userdata_v1"
        and user_data.runtime == "2.2c_live_helper"
        and user_data.cast_id == result.cast_id
        and user_data.slot_id == result.slot_id
        and user_data.helper_engine_id == result.helper_engine_id
        and user_data.depth == 0
        and user_data.source_postfix_opcode == "Timer"
        and user_data.has_timer_payload == true
        and user_data.timer_source_slot_id == result.slot_id
        and user_data.timer_payload_slot_id == result.timer_payload_slot_id
        and type(user_data.timer_delay_ticks) == "number"
        and type(user_data.timer_delay_seconds) == "number"
        and user_data.timer_delay_semantics == "async_simulation_timer"
end

local function payloadUserDataCarriesTimer(result)
    local user_data = result and result.timer_payload_launch_user_data or nil
    return type(user_data) == "table"
        and user_data.spellforge == true
        and user_data.schema == "spellforge_sfp_userdata_v1"
        and user_data.runtime == "2.2c_live_helper"
        and user_data.cast_id == result.cast_id
        and user_data.slot_id == result.timer_payload_slot_id
        and user_data.payload_slot_id == result.timer_payload_slot_id
        and user_data.source_slot_id == result.slot_id
        and user_data.source_helper_engine_id == result.helper_engine_id
        and user_data.source_postfix_opcode == "Timer"
        and user_data.depth == 1
        and user_data.timer_id == result.timer_id
        and user_data.timer_delay_ticks == result.timer_delay_ticks
        and user_data.timer_delay_seconds == result.timer_delay_seconds
        and user_data.timer_delay_semantics == "async_simulation_timer"
        and type(user_data.timer_due_tick) == "number"
        and type(user_data.timer_due_seconds) == "number"
end

local function payloadJobsCarryPostfixFanout(jobs, expected_count, cast_id, source_opcode, source_slot_id)
    if type(jobs) ~= "table" or #jobs ~= expected_count then
        return false
    end
    local seen_slots = {}
    local seen_emissions = {}
    for _, job in ipairs(jobs) do
        local user_data = job and job.launch_user_data or nil
        if type(user_data) ~= "table"
            or user_data.spellforge ~= true
            or user_data.schema ~= "spellforge_sfp_userdata_v1"
            or user_data.runtime ~= "2.2c_live_helper"
            or user_data.cast_id ~= cast_id
            or user_data.source_postfix_opcode ~= source_opcode
            or user_data.source_slot_id ~= source_slot_id
            or user_data.depth ~= 1
            or user_data.fanout_count ~= expected_count
            or type(user_data.payload_slot_id) ~= "string"
            or type(user_data.slot_id) ~= "string"
            or user_data.slot_id ~= user_data.payload_slot_id
            or type(user_data.emission_index) ~= "number" then
            return false
        end
        seen_slots[user_data.payload_slot_id] = true
        seen_emissions[user_data.emission_index] = true
    end
    return tableCount(seen_slots) == expected_count and tableCount(seen_emissions) == expected_count
end

local function payloadJobsCarryPostfixPattern(jobs, expected_count, cast_id, source_opcode, source_slot_id, pattern_kind)
    if not payloadJobsCarryPostfixFanout(jobs, expected_count, cast_id, source_opcode, source_slot_id) then
        return false
    end
    local seen_patterns = {}
    local seen_direction_keys = {}
    for _, job in ipairs(jobs or {}) do
        local user_data = job and job.launch_user_data or nil
        local direction_key = job and job.pattern_direction_key or nil
        if type(user_data) ~= "table"
            or user_data.pattern_kind ~= pattern_kind
            or user_data.pattern_count ~= expected_count
            or type(user_data.pattern_index) ~= "number"
            or type(user_data.pattern_direction_key) ~= "string"
            or type(direction_key) ~= "string"
            or user_data.pattern_direction_key ~= direction_key
            or job.pattern_kind ~= pattern_kind
            or job.pattern_count ~= expected_count
            or type(job.pattern_index) ~= "number"
            or job.launch_direction == nil then
            return false
        end
        seen_patterns[user_data.pattern_index] = true
        seen_direction_keys[direction_key] = true
    end
    return tableCount(seen_patterns) == expected_count and tableCount(seen_direction_keys) >= 2
end

local function nestedFinalFanoutJobsCarryUserData(jobs, expected_count, cast_id, source_opcode, source_slot_id, root_source_slot_id, pattern_kind)
    if type(jobs) ~= "table" or #jobs ~= expected_count then
        return false
    end
    local seen_slots = {}
    local seen_final_indexes = {}
    local seen_direction_keys = {}
    for _, job in ipairs(jobs) do
        local user_data = job and job.launch_user_data or nil
        if type(user_data) ~= "table"
            or user_data.spellforge ~= true
            or user_data.schema ~= "spellforge_sfp_userdata_v1"
            or user_data.runtime ~= "2.2c_live_helper"
            or user_data.cast_id ~= cast_id
            or user_data.source_postfix_opcode ~= source_opcode
            or user_data.source_slot_id ~= source_slot_id
            or user_data.root_source_slot_id ~= root_source_slot_id
            or user_data.current_source_slot_id ~= source_slot_id
            or user_data.depth ~= 2
            or user_data.payload_depth ~= 2
            or user_data.nested_final_fanout ~= true
            or user_data.final_fanout_count ~= expected_count
            or user_data.fanout_count ~= expected_count
            or type(user_data.final_fanout_index) ~= "number"
            or type(user_data.payload_slot_id) ~= "string"
            or type(user_data.slot_id) ~= "string"
            or user_data.slot_id ~= user_data.payload_slot_id then
            return false
        end
        if pattern_kind ~= nil then
            if user_data.pattern_kind ~= pattern_kind
                or user_data.pattern_count ~= expected_count
                or type(user_data.pattern_index) ~= "number"
                or type(user_data.pattern_direction_key) ~= "string"
                or job.pattern_kind ~= pattern_kind
                or job.pattern_count ~= expected_count
                or job.launch_direction == nil then
                return false
            end
            seen_direction_keys[user_data.pattern_direction_key] = true
        end
        seen_slots[user_data.payload_slot_id] = true
        seen_final_indexes[user_data.final_fanout_index] = true
    end
    if tableCount(seen_slots) ~= expected_count or tableCount(seen_final_indexes) ~= expected_count then
        return false
    end
    return pattern_kind == nil or tableCount(seen_direction_keys) >= 2
end

local function requestRuntimeStats(reset_before, callback)
    local request_id = nextRequestId("smoke-live-simple-stats")
    waitFor(state.pending_stats, request_id, 5, callback)
    core.sendGlobalEvent(events.RUNTIME_STATS_REQUEST, {
        sender = self.object,
        request_id = request_id,
        reset_before = reset_before == true,
    })
end

local function counter(snapshot, name)
    if type(snapshot) ~= "table" then
        return 0
    end
    return tonumber(snapshot[name]) or 0
end

local function assertCounterAtLeast(snapshot, name, minimum, label)
    local value = counter(snapshot, name)
    assertLine(value >= minimum, label, string.format("%s=%s expected>=%s", tostring(name), tostring(value), tostring(minimum)))
end

local function unsupportedContains(result, needle)
    for _, reason in ipairs(result and result.unsupported_reasons or {}) do
        if string.find(tostring(reason), needle, 1, true) ~= nil then
            return true
        end
    end
    return string.find(tostring(result and result.rejection_reason), needle, 1, true) ~= nil
end

local function compile(recipe, request_id)
    core.sendGlobalEvent(events.COMPILE_RECIPE, {
        sender = self.object,
        actor = self,
        actor_id = self.recordId,
        recipe = recipe,
        request_id = request_id,
        options = {
            debug_marker_range_from_root = DEBUG_MARKER_RANGE_FROM_ROOT,
        },
    })
end

local function runNestedAuditSmoke(callback)
    local cases = {
        {
            audit_case = "timer_simple",
            label = "simple Timer v0",
            check = function(result)
                assertLine(result and result.ok == true, "nested audit simple Timer ok", result and result.rejection_reason)
                assertLine(result and result.mode == "nested_payload_audit", "nested audit simple Timer mode")
                assertLine(result and result.audit_only == true and result.live_runtime_enabled == false, "nested audit simple Timer is audit-only")
                assertLine(result and result.timer_source_count == 1, "nested audit simple Timer source count")
                assertLine(result and result.timer_payload_count == 1, "nested audit simple Timer payload count")
                assertLine(result and result.nested_payload_count == 0, "nested audit simple Timer has no nested payload")
                assertLine(result and result.max_payload_depth == 1, "nested audit simple Timer depth is one")
                assertLine(result and result.live_safe_under_current_limits == true, "nested audit simple Timer is within limits")
                assertLine(result and result.future_runtime_candidate == false, "nested audit simple Timer is not a future-only candidate")
            end,
        },
        {
            audit_case = "trigger_simple",
            label = "simple Trigger v0",
            check = function(result)
                assertLine(result and result.ok == true, "nested audit simple Trigger ok", result and result.rejection_reason)
                assertLine(result and result.trigger_source_count == 1, "nested audit simple Trigger source count")
                assertLine(result and result.trigger_payload_count == 1, "nested audit simple Trigger payload count")
                assertLine(result and result.nested_payload_count == 0, "nested audit simple Trigger has no nested payload")
                assertLine(result and result.max_payload_depth == 1, "nested audit simple Trigger depth is one")
                assertLine(result and result.live_safe_under_current_limits == true, "nested audit simple Trigger is within limits")
            end,
        },
        {
            audit_case = "timer_payload_multicast",
            label = "Timer payload Multicast",
            check = function(result)
                assertLine(result and result.ok == true, "nested audit Timer payload Multicast ok", result and result.rejection_reason)
                assertLine(result and result.has_multicast_payload == true, "nested audit Timer payload Multicast classified")
                assertLine(result and result.timer_source_count == 1, "nested audit Timer payload Multicast source count")
                assertLine(result and result.payload_emission_count >= 3, "nested audit Timer payload Multicast payload emission count")
                assertLine(result and result.future_runtime_candidate == true, "nested audit Timer payload Multicast is future candidate")
                assertLine(result and result.live_runtime_enabled == false, "nested audit Timer payload Multicast does not enable runtime")
            end,
        },
        {
            audit_case = "trigger_payload_multicast",
            label = "Trigger payload Multicast",
            check = function(result)
                assertLine(result and result.ok == true, "nested audit Trigger payload Multicast ok", result and result.rejection_reason)
                assertLine(result and result.has_multicast_payload == true, "nested audit Trigger payload Multicast classified")
                assertLine(result and result.trigger_source_count == 1, "nested audit Trigger payload Multicast source count")
                assertLine(result and result.future_runtime_candidate == true, "nested audit Trigger payload Multicast is future candidate")
                assertLine(result and result.live_runtime_enabled == false, "nested audit Trigger payload Multicast does not enable runtime")
            end,
        },
        {
            audit_case = "timer_payload_burst_multicast",
            label = "Timer payload Burst+Multicast",
            check = function(result)
                assertLine(result and result.ok == true, "nested audit Timer payload Burst+Multicast ok", result and result.rejection_reason)
                assertLine(result and result.has_multicast_payload == true, "nested audit Timer payload Burst+Multicast has multicast payload")
                assertLine(result and result.has_pattern_payload == true, "nested audit Timer payload Burst+Multicast has pattern payload")
                assertLine(result and result.future_runtime_candidate == true, "nested audit Timer payload Burst+Multicast is future candidate")
            end,
        },
        {
            audit_case = "trigger_inside_timer",
            label = "Trigger inside Timer",
            check = function(result)
                assertLine(result and result.ok == true, "nested audit Trigger inside Timer ok", result and result.rejection_reason)
                assertLine(result and result.has_timer_payload == true, "nested audit Trigger inside Timer has Timer payload")
                assertLine(result and result.has_trigger_payload == true, "nested audit Trigger inside Timer has Trigger payload")
                assertLine(result and result.nested_payload_count >= 1, "nested audit Trigger inside Timer nested payload count")
                assertLine(result and result.max_payload_depth >= 2, "nested audit Trigger inside Timer depth")
                assertLine(result and result.future_runtime_candidate == true, "nested audit Trigger inside Timer is future candidate")
            end,
        },
        {
            audit_case = "timer_inside_trigger",
            label = "Timer inside Trigger",
            check = function(result)
                assertLine(result and result.ok == true, "nested audit Timer inside Trigger ok", result and result.rejection_reason)
                assertLine(result and result.has_trigger_payload == true, "nested audit Timer inside Trigger has Trigger payload")
                assertLine(result and result.has_timer_payload == true, "nested audit Timer inside Trigger has Timer payload")
                assertLine(result and result.nested_payload_count >= 1, "nested audit Timer inside Trigger nested payload count")
                assertLine(result and result.max_payload_depth >= 2, "nested audit Timer inside Trigger depth")
                assertLine(result and result.future_runtime_candidate == true, "nested audit Timer inside Trigger is future candidate")
            end,
        },
        {
            audit_case = "timer_payload_speed_plus",
            label = "Timer payload Speed+",
            check = function(result)
                assertLine(result and result.ok == true, "nested audit Timer payload Speed+ ok", result and result.rejection_reason)
                assertLine(result and result.has_speed_plus_payload == true, "nested audit Timer payload Speed+ classified")
                assertLine(result and result.future_runtime_candidate == true, "nested audit Timer payload Speed+ is future candidate")
            end,
        },
        {
            audit_case = "timer_payload_size_plus",
            label = "Timer payload Size+",
            check = function(result)
                assertLine(result and result.ok == true, "nested audit Timer payload Size+ ok", result and result.rejection_reason)
                assertLine(result and result.has_size_plus_payload == true, "nested audit Timer payload Size+ classified")
                assertLine(result and result.future_runtime_candidate == true, "nested audit Timer payload Size+ is future candidate")
            end,
        },
        {
            audit_case = "chain",
            label = "Chain rejection",
            check = function(result)
                assertLine(result and result.has_chain == true, "nested audit Chain classified")
                assertLine(result and result.future_runtime_candidate == false, "nested audit Chain is not future candidate")
                assertLine(result and (result.ok == false or result.live_safe_under_current_limits == false), "nested audit Chain is rejected or unsafe")
                assertLine(unsupportedContains(result, "chain"), "nested audit Chain rejection reason mentions chain")
            end,
        },
        {
            audit_case = "depth_rejection",
            label = "Depth rejection",
            check = function(result)
                local cap_rejected = result and (result.exceeds_depth_cap == true or result.exceeds_job_cap == true or result.exceeds_projectile_cap == true)
                assertLine(cap_rejected == true, "nested audit over-cap shape is rejected by a cap")
                assertLine(result and result.live_safe_under_current_limits == false, "nested audit over-cap shape is not live safe")
                assertLine(type(result and result.rejection_reason) == "string", "nested audit over-cap shape has rejection reason")
            end,
        },
    }

    requestRuntimeStats(false, function(before_stats)
        local before_snapshot = before_stats and before_stats.snapshot or {}
        local before_launches = counter(before_snapshot, "sfp_launch_attempts")

        local function runCase(index)
            local case = cases[index]
            if not case then
                requestRuntimeStats(false, function(after_stats)
                    local after_snapshot = after_stats and after_stats.snapshot or {}
                    assertLine(counter(after_snapshot, "sfp_launch_attempts") == before_launches, "nested audit probes do not call SFP launch")
                    assertCounterAtLeast(after_snapshot, "nested_payload_audit_attempts", #cases, "runtime stats counted nested audit attempts")
                    assertCounterAtLeast(after_snapshot, "nested_payload_audit_ok", #cases - 2, "runtime stats counted nested audit ok cases")
                    assertCounterAtLeast(after_snapshot, "nested_payload_audit_rejected", 2, "runtime stats counted nested audit rejected cases")
                    assertCounterAtLeast(after_snapshot, "nested_payload_audit_future_candidates", 7, "runtime stats counted nested audit future candidates")
                    assertCounterAtLeast(after_snapshot, "nested_payload_audit_chain_deferred", 1, "runtime stats counted Chain deferred audit")
                    assertCounterAtLeast(after_snapshot, "nested_payload_audit_cap_rejections", 1, "runtime stats counted nested audit cap rejection")
                    log.info("smoke nested payload audit run complete")
                    callback()
                end)
                return
            end

            requestProbe("nested_payload_audit", function(result)
                assertLine(result and result.mode == "nested_payload_audit", "nested audit " .. case.label .. " returns audit mode")
                assertLine(result and result.audit_only == true and result.live_runtime_enabled == false, "nested audit " .. case.label .. " is audit-only")
                assertLine(result and result.sfp_launch_unchanged == true, "nested audit " .. case.label .. " does not call SFP")
                case.check(result)
                runCase(index + 1)
            end, {
                audit_case = case.audit_case,
            })
        end

        runCase(1)
    end)
end

local function selectedTargetId(result)
    return result
        and result.selected_targets
        and result.selected_targets[1]
        and result.selected_targets[1].id
        or nil
end

local function exclusionContains(result, reason)
    for _, entry in ipairs(result and result.exclusion_reasons or {}) do
        if entry and entry.reason == reason then
            return true
        end
    end
    return false
end

local function selectedSequence(result)
    return table.concat(result and result.selected_target_ids or {}, ",")
end

local function chainPayloadJobsCarryUserData(jobs, expected_count, chain_id, max_hops)
    if type(jobs) ~= "table" or #jobs ~= expected_count then
        return false
    end
    for index, job in ipairs(jobs) do
        local user_data = job and job.launch_user_data or nil
        if type(user_data) ~= "table"
            or user_data.runtime ~= "2.2c_live_helper"
            or user_data.chain_runtime ~= true
            or user_data.chain_role ~= "payload"
            or user_data.chain_id ~= chain_id
            or tonumber(user_data.chain_hop_index) ~= index
            or tonumber(user_data.chain_max_hops) ~= tonumber(max_hops)
            or user_data.chain_targeting_mode ~= "no_immediate_repeat"
            or type(user_data.selected_target_id) ~= "string"
            or type(user_data.payload_slot_id) ~= "string" then
            return false
        end
    end
    return true
end

local function runChainTargetingSmoke(callback)
    local cases = {
        {
            chain_case = "direct_chain_3",
            label = "direct Chain 3 audit",
            check = function(result)
                assertLine(result and result.mode == "chain_targeting_audit", "Chain audit direct Chain 3 returns Chain mode")
                assertLine(result and result.audit_only == true and result.runtime_enabled == false, "Chain audit direct Chain 3 is audit-only")
                assertLine(result and result.has_chain == true, "Chain audit direct Chain 3 detects Chain")
                assertLine(result and tonumber(result.requested_hops) == 3, "Chain audit direct Chain 3 reports requested hops")
                assertLine(result and tonumber(result.max_hops) == 3, "Chain audit direct Chain 3 reports max hops")
                assertLine(result and result.chain_candidate == true, "Chain audit direct Chain 3 is a Chain v0 candidate")
                assertLine(result and result.future_runtime_candidate == true, "Chain audit direct Chain 3 is a future runtime candidate")
                assertLine(result and result.completed_hops == 3, "Chain audit direct Chain 3 completes three dry-run hops")
                assertLine(selectedSequence(result) == "B,A,B", "Chain audit direct Chain 3 can bounce B,A,B", selectedSequence(result))
                assertLine(result and result.would_enqueue_jobs == 3 and result.would_launch_payloads == 3, "Chain audit direct Chain 3 reports three future jobs")
            end,
        },
        {
            chain_case = "trigger_chain_3",
            label = "Trigger Chain 3 audit",
            check = function(result)
                assertLine(result and result.mode == "chain_targeting_audit", "Chain audit Trigger Chain 3 returns Chain mode")
                assertLine(result and result.audit_only == true and result.runtime_enabled == false, "Chain audit Trigger Chain 3 is audit-only")
                assertLine(result and result.has_chain == true, "Chain audit Trigger Chain 3 detects Chain")
                assertLine(result and result.has_trigger_payload_context == true, "Chain audit Trigger Chain 3 reports Trigger payload context")
                assertLine(result and tonumber(result.requested_hops) == 3, "Chain audit Trigger Chain 3 reports requested hops")
                assertLine(result and result.chain_candidate == true, "Chain audit Trigger Chain 3 is a future Chain candidate")
                assertLine(result and result.future_runtime_candidate == true, "Chain audit Trigger Chain 3 is future runtime candidate")
                assertLine(result and result.completed_hops == 3, "Chain audit Trigger Chain 3 completes three dry-run hops")
                assertLine(selectedSequence(result) == "B,A,B", "Chain audit Trigger Chain 3 can bounce B,A,B", selectedSequence(result))
            end,
        },
        {
            chain_case = "hop_bounce",
            label = "Chain hop bounce dry-run",
            check = function(result)
                assertLine(result and result.mode == "chain_hop_dry_run", "Chain hop dry-run mode")
                assertLine(result and result.audit_only == true and result.runtime_enabled == false, "Chain hop dry-run is audit-only")
                assertLine(result and tonumber(result.requested_hops) == 3, "Chain hop dry-run requested three hops")
                assertLine(result and result.completed_hops == 3, "Chain hop dry-run completes three hops")
                assertLine(result and result.stop_reason == "max_hops_reached", "Chain hop dry-run stops at max hops", result and result.stop_reason)
                assertLine(selectedSequence(result) == "B,A,B", "Chain hop dry-run permits A/B bounce under no_immediate_repeat", selectedSequence(result))
                assertLine(result and result.hops and result.hops[1] and result.hops[1].excluded_current_target_id == "A", "Chain hop 1 excludes current target A")
                assertLine(result and result.hops and result.hops[2] and result.hops[2].excluded_current_target_id == "B", "Chain hop 2 excludes current target B")
                assertLine(result and result.hops and result.hops[3] and result.hops[3].excluded_current_target_id == "A", "Chain hop 3 excludes current target A again")
            end,
        },
        {
            chain_case = "resolve_nearest",
            label = "mock nearest target",
            check = function(result)
                assertLine(result and result.ok == true, "Chain resolver nearest target ok", result and result.rejection_reason)
                assertLine(selectedTargetId(result) == "C", "Chain resolver selects C before B by distance", selectedTargetId(result))
                assertLine(exclusionContains(result, "excluded_caster"), "Chain resolver excludes caster")
                assertLine(exclusionContains(result, "excluded_current_hit_target"), "Chain resolver excludes current hit target")
                assertLine(exclusionContains(result, "candidate_invalid"), "Chain resolver excludes invalid target")
                assertLine(exclusionContains(result, "candidate_dead"), "Chain resolver excludes dead target")
                assertLine(exclusionContains(result, "candidate_non_actor"), "Chain resolver excludes non-actor")
                assertLine(exclusionContains(result, "candidate_different_cell"), "Chain resolver excludes different-cell target")
            end,
        },
        {
            chain_case = "tie",
            label = "deterministic tie-break",
            check = function(result)
                assertLine(result and result.ok == true, "Chain resolver tie-break ok", result and result.rejection_reason)
                assertLine(selectedTargetId(result) == "A", "Chain resolver tie-break selects stable id A", selectedTargetId(result))
                assertLine(result and result.repeat_selected_target_id == "A", "Chain resolver repeated tie-break is deterministic")
                assertLine(result and result.input_mutated == false, "Chain resolver does not mutate input candidates")
            end,
        },
        {
            chain_case = "hop_no_target",
            label = "hop no valid target",
            check = function(result)
                assertLine(result and result.mode == "chain_hop_dry_run", "Chain hop no-target returns hop dry-run mode")
                assertLine(result and result.ok == false, "Chain hop no-target rejects")
                assertLine(result and result.completed_hops == 0, "Chain hop no-target completes zero hops")
                assertLine(result and result.stop_reason == "no_valid_chain_target", "Chain hop no-target stop reason is stable", result and result.stop_reason)
            end,
        },
        {
            chain_case = "no_valid",
            label = "resolver no valid target",
            check = function(result)
                assertLine(result and result.ok == false, "Chain resolver no-valid rejects")
                assertLine(result and result.rejection_reason == "no_valid_chain_target", "Chain resolver no-valid rejection reason is stable", result and result.rejection_reason)
                assertLine(result and result.selected_count == 0, "Chain resolver no-valid selects zero targets")
            end,
        },
        {
            chain_case = "radius",
            label = "radius rejection",
            check = function(result)
                assertLine(result and result.ok == false, "Chain resolver radius rejects")
                assertLine(exclusionContains(result, "candidate_out_of_radius"), "Chain resolver records out-of-radius exclusion")
                assertLine(result and result.selected_count == 0, "Chain resolver radius selects zero targets")
            end,
        },
        {
            chain_case = "candidate_cap",
            label = "candidate cap",
            check = function(result)
                assertLine(result and result.ok == true, "Chain resolver candidate-cap still resolves within cap", result and result.rejection_reason)
                assertLine(result and result.exceeds_candidate_cap == true, "Chain resolver candidate-cap reports cap")
                assertLine(tonumber(result and result.considered_candidate_count) == 16, "Chain resolver considers only capped candidates")
            end,
        },
        {
            chain_case = "invalid_zero",
            label = "Chain zero-hop rejection",
            check = function(result)
                assertLine(result and result.ok == false, "Chain zero-hop recipe rejects")
                assertLine(result and tonumber(result.requested_hops) == 0, "Chain zero-hop reports requested hops")
                assertLine(unsupportedContains(result, "hops") or unsupportedContains(result, "Chain"), "Chain zero-hop rejection mentions hops or Chain")
            end,
        },
        {
            chain_case = "invalid_negative",
            label = "Chain negative-hop rejection",
            check = function(result)
                assertLine(result and result.ok == false, "Chain negative-hop recipe rejects")
                assertLine(result and tonumber(result.requested_hops) == -1, "Chain negative-hop reports requested hops")
                assertLine(unsupportedContains(result, "hops") or unsupportedContains(result, "Chain"), "Chain negative-hop rejection mentions hops or Chain")
            end,
        },
        {
            chain_case = "over_cap",
            label = "Chain over-cap rejection",
            check = function(result)
                assertLine(result and result.ok == false, "Chain over-cap recipe rejects")
                assertLine(result and tonumber(result.requested_hops) ~= nil and tonumber(result.requested_hops) > 3, "Chain over-cap reports requested hops")
                assertLine(unsupportedContains(result, "hops") or unsupportedContains(result, "Chain"), "Chain over-cap rejection mentions hops or Chain")
            end,
        },
        {
            chain_case = "multicast",
            label = "Chain Multicast deferral",
            check = function(result)
                assertLine(result and result.ok == false, "Chain audit Multicast is deferred")
                assertLine(result and result.has_chain_with_multicast == true, "Chain audit Multicast classified")
                assertLine(unsupportedContains(result, "chain_multicast"), "Chain audit Multicast rejection reason is specific")
            end,
        },
        {
            chain_case = "pattern",
            label = "Chain pattern deferral",
            check = function(result)
                assertLine(result and result.ok == false, "Chain audit pattern is deferred")
                assertLine(result and result.has_chain_with_pattern == true, "Chain audit pattern classified")
                assertLine(unsupportedContains(result, "chain_pattern"), "Chain audit pattern rejection reason is specific")
            end,
        },
        {
            chain_case = "trigger_timer",
            label = "Chain Trigger/Timer deferral",
            check = function(result)
                assertLine(result and result.ok == false, "Chain audit Trigger/Timer is deferred")
                assertLine(result and result.has_chain_with_trigger_timer == true, "Chain audit Trigger/Timer classified")
                assertLine(unsupportedContains(result, "chain_trigger_timer"), "Chain audit Trigger/Timer rejection reason is specific")
            end,
        },
        {
            chain_case = "nested_payload",
            label = "Trigger payload then Chain deferral",
            check = function(result)
                assertLine(result and result.ok == false, "Chain audit Trigger payload then Chain is deferred")
                assertLine(result and result.has_chain_in_nested_payload == true, "Chain audit Trigger payload then Chain classified")
                assertLine(unsupportedContains(result, "chain_nested_payload"), "Chain audit Trigger payload then Chain rejection reason is specific")
            end,
        },
        {
            chain_case = "trigger_chain_multicast",
            label = "Trigger Chain Multicast deferral",
            check = function(result)
                assertLine(result and result.ok == false, "Chain audit Trigger Chain Multicast is deferred")
                assertLine(result and result.has_chain_with_multicast == true, "Chain audit Trigger Chain Multicast classified")
                assertLine(unsupportedContains(result, "chain_multicast"), "Chain audit Trigger Chain Multicast rejection reason is specific")
            end,
        },
        {
            chain_case = "nested_trigger_timer",
            label = "nested Trigger/Timer Chain deferral",
            check = function(result)
                assertLine(result and result.ok == false, "Chain audit nested Trigger/Timer is deferred")
                assertLine(result and result.has_chain_in_nested_payload == true, "Chain audit nested Trigger/Timer classified")
                assertLine(unsupportedContains(result, "chain_nested_payload"), "Chain audit nested Trigger/Timer rejection reason is specific")
            end,
        },
        {
            chain_case = "recursion",
            label = "Chain recursion deferral",
            check = function(result)
                assertLine(result and result.ok == false, "Chain audit recursion is deferred")
                assertLine(result and result.has_nested_chain == true, "Chain audit recursion classified")
                assertLine(unsupportedContains(result, "chain_recursion"), "Chain audit recursion rejection reason is specific")
            end,
        },
        {
            chain_case = "runtime_deferred",
            label = "live Chain runtime deferral",
            check = function(result)
                assertLine(result and result.ok == true, "live Chain runtime remains deferred", result and result.fallback_reason)
                assertLine(result and result.runtime_dispatch_deferred == true, "live Chain runtime probe does not dispatch")
                assertLine(result and result.sfp_launch_unchanged == true, "live Chain runtime deferral does not call SFP")
            end,
        },
    }

    requestRuntimeStats(false, function(before_stats)
        local before_snapshot = before_stats and before_stats.snapshot or {}
        local before_launches = counter(before_snapshot, "sfp_launch_attempts")

        local function runCase(index)
            local case = cases[index]
            if not case then
                requestRuntimeStats(false, function(after_stats)
                    local after_snapshot = after_stats and after_stats.snapshot or {}
                    assertLine(counter(after_snapshot, "sfp_launch_attempts") == before_launches, "Chain audit probes do not call SFP launch")
                    assertCounterAtLeast(after_snapshot, "chain_audit_attempts", 10, "runtime stats counted Chain audit attempts")
                    assertCounterAtLeast(after_snapshot, "chain_audit_ok", 2, "runtime stats counted Chain audit ok")
                    assertCounterAtLeast(after_snapshot, "chain_audit_rejected", 7, "runtime stats counted Chain audit rejections")
                    assertCounterAtLeast(after_snapshot, "chain_audit_future_candidate", 2, "runtime stats counted Chain future candidate")
                    assertCounterAtLeast(after_snapshot, "chain_hop_dry_run_attempts", 4, "runtime stats counted Chain hop dry-run attempts")
                    assertCounterAtLeast(after_snapshot, "chain_hop_dry_run_ok", 3, "runtime stats counted Chain hop dry-run ok")
                    assertCounterAtLeast(after_snapshot, "chain_hop_dry_run_rejected", 1, "runtime stats counted Chain hop dry-run rejection")
                    assertCounterAtLeast(after_snapshot, "chain_hops_requested", 9, "runtime stats counted Chain requested hops")
                    assertCounterAtLeast(after_snapshot, "chain_hops_completed", 9, "runtime stats counted Chain completed hops")
                    assertCounterAtLeast(after_snapshot, "chain_hop_stop_max", 3, "runtime stats counted Chain max-hop stop")
                    assertCounterAtLeast(after_snapshot, "chain_hop_stop_no_target", 1, "runtime stats counted Chain no-target stop")
                    assertCounterAtLeast(after_snapshot, "chain_target_resolve_attempts", 6, "runtime stats counted Chain target resolve attempts")
                    assertCounterAtLeast(after_snapshot, "chain_target_resolve_ok", 4, "runtime stats counted Chain target resolve ok")
                    assertCounterAtLeast(after_snapshot, "chain_target_candidates_seen", 8, "runtime stats counted Chain candidates seen")
                    assertCounterAtLeast(after_snapshot, "chain_target_candidates_valid", 1, "runtime stats counted Chain valid candidates")
                    assertCounterAtLeast(after_snapshot, "chain_target_candidates_selected", 1, "runtime stats counted Chain selected candidates")
                    assertCounterAtLeast(after_snapshot, "chain_target_no_target_reject", 2, "runtime stats counted Chain no-target rejection")
                    assertCounterAtLeast(after_snapshot, "chain_target_radius_reject", 1, "runtime stats counted Chain radius rejection")
                    assertCounterAtLeast(after_snapshot, "chain_target_cap_reject", 1, "runtime stats counted Chain candidate cap")
                    assertCounterAtLeast(after_snapshot, "chain_target_nested_reject", 1, "runtime stats counted Chain nested rejection")
                    assertCounterAtLeast(after_snapshot, "chain_target_multicast_reject", 1, "runtime stats counted Chain Multicast rejection")
                    assertCounterAtLeast(after_snapshot, "chain_target_pattern_reject", 1, "runtime stats counted Chain pattern rejection")
                    assertCounterAtLeast(after_snapshot, "chain_target_trigger_timer_reject", 1, "runtime stats counted Chain Trigger/Timer rejection")
                    assertCounterAtLeast(after_snapshot, "chain_target_recursion_reject", 1, "runtime stats counted Chain recursion rejection")
                    assertCounterAtLeast(after_snapshot, "chain_target_runtime_deferred", 1, "runtime stats counted live Chain runtime deferral")
                    assertCounterAtLeast(after_snapshot, "chain_target_no_immediate_repeat_exclusions", 3, "runtime stats counted Chain no-immediate-repeat exclusions")
                    log.info("smoke Chain targeting audit run complete")
                    callback()
                end)
                return
            end

            requestProbe("chain_targeting_audit", function(result)
                assertLine(result and (result.mode == "chain_targeting_audit" or result.mode == "chain_hop_dry_run"), "Chain audit " .. case.label .. " returns Chain mode")
                assertLine(result and result.audit_only == true and result.runtime_enabled == false, "Chain audit " .. case.label .. " remains audit-only")
                assertLine(result and result.sfp_launch_unchanged == true, "Chain audit " .. case.label .. " does not call SFP")
                case.check(result)
                runCase(index + 1)
            end, {
                chain_case = case.chain_case,
            })
        end

        runCase(1)
    end)
end

local function beginObserve(spell_id, request_id)
    core.sendGlobalEvent(events.BEGIN_CAST_OBSERVE, {
        sender = self.object,
        spell_id = spell_id,
        request_id = request_id,
        timeout_seconds = 30,
    })
end

local function runManualCastStage()
    local base_spell_id = resolveSmokeBaseSpellId()
    assertLine(type(base_spell_id) == "string" and base_spell_id ~= "", "live simple smoke has target base spell")
    if not base_spell_id then
        state.running = false
        return
    end

    local trivial_recipe = {
        nodes = {
            { kind = "emitter", base_spell_id = base_spell_id },
        },
    }

    local compile_request_id = nextRequestId("smoke-live-simple-compile")
    compile(trivial_recipe, compile_request_id)
    waitFor(state.pending_compile, compile_request_id, 5, function(compile_result)
        assertLine(compile_result and compile_result.ok == true, "qualifying simple recipe compiles", compile_result and compile_result.error)
        if not compile_result or compile_result.ok ~= true then
            state.running = false
            return
        end

        assertLine(spellbookHasSpell(self, compile_result.spell_id) == true, "compiled simple spell appears in spellbook")
        state.last_spell_id = compile_result.spell_id
        state.intercept_seen = false
        state.intercept_live_2_2c = false
        state.intercept_projectile_registered = false
        state.intercept_projectile_id = nil
        state.intercept_slot_id = nil
        state.intercept_helper_engine_id = nil
        state.intercept_dispatch_kind = nil
        state.intercept_runtime = nil
        state.intercept_fallback = nil
        state.intercept_cast_id = nil

        local observe_request_id = nextRequestId("smoke-live-simple-observe")
        beginObserve(compile_result.spell_id, observe_request_id)
        log.info("manual cast required: select the compiled simple spell and cast within 30s")

        waitFor(state.pending_observe, observe_request_id, 30, function(hit_result)
            assertLine(state.intercept_seen == true, "intercept dispatched for compiled simple spell")
            assertLine(state.intercept_live_2_2c == true, "intercept used feature-flagged live 2.2c simple bridge")
            assertLine(state.intercept_dispatch_kind == "compiled_spellforge_2_2c_helper", "live bridge dispatch kind is distinct")
            assertLine(state.intercept_runtime == "2.2c_live_helper", "live bridge dispatch runtime is 2.2c_live_helper")
            assertLine(state.intercept_fallback == false, "live bridge dispatch did not fallback")
            assertLine(type(state.intercept_cast_id) == "string" and state.intercept_cast_id ~= "", "live bridge returned cast_id")
            assertLine(type(state.intercept_slot_id) == "string" and state.intercept_slot_id ~= "", "live bridge returned slot_id")
            assertLine(type(state.intercept_helper_engine_id) == "string" and state.intercept_helper_engine_id ~= "", "live bridge returned helper_engine_id")
            if state.intercept_projectile_id ~= nil then
                assertLine(state.intercept_projectile_registered == true, "live bridge projectile_id registered")
            else
                log.info("SKIP live bridge projectile_id registered: projectile_id unavailable")
            end

            local hit_ok = hit_result and hit_result.ok == true and hit_result.matched == true
            assertLine(hit_ok, "live 2.2c helper hit observed through shared routing", hit_result and hit_result.error)
            assertLine(hit_result and hit_result.live_2_2c == true, "live helper hit preserves 2.2b observer compatibility")
            assertLine(hit_result and hit_result.slot_id == state.intercept_slot_id, "live helper hit routes to bridge slot_id")
            assertLine(hit_result and hit_result.helper_engine_id == state.intercept_helper_engine_id, "live helper hit routes to bridge helper_engine_id")
            requestRuntimeStats(false, function(stats_result)
                local snapshot = stats_result and stats_result.snapshot or {}
                assertLine(stats_result and stats_result.ok == true, "runtime stats snapshot returned", stats_result and stats_result.error)
                assertCounterAtLeast(snapshot, "live_2_2c_attempts", 1, "runtime stats counted live 2.2c attempt")
                assertCounterAtLeast(snapshot, "live_2_2c_dry_run_attempts", 1, "runtime stats counted live 2.2c dry-run")
                assertCounterAtLeast(snapshot, "live_2_2c_qualified", 1, "runtime stats counted live 2.2c qualification")
                assertCounterAtLeast(snapshot, "live_2_2c_rejected", 1, "runtime stats counted non-qualifying fallback rejection")
                assertCounterAtLeast(snapshot, "live_2_2c_dispatch_ok", 1, "runtime stats counted live 2.2c dispatch ok")
                assertCounterAtLeast(snapshot, "compiled_dispatch_ok", 1, "runtime stats counted compatible compiled dispatch ok")
                assertCounterAtLeast(snapshot, "jobs_enqueued", 1, "runtime stats counted orchestrator enqueue")
                assertCounterAtLeast(snapshot, "live_helper_jobs_enqueued", 1, "runtime stats counted live helper enqueue")
                assertCounterAtLeast(snapshot, "jobs_processed", 1, "runtime stats counted orchestrator processing")
                assertCounterAtLeast(snapshot, "live_helper_jobs_processed", 1, "runtime stats counted live helper processing")
                assertCounterAtLeast(snapshot, "max_queue_depth", 1, "runtime stats tracked max queue depth")
                assertCounterAtLeast(snapshot, "queue_drained_observed", 1, "runtime stats observed queue drain")
                assertCounterAtLeast(snapshot, "sfp_launch_attempts", 1, "runtime stats counted SFP launch attempt")
                assertCounterAtLeast(snapshot, "sfp_launch_ok", 1, "runtime stats counted SFP launch ok")
                assertLine(
                    counter(snapshot, "hits_userdata_routed") + counter(snapshot, "hits_spellid_fallback_routed") >= 1,
                    "runtime stats counted helper hit route",
                    string.format("userData=%s spellIdFallback=%s", tostring(counter(snapshot, "hits_userdata_routed")), tostring(counter(snapshot, "hits_spellid_fallback_routed")))
                )
                for _, line in ipairs(stats_result and stats_result.summary_lines or {}) do
                    log.info("runtime stats " .. tostring(line))
                end
                log.info("smoke live simple dispatch run complete")
                state.running = false
            end)
        end)
    end)
end

local function runChainRuntimeSmoke(callback)
    local cases = {
        {
            chain_case = "disabled",
            label = "Chain runtime disabled rejection",
            check = function(result)
                assertLine(result and result.audit_future_runtime_candidate == true, "Chain runtime disabled probe keeps audit future candidate")
                assertLine(result and result.runtime_dispatch_deferred == true, "Chain runtime disabled probe defers live dispatch")
                assertLine(result and result.sfp_launch_unchanged == true, "Chain runtime disabled probe does not call SFP")
            end,
        },
        {
            chain_case = "chain_speed_plus_disabled",
            label = "Chain Speed+ disabled rejection",
            check = function(result)
                assertLine(result and result.fallback_reason == "chain_speed_plus_disabled", "Chain Speed+ disabled probe rejects clearly")
                assertLine(result and result.sfp_launch_attempts_before == result.sfp_launch_attempts_after, "Chain Speed+ disabled probe launches no payload")
            end,
        },
        {
            chain_case = "chain_size_plus_disabled",
            label = "Chain Size+ disabled rejection",
            check = function(result)
                assertLine(result and result.fallback_reason == "chain_size_plus_disabled", "Chain Size+ disabled probe rejects clearly")
                assertLine(result and result.sfp_launch_attempts_before == result.sfp_launch_attempts_after, "Chain Size+ disabled probe launches no payload")
            end,
        },
        {
            chain_case = "direct_chain_3",
            label = "direct Chain 3 live runtime",
            check = function(result)
                assertLine(result and result.live_mode == "chain", "direct Chain runtime reports Chain mode")
                assertLine(result and result.chain_shape == "source_chain_payload", "direct Chain runtime reports direct shape")
                assertLine(result and tonumber(result.max_hops) == 3, "direct Chain runtime reports max hops")
                assertLine(selectedSequence(result) == "B,A,B", "direct Chain runtime launches B,A,B sequence", selectedSequence(result))
                assertLine(result and result.chain_payload_launch_count == 3, "direct Chain runtime launches three Chain payloads")
                assertLine(result and result.stop_reason == "max_hops_reached", "direct Chain runtime stops at max hops", result and result.stop_reason)
                assertLine(result and result.duplicate_source_suppressed == true, "direct Chain runtime suppresses duplicate source hit")
                assertLine(result and result.branch_source_suppressed == true, "direct Chain runtime suppresses branched source hit")
                assertLine(result and result.duplicate_hop_suppressed == true, "direct Chain runtime suppresses duplicate chained hit")
                assertLine(result and result.branch_hop_suppressed == true, "direct Chain runtime suppresses branched chained hit")
                assertLine(chainPayloadJobsCarryUserData(result and result.chain_payload_jobs, 3, result and result.chain_id, result and result.max_hops), "direct Chain payload userData carries continuation identity")
            end,
        },
        {
            chain_case = "trigger_chain_3",
            label = "Trigger Chain 3 live runtime",
            check = function(result)
                assertLine(result and result.live_mode == "chain", "Trigger Chain runtime reports Chain mode")
                assertLine(result and result.chain_shape == "trigger_payload_chain", "Trigger Chain runtime reports Trigger payload shape")
                assertLine(selectedSequence(result) == "B,A,B", "Trigger Chain runtime launches B,A,B sequence", selectedSequence(result))
                assertLine(result and result.chain_payload_launch_count == 3, "Trigger Chain runtime launches three payloads after Trigger hit")
                assertLine(result and result.duplicate_source_suppressed == true, "Trigger Chain runtime suppresses duplicate root Trigger hit")
                assertLine(result and result.branch_source_suppressed == true, "Trigger Chain runtime suppresses branched root Trigger hit")
                assertLine(result and result.duplicate_hop_suppressed == true, "Trigger Chain runtime suppresses duplicate chained payload hit")
                assertLine(result and result.branch_hop_suppressed == true, "Trigger Chain runtime suppresses branched chained payload hit")
                assertLine(chainPayloadJobsCarryUserData(result and result.chain_payload_jobs, 3, result and result.chain_id, result and result.max_hops), "Trigger Chain payload userData carries continuation identity")
            end,
        },
        {
            chain_case = "direct_chain_speed_plus_3",
            label = "direct Chain 3 Speed+ live runtime",
            check = function(result)
                assertLine(result and result.payload_modifier_kind == "speed_plus", "direct Chain Speed+ reports payload modifier")
                assertLine(selectedSequence(result) == "B,A,B", "direct Chain Speed+ launches B,A,B sequence", selectedSequence(result))
                assertLine(result and result.chain_payload_launch_count == 3, "direct Chain Speed+ launches three modified payloads")
                assertLine(chainPayloadJobsCarryUserData(result and result.chain_payload_jobs, 3, result and result.chain_id, result and result.max_hops), "direct Chain Speed+ payload userData keeps Chain continuation")
                assertLine(jobsCarrySpeedPlusUserData(result and result.chain_payload_jobs, 3, result and result.dispatch and result.dispatch.cast_id), "direct Chain Speed+ payload userData keeps Speed+ metadata")
                assertLine(result and result.stop_reason == "max_hops_reached", "direct Chain Speed+ stops at max hops", result and result.stop_reason)
            end,
        },
        {
            chain_case = "trigger_chain_speed_plus_3",
            label = "Trigger Chain 3 Speed+ live runtime",
            check = function(result)
                assertLine(result and result.chain_shape == "trigger_payload_chain", "Trigger Chain Speed+ reports Trigger payload Chain shape")
                assertLine(result and result.payload_modifier_kind == "speed_plus", "Trigger Chain Speed+ reports payload modifier")
                assertLine(selectedSequence(result) == "B,A,B", "Trigger Chain Speed+ launches B,A,B sequence", selectedSequence(result))
                assertLine(result and result.chain_payload_launch_count == 3, "Trigger Chain Speed+ launches three modified payloads")
                assertLine(result and result.duplicate_source_suppressed == true, "Trigger Chain Speed+ suppresses duplicate root Trigger hit")
                assertLine(result and result.duplicate_hop_suppressed == true, "Trigger Chain Speed+ suppresses duplicate chained payload hit")
                assertLine(chainPayloadJobsCarryUserData(result and result.chain_payload_jobs, 3, result and result.chain_id, result and result.max_hops), "Trigger Chain Speed+ payload userData keeps Chain continuation")
                assertLine(jobsCarrySpeedPlusUserData(result and result.chain_payload_jobs, 3, result and result.dispatch and result.dispatch.cast_id), "Trigger Chain Speed+ payload userData keeps Speed+ metadata")
            end,
        },
        {
            chain_case = "direct_chain_size_plus_3",
            label = "direct Chain 3 Size+ live runtime",
            check = function(result)
                assertLine(result and result.payload_modifier_kind == "size_plus", "direct Chain Size+ reports payload modifier")
                assertLine(selectedSequence(result) == "B,A,B", "direct Chain Size+ launches B,A,B sequence", selectedSequence(result))
                assertLine(result and result.chain_payload_launch_count == 3, "direct Chain Size+ launches three modified payloads")
                assertLine(chainPayloadJobsCarryUserData(result and result.chain_payload_jobs, 3, result and result.chain_id, result and result.max_hops), "direct Chain Size+ payload userData keeps Chain continuation")
                assertLine(jobsCarrySizePlusUserData(result and result.chain_payload_jobs, 3, result and result.dispatch and result.dispatch.cast_id), "direct Chain Size+ payload userData keeps Size+ metadata")
                assertLine(result and result.stop_reason == "max_hops_reached", "direct Chain Size+ stops at max hops", result and result.stop_reason)
            end,
        },
        {
            chain_case = "trigger_chain_size_plus_3",
            label = "Trigger Chain 3 Size+ live runtime",
            check = function(result)
                assertLine(result and result.chain_shape == "trigger_payload_chain", "Trigger Chain Size+ reports Trigger payload Chain shape")
                assertLine(result and result.payload_modifier_kind == "size_plus", "Trigger Chain Size+ reports payload modifier")
                assertLine(selectedSequence(result) == "B,A,B", "Trigger Chain Size+ launches B,A,B sequence", selectedSequence(result))
                assertLine(result and result.chain_payload_launch_count == 3, "Trigger Chain Size+ launches three modified payloads")
                assertLine(result and result.duplicate_source_suppressed == true, "Trigger Chain Size+ suppresses duplicate root Trigger hit")
                assertLine(result and result.duplicate_hop_suppressed == true, "Trigger Chain Size+ suppresses duplicate chained payload hit")
                assertLine(chainPayloadJobsCarryUserData(result and result.chain_payload_jobs, 3, result and result.chain_id, result and result.max_hops), "Trigger Chain Size+ payload userData keeps Chain continuation")
                assertLine(jobsCarrySizePlusUserData(result and result.chain_payload_jobs, 3, result and result.dispatch and result.dispatch.cast_id), "Trigger Chain Size+ payload userData keeps Size+ metadata")
            end,
        },
        {
            chain_case = "no_valid",
            label = "Chain no-target early stop",
            check = function(result)
                assertLine(result and result.live_mode == "chain", "Chain no-target probe starts Chain runtime")
                assertLine(result and result.chain_payload_launch_count == 0, "Chain no-target probe launches no payload")
                assertLine(result and result.stop_reason == "no_valid_chain_target", "Chain no-target probe stops with stable reason", result and result.stop_reason)
            end,
        },
        {
            chain_case = "chain_speed_plus_no_valid",
            label = "Chain Speed+ no-target early stop",
            check = function(result)
                assertLine(result and result.live_mode == "chain", "Chain Speed+ no-target probe starts Chain runtime")
                assertLine(result and result.payload_modifier_kind == "speed_plus", "Chain Speed+ no-target probe keeps modifier metadata")
                assertLine(result and result.chain_payload_launch_count == 0, "Chain Speed+ no-target probe launches no payload")
                assertLine(result and result.stop_reason == "no_valid_chain_target", "Chain Speed+ no-target probe stops before mutation launch", result and result.stop_reason)
            end,
        },
        {
            chain_case = "filters",
            label = "Chain live candidate filters",
            check = function(result)
                assertLine(result and result.live_mode == "chain", "Chain filter probe reports Chain mode")
                assertLine(result and result.selected_target_ids and result.selected_target_ids[1] == "C", "Chain filter probe selects nearest valid target C", selectedSequence(result))
                assertLine(result and result.branch_source_suppressed == true, "Chain filter probe suppresses branched source hit")
            end,
        },
        {
            chain_case = "real_provider_availability",
            label = "Chain real provider availability probe",
            check = function(result)
                assertLine(result and (result.provider_supported == true or result.provider == "unavailable"), "Chain real provider reports supported or unavailable")
                assertLine(result and result.sfp_launch_unchanged == true, "Chain real provider availability probe does not call SFP")
            end,
        },
        {
            chain_case = "real_provider_no_target",
            label = "Chain real provider no-target stop",
            check = function(result)
                assertLine(result and result.live_mode == "chain", "Chain real provider no-target probe starts Chain runtime")
                assertLine(result and result.chain_payload_launch_count == 0, "Chain real provider no-target launches no Chain payload")
                assertLine(
                    result and (result.stop_reason == "no_valid_chain_target"
                        or result.stop_reason == "chain_target_provider_unavailable"),
                    "Chain real provider no-target stops safely",
                    result and result.stop_reason
                )
            end,
        },
        {
            chain_case = "invalid_zero",
            label = "Chain zero-hop live rejection",
            check = function(result)
                assertLine(result and result.fallback_reason ~= nil, "Chain zero-hop live rejection has reason")
            end,
        },
        {
            chain_case = "invalid_negative",
            label = "Chain negative-hop live rejection",
            check = function(result)
                assertLine(result and result.fallback_reason ~= nil, "Chain negative-hop live rejection has reason")
            end,
        },
        {
            chain_case = "over_cap",
            label = "Chain over-cap live rejection",
            check = function(result)
                assertLine(result and result.fallback_reason ~= nil, "Chain over-cap live rejection has reason")
            end,
        },
        {
            chain_case = "multicast",
            label = "Chain Multicast live deferral",
            check = function(result)
                assertLine(result and result.fallback_reason ~= nil, "Chain Multicast live defers")
            end,
        },
        {
            chain_case = "pattern",
            label = "Chain pattern live deferral",
            check = function(result)
                assertLine(result and result.fallback_reason ~= nil, "Chain pattern live defers")
            end,
        },
        {
            chain_case = "speed_plus_multicast",
            label = "Chain Speed+ Multicast live deferral",
            check = function(result)
                assertLine(result and result.fallback_reason == "chain_multicast_deferred", "Chain Speed+ Multicast live defers")
                assertLine(result and result.chain_payload_launch_count == 0, "Chain Speed+ Multicast launches no Chain payload")
            end,
        },
        {
            chain_case = "size_plus_multicast",
            label = "Chain Size+ Multicast live deferral",
            check = function(result)
                assertLine(result and result.fallback_reason == "chain_multicast_deferred", "Chain Size+ Multicast live defers")
                assertLine(result and result.chain_payload_launch_count == 0, "Chain Size+ Multicast launches no Chain payload")
            end,
        },
        {
            chain_case = "speed_plus_pattern",
            label = "Chain Speed+ pattern live deferral",
            check = function(result)
                assertLine(
                    result and (result.fallback_reason == "chain_multicast_deferred"
                        or result.fallback_reason == "chain_pattern_deferred"),
                    "Chain Speed+ pattern live defers"
                )
                assertLine(result and result.chain_payload_launch_count == 0, "Chain Speed+ pattern launches no Chain payload")
            end,
        },
        {
            chain_case = "size_plus_pattern",
            label = "Chain Size+ pattern live deferral",
            check = function(result)
                assertLine(
                    result and (result.fallback_reason == "chain_multicast_deferred"
                        or result.fallback_reason == "chain_pattern_deferred"),
                    "Chain Size+ pattern live defers"
                )
                assertLine(result and result.chain_payload_launch_count == 0, "Chain Size+ pattern launches no Chain payload")
            end,
        },
        {
            chain_case = "trigger_timer",
            label = "Chain Trigger/Timer live deferral",
            check = function(result)
                assertLine(result and result.fallback_reason ~= nil, "Chain Trigger/Timer live defers")
            end,
        },
        {
            chain_case = "speed_plus_trigger_timer",
            label = "Chain Speed+ Trigger live deferral",
            check = function(result)
                assertLine(result and result.fallback_reason ~= nil, "Chain Speed+ Trigger live defers")
                assertLine(result and result.chain_payload_launch_count == 0, "Chain Speed+ Trigger launches no Chain payload")
            end,
        },
        {
            chain_case = "size_plus_trigger_timer",
            label = "Chain Size+ Timer live deferral",
            check = function(result)
                assertLine(result and result.fallback_reason ~= nil, "Chain Size+ Timer live defers")
                assertLine(result and result.chain_payload_launch_count == 0, "Chain Size+ Timer launches no Chain payload")
            end,
        },
        {
            chain_case = "trigger_chain_multicast",
            label = "Trigger Chain Multicast live deferral",
            check = function(result)
                assertLine(result and result.fallback_reason ~= nil, "Trigger Chain Multicast live defers")
            end,
        },
        {
            chain_case = "nested_payload",
            label = "nested payload Chain live deferral",
            check = function(result)
                assertLine(result and result.fallback_reason ~= nil, "nested payload Chain live defers")
            end,
        },
        {
            chain_case = "nested_trigger_timer",
            label = "nested Trigger/Timer Chain live deferral",
            check = function(result)
                assertLine(result and result.fallback_reason ~= nil, "nested Trigger/Timer Chain live defers")
            end,
        },
        {
            chain_case = "recursion",
            label = "Chain recursion live deferral",
            check = function(result)
                assertLine(result and result.fallback_reason ~= nil, "Chain recursion live defers")
            end,
        },
        {
            chain_case = "speed_plus_recursion",
            label = "Chain Speed+ recursion live deferral",
            check = function(result)
                assertLine(result and result.fallback_reason == "chain_recursion_deferred", "Chain Speed+ recursion live defers")
                assertLine(result and result.chain_payload_launch_count == 0, "Chain Speed+ recursion launches no Chain payload")
            end,
        },
        {
            chain_case = "size_plus_recursion",
            label = "Chain Size+ recursion live deferral",
            check = function(result)
                assertLine(result and result.fallback_reason == "chain_recursion_deferred", "Chain Size+ recursion live defers")
                assertLine(result and result.chain_payload_launch_count == 0, "Chain Size+ recursion launches no Chain payload")
            end,
        },
    }

    local function runCase(index)
        local case = cases[index]
        if not case then
            requestRuntimeStats(false, function(stats_result)
                local snapshot = stats_result and stats_result.snapshot or {}
                assertLine(stats_result and stats_result.ok == true, "runtime stats snapshot returned", stats_result and stats_result.error)
                assertCounterAtLeast(snapshot, "chain_runtime_attempts", #cases - 1, "runtime stats counted Chain runtime attempts")
                assertCounterAtLeast(snapshot, "chain_runtime_qualified", 9, "runtime stats counted Chain runtime qualifications")
                assertCounterAtLeast(snapshot, "chain_runtime_rejected", 7, "runtime stats counted Chain runtime rejections")
                assertCounterAtLeast(snapshot, "chain_runtime_disabled_reject", 1, "runtime stats counted Chain runtime disabled rejection")
                assertCounterAtLeast(snapshot, "chain_runtime_direct_qualified", 6, "runtime stats counted direct Chain qualifications")
                assertCounterAtLeast(snapshot, "chain_runtime_trigger_chain_qualified", 3, "runtime stats counted Trigger Chain qualification")
                assertCounterAtLeast(snapshot, "chain_runtime_source_hits", 9, "runtime stats counted Chain source hits")
                assertCounterAtLeast(snapshot, "chain_runtime_hops_launched", 21, "runtime stats counted Chain hops launched")
                assertCounterAtLeast(snapshot, "chain_runtime_hops_completed", 21, "runtime stats counted Chain hops completed")
                assertCounterAtLeast(snapshot, "chain_runtime_stop_max_hops", 7, "runtime stats counted Chain max-hop stops")
                assertCounterAtLeast(snapshot, "chain_runtime_stop_no_target", 2, "runtime stats counted Chain no-target stop")
                assertCounterAtLeast(snapshot, "chain_runtime_payload_jobs", 21, "runtime stats counted Chain payload jobs")
                assertCounterAtLeast(snapshot, "chain_runtime_payload_ok", 21, "runtime stats counted Chain payload launch ok")
                assertCounterAtLeast(snapshot, "chain_runtime_duplicate_suppressed", 6, "runtime stats counted Chain duplicate suppression")
                assertCounterAtLeast(snapshot, "chain_runtime_multicast_reject", 1, "runtime stats counted Chain Multicast rejection")
                assertCounterAtLeast(snapshot, "chain_runtime_pattern_reject", 1, "runtime stats counted Chain pattern rejection")
                assertCounterAtLeast(snapshot, "chain_runtime_trigger_timer_reject", 1, "runtime stats counted Chain Trigger/Timer rejection")
                assertCounterAtLeast(snapshot, "chain_runtime_recursion_reject", 1, "runtime stats counted Chain recursion rejection")
                assertCounterAtLeast(snapshot, "chain_modifier_attempts", 7, "runtime stats counted Chain modifier attempts")
                assertCounterAtLeast(snapshot, "chain_modifier_qualified", 5, "runtime stats counted Chain modifier qualifications")
                assertCounterAtLeast(snapshot, "chain_modifier_rejected", 2, "runtime stats counted Chain modifier rejections")
                assertCounterAtLeast(snapshot, "chain_modifier_disabled_reject", 2, "runtime stats counted Chain modifier disabled rejections")
                assertCounterAtLeast(snapshot, "chain_modifier_speed_qualified", 3, "runtime stats counted Chain Speed+ qualifications")
                assertCounterAtLeast(snapshot, "chain_modifier_size_qualified", 2, "runtime stats counted Chain Size+ qualifications")
                assertCounterAtLeast(snapshot, "chain_modifier_speed_jobs", 6, "runtime stats counted Chain Speed+ payload jobs")
                assertCounterAtLeast(snapshot, "chain_modifier_size_jobs", 6, "runtime stats counted Chain Size+ payload jobs")
                assertCounterAtLeast(snapshot, "chain_modifier_speed_mutated", 6, "runtime stats counted Chain Speed+ mutations")
                assertCounterAtLeast(snapshot, "chain_modifier_size_mutated", 6, "runtime stats counted Chain Size+ mutations")
                assertCounterAtLeast(snapshot, "chain_modifier_payload_ok", 12, "runtime stats counted Chain modified payload ok")
                assertCounterAtLeast(snapshot, "chain_target_no_immediate_repeat_exclusions", 21, "runtime stats counted live Chain no-immediate-repeat exclusions")
                assertCounterAtLeast(snapshot, "chain_provider_mock_attempts", 10, "runtime stats counted Chain mock provider use")
                assertCounterAtLeast(snapshot, "chain_provider_attempts", 10, "runtime stats counted Chain provider attempts")
                assertLine(
                    counter(snapshot, "chain_provider_real_ok") + counter(snapshot, "chain_provider_real_unavailable") >= 1,
                    "runtime stats counted Chain real provider supported or unavailable state",
                    string.format("real_ok=%s unavailable=%s", tostring(counter(snapshot, "chain_provider_real_ok")), tostring(counter(snapshot, "chain_provider_real_unavailable")))
                )
                log.info("smoke Chain live runtime run complete")
                callback()
            end)
            return
        end

        local start_pos, direction, hit_object = currentLaunchAim()
        requestProbe("chain_runtime", function(result)
            assertLine(result and result.mode == "chain_runtime", "Chain runtime " .. case.label .. " returns runtime mode")
            assertLine(result and result.ok == true, "Chain runtime " .. case.label .. " ok", result and (result.rejection_reason or result.fallback_reason or result.error))
            case.check(result)
            runCase(index + 1)
        end, {
            chain_case = case.chain_case,
            start_pos = start_pos,
            direction = direction,
            hit_object = hit_object,
        })
    end

    runCase(1)
end

local function runSmoke()
    if not dev.smokeTestsEnabled() then
        return
    end
    if not dev.liveSimpleDispatchEnabled() then
        log.info(string.format("SKIP smoke live simple dispatch: enable %s", dev.liveSimpleDispatchSettingKey()))
        return
    end
    if state.running then
        log.warn("smoke live simple dispatch already in progress")
        return
    end
    if state.backend ~= "READY" then
        log.warn("smoke live simple dispatch skipped: backend is not READY")
        return
    end

    state.running = true
    log.info("smoke live simple dispatch hotkey accepted")

    requestRuntimeStats(true, function(reset_result)
        assertLine(reset_result and reset_result.ok == true, "runtime stats reset accepted", reset_result and reset_result.error)

        runNestedAuditSmoke(function()
            runChainTargetingSmoke(function()
                runChainRuntimeSmoke(function()
                    requestProbe("disabled", function(disabled)
                        assertLine(disabled and disabled.ok == true, "feature flag disabled probe reports bridge unavailable", disabled and disabled.error)
                        assertLine(disabled and disabled.used_live_2_2c == false, "disabled probe does not use live 2.2c bridge")

                        requestProbe("qualifying_dry_run", function(qualifying)
                            assertLine(qualifying and qualifying.ok == true, "qualifying simple bridge dry-run ok", qualifying and qualifying.error)
                            assertLine(qualifying and qualifying.slot_count == 1, "qualifying simple bridge has one slot")
                            assertLine(qualifying and qualifying.helper_record_count == 1, "qualifying simple bridge has one helper record")

                            requestProbe("non_qualifying", function(nonqualifying)
                                assertLine(nonqualifying and nonqualifying.ok == true, "non-qualifying recipe falls back cleanly", nonqualifying and nonqualifying.error)
                                assertLine(type(nonqualifying and nonqualifying.fallback_reason) == "string", "non-qualifying fallback has reason")
                                runManualCastStage()
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end)
end

local function runManualChainRealProbe()
    if not dev.smokeTestsEnabled() then
        return
    end
    if not dev.liveSimpleDispatchEnabled() then
        log.info(string.format("SKIP manual Chain real probe: enable %s", dev.liveSimpleDispatchSettingKey()))
        return
    end
    if state.running then
        log.warn("manual Chain real probe skipped: smoke live simple dispatch already in progress")
        return
    end
    if state.backend ~= "READY" then
        log.warn("manual Chain real probe skipped: backend is not READY")
        return
    end

    state.running = true
    local start_pos, direction, hit_object = currentLaunchAim()
    log.info("manual Chain real probe launching: Fire Damage -> Trigger -> Chain 3 -> Frost Damage; aim at one valid actor near another valid actor")
    requestProbe("chain_runtime", function(result)
        assertLine(result and result.mode == "chain_runtime", "manual Chain real probe returns runtime mode")
        assertLine(result and result.ok == true, "manual Chain real probe launched", result and (result.rejection_reason or result.fallback_reason or result.error))
        assertLine(result and result.chain_shape == "trigger_payload_chain", "manual Chain real probe uses Trigger payload Chain shape", result and tostring(result.chain_shape))
        assertLine(result and result.requested_hops == 3, "manual Chain real probe requests three hops", result and tostring(result.requested_hops))
        if result and result.ok == true then
            log.info("manual Chain real probe live: watch for SPELLFORGE_CHAIN_LOS_REQUESTED, SPELLFORGE_CHAIN_LOS_LOCAL_RESULT, SPELLFORGE_CHAIN_LOS_RESULT, SPELLFORGE_CHAIN_REAL_TARGET_SELECTED, SPELLFORGE_CHAIN_HOP_ENQUEUED, and SPELLFORGE_CHAIN_HOP_PAYLOAD_OK")
        end
        state.running = false
    end, {
        chain_case = "manual_real_gameplay",
        start_pos = start_pos,
        direction = direction,
        hit_object = hit_object,
    })
end

local function runMulticastSmoke()
    if not dev.smokeTestsEnabled() then
        return
    end
    if not dev.liveSimpleDispatchEnabled() then
        log.info(string.format("SKIP smoke live multicast: enable %s", dev.liveSimpleDispatchSettingKey()))
        return
    end
    if not dev.liveMulticastEnabled() then
        log.info(string.format("SKIP smoke live multicast: enable %s", dev.liveMulticastSettingKey()))
        return
    end
    if state.running then
        log.warn("smoke live simple dispatch already in progress")
        return
    end
    if state.backend ~= "READY" then
        log.warn("smoke live multicast skipped: backend is not READY")
        return
    end

    state.running = true
    log.info("smoke live Multicast hotkey accepted")

    requestRuntimeStats(true, function(reset_result)
        assertLine(reset_result and reset_result.ok == true, "runtime stats reset accepted", reset_result and reset_result.error)

        requestProbe("multicast_disabled", function(disabled)
            assertLine(disabled and disabled.ok == true, "live Multicast subflag disabled probe rejects", disabled and disabled.error)
            assertLine(disabled and disabled.used_live_2_2c == false, "disabled live Multicast probe does not enqueue")

            requestProbe("multicast_dry_run", function(dry)
                assertLine(dry and dry.ok == true, "live Multicast x3 dry-run ok", dry and dry.error)
                assertLine(dry and dry.live_mode == "multicast", "live Multicast dry-run mode is multicast")
                assertLine(dry and dry.dispatch_count == 3, "live Multicast dry-run plans three dispatches")
                assertLine(dry and dry.slot_count == 3, "live Multicast dry-run has three slots")
                assertLine(dry and dry.helper_record_count == 3, "live Multicast dry-run has three helper records")
                assertLine(uniqueCount(dry and dry.slot_ids) == 3, "live Multicast dry-run has three distinct slot_ids")
                assertLine(uniqueCount(dry and dry.helper_engine_ids) == 3, "live Multicast dry-run has three distinct helper ids")
                assertLine(uniqueCount(dry and dry.emission_indexes) == 3, "live Multicast dry-run has distinct emission indexes")

                local start_pos, direction, hit_object = currentLaunchAim()
                requestProbe("multicast_launch", function(result)
                    assertLine(result and result.ok == true, "live Multicast x3 launch ok", result and result.error)
                    assertLine(result and result.live_mode == "multicast", "live Multicast launch mode is multicast")
                    assertLine(result and result.dispatch_count == 3, "live Multicast launch dispatches three helpers")
                    assertLine(result and result.fanout_count == 3, "live Multicast launch reports fanout_count=3")
                    assertLine(type(result and result.cast_id) == "string" and result.cast_id ~= "", "live Multicast launch returns shared cast_id")
                    assertLine(uniqueCount(result and result.slot_ids) == 3, "live Multicast launch has three distinct slot_ids")
                    assertLine(uniqueCount(result and result.helper_engine_ids) == 3, "live Multicast launch has three distinct helper ids")
                    assertLine(uniqueCount(result and result.emission_indexes) == 3, "live Multicast launch has distinct emission indexes")
                    assertLine(jobsAllComplete(result and result.jobs, 3), "live Multicast launch jobs complete with SFP accepted")
                    assertLine(jobsCarryMulticastUserData(result and result.jobs, 3, result and result.cast_id), "live Multicast launch userData carries shared cast_id and per-emission identity")
                    assertLine(listCount(result and result.projectile_ids) >= 1, "live Multicast launch returned projectile ids when available")

                    requestRuntimeStats(false, function(stats_result)
                        local snapshot = stats_result and stats_result.snapshot or {}
                        assertLine(stats_result and stats_result.ok == true, "runtime stats snapshot returned", stats_result and stats_result.error)
                        assertCounterAtLeast(snapshot, "live_multicast_attempts", 3, "runtime stats counted live Multicast attempts")
                        assertCounterAtLeast(snapshot, "live_multicast_qualified", 2, "runtime stats counted live Multicast qualifications")
                        assertCounterAtLeast(snapshot, "live_multicast_rejected", 1, "runtime stats counted live Multicast rejection")
                        assertCounterAtLeast(snapshot, "live_multicast_emissions_planned", 6, "runtime stats counted planned Multicast emissions")
                        assertCounterAtLeast(snapshot, "live_multicast_jobs_enqueued", 3, "runtime stats counted live Multicast jobs")
                        assertCounterAtLeast(snapshot, "jobs_enqueued", 3, "runtime stats counted Multicast orchestrator enqueue")
                        assertCounterAtLeast(snapshot, "live_helper_jobs_enqueued", 3, "runtime stats counted live helper enqueues")
                        assertCounterAtLeast(snapshot, "jobs_processed", 3, "runtime stats counted Multicast processing")
                        assertCounterAtLeast(snapshot, "live_helper_jobs_processed", 3, "runtime stats counted live helper processing")
                        assertCounterAtLeast(snapshot, "sfp_launch_attempts", 3, "runtime stats counted Multicast SFP launch attempts")
                        assertCounterAtLeast(snapshot, "sfp_launch_ok", 3, "runtime stats counted Multicast SFP launch ok")
                        assertCounterAtLeast(snapshot, "max_queue_depth", 3, "runtime stats tracked Multicast queue depth")
                        assertCounterAtLeast(snapshot, "queue_drained_observed", 1, "runtime stats observed Multicast queue drain")
                        for _, line in ipairs(stats_result and stats_result.summary_lines or {}) do
                            log.info("runtime stats " .. tostring(line))
                        end
                        log.info("smoke live Multicast run complete; aim at a broad valid target/surface if you want to observe all helper hit routes")
                        state.running = false
                    end)
                end, {
                    start_pos = start_pos,
                    direction = direction,
                    hit_object = hit_object,
                })
            end)
        end)
    end)
end

local function runPatternSmoke(pattern_kind)
    if not dev.smokeTestsEnabled() then
        return
    end
    if not dev.liveSimpleDispatchEnabled() then
        log.info(string.format("SKIP smoke live %s: enable %s", tostring(pattern_kind), dev.liveSimpleDispatchSettingKey()))
        return
    end
    if not dev.liveMulticastEnabled() then
        log.info(string.format("SKIP smoke live %s: enable %s", tostring(pattern_kind), dev.liveMulticastSettingKey()))
        return
    end
    if not dev.liveSpreadBurstEnabled() then
        log.info(string.format("SKIP smoke live %s: enable %s", tostring(pattern_kind), dev.liveSpreadBurstSettingKey()))
        return
    end
    if state.running then
        log.warn("smoke live simple dispatch already in progress")
        return
    end
    if state.backend ~= "READY" then
        log.warn(string.format("smoke live %s skipped: backend is not READY", tostring(pattern_kind)))
        return
    end

    local mode_prefix = string.lower(pattern_kind)
    state.running = true
    log.info(string.format("smoke live %s hotkey accepted", tostring(pattern_kind)))

    requestRuntimeStats(true, function(reset_result)
        assertLine(reset_result and reset_result.ok == true, "runtime stats reset accepted", reset_result and reset_result.error)

        requestProbe(mode_prefix .. "_disabled", function(disabled)
            assertLine(disabled and disabled.ok == true, string.format("live %s subflag disabled probe rejects", tostring(pattern_kind)), disabled and disabled.error)
            assertLine(disabled and disabled.used_live_2_2c == false, string.format("disabled live %s probe does not enqueue", tostring(pattern_kind)))

            local dry_start_pos, dry_direction, dry_hit_object = currentLaunchAim()
            requestProbe(mode_prefix .. "_dry_run", function(dry)
                assertLine(dry and dry.ok == true, string.format("live %s x3 dry-run ok", tostring(pattern_kind)), dry and dry.error)
                assertLine(dry and dry.live_mode == mode_prefix, string.format("live %s dry-run mode is %s", tostring(pattern_kind), mode_prefix))
                assertLine(dry and dry.pattern_kind == pattern_kind, string.format("live %s dry-run carries pattern kind", tostring(pattern_kind)))
                assertLine(dry and dry.dispatch_count == 3, string.format("live %s dry-run plans three dispatches", tostring(pattern_kind)))
                assertLine(uniqueCount(dry and dry.slot_ids) == 3, string.format("live %s dry-run has three distinct slot_ids", tostring(pattern_kind)))
                assertLine(uniqueCount(dry and dry.emission_indexes) == 3, string.format("live %s dry-run has distinct emission indexes", tostring(pattern_kind)))
                assertLine(uniqueCount(dry and dry.pattern_direction_keys) == 3, string.format("live %s dry-run computes distinct directions", tostring(pattern_kind)))

                local start_pos, direction, hit_object = currentLaunchAim()
                requestProbe(mode_prefix .. "_launch", function(result)
                    assertLine(result and result.ok == true, string.format("live %s x3 launch ok", tostring(pattern_kind)), result and result.error)
                    assertLine(result and result.live_mode == mode_prefix, string.format("live %s launch mode is %s", tostring(pattern_kind), mode_prefix))
                    assertLine(result and result.pattern_kind == pattern_kind, string.format("live %s launch reports pattern kind", tostring(pattern_kind)))
                    assertLine(result and result.dispatch_count == 3, string.format("live %s launch dispatches three helpers", tostring(pattern_kind)))
                    assertLine(result and result.fanout_count == 3, string.format("live %s launch reports fanout_count=3", tostring(pattern_kind)))
                    assertLine(type(result and result.cast_id) == "string" and result.cast_id ~= "", string.format("live %s launch returns shared cast_id", tostring(pattern_kind)))
                    assertLine(uniqueCount(result and result.slot_ids) == 3, string.format("live %s launch has three distinct slot_ids", tostring(pattern_kind)))
                    assertLine(uniqueCount(result and result.emission_indexes) == 3, string.format("live %s launch has distinct emission indexes", tostring(pattern_kind)))
                    assertLine(uniqueCount(result and result.pattern_direction_keys) == 3, string.format("live %s launch has distinct direction keys", tostring(pattern_kind)))
                    assertLine(jobsAllComplete(result and result.jobs, 3), string.format("live %s launch jobs complete with SFP accepted", tostring(pattern_kind)))
                    assertLine(jobsCarryMulticastUserData(result and result.jobs, 3, result and result.cast_id), string.format("live %s launch carries shared fanout userData", tostring(pattern_kind)))
                    assertLine(jobsCarryPatternUserData(result and result.jobs, 3, result and result.cast_id, pattern_kind), string.format("live %s launch carries pattern userData", tostring(pattern_kind)))
                    assertLine(listCount(result and result.projectile_ids) >= 1, string.format("live %s launch returned projectile ids when available", tostring(pattern_kind)))

                    requestRuntimeStats(false, function(stats_result)
                        local snapshot = stats_result and stats_result.snapshot or {}
                        local attempt_counter = pattern_kind == "Spread" and "live_spread_attempts" or "live_burst_attempts"
                        local qualified_counter = pattern_kind == "Spread" and "live_spread_qualified" or "live_burst_qualified"
                        local rejected_counter = pattern_kind == "Spread" and "live_spread_rejected" or "live_burst_rejected"
                        local planned_counter = pattern_kind == "Spread" and "live_spread_emissions_planned" or "live_burst_emissions_planned"
                        assertLine(stats_result and stats_result.ok == true, "runtime stats snapshot returned", stats_result and stats_result.error)
                        assertCounterAtLeast(snapshot, attempt_counter, 3, string.format("runtime stats counted live %s attempts", tostring(pattern_kind)))
                        assertCounterAtLeast(snapshot, qualified_counter, 2, string.format("runtime stats counted live %s qualifications", tostring(pattern_kind)))
                        assertCounterAtLeast(snapshot, rejected_counter, 1, string.format("runtime stats counted live %s rejection", tostring(pattern_kind)))
                        assertCounterAtLeast(snapshot, planned_counter, 6, string.format("runtime stats counted planned %s emissions", tostring(pattern_kind)))
                        assertCounterAtLeast(snapshot, "live_pattern_direction_jobs", 6, "runtime stats counted pattern direction jobs")
                        assertCounterAtLeast(snapshot, "jobs_enqueued", 3, string.format("runtime stats counted %s orchestrator enqueue", tostring(pattern_kind)))
                        assertCounterAtLeast(snapshot, "live_helper_jobs_enqueued", 3, "runtime stats counted live helper enqueues")
                        assertCounterAtLeast(snapshot, "jobs_processed", 3, string.format("runtime stats counted %s processing", tostring(pattern_kind)))
                        assertCounterAtLeast(snapshot, "live_helper_jobs_processed", 3, "runtime stats counted live helper processing")
                        assertCounterAtLeast(snapshot, "sfp_launch_attempts", 3, string.format("runtime stats counted %s SFP launch attempts", tostring(pattern_kind)))
                        assertCounterAtLeast(snapshot, "sfp_launch_ok", 3, string.format("runtime stats counted %s SFP launch ok", tostring(pattern_kind)))
                        assertCounterAtLeast(snapshot, "sfp_projectile_id_returned", 3, string.format("runtime stats counted %s projectile ids", tostring(pattern_kind)))
                        assertCounterAtLeast(snapshot, "max_queue_depth", 3, string.format("runtime stats tracked %s queue depth", tostring(pattern_kind)))
                        assertCounterAtLeast(snapshot, "queue_drained_observed", 1, string.format("runtime stats observed %s queue drain", tostring(pattern_kind)))
                        for _, line in ipairs(stats_result and stats_result.summary_lines or {}) do
                            log.info("runtime stats " .. tostring(line))
                        end
                        log.info(string.format("smoke live %s run complete; aim at a broad valid target/surface if you want to observe all helper hit routes", tostring(pattern_kind)))
                        state.running = false
                    end)
                end, {
                    start_pos = start_pos,
                    direction = direction,
                    hit_object = hit_object,
                })
            end, {
                start_pos = dry_start_pos,
                direction = dry_direction,
                hit_object = dry_hit_object,
            })
        end)
    end)
end

local function runTriggerSmoke()
    if not dev.smokeTestsEnabled() then
        return
    end
    if not dev.liveSimpleDispatchEnabled() then
        log.info(string.format("SKIP smoke live Trigger: enable %s", dev.liveSimpleDispatchSettingKey()))
        return
    end
    if not dev.liveTriggerEnabled() then
        log.info(string.format("SKIP smoke live Trigger: enable %s", dev.liveTriggerSettingKey()))
        return
    end
    if state.running then
        log.warn("smoke live simple dispatch already in progress")
        return
    end
    if state.backend ~= "READY" then
        log.warn("smoke live Trigger skipped: backend is not READY")
        return
    end

    state.running = true
    log.info("smoke live Trigger hotkey accepted")

    requestRuntimeStats(true, function(reset_result)
        assertLine(reset_result and reset_result.ok == true, "runtime stats reset accepted", reset_result and reset_result.error)

        requestProbe("trigger_disabled", function(disabled)
            assertLine(disabled and disabled.ok == true, "live Trigger subflag disabled probe rejects", disabled and disabled.error)
            assertLine(disabled and disabled.used_live_2_2c == false, "disabled live Trigger probe does not enqueue")

            requestProbe("trigger_dry_run", function(dry)
                assertLine(dry and dry.ok == true, "live Trigger v0 dry-run ok", dry and dry.error)
                assertLine(dry and dry.live_mode == "trigger", "live Trigger dry-run mode is trigger")
                assertLine(dry and dry.dispatch_count == 1, "live Trigger dry-run plans one source dispatch")
                assertLine(dry and dry.slot_count == 2, "live Trigger dry-run has source and payload slots")
                assertLine(dry and dry.helper_record_count == 2, "live Trigger dry-run has source and payload helpers")
                assertLine(type(dry and dry.trigger_payload_slot_id) == "string", "live Trigger dry-run reports payload slot")
                assertLine(type(dry and dry.trigger_payload_helper_engine_id) == "string", "live Trigger dry-run reports payload helper")

                local start_pos, direction, hit_object = currentLaunchAim()
                requestProbe("trigger_launch", function(source)
                    assertLine(source and source.ok == true, "live Trigger source launch ok", source and source.error)
                    assertLine(source and source.live_mode == "trigger", "live Trigger source launch mode is trigger")
                    assertLine(source and source.dispatch_count == 1, "live Trigger launches one source helper at cast time")
                    assertLine(jobsAllComplete(source and source.jobs, 1), "live Trigger source job completes with SFP accepted")
                    assertLine(sourceJobCarriesTriggerUserData(source), "live Trigger source userData carries Trigger source metadata")

                    local hit_start_pos, hit_direction, hit_object_for_payload = currentLaunchAim()
                    requestProbe("trigger_post_hit", function(post_hit)
                        assertLine(post_hit and post_hit.ok == true, "live Trigger post-hit payload probe ok", post_hit and post_hit.error)
                        assertLine(post_hit and post_hit.live_mode == "trigger", "live Trigger post-hit mode is trigger")
                        assertLine(post_hit and post_hit.post_hit_result and post_hit.post_hit_result.ok == true, "live Trigger first source hit enqueues and launches payload")
                        assertLine(post_hit and post_hit.post_hit_result and post_hit.post_hit_result.trigger_route == "userData", "live Trigger post-hit uses userData route")
                        assertLine(post_hit and post_hit.trigger_duplicate_suppressed == true, "live Trigger duplicate source hit is suppressed")
                        assertLine(payloadUserDataCarriesTrigger(post_hit), "live Trigger payload userData carries source and payload identity")

                        local fallback_start_pos, fallback_direction, fallback_hit_object = currentLaunchAim()
                        requestProbe("trigger_post_hit_fallback", function(fallback_hit)
                            assertLine(fallback_hit and fallback_hit.ok == true, "live Trigger spellId fallback post-hit probe ok", fallback_hit and fallback_hit.error)
                            assertLine(fallback_hit and fallback_hit.post_hit_result and fallback_hit.post_hit_result.trigger_route == "spellId", "live Trigger fallback post-hit uses helper spellId route")
                            assertLine(fallback_hit and fallback_hit.post_hit_result and fallback_hit.post_hit_result.ok == true, "live Trigger fallback route enqueues and launches payload")

                            requestProbe("trigger_payload_multicast_disabled", function(multicast_disabled)
                                assertLine(multicast_disabled and multicast_disabled.ok == true, "payload Multicast disabled Trigger probe rejects", multicast_disabled and multicast_disabled.error)
                                assertLine(multicast_disabled and multicast_disabled.used_live_2_2c == false, "disabled Trigger payload Multicast does not enqueue partial payload")

                                local multicast_start_pos, multicast_direction, multicast_hit_object = currentLaunchAim()
                                requestProbe("trigger_payload_multicast_post_hit", function(multicast_hit)
                                    assertLine(multicast_hit and multicast_hit.ok == true, "Trigger payload Multicast post-hit probe ok", multicast_hit and multicast_hit.error)
                                    assertLine(multicast_hit and multicast_hit.payload_multicast == true, "Trigger payload Multicast runtime is flagged")
                                    assertLine(multicast_hit and multicast_hit.trigger_payload_count == 3, "Trigger payload Multicast enqueues three payload helpers")
                                    assertLine(jobsAllComplete(multicast_hit and multicast_hit.trigger_payload_jobs, 3), "Trigger payload Multicast payload jobs complete")
                                    assertLine(uniqueCount(multicast_hit and multicast_hit.trigger_payload_slot_ids) == 3, "Trigger payload Multicast payload slots are distinct")
                                    assertLine(payloadJobsCarryPostfixFanout(multicast_hit and multicast_hit.trigger_payload_jobs, 3, multicast_hit and multicast_hit.cast_id, "Trigger", multicast_hit and multicast_hit.slot_id), "Trigger payload Multicast payload userData carries fanout identity")
                                    assertLine(multicast_hit and multicast_hit.trigger_duplicate_suppressed == true, "Trigger payload Multicast duplicate source hit is suppressed as a group")

                                    requestProbe("trigger_payload_pattern_disabled", function(pattern_disabled)
                                        assertLine(pattern_disabled and pattern_disabled.ok == true, "payload pattern disabled Trigger probe rejects", pattern_disabled and pattern_disabled.error)
                                        assertLine(pattern_disabled and pattern_disabled.used_live_2_2c == false, "disabled Trigger payload pattern does not enqueue patterned payload")

                                        local burst_start_pos, burst_direction, burst_hit_object = currentLaunchAim()
                                        requestProbe("trigger_payload_burst_post_hit", function(burst_hit)
                                            assertLine(burst_hit and burst_hit.ok == true, "Trigger payload Burst+Multicast post-hit probe ok", burst_hit and burst_hit.error)
                                            assertLine(burst_hit and burst_hit.payload_pattern == true and burst_hit.payload_pattern_kind == "Burst", "Trigger payload Burst pattern runtime is flagged")
                                            assertLine(burst_hit and burst_hit.trigger_payload_count == 5, "Trigger payload Burst enqueues five payload helpers")
                                            assertLine(jobsAllComplete(burst_hit and burst_hit.trigger_payload_jobs, 5), "Trigger payload Burst payload jobs complete")
                                            assertLine(payloadJobsCarryPostfixPattern(burst_hit and burst_hit.trigger_payload_jobs, 5, burst_hit and burst_hit.cast_id, "Trigger", burst_hit and burst_hit.slot_id, "Burst"), "Trigger payload Burst userData carries pattern identity and distinct directions")
                                            assertLine(burst_hit and burst_hit.trigger_duplicate_suppressed == true, "Trigger payload Burst duplicate source hit is suppressed as a group")

                                            local spread_start_pos, spread_direction, spread_hit_object = currentLaunchAim()
                                            requestProbe("trigger_payload_spread_post_hit", function(spread_hit)
                                                assertLine(spread_hit and spread_hit.ok == true, "Trigger payload Spread+Multicast post-hit probe ok", spread_hit and spread_hit.error)
                                                assertLine(spread_hit and spread_hit.payload_pattern == true and spread_hit.payload_pattern_kind == "Spread", "Trigger payload Spread pattern runtime is flagged")
                                                assertLine(spread_hit and spread_hit.trigger_payload_count == 3, "Trigger payload Spread enqueues three payload helpers")
                                                assertLine(jobsAllComplete(spread_hit and spread_hit.trigger_payload_jobs, 3), "Trigger payload Spread payload jobs complete")
                                                assertLine(payloadJobsCarryPostfixPattern(spread_hit and spread_hit.trigger_payload_jobs, 3, spread_hit and spread_hit.cast_id, "Trigger", spread_hit and spread_hit.slot_id, "Spread"), "Trigger payload Spread userData carries pattern identity and distinct directions")
                                                assertLine(spread_hit and spread_hit.trigger_duplicate_suppressed == true, "Trigger payload Spread duplicate source hit is suppressed as a group")

                                                requestProbe("nested_trigger_timer_disabled", function(nested_disabled)
                                                    assertLine(nested_disabled and nested_disabled.ok == true, "nested Trigger/Timer disabled probe rejects", nested_disabled and nested_disabled.error)
                                                    assertLine(nested_disabled and nested_disabled.used_live_2_2c == false, "disabled nested Trigger/Timer does not enqueue live jobs")

                                                    local nested_start_pos, nested_direction, nested_hit_object = currentLaunchAim()
                                                    requestProbe("nested_trigger_timer_sequence", function(nested_tt)
                                                        assertLine(nested_tt and nested_tt.ok == true, "Trigger -> Timer nested runtime probe ok", nested_tt and nested_tt.error)
                                                        assertLine(nested_tt and nested_tt.live_mode == "nested_trigger_timer", "Trigger -> Timer nested runtime is flagged")
                                                        assertLine(nested_tt and nested_tt.nested_tt_kind == "trigger_timer", "Trigger -> Timer nested kind is reported")
                                                        assertLine(nested_tt and nested_tt.post_hit_result and nested_tt.post_hit_result.ok == true, "Trigger -> Timer root hit launches intermediate Timer source")
                                                        assertLine(nested_tt and nested_tt.trigger_payload_count == 1, "Trigger -> Timer launches one intermediate helper")
                                                        assertLine(nested_tt and type(nested_tt.nested_timer_id) == "string", "Trigger -> Timer schedules nested async Timer")
                                                        assertLine(nested_tt and nested_tt.trigger_duplicate_suppressed == true, "Trigger -> Timer duplicate root hit is suppressed")

                                                        local nested_timer_id = nested_tt and nested_tt.nested_timer_id
                                                        local nested_delay_seconds = tonumber(nested_tt and nested_tt.nested_timer_schedule and nested_tt.nested_timer_schedule.timer_delay_seconds) or 1
                                                        async:newUnsavableSimulationTimer(nested_delay_seconds + 0.1, function()
                                                            requestProbe("timer_real_delay_check", function(nested_done)
                                                                local final_job = nested_done and nested_done.timer_payload_jobs and nested_done.timer_payload_jobs[1] or nil
                                                                local final_user_data = final_job and final_job.launch_user_data or nil
                                                                assertLine(nested_done and nested_done.ok == true, "Trigger -> Timer nested callback payload check ok", nested_done and nested_done.error)
                                                                assertLine(nested_done and nested_done.callback_payload_count == 1, "Trigger -> Timer final payload count is one")
                                                                assertLine(jobsAllComplete(nested_done and nested_done.timer_payload_jobs, 1), "Trigger -> Timer final payload job completes")
                                                                assertLine(type(final_user_data) == "table" and final_user_data.payload_depth == 2 and final_user_data.root_source_slot_id == nested_tt.root_source_slot_id and final_user_data.current_source_slot_id == nested_tt.intermediate_slot_id, "Trigger -> Timer final userData preserves nested identity")

                                                                requestProbe("nested_final_fanout_disabled", function(final_fanout_disabled)
                                                                    assertLine(final_fanout_disabled and final_fanout_disabled.ok == true, "nested final fanout disabled probe rejects", final_fanout_disabled and final_fanout_disabled.error)
                                                                    assertLine(final_fanout_disabled and final_fanout_disabled.used_live_2_2c == false, "disabled nested final fanout does not downgrade to one payload")

                                                                    local final_multi_start_pos, final_multi_direction, final_multi_hit_object = currentLaunchAim()
                                                                    requestProbe("nested_trigger_timer_final_multicast_sequence", function(final_multi)
                                                                        assertLine(final_multi and final_multi.ok == true, "Trigger -> Timer -> final Multicast runtime probe ok", final_multi and final_multi.error)
                                                                        assertLine(final_multi and final_multi.nested_final_fanout == true, "Trigger -> Timer -> final Multicast runtime is flagged")
                                                                        assertLine(final_multi and final_multi.payload_multicast == true, "Trigger -> Timer -> final Multicast payload group is flagged")
                                                                        assertLine(final_multi and final_multi.final_payload_count == 3, "Trigger -> Timer -> final Multicast resolves three final payload helpers")
                                                                        assertLine(final_multi and final_multi.trigger_duplicate_suppressed == true, "Trigger -> Timer -> final Multicast duplicate root hit is suppressed")
                                                                        assertLine(final_multi and type(final_multi.nested_timer_id) == "string", "Trigger -> Timer -> final Multicast schedules nested async Timer")

                                                                        local final_multi_timer_id = final_multi and final_multi.nested_timer_id
                                                                        local final_multi_delay_seconds = tonumber(final_multi and final_multi.nested_timer_schedule and final_multi.nested_timer_schedule.timer_delay_seconds) or 1
                                                                        async:newUnsavableSimulationTimer(final_multi_delay_seconds + 0.1, function()
                                                                            requestProbe("timer_real_delay_check", function(final_multi_done)
                                                                                assertLine(final_multi_done and final_multi_done.ok == true, "Trigger -> Timer -> final Multicast callback payload check ok", final_multi_done and final_multi_done.error)
                                                                                assertLine(final_multi_done and final_multi_done.callback_payload_count == 3, "Trigger -> Timer -> final Multicast callback payload count is three")
                                                                                assertLine(jobsAllComplete(final_multi_done and final_multi_done.timer_payload_jobs, 3), "Trigger -> Timer -> final Multicast final payload jobs complete")
                                                                                assertLine(uniqueCount(final_multi_done and final_multi_done.timer_payload_slot_ids) == 3, "Trigger -> Timer -> final Multicast final payload slots are distinct")
                                                                                assertLine(nestedFinalFanoutJobsCarryUserData(final_multi_done and final_multi_done.timer_payload_jobs, 3, final_multi_done and final_multi_done.cast_id, "Timer", final_multi and final_multi.intermediate_slot_id, final_multi and final_multi.root_source_slot_id), "Trigger -> Timer -> final Multicast userData preserves nested final fanout identity")

                                                                                local final_burst_start_pos, final_burst_direction, final_burst_hit_object = currentLaunchAim()
                                                                                requestProbe("nested_trigger_timer_final_burst_sequence", function(final_burst)
                                                                                    assertLine(final_burst and final_burst.ok == true, "Trigger -> Timer -> final Burst+Multicast runtime probe ok", final_burst and final_burst.error)
                                                                                    assertLine(final_burst and final_burst.nested_final_fanout == true, "Trigger -> Timer -> final Burst runtime is flagged")
                                                                                    assertLine(final_burst and final_burst.payload_pattern == true and final_burst.payload_pattern_kind == "Burst", "Trigger -> Timer -> final Burst pattern is flagged")
                                                                                    assertLine(final_burst and final_burst.final_payload_count == 5, "Trigger -> Timer -> final Burst resolves five final payload helpers")

                                                                                    local final_burst_timer_id = final_burst and final_burst.nested_timer_id
                                                                                    local final_burst_delay_seconds = tonumber(final_burst and final_burst.nested_timer_schedule and final_burst.nested_timer_schedule.timer_delay_seconds) or 1
                                                                                    async:newUnsavableSimulationTimer(final_burst_delay_seconds + 0.1, function()
                                                                                        requestProbe("timer_real_delay_check", function(final_burst_done)
                                                                                            assertLine(final_burst_done and final_burst_done.ok == true, "Trigger -> Timer -> final Burst callback payload check ok", final_burst_done and final_burst_done.error)
                                                                                            assertLine(final_burst_done and final_burst_done.callback_payload_count == 5, "Trigger -> Timer -> final Burst callback payload count is five")
                                                                                            assertLine(jobsAllComplete(final_burst_done and final_burst_done.timer_payload_jobs, 5), "Trigger -> Timer -> final Burst final payload jobs complete")
                                                                                            assertLine(nestedFinalFanoutJobsCarryUserData(final_burst_done and final_burst_done.timer_payload_jobs, 5, final_burst_done and final_burst_done.cast_id, "Timer", final_burst and final_burst.intermediate_slot_id, final_burst and final_burst.root_source_slot_id, "Burst"), "Trigger -> Timer -> final Burst userData carries pattern identity and distinct directions")

                                                                requestRuntimeStats(false, function(stats_result)
                                                        local snapshot = stats_result and stats_result.snapshot or {}
                                                        assertLine(stats_result and stats_result.ok == true, "runtime stats snapshot returned", stats_result and stats_result.error)
                                                        assertCounterAtLeast(snapshot, "live_trigger_attempts", 7, "runtime stats counted live Trigger attempts")
                                                        assertCounterAtLeast(snapshot, "live_trigger_qualified", 5, "runtime stats counted live Trigger qualifications")
                                                        assertCounterAtLeast(snapshot, "live_trigger_rejected", 2, "runtime stats counted live Trigger rejection")
                                                        assertCounterAtLeast(snapshot, "live_trigger_disabled_rejections", 1, "runtime stats counted disabled Trigger rejection")
                                                        assertCounterAtLeast(snapshot, "live_trigger_source_jobs_enqueued", 5, "runtime stats counted Trigger source enqueues")
                                                        assertCounterAtLeast(snapshot, "live_trigger_source_hits", 8, "runtime stats counted Trigger source hits")
                                                        assertCounterAtLeast(snapshot, "live_trigger_payload_jobs_enqueued", 6, "runtime stats counted Trigger payload enqueue")
                                                        assertCounterAtLeast(snapshot, "live_trigger_payload_jobs_processed", 6, "runtime stats counted Trigger payload processing")
                                                        assertCounterAtLeast(snapshot, "live_trigger_payload_launch_ok", 6, "runtime stats counted Trigger payload launch ok")
                                                        assertCounterAtLeast(snapshot, "live_trigger_duplicate_hits_suppressed", 4, "runtime stats counted Trigger duplicate suppression")
                                                        assertCounterAtLeast(snapshot, "live_trigger_post_hit_smoke_observed", 3, "runtime stats counted post-hit smoke checkpoint")
                                                        assertCounterAtLeast(snapshot, "payload_multicast_attempts", 2, "runtime stats counted payload Multicast attempts")
                                                        assertCounterAtLeast(snapshot, "payload_multicast_qualified", 1, "runtime stats counted payload Multicast qualification")
                                                        assertCounterAtLeast(snapshot, "payload_multicast_rejected", 1, "runtime stats counted disabled payload Multicast rejection")
                                                        assertCounterAtLeast(snapshot, "payload_multicast_disabled_reject", 1, "runtime stats counted payload Multicast disabled rejection")
                                                        assertCounterAtLeast(snapshot, "payload_multicast_jobs", 3, "runtime stats counted payload Multicast jobs")
                                                        assertCounterAtLeast(snapshot, "payload_multicast_trigger_jobs", 3, "runtime stats counted Trigger payload Multicast jobs")
                                                        assertCounterAtLeast(snapshot, "payload_pattern_attempts", 3, "runtime stats counted payload pattern attempts")
                                                        assertCounterAtLeast(snapshot, "payload_pattern_qualified", 2, "runtime stats counted payload pattern qualifications")
                                                        assertCounterAtLeast(snapshot, "payload_pattern_rejected", 1, "runtime stats counted disabled payload pattern rejection")
                                                        assertCounterAtLeast(snapshot, "payload_pattern_disabled_reject", 1, "runtime stats counted payload pattern disabled rejection")
                                                        assertCounterAtLeast(snapshot, "payload_pattern_jobs", 8, "runtime stats counted payload pattern jobs")
                                                        assertCounterAtLeast(snapshot, "payload_pattern_trigger_jobs", 8, "runtime stats counted Trigger payload pattern jobs")
                                                        assertCounterAtLeast(snapshot, "payload_pattern_spread_jobs", 3, "runtime stats counted Trigger payload Spread jobs")
                                                        assertCounterAtLeast(snapshot, "payload_pattern_burst_jobs", 5, "runtime stats counted Trigger payload Burst jobs")
                                                        assertCounterAtLeast(snapshot, "nested_tt_qualified", 1, "runtime stats counted nested Trigger/Timer qualification")
                                                        assertCounterAtLeast(snapshot, "nested_tt_trigger_timer_qualified", 1, "runtime stats counted Trigger -> Timer qualification")
                                                        assertCounterAtLeast(snapshot, "nested_tt_intermediate_jobs", 1, "runtime stats counted nested intermediate job")
                                                        assertCounterAtLeast(snapshot, "nested_tt_final_jobs", 1, "runtime stats counted nested final job")
                                                        assertCounterAtLeast(snapshot, "nested_tt_timer_callbacks", 1, "runtime stats counted nested Timer callback")
                                                        assertCounterAtLeast(snapshot, "nested_tt_trigger_hits", 1, "runtime stats counted nested Trigger hit")
                                                        assertCounterAtLeast(snapshot, "nested_tt_duplicate_suppressed", 1, "runtime stats counted nested duplicate suppression")
                                                        assertCounterAtLeast(snapshot, "nested_final_fanout_attempts", 3, "runtime stats counted nested final fanout attempts")
                                                        assertCounterAtLeast(snapshot, "nested_final_fanout_qualified", 2, "runtime stats counted nested final fanout qualifications")
                                                        assertCounterAtLeast(snapshot, "nested_final_fanout_disabled_reject", 1, "runtime stats counted nested final fanout disabled rejection")
                                                        assertCounterAtLeast(snapshot, "nested_final_fanout_trigger_timer_qualified", 2, "runtime stats counted Trigger -> Timer final fanout qualifications")
                                                        assertCounterAtLeast(snapshot, "nested_final_fanout_jobs", 8, "runtime stats counted nested final fanout jobs")
                                                        assertCounterAtLeast(snapshot, "nested_final_fanout_timer_jobs", 8, "runtime stats counted Timer-released nested final fanout jobs")
                                                        assertCounterAtLeast(snapshot, "nested_final_fanout_burst_jobs", 5, "runtime stats counted nested final Burst jobs")
                                                        assertCounterAtLeast(snapshot, "nested_final_fanout_duplicate_suppressed", 2, "runtime stats counted nested final fanout duplicate suppression")
                                                        assertCounterAtLeast(snapshot, "hits_seen", 8, "runtime stats counted simulated post-hit events")
                                                        assertCounterAtLeast(snapshot, "jobs_enqueued", 10, "runtime stats counted source and payload orchestrator enqueue")
                                                        assertCounterAtLeast(snapshot, "live_helper_jobs_enqueued", 10, "runtime stats counted source and payload live helper enqueue")
                                                        assertCounterAtLeast(snapshot, "jobs_processed", 10, "runtime stats counted source and payload processing")
                                                        assertCounterAtLeast(snapshot, "live_helper_jobs_processed", 10, "runtime stats counted source and payload live helper processing")
                                                        assertCounterAtLeast(snapshot, "sfp_launch_attempts", 10, "runtime stats counted source and payload SFP launches")
                                                        assertCounterAtLeast(snapshot, "sfp_launch_ok", 10, "runtime stats counted source and payload SFP launch ok")
                                                        assertCounterAtLeast(snapshot, "hits_userdata_routed", 5, "runtime stats counted post-hit userData routes")
                                                        assertCounterAtLeast(snapshot, "hits_spellid_fallback_routed", 2, "runtime stats counted post-hit spellId fallback routes")
                                                        assertCounterAtLeast(snapshot, "queue_drained_observed", 3, "runtime stats observed Trigger queue drain")
                                                        for _, line in ipairs(stats_result and stats_result.summary_lines or {}) do
                                                            log.info("runtime stats " .. tostring(line))
                                                        end
                                                        log.info("smoke live Trigger run complete")
                                                        state.running = false
                                                                end)
                                                                                        end, {
                                                                                            timer_id = final_burst_timer_id,
                                                                                            observe_matured = true,
                                                                                            expected_payload_count = 5,
                                                                                        })
                                                                                    end)
                                                                                end, {
                                                                                    start_pos = final_burst_start_pos,
                                                                                    direction = final_burst_direction,
                                                                                    hit_object = final_burst_hit_object,
                                                                                })
                                                                            end, {
                                                                                timer_id = final_multi_timer_id,
                                                                                observe_matured = true,
                                                                                expected_payload_count = 3,
                                                                            })
                                                                        end)
                                                                    end, {
                                                                        start_pos = final_multi_start_pos,
                                                                        direction = final_multi_direction,
                                                                        hit_object = final_multi_hit_object,
                                                                    })
                                                                end)
                                                            end, {
                                                                timer_id = nested_timer_id,
                                                                observe_matured = true,
                                                                expected_payload_count = 1,
                                                            })
                                                        end)
                                                    end, {
                                                        start_pos = nested_start_pos,
                                                        direction = nested_direction,
                                                        hit_object = nested_hit_object,
                                                    })
                                                end)
                                            end, {
                                                start_pos = spread_start_pos,
                                                direction = spread_direction,
                                                hit_object = spread_hit_object,
                                            })
                                        end, {
                                            start_pos = burst_start_pos,
                                            direction = burst_direction,
                                            hit_object = burst_hit_object,
                                        })
                                    end)
                                end, {
                                    start_pos = multicast_start_pos,
                                    direction = multicast_direction,
                                    hit_object = multicast_hit_object,
                                })
                            end)
                        end, {
                            start_pos = fallback_start_pos,
                            direction = fallback_direction,
                            hit_object = fallback_hit_object,
                        })
                    end, {
                        start_pos = hit_start_pos,
                        direction = hit_direction,
                        hit_object = hit_object_for_payload,
                    })
                end, {
                    start_pos = start_pos,
                    direction = direction,
                    hit_object = hit_object,
                })
            end)
        end)
    end)
end

local function runTimerSmoke()
    if not dev.smokeTestsEnabled() then
        return
    end
    if not dev.liveSimpleDispatchEnabled() then
        log.info(string.format("SKIP smoke live Timer: enable %s", dev.liveSimpleDispatchSettingKey()))
        return
    end
    if not dev.liveTimerEnabled() then
        log.info(string.format("SKIP smoke live Timer: enable %s", dev.liveTimerSettingKey()))
        return
    end
    if state.running then
        log.warn("smoke live simple dispatch already in progress")
        return
    end
    if state.backend ~= "READY" then
        log.warn("smoke live Timer skipped: backend is not READY")
        return
    end

    state.running = true
    log.info("smoke live Timer hotkey accepted; async simulation timer smoke is phased")

    requestRuntimeStats(true, function(reset_result)
        assertLine(reset_result and reset_result.ok == true, "runtime stats reset accepted", reset_result and reset_result.error)

        requestProbe("timer_detonation_audit", function(timer_audit)
            assertLine(timer_audit and timer_audit.ok == true, "Timer source detonation capability audit returns status", timer_audit and timer_audit.error)
            assertLine(timer_audit and timer_audit.status == "blocked", "Timer source detonation is explicitly blocked pending projectile position/cell")

            requestProbe("timer_disabled", function(disabled)
                assertLine(disabled and disabled.ok == true, "live Timer subflag disabled probe rejects", disabled and disabled.error)
                assertLine(disabled and disabled.used_live_2_2c == false, "disabled live Timer probe does not enqueue")

            requestProbe("timer_dry_run", function(dry)
                assertLine(dry and dry.ok == true, "live Timer v0 dry-run ok", dry and dry.error)
                assertLine(dry and dry.live_mode == "timer", "live Timer dry-run mode is timer")
                assertLine(dry and dry.dispatch_count == 1, "live Timer dry-run plans one source dispatch")
                assertLine(dry and dry.slot_count == 2, "live Timer dry-run has source and payload slots")
                assertLine(dry and dry.helper_record_count == 2, "live Timer dry-run has source and payload helpers")
                assertLine(type(dry and dry.timer_payload_slot_id) == "string", "live Timer dry-run reports payload slot")
                assertLine(type(dry and dry.timer_payload_helper_engine_id) == "string", "live Timer dry-run reports payload helper")
                assertLine(tonumber(dry and dry.timer_delay_ticks) ~= nil and dry.timer_delay_ticks >= 1, "live Timer dry-run reports bounded delay ticks")

                local start_pos, direction, hit_object = currentLaunchAim()
                requestProbe("timer_real_delay_sequence", function(scheduled)
                    assertLine(scheduled and scheduled.ok == true, "live Timer async schedule probe ok", scheduled and scheduled.error)
                    assertLine(scheduled and scheduled.live_mode == "timer", "live Timer async schedule mode is timer")
                    assertLine(scheduled and scheduled.timer_delay_semantics == "async_simulation_timer", "live Timer uses OpenMW async simulation timer semantics")
                    assertLine(scheduled and scheduled.async_timer_scheduled == true, "live Timer schedules a reliable async simulation timer")
                    assertLine(scheduled and scheduled.timer_status_after_schedule and scheduled.timer_status_after_schedule.pending == true, "live Timer async timer is pending after source launch")
                    assertLine(scheduled and scheduled.pending_count == 1, "live Timer pending count is one after schedule")
                    assertLine(scheduled and scheduled.timer_immediate_payload_count == 0, "live Timer async immediate payload count is zero")
                    assertLine(scheduled and scheduled.timer_before_delay_payload_count == 0, "live Timer async before-delay payload count is zero")
                    assertLine(scheduled and scheduled.timer_duplicate_suppressed == true, "live Timer async duplicate schedule is suppressed")
                    assertLine(jobsAllComplete(scheduled and scheduled.source_jobs, 1), "live Timer source job completes with SFP accepted")
                    assertLine(sourceJobCarriesTimerUserData(scheduled), "live Timer source userData carries async Timer metadata")

                    local timer_id = scheduled and scheduled.timer_id
                    local delay_seconds = tonumber(scheduled and scheduled.timer_delay_seconds) or 1
                    async:newUnsavableSimulationTimer(delay_seconds * 0.5, function()
                        requestProbe("timer_real_delay_check", function(early)
                            assertLine(early and early.ok == false, "live Timer async callback has not fired under delay")
                            assertLine(early and early.pending_count == 1, "live Timer async timer remains pending under delay")
                            assertLine(early and (early.callback_count or 0) == 0, "live Timer async under-delay callback count is zero")
                            assertLine(early and (early.callback_payload_count or 0) == 0, "live Timer async under-delay payload count is zero")

                            async:newUnsavableSimulationTimer(math.max(0.1, delay_seconds * 0.7), function()
                                requestProbe("timer_real_delay_check", function(done)
                                    assertLine(done and done.ok == true, "live Timer async callback payload check ok", done and done.error)
                                    assertLine(done and done.callback_count == 1, "live Timer async callback count is one")
                                    assertLine(done and done.callback_payload_count == 1, "live Timer async callback payload count is one")
                                    assertLine(done and done.pending_count == 0, "live Timer async pending count clears after callback")
                                    assertLine(payloadUserDataCarriesTimer(done), "live Timer async payload userData carries source and Timer identity")

                                    requestProbe("timer_payload_multicast_disabled", function(multicast_disabled)
                                        assertLine(multicast_disabled and multicast_disabled.ok == true, "payload Multicast disabled Timer probe rejects", multicast_disabled and multicast_disabled.error)
                                        assertLine(multicast_disabled and multicast_disabled.used_live_2_2c == false, "disabled Timer payload Multicast does not enqueue partial payload")

                                        local multi_start_pos, multi_direction, multi_hit_object = currentLaunchAim()
                                        requestProbe("timer_payload_multicast_sequence", function(multicast_scheduled)
                                            assertLine(multicast_scheduled and multicast_scheduled.ok == true, "Timer payload Multicast async schedule probe ok", multicast_scheduled and multicast_scheduled.error)
                                            assertLine(multicast_scheduled and multicast_scheduled.payload_multicast == true, "Timer payload Multicast runtime is flagged")
                                            assertLine(multicast_scheduled and multicast_scheduled.timer_payload_count == 3, "Timer payload Multicast schedules three payload helpers")
                                            assertLine(multicast_scheduled and multicast_scheduled.timer_status_after_schedule and multicast_scheduled.timer_status_after_schedule.pending == true, "Timer payload Multicast async timer is pending after source launch")
                                            assertLine(multicast_scheduled and multicast_scheduled.timer_immediate_payload_count == 0, "Timer payload Multicast immediate payload count is zero")
                                            assertLine(multicast_scheduled and multicast_scheduled.timer_duplicate_suppressed == true, "Timer payload Multicast duplicate schedule is suppressed as a group")
                                            assertLine(jobsAllComplete(multicast_scheduled and multicast_scheduled.source_jobs, 1), "Timer payload Multicast source job completes")

                                            local multicast_timer_id = multicast_scheduled and multicast_scheduled.timer_id
                                            local multicast_delay_seconds = tonumber(multicast_scheduled and multicast_scheduled.timer_delay_seconds) or 1
                                            async:newUnsavableSimulationTimer(multicast_delay_seconds + 0.1, function()
                                                requestProbe("timer_real_delay_check", function(multicast_done)
                                                    assertLine(multicast_done and multicast_done.ok == true, "Timer payload Multicast callback payload check ok", multicast_done and multicast_done.error)
                                                    assertLine(multicast_done and multicast_done.callback_count == 1, "Timer payload Multicast callback count is one")
                                                    assertLine(multicast_done and multicast_done.callback_payload_count == 3, "Timer payload Multicast callback payload count is three")
                                                    assertLine(multicast_done and multicast_done.pending_count == 0, "Timer payload Multicast pending count clears")
                                                    assertLine(jobsAllComplete(multicast_done and multicast_done.timer_payload_jobs, 3), "Timer payload Multicast payload jobs complete")
                                                    assertLine(uniqueCount(multicast_done and multicast_done.timer_payload_slot_ids) == 3, "Timer payload Multicast payload slots are distinct")
                                                    assertLine(payloadJobsCarryPostfixFanout(multicast_done and multicast_done.timer_payload_jobs, 3, multicast_done and multicast_done.cast_id, "Timer", multicast_done and multicast_done.slot_id), "Timer payload Multicast payload userData carries fanout identity")

                                                    requestProbe("timer_payload_pattern_disabled", function(pattern_disabled)
                                                        assertLine(pattern_disabled and pattern_disabled.ok == true, "payload pattern disabled Timer probe rejects", pattern_disabled and pattern_disabled.error)
                                                        assertLine(pattern_disabled and pattern_disabled.used_live_2_2c == false, "disabled Timer payload pattern does not enqueue patterned payload")

                                                        local burst_start_pos, burst_direction, burst_hit_object = currentLaunchAim()
                                                        requestProbe("timer_payload_burst_sequence", function(burst_scheduled)
                                                            assertLine(burst_scheduled and burst_scheduled.ok == true, "Timer payload Burst+Multicast async schedule probe ok", burst_scheduled and burst_scheduled.error)
                                                            assertLine(burst_scheduled and burst_scheduled.payload_pattern == true and burst_scheduled.payload_pattern_kind == "Burst", "Timer payload Burst pattern runtime is flagged")
                                                            assertLine(burst_scheduled and burst_scheduled.timer_payload_count == 5, "Timer payload Burst schedules five payload helpers")
                                                            assertLine(burst_scheduled and burst_scheduled.timer_immediate_payload_count == 0, "Timer payload Burst immediate payload count is zero")
                                                            assertLine(burst_scheduled and burst_scheduled.timer_duplicate_suppressed == true, "Timer payload Burst duplicate schedule is suppressed as a group")

                                                            local burst_timer_id = burst_scheduled and burst_scheduled.timer_id
                                                            local burst_delay_seconds = tonumber(burst_scheduled and burst_scheduled.timer_delay_seconds) or 1
                                                            async:newUnsavableSimulationTimer(burst_delay_seconds + 0.1, function()
                                                                requestProbe("timer_real_delay_check", function(burst_done)
                                                                    assertLine(burst_done and burst_done.ok == true, "Timer payload Burst callback payload check ok", burst_done and burst_done.error)
                                                                    assertLine(burst_done and burst_done.callback_payload_count == 5, "Timer payload Burst callback payload count is five")
                                                                    assertLine(jobsAllComplete(burst_done and burst_done.timer_payload_jobs, 5), "Timer payload Burst payload jobs complete")
                                                                    assertLine(payloadJobsCarryPostfixPattern(burst_done and burst_done.timer_payload_jobs, 5, burst_done and burst_done.cast_id, "Timer", burst_done and burst_done.slot_id, "Burst"), "Timer payload Burst userData carries pattern identity and distinct directions")

                                                                    local spread_start_pos, spread_direction, spread_hit_object = currentLaunchAim()
                                                                    requestProbe("timer_payload_spread_sequence", function(spread_scheduled)
                                                                        assertLine(spread_scheduled and spread_scheduled.ok == true, "Timer payload Spread+Multicast async schedule probe ok", spread_scheduled and spread_scheduled.error)
                                                                        assertLine(spread_scheduled and spread_scheduled.payload_pattern == true and spread_scheduled.payload_pattern_kind == "Spread", "Timer payload Spread pattern runtime is flagged")
                                                                        assertLine(spread_scheduled and spread_scheduled.timer_payload_count == 3, "Timer payload Spread schedules three payload helpers")
                                                                        assertLine(spread_scheduled and spread_scheduled.timer_immediate_payload_count == 0, "Timer payload Spread immediate payload count is zero")
                                                                        assertLine(spread_scheduled and spread_scheduled.timer_duplicate_suppressed == true, "Timer payload Spread duplicate schedule is suppressed as a group")

                                                                        local spread_timer_id = spread_scheduled and spread_scheduled.timer_id
                                                                        local spread_delay_seconds = tonumber(spread_scheduled and spread_scheduled.timer_delay_seconds) or 1
                                                                        async:newUnsavableSimulationTimer(spread_delay_seconds + 0.1, function()
                                                                            requestProbe("timer_real_delay_check", function(spread_done)
                                                                                assertLine(spread_done and spread_done.ok == true, "Timer payload Spread callback payload check ok", spread_done and spread_done.error)
                                                                                assertLine(spread_done and spread_done.callback_payload_count == 3, "Timer payload Spread callback payload count is three")
                                                                                assertLine(jobsAllComplete(spread_done and spread_done.timer_payload_jobs, 3), "Timer payload Spread payload jobs complete")
                                                                                assertLine(payloadJobsCarryPostfixPattern(spread_done and spread_done.timer_payload_jobs, 3, spread_done and spread_done.cast_id, "Timer", spread_done and spread_done.slot_id, "Spread"), "Timer payload Spread userData carries pattern identity and distinct directions")

                                                                                requestProbe("nested_tt_depth_reject", function(depth_reject)
                                                                                    assertLine(depth_reject and depth_reject.ok == true, "nested Trigger/Timer depth > 2 probe rejects", depth_reject and depth_reject.error)
                                                                                    assertLine(depth_reject and depth_reject.used_live_2_2c == false, "depth-rejected nested Trigger/Timer does not enqueue jobs")

                                                                                    requestProbe("nested_tt_same_kind_reject", function(same_kind_reject)
                                                                                        assertLine(same_kind_reject and same_kind_reject.ok == true, "same-kind nested Timer probe rejects", same_kind_reject and same_kind_reject.error)
                                                                                        assertLine(same_kind_reject and same_kind_reject.used_live_2_2c == false, "same-kind nested Timer does not enqueue final payload")

                                                                                        requestProbe("nested_tt_fanout_reject", function(fanout_reject)
                                                                                            assertLine(fanout_reject and fanout_reject.ok == true, "nested Trigger/Timer fanout probe rejects", fanout_reject and fanout_reject.error)
                                                                                            assertLine(fanout_reject and fanout_reject.used_live_2_2c == false, "nested fanout under Trigger/Timer stays deferred")

                                                                                            local nested_start_pos, nested_direction, nested_hit_object = currentLaunchAim()
                                                                                            requestProbe("nested_timer_trigger_sequence", function(nested_tt)
                                                                                                assertLine(nested_tt and nested_tt.ok == true, "Timer -> Trigger nested runtime schedule probe ok", nested_tt and nested_tt.error)
                                                                                                assertLine(nested_tt and nested_tt.live_mode == "nested_trigger_timer", "Timer -> Trigger nested runtime is flagged")
                                                                                                assertLine(nested_tt and nested_tt.nested_tt_kind == "timer_trigger", "Timer -> Trigger nested kind is reported")
                                                                                                assertLine(nested_tt and nested_tt.nested_trigger_registered == true, "Timer -> Trigger registers intermediate Trigger binding")
                                                                                                assertLine(type(nested_tt and nested_tt.timer_id) == "string", "Timer -> Trigger schedules root async Timer")
                                                                                                assertLine(nested_tt and nested_tt.timer_immediate_payload_count == 0, "Timer -> Trigger intermediate does not launch before delay")
                                                                                                assertLine(nested_tt and nested_tt.timer_duplicate_suppressed == true, "Timer -> Trigger duplicate root Timer schedule is suppressed")

                                                                                                local nested_timer_id = nested_tt and nested_tt.timer_id
                                                                                                local nested_delay_seconds = tonumber(nested_tt and nested_tt.timer_delay_seconds) or 1
                                                                                                async:newUnsavableSimulationTimer(nested_delay_seconds + 0.1, function()
                                                                                                    requestProbe("timer_real_delay_check", function(nested_done)
                                                                                                        local intermediate_job = nested_done and nested_done.timer_payload_jobs and nested_done.timer_payload_jobs[1] or nil
                                                                                                        local intermediate_user_data = intermediate_job and intermediate_job.launch_user_data or nil
                                                                                                        local final_hit = nested_done and nested_done.nested_trigger_hit_result or nil
                                                                                                        local final_job = nested_done and nested_done.nested_final_payload_jobs and nested_done.nested_final_payload_jobs[1] or nil
                                                                                                        local final_user_data = final_job and final_job.launch_user_data or nil
                                                                                                        assertLine(nested_done and nested_done.ok == true, "Timer -> Trigger root callback payload check ok", nested_done and nested_done.error)
                                                                                                        assertLine(nested_done and nested_done.callback_payload_count == 1, "Timer -> Trigger launches one intermediate helper")
                                                                                                        assertLine(jobsAllComplete(nested_done and nested_done.timer_payload_jobs, 1), "Timer -> Trigger intermediate helper job completes")
                                                                                                        assertLine(type(intermediate_user_data) == "table" and intermediate_user_data.payload_depth == 1 and intermediate_user_data.has_trigger_payload == true, "Timer -> Trigger intermediate userData marks Trigger source")
                                                                                                        assertLine(final_hit and final_hit.ok == true, "Timer -> Trigger intermediate hit launches final payload")
                                                                                                        assertLine(nested_done and nested_done.nested_trigger_duplicate_suppressed == true, "Timer -> Trigger duplicate intermediate hit is suppressed")
                                                                                                        assertLine(nested_done and nested_done.nested_final_payload_count == 1, "Timer -> Trigger final payload count is one")
                                                                                                        assertLine(jobsAllComplete(nested_done and nested_done.nested_final_payload_jobs, 1), "Timer -> Trigger final payload job completes")
                                                                                                        assertLine(type(final_user_data) == "table" and final_user_data.payload_depth == 2 and final_user_data.root_source_slot_id == nested_tt.root_source_slot_id and final_user_data.current_source_slot_id == nested_tt.intermediate_slot_id, "Timer -> Trigger final userData preserves nested identity")

                                                                                                        requestProbe("nested_final_fanout_cap_reject", function(final_fanout_cap)
                                                                                                            assertLine(final_fanout_cap and final_fanout_cap.ok == true, "nested final fanout cap probe rejects", final_fanout_cap and final_fanout_cap.error)
                                                                                                            assertLine(final_fanout_cap and final_fanout_cap.used_live_2_2c == false, "over-cap nested final fanout does not enqueue payload jobs")

                                                                                                            local final_multi_start_pos, final_multi_direction, final_multi_hit_object = currentLaunchAim()
                                                                                                            requestProbe("nested_timer_trigger_final_multicast_sequence", function(final_multi)
                                                                                                                assertLine(final_multi and final_multi.ok == true, "Timer -> Trigger -> final Multicast runtime schedule probe ok", final_multi and final_multi.error)
                                                                                                                assertLine(final_multi and final_multi.nested_final_fanout == true, "Timer -> Trigger -> final Multicast runtime is flagged")
                                                                                                                assertLine(final_multi and final_multi.payload_multicast == true, "Timer -> Trigger -> final Multicast payload group is flagged")
                                                                                                                assertLine(final_multi and final_multi.final_payload_count == 3, "Timer -> Trigger -> final Multicast resolves three final payload helpers")
                                                                                                                assertLine(final_multi and final_multi.nested_trigger_registered == true, "Timer -> Trigger -> final Multicast registers intermediate Trigger binding")

                                                                                                                local final_multi_timer_id = final_multi and final_multi.timer_id
                                                                                                                local final_multi_delay_seconds = tonumber(final_multi and final_multi.timer_delay_seconds) or 1
                                                                                                                async:newUnsavableSimulationTimer(final_multi_delay_seconds + 0.1, function()
                                                                                                                    requestProbe("timer_real_delay_check", function(final_multi_done)
                                                                                                                        assertLine(final_multi_done and final_multi_done.ok == true, "Timer -> Trigger -> final Multicast root callback check ok", final_multi_done and final_multi_done.error)
                                                                                                                        assertLine(final_multi_done and final_multi_done.callback_payload_count == 1, "Timer -> Trigger -> final Multicast launches one intermediate helper")
                                                                                                                        assertLine(final_multi_done and final_multi_done.nested_trigger_hit_result and final_multi_done.nested_trigger_hit_result.ok == true, "Timer -> Trigger -> final Multicast intermediate hit launches final group")
                                                                                                                        assertLine(final_multi_done and final_multi_done.nested_trigger_duplicate_suppressed == true, "Timer -> Trigger -> final Multicast duplicate intermediate hit is suppressed")
                                                                                                                        assertLine(final_multi_done and final_multi_done.nested_final_payload_count == 3, "Timer -> Trigger -> final Multicast final payload count is three")
                                                                                                                        assertLine(jobsAllComplete(final_multi_done and final_multi_done.nested_final_payload_jobs, 3), "Timer -> Trigger -> final Multicast final payload jobs complete")
                                                                                                                        assertLine(nestedFinalFanoutJobsCarryUserData(final_multi_done and final_multi_done.nested_final_payload_jobs, 3, final_multi_done and final_multi_done.cast_id, "Trigger", final_multi and final_multi.intermediate_slot_id, final_multi and final_multi.root_source_slot_id), "Timer -> Trigger -> final Multicast userData preserves nested final fanout identity")

                                                                                                                        local final_spread_start_pos, final_spread_direction, final_spread_hit_object = currentLaunchAim()
                                                                                                                        requestProbe("nested_timer_trigger_final_spread_sequence", function(final_spread)
                                                                                                                            assertLine(final_spread and final_spread.ok == true, "Timer -> Trigger -> final Spread+Multicast runtime schedule probe ok", final_spread and final_spread.error)
                                                                                                                            assertLine(final_spread and final_spread.nested_final_fanout == true, "Timer -> Trigger -> final Spread runtime is flagged")
                                                                                                                            assertLine(final_spread and final_spread.payload_pattern == true and final_spread.payload_pattern_kind == "Spread", "Timer -> Trigger -> final Spread pattern is flagged")
                                                                                                                            assertLine(final_spread and final_spread.final_payload_count == 3, "Timer -> Trigger -> final Spread resolves three final payload helpers")

                                                                                                                            local final_spread_timer_id = final_spread and final_spread.timer_id
                                                                                                                            local final_spread_delay_seconds = tonumber(final_spread and final_spread.timer_delay_seconds) or 1
                                                                                                                            async:newUnsavableSimulationTimer(final_spread_delay_seconds + 0.1, function()
                                                                                                                                requestProbe("timer_real_delay_check", function(final_spread_done)
                                                                                                                                    assertLine(final_spread_done and final_spread_done.ok == true, "Timer -> Trigger -> final Spread root callback check ok", final_spread_done and final_spread_done.error)
                                                                                                                                    assertLine(final_spread_done and final_spread_done.nested_final_payload_count == 3, "Timer -> Trigger -> final Spread final payload count is three")
                                                                                                                                    assertLine(jobsAllComplete(final_spread_done and final_spread_done.nested_final_payload_jobs, 3), "Timer -> Trigger -> final Spread final payload jobs complete")
                                                                                                                                    assertLine(nestedFinalFanoutJobsCarryUserData(final_spread_done and final_spread_done.nested_final_payload_jobs, 3, final_spread_done and final_spread_done.cast_id, "Trigger", final_spread and final_spread.intermediate_slot_id, final_spread and final_spread.root_source_slot_id, "Spread"), "Timer -> Trigger -> final Spread userData carries pattern identity and distinct directions")

                                                                                                        requestRuntimeStats(false, function(stats_result)
                                                                                    local snapshot = stats_result and stats_result.snapshot or {}
                                                                                    assertLine(stats_result and stats_result.ok == true, "runtime stats snapshot returned", stats_result and stats_result.error)
                                                                                    assertCounterAtLeast(snapshot, "live_timer_attempts", 5, "runtime stats counted live Timer attempts")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_qualified", 3, "runtime stats counted live Timer qualifications")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_rejected", 2, "runtime stats counted live Timer rejection")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_disabled_rejections", 1, "runtime stats counted disabled Timer rejection")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_source_jobs_enqueued", 2, "runtime stats counted Timer source enqueue")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_wait_jobs_enqueued", 2, "runtime stats counted async Timer wait schedule")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_wait_jobs_processed", 2, "runtime stats counted async Timer callback processing")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_payload_jobs_enqueued", 4, "runtime stats counted async Timer payload enqueue")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_payload_jobs_processed", 4, "runtime stats counted Timer payload processing")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_payload_launch_ok", 4, "runtime stats counted Timer payload launch ok")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_duplicate_schedules_suppressed", 2, "runtime stats counted Timer duplicate suppression")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_async_scheduled", 2, "runtime stats counted async Timer schedule")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_async_callback_seen", 2, "runtime stats counted async Timer callback")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_async_payload_enqueued", 4, "runtime stats counted async Timer payload enqueue")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_async_payload_ok", 4, "runtime stats counted async Timer payload ok")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_async_pending", 1, "runtime stats recorded async Timer pending")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_async_pending_cleared", 2, "runtime stats counted async Timer pending clear")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_async_duplicate_suppressed", 2, "runtime stats counted async Timer duplicate suppression")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_real_delay_attempts", 2, "runtime stats counted Timer real-delay attempt")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_real_delay_matured", 2, "runtime stats counted Timer async maturity")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_real_delay_payload_ok", 4, "runtime stats counted Timer async payload ok")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_real_delay_smoke_scheduled", 1, "runtime stats counted async Timer smoke schedule")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_real_delay_smoke_pending", 1, "runtime stats counted async Timer smoke pending")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_real_delay_smoke_callback_ok", 2, "runtime stats counted async Timer smoke callback ok")
                                                                                    assertCounterAtLeast(snapshot, "live_timer_immediate_payload_blocked", 2, "runtime stats counted Timer immediate payload blocking")
                                                                                    assertCounterAtLeast(snapshot, "timer_source_detonation_blocked", 1, "runtime stats counted Timer source detonation blocker")
                                                                                    assertCounterAtLeast(snapshot, "payload_multicast_attempts", 2, "runtime stats counted payload Multicast attempts")
                                                                                    assertCounterAtLeast(snapshot, "payload_multicast_qualified", 1, "runtime stats counted payload Multicast qualification")
                                                                                    assertCounterAtLeast(snapshot, "payload_multicast_rejected", 1, "runtime stats counted disabled payload Multicast rejection")
                                                                                    assertCounterAtLeast(snapshot, "payload_multicast_disabled_reject", 1, "runtime stats counted payload Multicast disabled rejection")
                                                                                    assertCounterAtLeast(snapshot, "payload_multicast_jobs", 3, "runtime stats counted payload Multicast jobs")
                                                                                    assertCounterAtLeast(snapshot, "payload_multicast_timer_jobs", 3, "runtime stats counted Timer payload Multicast jobs")
                                                                                    assertCounterAtLeast(snapshot, "payload_pattern_attempts", 3, "runtime stats counted payload pattern attempts")
                                                                                    assertCounterAtLeast(snapshot, "payload_pattern_qualified", 2, "runtime stats counted payload pattern qualifications")
                                                                                    assertCounterAtLeast(snapshot, "payload_pattern_rejected", 1, "runtime stats counted disabled payload pattern rejection")
                                                                                    assertCounterAtLeast(snapshot, "payload_pattern_disabled_reject", 1, "runtime stats counted payload pattern disabled rejection")
                                                                                    assertCounterAtLeast(snapshot, "payload_pattern_jobs", 8, "runtime stats counted payload pattern jobs")
                                                                                    assertCounterAtLeast(snapshot, "payload_pattern_timer_jobs", 8, "runtime stats counted Timer payload pattern jobs")
                                                                                    assertCounterAtLeast(snapshot, "payload_pattern_spread_jobs", 3, "runtime stats counted Timer payload Spread jobs")
                                                                                    assertCounterAtLeast(snapshot, "payload_pattern_burst_jobs", 5, "runtime stats counted Timer payload Burst jobs")
                                                                                    assertCounterAtLeast(snapshot, "nested_tt_qualified", 1, "runtime stats counted nested Trigger/Timer qualification")
                                                                                    assertCounterAtLeast(snapshot, "nested_tt_timer_trigger_qualified", 1, "runtime stats counted Timer -> Trigger qualification")
                                                                                    assertCounterAtLeast(snapshot, "nested_tt_depth_reject", 1, "runtime stats counted nested depth rejection")
                                                                                    assertCounterAtLeast(snapshot, "nested_tt_multicast_reject", 1, "runtime stats counted nested fanout rejection")
                                                                                    assertCounterAtLeast(snapshot, "nested_tt_intermediate_jobs", 1, "runtime stats counted nested intermediate job")
                                                                                    assertCounterAtLeast(snapshot, "nested_tt_final_jobs", 1, "runtime stats counted nested final job")
                                                                                    assertCounterAtLeast(snapshot, "nested_tt_timer_callbacks", 1, "runtime stats counted nested Timer callback")
                                                                                    assertCounterAtLeast(snapshot, "nested_tt_trigger_hits", 1, "runtime stats counted nested Trigger hit")
                                                                                    assertCounterAtLeast(snapshot, "nested_tt_duplicate_suppressed", 1, "runtime stats counted nested duplicate suppression")
                                                                                    assertCounterAtLeast(snapshot, "nested_final_fanout_attempts", 3, "runtime stats counted nested final fanout attempts")
                                                                                    assertCounterAtLeast(snapshot, "nested_final_fanout_qualified", 2, "runtime stats counted nested final fanout qualifications")
                                                                                    assertCounterAtLeast(snapshot, "nested_final_fanout_cap_reject", 1, "runtime stats counted nested final fanout cap rejection")
                                                                                    assertCounterAtLeast(snapshot, "nested_final_fanout_timer_trigger_qualified", 2, "runtime stats counted Timer -> Trigger final fanout qualifications")
                                                                                    assertCounterAtLeast(snapshot, "nested_final_fanout_jobs", 6, "runtime stats counted nested final fanout jobs")
                                                                                    assertCounterAtLeast(snapshot, "nested_final_fanout_trigger_jobs", 6, "runtime stats counted Trigger-released nested final fanout jobs")
                                                                                    assertCounterAtLeast(snapshot, "nested_final_fanout_spread_jobs", 3, "runtime stats counted nested final Spread jobs")
                                                                                    assertCounterAtLeast(snapshot, "nested_final_fanout_duplicate_suppressed", 2, "runtime stats counted nested final fanout duplicate suppression")
                                                                                    assertCounterAtLeast(snapshot, "jobs_enqueued", 9, "runtime stats counted source and async payload jobs")
                                                                                    assertCounterAtLeast(snapshot, "live_helper_jobs_enqueued", 9, "runtime stats counted source and payload live helper jobs")
                                                                                    assertCounterAtLeast(snapshot, "jobs_processed", 9, "runtime stats counted source and payload processing")
                                                                                    assertCounterAtLeast(snapshot, "live_helper_jobs_processed", 9, "runtime stats counted live helper processing")
                                                                                    assertCounterAtLeast(snapshot, "sfp_launch_attempts", 9, "runtime stats counted Timer source and payload SFP launches")
                                                                                    assertCounterAtLeast(snapshot, "sfp_launch_ok", 9, "runtime stats counted Timer source and payload SFP launch ok")
                                                                                    assertCounterAtLeast(snapshot, "queue_drained_observed", 2, "runtime stats observed queue drain")
                                                                                    for _, line in ipairs(stats_result and stats_result.summary_lines or {}) do
                                                                                        log.info("runtime stats " .. tostring(line))
                                                                                    end
                                                                                    log.info("smoke live Timer async simulation-delay run complete")
                                                                                    state.running = false
                                                                                                        end)
                                                                                                                                end, {
                                                                                                                                    timer_id = final_spread_timer_id,
                                                                                                                                    observe_matured = true,
                                                                                                                                    expected_payload_count = 1,
                                                                                                                                    simulate_nested_trigger_hit = true,
                                                                                                                                    start_pos = final_spread_start_pos,
                                                                                                                                    hit_object = final_spread_hit_object,
                                                                                                                                })
                                                                                                                            end)
                                                                                                                        end, {
                                                                                                                            start_pos = final_spread_start_pos,
                                                                                                                            direction = final_spread_direction,
                                                                                                                            hit_object = final_spread_hit_object,
                                                                                                                        })
                                                                                                                    end, {
                                                                                                                        timer_id = final_multi_timer_id,
                                                                                                                        observe_matured = true,
                                                                                                                        expected_payload_count = 1,
                                                                                                                        simulate_nested_trigger_hit = true,
                                                                                                                        start_pos = final_multi_start_pos,
                                                                                                                        hit_object = final_multi_hit_object,
                                                                                                                    })
                                                                                                                end)
                                                                                                            end, {
                                                                                                                start_pos = final_multi_start_pos,
                                                                                                                direction = final_multi_direction,
                                                                                                                hit_object = final_multi_hit_object,
                                                                                                            })
                                                                                                        end)
                                                                                                    end, {
                                                                                                        timer_id = nested_timer_id,
                                                                                                        observe_matured = true,
                                                                                                        expected_payload_count = 1,
                                                                                                        simulate_nested_trigger_hit = true,
                                                                                                        start_pos = nested_start_pos,
                                                                                                        hit_object = nested_hit_object,
                                                                                                    })
                                                                                                end)
                                                                                            end, {
                                                                                                start_pos = nested_start_pos,
                                                                                                direction = nested_direction,
                                                                                                hit_object = nested_hit_object,
                                                                                            })
                                                                                        end)
                                                                                    end)
                                                                                end)
                                                                            end, {
                                                                                timer_id = spread_timer_id,
                                                                                observe_matured = true,
                                                                                expected_payload_count = 3,
                                                                            })
                                                                        end)
                                                                    end, {
                                                                        start_pos = spread_start_pos,
                                                                        direction = spread_direction,
                                                                        hit_object = spread_hit_object,
                                                                    })
                                                                end, {
                                                                    timer_id = burst_timer_id,
                                                                    observe_matured = true,
                                                                    expected_payload_count = 5,
                                                                })
                                                            end)
                                                        end, {
                                                            start_pos = burst_start_pos,
                                                            direction = burst_direction,
                                                            hit_object = burst_hit_object,
                                                        })
                                                    end)
                                                end, {
                                                    timer_id = multicast_timer_id,
                                                    observe_matured = true,
                                                    expected_payload_count = 3,
                                                })
                                            end)
                                        end, {
                                            start_pos = multi_start_pos,
                                            direction = multi_direction,
                                            hit_object = multi_hit_object,
                                        })
                                    end)
                                end, {
                                    timer_id = timer_id,
                                    observe_matured = true,
                                })
                            end)
                        end, {
                            timer_id = timer_id,
                        })
                    end)
                end, {
                    start_pos = start_pos,
                    direction = direction,
                    hit_object = hit_object,
                })
            end)
        end)
        end)
    end)
end

local function runSpeedPlusSmoke()
    if not dev.smokeTestsEnabled() then
        return
    end
    if not dev.liveSimpleDispatchEnabled() then
        log.info(string.format("SKIP smoke live Speed+: enable %s", dev.liveSimpleDispatchSettingKey()))
        return
    end
    if not dev.liveSpeedPlusEnabled() then
        log.info(string.format("SKIP smoke live Speed+: enable %s", dev.liveSpeedPlusSettingKey()))
        return
    end
    if state.running then
        log.warn("smoke live simple dispatch already in progress")
        return
    end
    if state.backend ~= "READY" then
        log.warn("smoke live Speed+ skipped: backend is not READY")
        return
    end

    state.running = true
    log.info("smoke live Speed+ hotkey accepted")

    requestRuntimeStats(true, function(reset_result)
        assertLine(reset_result and reset_result.ok == true, "runtime stats reset accepted", reset_result and reset_result.error)

        requestProbe("speed_plus_disabled", function(disabled)
            assertLine(disabled and disabled.ok == true, "live Speed+ subflag disabled probe rejects", disabled and disabled.error)
            assertLine(disabled and disabled.used_live_2_2c == false, "disabled live Speed+ probe does not enqueue")

            requestProbe("speed_plus_dry_run", function(dry)
                assertLine(dry and dry.ok == true, "live Speed+ dry-run ok", dry and dry.error)
                assertLine(dry and dry.live_mode == "speed_plus", "live Speed+ dry-run reports Speed+ mode")
                assertLine(dry and dry.dispatch_count == 1, "live Speed+ dry-run plans one source dispatch")
                assertLine(dry and dry.speed_plus_field == "speed", "live Speed+ dry-run reports SFP data.speed field")
                assertLine(tonumber(dry and dry.speed_plus_multiplier) ~= nil and dry.speed_plus_multiplier > 0, "live Speed+ dry-run computes bounded multiplier")
                assertLine(tonumber(dry and dry.speed_plus_base_speed) ~= nil and dry.speed_plus_base_speed == 1500, "live Speed+ dry-run reports base speed")
                assertLine(tonumber(dry and dry.speed_plus_speed) ~= nil and dry.speed_plus_speed ~= dry.speed_plus_base_speed, "live Speed+ dry-run reports mutated speed")
                assertLine(counter(dry, "speed_plus_field_missing") == 0, "live Speed+ dry-run no longer marks field missing")

                local start_pos, direction, hit_object = currentLaunchAim()
                requestProbe("speed_plus_launch", function(result)
                    assertLine(result and result.ok == true, "live Speed+ launch ok", result and result.error)
                    assertLine(result and result.live_mode == "speed_plus", "live Speed+ launch reports Speed+ mode")
                    assertLine(result and result.dispatch_count == 1, "live Speed+ launch dispatches one helper")
                    assertLine(result and result.speed_plus_field == "speed", "live Speed+ launch reports SFP data.speed mutation")
                    assertLine(tonumber(result and result.speed_plus_speed) ~= nil and result.speed_plus_speed ~= result.speed_plus_base_speed, "live Speed+ launch keeps mutated speed metadata")
                    assertLine(jobsAllComplete(result and result.jobs, 1), "live Speed+ launch job completes with SFP accepted")
                    assertLine(jobsCarrySpeedPlusUserData(result and result.jobs, 1, result and result.cast_id), "live Speed+ launch carries compact Speed+ userData")
                    assertLine(result and result.jobs and result.jobs[1] and result.jobs[1].speed == result.speed_plus_speed, "live Speed+ launch job carries data.speed")
                    assertLine(result and result.jobs and result.jobs[1] and result.jobs[1].maxSpeed == result.speed_plus_max_speed, "live Speed+ launch job carries data.maxSpeed cap")
                    assertLine(listCount(result and result.projectile_ids) >= 1, "live Speed+ launch returned projectile id when available")

                    requestRuntimeStats(false, function(stats_result)
                        local snapshot = stats_result and stats_result.snapshot or {}
                        assertLine(stats_result and stats_result.ok == true, "runtime stats snapshot returned", stats_result and stats_result.error)
                        assertCounterAtLeast(snapshot, "live_speed_plus_attempts", 3, "runtime stats counted live Speed+ attempts")
                        assertCounterAtLeast(snapshot, "live_speed_plus_qualified", 2, "runtime stats counted live Speed+ qualifications")
                        assertCounterAtLeast(snapshot, "live_speed_plus_rejected", 1, "runtime stats counted live Speed+ rejection")
                        assertCounterAtLeast(snapshot, "live_speed_plus_disabled_rejections", 1, "runtime stats counted disabled Speed+ rejection")
                        assertCounterAtLeast(snapshot, "live_speed_plus_jobs_mutated", 1, "runtime stats counted Speed+ job mutation")
                        assertLine(counter(snapshot, "live_speed_plus_field_missing") == 0, "runtime stats did not count missing Speed+ launch field")
                        assertCounterAtLeast(snapshot, "live_speed_plus_smoke_observed", 1, "runtime stats counted Speed+ smoke checkpoint")
                        assertCounterAtLeast(snapshot, "jobs_enqueued", 1, "runtime stats counted Speed+ orchestrator enqueue")
                        assertCounterAtLeast(snapshot, "jobs_processed", 1, "runtime stats counted Speed+ processing")
                        assertCounterAtLeast(snapshot, "sfp_launch_attempts", 1, "runtime stats counted Speed+ SFP launch attempts")
                        assertCounterAtLeast(snapshot, "sfp_launch_ok", 1, "runtime stats counted Speed+ SFP launch ok")
                        assertCounterAtLeast(snapshot, "queue_drained_observed", 1, "runtime stats observed Speed+ queue drain")
                        for _, line in ipairs(stats_result and stats_result.summary_lines or {}) do
                            log.info("runtime stats " .. tostring(line))
                        end
                        log.info("smoke live Speed+ run complete; SFP Beta3 data.speed mutation is active")
                        state.running = false
                    end)
                end, {
                    start_pos = start_pos,
                    direction = direction,
                    hit_object = hit_object,
                })
            end)
        end)
    end)
end

local function runSizePlusSmoke()
    if not dev.smokeTestsEnabled() then
        return
    end
    if not dev.liveSimpleDispatchEnabled() then
        log.info(string.format("SKIP smoke live Size+: enable %s", dev.liveSimpleDispatchSettingKey()))
        return
    end
    if not dev.liveSizePlusEnabled() then
        log.info(string.format("SKIP smoke live Size+: enable %s", dev.liveSizePlusSettingKey()))
        return
    end
    if state.running then
        log.warn("smoke live simple dispatch already in progress")
        return
    end
    if state.backend ~= "READY" then
        log.warn("smoke live Size+ skipped: backend is not READY")
        return
    end

    state.running = true
    log.info("smoke live Size+ hotkey accepted")

    requestRuntimeStats(true, function(reset_result)
        assertLine(reset_result and reset_result.ok == true, "runtime stats reset accepted", reset_result and reset_result.error)

        requestProbe("size_plus_disabled", function(disabled)
            assertLine(disabled and disabled.ok == true, "live Size+ subflag disabled probe rejects", disabled and disabled.error)
            assertLine(disabled and disabled.used_live_2_2c == false, "disabled live Size+ probe does not enqueue")

            requestProbe("size_plus_dry_run", function(dry)
                assertLine(dry and dry.ok == true, "live Size+ dry-run ok", dry and dry.error)
                assertLine(dry and dry.live_mode == "size_plus", "live Size+ dry-run reports Size+ mode")
                assertLine(dry and dry.dispatch_count == 1, "live Size+ dry-run plans one source dispatch")
                assertLine(dry and dry.size_plus_field == "effect.area", "live Size+ dry-run reports helper effect area field")
                assertLine(tonumber(dry and dry.size_plus_multiplier) ~= nil and dry.size_plus_multiplier > 0, "live Size+ dry-run computes bounded multiplier")
                local dry_base_area = tonumber(dry and dry.size_plus_base_area)
                local dry_size_area = tonumber(dry and dry.size_plus_area)
                assertLine(dry_size_area ~= nil and dry_base_area ~= nil and dry_size_area > dry_base_area, "live Size+ dry-run reports enlarged area")
                assertLine(tonumber(dry and dry.size_plus_specs_mutated) ~= nil and dry.size_plus_specs_mutated >= 1, "live Size+ dry-run mutates helper specs")

                local start_pos, direction, hit_object = currentLaunchAim()
                requestProbe("size_plus_launch", function(result)
                    assertLine(result and result.ok == true, "live Size+ launch ok", result and result.error)
                    assertLine(result and result.live_mode == "size_plus", "live Size+ launch reports Size+ mode")
                    assertLine(result and result.dispatch_count == 1, "live Size+ launch dispatches one helper")
                    assertLine(result and result.size_plus_field == "effect.area", "live Size+ launch reports effect area mutation")
                    local result_base_area = tonumber(result and result.size_plus_base_area)
                    local result_size_area = tonumber(result and result.size_plus_area)
                    assertLine(result_size_area ~= nil and result_base_area ~= nil and result_size_area > result_base_area, "live Size+ launch keeps enlarged area metadata")
                    assertLine(jobsAllComplete(result and result.jobs, 1), "live Size+ launch job completes with SFP accepted")
                    assertLine(jobsCarrySizePlusUserData(result and result.jobs, 1, result and result.cast_id), "live Size+ launch carries compact Size+ userData")
                    assertLine(listCount(result and result.projectile_ids) >= 1, "live Size+ launch returned projectile id when available")

                    requestRuntimeStats(false, function(stats_result)
                        local snapshot = stats_result and stats_result.snapshot or {}
                        assertLine(stats_result and stats_result.ok == true, "runtime stats snapshot returned", stats_result and stats_result.error)
                        assertCounterAtLeast(snapshot, "live_size_plus_attempts", 3, "runtime stats counted live Size+ attempts")
                        assertCounterAtLeast(snapshot, "live_size_plus_qualified", 2, "runtime stats counted live Size+ qualifications")
                        assertCounterAtLeast(snapshot, "live_size_plus_rejected", 1, "runtime stats counted live Size+ rejection")
                        assertCounterAtLeast(snapshot, "live_size_plus_disabled_rejections", 1, "runtime stats counted disabled Size+ rejection")
                        assertCounterAtLeast(snapshot, "live_size_plus_jobs_mutated", 1, "runtime stats counted Size+ job mutation")
                        assertCounterAtLeast(snapshot, "live_size_plus_specs_mutated", 2, "runtime stats counted Size+ spec mutations")
                        assertCounterAtLeast(snapshot, "live_size_plus_smoke_observed", 1, "runtime stats counted Size+ smoke checkpoint")
                        assertCounterAtLeast(snapshot, "jobs_enqueued", 1, "runtime stats counted Size+ orchestrator enqueue")
                        assertCounterAtLeast(snapshot, "jobs_processed", 1, "runtime stats counted Size+ processing")
                        assertCounterAtLeast(snapshot, "sfp_launch_attempts", 1, "runtime stats counted Size+ SFP launch attempts")
                        assertCounterAtLeast(snapshot, "sfp_launch_ok", 1, "runtime stats counted Size+ SFP launch ok")
                        assertCounterAtLeast(snapshot, "queue_drained_observed", 1, "runtime stats observed Size+ queue drain")
                        for _, line in ipairs(stats_result and stats_result.summary_lines or {}) do
                            log.info("runtime stats " .. tostring(line))
                        end
                        log.info("smoke live Size+ run complete")
                        state.running = false
                    end)
                end, {
                    start_pos = start_pos,
                    direction = direction,
                    hit_object = hit_object,
                })
            end)
        end)
    end)
end

local function runChaosBudgetSmoke()
    if state.running then
        log.warn("smoke live simple dispatch already in progress")
        return
    end
    state.running = true
    local high_count = 16

    local function adoptJobs(result, field_name, jobs_result)
        if result and jobs_result and type(jobs_result.jobs) == "table" then
            result[field_name] = jobs_result.jobs
        end
    end

    local function mergeTriggerHitResult(result, hit_result)
        if type(result) ~= "table" or type(hit_result) ~= "table" then
            return result
        end
        result.ok = hit_result.ok == true
        result.error = hit_result.error
        result.post_hit_result = hit_result.post_hit_result
        result.duplicate_hit_result = hit_result.duplicate_hit_result
        result.trigger_payload_job_id = hit_result.trigger_payload_job_id
        result.trigger_payload_job_ids = hit_result.trigger_payload_job_ids
        result.trigger_payload_jobs = hit_result.trigger_payload_jobs
        result.trigger_payload_slot_id = hit_result.trigger_payload_slot_id
        result.trigger_payload_slot_ids = hit_result.trigger_payload_slot_ids
        result.trigger_payload_count = hit_result.trigger_payload_count
        result.payload_multicast = hit_result.payload_multicast == true or result.payload_multicast == true
        result.payload_pattern = hit_result.payload_pattern == true or result.payload_pattern == true
        result.payload_pattern_kind = hit_result.payload_pattern_kind or result.payload_pattern_kind
        result.payload_pattern_direction_keys = hit_result.payload_pattern_direction_keys
        result.nested_final_fanout = hit_result.nested_final_fanout == true or result.nested_final_fanout == true
        result.nested_final_fanout_kind = hit_result.nested_final_fanout_kind or result.nested_final_fanout_kind
        result.trigger_payload_launch_count = hit_result.trigger_payload_launch_count
        result.trigger_payload_helper_engine_id = hit_result.trigger_payload_helper_engine_id
        result.trigger_payload_launch_user_data = hit_result.trigger_payload_launch_user_data
        result.trigger_duplicate_suppressed = hit_result.trigger_duplicate_suppressed == true
        result.nested_timer_schedule = hit_result.nested_timer_schedule
        result.nested_timer_id = hit_result.nested_timer_id
        result.pending_source_launch_job = false
        return result
    end

    local function ensureTriggerSourceHit(result, callback)
        if not (result and result.pending_source_launch_job == true) then
            callback(result)
            return
        end
        waitForJobsComplete(result.job_ids, 1, function(source_wait)
            adoptJobs(result, "jobs", source_wait)
            if not (source_wait and source_wait.all_complete == true) then
                result.ok = false
                result.error = source_wait and source_wait.error or "trigger source launch job did not complete"
                callback(result)
                return
            end
            requestProbe("trigger_hit_from_job", function(hit_result)
                callback(mergeTriggerHitResult(result, hit_result))
            end, launchAimPayload({
                source_job_id = result.job_id,
                allow_pending_launch_jobs = true,
            }))
        end, {
            max_attempts = 32,
            delay_seconds = 0.15,
        })
    end

    local function finish()
        requestRuntimeStats(false, function(stats_result)
            local snapshot = stats_result and stats_result.snapshot or {}
            assertLine(stats_result and stats_result.ok == true, "chaos budget runtime stats snapshot returned", stats_result and stats_result.error)
            assertCounterAtLeast(snapshot, "chaos_budget_profile_default", 1, "runtime stats counted default chaos budget report")
            assertCounterAtLeast(snapshot, "chaos_budget_profile_chaos", 1, "runtime stats counted chaos budget report")
            assertCounterAtLeast(snapshot, "chaos_budget_high_fanout_smoke", 5, "runtime stats counted high-fanout chaos smokes")
            assertCounterAtLeast(snapshot, "chaos_budget_max_jobs_observed", high_count, "runtime stats tracked high chaos job count")
            assertCounterAtLeast(snapshot, "chaos_budget_max_projectiles_observed", high_count, "runtime stats tracked high chaos projectile count")
            assertCounterAtLeast(snapshot, "chaos_budget_launch_density_throttle", 1, "runtime stats counted live launch density throttling")
            assertCounterAtLeast(snapshot, "chaos_budget_max_live_launches_per_tick_observed", 1, "runtime stats tracked live launches per tick")
            assertCounterAtLeast(snapshot, "chaos_budget_cap_reject", 2, "runtime stats counted chaos cap rejection")
            assertCounterAtLeast(snapshot, "chaos_budget_fanout_cap_reject", 2, "runtime stats counted chaos fanout cap rejection")
            assertCounterAtLeast(snapshot, "nested_final_fanout_cap_reject", 1, "runtime stats counted nested final fanout cap rejection")
            assertCounterAtLeast(snapshot, "chain_runtime_multicast_reject", 1, "runtime stats counted Chain+Multicast deferral under chaos budget")
            for _, line in ipairs(stats_result and stats_result.summary or {}) do
                log.info("runtime stats " .. tostring(line))
            end
            log.info("smoke chaos budget high-fanout run complete")
            state.running = false
        end)
    end

    requestRuntimeStats(true, function(reset_result)
        assertLine(reset_result and reset_result.ok == true, "runtime stats reset accepted", reset_result and reset_result.error)
        requestProbe("chaos_budget_report", function(report)
            local default_limits = report and report.default_limits or {}
            local chaos_limits = report and report.chaos_limits or {}
            assertLine(report and report.ok == true, "chaos budget profile report ok", report and report.error)
            assertLine((chaos_limits.MAX_PAYLOAD_FANOUT or 0) > (default_limits.MAX_PAYLOAD_FANOUT or 0), "chaos fanout cap exceeds default")
            assertLine((chaos_limits.MAX_NESTED_PAYLOAD_JOBS or 0) > (default_limits.MAX_NESTED_PAYLOAD_JOBS or 0), "chaos nested job cap exceeds default")
            assertLine((chaos_limits.MAX_LIVE_LAUNCHES_PER_TICK or 0) > 0, "chaos live launch density cap is positive")
            assertLine((chaos_limits.MAX_LIVE_LAUNCHES_PER_TICK or 0) <= (default_limits.MAX_LIVE_LAUNCHES_PER_TICK or 0), "chaos live launch density cap stays protective")
            assertLine((chaos_limits.MAX_LIVE_LAUNCHES_PER_TICK or 0) < (chaos_limits.MAX_PAYLOAD_FANOUT or 0), "chaos live launch density cap chunks high fanout")
            assertLine(chaos_limits.MAX_CHAIN_BRANCHES == default_limits.MAX_CHAIN_BRANCHES, "chaos budget keeps Chain branching disabled")

            requestProbe("chaos_multicast_high_dry_run", function(dry)
                assertLine(dry and dry.ok == true, "chaos direct Multicast high fanout dry-run ok", dry and dry.error)
                assertLine(dry and dry.dispatch_count == high_count, "chaos direct Multicast dry-run plans high fanout")

                requestProbe("chaos_multicast_high_launch", function(direct)
                    assertLine(direct and direct.ok == true, "chaos direct Multicast high fanout launch ok", direct and direct.error)
                    waitForJobsComplete(direct and direct.job_ids, high_count, function(direct_jobs)
                        adoptJobs(direct, "jobs", direct_jobs)
                        assertLine(jobsAllComplete(direct and direct.jobs, high_count), "chaos direct Multicast high fanout jobs complete")
                        assertLine(jobsCarryMulticastUserData(direct and direct.jobs, high_count, direct and direct.cast_id), "chaos direct Multicast userData carries fanout")

                        requestProbe("chaos_trigger_payload_multicast_post_hit", function(trigger_multi)
                            ensureTriggerSourceHit(trigger_multi, function(trigger_multi)
                            assertLine(trigger_multi and trigger_multi.ok == true, "chaos Trigger payload Multicast high fanout ok", trigger_multi and trigger_multi.error)
                            waitForJobsComplete(trigger_multi and trigger_multi.trigger_payload_job_ids, high_count, function(trigger_multi_jobs)
                                adoptJobs(trigger_multi, "trigger_payload_jobs", trigger_multi_jobs)
                                assertLine(jobsAllComplete(trigger_multi and trigger_multi.trigger_payload_jobs, high_count), "chaos Trigger payload Multicast payload jobs complete")
                                assertLine(payloadJobsCarryPostfixFanout(trigger_multi and trigger_multi.trigger_payload_jobs, high_count, trigger_multi and trigger_multi.cast_id, "Trigger", trigger_multi and trigger_multi.slot_id), "chaos Trigger payload Multicast userData carries fanout")

                                requestProbe("chaos_timer_payload_multicast_sequence", function(timer_multi)
                                    assertLine(timer_multi and timer_multi.ok == true, "chaos Timer payload Multicast high fanout schedules", timer_multi and timer_multi.error)
                                    requestTimerDelayCheck(timer_multi and timer_multi.timer_id, high_count, function(timer_done)
                                        assertLine(timer_done and timer_done.ok == true, "chaos Timer payload Multicast high fanout callback ok", timer_done and timer_done.error)
                                        waitForJobsComplete(timer_done and timer_done.timer_payload_job_ids, high_count, function(timer_jobs)
                                            adoptJobs(timer_done, "timer_payload_jobs", timer_jobs)
                                            assertLine(jobsAllComplete(timer_done and timer_done.timer_payload_jobs, high_count), "chaos Timer payload Multicast payload jobs complete")
                                            assertLine(payloadJobsCarryPostfixFanout(timer_done and timer_done.timer_payload_jobs, high_count, timer_done and timer_done.cast_id, "Timer", timer_done and timer_done.slot_id), "chaos Timer payload Multicast userData carries fanout")

                                            requestProbe("chaos_trigger_payload_burst_post_hit", function(trigger_burst)
                                                ensureTriggerSourceHit(trigger_burst, function(trigger_burst)
                                                assertLine(trigger_burst and trigger_burst.ok == true, "chaos Trigger payload Burst high fanout ok", trigger_burst and trigger_burst.error)
                                                waitForJobsComplete(trigger_burst and trigger_burst.trigger_payload_job_ids, high_count, function(trigger_burst_jobs)
                                                    adoptJobs(trigger_burst, "trigger_payload_jobs", trigger_burst_jobs)
                                                    assertLine(jobsAllComplete(trigger_burst and trigger_burst.trigger_payload_jobs, high_count), "chaos Trigger payload Burst payload jobs complete")
                                                    assertLine(payloadJobsCarryPostfixPattern(trigger_burst and trigger_burst.trigger_payload_jobs, high_count, trigger_burst and trigger_burst.cast_id, "Trigger", trigger_burst and trigger_burst.slot_id, "Burst"), "chaos Trigger payload Burst userData carries pattern fanout")

                                                    requestProbe("chaos_timer_payload_spread_sequence", function(timer_spread)
                                                        assertLine(timer_spread and timer_spread.ok == true, "chaos Timer payload Spread high fanout schedules", timer_spread and timer_spread.error)
                                                        requestTimerDelayCheck(timer_spread and timer_spread.timer_id, high_count, function(timer_spread_done)
                                                            assertLine(timer_spread_done and timer_spread_done.ok == true, "chaos Timer payload Spread high fanout callback ok", timer_spread_done and timer_spread_done.error)
                                                            waitForJobsComplete(timer_spread_done and timer_spread_done.timer_payload_job_ids, high_count, function(timer_spread_jobs)
                                                                adoptJobs(timer_spread_done, "timer_payload_jobs", timer_spread_jobs)
                                                                assertLine(jobsAllComplete(timer_spread_done and timer_spread_done.timer_payload_jobs, high_count), "chaos Timer payload Spread payload jobs complete")
                                                                assertLine(payloadJobsCarryPostfixPattern(timer_spread_done and timer_spread_done.timer_payload_jobs, high_count, timer_spread_done and timer_spread_done.cast_id, "Timer", timer_spread_done and timer_spread_done.slot_id, "Spread"), "chaos Timer payload Spread userData carries pattern fanout")

                                                                requestProbe("chaos_nested_trigger_timer_final_multicast_sequence", function(nested_trigger_timer)
                                                                    ensureTriggerSourceHit(nested_trigger_timer, function(nested_trigger_timer)
                                                                    assertLine(nested_trigger_timer and nested_trigger_timer.ok == true, "chaos Trigger->Timer nested final Multicast schedules", nested_trigger_timer and nested_trigger_timer.error)
                                                                    requestTimerDelayCheck(nested_trigger_timer and nested_trigger_timer.nested_timer_id, high_count, function(nested_trigger_timer_done)
                                                                        assertLine(nested_trigger_timer_done and nested_trigger_timer_done.ok == true, "chaos Trigger->Timer nested final Multicast callback ok", nested_trigger_timer_done and nested_trigger_timer_done.error)
                                                                        waitForJobsComplete(nested_trigger_timer_done and nested_trigger_timer_done.timer_payload_job_ids, high_count, function(nested_trigger_timer_jobs)
                                                                            adoptJobs(nested_trigger_timer_done, "timer_payload_jobs", nested_trigger_timer_jobs)
                                                                            assertLine(jobsAllComplete(nested_trigger_timer_done and nested_trigger_timer_done.timer_payload_jobs, high_count), "chaos Trigger->Timer nested final Multicast jobs complete")

                                                                            requestProbe("chaos_nested_timer_trigger_final_spread_sequence", function(nested_timer_trigger)
                                                                                assertLine(nested_timer_trigger and nested_timer_trigger.ok == true, "chaos Timer->Trigger nested final Spread schedules", nested_timer_trigger and nested_timer_trigger.error)
                                                                                requestTimerDelayCheck(nested_timer_trigger and nested_timer_trigger.timer_id, 1, function(nested_timer_trigger_done)
                                                                                    assertLine(nested_timer_trigger_done and nested_timer_trigger_done.ok == true, "chaos Timer->Trigger nested final Spread callback ok", nested_timer_trigger_done and nested_timer_trigger_done.error)
                                                                                    local nested_final_job_ids = nested_timer_trigger_done
                                                                                        and nested_timer_trigger_done.nested_trigger_hit_result
                                                                                        and nested_timer_trigger_done.nested_trigger_hit_result.job_ids
                                                                                        or nil
                                                                                    waitForJobsComplete(nested_final_job_ids, high_count, function(nested_timer_trigger_jobs)
                                                                                        adoptJobs(nested_timer_trigger_done, "nested_final_payload_jobs", nested_timer_trigger_jobs)
                                                                                        assertLine(jobsAllComplete(nested_timer_trigger_done and nested_timer_trigger_done.nested_final_payload_jobs, high_count), "chaos Timer->Trigger nested final Spread jobs complete")
                                                                                        assertLine(nestedFinalFanoutJobsCarryUserData(nested_timer_trigger_done and nested_timer_trigger_done.nested_final_payload_jobs, high_count, nested_timer_trigger_done and nested_timer_trigger_done.cast_id, "Trigger", nested_timer_trigger_done and nested_timer_trigger_done.nested_trigger_hit_result and nested_timer_trigger_done.nested_trigger_hit_result.source_slot_id, nested_timer_trigger_done and nested_timer_trigger_done.nested_final_payload_jobs and nested_timer_trigger_done.nested_final_payload_jobs[1] and nested_timer_trigger_done.nested_final_payload_jobs[1].launch_user_data and nested_timer_trigger_done.nested_final_payload_jobs[1].launch_user_data.root_source_slot_id, "Spread"), "chaos Timer->Trigger nested final Spread userData carries final fanout")

                                                                                        requestProbe("chaos_multicast_over_cap", function(over_direct)
                                                                                            assertLine(over_direct and over_direct.ok == true, "chaos direct Multicast over-cap rejects safely", over_direct and over_direct.error)
                                                                                            assertLine(over_direct and over_direct.fallback_reason == "multicast_cap_exceeded", "chaos direct Multicast over-cap has stable reason", over_direct and over_direct.fallback_reason)

                                                                                            requestProbe("chaos_nested_final_fanout_over_cap", function(over_nested)
                                                                                                assertLine(over_nested and over_nested.ok == true, "chaos nested final fanout over-cap rejects safely", over_nested and over_nested.error)
                                                                                                assertLine(over_nested and (over_nested.fallback_reason == "payload_multicast_fanout_cap_exceeded" or over_nested.fallback_reason == "exceeds_fanout_cap"), "chaos nested final fanout over-cap has stable reason", over_nested and over_nested.fallback_reason)

                                                                                                requestProbe("chaos_chain_multicast_still_deferred", function(chain_deferred)
                                                                                                    assertLine(chain_deferred and chain_deferred.ok == true, "chaos Chain+Multicast remains deferred", chain_deferred and chain_deferred.error)
                                                                                                    assertLine(chain_deferred and chain_deferred.fallback_reason == "chain_multicast_deferred", "chaos Chain+Multicast deferral reason is stable", chain_deferred and chain_deferred.fallback_reason)
                                                                                                    finish()
                                                                                                end)
                                                                                            end)
                                                                                        end)
                                                                                    end)
                                                                                end, launchAimPayload({
                                                                                    simulate_nested_trigger_hit = true,
                                                                                }))
                                                                            end, launchAimPayload())
                                                                        end)
                                                                    end)
                                                                    end)
                                                                end, launchAimPayload())
                                                            end)
                                                        end, {
                                                            timer_id = timer_spread and timer_spread.timer_id,
                                                            expected_payload_count = high_count,
                                                            observe_matured = true,
                                                        })
                                                    end, launchAimPayload())
                                                end)
                                                end)
                                            end, launchAimPayload())
                                        end)
                                    end, {
                                        timer_id = timer_multi and timer_multi.timer_id,
                                        expected_payload_count = high_count,
                                        observe_matured = true,
                                    })
                                end, launchAimPayload())
                            end)
                            end)
                        end, launchAimPayload())
                    end)
                end, launchAimPayload())
            end)
        end)
    end)
end

local function onKeyPress(key)
    if not dev.smokeTestsEnabled() then
        return true
    end
    local symbol = key and key.symbol and string.lower(tostring(key.symbol)) or ""
    if smoke_keys.matches(key, "num5") then
        runSmoke()
        return false
    end
    if smoke_keys.matches(key, "num6") then
        runMulticastSmoke()
        return false
    end
    if smoke_keys.matches(key, "num7") then
        runPatternSmoke("Spread")
        return false
    end
    if smoke_keys.matches(key, "num8") then
        runPatternSmoke("Burst")
        return false
    end
    if smoke_keys.matches(key, "num9") then
        runTriggerSmoke()
        return false
    end
    if smoke_keys.matches(key, "divide") then
        runTimerSmoke()
        return false
    end
    if smoke_keys.matches(key, "multiply") then
        runSpeedPlusSmoke()
        return false
    end
    if smoke_keys.matches(key, "minus") then
        runSizePlusSmoke()
        return false
    end
    if smoke_keys.matches(key, "decimal") then
        runChaosBudgetSmoke()
        return false
    end
    if symbol == "l" or key.code == input.KEY.L then
        runManualChainRealProbe()
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
            if not dev.liveSimpleDispatchEnabled() then
                if not state.skip_logged then
                    state.skip_logged = true
                    log.info(string.format("SKIP smoke live simple dispatch: enable %s", dev.liveSimpleDispatchSettingKey()))
                end
                return
            end
            if state.backend == "INIT" then
                requestBackend()
            elseif state.backend == "READY" and not state.ready_logged then
                state.ready_logged = true
                log.info("smoke live dispatch ready: press Numpad 5 for simple+nested+Chain audit/runtime plus Chain Speed+/Size+ payload modifiers, 6 for Multicast x3, 7 for Spread x3, 8 for Burst x3, 9 for Trigger v0 plus payload Multicast/Spread/Burst v0, / for Timer v0 plus payload Multicast/Spread/Burst v0, * for Speed+ v1, - for Size+ v0, Numpad . for chaos high-fanout budget stress, or L for manual Chain real-provider probe")
            end
        end,
        onKeyPress = onKeyPress,
    },
    eventHandlers = {
        [events.BACKEND_READY] = function()
            if not dev.smokeTestsEnabled() or not dev.liveSimpleDispatchEnabled() then
                return
            end
            clearTimer()
            state.backend = "READY"
            log.debug("backend READY")
        end,
        [events.BACKEND_UNAVAILABLE] = function(payload)
            if not dev.smokeTestsEnabled() or not dev.liveSimpleDispatchEnabled() then
                return
            end
            clearTimer()
            state.backend = "UNAVAILABLE"
            log.warn(string.format("backend unavailable: %s", tostring(payload and payload.reason)))
        end,
        [events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT] = function(payload)
            local request_id = payload and payload.request_id
            local cb = request_id and state.pending_probe[request_id]
            if cb then
                state.pending_probe[request_id] = nil
                cb(payload)
            end
        end,
        [events.COMPILE_RESULT] = function(payload)
            local request_id = payload and payload.request_id
            local cb = request_id and state.pending_compile[request_id]
            if cb then
                state.pending_compile[request_id] = nil
                cb(payload)
            end
        end,
        [events.CAST_OBSERVE_RESULT] = function(payload)
            local request_id = payload and payload.request_id
            if request_id and state.pending_observe[request_id] and payload and payload.ok == false then
                local cb = state.pending_observe[request_id]
                state.pending_observe[request_id] = nil
                cb({ ok = false, error = payload.error or "observe failed" })
            end
        end,
        [events.CAST_HIT_OBSERVED] = function(payload)
            local request_id = payload and payload.request_id
            local cb = request_id and state.pending_observe[request_id]
            if cb then
                state.pending_observe[request_id] = nil
                cb({
                    ok = true,
                    matched = payload and payload.matched == true,
                    live_2_2c = payload and payload.live_2_2c == true,
                    slot_id = payload and payload.slot_id or nil,
                    helper_engine_id = payload and payload.helper_engine_id or nil,
                    projectile_id = payload and payload.projectile_id or nil,
                })
            end
        end,
        [events.RUNTIME_STATS_RESULT] = function(payload)
            local request_id = payload and payload.request_id
            local cb = request_id and state.pending_stats[request_id]
            if cb then
                state.pending_stats[request_id] = nil
                cb(payload)
            end
        end,
        [events.INTERCEPT_DISPATCH_RESULT] = function(payload)
            if not state.running or not state.last_spell_id then
                return
            end
            if not payload or payload.spell_id ~= state.last_spell_id then
                return
            end
            if payload.ok == true then
                state.intercept_seen = true
                state.intercept_live_2_2c = payload.live_2_2c == true
                state.intercept_projectile_registered = payload.projectile_registered == true
                state.intercept_projectile_id = payload.projectile_id
                state.intercept_slot_id = payload.slot_id
                state.intercept_helper_engine_id = payload.helper_engine_id
                state.intercept_dispatch_kind = payload.dispatch_kind
                state.intercept_runtime = payload.runtime
                state.intercept_fallback = payload.fallback
                state.intercept_cast_id = payload.cast_id
                log.info(string.format(
                    "live simple intercept observed spell_id=%s dispatch_kind=%s runtime=%s live_2_2c=%s slot_id=%s helper_engine_id=%s projectile_id=%s cast_id=%s",
                    tostring(payload.spell_id),
                    tostring(payload.dispatch_kind),
                    tostring(payload.runtime),
                    tostring(payload.live_2_2c),
                    tostring(payload.slot_id),
                    tostring(payload.helper_engine_id),
                    tostring(payload.projectile_id),
                    tostring(payload.cast_id)
                ))
            else
                log.error(string.format("live simple intercept dispatch failed spell_id=%s err=%s", tostring(payload.spell_id), tostring(payload.error)))
            end
        end,
    },
}
