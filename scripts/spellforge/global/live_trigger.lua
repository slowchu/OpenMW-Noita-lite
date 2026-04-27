local dev = require("scripts.spellforge.shared.dev")
local limits = require("scripts.spellforge.shared.limits")
local log = require("scripts.spellforge.shared.log").new("global.live_trigger")
local helper_records = require("scripts.spellforge.global.helper_records")
local orchestrator = require("scripts.spellforge.global.orchestrator")
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

function live_trigger.selectV0Plan(plan)
    if type(plan) ~= "table" then
        return rejectSelect("missing_plan")
    end
    local bounds = plan.bounds or {}
    if bounds.has_timer then
        return rejectSelect("has_timer")
    end
    if bounds.has_chain then
        return rejectSelect("has_chain")
    end
    if bounds.has_multicast then
        return rejectSelect("has_multicast")
    end
    if bounds.has_pattern then
        return rejectSelect("has_pattern")
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
    if #slots ~= 2 then
        return rejectSelect("trigger_v0_slot_count_not_two")
    end
    if #helpers ~= 2 then
        return rejectSelect("trigger_v0_helper_count_not_two")
    end

    local source_slot = nil
    local payload_slot = nil
    for _, slot in ipairs(slots) do
        if slot.kind == "primary_emission" then
            if source_slot then
                return rejectSelect("multiple_trigger_sources")
            end
            source_slot = slot
        elseif slot.kind == "payload_emission" then
            if payload_slot then
                return rejectSelect("multiple_trigger_payloads")
            end
            payload_slot = slot
        else
            return rejectSelect("unknown_slot_kind")
        end
    end

    if not source_slot then
        return rejectSelect("missing_trigger_source_slot")
    end
    if not payload_slot then
        return rejectSelect("missing_trigger_payload_slot", "live_trigger_payload_missing")
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

    if payload_slot.parent_slot_id ~= source_slot.slot_id then
        return rejectSelect("payload_parent_mismatch", "live_trigger_payload_missing")
    end
    if payload_slot.trigger_source_slot_id ~= source_slot.slot_id then
        return rejectSelect("payload_trigger_source_mismatch", "live_trigger_payload_missing")
    end
    if payload_slot.source_postfix_opcode ~= "Trigger" then
        return rejectSelect("payload_not_trigger")
    end
    if payload_slot.timer_source_slot_id ~= nil then
        return rejectSelect("payload_timer_source_rejected")
    end
    if hasOps(payload_slot.prefix_ops) then
        return rejectSelect("payload_prefix_ops_rejected")
    end
    if hasOps(payload_slot.postfix_ops) then
        return rejectSelect("payload_postfix_ops_rejected")
    end
    if hasPayloadBindings(payload_slot.payload_bindings) then
        return rejectSelect("payload_nested_binding_rejected")
    end

    local helpers_by_slot = helperBySlotId(helpers)
    local source_helper = helpers_by_slot[source_slot.slot_id]
    local payload_helper = helpers_by_slot[payload_slot.slot_id]
    if not source_helper or type(source_helper.engine_id) ~= "string" or source_helper.engine_id == "" then
        return rejectSelect("source_helper_missing")
    end
    if not payload_helper or type(payload_helper.engine_id) ~= "string" or payload_helper.engine_id == "" then
        return rejectSelect("payload_helper_missing", "live_trigger_payload_missing")
    end
    if source_helper.parent_slot_id ~= nil or source_helper.source_postfix_opcode ~= nil then
        return rejectSelect("source_helper_not_primary")
    end
    if not slotHasOneTriggerBinding(source_helper) then
        return rejectSelect("source_helper_trigger_binding_missing", "live_trigger_payload_missing")
    end
    if payload_helper.parent_slot_id ~= source_slot.slot_id
        or payload_helper.trigger_source_slot_id ~= source_slot.slot_id
        or payload_helper.source_postfix_opcode ~= "Trigger" then
        return rejectSelect("payload_helper_trigger_mapping_mismatch", "live_trigger_payload_missing")
    end
    if hasOps(payload_helper.prefix_ops) or hasOps(payload_helper.postfix_ops) or hasPayloadBindings(payload_helper.payload_bindings) then
        return rejectSelect("payload_helper_not_simple")
    end

    return {
        source = {
            slot = source_slot,
            helper = source_helper,
        },
        payload = {
            slot = payload_slot,
            helper = payload_helper,
        },
        source_slot_id = source_slot.slot_id,
        source_helper_engine_id = source_helper.engine_id,
        payload_slot_id = payload_slot.slot_id,
        payload_helper_engine_id = payload_helper.engine_id,
        payload_effect_id = firstEffectId(payload_helper),
    }, nil
end

function live_trigger.decorateSourceJob(job, binding)
    if type(job) ~= "table" or type(binding) ~= "table" then
        return
    end
    job.source_postfix_opcode = "Trigger"
    job.trigger_source_slot_id = binding.source_slot_id
    job.trigger_payload_slot_id = binding.payload_slot_id
    job.has_trigger_payload = true
    job.payload = job.payload or {}
    job.payload.source_slot_id = binding.source_slot_id
    job.payload.source_helper_engine_id = binding.source_helper_engine_id
    job.payload.source_postfix_opcode = "Trigger"
    job.payload.trigger_source_slot_id = binding.source_slot_id
    job.payload.trigger_payload_slot_id = binding.payload_slot_id
    job.payload.has_trigger_payload = true
