local dev = require("scripts.spellforge.shared.dev")
local helper_records = require("scripts.spellforge.global.helper_records")
local log = require("scripts.spellforge.shared.log").new("global.dev_runtime")
local runtime_hits = require("scripts.spellforge.global.runtime_hits")
local runtime_launch = require("scripts.spellforge.global.runtime_launch")
local sfp_adapter = require("scripts.spellforge.global.sfp_adapter")

local dev_runtime = {}

function dev_runtime.firstEffectId(helper)
    return runtime_hits.firstEffectId(helper)
end

local function expectedPostfixForKind(job_kind)
    if job_kind == "dev_timer_payload" then
        return "Timer"
    elseif job_kind == "dev_trigger_payload" then
        return "Trigger"
    end
    return nil
end

function dev_runtime.validateHelperLaunchJob(job, expected_postfix_opcode)
    if not dev.devLaunchEnabled() then
        return nil, "dev launch disabled"
    end
    local capabilities = sfp_adapter.capabilities()
    if not capabilities.has_interface then
        return nil, "I.MagExp missing"
    end
    if not capabilities.has_launchSpell then
        return nil, "I.MagExp.launchSpell missing"
    end
    if type(job.helper_engine_id) ~= "string" or job.helper_engine_id == "" then
        return nil, "helper_engine_id must be a non-empty string"
    end

    local mapping = helper_records.getByEngineId(job.helper_engine_id)
    if not mapping then
        return nil, string.format("helper record metadata not found for engine_id=%s", tostring(job.helper_engine_id))
    end
    if mapping.recipe_id ~= job.recipe_id or mapping.slot_id ~= job.slot_id then
        return nil, string.format(
            "helper metadata mismatch expected recipe_id=%s slot_id=%s got recipe_id=%s slot_id=%s",
            tostring(job.recipe_id),
            tostring(job.slot_id),
            tostring(mapping.recipe_id),
            tostring(mapping.slot_id)
        )
    end
    if expected_postfix_opcode and mapping.source_postfix_opcode ~= expected_postfix_opcode then
        return nil, string.format("helper slot_id=%s is not a %s payload helper", tostring(mapping.slot_id), tostring(expected_postfix_opcode))
    end

    return mapping, nil
end

function dev_runtime.launchContextForKind(job_kind, payload)
    local launch_payload = payload or {}
    local start_pos = launch_payload.start_pos

    if job_kind == "dev_timer_payload" then
        if launch_payload.resolution_pos == nil then
            return nil, "Timer payload missing resolution_pos"
        end
        start_pos = launch_payload.resolution_pos
    elseif job_kind == "dev_trigger_payload" then
        if launch_payload.source_hit_pos == nil then
            return nil, "Trigger payload missing source_hit_pos"
        end
        start_pos = launch_payload.source_hit_pos
    end

    return {
        actor = launch_payload.actor or launch_payload.caster,
        start_pos = start_pos,
        direction = launch_payload.direction,
        hit_object = launch_payload.hit_object,
    }, nil
end

function dev_runtime.launchHelper(context)
    local result = runtime_launch.launchHelper(context or {})
    if not result.ok then
        return false, tostring(result.error), result
    end
    return true, nil, result
end

