local dev = require("scripts.spellforge.shared.dev")
local limits = require("scripts.spellforge.shared.limits")
local log = require("scripts.spellforge.shared.log").new("global.live_trigger")
local helper_records = require("scripts.spellforge.global.helper_records")
local orchestrator = require("scripts.spellforge.global.orchestrator")
local live_timer = require("scripts.spellforge.global.live_timer")
local payload_multicast = require("scripts.spellforge.global.payload_multicast")
local payload_pattern = require("scripts.spellforge.global.payload_pattern")
local runtime_hits = require("scripts.spellforge.global.runtime_hits")
local runtime_stats = require("scripts.spellforge.global.runtime_stats")

local live_trigger = {}

local MAX_BINDINGS = 128
local MAX_DUPLICATE_KEYS = 256

local bindings_by_cast_source = {}
local bindings_by_latest_source = {}
local binding_order = {}
local duplicate_keys = {}
local duplicate_order = {}

local function recipeSlotKey(recipe_id, slot_id)
    return string.format("%s::%s", tostring(recipe_id), tostring(slot_id))
end

local function castSourceKey(recipe_id, slot_id, cast_id)
    return string.format("%s::%s::%s", tostring(recipe_id), tostring(slot_id), tostring(cast_id))
end

local function appendBounded(order, key, max_count, on_evict)
    order[#order + 1] = key
    while #order > max_count do
        local evicted = table.remove(order, 1)
        if on_evict then
            on_evict(evicted)
        end
    end
end

local function hasOps(ops)
    return type(ops) == "table" and #ops > 0
end

local function hasPayloadBindings(value)
    return type(value) == "table" and #value > 0
end

local function firstEffectId(helper)
    local first = helper and helper.effects and helper.effects[1] or nil
    return first and first.id or nil
end

local function helperBySlotId(helpers)
    local by_slot = {}
    for _, helper in ipairs(helpers or {}) do
        if type(helper) == "table" and type(helper.slot_id) == "string" then
            by_slot[helper.slot_id] = helper
        end
    end
    return by_slot
end

local function slotHasOneTriggerBinding(slot)
    local bindings = slot and slot.payload_bindings
    if type(bindings) ~= "table" or #bindings ~= 1 then
        return false
    end
    return bindings[1] and bindings[1].source_opcode == "Trigger"
end

local function postfixIsOnlyTrigger(slot)
    local ops = slot and slot.postfix_ops
    return type(ops) == "table" and #ops == 1 and ops[1].opcode == "Trigger"
end

local function rejectSelect(reason, counter_name)
    if counter_name then
        runtime_stats.inc(counter_name)
    end
    return nil, reason
end

function live_trigger.selectV0Plan(plan, opts)
    local options = opts or {}
    if type(plan) ~= "table" then
        return rejectSelect("missing_plan")
    end
    local bounds = plan.bounds or {}
    if bounds.has_timer then
        return rejectSelect("nested_payload_runtime_deferred", "payload_multicast_nested_reject")
    end
    if bounds.has_chain then
        return rejectSelect("payload_multicast_chain_deferred", "payload_multicast_chain_reject")
    end
    if bounds.group_count ~= 1 then
        return rejectSelect("not_single_group")
    end
    if tonumber(bounds.static_emission_count) ~= 1 then
        return rejectSelect("not_single_source_emission")
    end

    local group = plan.groups and plan.groups[1] or nil
    if type(group) ~= "table" then
        return rejectSelect("missing_group")
    end
    if hasOps(group.prefix_ops) then
        return rejectSelect("source_has_prefix_ops")
    end
    if not postfixIsOnlyTrigger(group) then
        return rejectSelect("source_not_trigger")
    end
    if not group.payload or type(group.payload.effects) ~= "table" or #group.payload.effects == 0 then
        return rejectSelect("missing_trigger_payload", "live_trigger_payload_missing")
    end

    local slots = plan.emission_slots or {}
    local helpers = plan.helper_records or {}

    local source_slot = nil
    for _, slot in ipairs(slots) do
        if slot.kind == "primary_emission" then
            if source_slot then
                return rejectSelect("multiple_trigger_sources")
            end
            source_slot = slot
        elseif slot.kind == "payload_emission" then
            -- Payload slots are validated as a direct Trigger payload group below.
        else
            return rejectSelect("unknown_slot_kind")
        end
    end

    if not source_slot then
        return rejectSelect("missing_trigger_source_slot")
    end
    if source_slot.parent_slot_id ~= nil or source_slot.source_postfix_opcode ~= nil then
        return rejectSelect("source_slot_not_primary")
    end
    if source_slot.trigger_source_slot_id ~= nil or source_slot.timer_source_slot_id ~= nil then
        return rejectSelect("source_slot_has_payload_source")
    end
    if hasOps(source_slot.prefix_ops) then
        return rejectSelect("source_slot_has_prefix_ops")
    end
    if not postfixIsOnlyTrigger(source_slot) then
        return rejectSelect("source_slot_not_trigger")
    end
    if not slotHasOneTriggerBinding(source_slot) then
        return rejectSelect("source_trigger_binding_missing", "live_trigger_payload_missing")
    end

    local helpers_by_slot = helperBySlotId(helpers)
    local source_helper = helpers_by_slot[source_slot.slot_id]
    if not source_helper or type(source_helper.engine_id) ~= "string" or source_helper.engine_id == "" then
        return rejectSelect("source_helper_missing")
    end
    if source_helper.parent_slot_id ~= nil or source_helper.source_postfix_opcode ~= nil then
        return rejectSelect("source_helper_not_primary")
    end
    if not slotHasOneTriggerBinding(source_helper) then
        return rejectSelect("source_helper_trigger_binding_missing", "live_trigger_payload_missing")
    end

    local payload_result = payload_multicast.resolvePayloadHelpersForSource(plan, source_slot, {
        source_opcode = "Trigger",
        allow_payload_multicast = options.allow_payload_multicast == true,
        allow_payload_pattern = options.allow_payload_pattern == true,
        max_depth = options.max_depth,
        max_jobs = options.max_jobs,
        max_fanout = options.max_fanout,
        max_projectiles = options.max_projectiles,
    })
    if payload_result.detected_payload_multicast then
        runtime_stats.inc("payload_multicast_attempts")
    end
    if payload_result.detected_payload_pattern then
        runtime_stats.inc("payload_pattern_attempts")
    end
    if not payload_result.ok then
        local reason = payload_result.rejection_reason or "trigger_payload_resolution_failed"
        if payload_result.detected_payload_multicast then
            runtime_stats.inc("payload_multicast_rejected")
            if reason == "payload_multicast_disabled" then
                runtime_stats.inc("payload_multicast_disabled_reject")
            elseif reason == "payload_multicast_fanout_cap_exceeded"
                or reason == "payload_multicast_projectile_cap_exceeded"
                or reason == "payload_multicast_job_cap_exceeded" then
                runtime_stats.inc("payload_multicast_cap_reject")
            elseif reason == "payload_multicast_chain_deferred" then
                runtime_stats.inc("payload_multicast_chain_reject")
            elseif reason == "nested_payload_runtime_deferred"
                or reason == "payload_pattern_runtime_deferred"
                or reason == "payload_speed_plus_runtime_deferred"
                or reason == "payload_size_plus_runtime_deferred" then
                runtime_stats.inc("payload_multicast_nested_reject")
            end
        end
        if payload_result.detected_payload_pattern then
            runtime_stats.inc("payload_pattern_rejected")
            if reason == "payload_pattern_disabled" then
                runtime_stats.inc("payload_pattern_disabled_reject")
            elseif reason == "payload_multicast_fanout_cap_exceeded"
                or reason == "payload_multicast_projectile_cap_exceeded"
                or reason == "payload_multicast_job_cap_exceeded"
                or reason == "payload_pattern_fanout_missing" then
                runtime_stats.inc("payload_pattern_cap_reject")
            elseif reason == "payload_multicast_chain_deferred" then
                runtime_stats.inc("payload_pattern_chain_reject")
            else
                runtime_stats.inc("payload_pattern_nested_reject")
            end
        end
        local counter = reason == "payload_missing" and "live_trigger_payload_missing" or nil
        return rejectSelect(reason, counter)
    end
    if payload_result.is_payload_multicast then
        runtime_stats.inc("payload_multicast_qualified")
    end
    if payload_result.is_payload_pattern then
        runtime_stats.inc("payload_pattern_qualified")
    end

    return {
        source = {
            slot = source_slot,
            helper = source_helper,
        },
        payload = {
            slot = payload_result.payload_slots[1].slot,
            helper = payload_result.payload_slots[1].helper,
        },
        source_slot_id = source_slot.slot_id,
        source_helper_engine_id = source_helper.engine_id,
        payload_slot_id = payload_result.payload_slot_id,
        payload_helper_engine_id = payload_result.payload_helper_engine_id,
        payload_effect_id = payload_result.payload_effect_id,
        payloads = payload_result.payload_slots,
        payload_slot_ids = payload_result.payload_slot_ids,
        payload_helper_engine_ids = payload_result.payload_helper_engine_ids,
        payload_effect_ids = payload_result.payload_effect_ids,
        payload_count = payload_result.payload_count,
        payload_group_key = payload_result.payload_group_key,
        payload_multicast = payload_result.is_payload_multicast == true,
        payload_pattern = payload_result.is_payload_pattern == true,
        payload_pattern_kind = payload_result.pattern_kind,
        payload_pattern_op = payload_result.pattern_op,
        payload_multicast_fanout_count = payload_result.fanout_count,
        max_payload_fanout = tonumber(options.max_fanout) or limits.MAX_NESTED_PAYLOAD_FANOUT,
        max_projectiles = tonumber(options.max_projectiles) or limits.MAX_PROJECTILES_PER_CAST,
        max_jobs_per_tick = tonumber(options.max_jobs_per_tick) or limits.MAX_JOBS_PER_TICK,
        max_live_launches_per_tick = tonumber(options.max_live_launches_per_tick) or limits.MAX_LIVE_LAUNCHES_PER_TICK,
        chaos_budget_profile = options.chaos_budget_profile,
        allow_pending_launch_jobs = options.allow_pending_launch_jobs == true,
    }, nil
end

function live_trigger.decorateSourceJob(job, binding)
    if type(job) ~= "table" or type(binding) ~= "table" then
        return
    end
    job.source_postfix_opcode = "Trigger"
    job.root_source_slot_id = binding.root_source_slot_id or binding.source_slot_id
    job.current_source_slot_id = binding.current_source_slot_id or binding.source_slot_id
    job.parent_slot_id = binding.parent_slot_id
    job.payload_depth = tonumber(binding.source_depth) or 0
    job.nested_stage_kind = binding.nested_stage_kind
    job.nested_stage_index = binding.nested_stage_index
    job.trigger_source_slot_id = binding.source_slot_id
    job.trigger_payload_slot_id = binding.payload_slot_id
    job.trigger_payload_slot_ids = binding.payload_slot_ids
    job.has_trigger_payload = true
    job.payload_multicast = binding.payload_multicast == true
    job.payload_pattern = binding.payload_pattern == true
    job.payload_pattern_kind = binding.payload_pattern_kind
    job.nested_final_fanout = binding.nested_final_fanout == true
    job.nested_final_fanout_kind = binding.nested_final_fanout_kind
    job.payload_count = tonumber(binding.payload_count) or 1
    job.payload = job.payload or {}
    job.payload.source_slot_id = binding.source_slot_id
    job.payload.source_helper_engine_id = binding.source_helper_engine_id
    job.payload.source_postfix_opcode = "Trigger"
    job.payload.root_source_slot_id = binding.root_source_slot_id or binding.source_slot_id
    job.payload.current_source_slot_id = binding.current_source_slot_id or binding.source_slot_id
    job.payload.parent_slot_id = binding.parent_slot_id
    job.payload.payload_depth = tonumber(binding.source_depth) or 0
    job.payload.nested_stage_kind = binding.nested_stage_kind
    job.payload.nested_stage_index = binding.nested_stage_index
    job.payload.trigger_source_slot_id = binding.source_slot_id
    job.payload.trigger_payload_slot_id = binding.payload_slot_id
    job.payload.trigger_payload_slot_ids = binding.payload_slot_ids
    job.payload.has_trigger_payload = true
    job.payload.payload_multicast = binding.payload_multicast == true
    job.payload.payload_pattern = binding.payload_pattern == true
    job.payload.payload_pattern_kind = binding.payload_pattern_kind
    job.payload.nested_final_fanout = binding.nested_final_fanout == true
    job.payload.nested_final_fanout_kind = binding.nested_final_fanout_kind
    job.payload.payload_count = tonumber(binding.payload_count) or 1
end

local function compactPayloadsFromBinding(binding)
    local payloads = {}
    if type(binding.payloads) == "table" and #binding.payloads > 0 then
        for index, payload in ipairs(binding.payloads) do
            payloads[index] = {
                slot_id = payload.slot_id,
                helper_engine_id = payload.helper_engine_id,
                effect_id = payload.effect_id,
                emission_index = payload.emission_index,
                group_index = payload.group_index,
                direction = payload.direction,
                pattern_kind = payload.pattern_kind,
                pattern_index = payload.pattern_index,
                pattern_count = payload.pattern_count,
                pattern_direction_key = payload.pattern_direction_key,
                parent_slot_id = payload.parent_slot_id,
                root_source_slot_id = payload.root_source_slot_id,
                current_source_slot_id = payload.current_source_slot_id,
                payload_depth = payload.payload_depth,
                nested_stage_kind = payload.nested_stage_kind,
                nested_stage_index = payload.nested_stage_index,
                has_trigger_payload = payload.has_trigger_payload,
                has_timer_payload = payload.has_timer_payload,
            }
        end
    elseif type(binding.payload_slot_id) == "string" and type(binding.payload_helper_engine_id) == "string" then
        payloads[1] = {
            slot_id = binding.payload_slot_id,
            helper_engine_id = binding.payload_helper_engine_id,
        }
    end
    return payloads
end

local function payloadSlotIds(payloads)
    local ids = {}
    for index, payload in ipairs(payloads or {}) do
        ids[index] = payload.slot_id
    end
    return ids
end

function live_trigger.registerBinding(binding)
    local input = binding or {}
    local payloads = compactPayloadsFromBinding(input)
    if type(input.recipe_id) ~= "string" or input.recipe_id == ""
        or type(input.source_slot_id) ~= "string" or input.source_slot_id == ""
        or #payloads == 0 then
        return false
    end
    input.payloads = payloads
    input.payload_slot_ids = payloadSlotIds(payloads)
    input.payload_count = #payloads

    local cast_key = castSourceKey(input.recipe_id, input.source_slot_id, input.cast_id)
    local latest_key = recipeSlotKey(input.recipe_id, input.source_slot_id)
    bindings_by_cast_source[cast_key] = input
    bindings_by_latest_source[latest_key] = input
    appendBounded(binding_order, cast_key, MAX_BINDINGS, function(evicted)
        local evicted_binding = bindings_by_cast_source[evicted]
        if evicted_binding then
            local evicted_latest_key = recipeSlotKey(evicted_binding.recipe_id, evicted_binding.source_slot_id)
            if bindings_by_latest_source[evicted_latest_key] == evicted_binding then
                bindings_by_latest_source[evicted_latest_key] = nil
            end
        end
        bindings_by_cast_source[evicted] = nil
    end)
    return true
end

local function bindingForRoute(route)
    if not route or not route.ok then
        return nil
    end
    local user_data = route.user_data or {}
    local recipe_id = route.recipe_id
    local source_slot_id = route.slot_id
    local cast_id = user_data.cast_id
    if type(recipe_id) == "string" and type(source_slot_id) == "string" and type(cast_id) == "string" then
        local binding = bindings_by_cast_source[castSourceKey(recipe_id, source_slot_id, cast_id)]
        if binding then
            return binding
        end
    end
    if type(recipe_id) == "string" and type(source_slot_id) == "string" then
        return bindings_by_latest_source[recipeSlotKey(recipe_id, source_slot_id)]
    end
    return nil
end

local function duplicateKey(route, binding)
    local payload_key = binding.payload_group_key or binding.payload_slot_id
    return string.format(
        "trigger:%s:%s:%s:%s:%s:%s",
        tostring(binding.cast_id or (route.user_data and route.user_data.cast_id) or "no-cast"),
        tostring(binding.recipe_id or route.recipe_id),
        tostring(binding.source_slot_id or route.slot_id),
        tostring(payload_key),
        tostring(binding.source_helper_engine_id or route.helper_engine_id),
        tostring(route.projectile_id or "no-projectile")
    )
end

local function rememberDuplicateKey(key)
    duplicate_keys[key] = true
    appendBounded(duplicate_order, key, MAX_DUPLICATE_KEYS, function(evicted)
        duplicate_keys[evicted] = nil
    end)
end

local function shortKey(key)
    if type(key) == "string" and #key <= 180 then
        return key
    end
    return nil
end

function live_trigger.handleResolvedHit(route, opts)
    local options = opts or {}
    if not route or route.ok ~= true then
        return { ok = false, ignored = true, error = route and route.error or "unresolved hit" }
    end

    local binding = bindingForRoute(route)
    if not binding then
        return { ok = true, ignored = true, reason = "no_live_trigger_binding" }
    end
    if route.helper_engine_id ~= binding.source_helper_engine_id then
        return { ok = true, ignored = true, reason = "not_trigger_source_helper" }
    end

    if options.force_enabled ~= true and not dev.liveTriggerEnabled() then
        runtime_stats.inc("live_trigger_rejected")
        runtime_stats.inc("live_trigger_disabled_rejections")
        return { ok = false, disabled = true, error = "live trigger disabled" }
    end

    runtime_stats.inc("live_trigger_source_hits")

    local source_depth = tonumber(route.user_data and route.user_data.depth) or 0
    local payload_depth = source_depth + 1
    if payload_depth > limits.MAX_RECURSION_DEPTH then
        runtime_stats.inc("live_trigger_depth_rejections")
        runtime_stats.inc("live_trigger_payload_route_failed")
        return { ok = false, error = "trigger payload depth exceeds MAX_RECURSION_DEPTH" }
    end

    local key = duplicateKey(route, binding)
    if duplicate_keys[key] then
        runtime_stats.inc("live_trigger_duplicate_hits_suppressed")
        if binding.nested_tt == true then
            runtime_stats.inc("nested_tt_duplicate_suppressed")
        end
        if binding.nested_final_fanout == true
            or (type(binding.nested_timer_binding) == "table"
                and binding.nested_timer_binding.nested_final_fanout == true) then
            runtime_stats.inc("nested_final_fanout_duplicate_suppressed")
        end
        log.debug(string.format(
            "live Trigger duplicate payload skipped recipe_id=%s source_slot_id=%s payload_slot_id=%s key=%s",
            tostring(binding.recipe_id),
            tostring(binding.source_slot_id),
            tostring(binding.payload_slot_id),
            tostring(shortKey(key) or "<long>")
        ))
        return {
            ok = true,
            duplicate_suppressed = true,
            duplicate_key = key,
            source_slot_id = binding.source_slot_id,
            payload_slot_id = binding.payload_slot_id,
            payload_slot_ids = binding.payload_slot_ids,
            payload_count = binding.payload_count,
            payload_multicast = binding.payload_multicast == true,
            payload_pattern = binding.payload_pattern == true,
            payload_pattern_kind = binding.payload_pattern_kind,
            nested_final_fanout = binding.nested_final_fanout == true,
            nested_final_fanout_kind = binding.nested_final_fanout_kind,
        }
    end

    local payloads = compactPayloadsFromBinding(binding)
    if #payloads == 0 then
        runtime_stats.inc("live_trigger_payload_missing")
        runtime_stats.inc("live_trigger_payload_route_failed")
        return { ok = false, error = "trigger payload helper mapping missing" }
    end
    local max_payload_fanout = tonumber(binding.max_payload_fanout) or limits.MAX_NESTED_PAYLOAD_FANOUT
    local max_projectiles = tonumber(binding.max_projectiles) or limits.MAX_PROJECTILES_PER_CAST
    if #payloads > max_payload_fanout or #payloads > max_projectiles then
        runtime_stats.inc("live_trigger_payload_route_failed")
        runtime_stats.inc("payload_multicast_cap_reject")
        return { ok = false, error = "trigger payload multicast fanout exceeds cap" }
    end
    for index, payload in ipairs(payloads) do
        local payload_mapping = helper_records.getByRecipeSlot(binding.recipe_id, payload.slot_id)
            or helper_records.getByEngineId(payload.helper_engine_id)
        if not payload_mapping or payload_mapping.engine_id ~= payload.helper_engine_id then
            runtime_stats.inc("live_trigger_payload_missing")
            runtime_stats.inc("live_trigger_payload_route_failed")
            return { ok = false, error = "trigger payload helper mapping missing" }
        end
        if payload_mapping.source_postfix_opcode ~= "Trigger"
            or payload_mapping.trigger_source_slot_id ~= binding.source_slot_id then
            runtime_stats.inc("live_trigger_payload_route_failed")
            return { ok = false, error = "trigger payload helper mapping mismatch" }
        end
    end

    local actor = route.attacker or binding.actor
    local start_pos = route.hit_pos
    local direction = binding.direction
    if actor == nil then
        runtime_stats.inc("live_trigger_payload_route_failed")
        return { ok = false, error = "missing caster for trigger payload" }
    end
    if start_pos == nil then
        runtime_stats.inc("live_trigger_payload_route_failed")
        return { ok = false, error = "missing hit position for trigger payload" }
    end
    if direction == nil then
        runtime_stats.inc("live_trigger_payload_route_failed")
        return { ok = false, error = "missing source direction for trigger payload" }
    end

    local pattern_info = nil
    if binding.payload_pattern == true then
        local pattern_err = nil
        pattern_info, pattern_err = payload_pattern.compute(payloads, direction, binding.payload_pattern_kind, binding.payload_pattern_op)
        if not pattern_info then
            runtime_stats.inc("live_trigger_payload_route_failed")
            runtime_stats.inc("payload_pattern_rejected")
            runtime_stats.inc("payload_pattern_nested_reject")
            return { ok = false, error = pattern_err or "trigger payload pattern direction failed" }
        end
        payloads = pattern_info.payloads
    end

    local trigger_route = route.source or "unknown"
    local source_job_id = binding.source_job_id or (route.user_data and route.user_data.job_id)
    local job_ids = {}
    for index, payload in ipairs(payloads) do
        local payload_key = string.format("%s:%s", tostring(key), tostring(payload.slot_id))
        local enqueue = orchestrator.enqueue({
            kind = orchestrator.LIVE_TRIGGER_PAYLOAD_JOB_KIND,
            recipe_id = binding.recipe_id,
            slot_id = payload.slot_id,
            helper_engine_id = payload.helper_engine_id,
            idempotency_key = payload_key,
            source_job_id = source_job_id,
            parent_job_id = source_job_id,
            depth = payload_depth,
            cast_id = binding.cast_id,
            emission_index = payload.emission_index,
            group_index = payload.group_index,
            fanout_count = #payloads,
            max_live_launches_per_tick = binding.max_live_launches_per_tick,
            chaos_budget_profile = binding.chaos_budget_profile,
            root_source_slot_id = payload.root_source_slot_id or binding.root_source_slot_id,
            current_source_slot_id = payload.current_source_slot_id or payload.slot_id,
            parent_slot_id = payload.parent_slot_id or binding.source_slot_id,
            payload_depth = payload.payload_depth or payload_depth,
            nested_stage_kind = payload.nested_stage_kind or binding.nested_stage_kind,
            nested_stage_index = payload.nested_stage_index or binding.nested_stage_index,
            has_trigger_payload = payload.has_trigger_payload,
            has_timer_payload = payload.has_timer_payload,
            pattern_kind = payload.pattern_kind,
            pattern_index = payload.pattern_index,
            pattern_count = payload.pattern_count,
            pattern_direction_key = payload.pattern_direction_key,
            nested_final_fanout = binding.nested_final_fanout == true,
            nested_final_fanout_kind = binding.nested_final_fanout_kind,
            final_fanout_count = binding.nested_final_fanout == true and #payloads or nil,
            final_fanout_index = binding.nested_final_fanout == true and index or nil,
            source_slot_id = binding.source_slot_id,
            source_helper_engine_id = binding.source_helper_engine_id,
            source_postfix_opcode = "Trigger",
            payload_slot_id = payload.slot_id,
            payload = {
                actor = actor,
                start_pos = start_pos,
                direction = payload.direction or direction,
                hit_object = route.target,
                cast_id = binding.cast_id,
                source_slot_id = binding.source_slot_id,
                source_helper_engine_id = binding.source_helper_engine_id,
                source_postfix_opcode = "Trigger",
                root_source_slot_id = payload.root_source_slot_id or binding.root_source_slot_id,
                current_source_slot_id = payload.current_source_slot_id or payload.slot_id,
                parent_slot_id = payload.parent_slot_id or binding.source_slot_id,
                payload_depth = payload.payload_depth or payload_depth,
                nested_stage_kind = payload.nested_stage_kind or binding.nested_stage_kind,
                nested_stage_index = payload.nested_stage_index or binding.nested_stage_index,
                has_trigger_payload = payload.has_trigger_payload,
                has_timer_payload = payload.has_timer_payload,
                payload_slot_id = payload.slot_id,
                trigger_source_slot_id = binding.source_slot_id,
                trigger_payload_slot_id = payload.slot_id,
                trigger_route = trigger_route,
                trigger_duplicate_key = shortKey(key),
                payload_multicast = binding.payload_multicast == true,
                payload_pattern = binding.payload_pattern == true,
                payload_count = #payloads,
                fanout_count = #payloads,
                emission_index = payload.emission_index,
                group_index = payload.group_index,
                pattern_kind = payload.pattern_kind,
                pattern_index = payload.pattern_index,
                pattern_count = payload.pattern_count,
                pattern_direction_key = payload.pattern_direction_key,
                nested_final_fanout = binding.nested_final_fanout == true,
                nested_final_fanout_kind = binding.nested_final_fanout_kind,
                final_fanout_count = binding.nested_final_fanout == true and #payloads or nil,
                final_fanout_index = binding.nested_final_fanout == true and index or nil,
            },
        })
        if not enqueue.ok then
            runtime_stats.inc("live_trigger_payload_route_failed")
            return { ok = false, error = enqueue.error or "trigger payload enqueue failed", job_ids = job_ids }
        end
        job_ids[#job_ids + 1] = enqueue.job_id
    end

    rememberDuplicateKey(key)
    runtime_stats.inc("live_trigger_payload_jobs_enqueued", #job_ids)
    if binding.nested_tt == true then
        runtime_stats.inc("nested_tt_trigger_hits")
        if binding.nested_tt_kind == "trigger_timer" then
            runtime_stats.inc("nested_tt_intermediate_jobs", #job_ids)
        elseif binding.nested_tt_kind == "timer_trigger" then
            runtime_stats.inc("nested_tt_final_jobs", #job_ids)
        end
    end
    if binding.payload_multicast == true then
        runtime_stats.inc("payload_multicast_jobs", #job_ids)
        runtime_stats.inc("payload_multicast_trigger_jobs", #job_ids)
        runtime_stats.inc("payload_multicast_runtime_ok")
    end
    if binding.payload_pattern == true then
        runtime_stats.inc("payload_pattern_jobs", #job_ids)
        runtime_stats.inc("payload_pattern_trigger_jobs", #job_ids)
        runtime_stats.inc("payload_pattern_runtime_ok")
        if binding.payload_pattern_kind == "Spread" then
            runtime_stats.inc("payload_pattern_spread_jobs", #job_ids)
        elseif binding.payload_pattern_kind == "Burst" then
            runtime_stats.inc("payload_pattern_burst_jobs", #job_ids)
        end
    end
    runtime_stats.max("chaos_budget_max_jobs_observed", #job_ids)
    runtime_stats.max("chaos_budget_max_projectiles_observed", #job_ids)
    runtime_stats.max("chaos_budget_max_queue_observed", orchestrator.queueLength())
    if #job_ids > limits.MAX_NESTED_PAYLOAD_FANOUT then
        runtime_stats.inc("chaos_budget_high_fanout_smoke")
        log.info(string.format(
            "SPELLFORGE_CHAOS_STRESS_OK profile=chaos observed_jobs=%d observed_projectiles=%d observed_queue=%d live_mode=trigger_payload fanout_count=%d",
            #job_ids,
            #job_ids,
            orchestrator.queueLength(),
            #job_ids
        ))
    end
    if binding.nested_final_fanout == true then
        runtime_stats.inc("nested_final_fanout_jobs", #job_ids)
        runtime_stats.inc("nested_final_fanout_trigger_jobs", #job_ids)
        runtime_stats.inc("nested_final_fanout_runtime_ok")
        if binding.payload_pattern_kind == "Spread" then
            runtime_stats.inc("nested_final_fanout_spread_jobs", #job_ids)
        elseif binding.payload_pattern_kind == "Burst" then
            runtime_stats.inc("nested_final_fanout_burst_jobs", #job_ids)
        end
    end
    local marker = binding.nested_final_fanout == true
        and "SPELLFORGE_NESTED_FINAL_FANOUT_TRIGGER_ENQUEUED"
        or binding.payload_pattern == true
        and "SPELLFORGE_PAYLOAD_PATTERN_TRIGGER_ENQUEUED"
        or binding.payload_multicast == true
        and "SPELLFORGE_PAYLOAD_MULTICAST_TRIGGER_ENQUEUED"
        or "SPELLFORGE_LIVE_TRIGGER_PAYLOAD_ENQUEUED"
    log.info(string.format(
        "%s recipe_id=%s cast_id=%s source_slot_id=%s payload_count=%s pattern_kind=%s route=%s first_job_id=%s",
        marker,
        tostring(binding.recipe_id),
        tostring(binding.cast_id),
        tostring(binding.source_slot_id),
        tostring(#job_ids),
        tostring(binding.payload_pattern_kind),
        tostring(trigger_route),
        tostring(job_ids[1])
    ))

    local tick = nil
    local jobs = {}
    for _ = 1, 3 do
        local all_settled = true
        for _, job_id in ipairs(job_ids) do
            local job = orchestrator.getJob(job_id)
            if not job or job.status == "queued" or job.status == "running" then
                all_settled = false
                break
            end
        end
        if all_settled then
            break
        end
        tick = orchestrator.tick({
            max_jobs_per_tick = tonumber(binding.max_jobs_per_tick) or limits.MAX_JOBS_PER_TICK,
            max_live_launches_per_tick = tonumber(binding.max_live_launches_per_tick) or limits.MAX_LIVE_LAUNCHES_PER_TICK,
        })
        if binding.allow_pending_launch_jobs == true
            and tick
            and tonumber(tick.live_launch_throttled_count) ~= nil
            and tonumber(tick.live_launch_throttled_count) > 0 then
            break
        end
    end

    local launch_ok = true
    local processed_count = 0
    local launch_ok_count = 0
    local pending_count = 0
    local projectile_ids = {}
    for index, job_id in ipairs(job_ids) do
        local job = orchestrator.getJob(job_id)
        local processed = job and job.status ~= "queued" and job.status ~= "running"
        if processed then
            processed_count = processed_count + 1
        end
        local job_ok = job and job.status == "complete" and job.launch_accepted == true
        local pending = job and (job.status == "queued" or job.status == "running")
        if job_ok then
            launch_ok_count = launch_ok_count + 1
            if job.projectile_id ~= nil then
                projectile_ids[#projectile_ids + 1] = job.projectile_id
            end
        elseif pending and binding.allow_pending_launch_jobs == true then
            pending_count = pending_count + 1
        else
            launch_ok = false
        end
        jobs[index] = {
            job_id = job_id,
            job_status = job and job.status or nil,
            slot_id = job and job.slot_id or nil,
            helper_engine_id = job and job.helper_engine_id or nil,
            cast_id = job and job.cast_id or nil,
            emission_index = job and job.emission_index or nil,
            group_index = job and job.group_index or nil,
            fanout_count = job and job.fanout_count or nil,
            root_source_slot_id = job and job.root_source_slot_id or nil,
            current_source_slot_id = job and job.current_source_slot_id or nil,
            parent_slot_id = job and job.parent_slot_id or nil,
            payload_depth = job and job.payload_depth or nil,
            nested_stage_kind = job and job.nested_stage_kind or nil,
            nested_stage_index = job and job.nested_stage_index or nil,
            pattern_kind = job and job.pattern_kind or nil,
            pattern_index = job and job.pattern_index or nil,
            pattern_count = job and job.pattern_count or nil,
            pattern_direction_key = job and job.pattern_direction_key or nil,
            nested_final_fanout = job and job.nested_final_fanout == true or false,
            nested_final_fanout_kind = job and job.nested_final_fanout_kind or nil,
            final_fanout_count = job and job.final_fanout_count or nil,
            final_fanout_index = job and job.final_fanout_index or nil,
            source_slot_id = job and job.source_slot_id or nil,
            source_helper_engine_id = job and job.source_helper_engine_id or nil,
            source_postfix_opcode = job and job.source_postfix_opcode or nil,
            payload_slot_id = job and job.payload_slot_id or nil,
            trigger_route = job and job.trigger_route or nil,
            trigger_duplicate_key = job and job.trigger_duplicate_key or nil,
            launch_accepted = job and job.launch_accepted == true or false,
            launch_direction = job and job.launch_direction or nil,
            projectile_id = job and job.projectile_id or nil,
            launch_user_data = job and job.launch_user_data or nil,
            error = job and job.error or nil,
        }
    end
    if processed_count > 0 then
        runtime_stats.inc("live_trigger_payload_jobs_processed", processed_count)
    end
    if launch_ok_count > 0 then
        runtime_stats.inc("live_trigger_payload_launch_ok", launch_ok_count)
        log.info(string.format(
            "SPELLFORGE_LIVE_TRIGGER_PAYLOAD_OK recipe_id=%s cast_id=%s source_slot_id=%s payload_count=%s launch_ok_count=%s first_projectile_id=%s",
            tostring(binding.recipe_id),
            tostring(binding.cast_id),
            tostring(binding.source_slot_id),
            tostring(#payloads),
            tostring(launch_ok_count),
            tostring(projectile_ids[1])
        ))
    end
    if not launch_ok then
        runtime_stats.inc("live_trigger_payload_launch_failed", #payloads - launch_ok_count)
        runtime_stats.inc("live_trigger_payload_route_failed")
    end

    local nested_timer_schedule = nil
    if launch_ok and binding.nested_tt == true and binding.nested_tt_kind == "trigger_timer" then
        if options.force_timer_enabled ~= true and not dev.liveTimerEnabled() then
            runtime_stats.inc("nested_tt_rejected")
            runtime_stats.inc("nested_tt_disabled_reject")
            return { ok = false, error = "nested Trigger->Timer requires live Timer enabled" }
        end
        local nested_binding = binding.nested_timer_binding
        local first_payload = payloads[1]
        if type(nested_binding) ~= "table" or not first_payload then
            runtime_stats.inc("nested_tt_rejected")
            return { ok = false, error = "nested Trigger->Timer binding missing" }
        end
        nested_binding.actor = actor
        nested_binding.hit_object = route.target
        nested_binding.source_job_id = job_ids[1]
        nested_binding.source_depth = 1
        nested_binding.resolution = {
            timer_start_pos = start_pos,
            timer_direction = first_payload.direction or direction,
            resolution_pos = start_pos,
            resolution_kind = "trigger_hit",
            resolution_hit_object = route.target,
        }
        nested_timer_schedule = live_timer.schedulePayload(nested_binding, {
            duplicate_key_suffix = nested_binding.duplicate_key_suffix,
        })
        if not nested_timer_schedule.ok then
            runtime_stats.inc("nested_tt_rejected")
            return { ok = false, error = nested_timer_schedule.error or "nested Trigger->Timer schedule failed" }
        end
        log.info(string.format(
            "SPELLFORGE_NESTED_TRIGGER_TIMER_INTERMEDIATE_ENQUEUED recipe_id=%s cast_id=%s root_source_slot_id=%s current_source_slot_id=%s intermediate_slot_id=%s final_payload_slot_id=%s payload_depth=1 stage_kind=Trigger->Timer job_count=%s",
            tostring(binding.recipe_id),
            tostring(binding.cast_id),
            tostring(binding.root_source_slot_id or binding.source_slot_id),
            tostring(binding.source_slot_id),
            tostring(binding.payload_slot_id),
            tostring(nested_binding.payload_slot_id),
            tostring(#job_ids)
        ))
    elseif launch_ok and binding.nested_tt == true and binding.nested_tt_kind == "timer_trigger" then
        runtime_stats.inc("nested_tt_runtime_ok")
        log.info(string.format(
            "SPELLFORGE_NESTED_TIMER_TRIGGER_FINAL_ENQUEUED recipe_id=%s cast_id=%s root_source_slot_id=%s current_source_slot_id=%s final_payload_slot_id=%s payload_depth=2 job_count=%s",
            tostring(binding.recipe_id),
            tostring(binding.cast_id),
            tostring(binding.root_source_slot_id or binding.source_slot_id),
            tostring(binding.source_slot_id),
            tostring(binding.payload_slot_id),
            tostring(#job_ids)
        ))
    end

    return {
        ok = launch_ok == true,
        error = launch_ok and nil or "trigger payload job did not complete",
        source_slot_id = binding.source_slot_id,
        source_helper_engine_id = binding.source_helper_engine_id,
        payload_slot_id = binding.payload_slot_id,
        payload_helper_engine_id = binding.payload_helper_engine_id,
        payload_slot_ids = payloadSlotIds(payloads),
        payload_count = #payloads,
        payload_multicast = binding.payload_multicast == true,
        payload_pattern = binding.payload_pattern == true,
        payload_pattern_kind = binding.payload_pattern_kind,
        payload_pattern_direction_keys = pattern_info and pattern_info.direction_keys or nil,
        nested_final_fanout = binding.nested_final_fanout == true,
        nested_final_fanout_kind = binding.nested_final_fanout_kind,
        duplicate_key = key,
        trigger_route = trigger_route,
        job_id = job_ids[1],
        job_ids = job_ids,
        jobs = jobs,
        job_status = jobs[1] and jobs[1].job_status or nil,
        launch_accepted = launch_ok == true,
        launch_count = launch_ok_count,
        pending_launch_jobs = pending_count > 0,
        pending_job_count = pending_count,
        all_launch_jobs_complete = pending_count == 0,
        projectile_id = projectile_ids[1],
        projectile_ids = projectile_ids,
        launch_user_data = jobs[1] and jobs[1].launch_user_data or nil,
        tick = tick,
        nested_tt = binding.nested_tt == true,
        nested_tt_kind = binding.nested_tt_kind,
        nested_timer_schedule = nested_timer_schedule,
    }
end

function live_trigger.handleHitPayload(payload, opts)
    runtime_stats.inc("hits_seen")
    local route = runtime_hits.resolveHelperHit(payload)
    if not route.ok then
        return {
            ok = false,
            route = route,
            error = route.error,
        }
    end
    local result = live_trigger.handleResolvedHit(route, opts)
    result.route = route
    return result
end

function live_trigger.clearForTests()
    bindings_by_cast_source = {}
    bindings_by_latest_source = {}
    binding_order = {}
    duplicate_keys = {}
    duplicate_order = {}
end

return live_trigger
