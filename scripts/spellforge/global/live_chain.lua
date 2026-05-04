local async = require("openmw.async")
local util = require("openmw.util")
local ok_types, types = pcall(require, "openmw.types")

local dev = require("scripts.spellforge.shared.dev")
local events = require("scripts.spellforge.shared.events")
local limits = require("scripts.spellforge.shared.limits")
local log = require("scripts.spellforge.shared.log").new("global.live_chain")
local sfp_userdata = require("scripts.spellforge.shared.sfp_userdata")
local chain_target_provider = require("scripts.spellforge.global.chain_target_provider")
local chain_targeting = require("scripts.spellforge.global.chain_targeting")
local helper_records = require("scripts.spellforge.global.helper_records")
local live_size_plus = require("scripts.spellforge.global.live_size_plus")
local live_speed_plus = require("scripts.spellforge.global.live_speed_plus")
local orchestrator = require("scripts.spellforge.global.orchestrator")
local runtime_hits = require("scripts.spellforge.global.runtime_hits")
local runtime_stats = require("scripts.spellforge.global.runtime_stats")

local live_chain = {}

local MAX_BINDINGS = 128
local MAX_DUPLICATE_KEYS = 512
local MAX_PENDING_LOS = 64
local LOS_TIMEOUT_SECONDS = 0.5

local bindings_by_cast_source = {}
local bindings_by_chain_id = {}
local binding_order = {}
local duplicate_keys = {}
local duplicate_order = {}
local continuation_claims = {}
local continuation_claim_order = {}
local pending_los = {}
local pending_los_order = {}
local next_los_request_index = 0

