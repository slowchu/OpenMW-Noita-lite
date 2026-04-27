local async = require("openmw.async")

local limits = require("scripts.spellforge.shared.limits")
local log = require("scripts.spellforge.shared.log").new("global.live_timer")
local helper_records = require("scripts.spellforge.global.helper_records")
local orchestrator = require("scripts.spellforge.global.orchestrator")
local runtime_stats = require("scripts.spellforge.global.runtime_stats")
local sfp_adapter = require("scripts.spellforge.global.sfp_adapter")

local live_timer = {}

local TIMER_TICKS_PER_SECOND = 2
local DEFAULT_TIMER_SECONDS = 1.0
local DEFAULT_TIMER_PROJECTILE_SPEED = 1000
local MAX_TIMER_SECONDS = 5.0
local TIMER_EXPIRY_GRACE_TICKS = 4
local TIMER_EXPIRY_GRACE_SECONDS = TIMER_EXPIRY_GRACE_TICKS / TIMER_TICKS_PER_SECOND
local TIMER_CALLBACK_NAME = "spellforge_live_timer_due"
local MAX_SCHEDULE_KEYS = 256
local MAX_PENDING_TIMERS = 128
local MAX_TIMER_RESULTS = 128

local schedule_keys = {}
local schedule_order = {}
local timer_id_by_key = {}
local pending_timers = {}
local pending_order = {}
local timer_results = {}
local timer_result_order = {}
local timer_callback = nil
local next_timer_sequence = 1

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

local function slotHasOneTimerBinding(slot)
    local bindings = slot and slot.payload_bindings
    if type(bindings) ~= "table" or #bindings ~= 1 then
        return false
    end
    return bindings[1] and bindings[1].source_opcode == "Timer"
end

local function postfixIsOnlyTimer(slot)
    local ops = slot and slot.postfix_ops
    return type(ops) == "table" and #ops == 1 and ops[1].opcode == "Timer"
end

local function rejectSelect(reason, counter_name)
    if counter_name then
        runtime_stats.inc(counter_name)
    end
    return nil, reason
end

local function timerDelayFromOp(op)
    local raw_seconds = op and op.params and op.params.seconds
    local seconds = raw_seconds == nil and DEFAULT_TIMER_SECONDS or tonumber(raw_seconds)
    if seconds == nil or seconds ~= seconds or seconds < 0 then
        runtime_stats.inc("live_timer_delay_invalid")
        return nil, nil, false, "timer_delay_invalid"
    end

    local capped = false
    if seconds > MAX_TIMER_SECONDS then
        seconds = MAX_TIMER_SECONDS
        capped = true
        runtime_stats.inc("live_timer_delay_capped")
    end

    local ticks = math.ceil(seconds * TIMER_TICKS_PER_SECOND)
    if ticks < 1 then
        ticks = 1
    end
    return seconds, ticks, capped, nil
end