end

function live_trigger.registerBinding(binding)
    local input = binding or {}
    if type(input.recipe_id) ~= "string" or input.recipe_id == ""
        or type(input.source_slot_id) ~= "string" or input.source_slot_id == ""
        or type(input.payload_slot_id) ~= "string" or input.payload_slot_id == "" then
        return false
    end

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
    return string.format(
        "trigger:%s:%s:%s:%s:%s:%s",
        tostring(binding.cast_id or (route.user_data and route.user_data.cast_id) or "no-cast"),
        tostring(binding.recipe_id or route.recipe_id),
        tostring(binding.source_slot_id or route.slot_id),
        tostring(binding.payload_slot_id),
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
        }
    end

    local payload_mapping = helper_records.getByRecipeSlot(binding.recipe_id, binding.payload_slot_id)
        or helper_records.getByEngineId(binding.payload_helper_engine_id)
    if not payload_mapping or payload_mapping.engine_id ~= binding.payload_helper_engine_id then
        runtime_stats.inc("live_trigger_payload_missing")
        runtime_stats.inc("live_trigger_payload_route_failed")
        return { ok = false, error = "trigger payload helper mapping missing" }
    end
    if payload_mapping.source_postfix_opcode ~= "Trigger"
        or payload_mapping.trigger_source_slot_id ~= binding.source_slot_id then
        runtime_stats.inc("live_trigger_payload_route_failed")
        return { ok = false, error = "trigger payload helper mapping mismatch" }
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

    local trigger_route = route.source or "unknown"
    local enqueue = orchestrator.enqueue({
        kind = orchestrator.LIVE_TRIGGER_PAYLOAD_JOB_KIND,
        recipe_id = binding.recipe_id,
        slot_id = binding.payload_slot_id,
        helper_engine_id = binding.payload_helper_engine_id,
        idempotency_key = key,
        source_job_id = binding.source_job_id,
        parent_job_id = binding.source_job_id,
        depth = payload_depth,
        cast_id = binding.cast_id,
        payload = {
            actor = actor,
            start_pos = start_pos,
            direction = direction,
            hit_object = route.target,
            cast_id = binding.cast_id,
            source_slot_id = binding.source_slot_id,
            source_helper_engine_id = binding.source_helper_engine_id,
            source_postfix_opcode = "Trigger",
            payload_slot_id = binding.payload_slot_id,
            trigger_source_slot_id = binding.source_slot_id,
            trigger_payload_slot_id = binding.payload_slot_id,
            trigger_route = trigger_route,
            trigger_duplicate_key = shortKey(key),
        },
    })
    if not enqueue.ok then
        runtime_stats.inc("live_trigger_payload_route_failed")
        return { ok = false, error = enqueue.error or "trigger payload enqueue failed" }
    end

    rememberDuplicateKey(key)
    runtime_stats.inc("live_trigger_payload_jobs_enqueued")
    log.info(string.format(
        "SPELLFORGE_LIVE_TRIGGER_PAYLOAD_ENQUEUED recipe_id=%s cast_id=%s source_slot_id=%s payload_slot_id=%s route=%s job_id=%s",
        tostring(binding.recipe_id),
        tostring(binding.cast_id),
        tostring(binding.source_slot_id),
        tostring(binding.payload_slot_id),
        tostring(trigger_route),
        tostring(enqueue.job_id)
    ))

    local tick = nil
    local job = nil
    for _ = 1, 3 do
        job = orchestrator.getJob(enqueue.job_id)
        if job and job.status ~= "queued" and job.status ~= "running" then
            break
        end
        tick = orchestrator.tick({ max_jobs_per_tick = limits.MAX_JOBS_PER_TICK })
    end
    job = orchestrator.getJob(enqueue.job_id)
    local processed = job and job.status ~= "queued" and job.status ~= "running"
    if processed then
        runtime_stats.inc("live_trigger_payload_jobs_processed")
    end
    local launch_ok = job and job.status == "complete" and job.launch_accepted == true
    if launch_ok then
        runtime_stats.inc("live_trigger_payload_launch_ok")
        log.info(string.format(
            "SPELLFORGE_LIVE_TRIGGER_PAYLOAD_OK recipe_id=%s cast_id=%s source_slot_id=%s payload_slot_id=%s helper_engine_id=%s projectile_id=%s",
            tostring(binding.recipe_id),
            tostring(binding.cast_id),
            tostring(binding.source_slot_id),
            tostring(binding.payload_slot_id),
            tostring(binding.payload_helper_engine_id),
            tostring(job.projectile_id)
        ))
    else
        runtime_stats.inc("live_trigger_payload_launch_failed")
        runtime_stats.inc("live_trigger_payload_route_failed")
    end

    return {
        ok = launch_ok == true,
        error = launch_ok and nil or (job and job.error or "trigger payload job did not complete"),
        source_slot_id = binding.source_slot_id,
        source_helper_engine_id = binding.source_helper_engine_id,
        payload_slot_id = binding.payload_slot_id,
        payload_helper_engine_id = binding.payload_helper_engine_id,
        duplicate_key = key,
        trigger_route = trigger_route,
        job_id = enqueue.job_id,
        job_status = job and job.status or nil,
        launch_accepted = job and job.launch_accepted == true or false,
        projectile_id = job and job.projectile_id or nil,
        launch_user_data = job and job.launch_user_data or nil,
        tick = tick,
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
