local projectile_registry = require("scripts.spellforge.global.projectile_registry")
local helper_records = require("scripts.spellforge.global.helper_records")
local runtime_stats = require("scripts.spellforge.global.runtime_stats")
local sfp_adapter = require("scripts.spellforge.global.sfp_adapter")
local sfp_userdata = require("scripts.spellforge.shared.sfp_userdata")

local runtime_launch = {}

local function runtimeForJobKind(job_kind)
    if type(job_kind) == "string" and string.sub(job_kind, 1, 4) == "dev_" then
        return "2.2c_dev_helper"
    end
    if type(job_kind) == "string" and string.sub(job_kind, 1, 5) == "live_" then
        return "2.2c_live_helper"
    end
    return "2.2c_dev_helper"
end

local function firstNonNil(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if value ~= nil then
            return value
        end
    end
    return nil
end

local function copyIfPresent(tbl, key, value)
    if value ~= nil then
        tbl[key] = value
    end
end

local function nonEmptyString(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

local function finitePositiveNumber(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge or n <= 0 then
        return nil
    end
    return n
end

local function mappingHasAreaEffect(mapping)
    for _, effect in ipairs(mapping and mapping.effects or {}) do
        if (tonumber(effect.area) or 0) > 0 then
            return true
        end
    end
    return false
end

function runtime_launch.launchHelper(input)
    local launch = input or {}
    runtime_stats.inc("sfp_launch_attempts")
    local capabilities = sfp_adapter.capabilities()
    if not capabilities.has_interface then
        runtime_stats.inc("sfp_launch_missing_interface")
        runtime_stats.inc("sfp_launch_failed")
        return { ok = false, error = "I.MagExp missing" }
    end
    if not capabilities.has_launchSpell then
        runtime_stats.inc("sfp_launch_missing_interface")
        runtime_stats.inc("sfp_launch_failed")
        return { ok = false, error = "I.MagExp.launchSpell missing" }
    end
    if launch.actor == nil then
        runtime_stats.inc("sfp_launch_failed")
        return { ok = false, error = "missing caster for helper launch" }
    end
    if type(launch.helper_engine_id) ~= "string" or launch.helper_engine_id == "" then
        runtime_stats.inc("sfp_launch_failed")
        return { ok = false, error = "helper_engine_id must be a non-empty string" }
    end

    local mapping = helper_records.getByEngineId(launch.helper_engine_id)
    local supplied_user_data = sfp_userdata.compactSpellforgeUserData(launch.userData)
        or sfp_userdata.compactSpellforgeUserData(launch.user_data)
    local runtime = launch.runtime or runtimeForJobKind(launch.job_kind or launch.kind)
    local built_user_data = sfp_userdata.buildHelperUserData({
        runtime = runtime,
        mapping = mapping,
        recipe_id = launch.recipe_id,
        slot_id = launch.slot_id,
        helper_engine_id = launch.helper_engine_id,
        job_kind = launch.job_kind or launch.kind,
        job_id = launch.job_id,
        parent_job_id = launch.parent_job_id,
        source_job_id = launch.source_job_id,
        depth = launch.depth,
        source_slot_id = launch.source_slot_id,
        source_postfix_opcode = launch.source_postfix_opcode,
        payload_slot_id = launch.payload_slot_id,
        source_helper_engine_id = launch.source_helper_engine_id,
        trigger_source_slot_id = launch.trigger_source_slot_id,
        trigger_payload_slot_id = launch.trigger_payload_slot_id,
        has_trigger_payload = launch.has_trigger_payload,
        trigger_route = launch.trigger_route,
        trigger_duplicate_key = launch.trigger_duplicate_key,
        timer_source_slot_id = launch.timer_source_slot_id,
        timer_payload_slot_id = launch.timer_payload_slot_id,
        has_timer_payload = launch.has_timer_payload,
        timer_delay_ticks = launch.timer_delay_ticks,
        timer_delay_seconds = launch.timer_delay_seconds,
        timer_scheduled_tick = launch.timer_scheduled_tick,
        timer_due_tick = launch.timer_due_tick,
        timer_scheduled_seconds = launch.timer_scheduled_seconds,
        timer_due_seconds = launch.timer_due_seconds,
        timer_delay_semantics = launch.timer_delay_semantics,
        timer_duplicate_key = launch.timer_duplicate_key,
        timer_id = launch.timer_id,
        cast_id = launch.cast_id,
        emission_index = launch.emission_index,
        group_index = launch.group_index,
        fanout_count = launch.fanout_count,
        pattern_kind = launch.pattern_kind,
        pattern_index = launch.pattern_index,
        pattern_count = launch.pattern_count,
        speed_plus = launch.speed_plus,
        speed_plus_mode = launch.speed_plus_mode,
        speed_plus_value = launch.speed_plus_value,
        speed_plus_base_speed = launch.speed_plus_base_speed,
        speed_plus_multiplier = launch.speed_plus_multiplier,
        speed_plus_speed = launch.speed_plus_speed,
        speed_plus_max_speed = launch.speed_plus_max_speed,
        speed_plus_field = launch.speed_plus_field,
        speed_plus_capped = launch.speed_plus_capped,
        size_plus = launch.size_plus,
        size_plus_mode = launch.size_plus_mode,
        size_plus_value = launch.size_plus_value,
        size_plus_multiplier = launch.size_plus_multiplier,
        size_plus_field = launch.size_plus_field,
        size_plus_capped = launch.size_plus_capped,
        size_plus_base_area = launch.size_plus_base_area,
        size_plus_area = launch.size_plus_area,
    })
    if supplied_user_data then
        for key, value in pairs(built_user_data) do
            if supplied_user_data[key] == nil then
                supplied_user_data[key] = value
            end
        end
    end
    local user_data = supplied_user_data or built_user_data
    if runtime == "2.2c_live_helper" and (not user_data or type(user_data.cast_id) ~= "string" or user_data.cast_id == "") then
        runtime_stats.inc("cast_ids_missing")
    end

    local launch_data = {
        attacker = launch.actor,
        spellId = launch.helper_engine_id,
        startPos = launch.start_pos,
        direction = launch.direction,
        hitObject = launch.hit_object,
        isFree = launch.is_free ~= false,
        userData = user_data,
        muteAudio = firstNonNil(launch.mute_audio, launch.muteAudio, false),
        muteLight = firstNonNil(launch.mute_light, launch.muteLight, false),
    }
    local speed = firstNonNil(launch.speed, launch.initial_speed)
    if type(speed) == "number" then
        launch_data.speed = speed
    end
    local max_speed = firstNonNil(launch.maxSpeed, launch.max_speed)
    if type(max_speed) == "number" then
        launch_data.maxSpeed = max_speed
    end
    local acceleration_exp = firstNonNil(launch.accelerationExp, launch.acceleration_exp)
    if type(acceleration_exp) == "number" then
        launch_data.accelerationExp = acceleration_exp
    end

    local presentation = mapping and mapping.presentation or nil
    local area_vfx_rec_id = firstNonNil(
        launch.areaVfxRecId,
        launch.area_vfx_rec_id,
        presentation and presentation.areaVfxRecId,
        presentation and presentation.area_vfx_rec_id
    )
    if nonEmptyString(area_vfx_rec_id) then
        launch_data.areaVfxRecId = area_vfx_rec_id
        runtime_stats.inc("impact_vfx_metadata_present")
    elseif mappingHasAreaEffect(mapping) then
        runtime_stats.inc("impact_vfx_metadata_missing")
    end
    local area_vfx_scale = firstNonNil(
        launch.areaVfxScale,
        launch.area_vfx_scale,
        presentation and presentation.areaVfxScale,
        presentation and presentation.area_vfx_scale
    )
    area_vfx_scale = finitePositiveNumber(area_vfx_scale)
    if area_vfx_scale ~= nil then
        launch_data.areaVfxScale = area_vfx_scale
    end
    local vfx_rec_id = nonEmptyString(firstNonNil(
        launch.vfxRecId,
        launch.vfx_rec_id,
        presentation and presentation.vfxRecId,
        presentation and presentation.vfx_rec_id
    ))
    if vfx_rec_id then
        launch_data.vfxRecId = vfx_rec_id
        if launch_data.areaVfxRecId == nil and mappingHasAreaEffect(mapping) then
            runtime_stats.inc("impact_vfx_invalid_area_override_suppressed")
        end
    end
    local bolt_model = nonEmptyString(firstNonNil(
        launch.boltModel,
        launch.bolt_model,
        presentation and presentation.boltModel,
        presentation and presentation.bolt_model
    ))
    if bolt_model then
        launch_data.boltModel = bolt_model
    end
    local hit_model = nonEmptyString(firstNonNil(
        launch.hitModel,
        launch.hit_model,
        presentation and presentation.hitModel,
        presentation and presentation.hit_model
    ))
    if hit_model then
        launch_data.hitModel = hit_model
    end
    copyIfPresent(launch_data, "excludeTarget", firstNonNil(launch.excludeTarget, launch.exclude_target))
    copyIfPresent(launch_data, "forcedEffects", firstNonNil(launch.forcedEffects, launch.forced_effects))

    local launch_result = sfp_adapter.launchSpell(launch_data)
    if not launch_result.ok then
        runtime_stats.inc("sfp_launch_failed")
        return {
            ok = false,
            error = tostring(launch_result.error),
            helper_engine_id = launch.helper_engine_id,
            recipe_id = launch.recipe_id,
            slot_id = launch.slot_id,
            launch_result_raw = launch_result.launch_result_raw,
            warnings = launch_result.warnings,
            capability_notes = launch_result.capability_notes,
            forwarded_fields = launch_result.forwarded_fields,
            user_data = user_data,
        }
    end
    runtime_stats.inc("sfp_launch_ok")
    if launch_result.projectile_id ~= nil then
        runtime_stats.inc("sfp_projectile_id_returned")
    else
        runtime_stats.inc("sfp_projectile_id_missing")
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
        user_data = user_data,
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
        user_data = user_data,
        forwarded_fields = launch_result.forwarded_fields,
        accelerationExp = launch_data.accelerationExp,
        areaVfxRecId = launch_data.areaVfxRecId,
        areaVfxScale = launch_data.areaVfxScale,
        vfxRecId = launch_data.vfxRecId,
        boltModel = launch_data.boltModel,
        hitModel = launch_data.hitModel,
        excludeTarget = launch_data.excludeTarget,
        forcedEffects = launch_data.forcedEffects,
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
        depth = job.depth,
        cast_id = payload.cast_id or job.cast_id,
        source_slot_id = payload.source_slot_id,
        source_postfix_opcode = payload.source_postfix_opcode or mapping.source_postfix_opcode,
        payload_slot_id = payload.payload_slot_id,
        source_helper_engine_id = payload.source_helper_engine_id,
        trigger_source_slot_id = payload.trigger_source_slot_id,
        trigger_payload_slot_id = payload.trigger_payload_slot_id,
        has_trigger_payload = payload.has_trigger_payload,
        trigger_route = payload.trigger_route,
        trigger_duplicate_key = payload.trigger_duplicate_key,
        timer_source_slot_id = payload.timer_source_slot_id,
        timer_payload_slot_id = payload.timer_payload_slot_id,
        has_timer_payload = payload.has_timer_payload,
        timer_delay_ticks = payload.timer_delay_ticks,
        timer_delay_seconds = payload.timer_delay_seconds,
        timer_scheduled_tick = payload.timer_scheduled_tick,
        timer_due_tick = payload.timer_due_tick,
        timer_scheduled_seconds = payload.timer_scheduled_seconds,
        timer_due_seconds = payload.timer_due_seconds,
        timer_delay_semantics = payload.timer_delay_semantics,
        timer_duplicate_key = payload.timer_duplicate_key,
        timer_id = payload.timer_id,
        userData = payload.userData or payload.user_data,
        muteAudio = payload.muteAudio,
        mute_audio = payload.mute_audio,
        muteLight = payload.muteLight,
        mute_light = payload.mute_light,
        emission_index = mapping.emission_index,
        group_index = mapping.group_index,
        fanout_count = payload.fanout_count or job.fanout_count,
        pattern_kind = payload.pattern_kind or job.pattern_kind,
        pattern_index = payload.pattern_index or job.pattern_index,
        pattern_count = payload.pattern_count or job.pattern_count,
        speed = firstNonNil(payload.speed, job.speed),
        maxSpeed = firstNonNil(payload.maxSpeed, job.maxSpeed),
        accelerationExp = firstNonNil(payload.accelerationExp, payload.acceleration_exp, job.accelerationExp, job.acceleration_exp),
        areaVfxRecId = firstNonNil(payload.areaVfxRecId, payload.area_vfx_rec_id, job.areaVfxRecId, job.area_vfx_rec_id),
        areaVfxScale = firstNonNil(payload.areaVfxScale, payload.area_vfx_scale, job.areaVfxScale, job.area_vfx_scale),
        vfxRecId = firstNonNil(payload.vfxRecId, payload.vfx_rec_id, job.vfxRecId, job.vfx_rec_id),
        boltModel = firstNonNil(payload.boltModel, payload.bolt_model, job.boltModel, job.bolt_model),
        hitModel = firstNonNil(payload.hitModel, payload.hit_model, job.hitModel, job.hit_model),
        excludeTarget = firstNonNil(payload.excludeTarget, payload.exclude_target, job.excludeTarget, job.exclude_target),
        forcedEffects = firstNonNil(payload.forcedEffects, payload.forced_effects, job.forcedEffects, job.forced_effects),
        speed_plus = payload.speed_plus or job.speed_plus,
        speed_plus_mode = payload.speed_plus_mode or job.speed_plus_mode,
        speed_plus_value = payload.speed_plus_value or job.speed_plus_value,
        speed_plus_base_speed = payload.speed_plus_base_speed or job.speed_plus_base_speed,
        speed_plus_multiplier = payload.speed_plus_multiplier or job.speed_plus_multiplier,
        speed_plus_speed = payload.speed_plus_speed or job.speed_plus_speed,
        speed_plus_max_speed = payload.speed_plus_max_speed or job.speed_plus_max_speed,
        speed_plus_field = payload.speed_plus_field or job.speed_plus_field,
        speed_plus_capped = payload.speed_plus_capped or job.speed_plus_capped,
        size_plus = payload.size_plus or job.size_plus,
        size_plus_mode = payload.size_plus_mode or job.size_plus_mode,
        size_plus_value = payload.size_plus_value or job.size_plus_value,
        size_plus_multiplier = payload.size_plus_multiplier or job.size_plus_multiplier,
        size_plus_field = payload.size_plus_field or job.size_plus_field,
        size_plus_capped = payload.size_plus_capped or job.size_plus_capped,
        size_plus_base_area = payload.size_plus_base_area or job.size_plus_base_area,
        size_plus_area = payload.size_plus_area or job.size_plus_area,
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
    job.launch_user_data = result.user_data
    job.payload_slot_id = payload.payload_slot_id
    job.source_slot_id = payload.source_slot_id
    job.source_helper_engine_id = payload.source_helper_engine_id
    job.source_postfix_opcode = payload.source_postfix_opcode or mapping.source_postfix_opcode
    job.trigger_route = payload.trigger_route
    job.trigger_duplicate_key = payload.trigger_duplicate_key
    job.timer_source_slot_id = payload.timer_source_slot_id
    job.timer_payload_slot_id = payload.timer_payload_slot_id
    job.timer_delay_ticks = payload.timer_delay_ticks
    job.timer_delay_seconds = payload.timer_delay_seconds
    job.timer_scheduled_tick = payload.timer_scheduled_tick
    job.timer_due_tick = payload.timer_due_tick
    job.timer_scheduled_seconds = payload.timer_scheduled_seconds
    job.timer_due_seconds = payload.timer_due_seconds
    job.timer_delay_semantics = payload.timer_delay_semantics
    job.timer_duplicate_key = payload.timer_duplicate_key
    job.timer_id = payload.timer_id
    job.speed = firstNonNil(payload.speed, job.speed)
    job.maxSpeed = firstNonNil(payload.maxSpeed, job.maxSpeed)
    job.accelerationExp = firstNonNil(result.accelerationExp, payload.accelerationExp, payload.acceleration_exp, job.accelerationExp, job.acceleration_exp)
    job.areaVfxRecId = firstNonNil(result.areaVfxRecId, payload.areaVfxRecId, payload.area_vfx_rec_id, job.areaVfxRecId, job.area_vfx_rec_id)
    job.areaVfxScale = firstNonNil(result.areaVfxScale, payload.areaVfxScale, payload.area_vfx_scale, job.areaVfxScale, job.area_vfx_scale)
    job.vfxRecId = firstNonNil(result.vfxRecId, payload.vfxRecId, payload.vfx_rec_id, job.vfxRecId, job.vfx_rec_id)
    job.boltModel = firstNonNil(result.boltModel, payload.boltModel, payload.bolt_model, job.boltModel, job.bolt_model)
    job.hitModel = firstNonNil(result.hitModel, payload.hitModel, payload.hit_model, job.hitModel, job.hit_model)
    job.excludeTarget = firstNonNil(result.excludeTarget, payload.excludeTarget, payload.exclude_target, job.excludeTarget, job.exclude_target)
    job.forcedEffects = firstNonNil(result.forcedEffects, payload.forcedEffects, payload.forced_effects, job.forcedEffects, job.forced_effects)
    job.forwarded_launch_fields = result.forwarded_fields
    job.speed_plus = payload.speed_plus or job.speed_plus
    job.speed_plus_mode = payload.speed_plus_mode or job.speed_plus_mode
    job.speed_plus_value = payload.speed_plus_value or job.speed_plus_value
    job.speed_plus_base_speed = payload.speed_plus_base_speed or job.speed_plus_base_speed
    job.speed_plus_multiplier = payload.speed_plus_multiplier or job.speed_plus_multiplier
    job.speed_plus_speed = payload.speed_plus_speed or job.speed_plus_speed
    job.speed_plus_max_speed = payload.speed_plus_max_speed or job.speed_plus_max_speed
    job.speed_plus_field = payload.speed_plus_field or job.speed_plus_field
    job.speed_plus_capped = payload.speed_plus_capped or job.speed_plus_capped
    job.size_plus = payload.size_plus or job.size_plus
    job.size_plus_mode = payload.size_plus_mode or job.size_plus_mode
    job.size_plus_value = payload.size_plus_value or job.size_plus_value
    job.size_plus_multiplier = payload.size_plus_multiplier or job.size_plus_multiplier
    job.size_plus_field = payload.size_plus_field or job.size_plus_field
    job.size_plus_capped = payload.size_plus_capped or job.size_plus_capped
    job.size_plus_base_area = payload.size_plus_base_area or job.size_plus_base_area
    job.size_plus_area = payload.size_plus_area or job.size_plus_area
    job.trace = job.trace or {}
    job.trace[#job.trace + 1] = tostring(job_kind or job.kind) .. " launchSpell accepted"
    return true, nil, nil
end

return runtime_launch
