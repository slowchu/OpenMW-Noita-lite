local async = require("openmw.async")

local dev = require("scripts.spellforge.shared.dev")
local limits = require("scripts.spellforge.shared.limits")
local log = require("scripts.spellforge.shared.log").new("global.live_timer")
local helper_records = require("scripts.spellforge.global.helper_records")
local ir_runtime_adapter = require("scripts.spellforge.global.ir_runtime_adapter")
local launch_modifier_policy = require("scripts.spellforge.global.launch_modifier_policy")
local orchestrator = require("scripts.spellforge.global.orchestrator")
local payload_multicast = require("scripts.spellforge.global.payload_multicast")
local payload_pattern = require("scripts.spellforge.global.payload_pattern")
local projectile_registry = require("scripts.spellforge.global.projectile_registry")
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

local function sourcePrefixAllowed(ops, options)
    if not hasOps(ops) then
        return true
    end
    if options and options.allow_source_homing == true and #ops == 1 and ops[1] and ops[1].opcode == "Homing" then
        return true
    end
    return false
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

function live_timer.delayFromOp(op)
    return timerDelayFromOp(op)
end

function live_timer.selectV0Plan(plan, opts)
    local options = opts or {}
    if type(plan) ~= "table" then
        return rejectSelect("missing_plan")
    end
    local bounds = plan.bounds or {}
    if bounds.has_trigger then
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
    if not sourcePrefixAllowed(group.prefix_ops, options) then
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

    local source_slot = nil
    for _, slot in ipairs(slots) do
        if slot.kind == "primary_emission" then
            if source_slot then
                return rejectSelect("multiple_timer_sources")
            end
            source_slot = slot
        elseif slot.kind == "payload_emission" then
            -- Payload slots are validated as a direct Timer payload group below.
        else
            return rejectSelect("unknown_slot_kind")
        end
    end

    if not source_slot then
        return rejectSelect("missing_timer_source_slot")
    end
    if source_slot.parent_slot_id ~= nil or source_slot.source_postfix_opcode ~= nil then
        return rejectSelect("source_slot_not_primary")
    end
    if source_slot.trigger_source_slot_id ~= nil or source_slot.timer_source_slot_id ~= nil then
        return rejectSelect("source_slot_has_payload_source")
    end
    if not sourcePrefixAllowed(source_slot.prefix_ops, options) then
        return rejectSelect("source_slot_has_prefix_ops")
    end
    if not postfixIsOnlyTimer(source_slot) then
        return rejectSelect("source_slot_not_timer")
    end
    if not slotHasOneTimerBinding(source_slot) then
        return rejectSelect("source_timer_binding_missing", "live_timer_payload_missing")
    end

    local helpers_by_slot = helperBySlotId(helpers)
    local source_helper = helpers_by_slot[source_slot.slot_id]
    if not source_helper or type(source_helper.engine_id) ~= "string" or source_helper.engine_id == "" then
        return rejectSelect("source_helper_missing")
    end
    if source_helper.parent_slot_id ~= nil or source_helper.source_postfix_opcode ~= nil then
        return rejectSelect("source_helper_not_primary")
    end
    if not slotHasOneTimerBinding(source_helper) then
        return rejectSelect("source_helper_timer_binding_missing", "live_timer_payload_missing")
    end

    local payload_result = payload_multicast.resolvePayloadHelpersForSource(plan, source_slot, {
        source_opcode = "Timer",
        allow_payload_multicast = options.allow_payload_multicast == true,
        allow_payload_pattern = options.allow_payload_pattern == true,
        allow_payload_launch_modifiers = options.allow_payload_launch_modifiers == true,
        force_speed_plus_enabled = options.force_speed_plus_enabled,
        force_speed_plus_disabled = options.force_speed_plus_disabled,
        speed_plus_enabled = options.speed_plus_enabled == true,
        force_size_plus_enabled = options.force_size_plus_enabled,
        force_size_plus_disabled = options.force_size_plus_disabled,
        size_plus_enabled = options.size_plus_enabled == true,
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
        local reason = payload_result.rejection_reason or "timer_payload_resolution_failed"
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
                or reason == "payload_modifier_nested_deferred"
                or reason == "payload_modifier_combo_deferred"
                or reason == "payload_speed_plus_disabled"
                or reason == "payload_size_plus_disabled" then
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
        local counter = reason == "payload_missing" and "live_timer_payload_missing" or nil
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
        has_payload_modifier = payload_result.has_payload_modifier == true,
        has_payload_homing = payload_result.has_payload_homing == true,
        payload_modifier_kinds = payload_result.payload_modifier_kinds,
        payload_multicast_fanout_count = payload_result.fanout_count,
        max_payload_fanout = tonumber(options.max_fanout) or limits.MAX_NESTED_PAYLOAD_FANOUT,
        max_projectiles = tonumber(options.max_projectiles) or limits.MAX_PROJECTILES_PER_CAST,
        max_jobs_per_tick = tonumber(options.max_jobs_per_tick) or limits.MAX_JOBS_PER_TICK,
        max_live_launches_per_tick = tonumber(options.max_live_launches_per_tick) or limits.MAX_LIVE_LAUNCHES_PER_TICK,
        chaos_budget_profile = options.chaos_budget_profile,
        allow_pending_launch_jobs = options.allow_pending_launch_jobs == true,
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
    job.source_prefix_opcode = binding.source_prefix_opcode or job.source_prefix_opcode
    job.source_postfix_opcode = "Timer"
    job.root_source_slot_id = binding.root_source_slot_id or binding.source_slot_id
    job.current_source_slot_id = binding.current_source_slot_id or binding.source_slot_id
    job.parent_slot_id = binding.parent_slot_id
    job.payload_depth = tonumber(binding.source_depth) or 0
    job.nested_stage_kind = binding.nested_stage_kind
    job.nested_stage_index = binding.nested_stage_index
    job.timer_source_slot_id = binding.source_slot_id
    job.timer_payload_slot_id = binding.payload_slot_id
    job.timer_payload_slot_ids = binding.payload_slot_ids
    job.has_timer_payload = true
    job.payload_multicast = binding.payload_multicast == true
    job.payload_pattern = binding.payload_pattern == true
    job.payload_pattern_kind = binding.payload_pattern_kind
    job.nested_final_fanout = binding.nested_final_fanout == true
    job.nested_final_fanout_kind = binding.nested_final_fanout_kind
    job.payload_count = tonumber(binding.payload_count) or 1
    job.payload = job.payload or {}
    job.payload.source_prefix_opcode = binding.source_prefix_opcode or job.payload.source_prefix_opcode
    job.payload.source_slot_id = binding.source_slot_id
    job.payload.source_helper_engine_id = binding.source_helper_engine_id
    job.payload.source_postfix_opcode = "Timer"
    job.payload.root_source_slot_id = binding.root_source_slot_id or binding.source_slot_id
    job.payload.current_source_slot_id = binding.current_source_slot_id or binding.source_slot_id
    job.payload.parent_slot_id = binding.parent_slot_id
    job.payload.payload_depth = tonumber(binding.source_depth) or 0
    job.payload.nested_stage_kind = binding.nested_stage_kind
    job.payload.nested_stage_index = binding.nested_stage_index
    job.payload.timer_source_slot_id = binding.source_slot_id
    job.payload.timer_payload_slot_id = binding.payload_slot_id
    job.payload.timer_payload_slot_ids = binding.payload_slot_ids
    job.payload.has_timer_payload = true
    job.payload.payload_multicast = binding.payload_multicast == true
    job.payload.payload_pattern = binding.payload_pattern == true
    job.payload.payload_pattern_kind = binding.payload_pattern_kind
    job.payload.nested_final_fanout = binding.nested_final_fanout == true
    job.payload.nested_final_fanout_kind = binding.nested_final_fanout_kind
    job.payload.payload_count = tonumber(binding.payload_count) or 1
    job.payload.timer_delay_ticks = binding.timer_delay_ticks
    job.payload.timer_delay_seconds = binding.timer_seconds
    job.payload.timer_delay_semantics = "async_simulation_timer"
end

local sourceProjectileSnapshot

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
    local snapshot = has_projectile_id and sourceProjectileSnapshot
        and sourceProjectileSnapshot(projectile_id, projectile_state)
        or nil
    local has_position = snapshot and snapshot.position ~= nil or (
        type(projectile_state) == "table"
            and (projectile_state.position ~= nil or projectile_state.pos ~= nil)
    )
    local has_cell = snapshot and snapshot.cell ~= nil or (type(projectile_state) == "table" and projectile_state.cell ~= nil)
    local api_ready = caps.has_detonateSpellAtPos == true and caps.has_cancelSpell == true
    local can_detonate = api_ready and has_projectile_id and has_position and has_cell
    local blocker = nil
    local status = "ready"
    if not api_ready then
        status = "blocked"
        blocker = "Timer source detonation requires SFP detonateSpellAtPos and cancelSpell."
    elseif not has_projectile_id then
        status = "pending_projectile"
    elseif snapshot and snapshot.already_hit == true then
        status = "already_hit"
    elseif can_detonate then
        status = "implementable"
    else
        status = "pending_projectile_state"
    end
    return {
        status = status,
        blocker = blocker,
        cancelSpell_available = caps.has_cancelSpell == true,
        detonateSpellAtPos_available = caps.has_detonateSpellAtPos == true,
        getSpellState_available = caps.has_getSpellState == true,
        launch_projectile_registry_available = true,
        projectile_id_available = has_projectile_id,
        source_spell_id_available = has_source_spell_id,
        caster_available = has_caster,
        projectile_position_available = has_position == true,
        projectile_cell_available = has_cell == true,
        projectile_already_hit = snapshot and snapshot.already_hit == true or false,
        projectile_object_available = snapshot and snapshot.projectile ~= nil or false,
        projectile_state_fallback_available = snapshot and snapshot.from_projectile_state == true or false,
    }
end

local function duplicateKey(binding, opts)
    local suffix = opts and opts.duplicate_key_suffix or nil
    local delay_ticks = opts and opts.delay_ticks_override or binding.timer_delay_ticks
    local delay_seconds = opts and opts.delay_seconds_override or binding.timer_seconds
    local payload_key = binding.payload_group_key or binding.payload_slot_id
    local key = string.format(
        "timer:%s:%s:%s:%s:%s:%s:%s",
        tostring(binding.cast_id or "no-cast"),
        tostring(binding.recipe_id),
        tostring(binding.source_slot_id),
        tostring(payload_key),
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

local function shallowCopy(value)
    local out = {}
    for key, item in pairs(value or {}) do
        out[key] = item
    end
    return out
end

local function sourceUserData(value)
    if type(value) == "table" then
        return value.source_user_data
    end
    return nil
end

local function branchScope(value)
    local user_data = sourceUserData(value)
    return value.branch_scope
        or (user_data and user_data.branch_scope)
        or "default"
end

local function branchParentId(value)
    local user_data = sourceUserData(value)
    return value.branch_id
        or (user_data and user_data.branch_id)
        or string.format(
            "root:%s:%s",
            tostring(value.cast_id or (user_data and user_data.cast_id) or "no-cast"),
            tostring(value.source_slot_id or "no-source")
        )
end

local function branchKind(value, count)
    if value.nested_final_fanout == true then
        return "nested_final_fanout"
    end
    local prefix = "timer_payload"
    if value.payload_pattern == true then
        return prefix .. "_pattern"
    end
    if value.payload_multicast == true or tonumber(count) ~= 1 then
        return prefix .. "_multicast"
    end
    return prefix
end

local function branchInfo(value, payload, index, count)
    local parent_id = branchParentId(value)
    local payload_slot_id = payload and payload.slot_id or value.payload_slot_id or "no-payload"
    local user_data = sourceUserData(value)
    return {
        branch_scope = branchScope(value),
        branch_parent_id = parent_id,
        branch_id = string.format("%s:timer:%s:%s", tostring(parent_id), tostring(index), tostring(payload_slot_id)),
        branch_kind = branchKind(value, count),
        branch_index = index,
        branch_count = count,
        chain_continuation_group_id = value.chain_continuation_group_id
            or (user_data and user_data.chain_continuation_group_id),
    }
end

local function copyBranchFields(target, branch)
    if type(target) ~= "table" or type(branch) ~= "table" then
        return
    end
    target.branch_scope = branch.branch_scope
    target.branch_id = branch.branch_id
    target.branch_parent_id = branch.branch_parent_id
    target.branch_kind = branch.branch_kind
    target.branch_index = branch.branch_index
    target.branch_count = branch.branch_count
    target.chain_continuation_group_id = branch.chain_continuation_group_id
end

local function irTimerRuntimeEnabled(options)
    if options and options.force_ir_timer_runtime_disabled == true then
        return false
    end
    return (options and options.force_ir_timer_runtime_enabled == true)
        or dev.irTimerRuntimeEnabled()
end

local function irPlannerOptions(binding, options)
    local gates = launch_modifier_policy.gateHintsForModifierKinds(
        binding and binding.payload_modifier_kinds,
        options
    )
    return {
        allow_payload_multicast = binding.payload_multicast == true
            or (options and options.allow_payload_multicast == true)
            or (options and options.force_payload_multicast_enabled == true),
        allow_payload_pattern = binding.payload_pattern == true
            or (options and options.allow_payload_pattern == true)
            or (options and options.force_payload_pattern_enabled == true),
        allow_payload_launch_modifiers = binding.has_payload_modifier == true
            or (options and options.allow_payload_launch_modifiers == true),
        force_speed_plus_enabled = gates.force_speed_plus_enabled,
        force_speed_plus_disabled = gates.force_speed_plus_disabled,
        speed_plus_enabled = gates.speed_plus_enabled,
        force_size_plus_enabled = gates.force_size_plus_enabled,
        force_size_plus_disabled = gates.force_size_plus_disabled,
        size_plus_enabled = gates.size_plus_enabled,
        max_depth = options and options.max_depth or limits.MAX_RECURSION_DEPTH,
        max_jobs = binding.max_payload_fanout or (options and options.max_jobs),
        max_fanout = binding.max_payload_fanout or (options and options.max_fanout),
        max_projectiles = binding.max_projectiles or (options and options.max_projectiles),
        max_live_launches_per_tick = binding.max_live_launches_per_tick
            or (options and options.max_live_launches_per_tick),
        chaos_budget_profile = binding.chaos_budget_profile or (options and options.chaos_budget_profile),
        allow_source_homing = options and options.allow_source_homing == true,
        allow_payload_homing = (binding and binding.has_payload_homing == true)
            or (options and options.allow_payload_homing == true),
        allow_homing = options and options.allow_homing == true,
        force_homing_enabled = options and options.force_homing_enabled,
        force_homing_disabled = options and options.force_homing_disabled,
        homing_enabled = (options and options.homing_enabled == true) or dev.liveHomingEnabled() == true,
        max_homing_fanout_per_cast = options and options.max_homing_fanout_per_cast,
        max_homing_target_scans_per_cast = options and options.max_homing_target_scans_per_cast,
        max_soft_homing_registrations_per_cast = options and options.max_soft_homing_registrations_per_cast,
        homing_target_id = options and options.homing_target_id,
        homing_target_position = options and options.homing_target_position,
        homing_actor_scan = options and options.homing_actor_scan,
        allow_nested_trigger_timer = options and options.allow_nested_trigger_timer == true,
        allow_nested_final_fanout = options and options.allow_nested_final_fanout == true,
        allow_nested_payload_modifiers = options and options.allow_nested_payload_modifiers == true,
        allow_nested_payload_homing = options and options.allow_nested_payload_homing == true,
        max_live_nested_continuation_depth = options and options.max_live_nested_continuation_depth,
        max_nested_continuation_jobs_per_cast = options and options.max_nested_continuation_jobs_per_cast,
        max_nested_final_payload_jobs_per_cast = options and options.max_nested_final_payload_jobs_per_cast,
    }
end

local function irTimerFallback(binding, reason, marker)
    runtime_stats.inc("ir_timer_runtime_fallback")
    log.info(string.format(
        "%s recipe_id=%s cast_id=%s source_slot_id=%s reason=%s",
        marker or "SPELLFORGE_IR_TIMER_RUNTIME_FALLBACK",
        tostring(binding and binding.recipe_id),
        tostring(binding and binding.cast_id),
        tostring(binding and binding.source_slot_id),
        tostring(reason)
    ))
    return {
        fallback = true,
        reason = reason,
        mismatch = marker == "SPELLFORGE_IR_TIMER_RUNTIME_MISMATCH",
    }
end

local function irTimerMismatch(binding, reason)
    runtime_stats.inc("ir_timer_runtime_mismatch")
    return irTimerFallback(binding, reason, "SPELLFORGE_IR_TIMER_RUNTIME_MISMATCH")
end

local function validateIrTimerJobPlan(binding, payloads, continuation_plan, job_plan)
    if type(continuation_plan) ~= "table" or continuation_plan.ok ~= true then
        return false, continuation_plan and continuation_plan.rejection_reason or "continuation_plan_failed"
    end
    if continuation_plan.source_slot_id ~= binding.source_slot_id then
        return false, "source_slot_mismatch"
    end
    if continuation_plan.source_helper_engine_id ~= binding.source_helper_engine_id then
        return false, "source_helper_mismatch"
    end
    if type(job_plan) ~= "table" or job_plan.ok ~= true then
        return false, job_plan and job_plan.rejection_reason or "runtime_job_plan_failed"
    end
    if tonumber(job_plan.planned_job_count) ~= #payloads then
        return false, "payload_count_mismatch"
    end
    for index, payload in ipairs(payloads or {}) do
        local job = job_plan.planned_jobs and job_plan.planned_jobs[index] or nil
        if type(job) ~= "table" then
            return false, "planned_job_missing"
        end
        if job.slot_id ~= payload.slot_id or job.payload_slot_id ~= payload.slot_id then
            return false, "payload_slot_mismatch"
        end
        if job.helper_engine_id ~= payload.helper_engine_id then
            return false, "payload_helper_mismatch"
        end
        if job.kind ~= orchestrator.LIVE_TIMER_PAYLOAD_JOB_KIND then
            return false, "job_kind_mismatch"
        end
    end
    return true, nil
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

local function mergeSourceDetonationResult(result, source_result)
    if type(result) ~= "table" or type(source_result) ~= "table" then
        return result
    end
    for key, value in pairs(source_result) do
        if result[key] == nil then
            result[key] = value
        end
    end
    return result
end

local function safeReadField(value, key)
    if value == nil then
        return nil
    end
    local ok, result = pcall(function()
        return value[key]
    end)
    if ok then
        return result
    end
    return nil
end

local function objectIsValid(value)
    if value == nil then
        return false
    end
    local is_valid = safeReadField(value, "isValid")
    if type(is_valid) == "function" then
        local ok, result = pcall(function()
            return value:isValid()
        end)
        return ok and result == true
    end
    return true
end

local function statePosition(state)
    if type(state) ~= "table" then
        return nil
    end
    return state.position or state.pos or state.hitPos or state.hit_pos
end

local function stateCell(state)
    if type(state) ~= "table" then
        return nil
    end
    local cell = state.cell
    if cell ~= nil then
        return cell
    end
    local projectile = state.projectile
    return safeReadField(projectile, "cell")
end

sourceProjectileSnapshot = function(projectile_id, projectile_state)
    local entry = projectile_id and projectile_registry.getByProjectileId(projectile_id) or nil
    if entry and entry.hit == true then
        return {
            entry = entry,
            already_hit = true,
            position = statePosition(entry.hit_payload),
            cell = stateCell(entry.hit_payload),
        }
    end

    local projectile = entry and entry.projectile or nil
    if objectIsValid(projectile) then
        local position = safeReadField(projectile, "position")
        local cell = safeReadField(projectile, "cell")
        if position ~= nil and cell ~= nil then
            return {
                entry = entry,
                projectile = projectile,
                position = position,
                cell = cell,
                from_projectile_object = true,
            }
        end
    end

    local state = projectile_state or (entry and entry.last_state)
    local position = statePosition(state)
    local cell = stateCell(state)
    if position ~= nil and cell ~= nil then
        return {
            entry = entry,
            projectile = state and state.projectile or projectile,
            position = position,
            cell = cell,
            from_projectile_state = true,
        }
    end

    return {
        entry = entry,
        projectile = projectile,
        position = position,
        cell = cell,
    }
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

local function nextTimerId(binding)
    local sequence = next_timer_sequence
    next_timer_sequence = next_timer_sequence + 1
    local payload_key = binding.payload_group_key or binding.payload_slot_id or "no-payload"
    return string.format(
        "timer:%s:%s:%s:%d",
        tostring(binding.cast_id or "no-cast"),
        tostring(binding.source_slot_id or "no-source"),
        tostring(payload_key),
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

local function buildIrTimerRuntimePlan(binding, payloads, options, timer_context)
    if not irTimerRuntimeEnabled(options) then
        return nil
    end
    if binding.nested_tt == true or binding.nested_final_fanout == true then
        return nil
    end

    runtime_stats.inc("ir_timer_runtime_attempts")
    local plan = binding.plan or binding.compiled_plan or binding.attached_plan
    local planner_options = irPlannerOptions(binding, options)
    local event = {
        event_kind = "timer_matured",
        source_slot_id = binding.source_slot_id,
        source_helper_engine_id = binding.source_helper_engine_id,
        source_prefix_opcode = binding.source_prefix_opcode,
        source_postfix_opcode = "Timer",
        cast_id = binding.cast_id,
        source_job_id = binding.source_job_id,
        parent_job_id = binding.source_job_id,
        projectile_id = binding.source_projectile_id,
        timer_id = timer_context and timer_context.timer_id,
        timer_delay_ticks = timer_context and timer_context.delay_ticks,
        timer_delay_seconds = timer_context and timer_context.delay_seconds,
        timer_due_tick = timer_context and timer_context.due_tick,
        timer_due_seconds = timer_context and timer_context.due_seconds,
        branch_scope = branchScope(binding),
        branch_parent_id = branchParentId(binding),
        chain_runtime = binding.chain_runtime,
        chain_id = binding.chain_id,
        chain_hop_index = binding.chain_hop_index,
        chain_max_hops = binding.chain_max_hops,
        chain_continuation_group_id = binding.chain_continuation_group_id
            or (binding.source_user_data and binding.source_user_data.chain_continuation_group_id),
        bounce_id = binding.bounce_id,
        bounce_max = binding.bounce_max,
        bounce_power = binding.bounce_power,
        pierce_id = binding.pierce_id,
        pierce_limit = binding.pierce_limit,
    }
    local planned = ir_runtime_adapter.planEvent(binding, plan, event, planner_options)
    if planned.ok ~= true then
        if planned.stage == "ir" then
            return irTimerFallback(binding, planned.rejection_reason)
        end
        return irTimerMismatch(binding, planned.rejection_reason or "continuation_plan_failed")
    end
    local continuation_plan = planned.continuation_plan
    local job_plan = planned.job_plan
    local valid, reason = validateIrTimerJobPlan(binding, payloads, continuation_plan, job_plan)
    if not valid then
        return irTimerMismatch(binding, reason)
    end

    return {
        ok = true,
        continuation_plan = continuation_plan,
        job_plan = job_plan,
        event = event,
    }
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

    local payloads = data.payloads
    if type(payloads) ~= "table" or #payloads == 0 then
        if type(data.payload_helper_engine_id) ~= "string" or data.payload_helper_engine_id == "" then
            return nil, "payload_helper_engine_id missing"
        end
        payloads = {
            {
                slot_id = data.payload_slot_id,
                helper_engine_id = data.payload_helper_engine_id,
            },
        }
    end
    local max_payload_fanout = tonumber(data.max_payload_fanout) or limits.MAX_NESTED_PAYLOAD_FANOUT
    local max_projectiles = tonumber(data.max_projectiles) or limits.MAX_PROJECTILES_PER_CAST
    if #payloads > max_payload_fanout then
        return nil, "timer payload multicast fanout exceeds cap"
    end
    if #payloads > max_projectiles then
        return nil, "timer payload multicast projectile cap exceeded"
    end

    local payload_mappings = {}
    for index, payload in ipairs(payloads) do
        if type(payload.slot_id) ~= "string" or payload.slot_id == "" then
            return nil, "timer payload slot_id missing"
        end
        if type(payload.helper_engine_id) ~= "string" or payload.helper_engine_id == "" then
            return nil, "timer payload helper_engine_id missing"
        end
        local payload_mapping = helper_records.getByRecipeSlot(data.recipe_id, payload.slot_id)
            or helper_records.getByEngineId(payload.helper_engine_id)
        if not payload_mapping or payload_mapping.engine_id ~= payload.helper_engine_id then
            return nil, "timer payload helper mapping missing"
        end
        if payload_mapping.source_postfix_opcode ~= "Timer"
            or payload_mapping.timer_source_slot_id ~= data.source_slot_id then
            return nil, "timer payload helper mapping mismatch"
        end
        payload_mappings[index] = payload_mapping
    end

    return {
        payload_depth = payload_depth,
        payloads = payloads,
        payload_mappings = payload_mappings,
    }, nil
end

local function recordTimerPayloadEnqueued(data, source_result, job_ids, payload_slot_ids, payload_helper_engine_ids, ir_runtime)
    runtime_stats.inc("live_timer_async_payload_enqueued", #job_ids)
    runtime_stats.inc("live_timer_payload_jobs_enqueued", #job_ids)
    if ir_runtime == true then
        runtime_stats.inc("ir_timer_runtime_enqueued")
        runtime_stats.inc("ir_timer_runtime_jobs_enqueued", #job_ids)
    end
    if data.nested_tt == true then
        if data.nested_tt_kind == "timer_trigger" then
            runtime_stats.inc("nested_tt_intermediate_jobs", #job_ids)
        elseif data.nested_tt_kind == "trigger_timer" then
            runtime_stats.inc("nested_tt_final_jobs", #job_ids)
            runtime_stats.inc("nested_tt_runtime_ok")
        end
    end
    if data.chain_runtime == true and data.source_prefix_opcode == "Chain" then
        runtime_stats.inc("chain_timer_side_payload_enqueued", #job_ids)
        log.info(string.format(
            "SPELLFORGE_CHAIN_TIMER_SIDE_PAYLOAD_ENQUEUED timer_id=%s recipe_id=%s cast_id=%s chain_id=%s hop_index=%s payload_count=%s",
            tostring(data.timer_id),
            tostring(data.recipe_id),
            tostring(data.cast_id),
            tostring(data.chain_id),
            tostring(data.chain_hop_index),
            tostring(#job_ids)
        ))
    end
    if data.payload_multicast == true then
        runtime_stats.inc("payload_multicast_jobs", #job_ids)
        runtime_stats.inc("payload_multicast_timer_jobs", #job_ids)
        runtime_stats.inc("payload_multicast_runtime_ok")
    end
    if data.payload_pattern == true then
        runtime_stats.inc("payload_pattern_jobs", #job_ids)
        runtime_stats.inc("payload_pattern_timer_jobs", #job_ids)
        runtime_stats.inc("payload_pattern_runtime_ok")
        if data.payload_pattern_kind == "Spread" then
            runtime_stats.inc("payload_pattern_spread_jobs", #job_ids)
        elseif data.payload_pattern_kind == "Burst" then
            runtime_stats.inc("payload_pattern_burst_jobs", #job_ids)
        end
    end
    runtime_stats.max("chaos_budget_max_jobs_observed", #job_ids)
    runtime_stats.max("chaos_budget_max_projectiles_observed", #job_ids)
    runtime_stats.max("chaos_budget_max_queue_observed", orchestrator.queueLength())
    if #job_ids > limits.MAX_NESTED_PAYLOAD_FANOUT then
        runtime_stats.inc("chaos_budget_high_fanout_smoke")
        log.info(string.format(
            "SPELLFORGE_CHAOS_STRESS_OK profile=chaos observed_jobs=%d observed_projectiles=%d observed_queue=%d live_mode=timer_payload fanout_count=%d",
            #job_ids,
            #job_ids,
            orchestrator.queueLength(),
            #job_ids
        ))
    end
    if data.nested_final_fanout == true then
        runtime_stats.inc("nested_final_fanout_jobs", #job_ids)
        runtime_stats.inc("nested_final_fanout_timer_jobs", #job_ids)
        runtime_stats.inc("nested_final_fanout_runtime_ok")
        if data.payload_pattern_kind == "Spread" then
            runtime_stats.inc("nested_final_fanout_spread_jobs", #job_ids)
        elseif data.payload_pattern_kind == "Burst" then
            runtime_stats.inc("nested_final_fanout_burst_jobs", #job_ids)
        end
    end
    rememberTimerResult(mergeSourceDetonationResult({
        timer_id = data.timer_id,
        ok = true,
        status = "payload_enqueued",
        job_id = job_ids[1],
        job_ids = job_ids,
        payload_count = #job_ids,
        payload_multicast = data.payload_multicast == true,
        payload_pattern = data.payload_pattern == true,
        payload_pattern_kind = data.payload_pattern_kind,
        payload_pattern_direction_keys = data.payload_pattern_direction_keys,
        nested_tt = data.nested_tt == true,
        nested_tt_kind = data.nested_tt_kind,
        nested_tt_payload_role = data.nested_tt_payload_role,
        nested_final_fanout = data.nested_final_fanout == true,
        nested_final_fanout_kind = data.nested_final_fanout_kind,
        cast_id = data.cast_id,
        source_slot_id = data.source_slot_id,
        source_helper_engine_id = data.source_helper_engine_id,
        payload_slot_id = payload_slot_ids[1],
        payload_helper_engine_id = payload_helper_engine_ids[1],
        payload_slot_ids = payload_slot_ids,
        payload_helper_engine_ids = payload_helper_engine_ids,
        ir_timer_runtime = ir_runtime == true,
        ir_timer_runtime_job_count = ir_runtime == true and #job_ids or nil,
        ir_timer_runtime_fallback_used = data.ir_timer_runtime_fallback_reason ~= nil,
        ir_timer_runtime_fallback_reason = data.ir_timer_runtime_fallback_reason,
        ir_timer_runtime_mismatch = data.ir_timer_runtime_mismatch == true,
    }, source_result))
    if ir_runtime == true then
        local first_queued_job = orchestrator.getJob(job_ids[1])
        log.info(string.format(
            "SPELLFORGE_IR_TIMER_RUNTIME_ENQUEUED timer_id=%s recipe_id=%s cast_id=%s source_slot_id=%s payload_count=%s first_job_id=%s branch_kind=%s",
            tostring(data.timer_id),
            tostring(data.recipe_id),
            tostring(data.cast_id),
            tostring(data.source_slot_id),
            tostring(#job_ids),
            tostring(job_ids[1]),
            tostring(first_queued_job and first_queued_job.branch_kind or nil)
        ))
    end
    local marker = data.nested_final_fanout == true
        and "SPELLFORGE_NESTED_FINAL_FANOUT_TIMER_ENQUEUED"
        or data.payload_pattern == true
        and "SPELLFORGE_PAYLOAD_PATTERN_TIMER_ENQUEUED"
        or data.payload_multicast == true
        and "SPELLFORGE_PAYLOAD_MULTICAST_TIMER_ENQUEUED"
        or "SPELLFORGE_LIVE_TIMER_ASYNC_PAYLOAD_ENQUEUED"
    local first_queued_job = orchestrator.getJob(job_ids[1])
    log.info(string.format(
        "%s timer_id=%s job_count=%s cast_id=%s source_slot_id=%s payload_count=%s pattern_kind=%s first_payload_slot_id=%s first_branch_id=%s branch_kind=%s",
        marker,
        tostring(data.timer_id),
        tostring(#job_ids),
        tostring(data.cast_id),
        tostring(data.source_slot_id),
        tostring(#job_ids),
        tostring(data.payload_pattern_kind),
        tostring(payload_slot_ids[1]),
        tostring(first_queued_job and first_queued_job.branch_id or nil),
        tostring(first_queued_job and first_queued_job.branch_kind or nil)
    ))
    return mergeSourceDetonationResult({
        ok = true,
        job_id = job_ids[1],
        job_ids = job_ids,
        payload_count = #job_ids,
        timer_id = data.timer_id,
        ir_timer_runtime = ir_runtime == true,
        ir_timer_runtime_job_count = ir_runtime == true and #job_ids or nil,
        ir_timer_runtime_fallback_used = data.ir_timer_runtime_fallback_reason ~= nil,
        ir_timer_runtime_fallback_reason = data.ir_timer_runtime_fallback_reason,
        ir_timer_runtime_mismatch = data.ir_timer_runtime_mismatch == true,
    }, source_result)
end

local function enrichIrTimerPayload(planned_job, data, payload, index, count, payload_depth)
    local branch = branchInfo(data, payload, index, count)
    local payload_launch = shallowCopy(planned_job.payload or {})
    payload_launch.actor = data.actor
    payload_launch.start_pos = data.start_pos
    payload_launch.direction = payload.direction or data.direction
    payload_launch.hit_object = data.hit_object
    payload_launch.cast_id = data.cast_id
    payload_launch.source_slot_id = data.source_slot_id
    payload_launch.source_helper_engine_id = data.source_helper_engine_id
    payload_launch.source_prefix_opcode = data.source_prefix_opcode
    payload_launch.source_postfix_opcode = "Timer"
    payload_launch.root_source_slot_id = payload.root_source_slot_id or data.root_source_slot_id
    payload_launch.current_source_slot_id = payload.current_source_slot_id or payload.slot_id
    payload_launch.parent_slot_id = payload.parent_slot_id or data.source_slot_id
    payload_launch.payload_depth = payload.payload_depth or payload_depth
    payload_launch.nested_stage_kind = payload.nested_stage_kind or data.nested_stage_kind
    payload_launch.nested_stage_index = payload.nested_stage_index or data.nested_stage_index
    payload_launch.has_trigger_payload = payload.has_trigger_payload
    payload_launch.has_timer_payload = payload.has_timer_payload
    payload_launch.payload_slot_id = payload.slot_id
    payload_launch.timer_source_slot_id = data.source_slot_id
    payload_launch.timer_payload_slot_id = payload.slot_id
    payload_launch.timer_id = data.timer_id
    payload_launch.timer_delay_ticks = data.delay_ticks
    payload_launch.timer_delay_seconds = data.delay_seconds
    payload_launch.timer_scheduled_tick = data.scheduled_tick
    payload_launch.timer_due_tick = data.due_tick
    payload_launch.timer_scheduled_seconds = data.scheduled_seconds
    payload_launch.timer_due_seconds = data.due_seconds
    payload_launch.timer_delay_semantics = "async_simulation_timer"
    payload_launch.timer_duplicate_key = shortKey(data.duplicate_key)
    payload_launch.bounce_runtime = data.bounce_runtime
    payload_launch.bounce_role = data.bounce_role
    payload_launch.bounce_id = data.bounce_id
    payload_launch.bounce_max = data.bounce_max
    payload_launch.bounce_power = data.bounce_power
    payload_launch.pierce_runtime = data.pierce_runtime
    payload_launch.pierce_role = data.pierce_role
    payload_launch.pierce_id = data.pierce_id
    payload_launch.pierce_limit = data.pierce_limit
    payload_launch.chain_runtime = data.chain_runtime
    payload_launch.chain_role = data.chain_role
    payload_launch.chain_id = data.chain_id
    payload_launch.chain_hop_index = data.chain_hop_index
    payload_launch.chain_max_hops = data.chain_max_hops
    payload_launch.chain_continuation_group_id = data.chain_continuation_group_id
    payload_launch.payload_multicast = data.payload_multicast == true
    payload_launch.payload_pattern = data.payload_pattern == true
    payload_launch.payload_count = count
    payload_launch.fanout_count = count
    payload_launch.emission_index = payload.emission_index
    payload_launch.group_index = payload.group_index
    payload_launch.pattern_kind = payload.pattern_kind
    payload_launch.pattern_index = payload.pattern_index
    payload_launch.pattern_count = payload.pattern_count
    payload_launch.pattern_direction_key = payload.pattern_direction_key
    payload_launch.nested_final_fanout = data.nested_final_fanout == true
    payload_launch.nested_final_fanout_kind = data.nested_final_fanout_kind
    payload_launch.final_fanout_count = data.nested_final_fanout == true and count or nil
    payload_launch.final_fanout_index = data.nested_final_fanout == true and index or nil
    copyBranchFields(payload_launch, branch)

    local job = shallowCopy(planned_job)
    job.kind = orchestrator.LIVE_TIMER_PAYLOAD_JOB_KIND
    job.recipe_id = data.recipe_id
    job.slot_id = payload.slot_id
    job.helper_engine_id = payload.helper_engine_id
    job.idempotency_key = string.format("%s:%s", tostring(data.duplicate_key), tostring(payload.slot_id))
    job.source_job_id = data.source_job_id
    job.parent_job_id = data.source_job_id
    job.depth = payload_depth
    job.cast_id = data.cast_id
    job.emission_index = payload.emission_index
    job.group_index = payload.group_index
    job.fanout_count = count
    job.max_live_launches_per_tick = data.max_live_launches_per_tick
    job.chaos_budget_profile = data.chaos_budget_profile
    job.root_source_slot_id = payload.root_source_slot_id or data.root_source_slot_id
    job.current_source_slot_id = payload.current_source_slot_id or payload.slot_id
    job.parent_slot_id = payload.parent_slot_id or data.source_slot_id
    job.payload_depth = payload.payload_depth or payload_depth
    job.nested_stage_kind = payload.nested_stage_kind or data.nested_stage_kind
    job.nested_stage_index = payload.nested_stage_index or data.nested_stage_index
    job.has_trigger_payload = payload.has_trigger_payload
    job.has_timer_payload = payload.has_timer_payload
    job.pattern_kind = payload.pattern_kind
    job.pattern_index = payload.pattern_index
    job.pattern_count = payload.pattern_count
    job.pattern_direction_key = payload.pattern_direction_key
    job.nested_final_fanout = data.nested_final_fanout == true
    job.nested_final_fanout_kind = data.nested_final_fanout_kind
    job.final_fanout_count = data.nested_final_fanout == true and count or nil
    job.final_fanout_index = data.nested_final_fanout == true and index or nil
    job.timer_async = true
    job.timer_id = data.timer_id
    job.source_slot_id = data.source_slot_id
    job.source_helper_engine_id = data.source_helper_engine_id
    job.source_prefix_opcode = data.source_prefix_opcode
    job.source_postfix_opcode = "Timer"
    job.payload_slot_id = payload.slot_id
    job.timer_source_slot_id = data.source_slot_id
    job.timer_payload_slot_id = payload.slot_id
    job.timer_delay_ticks = data.delay_ticks
    job.timer_delay_seconds = data.delay_seconds
    job.timer_scheduled_tick = data.scheduled_tick
    job.timer_due_tick = data.due_tick
    job.timer_scheduled_seconds = data.scheduled_seconds
    job.timer_due_seconds = data.due_seconds
    job.timer_delay_semantics = "async_simulation_timer"
    job.timer_duplicate_key = shortKey(data.duplicate_key)
    job.bounce_runtime = data.bounce_runtime
    job.bounce_role = data.bounce_role
    job.bounce_id = data.bounce_id
    job.bounce_max = data.bounce_max
    job.bounce_power = data.bounce_power
    job.pierce_runtime = data.pierce_runtime
    job.pierce_role = data.pierce_role
    job.pierce_id = data.pierce_id
    job.pierce_limit = data.pierce_limit
    job.chain_runtime = data.chain_runtime
    job.chain_role = data.chain_role
    job.chain_id = data.chain_id
    job.chain_hop_index = data.chain_hop_index
    job.chain_max_hops = data.chain_max_hops
    job.chain_continuation_group_id = data.chain_continuation_group_id
    copyBranchFields(job, branch)
    job.payload = payload_launch
    return job
end

local function noteIrTimerCallbackMismatch(data, reason)
    runtime_stats.inc("ir_timer_runtime_mismatch")
    runtime_stats.inc("ir_timer_runtime_fallback")
    data.ir_timer_runtime_fallback_reason = reason
    data.ir_timer_runtime_mismatch = true
    data.ir_timer_runtime = false
    log.info(string.format(
        "SPELLFORGE_IR_TIMER_RUNTIME_MISMATCH timer_id=%s recipe_id=%s cast_id=%s source_slot_id=%s reason=%s",
        tostring(data.timer_id),
        tostring(data.recipe_id),
        tostring(data.cast_id),
        tostring(data.source_slot_id),
        tostring(reason)
    ))
end

local function enqueueIrTimerRuntime(data, validated, source_result)
    if data.ir_timer_runtime ~= true then
        return nil
    end
    local job_plan = data.ir_timer_runtime_job_plan
    if type(job_plan) ~= "table" or job_plan.ok ~= true then
        noteIrTimerCallbackMismatch(data, "runtime_job_plan_missing")
        return nil
    end
    if tonumber(job_plan.planned_job_count) ~= #validated.payloads then
        noteIrTimerCallbackMismatch(data, "payload_count_mismatch")
        return nil
    end

    local job_ids = {}
    local payload_slot_ids = {}
    local payload_helper_engine_ids = {}
    for index, payload in ipairs(validated.payloads) do
        local planned_job = job_plan.planned_jobs and job_plan.planned_jobs[index] or nil
        if type(planned_job) ~= "table" then
            noteIrTimerCallbackMismatch(data, "planned_job_missing")
            return nil
        end
        if planned_job.slot_id ~= payload.slot_id or planned_job.payload_slot_id ~= payload.slot_id then
            noteIrTimerCallbackMismatch(data, "payload_slot_mismatch")
            return nil
        end
        if planned_job.helper_engine_id ~= payload.helper_engine_id then
            noteIrTimerCallbackMismatch(data, "payload_helper_mismatch")
            return nil
        end
        if planned_job.kind ~= orchestrator.LIVE_TIMER_PAYLOAD_JOB_KIND then
            noteIrTimerCallbackMismatch(data, "job_kind_mismatch")
            return nil
        end

        local job = enrichIrTimerPayload(planned_job, data, payload, index, #validated.payloads, validated.payload_depth)
        local enqueue = orchestrator.enqueue(job)
        if not enqueue.ok then
            runtime_stats.inc("live_timer_payload_route_failed")
            rememberTimerResult(mergeSourceDetonationResult({
                timer_id = data.timer_id,
                ok = false,
                error = enqueue.error or "IR timer payload enqueue failed",
                status = "enqueue_failed",
                job_ids = job_ids,
                ir_timer_runtime = true,
            }, source_result))
            return { ok = false, error = enqueue.error or "IR timer payload enqueue failed" }
        end
        job_ids[#job_ids + 1] = enqueue.job_id
        payload_slot_ids[#payload_slot_ids + 1] = payload.slot_id
        payload_helper_engine_ids[#payload_helper_engine_ids + 1] = payload.helper_engine_id
    end

    return recordTimerPayloadEnqueued(
        data,
        source_result,
        job_ids,
        payload_slot_ids,
        payload_helper_engine_ids,
        true
    )
end

local function enqueuePayloadFromTimer(data, source_result)
    local validated, validation_error = validateTimerData(data)
    if not validated then
        runtime_stats.inc("live_timer_payload_route_failed")
        rememberTimerResult(mergeSourceDetonationResult({
            timer_id = data and data.timer_id or "unknown",
            ok = false,
            error = validation_error,
            status = "validation_failed",
        }, source_result))
        return { ok = false, error = validation_error }
    end

    local ir_result = enqueueIrTimerRuntime(data, validated, source_result)
    if ir_result ~= nil then
        return ir_result
    end

    local job_ids = {}
    local payload_slot_ids = {}
    local payload_helper_engine_ids = {}
    for index, payload in ipairs(validated.payloads) do
        local payload_key = string.format("%s:%s", tostring(data.duplicate_key), tostring(payload.slot_id))
        local branch = branchInfo(data, payload, index, #validated.payloads)
        local payload_launch = {
            actor = data.actor,
            start_pos = data.start_pos,
            direction = payload.direction or data.direction,
            hit_object = data.hit_object,
            cast_id = data.cast_id,
            source_slot_id = data.source_slot_id,
            source_helper_engine_id = data.source_helper_engine_id,
            source_prefix_opcode = data.source_prefix_opcode,
            source_postfix_opcode = "Timer",
            root_source_slot_id = payload.root_source_slot_id or data.root_source_slot_id,
            current_source_slot_id = payload.current_source_slot_id or payload.slot_id,
            parent_slot_id = payload.parent_slot_id or data.source_slot_id,
            payload_depth = payload.payload_depth or validated.payload_depth,
            nested_stage_kind = payload.nested_stage_kind or data.nested_stage_kind,
            nested_stage_index = payload.nested_stage_index or data.nested_stage_index,
            has_trigger_payload = payload.has_trigger_payload,
            has_timer_payload = payload.has_timer_payload,
            payload_slot_id = payload.slot_id,
            timer_source_slot_id = data.source_slot_id,
            timer_payload_slot_id = payload.slot_id,
            timer_id = data.timer_id,
            timer_delay_ticks = data.delay_ticks,
            timer_delay_seconds = data.delay_seconds,
            timer_scheduled_tick = data.scheduled_tick,
            timer_due_tick = data.due_tick,
            timer_scheduled_seconds = data.scheduled_seconds,
            timer_due_seconds = data.due_seconds,
            timer_delay_semantics = "async_simulation_timer",
            timer_duplicate_key = shortKey(data.duplicate_key),
            bounce_runtime = data.bounce_runtime,
            bounce_role = data.bounce_role,
            bounce_id = data.bounce_id,
            bounce_max = data.bounce_max,
            bounce_power = data.bounce_power,
            pierce_runtime = data.pierce_runtime,
            pierce_role = data.pierce_role,
            pierce_id = data.pierce_id,
            pierce_limit = data.pierce_limit,
            chain_runtime = data.chain_runtime,
            chain_role = data.chain_role,
            chain_id = data.chain_id,
            chain_hop_index = data.chain_hop_index,
            chain_max_hops = data.chain_max_hops,
            chain_continuation_group_id = data.chain_continuation_group_id,
            payload_multicast = data.payload_multicast == true,
            payload_pattern = data.payload_pattern == true,
            payload_count = #validated.payloads,
            fanout_count = #validated.payloads,
            emission_index = payload.emission_index,
            group_index = payload.group_index,
            pattern_kind = payload.pattern_kind,
            pattern_index = payload.pattern_index,
            pattern_count = payload.pattern_count,
            pattern_direction_key = payload.pattern_direction_key,
            nested_final_fanout = data.nested_final_fanout == true,
            nested_final_fanout_kind = data.nested_final_fanout_kind,
            final_fanout_count = data.nested_final_fanout == true and #validated.payloads or nil,
            final_fanout_index = data.nested_final_fanout == true and index or nil,
        }
        copyBranchFields(payload_launch, branch)
        local enqueue = orchestrator.enqueue({
            kind = orchestrator.LIVE_TIMER_PAYLOAD_JOB_KIND,
            recipe_id = data.recipe_id,
            slot_id = payload.slot_id,
            helper_engine_id = payload.helper_engine_id,
            idempotency_key = payload_key,
            source_job_id = data.source_job_id,
            parent_job_id = data.source_job_id,
            depth = validated.payload_depth,
            cast_id = data.cast_id,
            emission_index = payload.emission_index,
            group_index = payload.group_index,
            fanout_count = #validated.payloads,
            max_live_launches_per_tick = data.max_live_launches_per_tick,
            chaos_budget_profile = data.chaos_budget_profile,
            root_source_slot_id = payload.root_source_slot_id or data.root_source_slot_id,
            current_source_slot_id = payload.current_source_slot_id or payload.slot_id,
            parent_slot_id = payload.parent_slot_id or data.source_slot_id,
            payload_depth = payload.payload_depth or validated.payload_depth,
            nested_stage_kind = payload.nested_stage_kind or data.nested_stage_kind,
            nested_stage_index = payload.nested_stage_index or data.nested_stage_index,
            has_trigger_payload = payload.has_trigger_payload,
            has_timer_payload = payload.has_timer_payload,
            pattern_kind = payload.pattern_kind,
            pattern_index = payload.pattern_index,
            pattern_count = payload.pattern_count,
            pattern_direction_key = payload.pattern_direction_key,
            nested_final_fanout = data.nested_final_fanout == true,
            nested_final_fanout_kind = data.nested_final_fanout_kind,
            final_fanout_count = data.nested_final_fanout == true and #validated.payloads or nil,
            final_fanout_index = data.nested_final_fanout == true and index or nil,
            timer_async = true,
            timer_id = data.timer_id,
            source_slot_id = data.source_slot_id,
            source_helper_engine_id = data.source_helper_engine_id,
            source_prefix_opcode = data.source_prefix_opcode,
            source_postfix_opcode = "Timer",
            payload_slot_id = payload.slot_id,
            timer_source_slot_id = data.source_slot_id,
            timer_payload_slot_id = payload.slot_id,
            timer_delay_ticks = data.delay_ticks,
            timer_delay_seconds = data.delay_seconds,
            timer_scheduled_tick = data.scheduled_tick,
            timer_due_tick = data.due_tick,
            timer_scheduled_seconds = data.scheduled_seconds,
            timer_due_seconds = data.due_seconds,
            timer_delay_semantics = "async_simulation_timer",
            timer_duplicate_key = shortKey(data.duplicate_key),
            bounce_runtime = data.bounce_runtime,
            bounce_role = data.bounce_role,
            bounce_id = data.bounce_id,
            bounce_max = data.bounce_max,
            bounce_power = data.bounce_power,
            pierce_runtime = data.pierce_runtime,
            pierce_role = data.pierce_role,
            pierce_id = data.pierce_id,
            pierce_limit = data.pierce_limit,
            chain_runtime = data.chain_runtime,
            chain_role = data.chain_role,
            chain_id = data.chain_id,
            chain_hop_index = data.chain_hop_index,
            chain_max_hops = data.chain_max_hops,
            chain_continuation_group_id = data.chain_continuation_group_id,
            branch_scope = branch.branch_scope,
            branch_id = branch.branch_id,
            branch_parent_id = branch.branch_parent_id,
            branch_kind = branch.branch_kind,
            branch_index = branch.branch_index,
            branch_count = branch.branch_count,
            chain_continuation_group_id = branch.chain_continuation_group_id,
            payload = payload_launch,
        })
        if not enqueue.ok then
            runtime_stats.inc("live_timer_payload_route_failed")
            rememberTimerResult(mergeSourceDetonationResult({
                timer_id = data.timer_id,
                ok = false,
                error = enqueue.error or "timer payload enqueue failed",
                status = "enqueue_failed",
                job_ids = job_ids,
            }, source_result))
            return { ok = false, error = enqueue.error or "timer payload enqueue failed" }
        end
        job_ids[#job_ids + 1] = enqueue.job_id
        payload_slot_ids[#payload_slot_ids + 1] = payload.slot_id
        payload_helper_engine_ids[#payload_helper_engine_ids + 1] = payload.helper_engine_id
    end

    return recordTimerPayloadEnqueued(
        data,
        source_result,
        job_ids,
        payload_slot_ids,
        payload_helper_engine_ids,
        false
    )
end

local function helperPresentation(helper_engine_id)
    local mapping = helper_records.getByEngineId(helper_engine_id)
    return mapping and mapping.presentation or nil
end

local function detonateTimerSource(data)
    if type(data) ~= "table" then
        return {
            source_detonation_status = "skipped_missing_timer_data",
            source_detonation_ok = false,
        }
    end

    runtime_stats.inc("timer_source_detonation_checked")
    local projectile_id = data.source_projectile_id
    local source_spell_id = data.source_helper_engine_id
    local caps = sfp_adapter.capabilities()
    if not caps.has_detonateSpellAtPos or not caps.has_cancelSpell then
        runtime_stats.inc("timer_source_detonation_blocked")
        return {
            source_detonation_status = "skipped_capability_unavailable",
            source_detonation_ok = false,
            source_cancel_ok = false,
            source_projectile_id = projectile_id,
        }
    end
    if type(projectile_id) ~= "string" or projectile_id == "" then
        runtime_stats.inc("timer_source_detonation_skipped")
        return {
            source_detonation_status = "skipped_no_projectile_id",
            source_detonation_ok = false,
            source_cancel_ok = false,
        }
    end
    if type(source_spell_id) ~= "string" or source_spell_id == "" or data.actor == nil then
        runtime_stats.inc("timer_source_detonation_failed")
        return {
            source_detonation_status = "failed_missing_source_context",
            source_detonation_ok = false,
            source_cancel_ok = false,
            source_projectile_id = projectile_id,
        }
    end

    local snapshot = sourceProjectileSnapshot(projectile_id, data.source_projectile_state)
    if snapshot and snapshot.position ~= nil and snapshot.cell == nil then
        snapshot.cell = safeReadField(data.actor, "cell")
    end
    if snapshot and snapshot.already_hit == true then
        runtime_stats.inc("timer_source_detonation_skipped")
        return {
            source_detonation_status = "skipped_already_hit",
            source_detonation_ok = false,
            source_cancel_ok = false,
            source_projectile_id = projectile_id,
            source_projectile_already_hit = true,
        }
    end
    if not snapshot or snapshot.position == nil or snapshot.cell == nil then
        runtime_stats.inc("timer_source_detonation_failed")
        log.info(string.format(
            "SPELLFORGE_LIVE_TIMER_SOURCE_DETONATION_SKIPPED timer_id=%s recipe_id=%s cast_id=%s source_slot_id=%s projectile_id=%s reason=missing_position_or_cell",
            tostring(data.timer_id),
            tostring(data.recipe_id),
            tostring(data.cast_id),
            tostring(data.source_slot_id),
            tostring(projectile_id)
        ))
        return {
            source_detonation_status = "failed_missing_position_or_cell",
            source_detonation_ok = false,
            source_cancel_ok = false,
            source_projectile_id = projectile_id,
            source_projectile_position_available = snapshot and snapshot.position ~= nil or false,
            source_projectile_cell_available = snapshot and snapshot.cell ~= nil or false,
        }
    end

    runtime_stats.inc("timer_source_detonation_attempts")
    local presentation = helperPresentation(source_spell_id)
    local detonate = sfp_adapter.detonateSpellAtPos({
        spellId = source_spell_id,
        caster = data.actor,
        position = snapshot.position,
        cell = snapshot.cell,
        areaVfxRecId = presentation and presentation.areaVfxRecId or nil,
        areaVfxScale = presentation and presentation.areaVfxScale or nil,
        userData = data.source_user_data,
        muteAudio = data.source_mute_audio,
        muteLight = data.source_mute_light,
    })
    local cancel = sfp_adapter.cancelSpell(projectile_id)
    if detonate.ok then
        runtime_stats.inc("timer_source_detonation_ok")
    else
        runtime_stats.inc("timer_source_detonation_failed")
    end
    if cancel.ok then
        runtime_stats.inc("timer_source_cancel_ok")
    else
        runtime_stats.inc("timer_source_cancel_failed")
    end

    local status = detonate.ok and "detonated" or "detonate_failed"
    log.info(string.format(
        "SPELLFORGE_LIVE_TIMER_SOURCE_DETONATED timer_id=%s recipe_id=%s cast_id=%s source_slot_id=%s helper_engine_id=%s projectile_id=%s status=%s cancel_ok=%s",
        tostring(data.timer_id),
        tostring(data.recipe_id),
        tostring(data.cast_id),
        tostring(data.source_slot_id),
        tostring(source_spell_id),
        tostring(projectile_id),
        tostring(status),
        tostring(cancel.ok == true)
    ))
    return {
        source_detonation_status = status,
        source_detonation_ok = detonate.ok == true,
        source_cancel_ok = cancel.ok == true,
        source_projectile_id = projectile_id,
        source_projectile_position_available = true,
        source_projectile_cell_available = true,
        source_detonation_from_projectile_object = snapshot.from_projectile_object == true,
        source_detonation_from_projectile_state = snapshot.from_projectile_state == true,
        source_detonation_error = detonate.ok and nil or detonate.error,
        source_cancel_error = cancel.ok and nil or cancel.error,
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
    if type(data) == "table" and data.nested_tt == true then
        runtime_stats.inc("nested_tt_timer_callbacks")
    end
    log.info(string.format(
        "SPELLFORGE_LIVE_TIMER_ASYNC_CALLBACK timer_id=%s found=%s",
        tostring(timer_id),
        tostring(found)
    ))
    if type(data) == "table" and data.chain_runtime == true and data.source_prefix_opcode == "Chain" then
        runtime_stats.inc("chain_timer_side_payload_matured")
        log.info(string.format(
            "SPELLFORGE_CHAIN_TIMER_SIDE_PAYLOAD_MATURED timer_id=%s recipe_id=%s cast_id=%s chain_id=%s hop_index=%s found=%s",
            tostring(timer_id),
            tostring(data.recipe_id),
            tostring(data.cast_id),
            tostring(data.chain_id),
            tostring(data.chain_hop_index),
            tostring(found)
        ))
    end
    local source_result = detonateTimerSource(data)
    return enqueuePayloadFromTimer(data, source_result)
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
    if type(binding) ~= "table" then
        runtime_stats.inc("live_timer_payload_route_failed")
        return { ok = false, error = "missing timer binding" }
    end

    local payloads = compactPayloadsFromBinding(binding)
    if #payloads == 0 then
        runtime_stats.inc("live_timer_payload_missing")
        runtime_stats.inc("live_timer_payload_route_failed")
        return { ok = false, error = "timer payload helper mapping missing" }
    end
    local max_payload_fanout = tonumber(binding.max_payload_fanout) or limits.MAX_NESTED_PAYLOAD_FANOUT
    local max_projectiles = tonumber(binding.max_projectiles) or limits.MAX_PROJECTILES_PER_CAST
    if #payloads > max_payload_fanout or #payloads > max_projectiles then
        runtime_stats.inc("live_timer_payload_route_failed")
        runtime_stats.inc("payload_multicast_cap_reject")
        return { ok = false, error = "timer payload multicast fanout exceeds cap" }
    end
    for _, payload in ipairs(payloads) do
        local payload_mapping = helper_records.getByRecipeSlot(binding.recipe_id, payload.slot_id)
            or helper_records.getByEngineId(payload.helper_engine_id)
        if not payload_mapping or payload_mapping.engine_id ~= payload.helper_engine_id then
            runtime_stats.inc("live_timer_payload_missing")
            runtime_stats.inc("live_timer_payload_route_failed")
            return { ok = false, error = "timer payload helper mapping missing" }
        end
        if payload_mapping.source_postfix_opcode ~= "Timer"
            or payload_mapping.timer_source_slot_id ~= binding.source_slot_id then
            runtime_stats.inc("live_timer_payload_route_failed")
            return { ok = false, error = "timer payload helper mapping mismatch" }
        end
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

    local pattern_info = nil
    if binding.payload_pattern == true then
        local pattern_err = nil
        pattern_info, pattern_err = payload_pattern.compute(payloads, resolution.timer_direction, binding.payload_pattern_kind, binding.payload_pattern_op)
        if not pattern_info then
            runtime_stats.inc("live_timer_payload_route_failed")
            runtime_stats.inc("payload_pattern_rejected")
            runtime_stats.inc("payload_pattern_nested_reject")
            return { ok = false, error = pattern_err or "timer payload pattern direction failed" }
        end
        payloads = pattern_info.payloads
    end

    local key = duplicateKey(binding, options)
    if schedule_keys[key] then
        runtime_stats.inc("live_timer_duplicate_schedules_suppressed")
        runtime_stats.inc("live_timer_async_duplicate_suppressed")
        if binding.nested_tt == true then
            runtime_stats.inc("nested_tt_duplicate_suppressed")
        end
        if binding.nested_final_fanout == true then
            runtime_stats.inc("nested_final_fanout_duplicate_suppressed")
        end
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
            payload_slot_ids = payloadSlotIds(payloads),
            payload_count = #payloads,
            payload_multicast = binding.payload_multicast == true,
            payload_pattern = binding.payload_pattern == true,
            payload_pattern_kind = binding.payload_pattern_kind,
            nested_final_fanout = binding.nested_final_fanout == true,
            nested_final_fanout_kind = binding.nested_final_fanout_kind,
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
    local ir_runtime = buildIrTimerRuntimePlan(binding, payloads, options, {
        timer_id = timer_id,
        delay_ticks = delay_ticks,
        delay_seconds = delay_seconds,
        due_tick = due_tick,
        due_seconds = due_seconds,
    })
    local timer_data = {
        schema = "spellforge_live_timer_async_v1",
        timer_id = timer_id,
        recipe_id = binding.recipe_id,
        cast_id = binding.cast_id,
        source_job_id = binding.source_job_id,
        source_projectile_id = options.source_projectile_id or binding.source_projectile_id,
        source_user_data = options.source_user_data or binding.source_user_data,
        source_mute_audio = options.source_mute_audio or binding.source_mute_audio,
        source_mute_light = options.source_mute_light or binding.source_mute_light,
        source_slot_id = binding.source_slot_id,
        source_helper_engine_id = binding.source_helper_engine_id,
        source_prefix_opcode = binding.source_prefix_opcode,
        source_postfix_opcode = "Timer",
        bounce_runtime = binding.source_prefix_opcode == "Bounce" and true or nil,
        bounce_role = binding.source_prefix_opcode == "Bounce" and "source" or nil,
        bounce_id = binding.bounce_id,
        bounce_max = binding.bounce_max,
        bounce_power = binding.bounce_power,
        pierce_runtime = binding.source_prefix_opcode == "Pierce" and true or nil,
        pierce_role = binding.source_prefix_opcode == "Pierce" and "source" or nil,
        pierce_id = binding.pierce_id,
        pierce_limit = binding.pierce_limit,
        chain_runtime = binding.chain_runtime,
        chain_role = binding.chain_role,
        chain_id = binding.chain_id,
        chain_hop_index = binding.chain_hop_index,
        chain_max_hops = binding.chain_max_hops,
        chain_continuation_group_id = binding.chain_continuation_group_id
            or (binding.source_user_data and binding.source_user_data.chain_continuation_group_id),
        payload_slot_id = binding.payload_slot_id,
        payload_helper_engine_id = binding.payload_helper_engine_id,
        payloads = payloads,
        payload_slot_ids = payloadSlotIds(payloads),
        payload_count = #payloads,
        payload_multicast = binding.payload_multicast == true,
        payload_pattern = binding.payload_pattern == true,
        payload_pattern_kind = binding.payload_pattern_kind,
        branch_scope = branchScope(binding),
        branch_parent_id = branchParentId(binding),
        branch_kind = branchKind(binding, #payloads),
        branch_count = #payloads,
        chain_continuation_group_id = binding.chain_continuation_group_id
            or (binding.source_user_data and binding.source_user_data.chain_continuation_group_id),
        max_payload_fanout = max_payload_fanout,
        max_projectiles = max_projectiles,
        max_jobs_per_tick = tonumber(binding.max_jobs_per_tick) or limits.MAX_JOBS_PER_TICK,
        max_live_launches_per_tick = tonumber(binding.max_live_launches_per_tick) or limits.MAX_LIVE_LAUNCHES_PER_TICK,
        chaos_budget_profile = binding.chaos_budget_profile,
        allow_pending_launch_jobs = binding.allow_pending_launch_jobs == true,
        payload_pattern_count = pattern_info and pattern_info.pattern_count or nil,
        payload_pattern_direction_keys = pattern_info and pattern_info.direction_keys or nil,
        root_source_slot_id = binding.root_source_slot_id or binding.source_slot_id,
        current_source_slot_id = binding.current_source_slot_id or binding.source_slot_id,
        parent_slot_id = binding.parent_slot_id,
        nested_stage_kind = binding.nested_stage_kind,
        nested_stage_index = binding.nested_stage_index,
        nested_tt = binding.nested_tt == true,
        nested_tt_kind = binding.nested_tt_kind,
        nested_tt_payload_role = binding.nested_tt_payload_role,
        nested_final_fanout = binding.nested_final_fanout == true,
        nested_final_fanout_kind = binding.nested_final_fanout_kind,
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
        ir_timer_runtime = ir_runtime and ir_runtime.ok == true or false,
        ir_timer_runtime_job_plan = ir_runtime and ir_runtime.ok == true and ir_runtime.job_plan or nil,
        ir_timer_runtime_fallback_reason = ir_runtime and ir_runtime.fallback and ir_runtime.reason or nil,
        ir_timer_runtime_mismatch = ir_runtime and ir_runtime.mismatch == true or false,
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
        "SPELLFORGE_LIVE_TIMER_ASYNC_SCHEDULED timer_id=%s recipe_id=%s cast_id=%s source_slot_id=%s payload_slot_id=%s branch_parent_id=%s branch_kind=%s delay_seconds=%s",
        tostring(timer_id),
        tostring(binding.recipe_id),
        tostring(binding.cast_id),
        tostring(binding.source_slot_id),
        tostring(binding.payload_slot_id),
        tostring(timer_data.branch_parent_id),
        tostring(timer_data.branch_kind),
        tostring(delay_seconds)
    ))
    if timer_data.chain_runtime == true and timer_data.source_prefix_opcode == "Chain" then
        runtime_stats.inc("chain_timer_side_payload_scheduled")
        log.info(string.format(
            "SPELLFORGE_CHAIN_TIMER_SIDE_PAYLOAD_SCHEDULED timer_id=%s recipe_id=%s cast_id=%s chain_id=%s hop_index=%s source_slot_id=%s payload_count=%s",
            tostring(timer_id),
            tostring(binding.recipe_id),
            tostring(binding.cast_id),
            tostring(timer_data.chain_id),
            tostring(timer_data.chain_hop_index),
            tostring(binding.source_slot_id),
            tostring(#payloads)
        ))
    end

    return {
        ok = true,
        async_scheduled = true,
        timer_id = timer_id,
        duplicate_key = key,
        source_slot_id = binding.source_slot_id,
        payload_slot_id = binding.payload_slot_id,
        payload_helper_engine_id = binding.payload_helper_engine_id,
        payload_slot_ids = payloadSlotIds(payloads),
        payload_count = #payloads,
        payload_multicast = binding.payload_multicast == true,
        payload_pattern = binding.payload_pattern == true,
        payload_pattern_kind = binding.payload_pattern_kind,
        payload_pattern_count = pattern_info and pattern_info.pattern_count or nil,
        payload_pattern_direction_keys = pattern_info and pattern_info.direction_keys or nil,
        nested_final_fanout = binding.nested_final_fanout == true,
        nested_final_fanout_kind = binding.nested_final_fanout_kind,
        timer_delay_ticks = delay_ticks,
        timer_delay_seconds = delay_seconds,
        timer_scheduled_tick = scheduled_tick,
        timer_due_tick = due_tick,
        timer_scheduled_seconds = scheduled_seconds,
        timer_due_seconds = due_seconds,
        ttl_seconds = ttl_seconds,
        pending_count = pendingCount(),
        timer_delay_semantics = "async_simulation_timer",
        ir_timer_runtime_planned = ir_runtime and ir_runtime.ok == true or false,
        ir_timer_runtime_fallback_used = ir_runtime and ir_runtime.fallback == true or false,
        ir_timer_runtime_fallback_reason = ir_runtime and ir_runtime.fallback and ir_runtime.reason or nil,
        ir_timer_runtime_mismatch = ir_runtime and ir_runtime.mismatch == true or false,
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
    local job_ids = {}
    if result and type(result.job_ids) == "table" then
        for index, job_id in ipairs(result.job_ids) do
            job_ids[index] = job_id
        end
    elseif result and result.job_id then
        job_ids[1] = result.job_id
    end
    local jobs = {}
    local payload_launch_count = 0
    for index, job_id in ipairs(job_ids) do
        local payload_job = orchestrator.getJob(job_id)
        jobs[index] = payload_job and {
            job_id = job_id,
            job_status = payload_job.status,
            slot_id = payload_job.slot_id,
            helper_engine_id = payload_job.helper_engine_id,
            cast_id = payload_job.cast_id,
            emission_index = payload_job.emission_index,
            group_index = payload_job.group_index,
            fanout_count = payload_job.fanout_count,
            root_source_slot_id = payload_job.root_source_slot_id,
            current_source_slot_id = payload_job.current_source_slot_id,
            parent_slot_id = payload_job.parent_slot_id,
            payload_depth = payload_job.payload_depth,
            nested_stage_kind = payload_job.nested_stage_kind,
            nested_stage_index = payload_job.nested_stage_index,
            branch_scope = payload_job.branch_scope,
            branch_id = payload_job.branch_id,
            branch_parent_id = payload_job.branch_parent_id,
            branch_kind = payload_job.branch_kind,
            branch_index = payload_job.branch_index,
            branch_count = payload_job.branch_count,
            chain_continuation_group_id = payload_job.chain_continuation_group_id,
            pattern_kind = payload_job.pattern_kind,
            pattern_index = payload_job.pattern_index,
            pattern_count = payload_job.pattern_count,
            pattern_direction_key = payload_job.pattern_direction_key,
            source_slot_id = payload_job.source_slot_id,
            source_helper_engine_id = payload_job.source_helper_engine_id,
            source_postfix_opcode = payload_job.source_postfix_opcode,
            payload_slot_id = payload_job.payload_slot_id,
            timer_source_slot_id = payload_job.timer_source_slot_id,
            timer_payload_slot_id = payload_job.timer_payload_slot_id,
            timer_id = payload_job.timer_id,
            timer_delay_ticks = payload_job.timer_delay_ticks,
            timer_delay_seconds = payload_job.timer_delay_seconds,
            timer_due_tick = payload_job.timer_due_tick,
            timer_due_seconds = payload_job.timer_due_seconds,
            timer_delay_semantics = payload_job.timer_delay_semantics,
            launch_accepted = payload_job.launch_accepted == true,
            launch_direction = payload_job.launch_direction,
            projectile_id = payload_job.projectile_id,
            launch_user_data = payload_job.launch_user_data,
            error = payload_job.error,
        } or nil
        if payload_job and payload_job.status == "complete" and payload_job.launch_accepted == true then
            payload_launch_count = payload_launch_count + 1
        end
    end
    local job = jobs[1]
    return {
        timer_id = timer_id,
        pending = pending ~= nil,
        pending_count = pendingCount(),
        callback_seen = result ~= nil,
        callback_ok = result and result.ok == true or false,
        callback_status = result and result.status or nil,
        callback_error = result and result.error or nil,
        payload_job_id = result and result.job_id or nil,
        payload_job_ids = job_ids,
        payload_jobs = jobs,
        payload_job_status = job and job.job_status or nil,
        payload_launch_accepted = job and job.launch_accepted == true or false,
        payload_launch_count = payload_launch_count,
        payload_launch_user_data = job and job.launch_user_data or nil,
        payload_projectile_id = job and job.projectile_id or nil,
        source_projectile_id = (pending and pending.source_projectile_id) or (result and result.source_projectile_id) or nil,
        source_detonation_status = result and result.source_detonation_status or nil,
        source_detonation_ok = result and result.source_detonation_ok == true or false,
        source_cancel_ok = result and result.source_cancel_ok == true or false,
        source_projectile_position_available = result and result.source_projectile_position_available == true or false,
        source_projectile_cell_available = result and result.source_projectile_cell_available == true or false,
        source_projectile_already_hit = result and result.source_projectile_already_hit == true or false,
        source_detonation_error = result and result.source_detonation_error or nil,
        source_cancel_error = result and result.source_cancel_error or nil,
        cast_id = (pending and pending.cast_id) or (result and result.cast_id) or (job and job.cast_id) or nil,
        source_slot_id = (pending and pending.source_slot_id) or (result and result.source_slot_id) or (job and job.source_slot_id) or nil,
        source_helper_engine_id = (pending and pending.source_helper_engine_id) or (result and result.source_helper_engine_id) or (job and job.source_helper_engine_id) or nil,
        payload_slot_id = (pending and pending.payload_slot_id) or (result and result.payload_slot_id) or (job and job.payload_slot_id) or nil,
        payload_helper_engine_id = (pending and pending.payload_helper_engine_id) or (result and result.payload_helper_engine_id) or (job and job.helper_engine_id) or nil,
        payload_slot_ids = (pending and pending.payload_slot_ids) or (result and result.payload_slot_ids) or nil,
        payload_helper_engine_ids = (result and result.payload_helper_engine_ids) or nil,
        payload_count = (pending and pending.payload_count) or (result and result.payload_count) or #job_ids,
        payload_multicast = (pending and pending.payload_multicast == true) or (result and result.payload_multicast == true) or false,
        payload_pattern = (pending and pending.payload_pattern == true) or (result and result.payload_pattern == true) or false,
        payload_pattern_kind = (pending and pending.payload_pattern_kind) or (result and result.payload_pattern_kind) or nil,
        payload_pattern_direction_keys = (pending and pending.payload_pattern_direction_keys) or (result and result.payload_pattern_direction_keys) or nil,
        ir_timer_runtime_planned = pending and pending.ir_timer_runtime == true or false,
        ir_timer_runtime = result and result.ir_timer_runtime == true or false,
        ir_timer_runtime_job_count = result and result.ir_timer_runtime_job_count or nil,
        ir_timer_runtime_fallback_used = (pending and pending.ir_timer_runtime_fallback_reason ~= nil)
            or (result and result.ir_timer_runtime_fallback_used == true)
            or false,
        ir_timer_runtime_fallback_reason = (pending and pending.ir_timer_runtime_fallback_reason)
            or (result and result.ir_timer_runtime_fallback_reason)
            or nil,
        ir_timer_runtime_mismatch = (pending and pending.ir_timer_runtime_mismatch == true)
            or (result and result.ir_timer_runtime_mismatch == true)
            or false,
        nested_tt = (pending and pending.nested_tt == true) or (result and result.nested_tt == true) or false,
        nested_tt_kind = (pending and pending.nested_tt_kind) or (result and result.nested_tt_kind) or nil,
        nested_tt_payload_role = (pending and pending.nested_tt_payload_role) or (result and result.nested_tt_payload_role) or nil,
        nested_final_fanout = (pending and pending.nested_final_fanout == true)
            or (result and result.nested_final_fanout == true)
            or false,
        nested_final_fanout_kind = (pending and pending.nested_final_fanout_kind)
            or (result and result.nested_final_fanout_kind)
            or nil,
        timer_delay_ticks = (pending and pending.delay_ticks) or (job and job.timer_delay_ticks) or nil,
        timer_delay_seconds = (pending and pending.delay_seconds) or (job and job.timer_delay_seconds) or nil,
        timer_due_tick = (pending and pending.due_tick) or (job and job.timer_due_tick) or nil,
        timer_due_seconds = (pending and pending.due_seconds) or (job and job.timer_due_seconds) or nil,
    }
end

return live_timer