function live_timer.selectV0Plan(plan)
    if type(plan) ~= "table" then
        return rejectSelect("missing_plan")
    end
    local bounds = plan.bounds or {}
    if bounds.has_trigger then
        return rejectSelect("has_trigger")
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
    if not postfixIsOnlyTimer(group) then
        return rejectSelect("source_not_timer")
    end
    if not group.payload or type(group.payload.effects) ~= "table" or #group.payload.effects == 0 then
        return rejectSelect("missing_timer_payload", "live_timer_payload_missing")
    end

    local timer_seconds, timer_delay_ticks, delay_capped, delay_error = timerDelayFromOp(group.postfix_ops[1])
    if delay_error then
        return rejectSelect(delay_error)
    end

    local slots = plan.emission_slots or {}
    local helpers = plan.helper_records or {}
    if #slots ~= 2 then
        return rejectSelect("timer_v0_slot_count_not_two")
    end
    if #helpers ~= 2 then
        return rejectSelect("timer_v0_helper_count_not_two")
    end

    local source_slot = nil
    local payload_slot = nil
    for _, slot in ipairs(slots) do
        if slot.kind == "primary_emission" then
            if source_slot then
                return rejectSelect("multiple_timer_sources")
            end
            source_slot = slot
        elseif slot.kind == "payload_emission" then
            if payload_slot then
                return rejectSelect("multiple_timer_payloads")
            end
            payload_slot = slot
        else
            return rejectSelect("unknown_slot_kind")
        end
    end

    if not source_slot then
        return rejectSelect("missing_timer_source_slot")
    end
    if not payload_slot then
        return rejectSelect("missing_timer_payload_slot", "live_timer_payload_missing")
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
    if not postfixIsOnlyTimer(source_slot) then
        return rejectSelect("source_slot_not_timer")
    end
    if not slotHasOneTimerBinding(source_slot) then
        return rejectSelect("source_timer_binding_missing", "live_timer_payload_missing")
    end

    if payload_slot.parent_slot_id ~= source_slot.slot_id then
        return rejectSelect("payload_parent_mismatch", "live_timer_payload_missing")
    end
    if payload_slot.timer_source_slot_id ~= source_slot.slot_id then
        return rejectSelect("payload_timer_source_mismatch", "live_timer_payload_missing")
    end
    if payload_slot.source_postfix_opcode ~= "Timer" then
        return rejectSelect("payload_not_timer")
    end
    if payload_slot.trigger_source_slot_id ~= nil then
        return rejectSelect("payload_trigger_source_rejected")
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
        return rejectSelect("payload_helper_missing", "live_timer_payload_missing")
    end
    if source_helper.parent_slot_id ~= nil or source_helper.source_postfix_opcode ~= nil then
        return rejectSelect("source_helper_not_primary")
    end
    if not slotHasOneTimerBinding(source_helper) then
        return rejectSelect("source_helper_timer_binding_missing", "live_timer_payload_missing")
    end
    if payload_helper.parent_slot_id ~= source_slot.slot_id
        or payload_helper.timer_source_slot_id ~= source_slot.slot_id
        or payload_helper.source_postfix_opcode ~= "Timer" then
        return rejectSelect("payload_helper_timer_mapping_mismatch", "live_timer_payload_missing")
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
        timer_seconds = timer_seconds,
        timer_delay_ticks = timer_delay_ticks,
        timer_delay_capped = delay_capped == true,
        timer_ticks_per_second = TIMER_TICKS_PER_SECOND,
    }, nil
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
        return nil, "timer direction is missing"
    end
    local ok, normalized, original_length = pcall(function()
        return direction:normalize()
    end)
    if not ok or normalized == nil then
        return nil, "timer direction is not a vector"
    end
    original_length = tonumber(original_length) or safeVectorLength(direction)
    if original_length == nil or original_length <= 0.0001 then
        return nil, "timer direction has zero length"
    end
    return normalized, nil
end

function live_timer.computeResolution(launch_payload, timer_plan)
    local start_pos = launch_payload and launch_payload.start_pos or nil
    if start_pos == nil then
        return nil, "missing Timer source start_pos"
    end

    local direction, direction_error = normalizeDirection(launch_payload and launch_payload.direction or nil)
    if not direction then
        return nil, direction_error
    end

    local timer_seconds = tonumber(timer_plan and timer_plan.timer_seconds) or 0
    local projectile_speed = tonumber(launch_payload and launch_payload.timer_projectile_speed) or DEFAULT_TIMER_PROJECTILE_SPEED
    if projectile_speed <= 0 then
        return nil, "Timer projectile speed must be positive"
    end

    local travel_distance = projectile_speed * timer_seconds
    local endpoint = start_pos + (direction * travel_distance)
    local resolution_pos = endpoint
    local resolution_kind = "endpoint_no_raycast"
    local resolution_hit_object = nil

    local hint = launch_payload and launch_payload.timer_raycast or nil
    if type(hint) == "table" and hint.available == true then
        if hint.hit == true and hint.hit_pos ~= nil then
            local hit_distance = safeVectorDistance(start_pos, hint.hit_pos)
            if hit_distance ~= nil and hit_distance <= travel_distance + 4 then
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
        timer_start_pos = start_pos,
        timer_direction = direction,
        timer_endpoint = endpoint,
        timer_projectile_speed = projectile_speed,
        timer_travel_distance = travel_distance,
        resolution_pos = resolution_pos,
        resolution_kind = resolution_kind,
        resolution_hit_object = resolution_hit_object,
    }, nil
end

