local dev = require("scripts.spellforge.shared.dev")
local helper_records = require("scripts.spellforge.global.helper_records")
local interfaces = require("openmw.interfaces")
local log = require("scripts.spellforge.shared.log").new("global.dev_runtime")

local dev_runtime = {}

function dev_runtime.firstEffectId(helper)
    local first_effect = helper and helper.effects and helper.effects[1] or nil
    return first_effect and first_effect.id or nil
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
    if interfaces.MagExp == nil then
        return nil, "I.MagExp missing"
    end
    if type(interfaces.MagExp.launchSpell) ~= "function" then
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
    local launch = context or {}
    if interfaces.MagExp == nil then
        return false, "I.MagExp missing"
    end
    if type(interfaces.MagExp.launchSpell) ~= "function" then
        return false, "I.MagExp.launchSpell missing"
    end
    if launch.actor == nil then
        return false, "missing caster for dev launch"
    end
    if type(launch.helper_engine_id) ~= "string" or launch.helper_engine_id == "" then
        return false, "helper_engine_id must be a non-empty string"
    end

    local ok, err = pcall(interfaces.MagExp.launchSpell, {
        attacker = launch.actor,
        spellId = launch.helper_engine_id,
        startPos = launch.start_pos,
        direction = launch.direction,
        hitObject = launch.hit_object,
        isFree = true,
    })
    if not ok then
        return false, tostring(err)
    end
    return true, nil
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

    local ok, err = dev_runtime.launchHelper({
        actor = launch_context.actor,
        helper_engine_id = job.helper_engine_id,
        start_pos = launch_context.start_pos,
        direction = launch_context.direction,
        hit_object = launch_context.hit_object,
        recipe_id = job.recipe_id,
        slot_id = job.slot_id,
        kind = job_kind,
    })
    if not ok then
        return false, err, nil
    end

    job.launched_helper_engine_id = job.helper_engine_id
    job.launch_accepted = true
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

    local engine_id = payload and (payload.spellId or payload.spell_id) or nil
    if type(engine_id) ~= "string" or engine_id == "" then
        return { ok = false, error = "hit payload missing spellId" }
    end

    local mapping = helper_records.getByEngineId(engine_id)
    if not mapping then
        return {
            ok = false,
            engine_id = engine_id,
            error = string.format("helper record metadata not found for engine_id=%s", tostring(engine_id)),
        }
    end

    return {
        ok = true,
        mapping = mapping,
        recipe_id = mapping.recipe_id,
        slot_id = mapping.slot_id,
        helper_engine_id = mapping.engine_id,
        effect_id = dev_runtime.firstEffectId(mapping),
        hit_pos = payload and (payload.hitPos or payload.hit_pos) or nil,
        hit_normal = payload and (payload.hitNormal or payload.hit_normal) or nil,
        attacker = payload and payload.attacker or nil,
        target = payload and payload.target or nil,
        raw_payload = payload,
    }
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
        slot_id = input.payload_helper.slot_id,
        helper_engine_id = input.payload_helper.engine_id,
        effect_id = dev_runtime.firstEffectId(input.payload_helper),
        not_before_tick = input.not_before_tick,
        payload = payload,
    }
end

return dev_runtime
