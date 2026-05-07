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

local function applyPostLaunchPhysics(launch_data, launch_result, capabilities)
    local out = {}
    local projectile_id = launch_result and launch_result.projectile_id or nil
    local has_bounce = launch_data.bounceEnabled ~= nil
        or launch_data.bounceMax ~= nil
        or launch_data.bouncePower ~= nil
    local has_pierce = launch_data.piercing ~= nil
        or launch_data.pierceLimit ~= nil
    local has_actor_toggle = launch_data.detonateOnActorHit ~= nil
    if projectile_id == nil then
        if has_bounce or has_pierce or has_actor_toggle then
            runtime_stats.inc("sfp_post_launch_physics_projectile_missing")
            out.projectile_missing = true
        end
        return out
    end

    if (has_bounce or has_pierce or has_actor_toggle) and capabilities and capabilities.has_setSpellPhysics then
        local physics = {}
        copyIfPresent(physics, "bounceEnabled", launch_data.bounceEnabled)
        copyIfPresent(physics, "bounceMax", launch_data.bounceMax)
        copyIfPresent(physics, "bouncePower", launch_data.bouncePower)
        copyIfPresent(physics, "piercing", launch_data.piercing)
        copyIfPresent(physics, "pierceLimit", launch_data.pierceLimit)
        copyIfPresent(physics, "detonateOnActorHit", launch_data.detonateOnActorHit)
        local result = sfp_adapter.setSpellPhysics(projectile_id, physics)
        if has_bounce then
            out.bounce_attempted = true
            runtime_stats.inc("sfp_post_launch_bounce_attempts")
            out.bounce_ok = result.ok == true
            out.bounce_error = result.error
            if out.bounce_ok then
                runtime_stats.inc("sfp_post_launch_bounce_ok")
            else
                runtime_stats.inc("sfp_post_launch_bounce_failed")
            end
        end
        if has_actor_toggle then
            out.detonate_on_actor_attempted = true
            runtime_stats.inc("sfp_post_launch_actor_toggle_attempts")
            out.detonate_on_actor_ok = result.ok == true
            out.detonate_on_actor_error = result.error
            if out.detonate_on_actor_ok then
                runtime_stats.inc("sfp_post_launch_actor_toggle_ok")
            else
                runtime_stats.inc("sfp_post_launch_actor_toggle_failed")
            end
        end
        if has_pierce then
            out.pierce_attempted = true
            runtime_stats.inc("sfp_post_launch_pierce_attempts")
            out.pierce_ok = result.ok == true
            out.pierce_error = result.error
            if out.pierce_ok then
                runtime_stats.inc("sfp_post_launch_pierce_ok")
            else
                runtime_stats.inc("sfp_post_launch_pierce_failed")
            end
        end
        return out
    end

    if has_bounce then
        out.bounce_attempted = true
        runtime_stats.inc("sfp_post_launch_bounce_attempts")
        if capabilities and capabilities.has_setSpellBounce then
            local result = sfp_adapter.setSpellBounce(
                projectile_id,
                launch_data.bounceEnabled == true,
                launch_data.bounceMax,
                launch_data.bouncePower
            )
            out.bounce_ok = result.ok == true
            out.bounce_error = result.error
            if out.bounce_ok then
                runtime_stats.inc("sfp_post_launch_bounce_ok")
            else
                runtime_stats.inc("sfp_post_launch_bounce_failed")
            end
        else
            out.bounce_ok = false
            out.bounce_error = "I.MagExp.setSpellBounce missing"
            runtime_stats.inc("sfp_post_launch_bounce_failed")
        end
    end

    if has_actor_toggle then
        out.detonate_on_actor_attempted = true
        runtime_stats.inc("sfp_post_launch_actor_toggle_attempts")
        if capabilities and capabilities.has_setSpellDetonateOnActor then
            local result = sfp_adapter.setSpellDetonateOnActor(projectile_id, launch_data.detonateOnActorHit)
            out.detonate_on_actor_ok = result.ok == true
            out.detonate_on_actor_error = result.error
            if out.detonate_on_actor_ok then
                runtime_stats.inc("sfp_post_launch_actor_toggle_ok")
            else
                runtime_stats.inc("sfp_post_launch_actor_toggle_failed")
            end
        else
            out.detonate_on_actor_ok = false
            out.detonate_on_actor_error = "I.MagExp.setSpellDetonateOnActor missing"
            runtime_stats.inc("sfp_post_launch_actor_toggle_failed")
        end
    end

    if has_pierce then
        out.pierce_attempted = true
        runtime_stats.inc("sfp_post_launch_pierce_attempts")
        if capabilities and capabilities.has_setSpellPiercing then
            local result = sfp_adapter.setSpellPiercing(
                projectile_id,
                launch_data.piercing == true,
                launch_data.pierceLimit
            )
            out.pierce_ok = result.ok == true
            out.pierce_error = result.error
            if out.pierce_ok then
                runtime_stats.inc("sfp_post_launch_pierce_ok")
            else
                runtime_stats.inc("sfp_post_launch_pierce_failed")
            end
        else
            out.pierce_ok = false
            out.pierce_error = "I.MagExp.setSpellPiercing missing"
            runtime_stats.inc("sfp_post_launch_pierce_failed")
        end
    end

    return out
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
        root_source_slot_id = launch.root_source_slot_id,
        current_source_slot_id = launch.current_source_slot_id,
        parent_slot_id = launch.parent_slot_id,
        payload_depth = launch.payload_depth,
        nested_stage_kind = launch.nested_stage_kind,
        nested_stage_index = launch.nested_stage_index,
        nested_final_fanout = launch.nested_final_fanout,
        nested_final_fanout_kind = launch.nested_final_fanout_kind,
        final_fanout_count = launch.final_fanout_count,
        final_fanout_index = launch.final_fanout_index,
        source_slot_id = launch.source_slot_id,
        source_prefix_opcode = launch.source_prefix_opcode,
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
        pattern_direction_key = launch.pattern_direction_key,
        chain_runtime = launch.chain_runtime,
        chain_role = launch.chain_role,
        chain_id = launch.chain_id,
        chain_hop_index = launch.chain_hop_index,
        chain_max_hops = launch.chain_max_hops,
        chain_targeting_mode = launch.chain_targeting_mode,
        chain_target_provider = launch.chain_target_provider,
        branch_scope = launch.branch_scope,
        branch_id = launch.branch_id,
        branch_parent_id = launch.branch_parent_id,
        branch_kind = launch.branch_kind,
        branch_index = launch.branch_index,
        branch_count = launch.branch_count,
        chain_continuation_group_id = launch.chain_continuation_group_id,
        current_hit_target_id = launch.current_hit_target_id,
        selected_target_id = launch.selected_target_id,
        previous_projectile_id = launch.previous_projectile_id,
        bounce_runtime = launch.bounce_runtime,
        bounce_role = launch.bounce_role,
        bounce_id = launch.bounce_id,
        bounce_index = launch.bounce_index,
        bounce_max = launch.bounce_max,
        bounce_power = launch.bounce_power,
        bounce_detonate_on_actor_hit = launch.bounce_detonate_on_actor_hit,
        bounce_trigger_payload_slot_id = launch.bounce_trigger_payload_slot_id,
        bounce_manual_detonation = launch.bounce_manual_detonation,
        bounce_final = launch.bounce_final,
        pierce_runtime = launch.pierce_runtime,
        pierce_role = launch.pierce_role,
        pierce_id = launch.pierce_id,
        pierce_count = launch.pierce_count,
        pierce_limit = launch.pierce_limit,
        pierce_trigger_payload_slot_id = launch.pierce_trigger_payload_slot_id,
        payload_modifier_kind = launch.payload_modifier_kind,
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
        homing = launch.homing,
        homing_mode = launch.homing_mode,
        homing_force = launch.homing_force,
        homing_field = launch.homing_field,
        homing_target_id = launch.homing_target_id,
        homing_target_provider = launch.homing_target_provider,
        homing_target_kind = launch.homing_target_kind,
        homing_candidate_count = launch.homing_candidate_count,
        homing_actor_candidate_count = launch.homing_actor_candidate_count,
        homing_creature_candidate_count = launch.homing_creature_candidate_count,
        homing_npc_candidate_count = launch.homing_npc_candidate_count,
        homing_force_key = launch.homing_force_key,
        homing_direction_key = launch.homing_direction_key,
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
    local min_speed = firstNonNil(launch.minSpeed, launch.min_speed)
    if type(min_speed) == "number" then
        launch_data.minSpeed = min_speed
    end
    local acceleration_exp = firstNonNil(launch.accelerationExp, launch.acceleration_exp)
    if type(acceleration_exp) == "number" then
        launch_data.accelerationExp = acceleration_exp
    end
    copyIfPresent(launch_data, "itemObject", firstNonNil(launch.itemObject, launch.item_object, launch.item))
    copyIfPresent(launch_data, "casterLinked", firstNonNil(launch.casterLinked, launch.caster_linked))
    copyIfPresent(launch_data, "forceVec", firstNonNil(launch.forceVec, launch.force_vec))
    copyIfPresent(launch_data, "maxLifetime", firstNonNil(launch.maxLifetime, launch.max_lifetime))
    copyIfPresent(launch_data, "spawnOffset", firstNonNil(launch.spawnOffset, launch.spawn_offset))
    copyIfPresent(launch_data, "isPaused", firstNonNil(launch.isPaused, launch.is_paused))
    copyIfPresent(launch_data, "bounceEnabled", firstNonNil(launch.bounceEnabled, launch.bounce_enabled))
    copyIfPresent(launch_data, "bounceMax", firstNonNil(launch.bounceMax, launch.bounce_max))
    copyIfPresent(launch_data, "bouncePower", firstNonNil(launch.bouncePower, launch.bounce_power))
    copyIfPresent(launch_data, "piercing", firstNonNil(launch.piercing, launch.piercing_enabled))
    copyIfPresent(launch_data, "pierceLimit", firstNonNil(launch.pierceLimit, launch.pierce_limit))
    copyIfPresent(launch_data, "detonateOnActorHit", firstNonNil(launch.detonateOnActorHit, launch.detonate_on_actor_hit))
    copyIfPresent(launch_data, "impactImpulse", firstNonNil(launch.impactImpulse, launch.impact_impulse))
    copyIfPresent(launch_data, "spellType", firstNonNil(launch.spellType, launch.spell_type))
    copyIfPresent(launch_data, "area", firstNonNil(launch.area))
    copyIfPresent(launch_data, "unreflectable", firstNonNil(launch.unreflectable))
    copyIfPresent(launch_data, "nonRecastable", firstNonNil(launch.nonRecastable, launch.non_recastable))
    copyIfPresent(launch_data, "itemRequirements", firstNonNil(launch.itemRequirements, launch.item_requirements))

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
    local bolt_sound = nonEmptyString(firstNonNil(
        launch.boltSound,
        launch.bolt_sound,
        presentation and presentation.boltSound,
        presentation and presentation.bolt_sound
    ))
    if bolt_sound then
        launch_data.boltSound = bolt_sound
    end
    copyIfPresent(launch_data, "boltLightId", firstNonNil(
        launch.boltLightId,
        launch.bolt_light_id,
        presentation and presentation.boltLightId,
        presentation and presentation.bolt_light_id
    ))
    copyIfPresent(launch_data, "spinSpeed", firstNonNil(
        launch.spinSpeed,
        launch.spin_speed,
        presentation and presentation.spinSpeed,
        presentation and presentation.spin_speed
    ))
    copyIfPresent(launch_data, "muteCastGlow", firstNonNil(launch.muteCastGlow, launch.mute_cast_glow))
    copyIfPresent(launch_data, "continuousVfx", firstNonNil(launch.continuousVfx, launch.continuous_vfx))
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
    local post_launch_physics = applyPostLaunchPhysics(launch_data, launch_result, capabilities)

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
        post_launch_physics = post_launch_physics,
        post_launch_bounce_attempted = post_launch_physics.bounce_attempted == true,
        post_launch_bounce_ok = post_launch_physics.bounce_ok == true,
        post_launch_bounce_error = post_launch_physics.bounce_error,
        post_launch_pierce_attempted = post_launch_physics.pierce_attempted == true,
        post_launch_pierce_ok = post_launch_physics.pierce_ok == true,
        post_launch_pierce_error = post_launch_physics.pierce_error,
        post_launch_detonate_on_actor_attempted = post_launch_physics.detonate_on_actor_attempted == true,
        post_launch_detonate_on_actor_ok = post_launch_physics.detonate_on_actor_ok == true,
        post_launch_detonate_on_actor_error = post_launch_physics.detonate_on_actor_error,
        minSpeed = launch_data.minSpeed,
        accelerationExp = launch_data.accelerationExp,
        forceVec = launch_data.forceVec,
        maxLifetime = launch_data.maxLifetime,
        spawnOffset = launch_data.spawnOffset,
        isPaused = launch_data.isPaused,
        bounceEnabled = launch_data.bounceEnabled,
        bounceMax = launch_data.bounceMax,
        bouncePower = launch_data.bouncePower,
        piercing = launch_data.piercing,
        pierceLimit = launch_data.pierceLimit,
        detonateOnActorHit = launch_data.detonateOnActorHit,
        impactImpulse = launch_data.impactImpulse,
        areaVfxRecId = launch_data.areaVfxRecId,
        areaVfxScale = launch_data.areaVfxScale,
        vfxRecId = launch_data.vfxRecId,
        boltModel = launch_data.boltModel,
        hitModel = launch_data.hitModel,
        boltSound = launch_data.boltSound,
        boltLightId = launch_data.boltLightId,
        spinSpeed = launch_data.spinSpeed,
        muteCastGlow = launch_data.muteCastGlow,
        continuousVfx = launch_data.continuousVfx,
        excludeTarget = launch_data.excludeTarget,
        forcedEffects = launch_data.forcedEffects,
        spellType = launch_data.spellType,
        area = launch_data.area,
        unreflectable = launch_data.unreflectable,
        nonRecastable = launch_data.nonRecastable,
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
        root_source_slot_id = payload.root_source_slot_id or job.root_source_slot_id,
        current_source_slot_id = payload.current_source_slot_id or job.current_source_slot_id,
        parent_slot_id = payload.parent_slot_id or job.parent_slot_id,
        payload_depth = payload.payload_depth or job.payload_depth,
        nested_stage_kind = payload.nested_stage_kind or job.nested_stage_kind,
        nested_stage_index = payload.nested_stage_index or job.nested_stage_index,
        nested_final_fanout = payload.nested_final_fanout or job.nested_final_fanout,
        nested_final_fanout_kind = payload.nested_final_fanout_kind or job.nested_final_fanout_kind,
        final_fanout_count = payload.final_fanout_count or job.final_fanout_count,
        final_fanout_index = payload.final_fanout_index or job.final_fanout_index,
        cast_id = payload.cast_id or job.cast_id,
        source_slot_id = payload.source_slot_id,
        source_prefix_opcode = payload.source_prefix_opcode,
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
        pattern_direction_key = payload.pattern_direction_key or job.pattern_direction_key,
        chain_runtime = payload.chain_runtime or job.chain_runtime,
        chain_role = payload.chain_role or job.chain_role,
        chain_id = payload.chain_id or job.chain_id,
        chain_hop_index = payload.chain_hop_index or job.chain_hop_index,
        chain_max_hops = payload.chain_max_hops or job.chain_max_hops,
        chain_targeting_mode = payload.chain_targeting_mode or job.chain_targeting_mode,
        chain_target_provider = payload.chain_target_provider or job.chain_target_provider,
        branch_scope = payload.branch_scope or job.branch_scope,
        branch_id = payload.branch_id or job.branch_id,
        branch_parent_id = payload.branch_parent_id or job.branch_parent_id,
        branch_kind = payload.branch_kind or job.branch_kind,
        branch_index = payload.branch_index or job.branch_index,
        branch_count = payload.branch_count or job.branch_count,
        chain_continuation_group_id = payload.chain_continuation_group_id or job.chain_continuation_group_id,
        current_hit_target_id = payload.current_hit_target_id or job.current_hit_target_id,
        selected_target_id = payload.selected_target_id or job.selected_target_id,
        previous_projectile_id = payload.previous_projectile_id or job.previous_projectile_id,
        bounceEnabled = firstNonNil(payload.bounceEnabled, payload.bounce_enabled, job.bounceEnabled, job.bounce_enabled),
        bounceMax = firstNonNil(payload.bounceMax, payload.bounce_max, job.bounceMax, job.bounce_max),
        bouncePower = firstNonNil(payload.bouncePower, payload.bounce_power, job.bouncePower, job.bounce_power),
        detonateOnActorHit = firstNonNil(payload.detonateOnActorHit, payload.detonate_on_actor_hit, job.detonateOnActorHit, job.detonate_on_actor_hit),
        bounce_runtime = firstNonNil(payload.bounce_runtime, job.bounce_runtime),
        bounce_role = firstNonNil(payload.bounce_role, job.bounce_role),
        bounce_id = firstNonNil(payload.bounce_id, job.bounce_id),
        bounce_index = firstNonNil(payload.bounce_index, job.bounce_index),
        bounce_max = firstNonNil(payload.bounce_max, job.bounce_max),
        bounce_power = firstNonNil(payload.bounce_power, job.bounce_power),
        bounce_detonate_on_actor_hit = firstNonNil(payload.bounce_detonate_on_actor_hit, job.bounce_detonate_on_actor_hit),
        bounce_trigger_payload_slot_id = firstNonNil(payload.bounce_trigger_payload_slot_id, job.bounce_trigger_payload_slot_id),
        bounce_manual_detonation = firstNonNil(payload.bounce_manual_detonation, job.bounce_manual_detonation),
        bounce_final = firstNonNil(payload.bounce_final, job.bounce_final),
        piercing = firstNonNil(job.piercing, job.piercing_enabled, payload.piercing, payload.piercing_enabled),
        pierceLimit = firstNonNil(job.pierceLimit, job.pierce_limit, payload.pierceLimit, payload.pierce_limit),
        pierce_runtime = firstNonNil(payload.pierce_runtime, job.pierce_runtime),
        pierce_role = firstNonNil(payload.pierce_role, job.pierce_role),
        pierce_id = firstNonNil(payload.pierce_id, job.pierce_id),
        pierce_count = firstNonNil(payload.pierce_count, job.pierce_count),
        pierce_limit = firstNonNil(payload.pierce_limit, job.pierce_limit),
        pierce_trigger_payload_slot_id = firstNonNil(payload.pierce_trigger_payload_slot_id, job.pierce_trigger_payload_slot_id),
        payload_modifier_kind = payload.payload_modifier_kind or job.payload_modifier_kind,
        speed = firstNonNil(payload.speed, job.speed),
        maxSpeed = firstNonNil(payload.maxSpeed, job.maxSpeed),
        accelerationExp = firstNonNil(payload.accelerationExp, payload.acceleration_exp, job.accelerationExp, job.acceleration_exp),
        forceVec = firstNonNil(payload.forceVec, payload.force_vec, job.forceVec, job.force_vec),
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
        homing = payload.homing or job.homing,
        homing_mode = payload.homing_mode or job.homing_mode,
        homing_force = payload.homing_force or job.homing_force,
        homing_field = payload.homing_field or job.homing_field,
        homing_target_id = payload.homing_target_id or job.homing_target_id,
        homing_target_provider = payload.homing_target_provider or job.homing_target_provider,
        homing_target_kind = payload.homing_target_kind or job.homing_target_kind,
        homing_candidate_count = payload.homing_candidate_count or job.homing_candidate_count,
        homing_actor_candidate_count = payload.homing_actor_candidate_count or job.homing_actor_candidate_count,
        homing_creature_candidate_count = payload.homing_creature_candidate_count or job.homing_creature_candidate_count,
        homing_npc_candidate_count = payload.homing_npc_candidate_count or job.homing_npc_candidate_count,
        homing_force_key = payload.homing_force_key or job.homing_force_key,
        homing_direction_key = payload.homing_direction_key or job.homing_direction_key,
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
    job.root_source_slot_id = payload.root_source_slot_id or job.root_source_slot_id
    job.current_source_slot_id = payload.current_source_slot_id or job.current_source_slot_id
    job.parent_slot_id = payload.parent_slot_id or job.parent_slot_id
    job.payload_depth = payload.payload_depth or job.payload_depth
    job.nested_stage_kind = payload.nested_stage_kind or job.nested_stage_kind
    job.nested_stage_index = payload.nested_stage_index or job.nested_stage_index
    job.nested_final_fanout = payload.nested_final_fanout or job.nested_final_fanout
    job.nested_final_fanout_kind = payload.nested_final_fanout_kind or job.nested_final_fanout_kind
    job.final_fanout_count = payload.final_fanout_count or job.final_fanout_count
    job.final_fanout_index = payload.final_fanout_index or job.final_fanout_index
    job.payload_slot_id = payload.payload_slot_id
    job.source_slot_id = payload.source_slot_id
    job.source_prefix_opcode = payload.source_prefix_opcode
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
    job.minSpeed = firstNonNil(result.minSpeed, payload.minSpeed, payload.min_speed, job.minSpeed, job.min_speed)
    job.accelerationExp = firstNonNil(result.accelerationExp, payload.accelerationExp, payload.acceleration_exp, job.accelerationExp, job.acceleration_exp)
    job.forceVec = firstNonNil(result.forceVec, payload.forceVec, payload.force_vec, job.forceVec, job.force_vec)
    job.maxLifetime = firstNonNil(result.maxLifetime, payload.maxLifetime, payload.max_lifetime, job.maxLifetime, job.max_lifetime)
    job.spawnOffset = firstNonNil(result.spawnOffset, payload.spawnOffset, payload.spawn_offset, job.spawnOffset, job.spawn_offset)
    job.isPaused = firstNonNil(result.isPaused, payload.isPaused, payload.is_paused, job.isPaused, job.is_paused)
    job.bounceEnabled = firstNonNil(result.bounceEnabled, payload.bounceEnabled, payload.bounce_enabled, job.bounceEnabled, job.bounce_enabled)
    job.bounceMax = firstNonNil(result.bounceMax, payload.bounceMax, payload.bounce_max, job.bounceMax, job.bounce_max)
    job.bouncePower = firstNonNil(result.bouncePower, payload.bouncePower, payload.bounce_power, job.bouncePower, job.bounce_power)
    job.piercing = firstNonNil(job.piercing, job.piercing_enabled, payload.piercing, payload.piercing_enabled, result.piercing)
    job.pierceLimit = firstNonNil(job.pierceLimit, job.pierce_limit, payload.pierceLimit, payload.pierce_limit, result.pierceLimit)
    job.detonateOnActorHit = firstNonNil(result.detonateOnActorHit, payload.detonateOnActorHit, payload.detonate_on_actor_hit, job.detonateOnActorHit, job.detonate_on_actor_hit)
    job.impactImpulse = firstNonNil(result.impactImpulse, payload.impactImpulse, payload.impact_impulse, job.impactImpulse, job.impact_impulse)
    job.areaVfxRecId = firstNonNil(result.areaVfxRecId, payload.areaVfxRecId, payload.area_vfx_rec_id, job.areaVfxRecId, job.area_vfx_rec_id)
    job.areaVfxScale = firstNonNil(result.areaVfxScale, payload.areaVfxScale, payload.area_vfx_scale, job.areaVfxScale, job.area_vfx_scale)
    job.vfxRecId = firstNonNil(result.vfxRecId, payload.vfxRecId, payload.vfx_rec_id, job.vfxRecId, job.vfx_rec_id)
    job.boltModel = firstNonNil(result.boltModel, payload.boltModel, payload.bolt_model, job.boltModel, job.bolt_model)
    job.hitModel = firstNonNil(result.hitModel, payload.hitModel, payload.hit_model, job.hitModel, job.hit_model)
    job.boltSound = firstNonNil(result.boltSound, payload.boltSound, payload.bolt_sound, job.boltSound, job.bolt_sound)
    job.boltLightId = firstNonNil(result.boltLightId, payload.boltLightId, payload.bolt_light_id, job.boltLightId, job.bolt_light_id)
    job.spinSpeed = firstNonNil(result.spinSpeed, payload.spinSpeed, payload.spin_speed, job.spinSpeed, job.spin_speed)
    job.muteCastGlow = firstNonNil(result.muteCastGlow, payload.muteCastGlow, payload.mute_cast_glow, job.muteCastGlow, job.mute_cast_glow)
    job.continuousVfx = firstNonNil(result.continuousVfx, payload.continuousVfx, payload.continuous_vfx, job.continuousVfx, job.continuous_vfx)
    job.excludeTarget = firstNonNil(result.excludeTarget, payload.excludeTarget, payload.exclude_target, job.excludeTarget, job.exclude_target)
    job.forcedEffects = firstNonNil(result.forcedEffects, payload.forcedEffects, payload.forced_effects, job.forcedEffects, job.forced_effects)
    job.spellType = firstNonNil(result.spellType, payload.spellType, payload.spell_type, job.spellType, job.spell_type)
    job.area = firstNonNil(result.area, payload.area, job.area)
    job.unreflectable = firstNonNil(result.unreflectable, payload.unreflectable, job.unreflectable)
    job.nonRecastable = firstNonNil(result.nonRecastable, payload.nonRecastable, payload.non_recastable, job.nonRecastable, job.non_recastable)
    job.forwarded_launch_fields = result.forwarded_fields
    job.post_launch_physics = result.post_launch_physics
    job.post_launch_bounce_attempted = result.post_launch_bounce_attempted == true
    job.post_launch_bounce_ok = result.post_launch_bounce_ok == true
    job.post_launch_bounce_error = result.post_launch_bounce_error
    job.post_launch_pierce_attempted = result.post_launch_pierce_attempted == true
    job.post_launch_pierce_ok = result.post_launch_pierce_ok == true
    job.post_launch_pierce_error = result.post_launch_pierce_error
    job.post_launch_detonate_on_actor_attempted = result.post_launch_detonate_on_actor_attempted == true
    job.post_launch_detonate_on_actor_ok = result.post_launch_detonate_on_actor_ok == true
    job.post_launch_detonate_on_actor_error = result.post_launch_detonate_on_actor_error
    job.chain_runtime = payload.chain_runtime or job.chain_runtime
    job.chain_role = payload.chain_role or job.chain_role
    job.chain_id = payload.chain_id or job.chain_id
    job.chain_hop_index = payload.chain_hop_index or job.chain_hop_index
    job.chain_max_hops = payload.chain_max_hops or job.chain_max_hops
    job.chain_targeting_mode = payload.chain_targeting_mode or job.chain_targeting_mode
    job.chain_target_provider = payload.chain_target_provider or job.chain_target_provider
    job.branch_scope = payload.branch_scope or job.branch_scope
    job.branch_id = payload.branch_id or job.branch_id
    job.branch_parent_id = payload.branch_parent_id or job.branch_parent_id
    job.branch_kind = payload.branch_kind or job.branch_kind
    job.branch_index = payload.branch_index or job.branch_index
    job.branch_count = payload.branch_count or job.branch_count
    job.chain_continuation_group_id = payload.chain_continuation_group_id or job.chain_continuation_group_id
    job.current_hit_target_id = payload.current_hit_target_id or job.current_hit_target_id
    job.selected_target_id = payload.selected_target_id or job.selected_target_id
    job.previous_projectile_id = payload.previous_projectile_id or job.previous_projectile_id
    job.homing_target_provider = payload.homing_target_provider or job.homing_target_provider
    job.homing_target_kind = payload.homing_target_kind or job.homing_target_kind
    job.homing_candidate_count = payload.homing_candidate_count or job.homing_candidate_count
    job.homing_actor_candidate_count = payload.homing_actor_candidate_count or job.homing_actor_candidate_count
    job.homing_creature_candidate_count = payload.homing_creature_candidate_count or job.homing_creature_candidate_count
    job.homing_npc_candidate_count = payload.homing_npc_candidate_count or job.homing_npc_candidate_count
    job.bounce_runtime = firstNonNil(payload.bounce_runtime, job.bounce_runtime)
    job.bounce_role = firstNonNil(payload.bounce_role, job.bounce_role)
    job.bounce_id = firstNonNil(payload.bounce_id, job.bounce_id)
    job.bounce_index = firstNonNil(payload.bounce_index, job.bounce_index)
    job.bounce_max = firstNonNil(payload.bounce_max, job.bounce_max)
    job.bounce_power = firstNonNil(payload.bounce_power, job.bounce_power)
    job.bounce_detonate_on_actor_hit = firstNonNil(payload.bounce_detonate_on_actor_hit, job.bounce_detonate_on_actor_hit)
    job.bounce_trigger_payload_slot_id = firstNonNil(payload.bounce_trigger_payload_slot_id, job.bounce_trigger_payload_slot_id)
    job.bounce_manual_detonation = firstNonNil(payload.bounce_manual_detonation, job.bounce_manual_detonation)
    job.bounce_final = firstNonNil(payload.bounce_final, job.bounce_final)
    job.pierce_runtime = firstNonNil(payload.pierce_runtime, job.pierce_runtime)
    job.pierce_role = firstNonNil(payload.pierce_role, job.pierce_role)
    job.pierce_id = firstNonNil(payload.pierce_id, job.pierce_id)
    job.pierce_count = firstNonNil(payload.pierce_count, job.pierce_count)
    job.pierce_limit = firstNonNil(payload.pierce_limit, job.pierce_limit)
    job.pierce_trigger_payload_slot_id = firstNonNil(payload.pierce_trigger_payload_slot_id, job.pierce_trigger_payload_slot_id)
    job.payload_modifier_kind = payload.payload_modifier_kind or job.payload_modifier_kind
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
    job.homing = payload.homing or job.homing
    job.homing_mode = payload.homing_mode or job.homing_mode
    job.homing_force = payload.homing_force or job.homing_force
    job.homing_field = payload.homing_field or job.homing_field
    job.homing_target_id = payload.homing_target_id or job.homing_target_id
    job.homing_target_kind = payload.homing_target_kind or job.homing_target_kind
    job.homing_force_key = payload.homing_force_key or job.homing_force_key
    job.homing_direction_key = payload.homing_direction_key or job.homing_direction_key
    job.trace = job.trace or {}
    job.trace[#job.trace + 1] = tostring(job_kind or job.kind) .. " launchSpell accepted"
    return true, nil, nil
end

return runtime_launch