function live_timer.decorateSourceJob(job, binding)
    if type(job) ~= "table" or type(binding) ~= "table" then
        return
    end
    job.source_postfix_opcode = "Timer"
    job.timer_source_slot_id = binding.source_slot_id
    job.timer_payload_slot_id = binding.payload_slot_id
    job.has_timer_payload = true
    job.payload = job.payload or {}
    job.payload.source_slot_id = binding.source_slot_id
    job.payload.source_helper_engine_id = binding.source_helper_engine_id
    job.payload.source_postfix_opcode = "Timer"
    job.payload.timer_source_slot_id = binding.source_slot_id
    job.payload.timer_payload_slot_id = binding.payload_slot_id
    job.payload.has_timer_payload = true
    job.payload.timer_delay_ticks = binding.timer_delay_ticks
    job.payload.timer_delay_seconds = binding.timer_seconds
    job.payload.timer_delay_semantics = "async_simulation_timer"
end

function live_timer.sourceDetonationAudit(opts)
    local options = opts or {}
    local caps = sfp_adapter.capabilities()
    local projectile_state = options.projectile_state
    local projectile_id = options.projectile_id
    local source_spell_id = options.source_spell_id or options.spellId
    local caster = options.caster or options.actor
    local has_projectile_id = type(projectile_id) == "string" and projectile_id ~= ""
    local has_source_spell_id = type(source_spell_id) == "string" and source_spell_id ~= ""
    local has_caster = caster ~= nil
    local has_position = type(projectile_state) == "table"
        and (projectile_state.position ~= nil or projectile_state.pos ~= nil)
    local has_cell = type(projectile_state) == "table" and projectile_state.cell ~= nil
    local can_detonate = caps.has_detonateSpellAtPos == true
        and caps.has_cancelSpell == true
        and has_projectile_id
        and has_position
        and has_cell
    local blocker = nil
    if not can_detonate then
        blocker = "Timer source detonation requires current projectile position/cell; cancelSpell can remove by projectile id, but detonateSpellAtPos requires position/cell and Spellforge does not currently maintain that state at Timer maturity."
    end
    return {
        status = can_detonate and "implementable" or "blocked",
        blocker = blocker,
        cancelSpell_available = caps.has_cancelSpell == true,
        detonateSpellAtPos_available = caps.has_detonateSpellAtPos == true,
        getSpellState_available = caps.has_getSpellState == true,
        projectile_id_available = has_projectile_id,
        source_spell_id_available = has_source_spell_id,
        caster_available = has_caster,
        projectile_position_available = has_position == true,
        projectile_cell_available = has_cell == true,
    }
end

local function duplicateKey(binding, opts)
    local suffix = opts and opts.duplicate_key_suffix or nil
    local delay_ticks = opts and opts.delay_ticks_override or binding.timer_delay_ticks
    local delay_seconds = opts and opts.delay_seconds_override or binding.timer_seconds
    local key = string.format(
        "timer:%s:%s:%s:%s:%s:%s:%s",
        tostring(binding.cast_id or "no-cast"),
        tostring(binding.recipe_id),
        tostring(binding.source_slot_id),
        tostring(binding.payload_slot_id),
        tostring(binding.source_helper_engine_id),
        tostring(delay_ticks),
        tostring(delay_seconds)
    )
    if suffix ~= nil then
        key = key .. ":" .. tostring(suffix)
    end
    return key
end

local function rememberScheduleKey(key)
    schedule_keys[key] = true
    appendBounded(schedule_order, key, MAX_SCHEDULE_KEYS, function(evicted)
        schedule_keys[evicted] = nil
        timer_id_by_key[evicted] = nil
    end)
end

local function shortKey(key)
    if type(key) == "string" and #key <= 180 then
        return key
    end
    return nil
end

