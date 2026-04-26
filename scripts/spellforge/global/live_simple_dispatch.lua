local dev = require("scripts.spellforge.shared.dev")
local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("global.live_simple_dispatch")
local limits = require("scripts.spellforge.shared.limits")
local orchestrator = require("scripts.spellforge.global.orchestrator")
local plan_cache = require("scripts.spellforge.global.plan_cache")
local sfp_adapter = require("scripts.spellforge.global.sfp_adapter")

local live_simple_dispatch = {}

local SIMPLE_FIRE_DAMAGE_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

local NON_QUALIFYING_MULTICAST_FIRE_DAMAGE_TARGET = {
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
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

local function cloneEffect(effect)
    if type(effect) ~= "table" then
        return { id = tostring(effect) }
    end
    return {
        id = effect.id,
        range = effect.range,
        area = effect.area,
        duration = effect.duration,
        magnitudeMin = effect.magnitudeMin,
        magnitudeMax = effect.magnitudeMax,
        params = cloneParams(effect.params),
    }
end

local function cloneEffects(effects)
    local out = {}
    for i, effect in ipairs(effects or {}) do
        out[i] = cloneEffect(effect)
    end
    return out
end

local function firstErrorMessage(result)
    local first = result and result.errors and result.errors[1]
    return first and first.message or (result and result.error) or "unknown error"
end

local function fallback(reason, details)
    local result = details or {}
    result.ok = false
    result.used_live_2_2c = false
    result.fallback_reason = reason
    return result
end

local function bridgeError(message, details)
    local result = details or {}
    result.ok = false
    result.used_live_2_2c = true
    result.error = message
    return result
end

local function send(sender, event_name, payload)
    if sender and type(sender.sendEvent) == "function" then
        sender:sendEvent(event_name, payload)
    end
end

local function safeTryDispatch(payload, entry, root, opts)
    local ok, result_or_err = pcall(live_simple_dispatch.tryDispatch, payload, entry, root, opts)
    if ok then
        return result_or_err
    end
    return {
        ok = false,
        used_live_2_2c = true,
        error = tostring(result_or_err),
    }
end

local function isTargetRange(range)
    return range == 2 or range == "target" or range == "Target"
end

local function isSingleStoredNode(entry)
    return type(entry) == "table"
        and type(entry.node_metadata) == "table"
        and #entry.node_metadata == 1
end

local function prefixOpsAreSimple(prefix_ops)
    local saw_multicast = false
    for _, op in ipairs(prefix_ops or {}) do
        if op.opcode ~= "Multicast" then
            return false, string.format("unsupported_prefix_%s", tostring(op.opcode))
        end
        saw_multicast = true
        local count = tonumber(op.params and op.params.count) or 1
        if count ~= 1 then
            return false, "multicast_fanout"
        end
    end
    return true, saw_multicast and "multicast_count_1" or nil
end

local function validateSimplePlan(plan)
    if type(plan) ~= "table" then
        return false, "missing_plan"
    end
    local bounds = plan.bounds or {}
    if bounds.group_count ~= 1 then
        return false, "not_single_group"
    end
    if bounds.static_emission_count ~= 1 then
        return false, "not_single_emission"
    end
    if bounds.has_trigger then
        return false, "has_trigger"
    end
    if bounds.has_timer then
        return false, "has_timer"
    end
    if bounds.has_chain then
        return false, "has_chain"
    end
    if bounds.has_pattern then
        return false, "has_pattern"
    end

    local group = plan.groups and plan.groups[1] or nil
    if type(group) ~= "table" then
        return false, "missing_group"
    end
    if not isTargetRange(group.range) then
        return false, "not_target_range"
    end
    if type(group.effects) ~= "table" or #group.effects == 0 then
        return false, "missing_emitter_effects"
    end
    if type(group.postfix_ops) == "table" and #group.postfix_ops > 0 then
        return false, "has_postfix_ops"
    end
    if group.payload ~= nil then
        return false, "has_payload"
    end

    local prefix_ok, prefix_note = prefixOpsAreSimple(group.prefix_ops)
    if not prefix_ok then
        return false, prefix_note
    end

    return true, prefix_note
end

local function validateSimpleMaterialization(plan)
    if type(plan.emission_slots) ~= "table" or #plan.emission_slots ~= 1 then
        return false, "slot_count_not_one"
    end
    if type(plan.helper_records) ~= "table" or #plan.helper_records ~= 1 then
        return false, "helper_record_count_not_one"
    end

    local slot = plan.emission_slots[1]
    if slot.kind ~= "primary_emission" then
        return false, "slot_not_primary"
    end
    if type(slot.payload_bindings) == "table" and #slot.payload_bindings > 0 then
        return false, "slot_has_payload_bindings"
    end
    if type(slot.postfix_ops) == "table" and #slot.postfix_ops > 0 then
        return false, "slot_has_postfix_ops"
    end

    local helper = plan.helper_records[1]
    if type(helper.engine_id) ~= "string" or helper.engine_id == "" then
        return false, "helper_engine_id_missing"
    end
    if helper.source_postfix_opcode ~= nil then
        return false, "helper_is_payload"
    end
    if type(helper.payload_bindings) == "table" and #helper.payload_bindings > 0 then
        return false, "helper_has_payload_bindings"
    end

    return true, nil
end

local function tickUntilJobSettled(job_id, opts)
    local options = opts or {}
    local max_ticks = tonumber(options.max_launch_ticks) or 3
    local max_jobs_per_tick = tonumber(options.max_jobs_per_tick) or limits.MAX_JOBS_PER_TICK
    local last_tick = nil
    local job = orchestrator.getJob(job_id)

    for _ = 1, max_ticks do
        if job and job.status ~= "queued" then
            return job, last_tick
        end
        last_tick = orchestrator.tick({ max_jobs_per_tick = max_jobs_per_tick })
        job = orchestrator.getJob(job_id)
    end

    return job, last_tick
end

local function effectListFromRoot(root)
    if type(root) ~= "table" then
        return nil
    end
    if type(root.effect_list) == "table" and #root.effect_list > 0 then
        return cloneEffects(root.effect_list)
    end
    if type(root.real_effects) == "table" and #root.real_effects > 0 then
        return cloneEffects(root.real_effects)
    end
    return nil
end

function live_simple_dispatch.tryDispatch(payload, entry, root, opts)
    local options = opts or {}
    if options.force_disabled == true then
        return fallback("feature_flag_disabled")
    end
    if options.ignore_flag ~= true and not dev.liveSimpleDispatchEnabled() then
        return fallback("feature_flag_disabled")
    end

    local launch_payload = payload or {}
    local actor = launch_payload.actor or launch_payload.sender
    if not actor then
        return fallback("missing_actor")
    end
    if not options.skip_entry_shape_check and not isSingleStoredNode(entry) then
        return fallback("not_single_stored_node")
    end

    local effects = effectListFromRoot(root)
    if not effects then
        return fallback("missing_effect_list")
    end

    local capabilities = sfp_adapter.capabilities()
    if not capabilities.has_interface then
        return fallback("sfp_missing")
    end
    if not capabilities.has_launchSpell then
        return fallback("sfp_launch_missing")
    end

    local compiled = plan_cache.compileOrGet(effects)
    if not compiled.ok then
        return fallback("compile_failed", {
            plan_recipe_id = compiled.recipe_id,
            error = firstErrorMessage(compiled),
            errors = compiled.errors,
        })
    end

    local simple_ok, simple_reason = validateSimplePlan(compiled.plan)
    if not simple_ok then
        return fallback(simple_reason, {
            plan_recipe_id = compiled.recipe_id,
        })
    end

    local attached = plan_cache.attachHelperRecords(compiled.recipe_id)
    if not attached.ok then
        return bridgeError(firstErrorMessage(attached), {
            stage = "helper_records",
            plan_recipe_id = compiled.recipe_id,
            errors = attached.errors,
        })
    end

    local materialized_ok, materialized_reason = validateSimpleMaterialization(attached.plan)
    if not materialized_ok then
        return fallback(materialized_reason, {
            plan_recipe_id = compiled.recipe_id,
        })
    end

    local plan = attached.plan
    local helper = plan.helper_records[1]
    local slot = plan.emission_slots[1]
    local source_recipe_id = options.source_recipe_id or launch_payload.recipe_id
    local result_recipe_id = source_recipe_id or compiled.recipe_id

    if options.dry_run == true then
        return {
            ok = true,
            used_live_2_2c = true,
            dry_run = true,
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = helper.slot_id,
            helper_engine_id = helper.engine_id,
            slot_count = plan.slot_count or #plan.emission_slots,
            helper_record_count = plan.helper_record_count or #plan.helper_records,
            simple_note = simple_reason,
        }
    end

    local enqueue = orchestrator.enqueue({
        kind = orchestrator.LIVE_SIMPLE_LAUNCH_JOB_KIND,
        recipe_id = compiled.recipe_id,
        slot_id = helper.slot_id,
        helper_engine_id = helper.engine_id,
        depth = 0,
        payload = {
            actor = actor,
            start_pos = launch_payload.start_pos,
            direction = launch_payload.direction,
            hit_object = launch_payload.hit_object,
        },
    })
    if not enqueue.ok then
        return bridgeError(enqueue.error or "enqueue failed", {
            stage = "enqueue",
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = helper.slot_id,
            helper_engine_id = helper.engine_id,
        })
    end

    local job, tick_result = tickUntilJobSettled(enqueue.job_id, options)
    if not job or job.status ~= "complete" or job.launch_accepted ~= true then
        if job and job.status == "queued" then
            orchestrator.cancel(enqueue.job_id)
        end
        return bridgeError(job and job.error or "helper launch job did not complete", {
            stage = "launch_job",
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = helper.slot_id,
            helper_engine_id = helper.engine_id,
            job_id = enqueue.job_id,
            job_status = job and job.status or nil,
            tick_result = tick_result,
        })
    end

    log.info(string.format(
        "SPELLFORGE_LIVE_2_2C_SIMPLE_DISPATCH_OK recipe_id=%s plan_recipe_id=%s slot_id=%s helper_engine_id=%s projectile_id=%s",
        tostring(result_recipe_id),
        tostring(compiled.recipe_id),
        tostring(helper.slot_id),
        tostring(helper.engine_id),
        tostring(job.projectile_id)
    ))

    return {
        ok = true,
        used_live_2_2c = true,
        recipe_id = result_recipe_id,
        plan_recipe_id = compiled.recipe_id,
        slot_id = helper.slot_id,
        helper_engine_id = helper.engine_id,
        projectile_id = job.projectile_id,
        projectile_id_source = job.projectile_id_source,
        projectile_registered = job.projectile_registered == true,
        job_id = enqueue.job_id,
        job_status = job.status,
        dispatch_count = 1,
        slot_count = plan.slot_count or #plan.emission_slots,
        helper_record_count = plan.helper_record_count or #plan.helper_records,
        effect_id = slot.effects and slot.effects[1] and slot.effects[1].id or nil,
        simple_note = simple_reason,
    }
end

function live_simple_dispatch.onProbe(payload)
    local sender = payload and payload.sender
    if not sender then
        return
    end
    if not dev.smokeTestsEnabled() then
        send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, {
            request_id = payload and payload.request_id,
            ok = false,
            error = "smoke tests disabled",
        })
        return
    end

    local mode = payload and payload.mode or "qualifying_dry_run"
    local probe_entry = { node_metadata = { { logical_id = "probe" } } }
    local probe_root = { real_effects = SIMPLE_FIRE_DAMAGE_TARGET }
    local opts = {
        ignore_flag = true,
        dry_run = true,
        skip_entry_shape_check = false,
        source_recipe_id = "live-simple-probe",
    }

    if mode == "disabled" then
        local disabled = safeTryDispatch(payload, probe_entry, probe_root, {
            force_disabled = true,
        })
        send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, {
            request_id = payload and payload.request_id,
            ok = disabled.ok == false and disabled.fallback_reason == "feature_flag_disabled",
            mode = mode,
            fallback_reason = disabled.fallback_reason,
            used_live_2_2c = disabled.used_live_2_2c,
        })
        return
    elseif mode == "non_qualifying" then
        probe_root = { real_effects = NON_QUALIFYING_MULTICAST_FIRE_DAMAGE_TARGET }
    elseif mode ~= "qualifying_dry_run" then
        send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, {
            request_id = payload and payload.request_id,
            ok = false,
            mode = mode,
            error = "unknown probe mode",
        })
        return
    end

    local result = safeTryDispatch(payload, probe_entry, probe_root, opts)
    local ok = false
    if mode == "non_qualifying" then
        ok = result.ok == false and result.used_live_2_2c == false and type(result.fallback_reason) == "string"
    else
        ok = result.ok == true and result.used_live_2_2c == true and result.dry_run == true
    end
    result.request_id = payload and payload.request_id
    result.mode = mode
    result.ok = ok
    send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, result)
end

return live_simple_dispatch