local function appendBounded(order, key, max_count, on_evict)
    order[#order + 1] = key
    while #order > max_count do
        local evicted = table.remove(order, 1)
        if on_evict then
            on_evict(evicted)
        end
    end
end

local function castSourceKey(recipe_id, slot_id, cast_id)
    return string.format("%s::%s::%s", tostring(recipe_id), tostring(slot_id), tostring(cast_id))
end

local function hasOps(ops)
    return type(ops) == "table" and #ops > 0
end

local function hasPayloadBindings(value)
    return type(value) == "table" and #value > 0
end

local function countOpcode(ops, opcode)
    local count = 0
    local first = nil
    for _, op in ipairs(ops or {}) do
        if op and op.opcode == opcode then
            count = count + 1
            first = first or op
        end
    end
    return count, first
end

local function analyzePayloadPrefixOps(ops)
    local info = {
        chain_count = 0,
        chain_op = nil,
        speed_count = 0,
        speed_op = nil,
        size_count = 0,
        size_op = nil,
        multicast_count = 0,
        multicast_op = nil,
        unsupported_count = 0,
        unsupported_opcode = nil,
    }
    for _, op in ipairs(ops or {}) do
        if op and op.opcode == "Chain" then
            info.chain_count = info.chain_count + 1
            info.chain_op = info.chain_op or op
        elseif op and op.opcode == "Speed+" then
            info.speed_count = info.speed_count + 1
            info.speed_op = info.speed_op or op
        elseif op and op.opcode == "Size+" then
            info.size_count = info.size_count + 1
            info.size_op = info.size_op or op
        elseif op and op.opcode == "Multicast" then
            info.multicast_count = info.multicast_count + 1
            info.multicast_op = info.multicast_op or op
        else
            info.unsupported_count = info.unsupported_count + 1
            info.unsupported_opcode = info.unsupported_opcode or (op and op.opcode)
        end
    end
    return info
end

local function multicastFanout(op)
    local count = tonumber(op and op.params and op.params.count) or 1
    if count ~= count or count == math.huge or count == -math.huge then
        return 1
    end
    return math.max(1, math.floor(count))
end

local function chainMulticastEnabled(options)
    if options.force_chain_multicast_disabled == true then
        return false
    end
    return options.force_chain_multicast_enabled == true
        or options.allow_chain_multicast == true
        or options.chain_multicast_enabled == true
        or dev.liveChainMulticastEnabled()
end

local function modifierEnabled(kind, options)
    if kind == "speed_plus" then
        if options.force_speed_plus_disabled == true then
            return false
        end
        return options.force_speed_plus_enabled == true
            or options.speed_plus_enabled == true
            or dev.liveSpeedPlusEnabled()
    elseif kind == "size_plus" then
        if options.force_size_plus_disabled == true then
            return false
        end
        return options.force_size_plus_enabled == true
            or options.size_plus_enabled == true
            or dev.liveSizePlusEnabled()
    end
    return true
end

local function copyModifierFields(target, mutation, kind)
    if type(target) ~= "table" or type(mutation) ~= "table" then
        return
    end
    target.payload_modifier_kind = kind
    if kind == "speed_plus" then
        target.speed = mutation.speed_plus_speed
        target.maxSpeed = mutation.speed_plus_max_speed
        target.speed_plus = true
        target.speed_plus_mode = mutation.speed_plus_mode
        target.speed_plus_value = mutation.speed_plus_value
        target.speed_plus_base_speed = mutation.speed_plus_base_speed
        target.speed_plus_multiplier = mutation.speed_plus_multiplier
        target.speed_plus_speed = mutation.speed_plus_speed
        target.speed_plus_max_speed = mutation.speed_plus_max_speed
        target.speed_plus_field = mutation.speed_plus_field
        target.speed_plus_capped = mutation.speed_plus_capped
    elseif kind == "size_plus" then
        target.size_plus = true
        target.size_plus_mode = mutation.size_plus_mode
        target.size_plus_value = mutation.size_plus_value
        target.size_plus_multiplier = mutation.size_plus_multiplier
        target.size_plus_field = mutation.size_plus_field
        target.size_plus_capped = mutation.size_plus_capped
        target.size_plus_base_area = mutation.size_plus_base_area
        target.size_plus_area = mutation.size_plus_area
    end
end

local function clonePayload(payload)
    local out = {}
    for key, value in pairs(payload or {}) do
        out[key] = value
    end
    return out
end

local function cloneJobInput(job)
    local out = {}
    for key, value in pairs(job or {}) do
        if key == "payload" then
            out.payload = clonePayload(value)
        else
            out[key] = value
        end
    end
    return out
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

local function slotById(slots)
    local by_slot = {}
    for _, slot in ipairs(slots or {}) do
        if type(slot) == "table" and type(slot.slot_id) == "string" then
            by_slot[slot.slot_id] = slot
        end
    end
    return by_slot
end

local function firstEffectId(helper)
    local first = helper and helper.effects and helper.effects[1] or nil
    return first and first.id or nil
end

local function objectToken(value)
    if value == nil then
        return nil
    end
    local value_type = type(value)
    if value_type ~= "table" then
        return tostring(value)
    end
    if value_type == "table" then
        return value.id
            or value.recordId
            or value.refId
            or value.name
            or objectToken(value.object)
    end
    return tostring(value)
end

local function cellToken(value)
    if value == nil then
        return nil
    end
    if type(value) == "table" then
        return value.id or value.name or tostring(value)
    end
    return tostring(value)
end

local function tablePosition(value)
    if value == nil then
        return nil
    end
    local direct_ok, direct_x = pcall(function()
        return value.x
    end)
    local direct_y = nil
    if direct_ok then
        local ok_y, y = pcall(function()
            return value.y
        end)
        if ok_y then
            direct_y = y
        end
    end
    if direct_ok and direct_x ~= nil and direct_y ~= nil then
        return value
    end
    local ok, position = pcall(function()
        return value.position
    end)
    if ok and position ~= nil then
        return position
    end
    return nil
end

local function positionComponent(position, key)
    if position == nil then
        return 0
    end
    local ok, value = pcall(function()
        return position[key]
    end)
    if ok then
        return tonumber(value) or 0
    end
    return 0
end

local function elevatedPosition(position, height)
    if position == nil then
        return nil
    end
    return {
        x = positionComponent(position, "x"),
        y = positionComponent(position, "y"),
        z = positionComponent(position, "z") + (tonumber(height) or 0),
    }
end

local function targetIsKnownNonActor(value)
    if value == nil then
        return false
    end
    if type(value) == "table" then
        if value.is_actor ~= nil then
            return value.is_actor ~= true
        end
        if value.object ~= nil then
            return targetIsKnownNonActor(value.object)
        end
    end
    if not ok_types or not types or not types.Actor or not types.Actor.stats
        or not types.Actor.stats.dynamic or type(types.Actor.stats.dynamic.health) ~= "function" then
        return false
    end
    local ok, health = pcall(types.Actor.stats.dynamic.health, value)
    return not (ok and health ~= nil)
end

local function vectorFromPosition(value)
    local position = tablePosition(value)
    if not position then
        return nil
    end
    return util.vector3(
        tonumber(position.x) or 0,
        tonumber(position.y) or 0,
        tonumber(position.z) or 0
    )
end

local function directionBetween(origin_value, target_value)
    local origin = tablePosition(origin_value)
    local target = tablePosition(target_value)
    if not origin or not target then
        return nil, "chain_target_direction_missing"
    end
    local dx = (tonumber(target.x) or 0) - (tonumber(origin.x) or 0)
    local dy = (tonumber(target.y) or 0) - (tonumber(origin.y) or 0)
    local dz = (tonumber(target.z) or 0) - (tonumber(origin.z) or 0)
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    if length <= 0 then
        return nil, "chain_target_direction_zero"
    end
    return util.vector3(dx / length, dy / length, dz / length), nil
end

local function candidateObjectForSelected(candidates, selected_id)
    for _, candidate in ipairs(candidates or {}) do
        local id = candidate and (candidate.id or objectToken(candidate.object) or objectToken(candidate))
        if tostring(id) == tostring(selected_id) then
            return candidate.object
        end
    end
    return nil
end

local function candidateToken(candidate, index)
    return tostring(candidate and (candidate.id or objectToken(candidate.object) or objectToken(candidate)) or ("candidate_" .. tostring(index)))
end

local function isCandidateDescriptor(value)
    return type(value) == "table"
        and (value.id ~= nil or value.object ~= nil or value.position ~= nil or value.distance_override ~= nil)
end

local function isCandidateList(value)
    return type(value) == "table" and isCandidateDescriptor(value[1])
end

local function candidatesForHop(provider, hop_context)
    if type(provider) == "function" then
        return provider(hop_context)
    end
    if type(provider) ~= "table" then
        return nil
    end
    local keyed = provider[hop_context.hop_index]
    if isCandidateList(keyed) then
        return keyed
    end
    if isCandidateList(provider) then
        return provider
    end
    return nil
end

local function collectCandidates(provider, hop_context, binding, options)
    if provider ~= nil then
        runtime_stats.inc("chain_provider_attempts")
        runtime_stats.inc("chain_provider_mock_attempts")
        local candidates = candidatesForHop(provider, hop_context)
        local count = type(candidates) == "table" and #candidates or 0
        runtime_stats.inc("chain_provider_candidates_returned", count)
        if candidates then
            runtime_stats.inc("chain_provider_selected_mock")
            log.info(string.format(
                "SPELLFORGE_CHAIN_PROVIDER_MOCK_OK recipe_id=%s cast_id=%s chain_id=%s hop_index=%s candidate_count=%s",
                tostring(hop_context and hop_context.recipe_id or nil),
                tostring(hop_context and hop_context.cast_id or nil),
                tostring(hop_context and hop_context.chain_id or nil),
                tostring(hop_context and hop_context.hop_index or nil),
                tostring(count)
            ))
        end
        return candidates, {
            ok = candidates ~= nil,
            provider = "mock",
            candidate_count = count,
            candidates = candidates,
            rejection_reason = candidates == nil and "chain_target_provider_missing" or nil,
        }
    end

    local collected = chain_target_provider.collectCandidates(hop_context, {
        radius = binding and binding.scan_radius or limits.MAX_CHAIN_SCAN_RADIUS,
        max_radius = limits.MAX_CHAIN_SCAN_RADIUS,
        candidate_cap = binding and binding.candidate_cap or limits.MAX_CHAIN_SCAN_CANDIDATES,
    })
    if collected and collected.ok then
        return collected.candidates or {}, collected
    end
    return nil, collected
end

local function compactJob(job_id)
    local job = orchestrator.getJob(job_id)
    local payload = job and job.payload or nil
    return {
        job_id = job_id,
        job_status = job and job.status or nil,
        slot_id = job and job.slot_id or nil,
        helper_engine_id = job and job.helper_engine_id or nil,
        cast_id = job and job.cast_id or nil,
        emission_index = job and job.emission_index or nil,
        group_index = job and job.group_index or nil,
        source_slot_id = job and job.source_slot_id or nil,
        payload_slot_id = job and job.payload_slot_id or nil,
        root_source_slot_id = job and (job.root_source_slot_id or (payload and payload.root_source_slot_id)) or nil,
        chain_runtime = job and (job.chain_runtime or (payload and payload.chain_runtime)) or nil,
        chain_role = job and (job.chain_role or (payload and payload.chain_role)) or nil,
        chain_id = job and (job.chain_id or (payload and payload.chain_id)) or nil,
        chain_hop_index = job and (job.chain_hop_index or (payload and payload.chain_hop_index)) or nil,
        chain_max_hops = job and (job.chain_max_hops or (payload and payload.chain_max_hops)) or nil,
        chain_targeting_mode = job and (job.chain_targeting_mode or (payload and payload.chain_targeting_mode)) or nil,
        chain_target_provider = job and (job.chain_target_provider or (payload and payload.chain_target_provider)) or nil,
        branch_scope = job and (job.branch_scope or (payload and payload.branch_scope)) or nil,
        branch_id = job and (job.branch_id or (payload and payload.branch_id)) or nil,
        branch_parent_id = job and (job.branch_parent_id or (payload and payload.branch_parent_id)) or nil,
        branch_kind = job and (job.branch_kind or (payload and payload.branch_kind)) or nil,
        branch_index = job and (job.branch_index or (payload and payload.branch_index)) or nil,
        branch_count = job and (job.branch_count or (payload and payload.branch_count)) or nil,
        bounce_runtime = job and ((job.bounce_runtime or (payload and payload.bounce_runtime)) == true) or false,
        bounce_role = job and (job.bounce_role or (payload and payload.bounce_role)) or nil,
        bounce_id = job and (job.bounce_id or (payload and payload.bounce_id)) or nil,
        bounce_index = job and (job.bounce_index or (payload and payload.bounce_index)) or nil,
        bounce_final = job and ((job.bounce_final or (payload and payload.bounce_final)) == true) or false,
        chain_continuation_group_id = job and (job.chain_continuation_group_id or (payload and payload.chain_continuation_group_id)) or nil,
        current_hit_target_id = job and (job.current_hit_target_id or (payload and payload.current_hit_target_id)) or nil,
        selected_target_id = job and (job.selected_target_id or (payload and payload.selected_target_id)) or nil,
        previous_projectile_id = job and (job.previous_projectile_id or (payload and payload.previous_projectile_id)) or nil,
        payload_modifier_kind = job and (job.payload_modifier_kind or (payload and payload.payload_modifier_kind)) or nil,
        speed = job and (job.speed or (payload and payload.speed)) or nil,
        maxSpeed = job and (job.maxSpeed or (payload and payload.maxSpeed)) or nil,
        speed_plus = job and (job.speed_plus or (payload and payload.speed_plus)) or nil,
        speed_plus_mode = job and (job.speed_plus_mode or (payload and payload.speed_plus_mode)) or nil,
        speed_plus_value = job and (job.speed_plus_value or (payload and payload.speed_plus_value)) or nil,
        speed_plus_base_speed = job and (job.speed_plus_base_speed or (payload and payload.speed_plus_base_speed)) or nil,
        speed_plus_multiplier = job and (job.speed_plus_multiplier or (payload and payload.speed_plus_multiplier)) or nil,
        speed_plus_speed = job and (job.speed_plus_speed or (payload and payload.speed_plus_speed)) or nil,
        speed_plus_max_speed = job and (job.speed_plus_max_speed or (payload and payload.speed_plus_max_speed)) or nil,
        speed_plus_field = job and (job.speed_plus_field or (payload and payload.speed_plus_field)) or nil,
        speed_plus_capped = job and (job.speed_plus_capped or (payload and payload.speed_plus_capped)) or nil,
        size_plus = job and (job.size_plus or (payload and payload.size_plus)) or nil,
        size_plus_mode = job and (job.size_plus_mode or (payload and payload.size_plus_mode)) or nil,
        size_plus_value = job and (job.size_plus_value or (payload and payload.size_plus_value)) or nil,
        size_plus_multiplier = job and (job.size_plus_multiplier or (payload and payload.size_plus_multiplier)) or nil,
        size_plus_field = job and (job.size_plus_field or (payload and payload.size_plus_field)) or nil,
        size_plus_capped = job and (job.size_plus_capped or (payload and payload.size_plus_capped)) or nil,
        size_plus_base_area = job and (job.size_plus_base_area or (payload and payload.size_plus_base_area)) or nil,
        size_plus_area = job and (job.size_plus_area or (payload and payload.size_plus_area)) or nil,
        launch_accepted = job and job.launch_accepted == true or false,
        projectile_id = job and job.projectile_id or nil,
        projectile_id_source = job and job.projectile_id_source or nil,
        launch_direction = job and job.launch_direction or nil,
        launch_user_data = job and job.launch_user_data or nil,
        error = job and job.error or nil,
    }
end

local function makeProbeVirtualPayloadJob(job, job_id, projectile_id)
    local source = job or {}
    local payload = source.payload or {}
    local user_data_args = cloneJobInput(source)
    user_data_args.runtime = "2.2c_live_helper"
    user_data_args.mapping = helper_records.getByEngineId(source.helper_engine_id)
    user_data_args.job_kind = user_data_args.job_kind or user_data_args.kind
    user_data_args.job_id = job_id
    local user_data = sfp_userdata.buildHelperUserData(user_data_args)
    return {
        job_id = job_id,
        job_status = "complete",
        slot_id = source.slot_id,
        helper_engine_id = source.helper_engine_id,
        cast_id = source.cast_id,
        emission_index = source.emission_index,
        group_index = source.group_index,
        source_slot_id = source.source_slot_id,
        payload_slot_id = source.payload_slot_id,
        root_source_slot_id = source.root_source_slot_id or payload.root_source_slot_id,
        chain_runtime = source.chain_runtime or payload.chain_runtime,
        chain_role = source.chain_role or payload.chain_role,
        chain_id = source.chain_id or payload.chain_id,
        chain_hop_index = source.chain_hop_index or payload.chain_hop_index,
        chain_max_hops = source.chain_max_hops or payload.chain_max_hops,
        chain_targeting_mode = source.chain_targeting_mode or payload.chain_targeting_mode,
        chain_target_provider = source.chain_target_provider or payload.chain_target_provider,
        branch_scope = source.branch_scope or payload.branch_scope,
        branch_id = source.branch_id or payload.branch_id,
        branch_parent_id = source.branch_parent_id or payload.branch_parent_id,
        branch_kind = source.branch_kind or payload.branch_kind,
        branch_index = source.branch_index or payload.branch_index,
        branch_count = source.branch_count or payload.branch_count,
        chain_continuation_group_id = source.chain_continuation_group_id or payload.chain_continuation_group_id,
        current_hit_target_id = source.current_hit_target_id or payload.current_hit_target_id,
        selected_target_id = source.selected_target_id or payload.selected_target_id,
        previous_projectile_id = source.previous_projectile_id or payload.previous_projectile_id,
        payload_modifier_kind = source.payload_modifier_kind or payload.payload_modifier_kind,
        speed = source.speed or payload.speed,
        maxSpeed = source.maxSpeed or payload.maxSpeed,
        speed_plus = source.speed_plus or payload.speed_plus,
        speed_plus_mode = source.speed_plus_mode or payload.speed_plus_mode,
        speed_plus_value = source.speed_plus_value or payload.speed_plus_value,
        speed_plus_base_speed = source.speed_plus_base_speed or payload.speed_plus_base_speed,
        speed_plus_multiplier = source.speed_plus_multiplier or payload.speed_plus_multiplier,
        speed_plus_speed = source.speed_plus_speed or payload.speed_plus_speed,
        speed_plus_max_speed = source.speed_plus_max_speed or payload.speed_plus_max_speed,
        speed_plus_field = source.speed_plus_field or payload.speed_plus_field,
        speed_plus_capped = source.speed_plus_capped or payload.speed_plus_capped,
        size_plus = source.size_plus or payload.size_plus,
        size_plus_mode = source.size_plus_mode or payload.size_plus_mode,
        size_plus_value = source.size_plus_value or payload.size_plus_value,
        size_plus_multiplier = source.size_plus_multiplier or payload.size_plus_multiplier,
        size_plus_field = source.size_plus_field or payload.size_plus_field,
        size_plus_capped = source.size_plus_capped or payload.size_plus_capped,
        size_plus_base_area = source.size_plus_base_area or payload.size_plus_base_area,
        size_plus_area = source.size_plus_area or payload.size_plus_area,
        launch_accepted = true,
        projectile_id = projectile_id,
        projectile_id_source = "probe_virtual",
        launch_direction = payload.direction,
        launch_user_data = user_data,
        probe_virtual = true,
    }
end

local function jobsSettled(job_ids)
    for _, job_id in ipairs(job_ids or {}) do
        local job = orchestrator.getJob(job_id)
        if not job or job.status == "queued" or job.status == "running" then
            return false
        end
    end
    return true
end

local function tickJobs(job_ids, opts)
    local options = opts or {}
    local max_live_launches_per_tick = tonumber(options.max_live_launches_per_tick)
        or limits.MAX_LIVE_LAUNCHES_PER_TICK
    local job_count = type(job_ids) == "table" and #job_ids or 0
    local default_ticks = math.max(
        8,
        math.ceil(job_count / math.max(1, max_live_launches_per_tick)) + 2
    )
    local max_ticks = tonumber(options.max_chain_ticks) or default_ticks
    local tick_result = nil
    local tick_results = {}
    for _ = 1, max_ticks do
        if jobsSettled(job_ids) then
            break
        end
        local tick_options = {
            max_jobs_per_tick = tonumber(options.max_jobs_per_tick) or limits.MAX_JOBS_PER_TICK,
            max_live_launches_per_tick = max_live_launches_per_tick,
        }
        if options.simulate_update_ticks == true then
            tick_options.dt_seconds = tonumber(options.simulated_dt_seconds) or 0
        end
        tick_result = orchestrator.tick(tick_options)
        tick_results[#tick_results + 1] = tick_result
    end
    return tick_result, tick_results
end

local function shortKey(key)
    if type(key) == "string" and #key <= 180 then
        return key
    end
    return nil
end

local function inspectPayloadModifier(plan, audit, options)
    local slots_by_id = slotById(plan and plan.emission_slots)
    local payload_slot = slots_by_id[audit and audit.payload_slot_id]
    if not payload_slot then
        return nil, "chain_slot_mapping_missing"
    end

    local prefix = analyzePayloadPrefixOps(payload_slot.prefix_ops)
    if prefix.chain_count ~= 1 or prefix.chain_op == nil then
        return nil, "chain_payload_prefix_missing"
    end
    if prefix.speed_count > 1 or prefix.size_count > 1 or (prefix.speed_count > 0 and prefix.size_count > 0) then
        return nil, "chain_modifier_combo_deferred"
    end
    if prefix.multicast_count > 1 then
        return nil, "chain_multicast_nested_deferred"
    end
    if prefix.multicast_count == 1 and (prefix.speed_count > 0 or prefix.size_count > 0) then
        return nil, "chain_modifier_combo_deferred"
    end

    local modifier_count = prefix.speed_count + prefix.size_count
    local multicast_count = prefix.multicast_count or 0
    if prefix.unsupported_count > 0 or #(payload_slot.prefix_ops or {}) ~= (1 + modifier_count + multicast_count) then
        return nil, "chain_payload_modifier_deferred"
    end
    local fanout_count = 1
    if multicast_count == 1 then
        if not chainMulticastEnabled(options or {}) then
            return nil, "chain_multicast_disabled"
        end
        fanout_count = multicastFanout(prefix.multicast_op)
        local cap = tonumber(options and options.max_chain_multicast_fanout) or limits.MAX_CHAIN_MULTICAST_FANOUT
        if fanout_count > cap then
            return nil, "chain_multicast_fanout_cap_exceeded"
        end
    end

    local kind = nil
    local mutation = nil
    local mutation_err = nil
    if prefix.speed_count == 1 then
        kind = "speed_plus"
        if not modifierEnabled(kind, options or {}) then
            return nil, "chain_speed_plus_disabled"
        end
        if live_speed_plus.launchSpeedField() == nil then
            return nil, "chain_speed_plus_field_missing"
        end
        mutation, mutation_err = live_speed_plus.computeMutation(prefix.speed_op)
    elseif prefix.size_count == 1 then
        kind = "size_plus"
        if not modifierEnabled(kind, options or {}) then
            return nil, "chain_size_plus_disabled"
        end
        mutation, mutation_err = live_size_plus.computeMutation(prefix.size_op)
    end
    if kind ~= nil and mutation == nil then
        return nil, mutation_err or "chain_modifier_value_invalid"
    end

    local apply_result = nil
    if kind == "size_plus" and options and options.apply_size_to_specs == true then
        apply_result, mutation_err = live_size_plus.applyToPayloadSlotHelperSpecs(plan, audit.payload_slot_id, mutation)
        if not apply_result then
            return nil, mutation_err or "chain_size_plus_apply_failed"
        end
    end

    return {
        payload_modifier_kind = kind,
        has_speed_plus_payload = kind == "speed_plus",
        has_size_plus_payload = kind == "size_plus",
        has_multicast_payload = multicast_count == 1,
        chain_multicast_fanout_count = fanout_count,
        speed_plus_mutation = kind == "speed_plus" and mutation or nil,
        size_plus_mutation = kind == "size_plus" and mutation or nil,
        size_plus_apply_result = apply_result,
    }, nil
end

function live_chain.preparePayloadModifiers(plan, opts)
    local options = opts or {}
    local audit = chain_targeting.inspectPlan(plan, {
        max_hops = options.max_hops or limits.MAX_CHAIN_HOPS,
        max_jobs = options.max_jobs or limits.MAX_CHAIN_JOBS_PER_CAST,
        scan_radius = options.scan_radius,
        max_candidates = options.max_candidates or options.candidate_cap,
        allow_chain_multicast = chainMulticastEnabled(options),
        max_chain_multicast_fanout = options.max_chain_multicast_fanout,
    })
    if audit.chain_candidate ~= true then
        return nil, audit.rejection_reason or "unsupported_chain_shape", audit
    end
    if audit.chain_shape ~= "source_chain_payload" and audit.chain_shape ~= "trigger_payload_chain" then
        return nil, "unsupported_chain_shape", audit
    end

    local modifier, reason = inspectPayloadModifier(plan, audit, options)
    if not modifier then
        audit.rejection_reason = reason
        return nil, reason, audit
    end
    audit.payload_modifier_kind = modifier.payload_modifier_kind
    audit.has_speed_plus_payload = modifier.has_speed_plus_payload == true
    audit.has_size_plus_payload = modifier.has_size_plus_payload == true
    audit.has_multicast_payload = modifier.has_multicast_payload == true
    audit.chain_multicast_fanout_count = modifier.chain_multicast_fanout_count
    return modifier, nil, audit
end

function live_chain.selectV0Plan(plan, opts)
    local options = opts or {}
    local audit = chain_targeting.inspectPlan(plan, {
        max_hops = options.max_hops or limits.MAX_CHAIN_HOPS,
        max_jobs = options.max_jobs or limits.MAX_CHAIN_JOBS_PER_CAST,
        scan_radius = options.scan_radius,
        max_candidates = options.max_candidates or options.candidate_cap,
        allow_chain_multicast = chainMulticastEnabled(options),
        max_chain_multicast_fanout = options.max_chain_multicast_fanout,
    })
    if audit.chain_candidate ~= true then
        return nil, audit.rejection_reason or "unsupported_chain_shape", audit
    end
    if audit.chain_shape ~= "source_chain_payload" and audit.chain_shape ~= "trigger_payload_chain" then
        return nil, "unsupported_chain_shape", audit
    end

    local modifier = options.prepared_modifier
    if type(modifier) ~= "table" then
        local modifier_reason = nil
        modifier, modifier_reason = inspectPayloadModifier(plan, audit, options)
        if not modifier then
            audit.rejection_reason = modifier_reason
            return nil, modifier_reason or "chain_payload_modifier_deferred", audit
        end
    end

    local slots_by_id = slotById(plan.emission_slots)
    local helpers_by_slot = helperBySlotId(plan.helper_records)
    local source_slot = slots_by_id[audit.source_slot_id]
    local payload_slot = slots_by_id[audit.payload_slot_id]
    local source_helper = helpers_by_slot[audit.source_slot_id]
    local payload_helper = helpers_by_slot[audit.payload_slot_id]

    if not source_slot or not payload_slot then
        return nil, "chain_slot_mapping_missing", audit
    end
    if not source_helper or type(source_helper.engine_id) ~= "string" or source_helper.engine_id == "" then
        return nil, "chain_source_helper_missing", audit
    end
    if not payload_helper or type(payload_helper.engine_id) ~= "string" or payload_helper.engine_id == "" then
        return nil, "chain_payload_helper_missing", audit
    end

    local prefix = analyzePayloadPrefixOps(payload_slot.prefix_ops)
    if prefix.chain_count ~= 1 or prefix.chain_op == nil then
        return nil, "chain_payload_prefix_missing", audit
    end
    if hasOps(payload_slot.postfix_ops) or hasPayloadBindings(payload_slot.payload_bindings) then
        return nil, "chain_trigger_timer_deferred", audit
    end
    if hasOps(payload_helper.postfix_ops) or hasPayloadBindings(payload_helper.payload_bindings) then
        return nil, "chain_payload_nested_deferred", audit
    end
    local helper_prefix = analyzePayloadPrefixOps(payload_helper.prefix_ops)
    if helper_prefix.chain_count ~= 1 then
        return nil, "chain_payload_modifier_deferred", audit
    end
    if helper_prefix.speed_count ~= prefix.speed_count or helper_prefix.size_count ~= prefix.size_count then
        return nil, "chain_modifier_payload_unsupported", audit
    end
    if helper_prefix.multicast_count ~= prefix.multicast_count then
        return nil, "chain_multicast_payload_unsupported", audit
    end
    if helper_prefix.unsupported_count > 0
        or #(payload_helper.prefix_ops or {}) ~= #(payload_slot.prefix_ops or {}) then
        return nil, "chain_payload_modifier_deferred", audit
    end

    return {
        ok = true,
        chain_shape = audit.chain_shape,
        requested_hops = audit.requested_hops,
        max_hops = audit.max_hops,
        candidate_cap = tonumber(options.max_candidates or options.candidate_cap) or limits.MAX_CHAIN_SCAN_CANDIDATES,
        max_live_launches_per_tick = tonumber(options.max_live_launches_per_tick) or limits.MAX_LIVE_LAUNCHES_PER_TICK,
        chaos_budget_profile = options.chaos_budget_profile,
        source_slot_id = audit.source_slot_id,
        payload_slot_id = audit.payload_slot_id,
        source_helper_engine_id = source_helper.engine_id,
        payload_helper_engine_id = payload_helper.engine_id,
        payload_effect_id = firstEffectId(payload_helper),
        payload_modifier_kind = modifier.payload_modifier_kind,
        has_multicast_payload = modifier.has_multicast_payload == true,
        chain_multicast_fanout_count = modifier.chain_multicast_fanout_count or 1,
        has_speed_plus_payload = modifier.has_speed_plus_payload == true,
        has_size_plus_payload = modifier.has_size_plus_payload == true,
        speed_plus_mutation = modifier.speed_plus_mutation,
        size_plus_mutation = modifier.size_plus_mutation,
        size_plus_apply_result = modifier.size_plus_apply_result,
        has_trigger_payload_context = audit.has_trigger_payload_context == true,
        source = {
            slot = source_slot,
            helper = source_helper,
        },
        payload = {
            slot = payload_slot,
            helper = payload_helper,
        },
        audit = audit,
    }, nil, audit
end

function live_chain.decorateSourceJob(job, binding)
    if type(job) ~= "table" or type(binding) ~= "table" then
        return
    end
    job.chain_runtime = true
    job.chain_role = "source"
    job.chain_id = binding.chain_id
    job.chain_hop_index = 0
    job.chain_max_hops = binding.max_hops
    job.chain_targeting_mode = binding.targeting_mode or "no_immediate_repeat"
    job.root_source_slot_id = binding.root_source_slot_id or binding.source_slot_id
    job.current_source_slot_id = binding.source_slot_id
    job.parent_slot_id = nil
    job.payload_depth = 0
    job.source_slot_id = binding.source_slot_id
    job.source_helper_engine_id = binding.source_helper_engine_id
    job.payload_slot_id = binding.payload_slot_id
    job.payload_modifier_kind = binding.payload_modifier_kind
    job.branch_scope = binding.branch_scope or "default"
    job.branch_id = binding.root_branch_id or binding.chain_id
    job.branch_kind = binding.branch_kind or "chain"
    job.branch_count = binding.chain_multicast_fanout_count or 1
    if binding.chain_shape == "trigger_payload_chain" then
        job.source_postfix_opcode = "Trigger"
    end
    job.payload = job.payload or {}
    job.payload.chain_runtime = true
    job.payload.chain_role = "source"
    job.payload.chain_id = binding.chain_id
    job.payload.chain_hop_index = 0
    job.payload.chain_max_hops = binding.max_hops
    job.payload.chain_targeting_mode = binding.targeting_mode or "no_immediate_repeat"
    job.payload.root_source_slot_id = binding.root_source_slot_id or binding.source_slot_id
    job.payload.current_source_slot_id = binding.source_slot_id
    job.payload.parent_slot_id = nil
    job.payload.payload_depth = 0
    job.payload.source_slot_id = binding.source_slot_id
    job.payload.source_helper_engine_id = binding.source_helper_engine_id
    job.payload.payload_slot_id = binding.payload_slot_id
    job.payload.payload_modifier_kind = binding.payload_modifier_kind
    job.payload.branch_scope = binding.branch_scope or "default"
    job.payload.branch_id = binding.root_branch_id or binding.chain_id
    job.payload.branch_kind = binding.branch_kind or "chain"
    job.payload.branch_count = binding.chain_multicast_fanout_count or 1
    if binding.chain_shape == "trigger_payload_chain" then
        job.payload.source_postfix_opcode = "Trigger"
    end
end

function live_chain.registerBinding(binding)
    local input = binding or {}
    if type(input.recipe_id) ~= "string" or input.recipe_id == ""
        or type(input.source_slot_id) ~= "string" or input.source_slot_id == ""
        or type(input.payload_slot_id) ~= "string" or input.payload_slot_id == ""
        or type(input.chain_id) ~= "string" or input.chain_id == "" then
        return false
    end
    local cast_key = castSourceKey(input.recipe_id, input.source_slot_id, input.cast_id)
    bindings_by_cast_source[cast_key] = input
    bindings_by_chain_id[input.chain_id] = input
    appendBounded(binding_order, cast_key, MAX_BINDINGS, function(evicted)
        local evicted_binding = bindings_by_cast_source[evicted]
        if evicted_binding and evicted_binding.chain_id then
            bindings_by_chain_id[evicted_binding.chain_id] = nil
        end
        bindings_by_cast_source[evicted] = nil
    end)
    return true
end

local function bindingForRoute(route)
    if not route or route.ok ~= true then
        return nil
    end
    local user_data = route.user_data or {}
    if type(user_data.chain_id) == "string" and user_data.chain_id ~= "" then
        local by_chain = bindings_by_chain_id[user_data.chain_id]
        if by_chain then
            return by_chain
        end
    end
    local cast_id = user_data.cast_id
    if type(route.recipe_id) == "string" and type(route.slot_id) == "string" and type(cast_id) == "string" then
        return bindings_by_cast_source[castSourceKey(route.recipe_id, route.slot_id, cast_id)]
    end
    return nil
end

local function routeHopIndex(route, binding)
    local user_data = route.user_data or {}
    if user_data.chain_runtime == true
        and user_data.chain_id == binding.chain_id
        and (user_data.chain_role == "payload"
            or (route.slot_id == binding.payload_slot_id
                and route.helper_engine_id == binding.payload_helper_engine_id)) then
        return tonumber(user_data.chain_hop_index) or 0, "payload"
    end
    if route.slot_id == binding.source_slot_id
        and route.helper_engine_id == binding.source_helper_engine_id then
        return 0, "source"
    end
    return nil, nil
end

local function routeContinuationScope(route)
    local user_data = route and route.user_data or nil
    if user_data and user_data.bounce_runtime == true and user_data.bounce_index ~= nil then
        if type(user_data.branch_scope) == "string" and user_data.branch_scope ~= "" then
            return user_data.branch_scope
        end
        local bounce_id = tostring(user_data.bounce_id or "no-bounce")
        if string.sub(bounce_id, 1, 7) ~= "bounce:" then
            bounce_id = "bounce:" .. bounce_id
        end
        return string.format(
            "%s:b%s",
            bounce_id,
            tostring(user_data.bounce_index)
        )
    end
    return "default"
end

local function copyBounceContinuationScope(route, target)
    local user_data = route and route.user_data or nil
    if type(target) ~= "table" or not user_data
        or user_data.bounce_runtime ~= true
        or user_data.bounce_index == nil then
        return
    end

    -- Keep Bounce-triggered Chain branches independent without making the
    -- chained payload itself bounce. These fields are continuation identity.
    target.bounce_runtime = true
    target.bounce_role = "chain_branch_scope"
    target.bounce_id = user_data.bounce_id
    target.bounce_index = user_data.bounce_index
    target.bounce_max = user_data.bounce_max
    target.bounce_power = user_data.bounce_power
    target.bounce_trigger_payload_slot_id = user_data.bounce_trigger_payload_slot_id
    target.bounce_final = user_data.bounce_final
end

local function duplicateKey(route, binding, hop_index)
    return string.format(
        "chain:%s:%s:%s:%s:%s:%s:%s:%s",
        tostring(binding.chain_id),
        tostring(binding.cast_id or (route.user_data and route.user_data.cast_id) or "no-cast"),
        tostring(hop_index),
        tostring(route.slot_id),
        tostring(route.helper_engine_id),
        tostring(route.projectile_id or "no-projectile"),
        tostring(binding.payload_slot_id),
        routeContinuationScope(route)
    )
end

-- One Chain continuation may produce several hit reports from a single detonation.
-- Claim by hop, not projectile, so async LOS cannot fan those reports into branches.
-- Bounce sources are the exception: each bounce index is its own discrete trigger.
local function continuationClaimKey(route, binding, hop_index)
    local user_data = route and route.user_data or {}
    local continuation_group = user_data.chain_continuation_group_id
        or string.format(
            "%s:%s:%s",
            tostring(route and route.slot_id),
            tostring(route and route.helper_engine_id),
            tostring(binding.payload_slot_id)
        )
    return string.format(
        "chain-continuation:%s:%s:%s:%s:%s",
        tostring(binding.chain_id),
        tostring(binding.cast_id or (user_data and user_data.cast_id) or "no-cast"),
        tostring(hop_index),
        tostring(continuation_group),
        routeContinuationScope(route)
    )
end

local function rememberDuplicateKey(key)
    duplicate_keys[key] = true
    appendBounded(duplicate_order, key, MAX_DUPLICATE_KEYS, function(evicted)
        duplicate_keys[evicted] = nil
    end)
end

local function rememberContinuationClaim(key)
    continuation_claims[key] = true
    appendBounded(continuation_claim_order, key, MAX_DUPLICATE_KEYS, function(evicted)
        continuation_claims[evicted] = nil
    end)
end

local function clearPendingLos(request_id)
    local pending = request_id and pending_los[request_id] or nil
    if pending and pending.timer then
        pending.timer:cancel()
    end
    if request_id then
        pending_los[request_id] = nil
    end
end

local function nextLosRequestId(binding, next_hop)
    next_los_request_index = next_los_request_index + 1
    return string.format(
        "chain-los:%s:%s:%d",
        tostring(binding and binding.chain_id or "chain"),
        tostring(next_hop or 0),
        next_los_request_index
    )
end

local function visibleIdSet(values)
    local set = {}
    for _, value in ipairs(values or {}) do
        if value ~= nil then
            set[tostring(value)] = true
        end
    end
    return set
end

local function filterCandidatesByVisibleIds(candidates, visible_ids)
    local visible = visibleIdSet(visible_ids)
    local filtered = {}
    for index, candidate in ipairs(candidates or {}) do
        local id = candidateToken(candidate, index)
        if visible[id] then
            filtered[#filtered + 1] = candidate
        end
    end
    return filtered
end

local function compactLosCandidate(candidate, index)
    return {
        id = candidateToken(candidate, index),
        object = candidate and candidate.object or nil,
        position = candidate and candidate.position or tablePosition(candidate),
    }
end

local function stopResult(reason, binding, route, previous_hop, extra)
    local result = extra or {}
    local branch_scope = routeContinuationScope(route)
    result.ok = result.ok ~= false
    result.stopped = true
    result.stop_reason = reason
    result.rejection_reason = result.rejection_reason
    result.chain_id = binding and binding.chain_id or nil
    result.cast_id = binding and binding.cast_id or nil
    result.source_slot_id = binding and binding.source_slot_id or nil
    result.payload_slot_id = binding and binding.payload_slot_id or nil
    result.chain_hop_index = previous_hop
    result.max_hops = binding and binding.max_hops or nil
    result.projectile_id = route and route.projectile_id or nil
    result.branch_scope = branch_scope
    log.info(string.format(
        "SPELLFORGE_CHAIN_HOP_STOPPED recipe_id=%s cast_id=%s chain_id=%s branch_scope=%s hop_index=%s max_hops=%s stop_reason=%s",
        tostring(binding and binding.recipe_id or nil),
        tostring(binding and binding.cast_id or nil),
        tostring(binding and binding.chain_id or nil),
        tostring(branch_scope),
        tostring(previous_hop),
        tostring(binding and binding.max_hops or nil),
        tostring(reason)
    ))
    return result
end

local function completeLosRequest(request_id, payload)
    local pending = request_id and pending_los[request_id] or nil
    if not pending then
        return { ok = true, ignored = true, reason = "unknown_chain_los_request" }
    end

    clearPendingLos(request_id)

    if payload and payload.ok == false then
        runtime_stats.inc("chain_runtime_hop_rejected")
        runtime_stats.inc("chain_runtime_los_unavailable")
        return stopResult(payload.rejection_reason or "chain_los_unavailable", pending.binding, pending.route, pending.previous_hop, {
            ok = false,
            rejection_reason = payload.rejection_reason or "chain_los_unavailable",
            los_request_id = request_id,
            los_error = payload.error,
        })
    end

    local filtered = filterCandidatesByVisibleIds(pending.candidates, payload and payload.visible_ids or {})
    local original_count = #(pending.candidates or {})
    local provider_result = {}
    for key, value in pairs(pending.provider_result or {}) do
        provider_result[key] = value
    end
    provider_result.candidate_count = #filtered
    provider_result.los_candidate_count = original_count
    provider_result.los_visible_count = #filtered
    provider_result.los_blocked_count = tonumber(payload and payload.blocked_count) or math.max(0, original_count - #filtered)
    provider_result.los_raycast_count = tonumber(payload and payload.raycast_count) or 0
    provider_result.los_request_id = request_id

    log.info(string.format(
        "SPELLFORGE_CHAIN_LOS_RESULT recipe_id=%s cast_id=%s chain_id=%s branch_scope=%s hop_index=%s request_id=%s candidate_count=%s visible_count=%s blocked_count=%s raycast_count=%s",
        tostring(pending.binding and pending.binding.recipe_id or nil),
        tostring(pending.binding and pending.binding.cast_id or nil),
        tostring(pending.binding and pending.binding.chain_id or nil),
        tostring(routeContinuationScope(pending.route)),
        tostring(pending.next_hop),
        tostring(request_id),
        tostring(original_count),
        tostring(#filtered),
        tostring(provider_result.los_blocked_count),
        tostring(provider_result.los_raycast_count)
    ))

    if #filtered == 0 then
        runtime_stats.inc("chain_runtime_hop_rejected")
        runtime_stats.inc("chain_runtime_stop_no_target")
        runtime_stats.inc("chain_runtime_no_target")
        runtime_stats.inc("chain_runtime_los_no_visible_target")
        return stopResult("no_visible_chain_target", pending.binding, pending.route, pending.previous_hop, {
            resolved = {
                ok = false,
                rejection_reason = "no_visible_chain_target",
                los_request_id = request_id,
                candidate_count = original_count,
                visible_count = 0,
            },
            provider_result = provider_result,
        })
    end

    runtime_stats.inc("chain_runtime_los_visible_candidates", #filtered)
    return live_chain.handleResolvedHit(pending.route, {
        precollected_candidates = filtered,
        precollected_provider_result = provider_result,
        bypass_duplicate = true,
        skip_los = true,
        resume_after_los = true,
        max_chain_ticks = pending.options and pending.options.max_chain_ticks or nil,
        max_jobs_per_tick = pending.options and pending.options.max_jobs_per_tick or nil,
        max_live_launches_per_tick = pending.options and pending.options.max_live_launches_per_tick or nil,
        simulate_update_ticks = pending.options and pending.options.simulate_update_ticks == true,
        simulated_dt_seconds = pending.options and pending.options.simulated_dt_seconds or nil,
    })
end

local function requestLosFilter(binding, route, previous_hop, current_target, hit_context, candidates, provider_result, options)
    local candidate_count = #(candidates or {})
    if options.skip_los == true
        or not provider_result
        or provider_result.provider ~= "real"
        or candidate_count == 0 then
        return nil
    end

    local los_actor = route.attacker or binding.actor
    if not los_actor or type(los_actor.sendEvent) ~= "function" then
        runtime_stats.inc("chain_runtime_hop_rejected")
        runtime_stats.inc("chain_runtime_los_unavailable")
        return stopResult("chain_los_unavailable", binding, route, previous_hop, {
            ok = false,
            rejection_reason = "chain_los_unavailable",
        })
    end

    local next_hop = (tonumber(previous_hop) or 0) + 1
    local request_id = nextLosRequestId(binding, next_hop)
    local start_pos = elevatedPosition(tablePosition(current_target), limits.CHAIN_AIM_HEIGHT)
        or hit_context.current_hit_position

    local los_candidates = {}
    for index, candidate in ipairs(candidates or {}) do
        los_candidates[#los_candidates + 1] = compactLosCandidate(candidate, index)
    end

    pending_los[request_id] = {
        binding = binding,
        route = route,
        previous_hop = previous_hop,
        next_hop = next_hop,
        candidates = candidates,
        provider_result = provider_result,
        options = options,
    }
    appendBounded(pending_los_order, request_id, MAX_PENDING_LOS, function(evicted)
        pending_los[evicted] = nil
    end)
    pending_los[request_id].timer = async:newUnsavableSimulationTimer(LOS_TIMEOUT_SECONDS, function()
        if pending_los[request_id] then
            completeLosRequest(request_id, {
                ok = false,
                rejection_reason = "chain_los_timeout",
                error = "Chain LOS request timed out",
            })
        end
    end)

    local sent, send_err = pcall(function()
        los_actor:sendEvent(events.CHAIN_LOS_REQUEST, {
            request_id = request_id,
            start_pos = start_pos,
            current_target = current_target,
            candidates = los_candidates,
        })
    end)
    if not sent then
        clearPendingLos(request_id)
        runtime_stats.inc("chain_runtime_hop_rejected")
        runtime_stats.inc("chain_runtime_los_unavailable")
        return stopResult("chain_los_unavailable", binding, route, previous_hop, {
            ok = false,
            rejection_reason = "chain_los_unavailable",
            los_error = tostring(send_err),
        })
    end

    runtime_stats.inc("chain_runtime_los_requests")
    log.info(string.format(
        "SPELLFORGE_CHAIN_LOS_REQUESTED recipe_id=%s cast_id=%s chain_id=%s branch_scope=%s hop_index=%s request_id=%s candidate_count=%s",
        tostring(binding.recipe_id),
        tostring(binding.cast_id),
        tostring(binding.chain_id),
        tostring(routeContinuationScope(route)),
        tostring(next_hop),
        tostring(request_id),
        tostring(candidate_count)
    ))

    return {
        ok = true,
        pending_los = true,
        mode = "chain_runtime",
        chain_runtime = true,
        chain_id = binding.chain_id,
        cast_id = binding.cast_id,
        chain_hop_index = next_hop,
        previous_hop_index = previous_hop,
        max_hops = binding.max_hops,
        los_request_id = request_id,
        branch_scope = routeContinuationScope(route),
    }
end

function live_chain.handleResolvedHit(route, opts)
    local options = opts or {}
    if not route or route.ok ~= true then
        return { ok = false, ignored = true, error = route and route.error or "unresolved hit" }
    end

    local binding = bindingForRoute(route)
    if not binding then
        return { ok = true, ignored = true, reason = "no_live_chain_binding" }
    end

    local previous_hop, route_kind = routeHopIndex(route, binding)
    if previous_hop == nil then
        return { ok = true, ignored = true, reason = "not_chain_source_or_payload" }
    end
    local branch_scope = routeContinuationScope(route)

    if options.force_enabled ~= true and binding.force_enabled ~= true and not dev.liveChainRuntimeEnabled() then
        runtime_stats.inc("chain_runtime_rejected")
        runtime_stats.inc("chain_runtime_disabled_reject")
        return { ok = false, disabled = true, error = "live Chain runtime disabled" }
    end

    if route_kind == "source" and options.resume_after_los ~= true then
        runtime_stats.inc("chain_runtime_source_hits")
    end
    if options.resume_after_los ~= true then
        runtime_stats.inc("chain_runtime_hop_attempts")
    end

    if previous_hop >= (tonumber(binding.max_hops) or 0) then
        runtime_stats.inc("chain_runtime_stop_max_hops")
        return stopResult("max_hops_reached", binding, route, previous_hop, {
            completed_hops = previous_hop,
            selected_target_ids = {},
        })
    end

    local current_target = route.target
    if current_target == nil and route.user_data and route.user_data.selected_target_id ~= nil then
        current_target = {
            id = route.user_data.selected_target_id,
            object = route.user_data.selected_target_id,
            is_actor = true,
        }
    end
    if targetIsKnownNonActor(current_target) then
        runtime_stats.inc("chain_runtime_hit_non_actor")
        return stopResult("chain_hit_non_actor", binding, route, previous_hop, {
            ignored = true,
            current_hit_target_id = objectToken(current_target),
        })
    end

    local key = duplicateKey(route, binding, previous_hop)
    local claim_key = continuationClaimKey(route, binding, previous_hop)
    if options.bypass_duplicate ~= true then
        if continuation_claims[claim_key] or duplicate_keys[key] then
            runtime_stats.inc("chain_runtime_duplicate_suppressed")
            log.info(string.format(
                "SPELLFORGE_CHAIN_DUPLICATE_SUPPRESSED recipe_id=%s cast_id=%s chain_id=%s branch_scope=%s hop_index=%s key=%s claim_key=%s",
                tostring(binding.recipe_id),
                tostring(binding.cast_id),
                tostring(binding.chain_id),
                tostring(branch_scope),
                tostring(previous_hop),
                tostring(shortKey(key) or "<long>"),
                tostring(shortKey(claim_key) or "<long>")
            ))
            return {
                ok = true,
                duplicate_suppressed = true,
                duplicate_key = key,
                continuation_claim_key = claim_key,
                chain_id = binding.chain_id,
                chain_hop_index = previous_hop,
                max_hops = binding.max_hops,
                branch_scope = branch_scope,
            }
        end
        rememberDuplicateKey(key)
        rememberContinuationClaim(claim_key)
    end

    local next_hop = previous_hop + 1
    local hit_context = {
        caster = route.attacker or binding.actor,
        source_target = current_target,
        current_hit_target = current_target,
        current_hit_position = route.hit_pos or tablePosition(current_target),
        current_cell = cellToken(current_target and current_target.cell),
        cast_id = binding.cast_id,
        recipe_id = binding.recipe_id,
        source_slot_id = binding.source_slot_id,
        payload_slot_id = binding.payload_slot_id,
        source_helper_engine_id = binding.source_helper_engine_id,
        chain_id = binding.chain_id,
        hop_index = next_hop,
        max_hops = binding.max_hops,
        exclude_caster = true,
        exclude_current_hit_target = true,
    }
    local candidates = options.precollected_candidates
    local provider_result = options.precollected_provider_result
    if candidates == nil then
        local provider = options.candidate_provider or binding.candidate_provider or binding.target_provider
        candidates, provider_result = collectCandidates(provider, hit_context, binding, options)
    end
    if candidates == nil then
        local reason = provider_result and (provider_result.rejection_reason or provider_result.unsupported_reason)
            or "chain_target_provider_missing"
        runtime_stats.inc("chain_runtime_hop_rejected")
        runtime_stats.inc("chain_runtime_target_provider_missing")
        return stopResult(reason, binding, route, previous_hop, {
            ok = false,
            rejection_reason = reason,
            provider_result = provider_result,
        })
    end
    local los_result = requestLosFilter(binding, route, previous_hop, current_target, hit_context, candidates, provider_result, options)
    if los_result then
        return los_result
    end
    local resolved = chain_targeting.resolveNextTarget(hit_context, candidates, {
        hop_index = next_hop,
        max_hops = binding.max_hops,
        scan_radius = binding.scan_radius,
        max_radius = limits.MAX_CHAIN_SCAN_RADIUS,
        max_candidates = binding.candidate_cap or limits.MAX_CHAIN_SCAN_CANDIDATES,
        max_targets = limits.MAX_CHAIN_TARGETS_PER_HOP,
        targeting_mode = binding.targeting_mode or "no_immediate_repeat",
        chain_id = binding.chain_id,
    })
    local selected = resolved.selected_targets and resolved.selected_targets[1] or nil
    if not resolved.ok or not selected then
        runtime_stats.inc("chain_runtime_hop_rejected")
        runtime_stats.inc("chain_runtime_stop_no_target")
        runtime_stats.inc("chain_runtime_no_target")
        return stopResult(resolved.rejection_reason or "no_valid_chain_target", binding, route, previous_hop, {
            resolved = resolved,
            provider_result = provider_result,
        })
    end

    local origin = route.hit_pos or tablePosition(current_target)
    if provider_result and provider_result.provider == "real" then
        origin = elevatedPosition(tablePosition(current_target), limits.CHAIN_AIM_HEIGHT) or origin
    end
    local start_pos = vectorFromPosition(origin)
    local direction, direction_err = directionBetween(origin, selected.position)
    if not start_pos or not direction then
        runtime_stats.inc("chain_runtime_hop_rejected")
        runtime_stats.inc("chain_runtime_context_reject")
        return stopResult(direction_err or "chain_target_direction_missing", binding, route, previous_hop, {
            ok = false,
            rejection_reason = direction_err or "chain_target_direction_missing",
            resolved = resolved,
        })
    end

    runtime_stats.inc("chain_runtime_hop_qualified")
    local selected_object = candidateObjectForSelected(candidates, selected.id)
    if type(selected_object) ~= "table" and type(selected_object) ~= "userdata" then
        selected_object = nil
    end
    log.info(string.format(
        "SPELLFORGE_CHAIN_HOP_TARGET_SELECTED recipe_id=%s cast_id=%s chain_id=%s branch_scope=%s source_slot_id=%s payload_slot_id=%s hop_index=%s max_hops=%s current_hit_target_id=%s selected_target_id=%s targeting_mode=%s provider=%s",
        tostring(binding.recipe_id),
        tostring(binding.cast_id),
        tostring(binding.chain_id),
        tostring(branch_scope),
        tostring(binding.source_slot_id),
        tostring(binding.payload_slot_id),
        tostring(next_hop),
        tostring(binding.max_hops),
        tostring(objectToken(current_target)),
        tostring(selected.id),
        tostring(binding.targeting_mode or "no_immediate_repeat"),
        tostring(provider_result and provider_result.provider or "unknown")
    ))
    if provider_result and provider_result.provider == "real" then
        runtime_stats.inc("chain_provider_selected_real")
        log.info(string.format(
            "SPELLFORGE_CHAIN_REAL_TARGET_SELECTED recipe_id=%s cast_id=%s chain_id=%s branch_scope=%s hop_index=%s selected_target_id=%s candidate_count=%s radius=%s vertical_delta=%s aim_height=%s",
            tostring(binding.recipe_id),
            tostring(binding.cast_id),
            tostring(binding.chain_id),
            tostring(branch_scope),
            tostring(next_hop),
            tostring(selected.id),
            tostring(provider_result.candidate_count),
            tostring(provider_result.radius),
            tostring(selected.vertical_delta),
            tostring(limits.CHAIN_AIM_HEIGHT)
        ))
    end

    local source_job_id = binding.source_job_id or (route.user_data and route.user_data.job_id)
    local idempotency_key = string.format(
        "%s:%s:%s:%s",
        tostring(binding.chain_id),
        tostring(next_hop),
        tostring(selected.id),
        tostring(branch_scope)
    )
    local job_input = {
        kind = orchestrator.LIVE_CHAIN_PAYLOAD_JOB_KIND,
        recipe_id = binding.recipe_id,
        slot_id = binding.payload_slot_id,
        helper_engine_id = binding.payload_helper_engine_id,
        idempotency_key = idempotency_key,
        source_job_id = source_job_id,
        parent_job_id = route.user_data and route.user_data.job_id or source_job_id,
        depth = 1,
        cast_id = binding.cast_id,
        emission_index = binding.payload_emission_index,
        group_index = binding.payload_group_index,
        fanout_count = binding.chain_multicast_fanout_count or 1,
        max_live_launches_per_tick = binding.max_live_launches_per_tick,
        chaos_budget_profile = binding.chaos_budget_profile,
        root_source_slot_id = binding.root_source_slot_id or binding.source_slot_id,
        current_source_slot_id = binding.payload_slot_id,
        parent_slot_id = binding.source_slot_id,
        payload_depth = 1,
        source_slot_id = binding.source_slot_id,
        source_helper_engine_id = binding.source_helper_engine_id,
        source_postfix_opcode = "Chain",
        payload_slot_id = binding.payload_slot_id,
        chain_runtime = true,
        chain_role = "payload",
        chain_id = binding.chain_id,
        chain_hop_index = next_hop,
        chain_max_hops = binding.max_hops,
        chain_targeting_mode = binding.targeting_mode or "no_immediate_repeat",
        chain_target_provider = provider_result and provider_result.provider or nil,
        branch_scope = branch_scope,
        branch_kind = binding.has_multicast_payload and "chain_multicast" or "chain",
        branch_count = binding.chain_multicast_fanout_count or 1,
        chain_continuation_group_id = string.format("%s:h%s:%s", tostring(binding.chain_id), tostring(next_hop), tostring(branch_scope)),
        current_hit_target_id = objectToken(current_target),
        selected_target_id = selected.id,
        previous_projectile_id = route.projectile_id,
        payload = {
            actor = route.attacker or binding.actor,
            start_pos = start_pos,
            direction = direction,
            hit_object = selected_object,
            excludeTarget = current_target,
            cast_id = binding.cast_id,
            source_slot_id = binding.source_slot_id,
            source_helper_engine_id = binding.source_helper_engine_id,
            source_postfix_opcode = "Chain",
            root_source_slot_id = binding.root_source_slot_id or binding.source_slot_id,
            current_source_slot_id = binding.payload_slot_id,
            parent_slot_id = binding.source_slot_id,
            payload_depth = 1,
            payload_slot_id = binding.payload_slot_id,
            fanout_count = binding.chain_multicast_fanout_count or 1,
            emission_index = binding.payload_emission_index,
            group_index = binding.payload_group_index,
            chain_runtime = true,
            chain_role = "payload",
            chain_id = binding.chain_id,
            chain_hop_index = next_hop,
            chain_max_hops = binding.max_hops,
            chain_targeting_mode = binding.targeting_mode or "no_immediate_repeat",
            chain_target_provider = provider_result and provider_result.provider or nil,
            branch_scope = branch_scope,
            branch_kind = binding.has_multicast_payload and "chain_multicast" or "chain",
            branch_count = binding.chain_multicast_fanout_count or 1,
            chain_continuation_group_id = string.format("%s:h%s:%s", tostring(binding.chain_id), tostring(next_hop), tostring(branch_scope)),
            current_hit_target_id = objectToken(current_target),
            selected_target_id = selected.id,
            previous_projectile_id = route.projectile_id,
        },
    }
    copyBounceContinuationScope(route, job_input)
    copyBounceContinuationScope(route, job_input.payload)

    local modifier_kind = binding.payload_modifier_kind
    if modifier_kind == "speed_plus" then
        copyModifierFields(job_input, binding.speed_plus_mutation, modifier_kind)
        copyModifierFields(job_input.payload, binding.speed_plus_mutation, modifier_kind)
        runtime_stats.inc("chain_modifier_speed_jobs")
        runtime_stats.inc("chain_modifier_speed_mutated")
        log.info(string.format(
            "SPELLFORGE_CHAIN_SPEED_PLUS_APPLIED recipe_id=%s cast_id=%s chain_id=%s branch_scope=%s hop_index=%s max_hops=%s payload_modifier_kind=%s source_slot_id=%s payload_slot_id=%s selected_target_id=%s speed_value=%s",
            tostring(binding.recipe_id),
            tostring(binding.cast_id),
            tostring(binding.chain_id),
            tostring(branch_scope),
            tostring(next_hop),
            tostring(binding.max_hops),
            tostring(modifier_kind),
            tostring(binding.source_slot_id),
            tostring(binding.payload_slot_id),
            tostring(selected.id),
            tostring(binding.speed_plus_mutation and binding.speed_plus_mutation.speed_plus_speed or nil)
        ))
    elseif modifier_kind == "size_plus" then
        copyModifierFields(job_input, binding.size_plus_mutation, modifier_kind)
        copyModifierFields(job_input.payload, binding.size_plus_mutation, modifier_kind)
        runtime_stats.inc("chain_modifier_size_jobs")
        runtime_stats.inc("chain_modifier_size_mutated")
        log.info(string.format(
            "SPELLFORGE_CHAIN_SIZE_PLUS_APPLIED recipe_id=%s cast_id=%s chain_id=%s branch_scope=%s hop_index=%s max_hops=%s payload_modifier_kind=%s source_slot_id=%s payload_slot_id=%s selected_target_id=%s size_area=%s",
            tostring(binding.recipe_id),
            tostring(binding.cast_id),
            tostring(binding.chain_id),
            tostring(branch_scope),
            tostring(next_hop),
            tostring(binding.max_hops),
            tostring(modifier_kind),
            tostring(binding.source_slot_id),
            tostring(binding.payload_slot_id),
            tostring(selected.id),
            tostring(binding.size_plus_mutation and binding.size_plus_mutation.size_plus_area or nil)
        ))
    end

    local fanout_count = math.max(1, tonumber(binding.chain_multicast_fanout_count) or 1)
    local continuation_group_id = job_input.chain_continuation_group_id
    local branch_parent_id = continuation_group_id
    local launch_density_group_key = string.format(
        "chainfanout:%s:%s:%s",
        tostring(binding.chain_id),
        tostring(next_hop),
        tostring(branch_scope)
    )
    local job_ids = {}
    local real_job_ids = {}
    local jobs = {}
    local projectile_ids = {}
    local tick_results = {}
    local probe_virtual_jobs = {}
    local probe_virtual_fanout_after = tonumber(options.probe_virtual_fanout_after)
    local virtualized_count = 0
    local virtualized_first_branch_index = nil
    local virtualized_last_branch_index = nil
    local virtualized_sample_job_id = nil
    if probe_virtual_fanout_after ~= nil then
        probe_virtual_fanout_after = math.max(1, math.floor(probe_virtual_fanout_after))
    end
    if fanout_count <= 1 then
        probe_virtual_fanout_after = nil
    end

    if fanout_count > 1 then
        runtime_stats.inc("chain_multicast_hops")
        runtime_stats.inc("branch_observability_chain_multicast_branches")
        runtime_stats.max("branch_observability_max_branch_fanout", fanout_count)
        log.info(string.format(
            "SPELLFORGE_CHAIN_MULTICAST_HOP_QUALIFIED recipe_id=%s cast_id=%s chain_id=%s branch_scope=%s hop_index=%s max_hops=%s fanout_count=%s selected_target_id=%s continuation_group_id=%s",
            tostring(binding.recipe_id),
            tostring(binding.cast_id),
            tostring(binding.chain_id),
            tostring(branch_scope),
            tostring(next_hop),
            tostring(binding.max_hops),
            tostring(fanout_count),
            tostring(selected.id),
            tostring(continuation_group_id)
        ))
    end

    for fanout_index = 1, fanout_count do
        local job_to_enqueue = fanout_index == 1 and job_input or cloneJobInput(job_input)
        local branch_id = fanout_count > 1
            and string.format("%s:f%s", tostring(branch_parent_id), tostring(fanout_index))
            or branch_parent_id
        job_to_enqueue.idempotency_key = fanout_count > 1
            and string.format("%s:f%s", tostring(idempotency_key), tostring(fanout_index))
            or idempotency_key
        job_to_enqueue.fanout_count = fanout_count
        job_to_enqueue.branch_id = branch_id
        job_to_enqueue.branch_parent_id = branch_parent_id
        job_to_enqueue.branch_kind = fanout_count > 1 and "chain_multicast" or "chain"
        job_to_enqueue.branch_index = fanout_index
        job_to_enqueue.branch_count = fanout_count
        job_to_enqueue.chain_continuation_group_id = continuation_group_id
        job_to_enqueue.launch_density_group_key = launch_density_group_key
        if job_to_enqueue.payload then
            job_to_enqueue.payload.fanout_count = fanout_count
            job_to_enqueue.payload.branch_id = branch_id
            job_to_enqueue.payload.branch_parent_id = branch_parent_id
            job_to_enqueue.payload.branch_kind = job_to_enqueue.branch_kind
            job_to_enqueue.payload.branch_index = fanout_index
            job_to_enqueue.payload.branch_count = fanout_count
            job_to_enqueue.payload.chain_continuation_group_id = continuation_group_id
        end

        local probe_virtual = probe_virtual_fanout_after ~= nil and fanout_index > probe_virtual_fanout_after
        local enqueued_job_id = nil
        if probe_virtual then
            enqueued_job_id = string.format(
                "probe_virtual_chain:%s:%s:%s:%s",
                tostring(binding.chain_id),
                tostring(next_hop),
                tostring(branch_scope),
                tostring(fanout_index)
            )
            probe_virtual_jobs[enqueued_job_id] = makeProbeVirtualPayloadJob(
                job_to_enqueue,
                enqueued_job_id,
                "probe_virtual:" .. enqueued_job_id
            )
            runtime_stats.inc("chain_runtime_probe_virtual_payload_jobs")
            virtualized_count = virtualized_count + 1
            virtualized_first_branch_index = virtualized_first_branch_index or fanout_index
            virtualized_last_branch_index = fanout_index
            virtualized_sample_job_id = virtualized_sample_job_id or enqueued_job_id
        else
            local enqueue = orchestrator.enqueue(job_to_enqueue)
            if not enqueue.ok then
                runtime_stats.inc("chain_runtime_hop_rejected")
                runtime_stats.inc("chain_runtime_context_reject")
                if fanout_count > 1 then
                    runtime_stats.inc("chain_multicast_payload_failed")
                end
                return { ok = false, error = enqueue.error or "Chain payload enqueue failed" }
            end
            enqueued_job_id = enqueue.job_id
            real_job_ids[#real_job_ids + 1] = enqueue.job_id
            runtime_stats.inc("chain_runtime_sfp_launch_attempts")
            log.info(string.format(
                "SPELLFORGE_CHAIN_HOP_ENQUEUED recipe_id=%s cast_id=%s chain_id=%s branch_scope=%s branch_id=%s branch_index=%s branch_count=%s source_slot_id=%s payload_slot_id=%s hop_index=%s max_hops=%s selected_target_id=%s job_id=%s",
                tostring(binding.recipe_id),
                tostring(binding.cast_id),
                tostring(binding.chain_id),
                tostring(branch_scope),
                tostring(branch_id),
                tostring(fanout_index),
                tostring(fanout_count),
                tostring(binding.source_slot_id),
                tostring(binding.payload_slot_id),
                tostring(next_hop),
                tostring(binding.max_hops),
                tostring(selected.id),
                tostring(enqueued_job_id)
            ))
        end

        job_ids[#job_ids + 1] = enqueued_job_id
        runtime_stats.inc("chain_runtime_payload_jobs")
        if fanout_count > 1 then
            runtime_stats.inc("chain_multicast_jobs")
            runtime_stats.inc("branch_observability_events")
        end
        if modifier_kind ~= nil then
            log.info(string.format(
                "SPELLFORGE_CHAIN_MODIFIED_HOP_ENQUEUED recipe_id=%s cast_id=%s chain_id=%s branch_scope=%s source_slot_id=%s payload_slot_id=%s hop_index=%s max_hops=%s selected_target_id=%s payload_modifier_kind=%s job_id=%s",
                tostring(binding.recipe_id),
                tostring(binding.cast_id),
                tostring(binding.chain_id),
                tostring(branch_scope),
                tostring(binding.source_slot_id),
                tostring(binding.payload_slot_id),
                tostring(next_hop),
                tostring(binding.max_hops),
                tostring(selected.id),
                tostring(modifier_kind),
                tostring(enqueued_job_id)
            ))
        end
    end
    if virtualized_count > 0 then
        log.info(string.format(
            "SPELLFORGE_CHAIN_HOP_PROBE_VIRTUALIZED recipe_id=%s cast_id=%s chain_id=%s branch_scope=%s branch_count=%s virtual_branch_count=%s first_virtual_branch_index=%s last_virtual_branch_index=%s source_slot_id=%s payload_slot_id=%s hop_index=%s max_hops=%s selected_target_id=%s sample_job_id=%s",
            tostring(binding.recipe_id),
            tostring(binding.cast_id),
            tostring(binding.chain_id),
            tostring(branch_scope),
            tostring(fanout_count),
            tostring(virtualized_count),
            tostring(virtualized_first_branch_index),
            tostring(virtualized_last_branch_index),
            tostring(binding.source_slot_id),
            tostring(binding.payload_slot_id),
            tostring(next_hop),
            tostring(binding.max_hops),
            tostring(selected.id),
            tostring(virtualized_sample_job_id)
        ))
    end
    runtime_stats.inc("chain_runtime_hops_launched")

    local failed_job = nil
    local tick_result = nil
    tick_result, tick_results = tickJobs(real_job_ids, {
        max_chain_ticks = options.max_chain_ticks,
        max_jobs_per_tick = options.max_jobs_per_tick or binding.max_jobs_per_tick,
        max_live_launches_per_tick = options.max_live_launches_per_tick or binding.max_live_launches_per_tick,
        simulate_update_ticks = options.simulate_update_ticks == true,
        simulated_dt_seconds = options.simulated_dt_seconds,
    })

    local virtual_ok_count = 0
    local virtual_ok_first_branch_index = nil
    local virtual_ok_last_branch_index = nil
    local virtual_ok_sample_projectile_id = nil
    for _, job_id in ipairs(job_ids) do
        local job = probe_virtual_jobs[job_id] or compactJob(job_id)
        jobs[#jobs + 1] = job
        runtime_stats.inc("chain_runtime_payload_processed")
        if job.job_status == "complete" and job.launch_accepted == true then
            runtime_stats.inc("chain_runtime_payload_ok")
            if job.probe_virtual == true then
                runtime_stats.inc("chain_runtime_probe_virtual_payload_ok")
                virtual_ok_count = virtual_ok_count + 1
                virtual_ok_first_branch_index = virtual_ok_first_branch_index or job.branch_index
                virtual_ok_last_branch_index = job.branch_index
                virtual_ok_sample_projectile_id = virtual_ok_sample_projectile_id or job.projectile_id
            else
                runtime_stats.inc("chain_runtime_sfp_launch_ok")
                log.info(string.format(
                    "SPELLFORGE_CHAIN_HOP_PAYLOAD_OK recipe_id=%s cast_id=%s chain_id=%s branch_scope=%s branch_id=%s branch_index=%s branch_count=%s payload_slot_id=%s hop_index=%s max_hops=%s selected_target_id=%s projectile_id=%s",
                    tostring(binding.recipe_id),
                    tostring(binding.cast_id),
                    tostring(binding.chain_id),
                    tostring(branch_scope),
                    tostring(job.branch_id),
                    tostring(job.branch_index),
                    tostring(job.branch_count),
                    tostring(binding.payload_slot_id),
                    tostring(next_hop),
                    tostring(binding.max_hops),
                    tostring(selected.id),
                    tostring(job.projectile_id)
                ))
            end
            if modifier_kind ~= nil then
                runtime_stats.inc("chain_modifier_payload_ok")
            end
            if fanout_count > 1 then
                runtime_stats.inc("chain_multicast_payload_ok")
            end
            if job.projectile_id ~= nil then
                projectile_ids[#projectile_ids + 1] = job.projectile_id
            end
            if modifier_kind ~= nil then
                log.info(string.format(
                    "SPELLFORGE_CHAIN_MODIFIED_PAYLOAD_OK recipe_id=%s cast_id=%s chain_id=%s branch_scope=%s payload_slot_id=%s hop_index=%s max_hops=%s selected_target_id=%s payload_modifier_kind=%s projectile_id=%s",
                    tostring(binding.recipe_id),
                    tostring(binding.cast_id),
                    tostring(binding.chain_id),
                    tostring(branch_scope),
                    tostring(binding.payload_slot_id),
                    tostring(next_hop),
                    tostring(binding.max_hops),
                    tostring(selected.id),
                    tostring(modifier_kind),
                    tostring(job.projectile_id)
                ))
            end
        else
            failed_job = job
            runtime_stats.inc("chain_runtime_payload_failed")
            runtime_stats.inc("chain_runtime_sfp_launch_failed")
            if modifier_kind ~= nil then
                runtime_stats.inc("chain_modifier_payload_failed")
            end
            if fanout_count > 1 then
                runtime_stats.inc("chain_multicast_payload_failed")
            end
        end
    end
    if virtual_ok_count > 0 then
        log.info(string.format(
            "SPELLFORGE_CHAIN_HOP_PAYLOAD_VIRTUAL_OK recipe_id=%s cast_id=%s chain_id=%s branch_scope=%s branch_count=%s virtual_payload_count=%s first_virtual_branch_index=%s last_virtual_branch_index=%s payload_slot_id=%s hop_index=%s max_hops=%s selected_target_id=%s sample_projectile_id=%s",
            tostring(binding.recipe_id),
            tostring(binding.cast_id),
            tostring(binding.chain_id),
            tostring(branch_scope),
            tostring(fanout_count),
            tostring(virtual_ok_count),
            tostring(virtual_ok_first_branch_index),
            tostring(virtual_ok_last_branch_index),
            tostring(binding.payload_slot_id),
            tostring(next_hop),
            tostring(binding.max_hops),
            tostring(selected.id),
            tostring(virtual_ok_sample_projectile_id)
        ))
    end

    if failed_job then
        return {
            ok = false,
            error = failed_job.error or "Chain payload launch failed",
            chain_id = binding.chain_id,
            chain_hop_index = next_hop,
            max_hops = binding.max_hops,
            branch_scope = branch_scope,
            job_id = failed_job.job_id,
            job = failed_job,
            jobs = jobs,
            job_ids = job_ids,
            tick_result = tick_result,
            tick_results = tick_results,
            resolved = resolved,
        }
    end

    runtime_stats.inc("chain_runtime_hops_completed")

    return {
        ok = true,
        mode = "chain_runtime",
        chain_runtime = true,
        chain_id = binding.chain_id,
        cast_id = binding.cast_id,
        chain_shape = binding.chain_shape,
        chain_hop_index = next_hop,
        previous_hop_index = previous_hop,
        max_hops = binding.max_hops,
        branch_scope = branch_scope,
        targeting_mode = binding.targeting_mode or "no_immediate_repeat",
        current_hit_target_id = objectToken(current_target),
        selected_target_id = selected.id,
        selected_targets = resolved.selected_targets,
        selected_count = resolved.selected_count,
        candidate_count = resolved.candidate_count,
        valid_candidate_count = resolved.valid_candidate_count,
        payload_modifier_kind = modifier_kind,
        speed_plus_mutation = binding.speed_plus_mutation,
        size_plus_mutation = binding.size_plus_mutation,
        provider = provider_result and provider_result.provider or nil,
        provider_result = provider_result,
        excluded_current_target_id = resolved.excluded_current_target_id,
        job_id = job_ids[1],
        job_ids = job_ids,
        jobs = jobs,
        launch_count = #jobs,
        payload_job = jobs[1],
        payload_slot_id = binding.payload_slot_id,
        payload_helper_engine_id = binding.payload_helper_engine_id,
        has_multicast_payload = fanout_count > 1,
        chain_multicast_fanout_count = fanout_count,
        projectile_id = jobs[1] and jobs[1].projectile_id or nil,
        projectile_ids = projectile_ids,
        launch_user_data = jobs[1] and jobs[1].launch_user_data or nil,
        resolved = resolved,
        tick_result = tick_result,
        tick_results = tick_results,
    }
end

function live_chain.handleHitPayload(payload, opts)
    local route = runtime_hits.resolveHelperHit(payload or {})
    return live_chain.handleResolvedHit(route, opts)
end

function live_chain.onLosResult(payload)
    local request_id = payload and payload.request_id
    return completeLosRequest(request_id, payload or {})
end

function live_chain.clearForTests()
    for _, request_id in ipairs(pending_los_order or {}) do
        clearPendingLos(request_id)
    end
    bindings_by_cast_source = {}
    bindings_by_chain_id = {}
    binding_order = {}
    duplicate_keys = {}
    duplicate_order = {}
    continuation_claims = {}
    continuation_claim_order = {}
    pending_los = {}
    pending_los_order = {}
end

return live_chain