local function finiteNonNegative(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge or n < 0 then
        return nil
    end
    return n
end

local function pendingCount()
    local count = 0
    for _ in pairs(pending_timers) do
        count = count + 1
    end
    return count
end

local function rememberTimerResult(result)
    if type(result) ~= "table" or type(result.timer_id) ~= "string" then
        return
    end
    timer_results[result.timer_id] = result
    appendBounded(timer_result_order, result.timer_id, MAX_TIMER_RESULTS, function(evicted)
        timer_results[evicted] = nil
    end)
end

local function nextTimerId(binding)
    local sequence = next_timer_sequence
    next_timer_sequence = next_timer_sequence + 1
    return string.format(
        "timer:%s:%s:%s:%d",
        tostring(binding.cast_id or "no-cast"),
        tostring(binding.source_slot_id or "no-source"),
        tostring(binding.payload_slot_id or "no-payload"),
        sequence
    )
end

local function rememberPendingTimer(data)
    if type(data) ~= "table" or type(data.timer_id) ~= "string" then
        return
    end
    pending_timers[data.timer_id] = data
    if type(data.duplicate_key) == "string" then
        timer_id_by_key[data.duplicate_key] = data.timer_id
    end
    appendBounded(pending_order, data.timer_id, MAX_PENDING_TIMERS, function(evicted)
        pending_timers[evicted] = nil
    end)
    runtime_stats.max("live_timer_async_pending", pendingCount())
end

local function clearPendingTimer(timer_id)
    if type(timer_id) ~= "string" then
        return
    end
    if pending_timers[timer_id] ~= nil then
        pending_timers[timer_id] = nil
        runtime_stats.inc("live_timer_async_pending_cleared")
    end
end

local function validateTimerData(data)
    if type(data) ~= "table" then
        return nil, "timer data missing"
    end
    if type(data.timer_id) ~= "string" or data.timer_id == "" then
        return nil, "timer_id missing"
    end
    if type(data.recipe_id) ~= "string" or data.recipe_id == "" then
        return nil, "recipe_id missing"
    end
    if type(data.cast_id) ~= "string" or data.cast_id == "" then
        return nil, "cast_id missing"
    end
    if type(data.source_slot_id) ~= "string" or data.source_slot_id == "" then
        return nil, "source_slot_id missing"
    end
    if type(data.payload_slot_id) ~= "string" or data.payload_slot_id == "" then
        return nil, "payload_slot_id missing"
    end
    if type(data.source_helper_engine_id) ~= "string" or data.source_helper_engine_id == "" then
        return nil, "source_helper_engine_id missing"
    end
    if type(data.payload_helper_engine_id) ~= "string" or data.payload_helper_engine_id == "" then
        return nil, "payload_helper_engine_id missing"
    end
    if data.actor == nil then
        return nil, "caster missing"
    end
    if data.start_pos == nil then
        return nil, "start_pos missing"
    end
    if data.direction == nil then
        return nil, "direction missing"
    end

    local payload_depth = tonumber(data.depth) or 0
    if payload_depth > limits.MAX_RECURSION_DEPTH then
        return nil, "timer payload depth exceeds MAX_RECURSION_DEPTH"
    end
    local ttl_seconds = finiteNonNegative(data.ttl_seconds)
    local delay_seconds = finiteNonNegative(data.delay_seconds) or 0
    if ttl_seconds ~= nil and ttl_seconds < delay_seconds then
        return nil, "timer expired before callback"
    end

    local payload_mapping = helper_records.getByRecipeSlot(data.recipe_id, data.payload_slot_id)
        or helper_records.getByEngineId(data.payload_helper_engine_id)
    if not payload_mapping or payload_mapping.engine_id ~= data.payload_helper_engine_id then
        return nil, "timer payload helper mapping missing"
    end
    if payload_mapping.source_postfix_opcode ~= "Timer"
        or payload_mapping.timer_source_slot_id ~= data.source_slot_id then
        return nil, "timer payload helper mapping mismatch"
    end

    return {
        payload_depth = payload_depth,
        payload_mapping = payload_mapping,
    }, nil
end

local function enqueuePayloadFromTimer(data)
    local validated, validation_error = validateTimerData(data)
    if not validated then
        runtime_stats.inc("live_timer_payload_route_failed")
        rememberTimerResult({
            timer_id = data and data.timer_id or "unknown",
            ok = false,
            error = validation_error,
            status = "validation_failed",
        })
        return { ok = false, error = validation_error }
    end

    local enqueue = orchestrator.enqueue({
        kind = orchestrator.LIVE_TIMER_PAYLOAD_JOB_KIND,
        recipe_id = data.recipe_id,
        slot_id = data.payload_slot_id,
        helper_engine_id = data.payload_helper_engine_id,
        idempotency_key = data.duplicate_key,
        source_job_id = data.source_job_id,
        parent_job_id = data.source_job_id,
        depth = validated.payload_depth,
        cast_id = data.cast_id,
        timer_async = true,
        timer_id = data.timer_id,
        source_slot_id = data.source_slot_id,
        source_helper_engine_id = data.source_helper_engine_id,
        source_postfix_opcode = "Timer",
        payload_slot_id = data.payload_slot_id,
        timer_source_slot_id = data.source_slot_id,
        timer_payload_slot_id = data.payload_slot_id,
        timer_delay_ticks = data.delay_ticks,
        timer_delay_seconds = data.delay_seconds,
        timer_scheduled_tick = data.scheduled_tick,
        timer_due_tick = data.due_tick,
        timer_scheduled_seconds = data.scheduled_seconds,
        timer_due_seconds = data.due_seconds,
        timer_delay_semantics = "async_simulation_timer",
        timer_duplicate_key = shortKey(data.duplicate_key),
        payload = {
            actor = data.actor,
            start_pos = data.start_pos,
            direction = data.direction,
            hit_object = data.hit_object,
            cast_id = data.cast_id,
            source_slot_id = data.source_slot_id,
            source_helper_engine_id = data.source_helper_engine_id,
            source_postfix_opcode = "Timer",
            payload_slot_id = data.payload_slot_id,
            timer_source_slot_id = data.source_slot_id,
            timer_payload_slot_id = data.payload_slot_id,
            timer_id = data.timer_id,
            timer_delay_ticks = data.delay_ticks,
            timer_delay_seconds = data.delay_seconds,
            timer_scheduled_tick = data.scheduled_tick,
            timer_due_tick = data.due_tick,
            timer_scheduled_seconds = data.scheduled_seconds,
            timer_due_seconds = data.due_seconds,
            timer_delay_semantics = "async_simulation_timer",
            timer_duplicate_key = shortKey(data.duplicate_key),
        },
    })
    if not enqueue.ok then
        runtime_stats.inc("live_timer_payload_route_failed")
        rememberTimerResult({
            timer_id = data.timer_id,
            ok = false,
            error = enqueue.error or "timer payload enqueue failed",
            status = "enqueue_failed",
        })
        return { ok = false, error = enqueue.error or "timer payload enqueue failed" }
    end

    runtime_stats.inc("live_timer_async_payload_enqueued")
    runtime_stats.inc("live_timer_payload_jobs_enqueued")
    rememberTimerResult({
        timer_id = data.timer_id,
        ok = true,
        status = "payload_enqueued",
        job_id = enqueue.job_id,
        cast_id = data.cast_id,
        source_slot_id = data.source_slot_id,
        source_helper_engine_id = data.source_helper_engine_id,
        payload_slot_id = data.payload_slot_id,
        payload_helper_engine_id = data.payload_helper_engine_id,
    })
    log.info(string.format(
        "SPELLFORGE_LIVE_TIMER_ASYNC_PAYLOAD_ENQUEUED timer_id=%s job_id=%s cast_id=%s payload_slot_id=%s",
        tostring(data.timer_id),
        tostring(enqueue.job_id),
        tostring(data.cast_id),
        tostring(data.payload_slot_id)
    ))
    return {
        ok = true,
        job_id = enqueue.job_id,
        timer_id = data.timer_id,
    }
end

local function onAsyncTimerDue(data)
    local timer_id = type(data) == "table" and data.timer_id or nil
    local found = timer_id ~= nil and pending_timers[timer_id] ~= nil
    runtime_stats.inc("live_timer_async_callback_seen")
    if not found then
        runtime_stats.inc("live_timer_async_callback_missing")
    end
    clearPendingTimer(timer_id)
    runtime_stats.inc("live_timer_wait_jobs_processed")
    runtime_stats.inc("live_timer_real_delay_matured")
    log.info(string.format(
        "SPELLFORGE_LIVE_TIMER_ASYNC_CALLBACK timer_id=%s found=%s",
        tostring(timer_id),
        tostring(found)
    ))
    return enqueuePayloadFromTimer(data)
end

function live_timer.registerCallbacks()
    if timer_callback ~= nil then
        return timer_callback
    end
    timer_callback = async:registerTimerCallback(TIMER_CALLBACK_NAME, onAsyncTimerDue) or TIMER_CALLBACK_NAME
    return timer_callback
end

function live_timer.schedulePayload(binding, opts)
    local options = opts or {}
    -- Timer source detonation is intentionally not implemented in v0.
    -- SFP cancelSpell can remove by projectile id, but it does not detonate by id.
    -- Future timed detonation needs current projectile position/cell, then
    -- detonateSpellAtPos(...) at that position and cancelSpell(projectile_id).
    if type(binding) ~= "table" then
        runtime_stats.inc("live_timer_payload_route_failed")
        return { ok = false, error = "missing timer binding" }
    end

    local payload_mapping = helper_records.getByRecipeSlot(binding.recipe_id, binding.payload_slot_id)
        or helper_records.getByEngineId(binding.payload_helper_engine_id)
    if not payload_mapping or payload_mapping.engine_id ~= binding.payload_helper_engine_id then
        runtime_stats.inc("live_timer_payload_missing")
        runtime_stats.inc("live_timer_payload_route_failed")
        return { ok = false, error = "timer payload helper mapping missing" }
    end
    if payload_mapping.source_postfix_opcode ~= "Timer"
        or payload_mapping.timer_source_slot_id ~= binding.source_slot_id then
        runtime_stats.inc("live_timer_payload_route_failed")
        return { ok = false, error = "timer payload helper mapping mismatch" }
    end

    local payload_depth = tonumber(binding.source_depth or 0) + 1
    if payload_depth > limits.MAX_RECURSION_DEPTH then
        runtime_stats.inc("live_timer_depth_rejections")
        runtime_stats.inc("live_timer_payload_route_failed")
        return { ok = false, error = "timer payload depth exceeds MAX_RECURSION_DEPTH" }
    end

    local actor = binding.actor
    if actor == nil then
        runtime_stats.inc("live_timer_payload_route_failed")
        return { ok = false, error = "missing caster for timer payload" }
    end

    local resolution = binding.resolution
    if type(resolution) ~= "table" or resolution.resolution_pos == nil or resolution.timer_direction == nil then
        runtime_stats.inc("live_timer_payload_route_failed")
        return { ok = false, error = "missing timer payload launch resolution" }
    end

    local key = duplicateKey(binding, options)
    if schedule_keys[key] then
        runtime_stats.inc("live_timer_duplicate_schedules_suppressed")
        runtime_stats.inc("live_timer_async_duplicate_suppressed")
        log.debug(string.format(
            "live Timer duplicate schedule skipped recipe_id=%s source_slot_id=%s payload_slot_id=%s key=%s",
            tostring(binding.recipe_id),
            tostring(binding.source_slot_id),
            tostring(binding.payload_slot_id),
            tostring(shortKey(key) or "<long>")
        ))
        return {
            ok = true,
            duplicate_suppressed = true,
            duplicate_key = key,
            timer_id = timer_id_by_key[key],
            pending_count = pendingCount(),
            source_slot_id = binding.source_slot_id,
            payload_slot_id = binding.payload_slot_id,
        }
    end

    local delay_ticks = tonumber(options.delay_ticks_override or binding.timer_delay_ticks) or 1
    if delay_ticks < 1 then
        delay_ticks = 1
    end
    local delay_seconds = finiteNonNegative(options.delay_seconds_override or binding.timer_seconds)
    if delay_seconds == nil then
        delay_seconds = delay_ticks / TIMER_TICKS_PER_SECOND
    end
    local scheduled_tick = orchestrator.currentTick()
    local due_tick = scheduled_tick + delay_ticks
    local scheduled_seconds = orchestrator.currentTimeSeconds()
    local due_seconds = scheduled_seconds + delay_seconds
    local ttl_seconds = finiteNonNegative(options.ttl_seconds_override)
    if ttl_seconds == nil then
        local ttl_ticks = finiteNonNegative(options.ttl_ticks_override)
        if ttl_ticks ~= nil then
            ttl_seconds = ttl_ticks / TIMER_TICKS_PER_SECOND
        end
    end
    ttl_seconds = ttl_seconds or (delay_seconds + TIMER_EXPIRY_GRACE_SECONDS)
    runtime_stats.inc("live_timer_real_delay_attempts")
    local timer_id = nextTimerId(binding)
    local timer_data = {
        schema = "spellforge_live_timer_async_v1",
        timer_id = timer_id,
        recipe_id = binding.recipe_id,
        cast_id = binding.cast_id,
        source_job_id = binding.source_job_id,
        source_slot_id = binding.source_slot_id,
        source_helper_engine_id = binding.source_helper_engine_id,
        payload_slot_id = binding.payload_slot_id,
        payload_helper_engine_id = binding.payload_helper_engine_id,
        actor = actor,
        start_pos = resolution.resolution_pos,
        direction = resolution.timer_direction,
        hit_object = resolution.resolution_hit_object or binding.hit_object,
        depth = payload_depth,
        delay_ticks = delay_ticks,
        delay_seconds = delay_seconds,
        scheduled_tick = scheduled_tick,
        due_tick = due_tick,
        scheduled_seconds = scheduled_seconds,
        due_seconds = due_seconds,
        ttl_seconds = ttl_seconds,
        duplicate_key = key,
        reliable_arg_complete = true,
    }
    local callback = live_timer.registerCallbacks()
    local timer_ok, timer_or_err = pcall(function()
        return async:newSimulationTimer(delay_seconds, callback, timer_data)
    end)
    if not timer_ok then
        runtime_stats.inc("live_timer_payload_route_failed")
        return { ok = false, error = tostring(timer_or_err) }
    end

    rememberScheduleKey(key)
    rememberPendingTimer(timer_data)
    runtime_stats.inc("live_timer_async_scheduled")
    runtime_stats.inc("live_timer_wait_jobs_enqueued")
    runtime_stats.inc("live_timer_immediate_payload_blocked")
    log.info(string.format(
        "SPELLFORGE_LIVE_TIMER_ASYNC_SCHEDULED timer_id=%s recipe_id=%s cast_id=%s source_slot_id=%s payload_slot_id=%s delay_seconds=%s",
        tostring(timer_id),
        tostring(binding.recipe_id),
        tostring(binding.cast_id),
        tostring(binding.source_slot_id),
        tostring(binding.payload_slot_id),
        tostring(delay_seconds)
    ))

    return {
        ok = true,
        async_scheduled = true,
        timer_id = timer_id,
        duplicate_key = key,
        source_slot_id = binding.source_slot_id,
        payload_slot_id = binding.payload_slot_id,
        payload_helper_engine_id = binding.payload_helper_engine_id,
        timer_delay_ticks = delay_ticks,
        timer_delay_seconds = delay_seconds,
        timer_scheduled_tick = scheduled_tick,
        timer_due_tick = due_tick,
        timer_scheduled_seconds = scheduled_seconds,
        timer_due_seconds = due_seconds,
        ttl_seconds = ttl_seconds,
        pending_count = pendingCount(),
        timer_delay_semantics = "async_simulation_timer",
    }
end

function live_timer.clearForTests()
    schedule_keys = {}
    schedule_order = {}
    timer_id_by_key = {}
    pending_timers = {}
    pending_order = {}
    timer_results = {}
    timer_result_order = {}
    next_timer_sequence = 1
end

function live_timer.pendingCount()
    return pendingCount()
end

function live_timer.timerStatus(timer_id)
    local pending = type(timer_id) == "string" and pending_timers[timer_id] or nil
    local result = type(timer_id) == "string" and timer_results[timer_id] or nil
    local job = result and result.job_id and orchestrator.getJob(result.job_id) or nil
    return {
        timer_id = timer_id,
        pending = pending ~= nil,
        pending_count = pendingCount(),
        callback_seen = result ~= nil,
        callback_ok = result and result.ok == true or false,
        callback_status = result and result.status or nil,
        callback_error = result and result.error or nil,
        payload_job_id = result and result.job_id or nil,
        payload_job_status = job and job.status or nil,
        payload_launch_accepted = job and job.launch_accepted == true or false,
        payload_launch_user_data = job and job.launch_user_data or nil,
        payload_projectile_id = job and job.projectile_id or nil,
        cast_id = (pending and pending.cast_id) or (result and result.cast_id) or (job and job.cast_id) or nil,
        source_slot_id = (pending and pending.source_slot_id) or (result and result.source_slot_id) or (job and job.source_slot_id) or nil,
        source_helper_engine_id = (pending and pending.source_helper_engine_id) or (result and result.source_helper_engine_id) or (job and job.source_helper_engine_id) or nil,
        payload_slot_id = (pending and pending.payload_slot_id) or (result and result.payload_slot_id) or (job and job.payload_slot_id) or nil,
        payload_helper_engine_id = (pending and pending.payload_helper_engine_id) or (result and result.payload_helper_engine_id) or (job and job.helper_engine_id) or nil,
        timer_delay_ticks = (pending and pending.delay_ticks) or (job and job.timer_delay_ticks) or nil,
        timer_delay_seconds = (pending and pending.delay_seconds) or (job and job.timer_delay_seconds) or nil,
        timer_due_tick = (pending and pending.due_tick) or (job and job.timer_due_tick) or nil,
        timer_due_seconds = (pending and pending.due_seconds) or (job and job.timer_due_seconds) or nil,
    }
end

return live_timer
