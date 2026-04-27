local async = require("openmw.async")
local camera = require("openmw.camera")
local core = require("openmw.core")
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
    core.sendGlobalEvent(events.LIVE_SIMPLE_DISPATCH_PROBE, payload)
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

                            requestRuntimeStats(false, function(stats_result)
                                local snapshot = stats_result and stats_result.snapshot or {}
                                assertLine(stats_result and stats_result.ok == true, "runtime stats snapshot returned", stats_result and stats_result.error)
                                assertCounterAtLeast(snapshot, "live_trigger_attempts", 5, "runtime stats counted live Trigger attempts")
                                assertCounterAtLeast(snapshot, "live_trigger_qualified", 4, "runtime stats counted live Trigger qualifications")
                                assertCounterAtLeast(snapshot, "live_trigger_rejected", 1, "runtime stats counted live Trigger rejection")
                                assertCounterAtLeast(snapshot, "live_trigger_disabled_rejections", 1, "runtime stats counted disabled Trigger rejection")
                                assertCounterAtLeast(snapshot, "live_trigger_source_jobs_enqueued", 3, "runtime stats counted Trigger source enqueues")
                                assertCounterAtLeast(snapshot, "live_trigger_source_hits", 4, "runtime stats counted Trigger source hits")
                                assertCounterAtLeast(snapshot, "live_trigger_payload_jobs_enqueued", 2, "runtime stats counted Trigger payload enqueue")
                                assertCounterAtLeast(snapshot, "live_trigger_payload_jobs_processed", 2, "runtime stats counted Trigger payload processing")
                                assertCounterAtLeast(snapshot, "live_trigger_payload_launch_ok", 2, "runtime stats counted Trigger payload launch ok")
                                assertCounterAtLeast(snapshot, "live_trigger_duplicate_hits_suppressed", 2, "runtime stats counted Trigger duplicate suppression")
                                assertCounterAtLeast(snapshot, "live_trigger_post_hit_smoke_observed", 2, "runtime stats counted post-hit smoke checkpoint")
                                assertCounterAtLeast(snapshot, "hits_seen", 4, "runtime stats counted simulated post-hit events")
                                assertCounterAtLeast(snapshot, "jobs_enqueued", 5, "runtime stats counted source and payload orchestrator enqueue")
                                assertCounterAtLeast(snapshot, "live_helper_jobs_enqueued", 5, "runtime stats counted source and payload live helper enqueue")
                                assertCounterAtLeast(snapshot, "jobs_processed", 5, "runtime stats counted source and payload processing")
                                assertCounterAtLeast(snapshot, "live_helper_jobs_processed", 5, "runtime stats counted source and payload live helper processing")
                                assertCounterAtLeast(snapshot, "sfp_launch_attempts", 5, "runtime stats counted source and payload SFP launches")
                                assertCounterAtLeast(snapshot, "sfp_launch_ok", 5, "runtime stats counted source and payload SFP launch ok")
                                assertCounterAtLeast(snapshot, "hits_userdata_routed", 2, "runtime stats counted post-hit userData routes")
                                assertCounterAtLeast(snapshot, "hits_spellid_fallback_routed", 2, "runtime stats counted post-hit spellId fallback routes")
                                assertCounterAtLeast(snapshot, "queue_drained_observed", 2, "runtime stats observed Trigger queue drain")
                                for _, line in ipairs(stats_result and stats_result.summary_lines or {}) do
                                    log.info("runtime stats " .. tostring(line))
                                end
                                log.info("smoke live Trigger run complete")
                                state.running = false
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

                                    requestRuntimeStats(false, function(stats_result)
                                        local snapshot = stats_result and stats_result.snapshot or {}
                                        assertLine(stats_result and stats_result.ok == true, "runtime stats snapshot returned", stats_result and stats_result.error)
                                        assertCounterAtLeast(snapshot, "live_timer_attempts", 3, "runtime stats counted live Timer attempts")
                                        assertCounterAtLeast(snapshot, "live_timer_qualified", 2, "runtime stats counted live Timer qualifications")
                                        assertCounterAtLeast(snapshot, "live_timer_rejected", 1, "runtime stats counted live Timer rejection")
                                        assertCounterAtLeast(snapshot, "live_timer_disabled_rejections", 1, "runtime stats counted disabled Timer rejection")
                                        assertCounterAtLeast(snapshot, "live_timer_source_jobs_enqueued", 1, "runtime stats counted Timer source enqueue")
                                        assertCounterAtLeast(snapshot, "live_timer_wait_jobs_enqueued", 1, "runtime stats counted async Timer wait schedule")
                                        assertCounterAtLeast(snapshot, "live_timer_wait_jobs_processed", 1, "runtime stats counted async Timer callback processing")
                                        assertCounterAtLeast(snapshot, "live_timer_payload_jobs_enqueued", 1, "runtime stats counted async Timer payload enqueue")
                                        assertCounterAtLeast(snapshot, "live_timer_payload_jobs_processed", 1, "runtime stats counted Timer payload processing")
                                        assertCounterAtLeast(snapshot, "live_timer_payload_launch_ok", 1, "runtime stats counted Timer payload launch ok")
                                        assertCounterAtLeast(snapshot, "live_timer_duplicate_schedules_suppressed", 1, "runtime stats counted Timer duplicate suppression")
                                        assertCounterAtLeast(snapshot, "live_timer_async_scheduled", 1, "runtime stats counted async Timer schedule")
                                        assertCounterAtLeast(snapshot, "live_timer_async_callback_seen", 1, "runtime stats counted async Timer callback")
                                        assertCounterAtLeast(snapshot, "live_timer_async_payload_enqueued", 1, "runtime stats counted async Timer payload enqueue")
                                        assertCounterAtLeast(snapshot, "live_timer_async_payload_ok", 1, "runtime stats counted async Timer payload ok")
                                        assertCounterAtLeast(snapshot, "live_timer_async_pending", 1, "runtime stats recorded async Timer pending")
                                        assertCounterAtLeast(snapshot, "live_timer_async_pending_cleared", 1, "runtime stats counted async Timer pending clear")
                                        assertCounterAtLeast(snapshot, "live_timer_async_duplicate_suppressed", 1, "runtime stats counted async Timer duplicate suppression")
                                        assertCounterAtLeast(snapshot, "live_timer_real_delay_attempts", 1, "runtime stats counted Timer real-delay attempt")
                                        assertCounterAtLeast(snapshot, "live_timer_real_delay_matured", 1, "runtime stats counted Timer async maturity")
                                        assertCounterAtLeast(snapshot, "live_timer_real_delay_payload_ok", 1, "runtime stats counted Timer async payload ok")
                                        assertCounterAtLeast(snapshot, "live_timer_real_delay_smoke_scheduled", 1, "runtime stats counted async Timer smoke schedule")
                                        assertCounterAtLeast(snapshot, "live_timer_real_delay_smoke_pending", 1, "runtime stats counted async Timer smoke pending")
                                        assertCounterAtLeast(snapshot, "live_timer_real_delay_smoke_callback_ok", 1, "runtime stats counted async Timer smoke callback ok")
                                        assertCounterAtLeast(snapshot, "live_timer_immediate_payload_blocked", 1, "runtime stats counted Timer immediate payload blocking")
                                        assertCounterAtLeast(snapshot, "timer_source_detonation_blocked", 1, "runtime stats counted Timer source detonation blocker")
                                        assertCounterAtLeast(snapshot, "jobs_enqueued", 2, "runtime stats counted source and async payload jobs")
                                        assertCounterAtLeast(snapshot, "live_helper_jobs_enqueued", 2, "runtime stats counted source and payload live helper jobs")
                                        assertCounterAtLeast(snapshot, "jobs_processed", 2, "runtime stats counted source and payload processing")
                                        assertCounterAtLeast(snapshot, "live_helper_jobs_processed", 2, "runtime stats counted live helper processing")
                                        assertCounterAtLeast(snapshot, "sfp_launch_attempts", 2, "runtime stats counted Timer source and payload SFP launches")
                                        assertCounterAtLeast(snapshot, "sfp_launch_ok", 2, "runtime stats counted Timer source and payload SFP launch ok")
                                        assertCounterAtLeast(snapshot, "queue_drained_observed", 1, "runtime stats observed queue drain")
                                        for _, line in ipairs(stats_result and stats_result.summary_lines or {}) do
                                            log.info("runtime stats " .. tostring(line))
                                        end
                                        log.info("smoke live Timer async simulation-delay run complete")
                                        state.running = false
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

local function onKeyPress(key)
    if not dev.smokeTestsEnabled() then
        return true
    end
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
                    log.info("smoke live dispatch ready: press Numpad 5 for simple, 6 for Multicast x3, 7 for Spread x3, 8 for Burst x3, 9 for Trigger v0, / for Timer v0, * for Speed+ v1, or - for Size+ v0")
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
