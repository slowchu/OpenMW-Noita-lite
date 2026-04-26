local async = require("openmw.async")
local core = require("openmw.core")
local input = require("openmw.input")
local self = require("openmw.self")
local types = require("openmw.types")

local dev = require("scripts.spellforge.shared.dev")
local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_live_simple_dispatch")

local state = {
    backend = "INIT",
    handshake_timer = nil,
    running = false,
    skip_logged = false,
    ready_logged = false,
    pending_probe = {},
    pending_compile = {},
    pending_observe = {},
    last_spell_id = nil,
    intercept_seen = false,
    intercept_live_2_2c = false,
    intercept_projectile_registered = false,
    intercept_projectile_id = nil,
    intercept_slot_id = nil,
    intercept_helper_engine_id = nil,
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

local function requestProbe(mode, callback)
    local request_id = nextRequestId("smoke-live-simple-probe")
    waitFor(state.pending_probe, request_id, 5, callback)
    core.sendGlobalEvent(events.LIVE_SIMPLE_DISPATCH_PROBE, {
        sender = self.object,
        actor = self,
        request_id = request_id,
        mode = mode,
    })
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

        local observe_request_id = nextRequestId("smoke-live-simple-observe")
        beginObserve(compile_result.spell_id, observe_request_id)
        log.info("manual cast required: select the compiled simple spell and cast within 30s")

        waitFor(state.pending_observe, observe_request_id, 30, function(hit_result)
            assertLine(state.intercept_seen == true, "intercept dispatched for compiled simple spell")
            assertLine(state.intercept_live_2_2c == true, "intercept used feature-flagged live 2.2c simple bridge")
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
            log.info("smoke live simple dispatch run complete")
            state.running = false
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
end

local function onKeyPress(key)
    if not dev.smokeTestsEnabled() then
        return true
    end
    local symbol = key.symbol and string.lower(key.symbol) or ""
    if symbol == "n" or key.code == input.KEY.N then
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
                log.info("smoke live simple dispatch ready: press N, then cast the compiled simple spell when prompted")
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
                log.info(string.format(
                    "live simple intercept observed spell_id=%s live_2_2c=%s slot_id=%s helper_engine_id=%s projectile_id=%s",
                    tostring(payload.spell_id),
                    tostring(payload.live_2_2c),
                    tostring(payload.slot_id),
                    tostring(payload.helper_engine_id),
                    tostring(payload.projectile_id)
                ))
            else
                log.error(string.format("live simple intercept dispatch failed spell_id=%s err=%s", tostring(payload.spell_id), tostring(payload.error)))
            end
        end,
    },
}