function dev_runtime.runHelperLaunchJob(job, job_kind)
    local expected_postfix_opcode = expectedPostfixForKind(job_kind)
    local mapping, validate_err = dev_runtime.validateHelperLaunchJob(job, expected_postfix_opcode)
    if not mapping then
        return false, validate_err, nil
    end

    local payload = job.payload or {}
    local launch_context, context_err = dev_runtime.launchContextForKind(job_kind, payload)
    if not launch_context then
        return false, context_err, nil
    end

    log.debug(string.format(
        "%s params recipe_id=%s slot_id=%s spellId=%s actor=%s startPos=%s resolution_kind=%s source_hit_pos=%s",
        tostring(job_kind),
        tostring(job.recipe_id),
        tostring(job.slot_id),
        tostring(job.helper_engine_id),
        tostring(launch_context.actor and launch_context.actor.recordId),
        tostring(launch_context.start_pos),
        tostring(payload.resolution_kind),
        tostring(payload.source_hit_pos)
    ))

    local ok, err, launch_result = dev_runtime.launchHelper({
        actor = launch_context.actor,
        helper_engine_id = job.helper_engine_id,
        start_pos = launch_context.start_pos,
        direction = launch_context.direction,
        hit_object = launch_context.hit_object,
        recipe_id = job.recipe_id,
        slot_id = job.slot_id,
        runtime = "2.2c_dev_helper",
        kind = job_kind,
        job_id = job.job_id,
        job_kind = job_kind,
        source_job_id = job.source_job_id,
        parent_job_id = job.parent_job_id,
        depth = job.depth,
        source_slot_id = payload.source_slot_id or mapping.trigger_source_slot_id or mapping.timer_source_slot_id,
        source_postfix_opcode = payload.source_postfix_opcode or mapping.source_postfix_opcode,
        userData = payload.userData or payload.user_data,
        muteAudio = payload.muteAudio,
        mute_audio = payload.mute_audio,
        muteLight = payload.muteLight,
        mute_light = payload.mute_light,
        emission_index = mapping.emission_index,
        group_index = mapping.group_index,
    })
    if not ok then
        return false, err, nil
    end

    job.launched_helper_engine_id = job.helper_engine_id
    job.launch_accepted = true
    job.launch_returned_projectile = launch_result and launch_result.launch_returned_projectile == true
    job.projectile_id = launch_result and launch_result.projectile_id or nil
    job.projectile_id_source = launch_result and launch_result.projectile_id_source or nil
    job.projectile_registered = launch_result and launch_result.projectile_registered == true
    job.launch_user_data = launch_result and launch_result.user_data or nil
    job.launch_start_pos = launch_context.start_pos
    job.launch_direction = launch_context.direction
    job.timer_source_slot_id = payload.source_slot_id or mapping.timer_source_slot_id
    job.timer_endpoint = payload.timer_endpoint
    job.timer_resolution_pos = payload.resolution_pos
    job.timer_resolution_kind = payload.resolution_kind
    job.trigger_source_slot_id = payload.source_slot_id or mapping.trigger_source_slot_id
    job.trigger_source_hit_pos = payload.source_hit_pos
    job.trigger_source_hit_normal = payload.source_hit_normal
    job.trace[#job.trace + 1] = tostring(job_kind) .. " launchSpell accepted"
    return true, nil, nil
end

function dev_runtime.resolveHelperHit(payload)
    if not dev.devLaunchEnabled() then
        return { ok = false, error = "dev launch disabled" }
    end
    return runtime_hits.resolveHelperHit(payload)
end

function dev_runtime.enqueuePayloadLaunchJob(orchestrator, args)
    local input = args or {}
    if not orchestrator or type(orchestrator.enqueue) ~= "function" then
        return { ok = false, error = "orchestrator enqueue unavailable" }
    end
    if type(input.job_kind) ~= "string" or input.job_kind == "" then
        return { ok = false, error = "payload job_kind must be a non-empty string" }
    end
    if type(input.recipe_id) ~= "string" or input.recipe_id == "" then
        return { ok = false, error = "payload recipe_id must be a non-empty string" }
    end
    if not input.payload_helper or type(input.payload_helper.engine_id) ~= "string" or input.payload_helper.engine_id == "" then
        return { ok = false, error = "payload helper missing engine_id" }
    end

    local payload = input.payload or {}
    local enqueue = orchestrator.enqueue({
        kind = input.job_kind,
        recipe_id = input.recipe_id,
        slot_id = input.payload_helper.slot_id,
        helper_engine_id = input.payload_helper.engine_id,
        idempotency_key = input.idempotency_key,
        source_job_id = input.source_job and input.source_job.job_id or input.source_job_id,
        parent_job_id = input.source_job and input.source_job.job_id or input.parent_job_id,
        depth = input.depth or 1,
        not_before_tick = input.not_before_tick,
        payload = payload,
    })
    if not enqueue.ok then
        return enqueue
    end

    return {
        ok = true,
        job_id = enqueue.job_id,
        status = enqueue.status,
        job_kind = input.job_kind,
        source_slot_id = input.source_slot_id,
        source_helper_engine_id = input.source_helper_engine_id,
        idempotency_key = input.idempotency_key,
        slot_id = input.payload_helper.slot_id,
        helper_engine_id = input.payload_helper.engine_id,
        effect_id = dev_runtime.firstEffectId(input.payload_helper),
        not_before_tick = input.not_before_tick,
        payload = payload,
    }
end

return dev_runtime
