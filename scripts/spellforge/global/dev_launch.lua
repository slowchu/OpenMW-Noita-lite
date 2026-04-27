local async = require("openmw.async")

local dev = require("scripts.spellforge.shared.dev")
local dev_runtime = require("scripts.spellforge.global.dev_runtime")
local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("global.dev_launch")
local orchestrator = require("scripts.spellforge.global.orchestrator")
local patterns = require("scripts.spellforge.global.patterns")
local plan_cache = require("scripts.spellforge.global.plan_cache")
local projectile_registry = require("scripts.spellforge.global.projectile_registry")
local sfp_userdata = require("scripts.spellforge.shared.sfp_userdata")

local dev_launch = {}

local pending_hits = {}
local pending_timer_runs = {}
local pending_trigger_runs = {}

local TIMER_TICKS_PER_SECOND = 2
-- TODO(2.2c): replace this approximation with the actual SFP/helper projectile speed once exposed.
local DEFAULT_TIMER_PROJECTILE_SPEED = 1000
local TIMER_RAYCAST_SEGMENT_TOLERANCE = 4
local TRIGGER_PAYLOAD_TICK_DELAY = 0.01

local SIMPLE_FIRE_DAMAGE_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

local MULTICAST_FIRE_DAMAGE_TARGET = {
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

local SPREAD_MULTICAST_FIRE_DAMAGE_TARGET = {
    { id = "spellforge_spread", params = { preset = 2 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

local BURST_MULTICAST_FIRE_DAMAGE_TARGET = {
    { id = "spellforge_burst", params = { count = 5 } },
    { id = "spellforge_multicast", params = { count = 5 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

local TIMER_FIRE_FROST_TARGET = {
    { id = "spellforge_multicast", params = { count = 2 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

local TRIGGER_FIRE_FROST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

local TRIGGER_MULTICAST_FIRE_FROST_TARGET = {
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

local PERFORMANCE_STRESS_TARGET = {
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 10, magnitudeMax = 10 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "spellforge_multicast", params = { count = 8 } },
    { id = "spellforge_burst", params = { count = 8 } },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 10, magnitudeMax = 10 },
    { id = "spellforge_trigger" },
    { id = "spellforge_multicast", params = { count = 2 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 10, magnitudeMax = 10 },
}

local function cloneParams(params)
    local out = {}
    local keys = {}
    for key in pairs(params or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        out[key] = params[key]
    end
    return out
end

local PRESENTATION_METADATA_FIELDS = {
    "areaVfxRecId",
    "areaVfxScale",
    "vfxRecId",
    "boltModel",
    "hitModel",
}

local function cloneEffect(effect)
    local out = {
        id = effect.id,
        range = effect.range,
        area = effect.area,
        duration = effect.duration,
        magnitudeMin = effect.magnitudeMin,
        magnitudeMax = effect.magnitudeMax,
        params = cloneParams(effect.params),
    }
    for _, field in ipairs(PRESENTATION_METADATA_FIELDS) do
        if effect[field] ~= nil then
            out[field] = effect[field]
        end
    end
    return out
end

local function cloneEffects(effects)
    local out = {}
    for i, effect in ipairs(effects or {}) do
        out[i] = cloneEffect(effect)
    end
    return out
end

local function send(sender, event_name, payload)
    if sender and type(sender.sendEvent) == "function" then
        sender:sendEvent(event_name, payload)
    end
end

local function firstErrorMessage(result)
    local first = result and result.errors and result.errors[1]
    return first and first.message or (result and result.error) or "unknown error"
end

local function ensureDevLaunchEnabled()
    if not dev.devLaunchEnabled() then
        return false, string.format("dev launch disabled; enable %s", dev.devLaunchSettingKey())
    end
    return true, nil
end

local function firstEffectId(helper)
    return dev_runtime.firstEffectId(helper)
end

local function findPrefixOp(ops, opcode)
    for _, op in ipairs(ops or {}) do
        if op.opcode == opcode then
            return op
        end
    end
    return nil
end

local function normalizeEffectId(effect_id)
    if effect_id == nil then
        return nil
    end
    return string.lower(tostring(effect_id))
end

local function timerDelayTicks(seconds)
    local value = tonumber(seconds) or 0
    local ticks = math.ceil(value * TIMER_TICKS_PER_SECOND)
    if ticks < 1 then
        ticks = 1
    end
    return ticks
end

local function safeVectorLength(vector)
    local ok, length = pcall(function()
        return vector:length()
    end)
    if ok then
        return tonumber(length)
    end
    return nil
end

local function safeVectorDistance(a, b)
    local ok, diff = pcall(function()
        return a - b
    end)
    if not ok then
        return nil
    end
    return safeVectorLength(diff)
end

local function normalizeDirection(direction)
    if direction == nil then
        return nil, nil, "timer direction is missing"
    end
    local ok, normalized, original_length = pcall(function()
        return direction:normalize()
    end)
    if not ok or normalized == nil then
        return nil, nil, "timer direction is not a vector"
    end
    original_length = tonumber(original_length) or safeVectorLength(direction)
    if original_length == nil or original_length <= 0.0001 then
        return nil, nil, "timer direction has zero length"
    end
    return normalized, original_length, nil
end

local function computeTimerResolution(launch_payload, built, source_helper)
    local start_pos = launch_payload and launch_payload.start_pos or nil
    if start_pos == nil then
        return {
            ok = false,
            stage = "timer_resolution",
            recipe_id = built and built.recipe_id or nil,
            source_slot_id = source_helper and source_helper.slot_id or nil,
            error = "missing Timer source start_pos",
        }
    end

    local direction, direction_length, direction_error = normalizeDirection(launch_payload and launch_payload.direction or nil)
    if not direction then
        return {
            ok = false,
            stage = "timer_resolution",
            recipe_id = built and built.recipe_id or nil,
            source_slot_id = source_helper and source_helper.slot_id or nil,
            error = direction_error,
        }
    end

    local timer_seconds = tonumber(built and built.timer_seconds) or 0
    local projectile_speed = tonumber(launch_payload and launch_payload.timer_projectile_speed) or DEFAULT_TIMER_PROJECTILE_SPEED
    if projectile_speed <= 0 then
        return {
            ok = false,
            stage = "timer_resolution",
            recipe_id = built and built.recipe_id or nil,
            source_slot_id = source_helper and source_helper.slot_id or nil,
            error = "Timer projectile speed must be positive",
        }
    end

    local travel_distance = projectile_speed * timer_seconds
    local endpoint = start_pos + (direction * travel_distance)
    local resolution_pos = endpoint
    local resolution_kind = "endpoint_no_raycast"
    local resolution_hit_object = nil
    local raycast_available = false
    local raycast_note = "global raycast unavailable; using predicted endpoint"

    local hint = launch_payload and launch_payload.timer_raycast or nil
    if type(hint) == "table" and hint.available == true then
        raycast_available = true
        raycast_note = "local raycast hint evaluated"
        if hint.hit == true and hint.hit_pos ~= nil then
            local hit_distance = safeVectorDistance(start_pos, hint.hit_pos)
            if hit_distance ~= nil and hit_distance <= travel_distance + TIMER_RAYCAST_SEGMENT_TOLERANCE then
                resolution_pos = hint.hit_pos
                resolution_kind = "ray_hit"
                resolution_hit_object = hint.hit_object or launch_payload.hit_object
            else
                resolution_kind = "midair"
            end
        else
            resolution_kind = "midair"
        end
    end

    return {
        ok = true,
        timer_start_pos = start_pos,
        timer_direction = direction,
        timer_direction_length = direction_length,
        timer_endpoint = endpoint,
        timer_projectile_speed = projectile_speed,
        timer_travel_distance = travel_distance,
        timer_seconds = timer_seconds,
        resolution_pos = resolution_pos,
        resolution_kind = resolution_kind,
        resolution_hit_object = resolution_hit_object,
        raycast_available = raycast_available,
        raycast_note = raycast_note,
    }
end

local function firstTimerSeconds(plan)
    for _, group in ipairs(plan and plan.groups or {}) do
        for _, op in ipairs(group.postfix_ops or {}) do
            if op.opcode == "Timer" then
                return tonumber(op.params and op.params.seconds) or 0
            end
        end
    end
    return nil
end

local function classifyTimerHelpers(helpers)
    local source_helpers = {}
    local payload_helpers = {}
    local payload_by_source_slot_id = {}

    for _, helper in ipairs(helpers or {}) do
        local effect_id = normalizeEffectId(firstEffectId(helper))
        if helper.source_postfix_opcode == "Timer" or helper.timer_source_slot_id ~= nil then
            payload_helpers[#payload_helpers + 1] = helper
            if helper.timer_source_slot_id then
                payload_by_source_slot_id[helper.timer_source_slot_id] = helper
            end
        elseif effect_id == "firedamage" then
            source_helpers[#source_helpers + 1] = helper
        end
    end

    return source_helpers, payload_helpers, payload_by_source_slot_id
end

local function classifyTriggerHelpers(helpers)
    local source_helpers = {}
    local payload_helpers = {}
    local payload_by_source_slot_id = {}

    for _, helper in ipairs(helpers or {}) do
        local effect_id = normalizeEffectId(firstEffectId(helper))
        if helper.source_postfix_opcode == "Trigger" or helper.trigger_source_slot_id ~= nil then
            payload_helpers[#payload_helpers + 1] = helper
            if helper.trigger_source_slot_id then
                payload_by_source_slot_id[helper.trigger_source_slot_id] = helper
            end
        elseif effect_id == "firedamage" then
            source_helpers[#source_helpers + 1] = helper
        end
    end

    return source_helpers, payload_helpers, payload_by_source_slot_id
end

local function buildEmitterPlan(effects, expected_helper_count)
    local enabled, disabled_reason = ensureDevLaunchEnabled()
    if not enabled then
        return { ok = false, error = disabled_reason }
    end

    local compiled = plan_cache.compileOrGet(cloneEffects(effects))
    if not compiled.ok then
        return {
            ok = false,
            stage = "compile",
            recipe_id = compiled.recipe_id,
            error = firstErrorMessage(compiled),
            errors = compiled.errors,
        }
    end

    local attached = plan_cache.attachHelperRecords(compiled.recipe_id)
    if not attached.ok then
        return {
            ok = false,
            stage = "helper_records",
            recipe_id = compiled.recipe_id,
            error = firstErrorMessage(attached),
            errors = attached.errors,
        }
    end

    local plan = attached.plan
    local helpers = plan and plan.helper_records or nil
    if type(helpers) ~= "table" or #helpers == 0 then
        return {
            ok = false,
            stage = "helper_records",
            recipe_id = compiled.recipe_id,
            error = "no helper record materialized",
        }
    end
    if expected_helper_count ~= nil and #helpers ~= expected_helper_count then
        return {
            ok = false,
            stage = "helper_records",
            recipe_id = compiled.recipe_id,
            error = string.format("expected %d helper records, got %d", expected_helper_count, #helpers),
        }
    end

    return {
        ok = true,
        recipe_id = compiled.recipe_id,
        reused = compiled.reused == true,
        plan = plan,
        slot_count = plan.slot_count or 0,
        helper_record_count = plan.helper_record_count or 0,
        helpers = helpers,
        helper = helpers[1],
        helper_engine_id = helpers[1] and helpers[1].engine_id or nil,
        slot_id = helpers[1] and helpers[1].slot_id or nil,
        effect_id = firstEffectId(helpers[1]),
    }
end

function dev_launch.buildSimpleEmitterPlan()
    return buildEmitterPlan(SIMPLE_FIRE_DAMAGE_TARGET, 1)
end

function dev_launch.buildMulticastEmitterPlan()
    return buildEmitterPlan(MULTICAST_FIRE_DAMAGE_TARGET, 3)
end

function dev_launch.buildSpreadEmitterPlan()
    local built = buildEmitterPlan(SPREAD_MULTICAST_FIRE_DAMAGE_TARGET, 3)
    if not built.ok then
        return built
    end

    local spread_op = nil
    local multicast_op = nil
    for _, helper in ipairs(built.helpers or {}) do
        local helper_spread = findPrefixOp(helper.prefix_ops, "Spread")
        local helper_multicast = findPrefixOp(helper.prefix_ops, "Multicast")
        if not helper_spread then
            return {
                ok = false,
                stage = "spread_plan",
                recipe_id = built.recipe_id,
                slot_id = helper.slot_id,
                error = "Spread metadata missing from helper slot",
            }
        end
        if not helper_multicast then
            return {
                ok = false,
                stage = "spread_plan",
                recipe_id = built.recipe_id,
                slot_id = helper.slot_id,
                error = "Multicast metadata missing from Spread helper slot",
            }
        end
        if normalizeEffectId(firstEffectId(helper)) ~= "firedamage" then
            return {
                ok = false,
                stage = "spread_plan",
                recipe_id = built.recipe_id,
                slot_id = helper.slot_id,
                error = "Spread helper slot is not Fire Damage",
            }
        end
        spread_op = spread_op or helper_spread
        multicast_op = multicast_op or helper_multicast
    end

    local spread_angle_degrees, spread_preset = patterns.spreadSideAngleDegrees(spread_op and spread_op.params or nil)
    built.spread_op = spread_op
    built.multicast_op = multicast_op
    built.spread_preset = spread_preset
    built.spread_angle_degrees = spread_angle_degrees
    built.spread_metadata_exists = spread_op ~= nil
    built.multicast_metadata_exists = multicast_op ~= nil
    return built
end

function dev_launch.buildBurstEmitterPlan()
    local built = buildEmitterPlan(BURST_MULTICAST_FIRE_DAMAGE_TARGET, 5)
    if not built.ok then
        return built
    end

    local burst_op = nil
    local multicast_op = nil
    for _, helper in ipairs(built.helpers or {}) do
        local helper_burst = findPrefixOp(helper.prefix_ops, "Burst")
        local helper_multicast = findPrefixOp(helper.prefix_ops, "Multicast")
        if not helper_burst then
            return {
                ok = false,
                stage = "burst_plan",
                recipe_id = built.recipe_id,
                slot_id = helper.slot_id,
                error = "Burst metadata missing from helper slot",
            }
        end
        if not helper_multicast then
            return {
                ok = false,
                stage = "burst_plan",
                recipe_id = built.recipe_id,
                slot_id = helper.slot_id,
                error = "Multicast metadata missing from Burst helper slot",
            }
        end
        if normalizeEffectId(firstEffectId(helper)) ~= "firedamage" then
            return {
                ok = false,
                stage = "burst_plan",
                recipe_id = built.recipe_id,
                slot_id = helper.slot_id,
                error = "Burst helper slot is not Fire Damage",
            }
        end
        burst_op = burst_op or helper_burst
        multicast_op = multicast_op or helper_multicast
    end

    local burst_ring_angle_degrees, burst_param_count = patterns.burstRingAngleDegrees(burst_op and burst_op.params or nil)
    built.burst_op = burst_op
    built.multicast_op = multicast_op
    built.burst_param_count = burst_param_count
    built.burst_ring_angle_degrees = burst_ring_angle_degrees
    built.burst_metadata_exists = burst_op ~= nil
    built.multicast_metadata_exists = multicast_op ~= nil
    return built
end

function dev_launch.buildTimerEmitterPlan()
    local built = buildEmitterPlan(TIMER_FIRE_FROST_TARGET, 4)
    if not built.ok then
        return built
    end

    local source_helpers, payload_helpers, payload_by_source_slot_id = classifyTimerHelpers(built.helpers)
    if #source_helpers ~= 2 then
        return {
            ok = false,
            stage = "timer_plan",
            recipe_id = built.recipe_id,
            error = string.format("expected 2 source Fire Damage helpers, got %d", #source_helpers),
        }
    end
    if #payload_helpers ~= 2 then
        return {
            ok = false,
            stage = "timer_plan",
            recipe_id = built.recipe_id,
            error = string.format("expected 2 Timer payload helpers, got %d", #payload_helpers),
        }
    end

    for _, helper in ipairs(payload_helpers) do
        if normalizeEffectId(firstEffectId(helper)) ~= "frostdamage" then
            return {
                ok = false,
                stage = "timer_plan",
                recipe_id = built.recipe_id,
                error = string.format("Timer payload helper slot_id=%s is not Frost Damage", tostring(helper.slot_id)),
            }
        end
    end

    local timer_seconds = firstTimerSeconds(built.plan)
    if timer_seconds == nil then
        return {
            ok = false,
            stage = "timer_plan",
            recipe_id = built.recipe_id,
            error = "Timer postfix metadata not found",
        }
    end

    built.source_helpers = source_helpers
    built.timer_payload_helpers = payload_helpers
    built.timer_payload_by_source_slot_id = payload_by_source_slot_id
    built.timer_seconds = timer_seconds
    built.timer_delay_ticks = timerDelayTicks(timer_seconds)
    return built
end

local function buildTriggerEmitterPlan(effects, expected_count)
    local built = buildEmitterPlan(effects, expected_count * 2)
    if not built.ok then
        return built
    end

    local source_helpers, payload_helpers, payload_by_source_slot_id = classifyTriggerHelpers(built.helpers)
    if #source_helpers ~= expected_count then
        return {
            ok = false,
            stage = "trigger_plan",
            recipe_id = built.recipe_id,
            error = string.format("expected %d source Fire Damage helpers, got %d", expected_count, #source_helpers),
        }
    end
    if #payload_helpers ~= expected_count then
        return {
            ok = false,
            stage = "trigger_plan",
            recipe_id = built.recipe_id,
            error = string.format("expected %d Trigger payload helpers, got %d", expected_count, #payload_helpers),
        }
    end

    for _, source_helper in ipairs(source_helpers) do
        if not payload_by_source_slot_id[source_helper.slot_id] then
            return {
                ok = false,
                stage = "trigger_plan",
                recipe_id = built.recipe_id,
                source_slot_id = source_helper.slot_id,
                error = "missing Trigger payload helper for source slot",
            }
        end
    end
    for _, helper in ipairs(payload_helpers) do
        if normalizeEffectId(firstEffectId(helper)) ~= "frostdamage" then
            return {
                ok = false,
                stage = "trigger_plan",
                recipe_id = built.recipe_id,
                error = string.format("Trigger payload helper slot_id=%s is not Frost Damage", tostring(helper.slot_id)),
            }
        end
    end

    built.source_helpers = source_helpers
    built.trigger_payload_helpers = payload_helpers
    built.trigger_payload_by_source_slot_id = payload_by_source_slot_id
    return built
end

function dev_launch.buildTriggerEmitterPlan(multicast)
    if multicast == true then
        return buildTriggerEmitterPlan(TRIGGER_MULTICAST_FIRE_FROST_TARGET, 3)
    end
    return buildTriggerEmitterPlan(TRIGGER_FIRE_FROST_TARGET, 1)
end

local function classifyPerformanceStressHelpers(helpers)
    local source_helpers = {}
    local timer_payload_helpers = {}
    local trigger_payload_helpers = {}
    local by_slot_id = {}
    for _, helper in ipairs(helpers or {}) do
        if type(helper) == "table" then
            by_slot_id[helper.slot_id] = helper
            local effect_id = normalizeEffectId(firstEffectId(helper))
            if helper.source_postfix_opcode == "Timer" then
                timer_payload_helpers[#timer_payload_helpers + 1] = helper
            elseif helper.source_postfix_opcode == "Trigger" then
                trigger_payload_helpers[#trigger_payload_helpers + 1] = helper
            elseif helper.parent_slot_id == nil and effect_id == "firedamage" then
                source_helpers[#source_helpers + 1] = helper
            end
        end
    end
    return source_helpers, timer_payload_helpers, trigger_payload_helpers, by_slot_id
end

function dev_launch.buildPerformanceStressPlan()
    local built = buildEmitterPlan(PERFORMANCE_STRESS_TARGET, 25)
    if not built.ok then
        return built
    end

    local source_helpers, timer_payload_helpers, trigger_payload_helpers, by_slot_id = classifyPerformanceStressHelpers(built.helpers)
    if #source_helpers ~= 1 then
        return {
            ok = false,
            stage = "performance_stress_plan",
            recipe_id = built.recipe_id,
            error = string.format("expected 1 source Fireball helper, got %d", #source_helpers),
        }
    end
    if #timer_payload_helpers ~= 8 then
        return {
            ok = false,
            stage = "performance_stress_plan",
            recipe_id = built.recipe_id,
            error = string.format("expected 8 Timer Frostball helpers, got %d", #timer_payload_helpers),
        }
    end
    if #trigger_payload_helpers ~= 16 then
        return {
            ok = false,
            stage = "performance_stress_plan",
            recipe_id = built.recipe_id,
            error = string.format("expected 16 Trigger Fire Damage helpers, got %d", #trigger_payload_helpers),
        }
    end

    for _, helper in ipairs(timer_payload_helpers) do
        if normalizeEffectId(firstEffectId(helper)) ~= "frostdamage" then
            return {
                ok = false,
                stage = "performance_stress_plan",
                recipe_id = built.recipe_id,
                error = string.format("Timer payload helper slot_id=%s is not Frost Damage", tostring(helper.slot_id)),
            }
        end
    end
    for _, helper in ipairs(trigger_payload_helpers) do
        if normalizeEffectId(firstEffectId(helper)) ~= "firedamage" then
            return {
                ok = false,
                stage = "performance_stress_plan",
                recipe_id = built.recipe_id,
                error = string.format("Trigger payload helper slot_id=%s is not Fire Damage", tostring(helper.slot_id)),
            }
        end
        if not by_slot_id[helper.trigger_source_slot_id] then
            return {
                ok = false,
                stage = "performance_stress_plan",
                recipe_id = built.recipe_id,
                error = string.format("missing Frost Trigger source for payload slot_id=%s", tostring(helper.slot_id)),
            }
        end
    end

    local timer_seconds = firstTimerSeconds(built.plan)
    if timer_seconds == nil then
        return {
            ok = false,
            stage = "performance_stress_plan",
            recipe_id = built.recipe_id,
            error = "Timer postfix metadata not found",
        }
    end

    local burst_op = findPrefixOp(timer_payload_helpers[1] and timer_payload_helpers[1].prefix_ops, "Burst")
    local multicast_op = findPrefixOp(timer_payload_helpers[1] and timer_payload_helpers[1].prefix_ops, "Multicast")
    built.source_helpers = source_helpers
    built.timer_payload_helpers = timer_payload_helpers
    built.trigger_payload_helpers = trigger_payload_helpers
    built.helpers_by_slot_id = by_slot_id
    built.timer_seconds = timer_seconds
    built.timer_delay_ticks = timerDelayTicks(timer_seconds)
    built.burst_op = burst_op
    built.multicast_op = multicast_op
    built.burst_metadata_exists = burst_op ~= nil
    built.multicast_metadata_exists = multicast_op ~= nil
    return built
end

local function normalizeMappings(mappings)
    if type(mappings) ~= "table" then
        return nil
    end
    if mappings.engine_id ~= nil then
        return { mappings }
    end
    return mappings
end

local function registerHitWatcher(request_id, sender, mappings, timeout_seconds)
    local list = normalizeMappings(mappings)
    if type(request_id) ~= "string" or request_id == "" or not sender or type(list) ~= "table" then
        return
    end

    local helpers_by_engine_id = {}
    local helper_engine_ids = {}
    local slot_ids = {}
    for _, mapping in ipairs(list) do
        if type(mapping) == "table" and type(mapping.engine_id) == "string" and mapping.engine_id ~= "" then
            helpers_by_engine_id[mapping.engine_id] = mapping
            helper_engine_ids[#helper_engine_ids + 1] = mapping.engine_id
            slot_ids[#slot_ids + 1] = mapping.slot_id
        end
    end
    if #helper_engine_ids == 0 then
        return
    end

    pending_hits[request_id] = {
        sender = sender,
        helpers_by_engine_id = helpers_by_engine_id,
        helper_engine_ids = helper_engine_ids,
        slot_ids = slot_ids,
        expected_count = #helper_engine_ids,
        seen_by_engine_id = {},
        hit_count = 0,
    }

    local timeout = tonumber(timeout_seconds) or 30
    async:newUnsavableSimulationTimer(timeout, function()
        pending_hits[request_id] = nil
    end)
end

local function clearHitWatcher(request_id)
    if request_id then
        pending_hits[request_id] = nil
    end
end

local function payloadIdempotencyKey(kind, request_id, recipe_id, source_slot_id, helper_engine_id, projectile_id)
    local identity_kind = "helper"
    local identity_value = helper_engine_id
    if projectile_id ~= nil then
        identity_kind = "projectile"
        identity_value = projectile_id
    end
    return string.format(
        "%s:%s:%s:%s:%s:%s",
        tostring(kind),
        tostring(request_id),
        tostring(recipe_id),
        tostring(source_slot_id),
        identity_kind,
        tostring(identity_value)
    )
end

local function projectileIdFromRouteOrPayload(route, payload)
    if route and route.projectile_id ~= nil then
        return route.projectile_id
    end
    local data = payload or {}
    return data.projectile_id or data.projectileId or data.proj_id or data.projId
end

local function enqueueLaunchJobs(payload, built, helpers, opts)
    local launch_payload = payload or {}
    local options = opts or {}
    local sender = launch_payload.sender
    local actor = launch_payload.actor or launch_payload.sender
    if not actor then
        return { ok = false, error = "missing caster for dev launch" }
    end
    local launch_helpers = helpers or (built and built.helpers)
    if type(built) ~= "table" or type(launch_helpers) ~= "table" or #launch_helpers == 0 then
        return { ok = false, stage = "helper_records", error = "no helper records to launch" }
    end

    local jobs = {}
    local slot_ids = {}
    local helper_engine_ids = {}
    local effect_ids = {}
    for _, helper in ipairs(launch_helpers) do
        local launch_direction = launch_payload.direction
        if options.direction_by_slot_id and options.direction_by_slot_id[helper.slot_id] ~= nil then
            launch_direction = options.direction_by_slot_id[helper.slot_id]
        end
        local enqueue = orchestrator.enqueue({
            kind = orchestrator.DEV_LAUNCH_JOB_KIND,
            recipe_id = built.recipe_id,
            slot_id = helper.slot_id,
            helper_engine_id = helper.engine_id,
            payload = {
                actor = actor,
                start_pos = launch_payload.start_pos,
                direction = launch_direction,
                hit_object = launch_payload.hit_object,
            },
        })
        if not enqueue.ok then
            return {
                ok = false,
                stage = "enqueue",
                recipe_id = built.recipe_id,
                slot_id = helper.slot_id,
                helper_engine_id = helper.engine_id,
                error = enqueue.error,
                jobs = jobs,
            }
        end

        local effect_id = firstEffectId(helper)
        jobs[#jobs + 1] = {
            job_id = enqueue.job_id,
            job_kind = orchestrator.DEV_LAUNCH_JOB_KIND,
            status = enqueue.status,
            slot_id = helper.slot_id,
            helper_engine_id = helper.engine_id,
            effect_id = effect_id,
            launch_direction = launch_direction,
        }
        slot_ids[#slot_ids + 1] = helper.slot_id
        helper_engine_ids[#helper_engine_ids + 1] = helper.engine_id
        effect_ids[#effect_ids + 1] = effect_id
    end

    return {
        ok = true,
        sender = sender,
        request_id = launch_payload.request_id,
        recipe_id = built.recipe_id,
        slot_count = built.slot_count,
        helper_record_count = built.helper_record_count,
        helpers = launch_helpers,
        jobs = jobs,
        job_count = #jobs,
        slot_ids = slot_ids,
        helper_engine_ids = helper_engine_ids,
        effect_ids = effect_ids,
    }
end

function dev_launch.enqueueSimpleEmitterLaunch(payload)
    local enabled, disabled_reason = ensureDevLaunchEnabled()
    if not enabled then
        return { ok = false, error = disabled_reason }
    end

    local actor = payload and (payload.actor or payload.sender)
    if not actor then
        return { ok = false, error = "missing caster for dev launch" }
    end

    local built = dev_launch.buildSimpleEmitterPlan()
    if not built.ok then
        return built
    end

    local enqueued = enqueueLaunchJobs(payload, built)
    if not enqueued.ok then
        return enqueued
    end

    local job = enqueued.jobs and enqueued.jobs[1] or {}
    return {
        ok = true,
        sender = enqueued.sender,
        request_id = payload and payload.request_id or nil,
        recipe_id = built.recipe_id,
        slot_id = built.slot_id,
        helper_engine_id = built.helper_engine_id,
        effect_id = built.effect_id,
        slot_count = built.slot_count,
        helper_record_count = built.helper_record_count,
        job_id = job.job_id,
        job_kind = orchestrator.DEV_LAUNCH_JOB_KIND,
        status = job.status,
        helper = built.helper,
        helpers = built.helpers,
    }
end

function dev_launch.enqueueMulticastEmitterLaunch(payload)
    local enabled, disabled_reason = ensureDevLaunchEnabled()
    if not enabled then
        return { ok = false, error = disabled_reason }
    end

    local actor = payload and (payload.actor or payload.sender)
    if not actor then
        return { ok = false, error = "missing caster for dev launch" }
    end

    local built = dev_launch.buildMulticastEmitterPlan()
    if not built.ok then
        return built
    end

    return enqueueLaunchJobs(payload, built)
end

local function keysMatch(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
        return false
    end
    for i, key in ipairs(a) do
        if key ~= b[i] then
            return false
        end
    end
    return true
end

local function computeSpreadLaunchDirections(payload, built)
    local launch_payload = payload or {}
    local helpers = built and built.helpers or {}
    local computed = patterns.computeSpreadDirections(
        launch_payload.direction,
        #helpers,
        built and built.spread_op and built.spread_op.params or nil
    )
    if not computed.ok then
        return {
            ok = false,
            stage = "spread_directions",
            recipe_id = built and built.recipe_id or nil,
            error = computed.error,
        }
    end

    local repeat_computed = patterns.computeSpreadDirections(
        launch_payload.direction,
        #helpers,
        built and built.spread_op and built.spread_op.params or nil
    )
    local direction_by_slot_id = {}
    for index, helper in ipairs(helpers) do
        direction_by_slot_id[helper.slot_id] = computed.directions[index]
    end

    return {
        ok = true,
        direction_by_slot_id = direction_by_slot_id,
        spread_directions = computed.directions,
        spread_direction_keys = computed.direction_keys,
        spread_angle_offsets_degrees = computed.angle_offsets_degrees,
        spread_angle_degrees = computed.side_angle_degrees,
        spread_preset = computed.preset,
        spread_rotation_axis = computed.rotation_axis,
        spread_deterministic = repeat_computed.ok == true and keysMatch(computed.direction_keys, repeat_computed.direction_keys),
    }
end

function dev_launch.enqueueSpreadEmitterLaunch(payload)
    local enabled, disabled_reason = ensureDevLaunchEnabled()
    if not enabled then
        return { ok = false, error = disabled_reason }
    end

    local actor = payload and (payload.actor or payload.sender)
    if not actor then
        return { ok = false, error = "missing caster for dev Spread launch" }
    end

    local built = dev_launch.buildSpreadEmitterPlan()
    if not built.ok then
        return built
    end

    local directions = computeSpreadLaunchDirections(payload, built)
    if not directions.ok then
        return directions
    end

    local enqueued = enqueueLaunchJobs(payload, built, built.helpers, {
        direction_by_slot_id = directions.direction_by_slot_id,
    })
    if not enqueued.ok then
        return enqueued
    end

    enqueued.built = built
    enqueued.spread_metadata_exists = built.spread_metadata_exists
    enqueued.multicast_metadata_exists = built.multicast_metadata_exists
    enqueued.spread_preset = directions.spread_preset
    enqueued.spread_angle_degrees = directions.spread_angle_degrees
    enqueued.spread_rotation_axis = directions.spread_rotation_axis
    enqueued.spread_direction_keys = directions.spread_direction_keys
    enqueued.spread_angle_offsets_degrees = directions.spread_angle_offsets_degrees
    enqueued.spread_deterministic = directions.spread_deterministic
    return enqueued
end

local function computeBurstLaunchDirections(payload, built)
    local launch_payload = payload or {}
    local helpers = built and built.helpers or {}
    local computed = patterns.computeBurstDirections(
        launch_payload.direction,
        #helpers,
        built and built.burst_op and built.burst_op.params or nil
    )
    if not computed.ok then
        return {
            ok = false,
            stage = "burst_directions",
            recipe_id = built and built.recipe_id or nil,
            error = computed.error,
        }
    end

    local repeat_computed = patterns.computeBurstDirections(
        launch_payload.direction,
        #helpers,
        built and built.burst_op and built.burst_op.params or nil
    )
    local direction_by_slot_id = {}
    for index, helper in ipairs(helpers) do
        direction_by_slot_id[helper.slot_id] = computed.directions[index]
    end

    return {
        ok = true,
        direction_by_slot_id = direction_by_slot_id,
        burst_directions = computed.directions,
        burst_direction_keys = computed.direction_keys,
        burst_yaw_offsets_degrees = computed.yaw_offsets_degrees,
        burst_pitch_offsets_degrees = computed.pitch_offsets_degrees,
        burst_ring_angle_degrees = computed.ring_angle_degrees,
        burst_param_count = computed.burst_param_count,
        burst_distribution = computed.distribution,
        burst_deterministic = repeat_computed.ok == true and keysMatch(computed.direction_keys, repeat_computed.direction_keys),
    }
end

function dev_launch.enqueueBurstEmitterLaunch(payload)
    local enabled, disabled_reason = ensureDevLaunchEnabled()
    if not enabled then
        return { ok = false, error = disabled_reason }
    end

    local actor = payload and (payload.actor or payload.sender)
    if not actor then
        return { ok = false, error = "missing caster for dev Burst launch" }
    end

    local built = dev_launch.buildBurstEmitterPlan()
    if not built.ok then
        return built
    end

    local directions = computeBurstLaunchDirections(payload, built)
    if not directions.ok then
        return directions
    end

    local enqueued = enqueueLaunchJobs(payload, built, built.helpers, {
        direction_by_slot_id = directions.direction_by_slot_id,
    })
    if not enqueued.ok then
        return enqueued
    end

    enqueued.built = built
    enqueued.burst_metadata_exists = built.burst_metadata_exists
    enqueued.multicast_metadata_exists = built.multicast_metadata_exists
    enqueued.burst_param_count = directions.burst_param_count
    enqueued.burst_ring_angle_degrees = directions.burst_ring_angle_degrees
    enqueued.burst_distribution = directions.burst_distribution
    enqueued.burst_direction_keys = directions.burst_direction_keys
    enqueued.burst_yaw_offsets_degrees = directions.burst_yaw_offsets_degrees
    enqueued.burst_pitch_offsets_degrees = directions.burst_pitch_offsets_degrees
    enqueued.burst_deterministic = directions.burst_deterministic
    return enqueued
end

local function enqueueTimerPayloadJobs(payload, built, source_jobs)
    local launch_payload = payload or {}
    local actor = launch_payload.actor or launch_payload.sender
    if not actor then
        return { ok = false, error = "missing caster for dev timer payload" }
    end

    local source_job_by_slot_id = {}
    for _, job in ipairs(source_jobs or {}) do
        source_job_by_slot_id[job.slot_id] = job
    end

    local timer_jobs = {}
    local payload_slot_ids = {}
    local payload_helper_engine_ids = {}
    local payload_effect_ids = {}
    local timer_resolution_infos = {}
    local timer_payload_key_set = {}
    local timer_payload_idempotency_keys = {}
    local timer_duplicate_skipped_count = 0
    local wake_tick = orchestrator.currentTick() + built.timer_delay_ticks

    for _, source_helper in ipairs(built.source_helpers or {}) do
        local payload_helper = built.timer_payload_by_source_slot_id[source_helper.slot_id]
        if not payload_helper then
            return {
                ok = false,
                stage = "timer_payload",
                recipe_id = built.recipe_id,
                source_slot_id = source_helper.slot_id,
                error = "missing Timer payload helper for source slot",
            }
        end

        local resolution = computeTimerResolution(launch_payload, built, source_helper)
        if not resolution.ok then
            return resolution
        end

        local source_job = source_job_by_slot_id[source_helper.slot_id]
        local idempotency_key = payloadIdempotencyKey(
            "timer",
            launch_payload.request_id,
            built.recipe_id,
            source_helper.slot_id,
            source_helper.engine_id,
            source_job and source_job.projectile_id or nil
        )
        local should_enqueue_timer_payload = false
        if timer_payload_key_set[idempotency_key] then
            timer_duplicate_skipped_count = timer_duplicate_skipped_count + 1
            log.debug(string.format("duplicate Timer payload skipped key=%s", tostring(idempotency_key)))
        else
            timer_payload_key_set[idempotency_key] = true
            timer_payload_idempotency_keys[#timer_payload_idempotency_keys + 1] = idempotency_key
            should_enqueue_timer_payload = true
        end
        if should_enqueue_timer_payload then
        local enqueue = dev_runtime.enqueuePayloadLaunchJob(orchestrator, {
            job_kind = orchestrator.DEV_TIMER_PAYLOAD_JOB_KIND,
            recipe_id = built.recipe_id,
            payload_helper = payload_helper,
            source_slot_id = source_helper.slot_id,
            source_helper_engine_id = source_helper.engine_id,
            source_job = source_job,
            idempotency_key = idempotency_key,
            depth = 1,
            not_before_tick = wake_tick,
            payload = {
                actor = actor,
                start_pos = resolution.resolution_pos,
                direction = resolution.timer_direction,
                hit_object = resolution.resolution_hit_object,
                source_slot_id = source_helper.slot_id,
                timer_seconds = built.timer_seconds,
                timer_delay_ticks = built.timer_delay_ticks,
                timer_start_pos = resolution.timer_start_pos,
                timer_direction = resolution.timer_direction,
                timer_endpoint = resolution.timer_endpoint,
                timer_projectile_speed = resolution.timer_projectile_speed,
                timer_travel_distance = resolution.timer_travel_distance,
                resolution_pos = resolution.resolution_pos,
                resolution_kind = resolution.resolution_kind,
                timer_raycast_available = resolution.raycast_available,
                timer_raycast_note = resolution.raycast_note,
                source_projectile_id = source_job and source_job.projectile_id or nil,
                payload_idempotency_key = idempotency_key,
            },
        })
        if not enqueue.ok then
            return {
                ok = false,
                stage = "timer_enqueue",
                recipe_id = built.recipe_id,
                source_slot_id = source_helper.slot_id,
                payload_slot_id = payload_helper.slot_id,
                helper_engine_id = payload_helper.engine_id,
                error = enqueue.error,
                timer_jobs = timer_jobs,
            }
        end

        timer_jobs[#timer_jobs + 1] = {
            job_id = enqueue.job_id,
            job_kind = orchestrator.DEV_TIMER_PAYLOAD_JOB_KIND,
            status = enqueue.status,
            source_slot_id = source_helper.slot_id,
            slot_id = payload_helper.slot_id,
            helper_engine_id = payload_helper.engine_id,
            effect_id = firstEffectId(payload_helper),
            idempotency_key = idempotency_key,
            source_projectile_id = source_job and source_job.projectile_id or nil,
            not_before_tick = wake_tick,
            timer_seconds = built.timer_seconds,
            timer_delay_ticks = built.timer_delay_ticks,
            timer_start_pos = resolution.timer_start_pos,
            timer_direction = resolution.timer_direction,
            timer_endpoint = resolution.timer_endpoint,
            timer_projectile_speed = resolution.timer_projectile_speed,
            timer_travel_distance = resolution.timer_travel_distance,
            resolution_pos = resolution.resolution_pos,
            resolution_kind = resolution.resolution_kind,
            timer_raycast_available = resolution.raycast_available,
            timer_raycast_note = resolution.raycast_note,
        }
        timer_resolution_infos[#timer_resolution_infos + 1] = {
            source_slot_id = source_helper.slot_id,
            payload_slot_id = payload_helper.slot_id,
            timer_start_pos = resolution.timer_start_pos,
            timer_direction = resolution.timer_direction,
            timer_endpoint = resolution.timer_endpoint,
            timer_projectile_speed = resolution.timer_projectile_speed,
            timer_travel_distance = resolution.timer_travel_distance,
            resolution_pos = resolution.resolution_pos,
            resolution_kind = resolution.resolution_kind,
            timer_raycast_available = resolution.raycast_available,
            timer_raycast_note = resolution.raycast_note,
            idempotency_key = idempotency_key,
            source_projectile_id = source_job and source_job.projectile_id or nil,
        }
        payload_slot_ids[#payload_slot_ids + 1] = payload_helper.slot_id
        payload_helper_engine_ids[#payload_helper_engine_ids + 1] = payload_helper.engine_id
        payload_effect_ids[#payload_effect_ids + 1] = firstEffectId(payload_helper)
        end
    end

    local first_resolution = timer_resolution_infos[1] or {}
    return {
        ok = true,
        recipe_id = built.recipe_id,
        timer_jobs = timer_jobs,
        timer_job_count = #timer_jobs,
        payload_slot_ids = payload_slot_ids,
        payload_helper_engine_ids = payload_helper_engine_ids,
        payload_effect_ids = payload_effect_ids,
        timer_resolution_infos = timer_resolution_infos,
        wake_tick = wake_tick,
        timer_seconds = built.timer_seconds,
        timer_delay_ticks = built.timer_delay_ticks,
        timer_projectile_speed = first_resolution.timer_projectile_speed or DEFAULT_TIMER_PROJECTILE_SPEED,
        timer_payload_idempotency_keys = timer_payload_idempotency_keys,
        timer_duplicate_skipped_count = timer_duplicate_skipped_count,
    }
end

local function collectJobResults(enqueued)
    local updated_jobs = {}
    local complete_count = 0
    local accepted_count = 0
    local first_error = nil

    for i, queued in ipairs(enqueued.jobs or {}) do
        local job = orchestrator.getJob(queued.job_id)
        local job_status = job and job.status or "missing"
        local launch_accepted = job and job.launch_accepted == true
        if job_status == "complete" then
            complete_count = complete_count + 1
        elseif not first_error then
            first_error = job and job.error or "dev launch job was not processed"
        end
        if launch_accepted then
            accepted_count = accepted_count + 1
        end

        local job_payload = job and job.payload or nil
        local timer_raycast_available = queued.timer_raycast_available
        if timer_raycast_available == nil and job_payload then
            timer_raycast_available = job_payload.timer_raycast_available
        end

        updated_jobs[i] = {
            job_id = queued.job_id,
            job_kind = queued.job_kind,
            job_status = job_status,
            slot_id = queued.slot_id,
            source_slot_id = queued.source_slot_id or (job and job.timer_source_slot_id or nil),
            helper_engine_id = queued.helper_engine_id,
            effect_id = queued.effect_id,
            not_before_tick = queued.not_before_tick or (job and job.not_before_tick or nil),
            source_job_id = job and job.source_job_id or nil,
            parent_job_id = job and job.parent_job_id or nil,
            idempotency_key = job and job.idempotency_key or queued.idempotency_key,
            source_projectile_id = queued.source_projectile_id or (job_payload and job_payload.source_projectile_id or nil),
            launch_accepted = launch_accepted,
            launch_returned_projectile = job and job.launch_returned_projectile == true,
            projectile_id = job and job.projectile_id or nil,
            projectile_id_source = job and job.projectile_id_source or nil,
            projectile_registered = job and job.projectile_registered == true,
            launch_start_pos = job and job.launch_start_pos or nil,
            launch_direction = job and job.launch_direction or queued.launch_direction,
            launch_user_data_present = job and type(job.launch_user_data) == "table" or false,
            launch_user_data_schema = job and job.launch_user_data and job.launch_user_data.schema or nil,
            launch_user_data_runtime = job and job.launch_user_data and job.launch_user_data.runtime or nil,
            launch_user_data_recipe_id = job and job.launch_user_data and job.launch_user_data.recipe_id or nil,
            launch_user_data_slot_id = job and job.launch_user_data and job.launch_user_data.slot_id or nil,
            launch_user_data_helper_engine_id = job and job.launch_user_data and job.launch_user_data.helper_engine_id or nil,
            timer_start_pos = queued.timer_start_pos or (job_payload and job_payload.timer_start_pos or nil),
            timer_direction = queued.timer_direction or (job_payload and job_payload.timer_direction or nil),
            timer_endpoint = queued.timer_endpoint or (job_payload and job_payload.timer_endpoint or nil),
            timer_projectile_speed = queued.timer_projectile_speed or (job_payload and job_payload.timer_projectile_speed or nil),
            timer_travel_distance = queued.timer_travel_distance or (job_payload and job_payload.timer_travel_distance or nil),
            resolution_pos = queued.resolution_pos or (job_payload and job_payload.resolution_pos or nil),
            resolution_kind = queued.resolution_kind or (job_payload and job_payload.resolution_kind or nil),
            timer_raycast_available = timer_raycast_available,
            timer_raycast_note = queued.timer_raycast_note or (job_payload and job_payload.timer_raycast_note or nil),
            source_hit_pos = queued.source_hit_pos or (job and job.trigger_source_hit_pos or (job_payload and job_payload.source_hit_pos or nil)),
            source_hit_normal = queued.source_hit_normal or (job and job.trigger_source_hit_normal or (job_payload and job_payload.source_hit_normal or nil)),
            source_hit_target_id = queued.source_hit_target_id or (job_payload and job_payload.source_hit_target_id or nil),
            error = job and job.error or nil,
        }
    end

    return {
        jobs = updated_jobs,
        complete_count = complete_count,
        accepted_count = accepted_count,
        first_error = first_error,
    }
end

local function collectTimerJobResults(timer_jobs)
    local wrapped = { jobs = timer_jobs or {} }
    return collectJobResults(wrapped)
end

local function collectTriggerJobResults(trigger_jobs)
    local wrapped = { jobs = trigger_jobs or {} }
    return collectJobResults(wrapped)
end

local function combinedMappings(a, b)
    local out = {}
    for _, mapping in ipairs(a or {}) do
        out[#out + 1] = mapping
    end
    for _, mapping in ipairs(b or {}) do
        out[#out + 1] = mapping
    end
    return out
end

local function mapHelpersByEngineId(helpers)
    local out = {}
    for _, helper in ipairs(helpers or {}) do
        if helper.engine_id then
            out[helper.engine_id] = helper
        end
    end
    return out
end

local function clearTriggerRun(request_id)
    if request_id then
        pending_trigger_runs[request_id] = nil
    end
end

local completeTimerRun
local completeTriggerPayloadJob

function dev_launch.runSimpleEmitterLaunch(payload)
    local enqueued = dev_launch.enqueueSimpleEmitterLaunch(payload)
    if not enqueued.ok then
        return enqueued
    end

    registerHitWatcher(payload and payload.request_id, payload and payload.sender, enqueued.helper, payload and payload.timeout_seconds)

    local tick = orchestrator.tick({ max_jobs_per_tick = 1 })
    local job = orchestrator.getJob(enqueued.job_id)
    local job_status = job and job.status or "missing"
    if job_status ~= "complete" then
        clearHitWatcher(payload and payload.request_id)
        return {
            ok = false,
            stage = "tick",
            recipe_id = enqueued.recipe_id,
            slot_id = enqueued.slot_id,
            helper_engine_id = enqueued.helper_engine_id,
            effect_id = enqueued.effect_id,
            slot_count = enqueued.slot_count,
            helper_record_count = enqueued.helper_record_count,
            job_id = enqueued.job_id,
            job_kind = enqueued.job_kind,
            job_status = job_status,
            tick_processed_count = tick.processed_count,
            error = job and job.error or "dev launch job was not processed",
        }
    end

    return {
        ok = true,
        recipe_id = enqueued.recipe_id,
        slot_id = enqueued.slot_id,
        helper_engine_id = enqueued.helper_engine_id,
        effect_id = enqueued.effect_id,
        slot_count = enqueued.slot_count,
        helper_record_count = enqueued.helper_record_count,
        job_id = enqueued.job_id,
        job_kind = enqueued.job_kind,
        job_status = job_status,
        tick_processed_count = tick.processed_count,
        launch_accepted = job and job.launch_accepted == true,
        launch_returned_projectile = job and job.launch_returned_projectile == true,
        projectile_id = job and job.projectile_id or nil,
        projectile_id_source = job and job.projectile_id_source or nil,
        projectile_registered = job and job.projectile_registered == true,
        launch_user_data_present = job and type(job.launch_user_data) == "table" or false,
        launch_user_data_schema = job and job.launch_user_data and job.launch_user_data.schema or nil,
        launch_user_data_runtime = job and job.launch_user_data and job.launch_user_data.runtime or nil,
        launch_user_data_recipe_id = job and job.launch_user_data and job.launch_user_data.recipe_id or nil,
        launch_user_data_slot_id = job and job.launch_user_data and job.launch_user_data.slot_id or nil,
        launch_user_data_helper_engine_id = job and job.launch_user_data and job.launch_user_data.helper_engine_id or nil,
    }
end

function dev_launch.runMulticastEmitterLaunch(payload)
    local enqueued = dev_launch.enqueueMulticastEmitterLaunch(payload)
    if not enqueued.ok then
        return enqueued
    end

    registerHitWatcher(payload and payload.request_id, payload and payload.sender, enqueued.helpers, payload and payload.timeout_seconds)

    local tick = orchestrator.tick({ max_jobs_per_tick = enqueued.job_count })
    local collected = collectJobResults(enqueued)
    local all_complete = collected.complete_count == enqueued.job_count
    local all_accepted = collected.accepted_count == enqueued.job_count
    if not all_complete or not all_accepted then
        clearHitWatcher(payload and payload.request_id)
        return {
            ok = false,
            stage = "tick",
            recipe_id = enqueued.recipe_id,
            slot_count = enqueued.slot_count,
            helper_record_count = enqueued.helper_record_count,
            job_count = enqueued.job_count,
            jobs = collected.jobs,
            slot_ids = enqueued.slot_ids,
            helper_engine_ids = enqueued.helper_engine_ids,
            effect_ids = enqueued.effect_ids,
            tick_processed_count = tick.processed_count,
            launch_accepted_count = collected.accepted_count,
            error = collected.first_error or "one or more dev multicast launch jobs failed",
        }
    end

    return {
        ok = true,
        recipe_id = enqueued.recipe_id,
        slot_count = enqueued.slot_count,
        helper_record_count = enqueued.helper_record_count,
        job_count = enqueued.job_count,
        jobs = collected.jobs,
        slot_ids = enqueued.slot_ids,
        helper_engine_ids = enqueued.helper_engine_ids,
        effect_ids = enqueued.effect_ids,
        tick_processed_count = tick.processed_count,
        launch_accepted_count = collected.accepted_count,
        multicast_count = enqueued.job_count,
    }
end

function dev_launch.runSpreadEmitterLaunch(payload)
    local enqueued = dev_launch.enqueueSpreadEmitterLaunch(payload)
    if not enqueued.ok then
        return enqueued
    end

    registerHitWatcher(payload and payload.request_id, payload and payload.sender, enqueued.helpers, payload and payload.timeout_seconds)

    local tick = orchestrator.tick({ max_jobs_per_tick = enqueued.job_count })
    local collected = collectJobResults(enqueued)
    local all_complete = collected.complete_count == enqueued.job_count
    local all_accepted = collected.accepted_count == enqueued.job_count
    if not all_complete or not all_accepted then
        clearHitWatcher(payload and payload.request_id)
        return {
            ok = false,
            stage = "tick",
            recipe_id = enqueued.recipe_id,
            slot_count = enqueued.slot_count,
            helper_record_count = enqueued.helper_record_count,
            job_count = enqueued.job_count,
            jobs = collected.jobs,
            slot_ids = enqueued.slot_ids,
            helper_engine_ids = enqueued.helper_engine_ids,
            effect_ids = enqueued.effect_ids,
            spread_metadata_exists = enqueued.spread_metadata_exists,
            multicast_metadata_exists = enqueued.multicast_metadata_exists,
            spread_preset = enqueued.spread_preset,
            spread_angle_degrees = enqueued.spread_angle_degrees,
            spread_rotation_axis = enqueued.spread_rotation_axis,
            spread_direction_keys = enqueued.spread_direction_keys,
            spread_angle_offsets_degrees = enqueued.spread_angle_offsets_degrees,
            spread_direction_count = #(enqueued.spread_direction_keys or {}),
            spread_deterministic = enqueued.spread_deterministic,
            tick_processed_count = tick.processed_count,
            launch_accepted_count = collected.accepted_count,
            error = collected.first_error or "one or more dev Spread launch jobs failed",
        }
    end

    return {
        ok = true,
        recipe_id = enqueued.recipe_id,
        slot_count = enqueued.slot_count,
        helper_record_count = enqueued.helper_record_count,
        job_count = enqueued.job_count,
        jobs = collected.jobs,
        slot_ids = enqueued.slot_ids,
        helper_engine_ids = enqueued.helper_engine_ids,
        effect_ids = enqueued.effect_ids,
        spread_metadata_exists = enqueued.spread_metadata_exists,
        multicast_metadata_exists = enqueued.multicast_metadata_exists,
        spread_preset = enqueued.spread_preset,
        spread_angle_degrees = enqueued.spread_angle_degrees,
        spread_rotation_axis = enqueued.spread_rotation_axis,
        spread_direction_keys = enqueued.spread_direction_keys,
        spread_angle_offsets_degrees = enqueued.spread_angle_offsets_degrees,
        spread_direction_count = #(enqueued.spread_direction_keys or {}),
        spread_deterministic = enqueued.spread_deterministic,
        tick_processed_count = tick.processed_count,
        launch_accepted_count = collected.accepted_count,
        multicast_count = enqueued.job_count,
        trigger_job_count = 0,
        timer_job_count = 0,
        chain_job_count = 0,
    }
end

function dev_launch.runBurstEmitterLaunch(payload)
    local enqueued = dev_launch.enqueueBurstEmitterLaunch(payload)
    if not enqueued.ok then
        return enqueued
    end

    registerHitWatcher(payload and payload.request_id, payload and payload.sender, enqueued.helpers, payload and payload.timeout_seconds)

    local tick = orchestrator.tick({ max_jobs_per_tick = enqueued.job_count })
    local collected = collectJobResults(enqueued)
    local all_complete = collected.complete_count == enqueued.job_count
    local all_accepted = collected.accepted_count == enqueued.job_count
    if not all_complete or not all_accepted then
        clearHitWatcher(payload and payload.request_id)
        return {
            ok = false,
            stage = "tick",
            recipe_id = enqueued.recipe_id,
            slot_count = enqueued.slot_count,
            helper_record_count = enqueued.helper_record_count,
            job_count = enqueued.job_count,
            jobs = collected.jobs,
            slot_ids = enqueued.slot_ids,
            helper_engine_ids = enqueued.helper_engine_ids,
            effect_ids = enqueued.effect_ids,
            burst_metadata_exists = enqueued.burst_metadata_exists,
            multicast_metadata_exists = enqueued.multicast_metadata_exists,
            burst_param_count = enqueued.burst_param_count,
            burst_ring_angle_degrees = enqueued.burst_ring_angle_degrees,
            burst_distribution = enqueued.burst_distribution,
            burst_direction_keys = enqueued.burst_direction_keys,
            burst_yaw_offsets_degrees = enqueued.burst_yaw_offsets_degrees,
            burst_pitch_offsets_degrees = enqueued.burst_pitch_offsets_degrees,
            burst_direction_count = #(enqueued.burst_direction_keys or {}),
            burst_deterministic = enqueued.burst_deterministic,
            tick_processed_count = tick.processed_count,
            launch_accepted_count = collected.accepted_count,
            error = collected.first_error or "one or more dev Burst launch jobs failed",
        }
    end

    return {
        ok = true,
        recipe_id = enqueued.recipe_id,
        slot_count = enqueued.slot_count,
        helper_record_count = enqueued.helper_record_count,
        job_count = enqueued.job_count,
        jobs = collected.jobs,
        slot_ids = enqueued.slot_ids,
        helper_engine_ids = enqueued.helper_engine_ids,
        effect_ids = enqueued.effect_ids,
        burst_metadata_exists = enqueued.burst_metadata_exists,
        multicast_metadata_exists = enqueued.multicast_metadata_exists,
        burst_param_count = enqueued.burst_param_count,
        burst_ring_angle_degrees = enqueued.burst_ring_angle_degrees,
        burst_distribution = enqueued.burst_distribution,
        burst_direction_keys = enqueued.burst_direction_keys,
        burst_yaw_offsets_degrees = enqueued.burst_yaw_offsets_degrees,
        burst_pitch_offsets_degrees = enqueued.burst_pitch_offsets_degrees,
        burst_direction_count = #(enqueued.burst_direction_keys or {}),
        burst_deterministic = enqueued.burst_deterministic,
        tick_processed_count = tick.processed_count,
        launch_accepted_count = collected.accepted_count,
        multicast_count = enqueued.job_count,
        trigger_job_count = 0,
        timer_job_count = 0,
        chain_job_count = 0,
    }
end

local function helperBySlotId(helpers)
    local out = {}
    for _, helper in ipairs(helpers or {}) do
        if helper.slot_id then
            out[helper.slot_id] = helper
        end
    end
    return out
end

local function enqueueStressPayloadJob(job_kind, built, helper, source_helper, payload_fields, opts)
    local options = opts or {}
    local payload = payload_fields or {}
    return dev_runtime.enqueuePayloadLaunchJob(orchestrator, {
        job_kind = job_kind,
        recipe_id = built.recipe_id,
        payload_helper = helper,
        source_slot_id = source_helper and source_helper.slot_id or nil,
        source_helper_engine_id = source_helper and source_helper.engine_id or nil,
        source_job_id = options.source_job_id,
        parent_job_id = options.parent_job_id,
        not_before_tick = options.not_before_tick,
        depth = options.depth,
        idempotency_key = options.idempotency_key,
        payload = payload,
    })
end

function dev_launch.runPerformanceStressLaunch(payload)
    local started_tick = orchestrator.currentTick()
    local enabled, disabled_reason = ensureDevLaunchEnabled()
    if not enabled then
        return { ok = false, error = disabled_reason }
    end

    local launch_payload = payload or {}
    local actor = launch_payload.actor or launch_payload.sender
    if not actor then
        return { ok = false, error = "missing caster for performance stress launch" }
    end

    local built = dev_launch.buildPerformanceStressPlan()
    if not built.ok then
        return built
    end

    local source_helper = built.source_helpers[1]
    local source_enqueued = enqueueLaunchJobs(launch_payload, built, { source_helper })
    if not source_enqueued.ok then
        return source_enqueued
    end

    local source_tick = orchestrator.tick({ max_jobs_per_tick = source_enqueued.job_count })
    local source_collected = collectJobResults(source_enqueued)
    if source_collected.complete_count ~= source_enqueued.job_count
        or source_collected.accepted_count ~= source_enqueued.job_count then
        return {
            ok = false,
            stage = "performance_source_launch",
            recipe_id = built.recipe_id,
            source_job_count = source_enqueued.job_count,
            source_jobs = source_collected.jobs,
            error = source_collected.first_error or "performance source launch failed",
        }
    end

    local resolution = computeTimerResolution(launch_payload, built, source_helper)
    if not resolution.ok then
        return resolution
    end

    local burst = patterns.computeBurstDirections(
        launch_payload.direction,
        #built.timer_payload_helpers,
        built.burst_op and built.burst_op.params or nil
    )
    if not burst.ok then
        return {
            ok = false,
            stage = "performance_burst_directions",
            recipe_id = built.recipe_id,
            error = burst.error,
        }
    end

    local timer_direction_by_slot_id = {}
    for index, helper in ipairs(built.timer_payload_helpers) do
        timer_direction_by_slot_id[helper.slot_id] = burst.directions[index] or resolution.timer_direction
    end

    local source_job = source_collected.jobs and source_collected.jobs[1] or nil
    local timer_due_tick = orchestrator.currentTick() + built.timer_delay_ticks
    local timer_jobs = {}
    for _, helper in ipairs(built.timer_payload_helpers) do
        local timer_direction = timer_direction_by_slot_id[helper.slot_id] or resolution.timer_direction
        local enqueue = enqueueStressPayloadJob(orchestrator.DEV_TIMER_PAYLOAD_JOB_KIND, built, helper, source_helper, {
            actor = actor,
            start_pos = resolution.timer_start_pos,
            direction = timer_direction,
            hit_object = resolution.resolution_hit_object or launch_payload.hit_object,
            source_slot_id = source_helper.slot_id,
            resolution_pos = resolution.resolution_pos,
            resolution_kind = resolution.resolution_kind,
            timer_seconds = built.timer_seconds,
            timer_delay_ticks = built.timer_delay_ticks,
            timer_start_pos = resolution.timer_start_pos,
            timer_direction = timer_direction,
            timer_endpoint = resolution.timer_endpoint,
            timer_projectile_speed = resolution.timer_projectile_speed,
            timer_travel_distance = resolution.timer_travel_distance,
        }, {
            source_job_id = source_job and source_job.job_id,
            parent_job_id = source_job and source_job.job_id,
            not_before_tick = timer_due_tick,
            depth = 1,
            idempotency_key = string.format("%s:perf_timer:%s", tostring(launch_payload.request_id or built.recipe_id), tostring(helper.slot_id)),
        })
        if not enqueue.ok then
            return {
                ok = false,
                stage = "performance_timer_enqueue",
                recipe_id = built.recipe_id,
                slot_id = helper.slot_id,
                error = enqueue.error,
                timer_jobs = timer_jobs,
            }
        end
        timer_jobs[#timer_jobs + 1] = enqueue
    end

    local timer_pre_tick = orchestrator.tick({ max_jobs_per_tick = #timer_jobs })
    local timer_tick = nil
    for _ = 1, built.timer_delay_ticks + 2 do
        local collected = collectTimerJobResults(timer_jobs)
        if collected.complete_count == #timer_jobs then
            break
        end
        timer_tick = orchestrator.tick({ max_jobs_per_tick = #timer_jobs })
    end
    local timer_collected = collectTimerJobResults(timer_jobs)
    if timer_collected.complete_count ~= #timer_jobs or timer_collected.accepted_count ~= #timer_jobs then
        return {
            ok = false,
            stage = "performance_timer_launch",
            recipe_id = built.recipe_id,
            timer_payload_job_count = #timer_jobs,
            timer_jobs = timer_collected.jobs,
            timer_pre_tick = timer_pre_tick,
            timer_tick = timer_tick,
            error = timer_collected.first_error or "performance timer payload launch failed",
        }
    end

    local timer_helper_by_slot_id = helperBySlotId(built.timer_payload_helpers)
    local timer_job_by_slot_id = {}
    for _, job in ipairs(timer_collected.jobs or {}) do
        timer_job_by_slot_id[job.slot_id] = job
    end

    local trigger_jobs = {}
    for _, helper in ipairs(built.trigger_payload_helpers) do
        local trigger_source_slot_id = helper.trigger_source_slot_id
        local trigger_source_helper = timer_helper_by_slot_id[trigger_source_slot_id]
        local trigger_source_job = timer_job_by_slot_id[trigger_source_slot_id]
        local direction = timer_direction_by_slot_id[trigger_source_slot_id] or resolution.timer_direction
        local enqueue = enqueueStressPayloadJob(orchestrator.DEV_TRIGGER_PAYLOAD_JOB_KIND, built, helper, trigger_source_helper, {
            actor = actor,
            start_pos = resolution.resolution_pos,
            direction = direction,
            hit_object = resolution.resolution_hit_object or launch_payload.hit_object,
            source_slot_id = trigger_source_slot_id,
            source_hit_pos = resolution.resolution_pos,
            source_hit_target_id = resolution.resolution_hit_object and resolution.resolution_hit_object.recordId or nil,
        }, {
            source_job_id = trigger_source_job and trigger_source_job.job_id,
            parent_job_id = trigger_source_job and trigger_source_job.job_id,
            depth = 2,
            idempotency_key = string.format("%s:perf_trigger:%s", tostring(launch_payload.request_id or built.recipe_id), tostring(helper.slot_id)),
        })
        if not enqueue.ok then
            return {
                ok = false,
                stage = "performance_trigger_enqueue",
                recipe_id = built.recipe_id,
                slot_id = helper.slot_id,
                error = enqueue.error,
                trigger_jobs = trigger_jobs,
            }
        end
        trigger_jobs[#trigger_jobs + 1] = enqueue
    end

    local trigger_tick = orchestrator.tick({ max_jobs_per_tick = #trigger_jobs })
    local trigger_collected = collectTriggerJobResults(trigger_jobs)
    local all_trigger_complete = trigger_collected.complete_count == #trigger_jobs
    local all_trigger_accepted = trigger_collected.accepted_count == #trigger_jobs
    local total_job_count = source_enqueued.job_count + #timer_jobs + #trigger_jobs
    local accepted_count = source_collected.accepted_count + timer_collected.accepted_count + trigger_collected.accepted_count

    return {
        ok = all_trigger_complete and all_trigger_accepted,
        stage = all_trigger_complete and all_trigger_accepted and nil or "performance_trigger_launch",
        recipe_id = built.recipe_id,
        slot_count = built.slot_count,
        helper_record_count = built.helper_record_count,
        source_job_count = source_enqueued.job_count,
        timer_payload_job_count = #timer_jobs,
        trigger_payload_job_count = #trigger_jobs,
        total_job_count = total_job_count,
        launch_accepted_count = accepted_count,
        source_jobs = source_collected.jobs,
        timer_jobs = timer_collected.jobs,
        trigger_jobs = trigger_collected.jobs,
        timer_seconds = built.timer_seconds,
        timer_delay_ticks = built.timer_delay_ticks,
        timer_due_tick = timer_due_tick,
        timer_pre_tick = timer_pre_tick,
        timer_tick = timer_tick,
        source_tick = source_tick,
        trigger_tick = trigger_tick,
        burst_metadata_exists = built.burst_metadata_exists,
        multicast_metadata_exists = built.multicast_metadata_exists,
        burst_param_count = burst.burst_param_count,
        burst_ring_angle_degrees = burst.ring_angle_degrees,
        burst_direction_count = #(burst.direction_keys or {}),
        burst_direction_keys = burst.direction_keys,
        timer_resolution_kind = resolution.resolution_kind,
        timer_projectile_speed = resolution.timer_projectile_speed,
        timer_travel_distance = resolution.timer_travel_distance,
        queue_drained = orchestrator.queueLength() == 0,
        performance_shape = "Fireball Timer 1s -> Multicast 8 Burst Frostball Trigger -> Multicast 2 Fire Damage 10pt/10ft",
        fast_forward_semantics = "logical_orchestrator_tick_fast_forward",
        performance_stress_only = true,
        real_delay_test = false,
        elapsed_ticks = orchestrator.currentTick() - started_tick,
        error = (all_trigger_complete and all_trigger_accepted) and nil or (trigger_collected.first_error or "performance trigger payload launch failed"),
    }
end

function dev_launch.enqueueTriggerEmitterLaunch(payload)
    local enabled, disabled_reason = ensureDevLaunchEnabled()
    if not enabled then
        return { ok = false, error = disabled_reason }
    end

    local actor = payload and (payload.actor or payload.sender)
    if not actor then
        return { ok = false, error = "missing caster for dev trigger launch" }
    end

    local built = dev_launch.buildTriggerEmitterPlan(payload and payload.multicast == true)
    if not built.ok then
        return built
    end

    local source_enqueued = enqueueLaunchJobs(payload, built, built.source_helpers)
    if not source_enqueued.ok then
        return source_enqueued
    end

    source_enqueued.built = built
    return source_enqueued
end

function dev_launch.runTriggerEmitterLaunch(payload)
    local request_id = payload and payload.request_id
    local sender = payload and payload.sender
    if type(request_id) ~= "string" or request_id == "" or not sender then
        return { ok = false, error = "missing sender/request_id for dev trigger launch" }
    end

    local enqueued = dev_launch.enqueueTriggerEmitterLaunch(payload)
    if not enqueued.ok then
        return enqueued
    end

    local built = enqueued.built
    registerHitWatcher(request_id, sender, combinedMappings(built.source_helpers, built.trigger_payload_helpers), payload and payload.timeout_seconds)

    pending_trigger_runs[request_id] = {
        sender = sender,
        actor = payload and (payload.actor or payload.sender) or nil,
        recipe_id = built.recipe_id,
        direction = payload and payload.direction or nil,
        source_helpers_by_engine_id = mapHelpersByEngineId(built.source_helpers),
        payload_helpers_by_engine_id = mapHelpersByEngineId(built.trigger_payload_helpers),
        payload_by_source_slot_id = built.trigger_payload_by_source_slot_id,
        source_job_by_slot_id = {},
        trigger_jobs = {},
        triggered_source_slot_set = {},
        triggered_source_key_set = {},
        payload_hit_slot_set = {},
        source_hit_count = 0,
        payload_hit_count = 0,
        trigger_payload_job_count = 0,
        duplicate_trigger_skipped_count = 0,
        payload_launch_accepted_count = 0,
        expected_source_count = #built.source_helpers,
        expected_payload_count = #built.trigger_payload_helpers,
    }

    async:newUnsavableSimulationTimer(tonumber(payload and payload.timeout_seconds) or 30, function()
        clearTriggerRun(request_id)
    end)

    local source_tick = orchestrator.tick({ max_jobs_per_tick = enqueued.job_count })
    local source_collected = collectJobResults(enqueued)
    local sources_complete = source_collected.complete_count == enqueued.job_count
    local sources_accepted = source_collected.accepted_count == enqueued.job_count
    if not sources_complete or not sources_accepted then
        clearHitWatcher(request_id)
        clearTriggerRun(request_id)
        return {
            ok = false,
            stage = "source_tick",
            recipe_id = enqueued.recipe_id,
            slot_count = built.slot_count,
            helper_record_count = built.helper_record_count,
            source_job_count = enqueued.job_count,
            source_jobs = source_collected.jobs,
            source_launch_accepted_count = source_collected.accepted_count,
            tick_processed_count = source_tick.processed_count,
            error = source_collected.first_error or "one or more dev trigger source launch jobs failed",
        }
    end

    local run = pending_trigger_runs[request_id]
    if run then
        for _, job in ipairs(source_collected.jobs or {}) do
            run.source_job_by_slot_id[job.slot_id] = job
        end
    end

    return {
        ok = true,
        recipe_id = built.recipe_id,
        slot_count = built.slot_count,
        helper_record_count = built.helper_record_count,
        source_job_count = enqueued.job_count,
        source_jobs = source_collected.jobs,
        source_slot_ids = enqueued.slot_ids,
        source_helper_engine_ids = enqueued.helper_engine_ids,
        source_effect_ids = enqueued.effect_ids,
        source_launch_accepted_count = source_collected.accepted_count,
        trigger_payload_job_count = 0,
        trigger_payload_slot_ids = (function()
            local ids = {}
            for _, helper in ipairs(built.trigger_payload_helpers or {}) do
                ids[#ids + 1] = helper.slot_id
            end
            return ids
        end)(),
        trigger_payload_helper_engine_ids = (function()
            local ids = {}
            for _, helper in ipairs(built.trigger_payload_helpers or {}) do
                ids[#ids + 1] = helper.engine_id
            end
            return ids
        end)(),
        trigger_payload_effect_ids = (function()
            local ids = {}
            for _, helper in ipairs(built.trigger_payload_helpers or {}) do
                ids[#ids + 1] = firstEffectId(helper)
            end
            return ids
        end)(),
        expected_trigger_payload_count = #built.trigger_payload_helpers,
        multicast = payload and payload.multicast == true,
        trigger_metadata_exists = true,
        tick_processed_count = source_tick.processed_count,
        timer_job_count = 0,
        chain_job_count = 0,
    }
end

function dev_launch.enqueueTimerEmitterLaunch(payload)
    local enabled, disabled_reason = ensureDevLaunchEnabled()
    if not enabled then
        return { ok = false, error = disabled_reason }
    end

    local actor = payload and (payload.actor or payload.sender)
    if not actor then
        return { ok = false, error = "missing caster for dev timer launch" }
    end

    local built = dev_launch.buildTimerEmitterPlan()
    if not built.ok then
        return built
    end

    local source_enqueued = enqueueLaunchJobs(payload, built, built.source_helpers)
    if not source_enqueued.ok then
        return source_enqueued
    end

    source_enqueued.built = built
    return source_enqueued
end

function dev_launch.runTimerEmitterLaunch(payload)
    local request_id = payload and payload.request_id
    local sender = payload and payload.sender
    if type(request_id) ~= "string" or request_id == "" or not sender then
        return { ok = false, error = "missing sender/request_id for dev timer launch" }
    end

    local enqueued = dev_launch.enqueueTimerEmitterLaunch(payload)
    if not enqueued.ok then
        return enqueued
    end

    local built = enqueued.built
    registerHitWatcher(request_id, sender, built.timer_payload_helpers, payload and payload.timeout_seconds)

    local source_tick = orchestrator.tick({ max_jobs_per_tick = enqueued.job_count })
    local source_collected = collectJobResults(enqueued)
    local sources_complete = source_collected.complete_count == enqueued.job_count
    local sources_accepted = source_collected.accepted_count == enqueued.job_count
    if not sources_complete or not sources_accepted then
        clearHitWatcher(request_id)
        return {
            ok = false,
            stage = "source_tick",
            recipe_id = enqueued.recipe_id,
            slot_count = built.slot_count,
            helper_record_count = built.helper_record_count,
            source_job_count = enqueued.job_count,
            source_jobs = source_collected.jobs,
            source_launch_accepted_count = source_collected.accepted_count,
            tick_processed_count = source_tick.processed_count,
            error = source_collected.first_error or "one or more dev timer source launch jobs failed",
        }
    end

    local timer_enqueued = enqueueTimerPayloadJobs(payload, built, source_collected.jobs)
    if not timer_enqueued.ok then
        clearHitWatcher(request_id)
        return timer_enqueued
    end

    local pre_delay_tick = orchestrator.tick({ max_jobs_per_tick = timer_enqueued.timer_job_count })
    local pre_delay_collected = collectTimerJobResults(timer_enqueued.timer_jobs)
    local timer_jobs_waiting = pre_delay_collected.complete_count == 0 and pre_delay_collected.accepted_count == 0
    if not timer_jobs_waiting then
        clearHitWatcher(request_id)
        return {
            ok = false,
            stage = "timer_pre_delay",
            recipe_id = enqueued.recipe_id,
            timer_payload_job_count = timer_enqueued.timer_job_count,
            timer_jobs = pre_delay_collected.jobs,
            pre_delay_tick_processed_count = pre_delay_tick.processed_count,
            error = "Timer payload jobs completed before delay elapsed",
        }
    end

    pending_timer_runs[request_id] = {
        sender = sender,
        recipe_id = built.recipe_id,
        timer_jobs = timer_enqueued.timer_jobs,
        timer_job_count = timer_enqueued.timer_job_count,
        payload_slot_ids = timer_enqueued.payload_slot_ids,
        payload_helper_engine_ids = timer_enqueued.payload_helper_engine_ids,
        payload_effect_ids = timer_enqueued.payload_effect_ids,
        timer_resolution_infos = timer_enqueued.timer_resolution_infos,
        timer_payload_idempotency_keys = timer_enqueued.timer_payload_idempotency_keys,
        timer_duplicate_skipped_count = timer_enqueued.timer_duplicate_skipped_count,
        wake_tick = timer_enqueued.wake_tick,
    }

    async:newUnsavableSimulationTimer(timer_enqueued.timer_seconds, function()
        completeTimerRun(request_id)
    end)

    return {
        ok = true,
        recipe_id = built.recipe_id,
        slot_count = built.slot_count,
        helper_record_count = built.helper_record_count,
        source_job_count = enqueued.job_count,
        source_jobs = source_collected.jobs,
        source_slot_ids = enqueued.slot_ids,
        source_helper_engine_ids = enqueued.helper_engine_ids,
        source_effect_ids = enqueued.effect_ids,
        source_launch_accepted_count = source_collected.accepted_count,
        timer_payload_job_count = timer_enqueued.timer_job_count,
        timer_jobs = pre_delay_collected.jobs,
        timer_payload_slot_ids = timer_enqueued.payload_slot_ids,
        timer_payload_helper_engine_ids = timer_enqueued.payload_helper_engine_ids,
        timer_payload_effect_ids = timer_enqueued.payload_effect_ids,
        timer_resolution_infos = timer_enqueued.timer_resolution_infos,
        timer_seconds = timer_enqueued.timer_seconds,
        timer_delay_ticks = timer_enqueued.timer_delay_ticks,
        timer_ticks_per_second = TIMER_TICKS_PER_SECOND,
        timer_projectile_speed = timer_enqueued.timer_projectile_speed,
        timer_payload_idempotency_keys = timer_enqueued.timer_payload_idempotency_keys,
        timer_duplicate_skipped_count = timer_enqueued.timer_duplicate_skipped_count,
        timer_wake_tick = timer_enqueued.wake_tick,
        pre_delay_tick_processed_count = pre_delay_tick.processed_count,
        timer_jobs_complete_before_delay = pre_delay_collected.complete_count,
        timer_jobs_waiting = timer_jobs_waiting,
        trigger_job_count = 0,
        chain_job_count = 0,
    }
end

completeTimerRun = function(request_id)
    local run = pending_timer_runs[request_id]
    if not run then
        return
    end

    local tick = orchestrator.tick({ max_jobs_per_tick = run.timer_job_count })
    local collected = collectTimerJobResults(run.timer_jobs)
    local all_complete = collected.complete_count == run.timer_job_count
    local all_accepted = collected.accepted_count == run.timer_job_count
    local ok = all_complete and all_accepted

    local result = {
        request_id = request_id,
        ok = ok,
        recipe_id = run.recipe_id,
        timer_payload_job_count = run.timer_job_count,
        timer_jobs = collected.jobs,
        timer_payload_slot_ids = run.payload_slot_ids,
        timer_payload_helper_engine_ids = run.payload_helper_engine_ids,
        timer_payload_effect_ids = run.payload_effect_ids,
        timer_resolution_infos = run.timer_resolution_infos,
        timer_payload_idempotency_keys = run.timer_payload_idempotency_keys,
        timer_duplicate_skipped_count = run.timer_duplicate_skipped_count or 0,
        frost_payload_launch_accepted_count = collected.accepted_count,
        tick_processed_count = tick.processed_count,
        timer_wake_tick = run.wake_tick,
        error = ok and nil or (collected.first_error or "one or more Timer payload jobs failed"),
    }

    send(run.sender, events.DEV_LAUNCH_TIMER_RESULT, result)
    if ok then
        log.info(string.format(
            "SPELLFORGE_DEV_TIMER_PAYLOAD_OK recipe_id=%s timer_job_count=%s payload_launch_accepted_count=%s",
            tostring(result.recipe_id),
            tostring(result.timer_payload_job_count),
            tostring(result.frost_payload_launch_accepted_count)
        ))
    else
        log.warn(string.format("dev timer payload failed error=%s", tostring(result.error)))
    end

    pending_timer_runs[request_id] = nil
end

local function triggerPayloadResult(run, request_id, ok, fields)
    local result = fields or {}
    result.request_id = request_id
    result.ok = ok == true
    result.recipe_id = run and run.recipe_id or result.recipe_id
    if not result.trigger_payload_job_count and run then
        result.trigger_payload_job_count = run.trigger_payload_job_count
    end
    if not result.frost_payload_launch_accepted_count and run then
        result.frost_payload_launch_accepted_count = run.payload_launch_accepted_count
    end
    if not result.duplicate_trigger_skipped_count and run then
        result.duplicate_trigger_skipped_count = run.duplicate_trigger_skipped_count or 0
    end
    if not result.trigger_jobs and run then
        result.trigger_jobs = collectTriggerJobResults(run.trigger_jobs).jobs
    end
    send(run and run.sender or nil, events.DEV_LAUNCH_TRIGGER_RESULT, result)
end

local function enqueueTriggerPayloadJob(request_id, run, hit_payload, source_mapping, idempotency_key, source_projectile_id)
    if source_mapping == nil then
        return nil, "missing Trigger source metadata"
    end
    local payload_helper = run.payload_by_source_slot_id and run.payload_by_source_slot_id[source_mapping.slot_id] or nil
    if not payload_helper then
        return nil, string.format("missing Trigger payload helper for source_slot_id=%s", tostring(source_mapping.slot_id))
    end

    local source_hit_pos = hit_payload and (hit_payload.hitPos or hit_payload.hit_pos) or nil
    if source_hit_pos == nil then
        return nil, string.format("Trigger source hit missing hitPos for source_slot_id=%s", tostring(source_mapping.slot_id))
    end

    local actor = hit_payload and hit_payload.attacker or run.actor
    if actor == nil then
        return nil, "missing caster for Trigger payload"
    end
    if run.direction == nil then
        return nil, "missing source direction for Trigger payload"
    end

    local source_hit_normal = hit_payload and (hit_payload.hitNormal or hit_payload.hit_normal) or nil
    local target = hit_payload and hit_payload.target or nil
    local source_job = run.source_job_by_slot_id and run.source_job_by_slot_id[source_mapping.slot_id] or nil
    if run.test_dry_run_payload_enqueue then
        local job_entry = {
            job_id = string.format("dry_run_trigger_%d", #run.trigger_jobs + 1),
            job_kind = orchestrator.DEV_TRIGGER_PAYLOAD_JOB_KIND,
            status = "queued",
            source_slot_id = source_mapping.slot_id,
            source_helper_engine_id = source_mapping.engine_id,
            slot_id = payload_helper.slot_id,
            helper_engine_id = payload_helper.engine_id,
            effect_id = firstEffectId(payload_helper),
            source_hit_pos = source_hit_pos,
            source_hit_normal = source_hit_normal,
            source_hit_target_id = target and target.recordId or nil,
            source_projectile_id = source_projectile_id,
            idempotency_key = idempotency_key,
        }
        run.trigger_jobs[#run.trigger_jobs + 1] = job_entry
        run.trigger_payload_job_count = run.trigger_payload_job_count + 1
        return job_entry, nil
    end

    local enqueue = dev_runtime.enqueuePayloadLaunchJob(orchestrator, {
        job_kind = orchestrator.DEV_TRIGGER_PAYLOAD_JOB_KIND,
        recipe_id = run.recipe_id,
        payload_helper = payload_helper,
        source_slot_id = source_mapping.slot_id,
        source_helper_engine_id = source_mapping.engine_id,
        source_job = source_job,
        idempotency_key = idempotency_key,
        depth = 1,
        payload = {
            actor = actor,
            start_pos = source_hit_pos,
            direction = run.direction,
            hit_object = target,
            source_slot_id = source_mapping.slot_id,
            source_hit_pos = source_hit_pos,
            source_hit_normal = source_hit_normal,
            source_hit_target_id = target and target.recordId or nil,
            source_projectile_id = source_projectile_id,
            payload_idempotency_key = idempotency_key,
        },
    })
    if not enqueue.ok then
        return nil, enqueue.error
    end

    local job_entry = {
        job_id = enqueue.job_id,
        job_kind = orchestrator.DEV_TRIGGER_PAYLOAD_JOB_KIND,
        status = enqueue.status,
        source_slot_id = source_mapping.slot_id,
        source_helper_engine_id = source_mapping.engine_id,
        slot_id = payload_helper.slot_id,
        helper_engine_id = payload_helper.engine_id,
        effect_id = firstEffectId(payload_helper),
        source_hit_pos = source_hit_pos,
        source_hit_normal = source_hit_normal,
        source_hit_target_id = target and target.recordId or nil,
        source_projectile_id = source_projectile_id,
        idempotency_key = idempotency_key,
    }
    run.trigger_jobs[#run.trigger_jobs + 1] = job_entry
    run.trigger_payload_job_count = run.trigger_payload_job_count + 1
    return job_entry, nil
end

completeTriggerPayloadJob = function(request_id, job_entry)
    local run = pending_trigger_runs[request_id]
    if not run then
        return
    end

    local tick = orchestrator.tick({ max_jobs_per_tick = 1 })
    local job = orchestrator.getJob(job_entry.job_id)
    local accepted = job and job.launch_accepted == true
    if accepted then
        run.payload_launch_accepted_count = run.payload_launch_accepted_count + 1
    end

    local collected = collectTriggerJobResults(run.trigger_jobs)
    local ok = job and job.status == "complete" and accepted == true
    triggerPayloadResult(run, request_id, ok, {
        source_slot_id = job_entry.source_slot_id,
        source_helper_engine_id = job_entry.source_helper_engine_id,
        payload_slot_id = job_entry.slot_id,
        payload_helper_engine_id = job_entry.helper_engine_id,
        effect_id = job_entry.effect_id,
        source_hit_pos = job_entry.source_hit_pos,
        source_hit_normal = job_entry.source_hit_normal,
        source_hit_target_id = job_entry.source_hit_target_id,
        source_projectile_id = job_entry.source_projectile_id,
        idempotency_key = job_entry.idempotency_key,
        trigger_payload_job_count = run.trigger_payload_job_count,
        duplicate_trigger_skipped_count = run.duplicate_trigger_skipped_count or 0,
        frost_payload_launch_accepted_count = run.payload_launch_accepted_count,
        trigger_jobs = collected.jobs,
        tick_processed_count = tick.processed_count,
        error = ok and nil or (job and job.error or "Trigger payload job was not processed"),
    })

    if ok then
        log.info(string.format(
            "SPELLFORGE_DEV_TRIGGER_PAYLOAD_OK recipe_id=%s source_slot_id=%s payload_slot_id=%s helper_engine_id=%s source_hit_pos=%s",
            tostring(run.recipe_id),
            tostring(job_entry.source_slot_id),
            tostring(job_entry.slot_id),
            tostring(job_entry.helper_engine_id),
            tostring(job_entry.source_hit_pos)
        ))
    else
        log.warn(string.format("dev trigger payload failed source_slot_id=%s error=%s", tostring(job_entry.source_slot_id), tostring(job and job.error)))
    end
end

local function handleTriggerHit(hit_payload, mapping, route, request_id_filter)
    for request_id, run in pairs(pending_trigger_runs) do
        if request_id_filter == nil or request_id == request_id_filter then
        local source_helper = run.source_helpers_by_engine_id and run.source_helpers_by_engine_id[mapping.engine_id] or nil
        if source_helper then
            local source_projectile_id = projectileIdFromRouteOrPayload(route, hit_payload)
            local idempotency_key = payloadIdempotencyKey(
                "trigger",
                request_id,
                run.recipe_id,
                mapping.slot_id,
                mapping.engine_id,
                source_projectile_id
            )
            if run.triggered_source_key_set and run.triggered_source_key_set[idempotency_key] then
                run.duplicate_trigger_skipped_count = (run.duplicate_trigger_skipped_count or 0) + 1
                log.debug(string.format("duplicate Trigger payload skipped key=%s", tostring(idempotency_key)))
            else
                if run.triggered_source_key_set then
                    run.triggered_source_key_set[idempotency_key] = true
                end
                if not run.triggered_source_slot_set[mapping.slot_id] then
                    run.triggered_source_slot_set[mapping.slot_id] = true
                    run.source_hit_count = run.source_hit_count + 1
                end
                local job_entry, err = enqueueTriggerPayloadJob(request_id, run, hit_payload, mapping, idempotency_key, source_projectile_id)
                if not job_entry then
                    triggerPayloadResult(run, request_id, false, {
                        source_slot_id = mapping.slot_id,
                        source_helper_engine_id = mapping.engine_id,
                        idempotency_key = idempotency_key,
                        error = err,
                    })
                else
                    if not run.test_no_auto_complete_payload then
                        async:newUnsavableSimulationTimer(TRIGGER_PAYLOAD_TICK_DELAY, function()
                            completeTriggerPayloadJob(request_id, job_entry)
                        end)
                    end
                end
            end
        elseif run.payload_helpers_by_engine_id and run.payload_helpers_by_engine_id[mapping.engine_id] then
            if not run.payload_hit_slot_set[mapping.slot_id] then
                run.payload_hit_slot_set[mapping.slot_id] = true
                run.payload_hit_count = run.payload_hit_count + 1
            end
            if run.payload_hit_count >= run.expected_payload_count then
                pending_trigger_runs[request_id] = nil
            end
        end
        end
    end
end

local function createTriggerProbeRun(request_id, sender, actor, built, direction)
    pending_trigger_runs[request_id] = {
        sender = sender,
        actor = actor,
        recipe_id = built.recipe_id,
        direction = direction,
        source_helpers_by_engine_id = mapHelpersByEngineId(built.source_helpers),
        payload_helpers_by_engine_id = mapHelpersByEngineId(built.trigger_payload_helpers),
        payload_by_source_slot_id = built.trigger_payload_by_source_slot_id,
        source_job_by_slot_id = {},
        trigger_jobs = {},
        triggered_source_slot_set = {},
        triggered_source_key_set = {},
        payload_hit_slot_set = {},
        source_hit_count = 0,
        payload_hit_count = 0,
        trigger_payload_job_count = 0,
        duplicate_trigger_skipped_count = 0,
        payload_launch_accepted_count = 0,
        expected_source_count = #built.source_helpers,
        expected_payload_count = #built.trigger_payload_helpers,
        test_dry_run_payload_enqueue = true,
        test_no_auto_complete_payload = true,
    }
    return pending_trigger_runs[request_id]
end

local function simulateTriggerSourceHit(request_id, helper, hit_payload)
    local route = dev_runtime.resolveHelperHit(hit_payload)
    if not route.ok then
        return {
            ok = false,
            request_id = request_id,
            source_slot_id = helper and helper.slot_id or nil,
            helper_engine_id = helper and helper.engine_id or nil,
            error = route.error,
        }
    end
    handleTriggerHit(hit_payload, route.mapping, route, request_id)
    return {
        ok = true,
        request_id = request_id,
        source_slot_id = route.slot_id,
        helper_engine_id = route.helper_engine_id,
        projectile_id = route.projectile_id,
        source = route.source,
        user_data = route.user_data,
        hit_key = route.hit_key,
        first_hit = route.first_hit,
        previous_hit_key = route.hit_record and route.hit_record.previous and route.hit_record.previous.hit_key or nil,
        effect_id = route.effect_id,
    }
end

function dev_launch.runHelperHitIdempotencyProbe(payload)
    local enabled, disabled_reason = ensureDevLaunchEnabled()
    if not enabled then
        return { ok = false, error = disabled_reason }
    end

    local probe_payload = payload or {}
    local request_id = probe_payload.request_id or "helper-hit-idempotency-probe"
    local sender = probe_payload.sender
    local actor = probe_payload.actor or sender
    local start_pos = probe_payload.start_pos
    local direction = probe_payload.direction
    if not actor then
        return { ok = false, error = "missing actor for helper-hit idempotency probe" }
    end
    if start_pos == nil then
        return { ok = false, error = "missing start_pos for helper-hit idempotency probe" }
    end
    if direction == nil then
        return { ok = false, error = "missing direction for helper-hit idempotency probe" }
    end

    projectile_registry.clearHitMarksForTests()

    local simple_built = dev_launch.buildTriggerEmitterPlan(false)
    if not simple_built.ok then
        return simple_built
    end

    local simple_request_id = request_id .. ":projectile"
    local simple_run = createTriggerProbeRun(simple_request_id, sender, actor, simple_built, direction)
    local simple_source = simple_built.source_helpers[1]
    local simple_hit_payload = {
        spellId = simple_source.engine_id,
        projectileId = request_id .. ":same-projectile",
        attacker = actor,
        hitPos = start_pos,
    }
    local simple_first = simulateTriggerSourceHit(simple_request_id, simple_source, simple_hit_payload)
    local simple_after_first_count = simple_run.trigger_payload_job_count
    local simple_second = simulateTriggerSourceHit(simple_request_id, simple_source, simple_hit_payload)
    local simple_after_duplicate_count = simple_run.trigger_payload_job_count
    local simple_distinct = simulateTriggerSourceHit(simple_request_id, simple_source, {
        spellId = simple_source.engine_id,
        projectileId = request_id .. ":distinct-projectile",
        attacker = actor,
        hitPos = start_pos,
    })
    local simple_after_distinct_projectile_count = simple_run.trigger_payload_job_count
    local simple_duplicate_skipped_count = simple_run.duplicate_trigger_skipped_count or 0
    pending_trigger_runs[simple_request_id] = nil

    local projectile_only_id = request_id .. ":projectile-only"
    projectile_registry.registerLaunch({
        ok = true,
        projectile_id = projectile_only_id,
        projectile_id_source = "probe",
        launch_returns_projectile = true,
    }, {
        recipe_id = simple_built.recipe_id,
        slot_id = simple_source.slot_id,
        helper_engine_id = simple_source.engine_id,
        job_kind = "idempotency_probe",
    })
    local projectile_only_route = dev_runtime.resolveHelperHit({
        projectileId = projectile_only_id,
        attacker = actor,
        hitPos = start_pos,
    })

    local user_data_request_id = request_id .. ":userdata"
    local user_data_run = createTriggerProbeRun(user_data_request_id, sender, actor, simple_built, direction)
    local user_data_first = simulateTriggerSourceHit(user_data_request_id, simple_source, {
        spellId = "spellforge_probe_wrong_spellid",
        projectileId = request_id .. ":userdata-projectile",
        userData = sfp_userdata.buildHelperUserData({
            runtime = "2.2c_dev_helper",
            recipe_id = simple_built.recipe_id,
            slot_id = simple_source.slot_id,
            helper_engine_id = simple_source.engine_id,
            job_kind = "idempotency_probe",
            job_id = request_id .. ":userdata-job",
            depth = 0,
        }),
        attacker = actor,
        hitPos = start_pos,
    })
    local user_data_trigger_count = user_data_run.trigger_payload_job_count
    pending_trigger_runs[user_data_request_id] = nil

    local mismatch_route = dev_runtime.resolveHelperHit({
        spellId = simple_source.engine_id,
        userData = {
            spellforge = true,
            schema = sfp_userdata.schema(),
            runtime = "2.2c_dev_helper",
            recipe_id = simple_built.recipe_id .. ":mismatch",
            slot_id = simple_source.slot_id,
            helper_engine_id = simple_source.engine_id,
        },
        attacker = actor,
        hitPos = start_pos,
    })

    local fallback_request_id = request_id .. ":fallback"
    local fallback_run = createTriggerProbeRun(fallback_request_id, sender, actor, simple_built, direction)
    local fallback_hit_payload = {
        spellId = simple_source.engine_id,
        attacker = actor,
        hitPos = start_pos,
    }
    local fallback_first = simulateTriggerSourceHit(fallback_request_id, simple_source, fallback_hit_payload)
    local fallback_after_first_count = fallback_run.trigger_payload_job_count
    local fallback_second = simulateTriggerSourceHit(fallback_request_id, simple_source, fallback_hit_payload)
    local fallback_after_duplicate_count = fallback_run.trigger_payload_job_count
    local fallback_duplicate_skipped_count = fallback_run.duplicate_trigger_skipped_count or 0
    pending_trigger_runs[fallback_request_id] = nil

    local multicast_built = dev_launch.buildTriggerEmitterPlan(true)
    if not multicast_built.ok then
        return multicast_built
    end

    local multicast_request_id = request_id .. ":multicast"
    local multicast_run = createTriggerProbeRun(multicast_request_id, sender, actor, multicast_built, direction)
    local multicast_route_ok = true
    for index, helper in ipairs(multicast_built.source_helpers or {}) do
        local route = simulateTriggerSourceHit(multicast_request_id, helper, {
            spellId = helper.engine_id,
            attacker = actor,
            hitPos = start_pos,
        })
        multicast_route_ok = multicast_route_ok and route.ok == true
        if index >= 3 then
            break
        end
    end
    local multicast_distinct_count = multicast_run.trigger_payload_job_count
    local multicast_duplicate_skipped_count = multicast_run.duplicate_trigger_skipped_count or 0
    pending_trigger_runs[multicast_request_id] = nil

    return {
        ok = simple_first.ok == true
            and simple_second.ok == true
            and simple_distinct.ok == true
            and projectile_only_route.ok == true
            and projectile_only_route.helper_engine_id == simple_source.engine_id
            and projectile_only_route.slot_id == simple_source.slot_id
            and user_data_first.ok == true
            and user_data_first.source == "userData"
            and user_data_first.helper_engine_id == simple_source.engine_id
            and user_data_first.source_slot_id == simple_source.slot_id
            and user_data_trigger_count == 1
            and mismatch_route.ok == false
            and type(mismatch_route.error) == "string"
            and fallback_first.ok == true
            and fallback_second.ok == true
            and multicast_route_ok == true
            and simple_first.first_hit == true
            and simple_second.first_hit == false
            and simple_second.hit_key == simple_first.hit_key
            and simple_second.previous_hit_key == simple_first.hit_key
            and simple_after_first_count == 1
            and simple_after_duplicate_count == 1
            and simple_after_distinct_projectile_count == 2
            and simple_duplicate_skipped_count == 1
            and fallback_first.first_hit == true
            and fallback_second.first_hit == false
            and fallback_second.hit_key == fallback_first.hit_key
            and fallback_second.previous_hit_key == fallback_first.hit_key
            and fallback_after_first_count == 1
            and fallback_after_duplicate_count == 1
            and fallback_duplicate_skipped_count == 1
            and multicast_distinct_count == #(multicast_built.source_helpers or {})
            and multicast_duplicate_skipped_count == 0,
        request_id = request_id,
        recipe_id = simple_built.recipe_id,
        helper_spellid_routing_ok = simple_first.ok == true and simple_first.helper_engine_id == simple_source.engine_id,
        projectile_routing_ok = simple_first.ok == true and simple_first.projectile_id ~= nil,
        projectile_only_routing_ok = projectile_only_route.ok == true
            and projectile_only_route.helper_engine_id == simple_source.engine_id
            and projectile_only_route.slot_id == simple_source.slot_id,
        user_data_routing_ok = user_data_first.ok == true
            and user_data_first.source == "userData"
            and user_data_first.helper_engine_id == simple_source.engine_id
            and user_data_first.source_slot_id == simple_source.slot_id
            and user_data_trigger_count == 1,
        user_data_mismatch_guard_ok = mismatch_route.ok == false and type(mismatch_route.error) == "string",
        user_data_mismatch_error = mismatch_route.error,
        projectile_duplicate_first_hit = simple_first.first_hit,
        projectile_duplicate_second_first_hit = simple_second.first_hit,
        projectile_duplicate_hit_key_stable = simple_second.hit_key == simple_first.hit_key,
        projectile_duplicate_previous_hit_key_matches = simple_second.previous_hit_key == simple_first.hit_key,
        projectile_trigger_after_first_count = simple_after_first_count,
        projectile_trigger_after_duplicate_count = simple_after_duplicate_count,
        projectile_trigger_after_distinct_projectile_count = simple_after_distinct_projectile_count,
        projectile_duplicate_skipped_count = simple_duplicate_skipped_count,
        fallback_routing_ok = fallback_first.ok == true and fallback_first.projectile_id == nil,
        fallback_duplicate_first_hit = fallback_first.first_hit,
        fallback_duplicate_second_first_hit = fallback_second.first_hit,
        fallback_duplicate_hit_key_stable = fallback_second.hit_key == fallback_first.hit_key,
        fallback_duplicate_previous_hit_key_matches = fallback_second.previous_hit_key == fallback_first.hit_key,
        fallback_trigger_after_first_count = fallback_after_first_count,
        fallback_trigger_after_duplicate_count = fallback_after_duplicate_count,
        fallback_duplicate_skipped_count = fallback_duplicate_skipped_count,
        multicast_distinct_count = multicast_distinct_count,
        multicast_expected_count = #(multicast_built.source_helpers or {}),
        multicast_duplicate_skipped_count = multicast_duplicate_skipped_count,
        timer_hit_driven_payload_enqueue = false,
        error = nil,
    }
end

function dev_launch.onHelperHitIdempotencyProbe(payload)
    local sender = payload and payload.sender
    local result = dev_launch.runHelperHitIdempotencyProbe(payload or {})
    result.request_id = payload and payload.request_id or nil
    send(sender, events.DEV_HELPER_HIT_IDEMPOTENCY_RESULT, result)
end

function dev_launch.onSimpleEmitterRequest(payload)
    local sender = payload and payload.sender
    local result = dev_launch.runSimpleEmitterLaunch(payload or {})
    result.request_id = payload and payload.request_id or nil
    send(sender, events.DEV_LAUNCH_RESULT, result)
    if result.ok then
        log.info(string.format(
            "SPELLFORGE_DEV_LAUNCH_OK recipe_id=%s slot_id=%s helper_engine_id=%s",
            tostring(result.recipe_id),
            tostring(result.slot_id),
            tostring(result.helper_engine_id)
        ))
    else
        log.warn(string.format("dev launch request failed stage=%s error=%s", tostring(result.stage), tostring(result.error)))
    end
end

function dev_launch.onMulticastEmitterRequest(payload)
    local sender = payload and payload.sender
    local result = dev_launch.runMulticastEmitterLaunch(payload or {})
    result.request_id = payload and payload.request_id or nil
    send(sender, events.DEV_LAUNCH_RESULT, result)
    if result.ok then
        log.info(string.format(
            "SPELLFORGE_DEV_MULTICAST_LAUNCH_OK recipe_id=%s slot_count=%s helper_record_count=%s job_count=%s",
            tostring(result.recipe_id),
            tostring(result.slot_count),
            tostring(result.helper_record_count),
            tostring(result.job_count)
        ))
    else
        log.warn(string.format("dev multicast launch request failed stage=%s error=%s", tostring(result.stage), tostring(result.error)))
    end
end

function dev_launch.onSpreadEmitterRequest(payload)
    local sender = payload and payload.sender
    local result = dev_launch.runSpreadEmitterLaunch(payload or {})
    result.request_id = payload and payload.request_id or nil
    send(sender, events.DEV_LAUNCH_RESULT, result)
    if result.ok then
        log.info(string.format(
            "SPELLFORGE_DEV_SPREAD_LAUNCH_OK recipe_id=%s slot_count=%s helper_record_count=%s job_count=%s spread_preset=%s spread_angle_degrees=%s",
            tostring(result.recipe_id),
            tostring(result.slot_count),
            tostring(result.helper_record_count),
            tostring(result.job_count),
            tostring(result.spread_preset),
            tostring(result.spread_angle_degrees)
        ))
    else
        log.warn(string.format("dev Spread launch request failed stage=%s error=%s", tostring(result.stage), tostring(result.error)))
    end
end

function dev_launch.onBurstEmitterRequest(payload)
    local sender = payload and payload.sender
    local result = dev_launch.runBurstEmitterLaunch(payload or {})
    result.request_id = payload and payload.request_id or nil
    send(sender, events.DEV_LAUNCH_RESULT, result)
    if result.ok then
        log.info(string.format(
            "SPELLFORGE_DEV_BURST_LAUNCH_OK recipe_id=%s slot_count=%s helper_record_count=%s job_count=%s burst_param_count=%s burst_ring_angle_degrees=%s",
            tostring(result.recipe_id),
            tostring(result.slot_count),
            tostring(result.helper_record_count),
            tostring(result.job_count),
            tostring(result.burst_param_count),
            tostring(result.burst_ring_angle_degrees)
        ))
    else
        log.warn(string.format("dev Burst launch request failed stage=%s error=%s", tostring(result.stage), tostring(result.error)))
    end
end

function dev_launch.onTimerEmitterRequest(payload)
    local sender = payload and payload.sender
    local result = dev_launch.runTimerEmitterLaunch(payload or {})
    result.request_id = payload and payload.request_id or nil
    send(sender, events.DEV_LAUNCH_RESULT, result)
    if result.ok then
        local first_resolution = result.timer_resolution_infos and result.timer_resolution_infos[1] or {}
        log.info(string.format(
            "SPELLFORGE_DEV_TIMER_LAUNCH_OK recipe_id=%s source_job_count=%s timer_payload_job_count=%s timer_seconds=%s timer_delay_ticks=%s start_pos=%s endpoint=%s resolution_pos=%s resolution_kind=%s",
            tostring(result.recipe_id),
            tostring(result.source_job_count),
            tostring(result.timer_payload_job_count),
            tostring(result.timer_seconds),
            tostring(result.timer_delay_ticks),
            tostring(first_resolution.timer_start_pos),
            tostring(first_resolution.timer_endpoint),
            tostring(first_resolution.resolution_pos),
            tostring(first_resolution.resolution_kind)
        ))
    else
        log.warn(string.format("dev timer launch request failed stage=%s error=%s", tostring(result.stage), tostring(result.error)))
    end
end

function dev_launch.onTriggerEmitterRequest(payload)
    local sender = payload and payload.sender
    local result = dev_launch.runTriggerEmitterLaunch(payload or {})
    result.request_id = payload and payload.request_id or nil
    send(sender, events.DEV_LAUNCH_RESULT, result)
    if result.ok then
        log.info(string.format(
            "SPELLFORGE_DEV_TRIGGER_LAUNCH_OK recipe_id=%s source_job_count=%s payload_helper_count=%s multicast=%s",
            tostring(result.recipe_id),
            tostring(result.source_job_count),
            tostring(result.expected_trigger_payload_count),
            tostring(result.multicast)
        ))
    else
        log.warn(string.format("dev trigger launch request failed stage=%s error=%s", tostring(result.stage), tostring(result.error)))
    end
end

function dev_launch.onPerformanceStressRequest(payload)
    local sender = payload and payload.sender
    local result = dev_launch.runPerformanceStressLaunch(payload or {})
    result.request_id = payload and payload.request_id or nil
    send(sender, events.DEV_LAUNCH_PERF_STRESS_RESULT, result)
    if result.ok then
        log.info(string.format(
            "SPELLFORGE_DEV_PERF_STRESS_FAST_FORWARD_OK recipe_id=%s slots=%s total_jobs=%s accepted=%s source=%s timer_payloads=%s trigger_payloads=%s timer_delay_ticks=%s burst_dirs=%s elapsed_ticks=%s queue_drained=%s fast_forward=%s real_delay_test=%s",
            tostring(result.recipe_id),
            tostring(result.slot_count),
            tostring(result.total_job_count),
            tostring(result.launch_accepted_count),
            tostring(result.source_job_count),
            tostring(result.timer_payload_job_count),
            tostring(result.trigger_payload_job_count),
            tostring(result.timer_delay_ticks),
            tostring(result.burst_direction_count),
            tostring(result.elapsed_ticks),
            tostring(result.queue_drained),
            tostring(result.fast_forward_semantics),
            tostring(result.real_delay_test)
        ))
    else
        log.warn(string.format("dev performance stress failed stage=%s error=%s", tostring(result.stage), tostring(result.error)))
    end
end

function dev_launch.onProbeUnknownHelper(payload)
    local sender = payload and payload.sender
    local request_id = payload and payload.request_id
    local engine_id = payload and payload.engine_id or "spellforge_unknown_helper_for_probe"

    local enabled, disabled_reason = ensureDevLaunchEnabled()
    if not enabled then
        send(sender, events.DEV_LAUNCH_LOOKUP_RESULT, {
            request_id = request_id,
            ok = false,
            engine_id = engine_id,
            error = disabled_reason,
        })
        return
    end

    local route = dev_runtime.resolveHelperHit({ spellId = engine_id })
    if not route.ok then
        send(sender, events.DEV_LAUNCH_LOOKUP_RESULT, {
            request_id = request_id,
            ok = false,
            engine_id = engine_id,
            error = route.error,
        })
        return
    end

    local mapping = route.mapping
    send(sender, events.DEV_LAUNCH_LOOKUP_RESULT, {
        request_id = request_id,
        ok = true,
        engine_id = engine_id,
        recipe_id = mapping.recipe_id,
        slot_id = mapping.slot_id,
    })
end

function dev_launch.onHelperHit(route_or_payload, mapping_arg)
    if not dev.devLaunchEnabled() then
        return
    end
    local route = nil
    if type(route_or_payload) == "table" and route_or_payload.ok == true and route_or_payload.mapping ~= nil then
        route = route_or_payload
    elseif mapping_arg ~= nil then
        route = {
            ok = true,
            mapping = mapping_arg,
            recipe_id = mapping_arg.recipe_id,
            slot_id = mapping_arg.slot_id,
            helper_engine_id = mapping_arg.engine_id,
            effect_id = firstEffectId(mapping_arg),
            hit_pos = route_or_payload and (route_or_payload.hitPos or route_or_payload.hit_pos) or nil,
            hit_normal = route_or_payload and (route_or_payload.hitNormal or route_or_payload.hit_normal) or nil,
            attacker = route_or_payload and route_or_payload.attacker or nil,
            target = route_or_payload and route_or_payload.target or nil,
            raw_payload = route_or_payload,
        }
    end

    local mapping = route and route.mapping or nil
    if type(mapping) ~= "table" then
        return
    end
    local payload = route.raw_payload

    log.info(string.format(
        "SPELLFORGE_DEV_HELPER_HIT recipe_id=%s slot_id=%s helper_engine_id=%s effect_id=%s",
        tostring(mapping.recipe_id),
        tostring(mapping.slot_id),
        tostring(mapping.engine_id),
        tostring(route.effect_id)
    ))

    handleTriggerHit(payload, mapping, route)

    for request_id, watcher in pairs(pending_hits) do
        if watcher.helpers_by_engine_id and watcher.helpers_by_engine_id[mapping.engine_id] then
            if not watcher.seen_by_engine_id[mapping.engine_id] then
                watcher.seen_by_engine_id[mapping.engine_id] = true
                watcher.hit_count = (watcher.hit_count or 0) + 1
            end

            local remaining_count = (watcher.expected_count or 1) - (watcher.hit_count or 0)
            if remaining_count < 0 then
                remaining_count = 0
            end
            send(watcher.sender, events.DEV_LAUNCH_HIT_OBSERVED, {
                request_id = request_id,
                ok = true,
                recipe_id = mapping.recipe_id,
                slot_id = mapping.slot_id,
                helper_engine_id = mapping.engine_id,
                effect_id = mapping.effects and mapping.effects[1] and mapping.effects[1].id or nil,
                hit_count = watcher.hit_count,
                expected_count = watcher.expected_count,
                remaining_count = remaining_count,
                spell_id = payload and (payload.spellId or payload.spell_id) or nil,
                projectile_id = route.projectile_id,
                projectile_id_source = route.projectile_id_source,
                route_source = route.source,
                hit_user_data_present = type(route.user_data) == "table",
                hit_user_data_schema = route.user_data and route.user_data.schema or nil,
                hit_user_data_runtime = route.user_data and route.user_data.runtime or nil,
                hit_user_data_recipe_id = route.user_data and route.user_data.recipe_id or nil,
                hit_user_data_slot_id = route.user_data and route.user_data.slot_id or nil,
                hit_user_data_helper_engine_id = route.user_data and route.user_data.helper_engine_id or nil,
                hit_key = route.hit_key,
                first_hit = route.first_hit,
                impactSpeed = route.telemetry and route.telemetry.impactSpeed or nil,
                maxSpeed = route.telemetry and route.telemetry.maxSpeed or nil,
                velocity = route.telemetry and route.telemetry.velocity or nil,
                magMin = route.telemetry and route.telemetry.magMin or nil,
                magMax = route.telemetry and route.telemetry.magMax or nil,
                casterLinked = route.telemetry and route.telemetry.casterLinked or nil,
                stackLimit = route.telemetry and route.telemetry.stackLimit or nil,
                stackCount = route.telemetry and route.telemetry.stackCount or nil,
                telemetry_present_count = route.telemetry and route.telemetry.present_count or 0,
                telemetry_has_beta2_fields = route.telemetry and route.telemetry.has_any_beta2_fields or false,
                hit_pos = route.hit_pos,
                hit_normal = route.hit_normal,
                attacker_id = route.attacker and route.attacker.recordId or nil,
                victim_id = route.target and route.target.recordId or nil,
            })
            if (watcher.hit_count or 0) >= (watcher.expected_count or 1) then
                pending_hits[request_id] = nil
            end
        end
    end
end

return dev_launch
