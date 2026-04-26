local projectile_registry = require("scripts.spellforge.global.projectile_registry")
local helper_records = require("scripts.spellforge.global.helper_records")
local sfp_adapter = require("scripts.spellforge.global.sfp_adapter")

local runtime_launch = {}

function runtime_launch.launchHelper(input)
    local launch = input or {}
    local capabilities = sfp_adapter.capabilities()
    if not capabilities.has_interface then
        return { ok = false, error = "I.MagExp missing" }
    end
    if not capabilities.has_launchSpell then
        return { ok = false, error = "I.MagExp.launchSpell missing" }
    end
    if launch.actor == nil then
        return { ok = false, error = "missing caster for helper launch" }
    end
    if type(launch.helper_engine_id) ~= "string" or launch.helper_engine_id == "" then
        return { ok = false, error = "helper_engine_id must be a non-empty string" }
    end

    local launch_result = sfp_adapter.launchSpell({
        attacker = launch.actor,
        spellId = launch.helper_engine_id,
        startPos = launch.start_pos,
        direction = launch.direction,
        hitObject = launch.hit_object,
        isFree = launch.is_free ~= false,
    })
    if not launch_result.ok then
        return {
            ok = false,
            error = tostring(launch_result.error),
            helper_engine_id = launch.helper_engine_id,
            recipe_id = launch.recipe_id,
            slot_id = launch.slot_id,
            launch_result_raw = launch_result.launch_result_raw,
            warnings = launch_result.warnings,
            capability_notes = launch_result.capability_notes,
        }
    end

    local registry_entry = projectile_registry.registerLaunch(launch_result, {
        recipe_id = launch.recipe_id,
        slot_id = launch.slot_id,
        helper_engine_id = launch.helper_engine_id,
        job_id = launch.job_id,
        job_kind = launch.job_kind or launch.kind,
        start_pos = launch.start_pos,
        direction = launch.direction,
        reason = launch.reason or launch.kind,
        source_job_id = launch.source_job_id,
        parent_job_id = launch.parent_job_id,
    })

    return {
        ok = true,
        error = nil,
        helper_engine_id = launch.helper_engine_id,
        recipe_id = launch.recipe_id,
        slot_id = launch.slot_id,
        projectile = launch_result.projectile,
        projectile_id = launch_result.projectile_id,
        projectile_id_source = launch_result.projectile_id_source,
        launch_result_raw = launch_result.launch_result_raw,
        launch_result = launch_result,
        launch_returns_projectile = launch_result.launch_returns_projectile == true,
        launch_returned_projectile = launch_result.launch_returns_projectile == true,
        projectile_registered = registry_entry ~= nil and registry_entry.projectile_id ~= nil,
        registry_entry = registry_entry,
        warnings = launch_result.warnings or {},
        capability_notes = launch_result.capability_notes or {},
    }
end

function runtime_launch.validateHelperLaunchJob(job, expected_postfix_opcode)
    if type(job) ~= "table" then
        return nil, "job must be a table"
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

function runtime_launch.runHelperLaunchJob(job, job_kind, opts)
    local options = opts or {}
    local mapping, validate_err = runtime_launch.validateHelperLaunchJob(job, options.expected_postfix_opcode)
    if not mapping then
        return false, validate_err, nil
    end

    local payload = job.payload or {}
    local result = runtime_launch.launchHelper({
        actor = payload.actor or payload.caster,
        helper_engine_id = job.helper_engine_id,
        start_pos = payload.start_pos,
        direction = payload.direction,
        hit_object = payload.hit_object,
        recipe_id = job.recipe_id,
        slot_id = job.slot_id,
        kind = job_kind or job.kind,
        job_id = job.job_id,
        job_kind = job_kind or job.kind,
        source_job_id = job.source_job_id,
        parent_job_id = job.parent_job_id,
    })
    if not result.ok then
        return false, tostring(result.error), nil
    end

    job.launched_helper_engine_id = job.helper_engine_id
    job.launch_accepted = true
    job.launch_returned_projectile = result.launch_returned_projectile == true
    job.projectile_id = result.projectile_id
    job.projectile_id_source = result.projectile_id_source
    job.projectile_registered = result.projectile_registered == true
    job.launch_start_pos = payload.start_pos
    job.launch_direction = payload.direction
    job.trace = job.trace or {}
    job.trace[#job.trace + 1] = tostring(job_kind or job.kind) .. " launchSpell accepted"
    return true, nil, nil
end

return runtime_launch
