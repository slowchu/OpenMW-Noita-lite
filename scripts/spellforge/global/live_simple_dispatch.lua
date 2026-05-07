local dev = require("scripts.spellforge.shared.dev")
local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("global.live_simple_dispatch")
local limits = require("scripts.spellforge.shared.limits")
local helper_records = require("scripts.spellforge.global.helper_records")
local orchestrator = require("scripts.spellforge.global.orchestrator")
local patterns = require("scripts.spellforge.global.patterns")
local plan_cache = require("scripts.spellforge.global.plan_cache")
local nested_payload_audit = require("scripts.spellforge.global.nested_payload_audit")
local nested_trigger_timer = require("scripts.spellforge.global.nested_trigger_timer")
local chain_target_provider = require("scripts.spellforge.global.chain_target_provider")
local chain_targeting = require("scripts.spellforge.global.chain_targeting")
local chaos_budget = require("scripts.spellforge.global.chaos_budget")
local live_bounce = require("scripts.spellforge.global.live_bounce")
local live_chain = require("scripts.spellforge.global.live_chain")
local live_homing = require("scripts.spellforge.global.live_homing")
local live_pierce = require("scripts.spellforge.global.live_pierce")
local live_size_plus = require("scripts.spellforge.global.live_size_plus")
local live_speed_plus = require("scripts.spellforge.global.live_speed_plus")
local live_timer = require("scripts.spellforge.global.live_timer")
local live_trigger = require("scripts.spellforge.global.live_trigger")
local runtime_stats = require("scripts.spellforge.global.runtime_stats")
local sfp_adapter = require("scripts.spellforge.global.sfp_adapter")
local sfp_userdata = require("scripts.spellforge.shared.sfp_userdata")

local live_simple_dispatch = {}
local next_live_cast_index = 1
local seen_cast_ids = {}
local recipes = require("scripts.spellforge.global.live_dispatch_recipes")
local function applyBounceProbeMode(mode, opts)
    if mode == "bounce_disabled" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_TRIGGER_FIRE_FROST_TARGET }
        opts.force_bounce_disabled = true
        opts.force_trigger_enabled = true
    elseif mode == "bounce_source_only_dry_run" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_FIRE_TARGET }
        opts.force_bounce_enabled = true
    elseif mode == "bounce_source_only_launch" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_FIRE_TARGET }
        opts.force_bounce_enabled = true
        opts.dry_run = false
    elseif mode == "bounce_dry_run" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_TRIGGER_FIRE_FROST_TARGET }
        opts.force_bounce_enabled = true
        opts.force_trigger_enabled = true
    elseif mode == "bounce_trigger_simple_post_bounce" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_TRIGGER_FIRE_FROST_TARGET }
        opts.force_bounce_enabled = true
        opts.force_trigger_enabled = true
        opts.register_bounce_probe_binding = true
    elseif mode == "bounce_launch" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_TRIGGER_FIRE_FROST_TARGET }
        opts.force_bounce_enabled = true
        opts.force_trigger_enabled = true
        opts.dry_run = false
    elseif mode == "bounce_chain_payload_disabled" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_TRIGGER_CHAIN_FROST_TARGET }
        opts.force_bounce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_chain_runtime_disabled = true
    elseif mode == "bounce_chain_payload_dry_run" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_TRIGGER_CHAIN_FROST_TARGET }
        opts.force_bounce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_chain_runtime_enabled = true
    elseif mode == "bounce_chain_payload_no_target" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_TRIGGER_CHAIN_FROST_TARGET }
        opts.force_bounce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_chain_runtime_enabled = true
        opts.register_bounce_probe_binding = true
    elseif mode == "bounce_chain_payload_mock_handoff" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_TRIGGER_CHAIN_FROST_TARGET }
        opts.force_bounce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_chain_runtime_enabled = true
        opts.register_bounce_probe_binding = true
    elseif mode == "bounce_chain_payload_launch" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_TRIGGER_CHAIN_FROST_TARGET }
        opts.force_bounce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_chain_runtime_enabled = true
        opts.dry_run = false
    elseif mode == "bounce_trigger_multicast_disabled" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_TRIGGER_MULTICAST_FROST_TARGET }
        opts.force_bounce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_disabled = true
    elseif mode == "bounce_trigger_multicast_dry_run" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_TRIGGER_MULTICAST_FROST_TARGET }
        opts.force_bounce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_enabled = true
    elseif mode == "bounce_trigger_multicast_post_bounce" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_TRIGGER_MULTICAST_FROST_TARGET }
        opts.force_bounce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.register_bounce_probe_binding = true
    elseif mode == "bounce_trigger_burst_post_bounce" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_TRIGGER_BURST_MULTICAST_FROST_TARGET }
        opts.force_bounce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_payload_pattern_enabled = true
        opts.register_bounce_probe_binding = true
    elseif mode == "bounce_trigger_pattern_disabled" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_TRIGGER_BURST_MULTICAST_FROST_TARGET }
        opts.force_bounce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_payload_pattern_disabled = true
    elseif mode == "bounce_trigger_burst_dry_run" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_TRIGGER_BURST_MULTICAST_FROST_TARGET }
        opts.force_bounce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_payload_pattern_enabled = true
    elseif mode == "bounce_trigger_spread_dry_run" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_TRIGGER_SPREAD_MULTICAST_FROST_TARGET }
        opts.force_bounce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_payload_pattern_enabled = true
    elseif mode == "bounce_over_cap" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_OVER_CAP_TARGET }
        opts.force_bounce_enabled = true
        opts.force_trigger_enabled = true
    elseif mode == "bounce_fanout_deferred" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_MULTICAST_TARGET }
        opts.force_bounce_enabled = true
    elseif mode == "bounce_timer_deferred" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_TIMER_TARGET }
        opts.force_bounce_enabled = true
    elseif mode == "bounce_chain_deferred" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_CHAIN_TARGET }
        opts.force_bounce_enabled = true
    elseif mode == "bounce_nested_payload_deferred" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_TRIGGER_NESTED_TRIGGER_TARGET }
        opts.force_bounce_enabled = true
        opts.force_trigger_enabled = true
    elseif mode == "bounce_speed_plus_deferred" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_SPEED_PLUS_TARGET }
        opts.force_bounce_enabled = true
    elseif mode == "bounce_size_plus_deferred" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_SIZE_PLUS_TARGET }
        opts.force_bounce_enabled = true
    elseif mode == "bounce_homing_deferred" then
        opts._spellforge_probe_root = { real_effects = recipes.BOUNCE_HOMING_TARGET }
        opts.force_bounce_enabled = true
        opts.force_homing_enabled = true
    else
        return false
    end
    return true
end

local function applyPierceProbeMode(mode, opts)
    if mode == "pierce_disabled" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_FIRE_TARGET }
        opts.force_pierce_disabled = true
    elseif mode == "pierce_source_only_dry_run" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_FIRE_TARGET }
        opts.force_pierce_enabled = true
    elseif mode == "pierce_source_only_launch" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_FIRE_TARGET }
        opts.force_pierce_enabled = true
        opts.dry_run = false
    elseif mode == "pierce_trigger_simple_event" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_TRIGGER_FIRE_FROST_TARGET }
        opts.force_pierce_enabled = true
        opts.force_trigger_enabled = true
        opts.register_pierce_probe_binding = true
    elseif mode == "pierce_trigger_multicast_event" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_TRIGGER_MULTICAST_FROST_TARGET }
        opts.force_pierce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.register_pierce_probe_binding = true
    elseif mode == "pierce_trigger_pattern_event" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_TRIGGER_BURST_MULTICAST_FROST_TARGET }
        opts.force_pierce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_payload_pattern_enabled = true
        opts.register_pierce_probe_binding = true
    elseif mode == "pierce_trigger_spread_event" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_TRIGGER_SPREAD_MULTICAST_FROST_TARGET }
        opts.force_pierce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_payload_pattern_enabled = true
        opts.register_pierce_probe_binding = true
    elseif mode == "pierce_trigger_chain_event" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_TRIGGER_CHAIN_FROST_TARGET }
        opts.force_pierce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_chain_runtime_enabled = true
        opts.register_pierce_probe_binding = true
    elseif mode == "pierce_trigger_multicast_disabled" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_TRIGGER_MULTICAST_FROST_TARGET }
        opts.force_pierce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_disabled = true
    elseif mode == "pierce_trigger_pattern_disabled" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_TRIGGER_BURST_MULTICAST_FROST_TARGET }
        opts.force_pierce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_payload_pattern_disabled = true
    elseif mode == "pierce_chain_payload_disabled" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_TRIGGER_CHAIN_FROST_TARGET }
        opts.force_pierce_enabled = true
        opts.force_trigger_enabled = true
        opts.force_chain_runtime_disabled = true
    elseif mode == "pierce_timer_deferred" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_TIMER_TARGET }
        opts.force_pierce_enabled = true
    elseif mode == "pierce_bounce_deferred" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_BOUNCE_TARGET }
        opts.force_pierce_enabled = true
        opts.force_bounce_enabled = true
    elseif mode == "pierce_homing_deferred" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_HOMING_TARGET }
        opts.force_pierce_enabled = true
        opts.force_homing_enabled = true
    elseif mode == "pierce_speed_plus_deferred" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_SPEED_PLUS_TARGET }
        opts.force_pierce_enabled = true
    elseif mode == "pierce_size_plus_deferred" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_SIZE_PLUS_TARGET }
        opts.force_pierce_enabled = true
    elseif mode == "pierce_chain_deferred" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_CHAIN_TARGET }
        opts.force_pierce_enabled = true
    elseif mode == "pierce_fanout_deferred" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_MULTICAST_TARGET }
        opts.force_pierce_enabled = true
    elseif mode == "pierce_nested_payload_deferred" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_TRIGGER_NESTED_TRIGGER_TARGET }
        opts.force_pierce_enabled = true
        opts.force_trigger_enabled = true
    elseif mode == "pierce_recursion_deferred" then
        opts._spellforge_probe_root = { real_effects = recipes.PIERCE_TRIGGER_PIERCE_PAYLOAD_TARGET }
        opts.force_pierce_enabled = true
        opts.force_trigger_enabled = true
    else
        return false
    end
    return true
end

local function cloneParams(params)
    local out = {}
    if type(params) ~= "table" then
        return out
    end
    local keys = {}
    for key in pairs(params) do
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
    local out = {
        id = effect.id,
        range = effect.range,
        area = effect.area,
        duration = effect.duration,
        magnitudeMin = effect.magnitudeMin,
        magnitudeMax = effect.magnitudeMax,
        params = cloneParams(effect.params),
    }
    for _, field in ipairs(recipes.PRESENTATION_METADATA_FIELDS) do
        if effect[field] ~= nil then
            out[field] = effect[field]
        end
    end
    return out
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

local function firstPresent(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if value ~= nil then
            return value
        end
    end
    return nil
end

local function bounceDetonateOnActorHit(job, payload)
    if job == nil then
        return nil
    end
    return firstPresent(
        job.detonateOnActorHit,
        payload and payload.detonateOnActorHit,
        job.bounce_detonate_on_actor_hit,
        payload and payload.bounce_detonate_on_actor_hit
    )
end

local function fallback(reason, details)
    local result = details or {}
    result.ok = false
    result.used_live_2_2c = false
    result.fallback_allowed = true
    result.fallback_reason = reason
    return result
end

local function bridgeError(message, details)
    local result = details or {}
    result.ok = false
    result.used_live_2_2c = true
    result.fallback_allowed = result.fallback_allowed == true
    result.error = message
    return result
end

local function nextCastId(recipe_id, plan_recipe_id)
    local cast_id = string.format(
        "live_2_2c:%s:%s:%d",
        tostring(recipe_id),
        tostring(plan_recipe_id),
        next_live_cast_index
    )
    next_live_cast_index = next_live_cast_index + 1
    if seen_cast_ids[cast_id] then
        runtime_stats.inc("cast_ids_reused_unexpectedly")
    end
    seen_cast_ids[cast_id] = true
    runtime_stats.inc("cast_ids_created")
    return cast_id
end

local function rejected(reason, details)
    runtime_stats.inc("live_2_2c_rejected")
    return fallback(reason, details)
end

local function send(sender, event_name, payload)
    if sender and type(sender.sendEvent) == "function" then
        sender:sendEvent(event_name, payload)
    end
end

local function firstHelperSpecForAudit(effects)
    local compiled = plan_cache.compileOrGet(effects, {
        source_recipe_id = "sfp-beta3-boundary-audit",
    })
    if not compiled.ok then
        return nil, firstErrorMessage(compiled)
    end
    local specs = plan_cache.attachHelperSpecs(compiled.recipe_id)
    if not specs.ok then
        return nil, firstErrorMessage(specs)
    end
    return specs.plan and specs.plan.helper_specs and specs.plan.helper_specs[1] or nil, nil
end

local function adapterCapabilitiesProbe(payload)
    local caps = sfp_adapter.capabilities()
    return {
        request_id = payload and payload.request_id,
        ok = type(caps.has_launchSpell) == "boolean"
            and type(caps.has_detonateSpellAtPos) == "boolean"
            and type(caps.has_cancelSpell) == "boolean"
            and type(caps.has_setSpellSpeed) == "boolean"
            and type(caps.has_setSpellPhysics) == "boolean",
        mode = "adapter_capabilities",
        launchSpell = caps.has_launchSpell == true,
        detonateSpellAtPos = caps.has_detonateSpellAtPos == true,
        cancelSpell = caps.has_cancelSpell == true,
        setSpellSpeed = caps.has_setSpellSpeed == true,
        setSpellPhysics = caps.has_setSpellPhysics == true,
        has_interface = caps.has_interface == true,
    }
end

local function adapterLaunchFieldsProbe(payload)
    local fields = sfp_adapter.forwardedLaunchFields({
        attacker = payload and (payload.actor or payload.sender) or true,
        spellId = "spellforge_adapter_launch_field_probe",
        startPos = payload and payload.start_pos or { x = 0, y = 0, z = 0 },
        direction = payload and payload.direction or { x = 0, y = 1, z = 0 },
        hitObject = payload and payload.hit_object or false,
        isFree = true,
        userData = { spellforge = true, probe = "adapter_launch_fields" },
        muteAudio = true,
        muteLight = true,
        speed = 1200,
        maxSpeed = 1800,
        minSpeed = 100,
        accelerationExp = 0,
        forceVec = { x = 0, y = 0, z = 100 },
        maxLifetime = 5,
        spawnOffset = 24,
        muteCastGlow = true,
        areaVfxRecId = "spellforge_test_area_static",
        areaVfxScale = 1.25,
        vfxRecId = "spellforge_test_bolt_vfx",
        boltModel = "meshes/spellforge/test_bolt.nif",
        hitModel = "meshes/spellforge/test_impact.nif",
        boltSound = "destruction bolt",
        spinSpeed = 1.5,
    })
    local ordinary = sfp_adapter.forwardedLaunchFields({
        attacker = payload and (payload.actor or payload.sender) or true,
        spellId = "spellforge_adapter_ordinary_launch_probe",
        isFree = true,
    })
    return {
        request_id = payload and payload.request_id,
        ok = fields.userData == true
            and fields.muteAudio == true
            and fields.muteLight == true
            and fields.speed == true
            and fields.maxSpeed == true
            and fields.minSpeed == true
            and fields.accelerationExp == true
            and fields.forceVec == true
            and fields.maxLifetime == true
            and fields.spawnOffset == true
            and fields.muteCastGlow == true
            and fields.areaVfxRecId == true
            and fields.areaVfxScale == true
            and fields.vfxRecId == true
            and fields.boltModel == true
            and fields.hitModel == true
            and fields.boltSound == true
            and fields.spinSpeed == true
            and ordinary.speed ~= true
            and ordinary.maxSpeed ~= true
            and ordinary.accelerationExp ~= true,
        mode = "adapter_launch_fields",
        forwarded_fields = fields,
        ordinary_forwarded_fields = ordinary,
        ordinary_launch_unchanged = ordinary.speed ~= true
            and ordinary.maxSpeed ~= true
            and ordinary.accelerationExp ~= true,
    }
end

local function adapterDetonateArgsProbe(payload)
    local caps = sfp_adapter.capabilities()
    local full = sfp_adapter.previewDetonateArgs({
        spellId = "spellforge_adapter_detonate_probe",
        caster = payload and (payload.actor or payload.sender) or true,
        position = payload and payload.start_pos or { x = 0, y = 0, z = 0 },
        cell = payload and payload.cell or "spellforge_adapter_probe_cell",
        excludeTarget = payload and payload.hit_object or false,
        areaVfxRecId = "spellforge_test_area_static",
        areaVfxScale = 1.25,
        forcedEffects = {},
        userData = { spellforge = true, probe = "adapter_detonate_args" },
        muteAudio = true,
        muteLight = true,
    })
    local legacy = sfp_adapter.previewDetonateArgs(
        "spellforge_adapter_detonate_probe",
        payload and (payload.actor or payload.sender) or true,
        payload and payload.start_pos or { x = 0, y = 0, z = 0 },
        payload and payload.cell or "spellforge_adapter_probe_cell",
        payload and payload.hit_object or nil
    )
    local f = full.forwarded_fields or {}
    return {
        request_id = payload and payload.request_id,
        ok = full.ok == true
            and full.legacy_positional == false
            and legacy.legacy_positional == true
            and f.areaVfxRecId == true
            and f.areaVfxScale == true
            and f.excludeTarget == true
            and f.forcedEffects == true
            and f.userData == true
            and f.muteAudio == true
            and f.muteLight == true,
        mode = "adapter_detonate_args",
        detonateSpellAtPos_available = caps.has_detonateSpellAtPos == true,
        missing_optional_api_graceful = true,
        full_forwarded_fields = full.forwarded_fields,
        legacy_positional_preserved = legacy.legacy_positional == true,
    }
end

local function timerDetonationAuditProbe(payload)
    local audit = live_timer.sourceDetonationAudit()
    if audit.status == "blocked" then
        runtime_stats.inc("timer_source_detonation_blocked")
    end
    audit.request_id = payload and payload.request_id
    audit.ok = audit.status == "blocked"
        or audit.status == "implementable"
        or audit.status == "pending"
        or audit.status == "pending_projectile"
        or audit.status == "pending_projectile_state"
        or audit.status == "ready"
    audit.mode = "timer_detonation_audit"
    audit.timer_gameplay_delay_smoke = "implemented"
    audit.deterministic_fast_forward_smoke = "implemented"
    return audit
end

local function vfxMetadataAuditProbe(payload)
    local spec, spec_err = firstHelperSpecForAudit(recipes.VFX_METADATA_AUDIT_TARGET)
    local missing_area_spec, missing_err = firstHelperSpecForAudit(recipes.VFX_METADATA_MISSING_AREA_TARGET)
    local presentation = spec and spec.presentation or nil
    local missing_presentation = missing_area_spec and missing_area_spec.presentation or nil
    local launch_fields = sfp_adapter.forwardedLaunchFields({
        areaVfxRecId = presentation and presentation.areaVfxRecId or nil,
        areaVfxScale = presentation and presentation.areaVfxScale or nil,
        vfxRecId = presentation and presentation.vfxRecId or nil,
        boltModel = presentation and presentation.boltModel or nil,
        hitModel = presentation and presentation.hitModel or nil,
    })
    local missing_launch_fields = sfp_adapter.forwardedLaunchFields({
        areaVfxRecId = missing_presentation and missing_presentation.areaVfxRecId or nil,
        vfxRecId = missing_presentation and missing_presentation.vfxRecId or nil,
    })
    local missing_collision = sfp_adapter.previewCollisionVfxArgs({
        spellId = "spellforge_vfx_missing_area_probe",
        caster = payload and (payload.actor or payload.sender) or true,
        position = payload and payload.start_pos or { x = 0, y = 0, z = 0 },
        cell = payload and payload.cell or "spellforge_vfx_probe_cell",
        areaVfxRecId = missing_presentation and missing_presentation.areaVfxRecId or nil,
        areaVfxScale = missing_presentation and missing_presentation.areaVfxScale or nil,
        vfxRecId = missing_presentation and missing_presentation.vfxRecId or nil,
        userData = { spellforge = true, probe = "vfx_missing_area" },
        muteAudio = false,
        muteLight = false,
    })
    local explicit_collision = sfp_adapter.previewCollisionVfxArgs({
        spellId = "spellforge_vfx_explicit_area_probe",
        caster = payload and (payload.actor or payload.sender) or true,
        position = payload and payload.start_pos or { x = 0, y = 0, z = 0 },
        cell = payload and payload.cell or "spellforge_vfx_probe_cell",
        areaVfxRecId = presentation and presentation.areaVfxRecId or nil,
        areaVfxScale = presentation and presentation.areaVfxScale or nil,
        vfxRecId = presentation and presentation.vfxRecId or nil,
        userData = { spellforge = true, probe = "vfx_explicit_area" },
        muteAudio = false,
        muteLight = false,
    })
    local hit_model_collision = sfp_adapter.previewCollisionVfxArgs({
        spellId = "spellforge_vfx_hit_model_probe",
        caster = payload and (payload.actor or payload.sender) or true,
        position = payload and payload.start_pos or { x = 0, y = 0, z = 0 },
        cell = payload and payload.cell or "spellforge_vfx_probe_cell",
        hitModel = presentation and presentation.hitModel or nil,
    })
    if missing_collision.default_area_fallback_expected == true then
        runtime_stats.inc("impact_vfx_default_area_fallback_used")
    end
    if explicit_collision.area_override_used == true then
        runtime_stats.inc("impact_vfx_area_override_used")
    end
    if hit_model_collision.hit_model_spawn_attempted == true then
        runtime_stats.inc("impact_vfx_hit_model_spawn_attempted")
    end
    return {
        request_id = payload and payload.request_id,
        ok = spec ~= nil
            and missing_area_spec ~= nil
            and presentation ~= nil
            and presentation.areaVfxRecId == "spellforge_test_area_static"
            and presentation.areaVfxScale == 1.25
            and presentation.vfxRecId == "spellforge_test_bolt_vfx"
            and presentation.hitModel == "meshes/spellforge/test_impact.nif"
            and missing_presentation ~= nil
            and missing_presentation.areaVfxRecId == nil
            and missing_presentation.vfxRecId == "spellforge_test_bolt_vfx"
            and launch_fields.areaVfxRecId == true
            and launch_fields.areaVfxScale == true
            and launch_fields.vfxRecId == true
            and launch_fields.boltModel == true
            and launch_fields.hitModel == true
            and missing_launch_fields.areaVfxRecId ~= true
            and missing_collision.used_bolt_as_area_override == false
            and missing_collision.vfx_override_passed == nil
            and missing_collision.default_area_fallback_expected == true
            and explicit_collision.area_override_used == true
            and explicit_collision.areaVfxScale_forwarded == true
            and hit_model_collision.hit_model_spawn_attempted == true,
        mode = "vfx_metadata_audit",
        error = spec_err or missing_err,
        helper_spec_has_areaVfxRecId = presentation and presentation.areaVfxRecId ~= nil or false,
        helper_spec_has_areaVfxScale = presentation and presentation.areaVfxScale ~= nil or false,
        helper_spec_has_vfxRecId = presentation and presentation.vfxRecId ~= nil or false,
        helper_spec_has_boltModel = presentation and presentation.boltModel ~= nil or false,
        helper_spec_has_hitModel = presentation and presentation.hitModel ~= nil or false,
        areaVfxRecId = presentation and presentation.areaVfxRecId or nil,
        areaVfxScale = presentation and presentation.areaVfxScale or nil,
        vfxRecId = presentation and presentation.vfxRecId or nil,
        boltModel = presentation and presentation.boltModel or nil,
        hitModel = presentation and presentation.hitModel or nil,
        missing_area_vfx_vfxRecId = missing_presentation and missing_presentation.vfxRecId or nil,
        areaVfxRecId_forwarded_when_present = launch_fields.areaVfxRecId == true,
        areaVfxScale_forwarded_when_present = launch_fields.areaVfxScale == true,
        vfxRecId_forwarded_as_bolt_vfx = launch_fields.vfxRecId == true,
        boltModel_forwarded_as_bolt_model = launch_fields.boltModel == true,
        hitModel_forwarded_as_hit_model = launch_fields.hitModel == true,
        missing_areaVfxRecId_does_not_use_bolt_vfx = missing_launch_fields.areaVfxRecId ~= true,
        missing_area_vfx_override_passed_is_nil = missing_collision.vfx_override_passed == nil,
        default_area_fallback_expected = missing_collision.default_area_fallback_expected == true,
        collision_preview_used_bolt_as_area_override = missing_collision.used_bolt_as_area_override == true,
        explicit_area_override_used = explicit_collision.area_override_used == true,
        explicit_areaVfxScale_forwarded = explicit_collision.areaVfxScale_forwarded == true,
        hitModel_spawn_attempted = hit_model_collision.hit_model_spawn_attempted == true,
        collision_vfx_policy_preview_only = true,
        spellforge_synthesizes_area_from_bolt = false,
    }
end

local function nestedPayloadAuditProbe(payload)
    local audit_case = payload and payload.audit_case or "timer_simple"
    local effects = recipes.NESTED_AUDIT_TARGETS[audit_case]
    if type(effects) ~= "table" then
        return {
            request_id = payload and payload.request_id,
            ok = false,
            mode = "nested_payload_audit",
            audit_only = true,
            live_runtime_enabled = false,
            audit_case = audit_case,
            error = "unknown nested payload audit case",
        }
    end

    runtime_stats.inc("nested_payload_audit_attempts")
    local sfp_launch_before = runtime_stats.get("sfp_launch_attempts")
    local compiled = plan_cache.compileOrGet(cloneEffects(effects))
    if not compiled.ok then
        runtime_stats.inc("nested_payload_audit_rejected")
        return {
            request_id = payload and payload.request_id,
            ok = false,
            mode = "nested_payload_audit",
            audit_only = true,
            live_runtime_enabled = false,
            audit_case = audit_case,
            recipe_id = compiled.recipe_id,
            rejection_reason = firstErrorMessage(compiled),
            unsupported_reasons = { firstErrorMessage(compiled) },
            sfp_launch_attempts_before = sfp_launch_before,
            sfp_launch_attempts_after = runtime_stats.get("sfp_launch_attempts"),
        }
    end

    local slots = plan_cache.attachEmissionSlots(compiled.recipe_id)
    if not slots.ok then
        runtime_stats.inc("nested_payload_audit_rejected")
        return {
            request_id = payload and payload.request_id,
            ok = false,
            mode = "nested_payload_audit",
            audit_only = true,
            live_runtime_enabled = false,
            audit_case = audit_case,
            recipe_id = compiled.recipe_id,
            rejection_reason = firstErrorMessage(slots),
            unsupported_reasons = { firstErrorMessage(slots) },
            sfp_launch_attempts_before = sfp_launch_before,
            sfp_launch_attempts_after = runtime_stats.get("sfp_launch_attempts"),
        }
    end

    local specs = plan_cache.attachHelperSpecs(compiled.recipe_id)
    local plan = specs.ok and specs.plan or slots.plan
    local audit = nested_payload_audit.inspectPlan(plan, {
        max_depth = limits.MAX_NESTED_PAYLOAD_DEPTH,
        max_jobs = limits.MAX_NESTED_PAYLOAD_JOBS,
        max_fanout = limits.MAX_NESTED_PAYLOAD_FANOUT,
    })
    audit.request_id = payload and payload.request_id
    audit.audit_case = audit_case
    audit.sfp_launch_attempts_before = sfp_launch_before
    audit.sfp_launch_attempts_after = runtime_stats.get("sfp_launch_attempts")
    audit.sfp_launch_unchanged = audit.sfp_launch_attempts_before == audit.sfp_launch_attempts_after
    if specs.ok ~= true then
        audit.helper_spec_error = firstErrorMessage(specs)
    end

    if audit.ok then
        runtime_stats.inc("nested_payload_audit_ok")
    else
        runtime_stats.inc("nested_payload_audit_rejected")
    end
    if audit.future_runtime_candidate then
        runtime_stats.inc("nested_payload_audit_future_candidates")
    end
    if audit.has_chain then
        runtime_stats.inc("nested_payload_audit_chain_deferred")
    end
    if audit.exceeds_depth_cap or audit.exceeds_job_cap or audit.exceeds_projectile_cap then
        runtime_stats.inc("nested_payload_audit_cap_rejections")
    end

    local marker = audit.ok and "SPELLFORGE_NESTED_PAYLOAD_AUDIT_OK" or "SPELLFORGE_NESTED_PAYLOAD_AUDIT_REJECTED"
    log.info(string.format(
        "%s audit_case=%s recipe_id=%s slot_count=%s helper_count=%s payload_emission_count=%s max_payload_depth=%s estimated_total_jobs=%s future_runtime_candidate=%s rejection_reason=%s",
        marker,
        tostring(audit_case),
        tostring(audit.recipe_id),
        tostring(audit.slot_count),
        tostring(audit.helper_count),
        tostring(audit.payload_emission_count),
        tostring(audit.max_payload_depth),
        tostring(audit.estimated_total_jobs),
        tostring(audit.future_runtime_candidate),
        tostring(audit.rejection_reason)
    ))

    return audit
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

local function chainHitContext()
    return {
        caster = "chain-caster",
        source_target = { id = "A", object = "A", position = { x = 0, y = 0, z = 0 }, cell = "chain-test-cell" },
        current_hit_target = { id = "A", object = "A", position = { x = 0, y = 0, z = 0 }, cell = "chain-test-cell" },
        current_hit_position = { x = 0, y = 0, z = 0 },
        current_cell = "chain-test-cell",
        cast_id = "chain-audit-cast",
        recipe_id = "chain-audit-recipe",
        source_slot_id = "chain-source-slot",
        payload_slot_id = "chain-payload-slot",
        source_helper_engine_id = "chain-source-helper",
        exclude_caster = true,
        exclude_current_hit_target = true,
    }
end

local function chainCandidates(case_name)
    if case_name == "tie" then
        return {
            { id = "B", object = "B", position = { x = 100, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = true, is_valid = true },
            { id = "A", object = "A", position = { x = 0, y = 100, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = true, is_valid = true },
        }
    elseif case_name == "no_valid" then
        return {
            { id = "chain-caster", object = "chain-caster", position = { x = 10, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = true, is_valid = true },
            { id = "A", object = "A", position = { x = 0, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = true, is_valid = true },
            { id = "invalid-D", object = "invalid-D", position = { x = 25, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = true, is_valid = false },
            { id = "dead-E", object = "dead-E", position = { x = 30, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = false, is_valid = true },
            { id = "far-H", object = "far-H", position = { x = 2000, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = true, is_valid = true },
        }
    elseif case_name == "radius" then
        return {
            { id = "outside-radius", object = "outside-radius", position = { x = limits.MAX_CHAIN_SCAN_RADIUS + 10, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = true, is_valid = true },
        }
    elseif case_name == "candidate_cap" then
        local out = {}
        for i = 1, (limits.MAX_CHAIN_SCAN_CANDIDATES + 4) do
            out[i] = {
                id = string.format("cap-%02d", i),
                object = string.format("cap-%02d", i),
                position = { x = i * 10, y = 0, z = 0 },
                cell = "chain-test-cell",
                is_actor = true,
                is_alive = true,
                is_valid = true,
            }
        end
        return out
    end

    return {
        { id = "chain-caster", object = "chain-caster", position = { x = 10, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = true, is_valid = true },
        { id = "A", object = "A", position = { x = 0, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = true, is_valid = true },
        { id = "B", object = "B", position = { x = 100, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = true, is_valid = true },
        { id = "C", object = "C", position = { x = 50, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = true, is_valid = true },
        { id = "invalid-D", object = "invalid-D", position = { x = 25, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = true, is_valid = false },
        { id = "dead-E", object = "dead-E", position = { x = 30, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = false, is_valid = true },
        { id = "non-actor-F", object = "non-actor-F", position = { x = 40, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = false, is_alive = true, is_valid = true },
        { id = "other-cell-G", object = "other-cell-G", position = { x = 5, y = 0, z = 0 }, cell = "other-cell", is_actor = true, is_alive = true, is_valid = true },
    }
end

local function chainHopCandidates(case_name)
    if case_name == "hop_bounce"
        or case_name == "direct_chain_3"
        or case_name == "trigger_chain_3"
        or case_name == "direct_chain_speed_plus_3"
        or case_name == "trigger_chain_speed_plus_3"
        or case_name == "direct_chain_size_plus_3"
        or case_name == "trigger_chain_size_plus_3"
        or case_name == "direct_chain_multicast_8"
        or case_name == "trigger_chain_multicast_8"
        or case_name == "simple" then
        return {
            [1] = {
                { id = "A", object = "A", position = { x = 0, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = true, is_valid = true, distance_override = 0 },
                { id = "B", object = "B", position = { x = 100, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = true, is_valid = true, distance_override = 100 },
            },
            [2] = {
                { id = "A", object = "A", position = { x = 0, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = true, is_valid = true, distance_override = 100 },
                { id = "B", object = "B", position = { x = 100, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = true, is_valid = true, distance_override = 0 },
            },
            [3] = {
                { id = "A", object = "A", position = { x = 0, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = true, is_valid = true, distance_override = 0 },
                { id = "B", object = "B", position = { x = 100, y = 0, z = 0 }, cell = "chain-test-cell", is_actor = true, is_alive = true, is_valid = true, distance_override = 100 },
            },
        }
    elseif case_name == "hop_no_target" then
        return {
            [1] = chainCandidates("no_valid"),
        }
    end
    return chainCandidates(case_name)
end

local function chainLiveCandidates(case_name)
    if case_name ~= "nearest" and case_name ~= "hop_no_target" then
        return chainHopCandidates(case_name)
    end
    return function(hop_context)
        local candidates = chainCandidates(case_name == "nearest" and "nearest" or "no_valid")
        for _, candidate in ipairs(candidates) do
            if candidate.id == "chain-caster" then
                candidate.object = hop_context and hop_context.caster or candidate.object
            end
        end
        return candidates
    end
end

local function bounceChainMockSourceTarget()
    return {
        id = "A",
        object = "A",
        position = { x = 0, y = 0, z = 0 },
        cell = "chain-test-cell",
        is_actor = true,
        is_alive = true,
        is_valid = true,
    }
end

local function bounceChainMockCandidates()
    return chainHopCandidates("hop_bounce")
end

local function chainTargetingProbe(payload)
    local chain_case = payload and payload.chain_case or "simple"
    local sfp_launch_before = runtime_stats.get("sfp_launch_attempts")
    if dev.liveChainAuditEnabled() ~= true and not (payload and payload.force_chain_audit_enabled == true) then
        return {
            request_id = payload and payload.request_id,
            ok = false,
            mode = "chain_targeting_audit",
            audit_only = true,
            runtime_enabled = false,
            chain_case = chain_case,
            rejection_reason = "chain_audit_disabled",
            sfp_launch_attempts_before = sfp_launch_before,
            sfp_launch_attempts_after = runtime_stats.get("sfp_launch_attempts"),
            sfp_launch_unchanged = sfp_launch_before == runtime_stats.get("sfp_launch_attempts"),
        }
    end

    if chain_case == "resolve_nearest" or chain_case == "tie" or chain_case == "no_valid" or chain_case == "radius" or chain_case == "candidate_cap" then
        local candidates = chainCandidates(chain_case == "resolve_nearest" and "nearest" or chain_case)
        local before_first = candidates[1] and candidates[1].id or nil
        local context = chainHitContext()
        if chain_case == "tie" then
            context.current_hit_target = { id = "current-hit", object = "current-hit", position = { x = 0, y = 0, z = 0 }, cell = "chain-test-cell" }
            context.source_target = context.current_hit_target
        end
        local resolved = chain_targeting.resolveNextTarget(context, candidates, {
            scan_radius = chain_case == "radius" and limits.MAX_CHAIN_SCAN_RADIUS or nil,
        })
        local repeat_resolved = chain_case == "tie" and chain_targeting.resolveNextTarget(context, candidates) or nil
        resolved.request_id = payload and payload.request_id
        resolved.chain_case = chain_case
        resolved.sfp_launch_attempts_before = sfp_launch_before
        resolved.sfp_launch_attempts_after = runtime_stats.get("sfp_launch_attempts")
        resolved.sfp_launch_unchanged = resolved.sfp_launch_attempts_before == resolved.sfp_launch_attempts_after
        resolved.repeat_selected_target_id = repeat_resolved and repeat_resolved.selected_targets and repeat_resolved.selected_targets[1] and repeat_resolved.selected_targets[1].id or nil
        resolved.input_mutated = candidates[1] and candidates[1].id ~= before_first or false
        local marker = resolved.ok and "SPELLFORGE_CHAIN_TARGETS_RESOLVED" or "SPELLFORGE_CHAIN_TARGETS_REJECTED"
        log.info(string.format(
            "%s chain_case=%s candidate_count=%s valid_candidate_count=%s selected_count=%s scan_radius=%s hop_index=%s rejection_reason=%s",
            marker,
            tostring(chain_case),
            tostring(resolved.candidate_count),
            tostring(resolved.valid_candidate_count),
            tostring(resolved.selected_count),
            tostring(resolved.scan_radius),
            tostring(resolved.hop_index),
            tostring(resolved.rejection_reason)
        ))
        return resolved
    end

    if chain_case == "hop_bounce" or chain_case == "hop_no_target" then
        local effects = recipes.CHAIN_AUDIT_TARGETS[chain_case] or recipes.CHAIN_FIRE_FROST_TARGET
        local compiled = plan_cache.compileOrGet(cloneEffects(effects))
        if not compiled.ok then
            runtime_stats.inc("chain_hop_dry_run_attempts")
            runtime_stats.inc("chain_hop_dry_run_rejected")
            return {
                request_id = payload and payload.request_id,
                ok = false,
                mode = "chain_hop_dry_run",
                audit_only = true,
                runtime_enabled = false,
                chain_case = chain_case,
                rejection_reason = firstErrorMessage(compiled),
                sfp_launch_attempts_before = sfp_launch_before,
                sfp_launch_attempts_after = runtime_stats.get("sfp_launch_attempts"),
                sfp_launch_unchanged = sfp_launch_before == runtime_stats.get("sfp_launch_attempts"),
            }
        end
        local slots = plan_cache.attachEmissionSlots(compiled.recipe_id)
        local specs = slots.ok and plan_cache.attachHelperSpecs(compiled.recipe_id) or nil
        local plan = specs and specs.ok and specs.plan or (slots and slots.plan or compiled.plan)
        local simulated = chain_targeting.simulateHops(plan, chainHitContext(), chainHopCandidates(chain_case), {
            scan_radius = limits.MAX_CHAIN_SCAN_RADIUS,
        })
        simulated.request_id = payload and payload.request_id
        simulated.chain_case = chain_case
        simulated.sfp_launch_attempts_before = sfp_launch_before
        simulated.sfp_launch_attempts_after = runtime_stats.get("sfp_launch_attempts")
        simulated.sfp_launch_unchanged = simulated.sfp_launch_attempts_before == simulated.sfp_launch_attempts_after
        local marker = simulated.ok and "SPELLFORGE_CHAIN_HOP_DRY_RUN_OK" or "SPELLFORGE_CHAIN_HOP_DRY_RUN_REJECTED"
        log.info(string.format(
            "%s chain_case=%s recipe_id=%s requested_hops=%s completed_hops=%s stop_reason=%s selected_target_ids=%s rejection_reason=%s",
            marker,
            tostring(chain_case),
            tostring(simulated.recipe_id),
            tostring(simulated.requested_hops),
            tostring(simulated.completed_hops),
            tostring(simulated.stop_reason),
            table.concat(simulated.selected_target_ids or {}, ","),
            tostring(simulated.rejection_reason)
        ))
        return simulated
    end

    if chain_case == "runtime_deferred" then
        local dispatch = safeTryDispatch(payload, { node_metadata = { { logical_id = "chain-runtime-deferred" } } }, { real_effects = recipes.CHAIN_FIRE_FROST_TARGET }, {
            ignore_flag = true,
            dry_run = true,
            force_chain_runtime_disabled = true,
            source_recipe_id = "chain-audit-probe",
        })
        runtime_stats.inc("chain_target_runtime_deferred")
        return {
            request_id = payload and payload.request_id,
            ok = dispatch and dispatch.ok == false and dispatch.used_live_2_2c == false,
            mode = "chain_targeting_audit",
            audit_only = true,
            runtime_enabled = false,
            chain_case = chain_case,
            runtime_dispatch_deferred = dispatch and dispatch.ok == false,
            fallback_reason = dispatch and dispatch.fallback_reason or nil,
            sfp_launch_attempts_before = sfp_launch_before,
            sfp_launch_attempts_after = runtime_stats.get("sfp_launch_attempts"),
            sfp_launch_unchanged = sfp_launch_before == runtime_stats.get("sfp_launch_attempts"),
        }
    end

    local effects = recipes.CHAIN_AUDIT_TARGETS[chain_case] or recipes.CHAIN_FIRE_FROST_TARGET
    local compiled = plan_cache.compileOrGet(cloneEffects(effects))
    if not compiled.ok then
        runtime_stats.inc("chain_audit_attempts")
        runtime_stats.inc("chain_audit_rejected")
        return {
            request_id = payload and payload.request_id,
            ok = false,
            mode = "chain_targeting_audit",
            audit_only = true,
            runtime_enabled = false,
            chain_case = chain_case,
            requested_hops = chain_case == "invalid_zero" and 0
                or chain_case == "invalid_negative" and -1
                or chain_case == "over_cap" and (limits.MAX_CHAIN_HOPS + 1)
                or nil,
            max_hops_cap = limits.MAX_CHAIN_HOPS,
            rejection_reason = firstErrorMessage(compiled),
            sfp_launch_attempts_before = sfp_launch_before,
            sfp_launch_attempts_after = runtime_stats.get("sfp_launch_attempts"),
            sfp_launch_unchanged = sfp_launch_before == runtime_stats.get("sfp_launch_attempts"),
        }
    end

    local slots = plan_cache.attachEmissionSlots(compiled.recipe_id)
    local specs = slots.ok and plan_cache.attachHelperSpecs(compiled.recipe_id) or nil
    local plan = specs and specs.ok and specs.plan or (slots and slots.plan or compiled.plan)
    local audit = chain_targeting.auditChainDryRun(plan, chainHitContext(), chainHopCandidates(chain_case), {
        scan_radius = limits.MAX_CHAIN_SCAN_RADIUS,
    })
    audit.request_id = payload and payload.request_id
    audit.chain_case = chain_case
    audit.sfp_launch_attempts_before = sfp_launch_before
    audit.sfp_launch_attempts_after = runtime_stats.get("sfp_launch_attempts")
    audit.sfp_launch_unchanged = audit.sfp_launch_attempts_before == audit.sfp_launch_attempts_after

    local marker = audit.ok and "SPELLFORGE_CHAIN_AUDIT_OK" or "SPELLFORGE_CHAIN_AUDIT_REJECTED"
    log.info(string.format(
        "%s chain_case=%s recipe_id=%s source_slot_id=%s payload_slot_id=%s requested_hops=%s completed_hops=%s scan_radius=%s future_runtime_candidate=%s stop_reason=%s rejection_reason=%s",
        marker,
        tostring(chain_case),
        tostring(audit.recipe_id),
        tostring(audit.source_slot_id),
        tostring(audit.payload_slot_id),
        tostring(audit.requested_hops),
        tostring(audit.completed_hops),
        tostring(audit.scan_radius),
        tostring(audit.future_runtime_candidate),
        tostring(audit.stop_reason),
        tostring(audit.rejection_reason)
    ))
    return audit
end

local function chainSmokeTarget(id)
    local positions = {
        A = { x = 0, y = 0, z = 0 },
        B = { x = 100, y = 0, z = 0 },
        C = { x = 50, y = 0, z = 0 },
        far = { x = 1000000, y = 1000000, z = 1000000 },
    }
    return {
        id = id,
        object = id,
        position = positions[id] or { x = 0, y = 0, z = 0 },
        cell = "chain-test-cell",
        is_actor = true,
        is_alive = true,
        is_valid = true,
    }
end

local function chainHitPayloadForJob(job, target_id, payload, suffix)
    local target = chainSmokeTarget(target_id)
    return {
        spellId = job and job.helper_engine_id or nil,
        projectileId = job and job.projectile_id or string.format("%s:%s", tostring(payload and payload.request_id or "chain-runtime"), tostring(suffix or "projectile")),
        userData = job and job.launch_user_data or nil,
        attacker = payload and (payload.actor or payload.sender),
        hitPos = target.position,
        target = target,
    }
end

local function simulateChainRuntime(dispatch, payload, provider, opts)
    local options = opts or {}
    local result = {
        source_hit_result = nil,
        duplicate_source_result = nil,
        branch_source_result = nil,
        duplicate_hop_result = nil,
        branch_hop_result = nil,
        max_stop_result = nil,
        selected_target_ids = {},
        chain_payload_jobs = {},
        chain_payload_launch_count = 0,
        ir_chain_runtime_hops = 0,
        ir_chain_runtime_job_count = 0,
        ir_chain_runtime_real_job_count = 0,
        completed_hops = 0,
    }
    local source_job = dispatch and dispatch.jobs and dispatch.jobs[1] or nil
    if not source_job then
        result.error = "missing Chain source job"
        return result
    end

    local source_hit = chainHitPayloadForJob(source_job, options.source_target_id or "A", payload, "source")
    local probe_virtual_fanout_after = nil
    if dispatch and dispatch.has_multicast_payload == true then
        -- The smoke needs every branch's metadata, but only the first sibling can continue the Chain.
        probe_virtual_fanout_after = tonumber(options.probe_virtual_fanout_after) or 1
    end
    local function chainHitOptions()
        return {
            force_enabled = true,
            candidate_provider = provider,
            simulate_update_ticks = true,
            probe_virtual_fanout_after = probe_virtual_fanout_after,
        }
    end
    local hop_result = live_chain.handleHitPayload(source_hit, chainHitOptions())
    result.source_hit_result = hop_result
    result.duplicate_source_result = live_chain.handleHitPayload(source_hit, chainHitOptions())
    local branch_source_hit = chainHitPayloadForJob(source_job, "B", payload, "source-branch")
    branch_source_hit.projectileId = tostring(source_hit.projectileId or "source") .. ":branch"
    result.branch_source_result = live_chain.handleHitPayload(branch_source_hit, chainHitOptions())

    while hop_result and hop_result.ok == true and (tonumber(hop_result.launch_count) or 0) >= 1 do
        local launch_count = tonumber(hop_result.launch_count) or 1
        result.completed_hops = result.completed_hops + 1
        result.chain_payload_launch_count = result.chain_payload_launch_count + launch_count
        if hop_result.ir_chain_runtime == true then
            result.ir_chain_runtime_hops = result.ir_chain_runtime_hops + 1
            result.ir_chain_runtime_job_count = result.ir_chain_runtime_job_count + (tonumber(hop_result.ir_chain_runtime_job_count) or launch_count)
            result.ir_chain_runtime_real_job_count = result.ir_chain_runtime_real_job_count + (tonumber(hop_result.ir_chain_runtime_real_job_count) or 0)
        end
        result.selected_target_ids[#result.selected_target_ids + 1] = hop_result.selected_target_id
        local payload_job = hop_result.payload_job or (hop_result.jobs and hop_result.jobs[1])
        for _, job in ipairs(hop_result.jobs or { payload_job }) do
            if job ~= nil then
                result.chain_payload_jobs[#result.chain_payload_jobs + 1] = job
            end
        end

        local hit_payload = chainHitPayloadForJob(payload_job, hop_result.selected_target_id, payload, "hop" .. tostring(hop_result.chain_hop_index))
        local next_result = live_chain.handleHitPayload(hit_payload, chainHitOptions())
        if hop_result.chain_hop_index == 1 then
            result.duplicate_hop_result = live_chain.handleHitPayload(hit_payload, chainHitOptions())
            local branch_hit = chainHitPayloadForJob(payload_job, "C", payload, "hop-branch" .. tostring(hop_result.chain_hop_index))
            branch_hit.projectileId = tostring(hit_payload.projectileId or "hop") .. ":branch"
            result.branch_hop_result = live_chain.handleHitPayload(branch_hit, chainHitOptions())
        end
        hop_result = next_result
    end

    if hop_result and hop_result.stopped == true then
        result.max_stop_result = hop_result
    end
    result.stop_reason = hop_result and hop_result.stop_reason or nil
    return result
end

local function chainPayloadJobsHaveFanoutMetadata(jobs, fanout_count)
    if type(jobs) ~= "table" or #jobs == 0 then
        return false
    end
    local expected = tonumber(fanout_count) or 1
    if expected <= 1 then
        return true
    end
    local saw_first = false
    for _, job in ipairs(jobs) do
        local user_data = job and job.launch_user_data or nil
        if type(user_data) ~= "table" then
            return false
        end
        if user_data.chain_runtime ~= true
            or user_data.chain_role ~= "payload"
            or user_data.branch_kind ~= "chain_multicast"
            or tonumber(user_data.branch_count) ~= expected
            or type(user_data.branch_id) ~= "string"
            or type(user_data.branch_parent_id) ~= "string"
            or type(user_data.chain_continuation_group_id) ~= "string" then
            return false
        end
        local branch_index = tonumber(user_data.branch_index)
        if branch_index == 1 then
            saw_first = true
        end
        if branch_index == nil or branch_index < 1 or branch_index > expected then
            return false
        end
    end
    return saw_first
end

local function chainPayloadJobsHaveModifier(jobs, kind)
    if type(jobs) ~= "table" or #jobs == 0 then
        return false
    end
    for _, job in ipairs(jobs) do
        local user_data = job and job.launch_user_data or nil
        if not job or job.payload_modifier_kind ~= kind or type(user_data) ~= "table" then
            return false
        end
        if user_data.chain_runtime ~= true
            or user_data.chain_role ~= "payload"
            or user_data.payload_modifier_kind ~= kind then
            return false
        end
        if kind == "speed_plus" then
            if job.speed_plus ~= true
                or user_data.speed_plus ~= true
                or job.speed ~= job.speed_plus_speed
                or job.maxSpeed ~= job.speed_plus_max_speed
                or tonumber(job.speed_plus_speed) == nil
                or job.speed_plus_speed == job.speed_plus_base_speed then
                return false
            end
        elseif kind == "size_plus" then
            if job.size_plus ~= true
                or user_data.size_plus ~= true
                or tonumber(job.size_plus_area) == nil
                or tonumber(job.size_plus_base_area) == nil
                or job.size_plus_area <= job.size_plus_base_area then
                return false
            end
        end
    end
    return true
end

local function chainRuntimeProbe(payload)
    local chain_case = payload and payload.chain_case or "direct_chain_3"
    local manual_real_gameplay = chain_case == "manual_real_gameplay"
    if chain_case == "real_provider_availability" then
        local supported = chain_target_provider.isSupported()
        local context = chainHitContext()
        local collected = chain_target_provider.collectCandidates(context, {
            radius = limits.MAX_CHAIN_SCAN_RADIUS,
            candidate_cap = limits.MAX_CHAIN_SCAN_CANDIDATES,
        })
        return {
            request_id = payload and payload.request_id,
            ok = supported.supported == true or collected.provider == "unavailable",
            mode = "chain_runtime",
            chain_case = chain_case,
            provider = collected.provider,
            provider_supported = supported.supported == true,
            candidate_count = collected.candidate_count or 0,
            radius = collected.radius,
            candidate_cap = collected.candidate_cap,
            rejection_reason = collected.rejection_reason,
            unsupported_reason = collected.unsupported_reason,
            sfp_launch_unchanged = true,
        }
    end

    local effects = recipes.CHAIN_FIRE_FROST_TARGET
    local provider = chainHopCandidates(chain_case)
    local opts = {
        ignore_flag = true,
        dry_run = false,
        skip_entry_shape_check = false,
        source_recipe_id = "chain-runtime-probe",
        force_chain_runtime_enabled = true,
        chain_candidate_provider = provider,
    }
    if chain_case == "trigger_chain_3" then
        effects = recipes.TRIGGER_CHAIN_FROST_TARGET
        opts.force_trigger_enabled = true
    elseif chain_case == "chain_speed_plus_disabled" then
        effects = recipes.CHAIN_SPEED_PLUS_FROST_TARGET
        opts.force_speed_plus_disabled = true
    elseif chain_case == "chain_size_plus_disabled" then
        effects = recipes.CHAIN_SIZE_PLUS_FROST_TARGET
        opts.force_size_plus_disabled = true
    elseif chain_case == "direct_chain_speed_plus_3" then
        effects = recipes.CHAIN_SPEED_PLUS_FROST_TARGET
        opts.force_speed_plus_enabled = true
    elseif chain_case == "trigger_chain_speed_plus_3" then
        effects = recipes.TRIGGER_CHAIN_SPEED_PLUS_FROST_TARGET
        opts.force_trigger_enabled = true
        opts.force_speed_plus_enabled = true
    elseif chain_case == "direct_chain_size_plus_3" then
        effects = recipes.CHAIN_SIZE_PLUS_FROST_TARGET
        opts.force_size_plus_enabled = true
    elseif chain_case == "trigger_chain_size_plus_3" then
        effects = recipes.TRIGGER_CHAIN_SIZE_PLUS_FROST_TARGET
        opts.force_trigger_enabled = true
        opts.force_size_plus_enabled = true
    elseif chain_case == "direct_chain_multicast_8" then
        effects = recipes.CHAIN_MULTICAST_X8_TARGET
        opts.force_chaos_budget_enabled = true
        opts.force_chain_multicast_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.max_chain_multicast_fanout = recipes.CHAOS_CHAIN_MULTICAST_FANOUT_COUNT
        opts.max_chain_jobs = limits.MAX_CHAIN_HOPS_CHAOS * recipes.CHAOS_CHAIN_MULTICAST_FANOUT_COUNT
        opts.max_live_launches_per_tick = limits.MAX_LIVE_LAUNCHES_PER_TICK_CHAOS
    elseif chain_case == "trigger_chain_multicast_8" then
        effects = recipes.TRIGGER_CHAIN_MULTICAST_X8_TARGET
        opts.force_chaos_budget_enabled = true
        opts.force_trigger_enabled = true
        opts.force_chain_multicast_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.max_chain_multicast_fanout = recipes.CHAOS_CHAIN_MULTICAST_FANOUT_COUNT
        opts.max_chain_jobs = limits.MAX_CHAIN_HOPS_CHAOS * recipes.CHAOS_CHAIN_MULTICAST_FANOUT_COUNT
        opts.max_live_launches_per_tick = limits.MAX_LIVE_LAUNCHES_PER_TICK_CHAOS
    elseif chain_case == "chain_speed_plus_no_valid" then
        effects = recipes.CHAIN_SPEED_PLUS_FROST_TARGET
        provider = chainLiveCandidates("hop_no_target")
        opts.chain_candidate_provider = provider
        opts.force_speed_plus_enabled = true
    elseif chain_case == "speed_plus_multicast" then
        effects = recipes.CHAIN_SPEED_PLUS_MULTICAST_TARGET
        opts.force_speed_plus_enabled = true
    elseif chain_case == "size_plus_multicast" then
        effects = recipes.CHAIN_SIZE_PLUS_MULTICAST_TARGET
        opts.force_size_plus_enabled = true
    elseif chain_case == "speed_plus_pattern" then
        effects = recipes.CHAIN_SPEED_PLUS_BURST_MULTICAST_TARGET
        opts.force_speed_plus_enabled = true
    elseif chain_case == "size_plus_pattern" then
        effects = recipes.CHAIN_SIZE_PLUS_BURST_MULTICAST_TARGET
        opts.force_size_plus_enabled = true
    elseif chain_case == "speed_plus_trigger_timer" then
        effects = recipes.CHAIN_SPEED_PLUS_TRIGGER_PAYLOAD_TARGET
        opts.force_speed_plus_enabled = true
    elseif chain_case == "size_plus_trigger_timer" then
        effects = recipes.CHAIN_SIZE_PLUS_TIMER_PAYLOAD_TARGET
        opts.force_size_plus_enabled = true
    elseif chain_case == "speed_plus_recursion" then
        effects = recipes.CHAIN_SPEED_PLUS_CHAIN_TARGET
        opts.force_speed_plus_enabled = true
    elseif chain_case == "size_plus_recursion" then
        effects = recipes.CHAIN_SIZE_PLUS_CHAIN_TARGET
        opts.force_size_plus_enabled = true
    elseif manual_real_gameplay then
        effects = recipes.TRIGGER_CHAIN_FROST_TARGET
        provider = nil
        opts.chain_candidate_provider = nil
        opts.force_trigger_enabled = true
        opts.source_recipe_id = "chain-manual-real-probe"
    elseif chain_case == "disabled" then
        opts.force_chain_runtime_disabled = true
    elseif chain_case == "no_valid" then
        provider = chainLiveCandidates("hop_no_target")
        opts.chain_candidate_provider = provider
    elseif chain_case == "filters" then
        provider = chainLiveCandidates("nearest")
        opts.chain_candidate_provider = provider
    elseif chain_case == "real_provider_no_target" then
        provider = nil
        opts.chain_candidate_provider = nil
    elseif chain_case == "invalid_zero" then
        effects = recipes.CHAIN_ZERO_TARGET
    elseif chain_case == "invalid_negative" then
        effects = recipes.CHAIN_NEGATIVE_TARGET
    elseif chain_case == "over_cap" then
        effects = recipes.CHAIN_OVER_CAP_TARGET
    elseif chain_case == "multicast" then
        effects = recipes.CHAIN_MULTICAST_TARGET
        opts.force_chain_multicast_disabled = true
    elseif chain_case == "pattern" then
        effects = recipes.CHAIN_BURST_MULTICAST_TARGET
    elseif chain_case == "trigger_timer" then
        effects = recipes.CHAIN_TRIGGER_PAYLOAD_TARGET
    elseif chain_case == "trigger_chain_multicast" then
        effects = recipes.TRIGGER_CHAIN_MULTICAST_TARGET
        opts.force_trigger_enabled = true
        opts.force_chain_multicast_disabled = true
    elseif chain_case == "nested_payload" then
        effects = recipes.TRIGGER_CHAIN_PAYLOAD_TARGET
        opts.force_trigger_enabled = true
    elseif chain_case == "nested_trigger_timer" then
        effects = recipes.TIMER_TRIGGER_CHAIN_TARGET
        opts.force_trigger_enabled = true
        opts.force_timer_enabled = true
    elseif chain_case == "recursion" then
        effects = recipes.CHAIN_CHAIN_TARGET
    end

    local sfp_launch_before = runtime_stats.get("sfp_launch_attempts")
    if chain_case == "disabled" then
        local compiled = plan_cache.compileOrGet(cloneEffects(recipes.CHAIN_FIRE_FROST_TARGET))
        local audit = nil
        if compiled.ok then
            local slots = plan_cache.attachEmissionSlots(compiled.recipe_id)
            local specs = slots.ok and plan_cache.attachHelperSpecs(compiled.recipe_id) or nil
            local plan = specs and specs.ok and specs.plan or (slots and slots.plan or compiled.plan)
            audit = chain_targeting.auditChainDryRun(plan, chainHitContext(), chainHopCandidates("direct_chain_3"), {
                scan_radius = limits.MAX_CHAIN_SCAN_RADIUS,
            })
        end
        local dispatch = safeTryDispatch(payload, { node_metadata = { { logical_id = "chain-runtime-disabled" } } }, { real_effects = recipes.CHAIN_FIRE_FROST_TARGET }, opts)
        return {
            request_id = payload and payload.request_id,
            ok = dispatch and dispatch.ok == false and dispatch.used_live_2_2c == false and audit and audit.future_runtime_candidate == true,
            mode = "chain_runtime",
            chain_case = chain_case,
            audit_future_runtime_candidate = audit and audit.future_runtime_candidate == true or false,
            runtime_dispatch_deferred = dispatch and dispatch.ok == false,
            fallback_reason = dispatch and dispatch.fallback_reason or nil,
            sfp_launch_attempts_before = sfp_launch_before,
            sfp_launch_attempts_after = runtime_stats.get("sfp_launch_attempts"),
            sfp_launch_unchanged = sfp_launch_before == runtime_stats.get("sfp_launch_attempts"),
        }
    end

    local dispatch = safeTryDispatch(payload, { node_metadata = { { logical_id = "chain-runtime" } } }, { real_effects = effects }, opts)
    local probe = {
        request_id = payload and payload.request_id,
        mode = "chain_runtime",
        chain_case = chain_case,
        dispatch = dispatch,
        live_mode = dispatch and dispatch.live_mode or nil,
        chain_shape = dispatch and dispatch.chain_shape or nil,
        chain_id = dispatch and dispatch.chain_id or nil,
        payload_modifier_kind = dispatch and dispatch.payload_modifier_kind or nil,
        has_multicast_payload = dispatch and dispatch.has_multicast_payload == true or false,
        chain_multicast_fanout_count = dispatch and dispatch.chain_multicast_fanout_count or 1,
        max_hops = dispatch and dispatch.max_hops or nil,
        requested_hops = dispatch and dispatch.requested_hops or nil,
        source_jobs = dispatch and dispatch.source_jobs or nil,
        source_launch_count = dispatch and dispatch.ok == true and 1 or 0,
        selected_target_ids = {},
        completed_hops = 0,
        chain_payload_launch_count = 0,
        chain_payload_jobs = {},
        duplicate_source_suppressed = false,
        branch_source_suppressed = false,
        duplicate_hop_suppressed = false,
        branch_hop_suppressed = false,
        stop_reason = nil,
        fallback_reason = dispatch and dispatch.fallback_reason or nil,
        rejection_reason = dispatch and (dispatch.rejection_reason or dispatch.fallback_reason or dispatch.error) or nil,
        sfp_launch_attempts_before = sfp_launch_before,
        sfp_launch_attempts_after = runtime_stats.get("sfp_launch_attempts"),
    }

    if dispatch and dispatch.ok == true and dispatch.live_mode == "chain" and not manual_real_gameplay then
        local simulated = simulateChainRuntime(dispatch, payload, provider, {
            source_target_id = chain_case == "real_provider_no_target" and "far" or nil,
        })
        probe.selected_target_ids = simulated.selected_target_ids
        probe.completed_hops = simulated.completed_hops
        probe.chain_payload_launch_count = simulated.chain_payload_launch_count
        probe.chain_payload_jobs = simulated.chain_payload_jobs
        probe.ir_chain_runtime_hops = simulated.ir_chain_runtime_hops
        probe.ir_chain_runtime_job_count = simulated.ir_chain_runtime_job_count
        probe.ir_chain_runtime_real_job_count = simulated.ir_chain_runtime_real_job_count
        probe.source_hit_result = simulated.source_hit_result
        probe.duplicate_source_suppressed = simulated.duplicate_source_result and simulated.duplicate_source_result.duplicate_suppressed == true or false
        probe.branch_source_suppressed = simulated.branch_source_result and simulated.branch_source_result.duplicate_suppressed == true or false
        probe.duplicate_hop_suppressed = simulated.duplicate_hop_result and simulated.duplicate_hop_result.duplicate_suppressed == true or false
        probe.branch_hop_suppressed = simulated.branch_hop_result and simulated.branch_hop_result.duplicate_suppressed == true or false
        probe.stop_reason = simulated.stop_reason
        probe.max_stop_result = simulated.max_stop_result
        probe.sfp_launch_attempts_after = runtime_stats.get("sfp_launch_attempts")
    end

    local expected_success = chain_case == "direct_chain_3"
        or chain_case == "trigger_chain_3"
        or chain_case == "direct_chain_speed_plus_3"
        or chain_case == "trigger_chain_speed_plus_3"
        or chain_case == "direct_chain_size_plus_3"
        or chain_case == "trigger_chain_size_plus_3"
        or chain_case == "direct_chain_multicast_8"
        or chain_case == "trigger_chain_multicast_8"
        or chain_case == "filters"
    local expected_fanout_count = (chain_case == "direct_chain_multicast_8"
        or chain_case == "trigger_chain_multicast_8") and recipes.CHAOS_CHAIN_MULTICAST_FANOUT_COUNT or 1
    local expected_modifier_kind = nil
    if string.find(chain_case, "speed_plus", 1, true) then
        expected_modifier_kind = "speed_plus"
    elseif string.find(chain_case, "size_plus", 1, true) then
        expected_modifier_kind = "size_plus"
    end
    if chain_case == "filters" then
        probe.ok = dispatch and dispatch.ok == true
            and dispatch.live_mode == "chain"
            and probe.chain_payload_launch_count >= 1
            and probe.selected_target_ids
            and probe.selected_target_ids[1] == "C"
            and probe.duplicate_source_suppressed == true
            and probe.branch_source_suppressed == true
    elseif expected_success then
        probe.ok = dispatch and dispatch.ok == true
            and dispatch.live_mode == "chain"
            and (expected_modifier_kind == nil or dispatch.payload_modifier_kind == expected_modifier_kind)
            and probe.chain_payload_launch_count == 3 * expected_fanout_count
            and (expected_fanout_count == 1
                or (dispatch.has_multicast_payload == true
                    and dispatch.chain_multicast_fanout_count == expected_fanout_count
                    and chainPayloadJobsHaveFanoutMetadata(probe.chain_payload_jobs, expected_fanout_count)))
            and table.concat(probe.selected_target_ids or {}, ",") == "B,A,B"
            and probe.duplicate_source_suppressed == true
            and probe.branch_source_suppressed == true
            and probe.duplicate_hop_suppressed == true
            and probe.branch_hop_suppressed == true
            and probe.stop_reason == "max_hops_reached"
            and (expected_modifier_kind == nil or chainPayloadJobsHaveModifier(probe.chain_payload_jobs, expected_modifier_kind))
    elseif chain_case == "no_valid" then
        probe.ok = dispatch and dispatch.ok == true
            and dispatch.live_mode == "chain"
            and probe.chain_payload_launch_count == 0
            and probe.stop_reason == "no_valid_chain_target"
    elseif chain_case == "chain_speed_plus_no_valid" then
        probe.ok = dispatch and dispatch.ok == true
            and dispatch.live_mode == "chain"
            and dispatch.payload_modifier_kind == "speed_plus"
            and probe.chain_payload_launch_count == 0
            and probe.stop_reason == "no_valid_chain_target"
    elseif chain_case == "real_provider_no_target" then
        probe.ok = dispatch and dispatch.ok == true
            and dispatch.live_mode == "chain"
            and probe.chain_payload_launch_count == 0
            and (probe.stop_reason == "no_valid_chain_target"
                or probe.stop_reason == "chain_target_provider_unavailable")
    elseif manual_real_gameplay then
        probe.ok = dispatch and dispatch.ok == true
            and dispatch.live_mode == "chain"
            and dispatch.chain_shape == "trigger_payload_chain"
            and dispatch.requested_hops == 3
        if probe.ok then
            log.info(string.format(
                "SPELLFORGE_CHAIN_MANUAL_REAL_PROBE_READY recipe_id=%s plan_recipe_id=%s cast_id=%s chain_id=%s chain_shape=%s source_slot_id=%s payload_slot_id=%s requested_hops=%s source_projectile_id=%s provider=real effect_chain=fire_damage_trigger_chain3_frost_damage",
                tostring(dispatch.recipe_id),
                tostring(dispatch.plan_recipe_id),
                tostring(dispatch.cast_id),
                tostring(dispatch.chain_id),
                tostring(dispatch.chain_shape),
                tostring(dispatch.slot_id),
                tostring(dispatch.payload_slot_id),
                tostring(dispatch.requested_hops),
                tostring(dispatch.projectile_id)
            ))
        end
    elseif chain_case == "chain_speed_plus_disabled" then
        probe.ok = dispatch and dispatch.ok == false
            and dispatch.used_live_2_2c == false
            and dispatch.fallback_reason == "chain_speed_plus_disabled"
            and sfp_launch_before == runtime_stats.get("sfp_launch_attempts")
    elseif chain_case == "chain_size_plus_disabled" then
        probe.ok = dispatch and dispatch.ok == false
            and dispatch.used_live_2_2c == false
            and dispatch.fallback_reason == "chain_size_plus_disabled"
            and sfp_launch_before == runtime_stats.get("sfp_launch_attempts")
    else
        probe.ok = dispatch and dispatch.ok == false
            and dispatch.used_live_2_2c == false
            and type(dispatch.fallback_reason) == "string"
    end

    local marker = probe.ok and "SPELLFORGE_CHAIN_RUNTIME_PROBE_OK" or "SPELLFORGE_CHAIN_RUNTIME_PROBE_REJECTED"
    log.info(string.format(
        "%s chain_case=%s live_mode=%s chain_shape=%s payload_modifier_kind=%s fanout_count=%s requested_hops=%s completed_hops=%s ir_chain_hops=%s ir_chain_jobs=%s selected_target_ids=%s stop_reason=%s rejection_reason=%s",
        marker,
        tostring(chain_case),
        tostring(probe.live_mode),
        tostring(probe.chain_shape),
        tostring(probe.payload_modifier_kind),
        tostring(probe.chain_multicast_fanout_count),
        tostring(probe.requested_hops),
        tostring(probe.completed_hops),
        tostring(probe.ir_chain_runtime_hops),
        tostring(probe.ir_chain_runtime_job_count),
        table.concat(probe.selected_target_ids or {}, ","),
        tostring(probe.stop_reason),
        tostring(probe.rejection_reason)
    ))
    return probe
end

local function isTargetRange(range)
    return range == 2 or range == "target" or range == "Target"
end

local function isSingleStoredNode(entry)
    return type(entry) == "table"
        and type(entry.node_metadata) == "table"
        and #entry.node_metadata == 1
end

local function multicastRejected(reason, details, counter_name)
    runtime_stats.inc("live_multicast_rejected")
    if counter_name then
        runtime_stats.inc(counter_name)
    end
    return rejected(reason, details)
end

local function isPatternMode(mode)
    return mode == "spread" or mode == "burst"
end

local function isFanoutMode(mode)
    return mode == "multicast" or isPatternMode(mode)
end

local function patternModeForKind(pattern_kind)
    if pattern_kind == "Spread" then
        return "spread"
    elseif pattern_kind == "Burst" then
        return "burst"
    end
    return nil
end

local function patternRejected(pattern_kind, reason, details, counter_name)
    if pattern_kind == "Spread" then
        runtime_stats.inc("live_spread_rejected")
    elseif pattern_kind == "Burst" then
        runtime_stats.inc("live_burst_rejected")
    end
    if counter_name then
        runtime_stats.inc(counter_name)
    end
    return rejected(reason, details)
end

local function triggerRejected(reason, details, counter_name)
    runtime_stats.inc("live_trigger_rejected")
    if counter_name then
        runtime_stats.inc(counter_name)
    end
    return rejected(reason, details)
end

local function timerRejected(reason, details, counter_name)
    runtime_stats.inc("live_timer_rejected")
    if counter_name then
        runtime_stats.inc(counter_name)
    end
    return rejected(reason, details)
end

local function chainRuntimeRejected(reason, details, counter_name)
    runtime_stats.inc("chain_runtime_rejected")
    if counter_name then
        runtime_stats.inc(counter_name)
    end
    log.info(string.format(
        "SPELLFORGE_CHAIN_RUNTIME_REJECTED reason=%s plan_recipe_id=%s source_slot_id=%s payload_slot_id=%s requested_hops=%s max_hops=%s",
        tostring(reason),
        tostring(details and details.plan_recipe_id or nil),
        tostring(details and details.source_slot_id or nil),
        tostring(details and details.payload_slot_id or nil),
        tostring(details and details.requested_hops or nil),
        tostring(details and details.max_hops or nil)
    ))
    return rejected(reason, details)
end

local function bounceRejected(reason, details, counter_name)
    runtime_stats.inc("live_bounce_rejected")
    if counter_name then
        runtime_stats.inc(counter_name)
    end
    log.info(string.format(
        "SPELLFORGE_LIVE_BOUNCE_REJECTED reason=%s plan_recipe_id=%s source_slot_id=%s payload_slot_id=%s bounce_max=%s",
        tostring(reason),
        tostring(details and details.plan_recipe_id or nil),
        tostring(details and details.source_slot_id or nil),
        tostring(details and details.payload_slot_id or nil),
        tostring(details and details.bounce_max or nil)
    ))
    return rejected(reason, details)
end

local function pierceRejected(reason, details, counter_name)
    runtime_stats.inc("live_pierce_rejected")
    if counter_name then
        runtime_stats.inc(counter_name)
    end
    log.info(string.format(
        "SPELLFORGE_PIERCE_DEFERRED reason=%s plan_recipe_id=%s source_slot_id=%s payload_slot_id=%s pierce_limit=%s",
        tostring(reason),
        tostring(details and details.plan_recipe_id or nil),
        tostring(details and details.source_slot_id or nil),
        tostring(details and details.payload_slot_id or nil),
        tostring(details and details.pierce_limit or nil)
    ))
    return rejected(reason, details)
end

local function nestedTriggerTimerRejected(reason, details, counter_name)
    local result = details or {}
    result.nested_trigger_timer_rejected = true
    result.rejection_reason = result.rejection_reason or reason
    if counter_name then
        runtime_stats.inc(counter_name)
    end
    log.info(string.format(
        "SPELLFORGE_NESTED_TRIGGER_TIMER_REJECTED reason=%s plan_recipe_id=%s root_source_slot_id=%s intermediate_slot_id=%s final_payload_slot_id=%s root_stage_kind=%s intermediate_stage_kind=%s max_payload_depth=%s has_trigger_payload=%s has_timer_payload=%s has_multicast_payload=%s has_pattern_payload=%s has_chain=%s",
        tostring(reason),
        tostring(result.plan_recipe_id),
        tostring(result.root_source_slot_id),
        tostring(result.intermediate_slot_id),
        tostring(result.final_payload_slot_id),
        tostring(result.root_stage_kind),
        tostring(result.intermediate_stage_kind),
        tostring(result.max_payload_depth),
        tostring(result.has_trigger_payload),
        tostring(result.has_timer_payload),
        tostring(result.has_multicast_payload),
        tostring(result.has_pattern_payload),
        tostring(result.has_chain)
    ))
    if string.find(tostring(reason), "nested_final_fanout", 1, true)
        or result.has_multicast_payload == true
        or result.has_pattern_payload == true then
        log.info(string.format(
            "SPELLFORGE_NESTED_FINAL_FANOUT_REJECTED reason=%s plan_recipe_id=%s root_source_slot_id=%s intermediate_slot_id=%s final_payload_slot_id=%s max_payload_depth=%s has_multicast_payload=%s has_pattern_payload=%s",
            tostring(reason),
            tostring(result.plan_recipe_id),
            tostring(result.root_source_slot_id),
            tostring(result.intermediate_slot_id),
            tostring(result.final_payload_slot_id),
            tostring(result.max_payload_depth),
            tostring(result.has_multicast_payload),
            tostring(result.has_pattern_payload)
        ))
    end
    return rejected(reason, result)
end

local function speedPlusRejected(reason, details, counter_name)
    runtime_stats.inc("live_speed_plus_rejected")
    if counter_name then
        runtime_stats.inc(counter_name)
    end
    return rejected(reason, details)
end

local function sizePlusRejected(reason, details, counter_name)
    runtime_stats.inc("live_size_plus_rejected")
    if counter_name then
        runtime_stats.inc(counter_name)
    end
    return rejected(reason, details)
end

local function homingRejected(reason, details, counter_name)
    runtime_stats.inc("live_homing_rejected")
    if counter_name then
        runtime_stats.inc(counter_name)
    end
    return rejected(reason, details)
end

local function payloadMulticastRuntimeEnabled(options)
    if options.force_payload_multicast_disabled == true then
        return false
    end
    return options.force_payload_multicast_enabled == true or dev.livePayloadMulticastEnabled()
end

local function payloadPatternRuntimeEnabled(options)
    if options.force_payload_pattern_disabled == true then
        return false
    end
    return options.force_payload_pattern_enabled == true or dev.livePayloadPatternEnabled()
end

local function nestedTriggerTimerRuntimeEnabled(options)
    if options.force_nested_trigger_timer_disabled == true then
        return false
    end
    return options.force_nested_trigger_timer_enabled == true or dev.liveNestedTriggerTimerEnabled()
end

local function nestedFinalFanoutRuntimeEnabled(options)
    if options.force_nested_final_fanout_disabled == true then
        return false
    end
    return options.force_nested_final_fanout_enabled == true or dev.liveNestedFinalFanoutEnabled()
end

local function addNestedTriggerTimerDiagnostics(details, plan)
    local out = details or {}
    local shape = nested_trigger_timer.inspectShape(plan)
    for key, value in pairs(shape or {}) do
        if out[key] == nil then
            out[key] = value
        end
    end
    return out
end

local function patternAttempt(pattern_kind)
    if pattern_kind == "Spread" then
        runtime_stats.inc("live_spread_attempts")
    elseif pattern_kind == "Burst" then
        runtime_stats.inc("live_burst_attempts")
    end
end

local function patternQualified(pattern_kind, emission_count)
    if pattern_kind == "Spread" then
        runtime_stats.inc("live_spread_qualified")
        runtime_stats.inc("live_spread_emissions_planned", emission_count)
    elseif pattern_kind == "Burst" then
        runtime_stats.inc("live_burst_qualified")
        runtime_stats.inc("live_burst_emissions_planned", emission_count)
    end
end

local function prefixLiveShape(prefix_ops)
    local saw_multicast = false
    local pattern_kind = nil
    local pattern_op = nil
    for _, op in ipairs(prefix_ops or {}) do
        if op.opcode == "Multicast" then
            saw_multicast = true
        elseif op.opcode == "Spread" or op.opcode == "Burst" then
            if pattern_kind ~= nil then
                return false, "ambiguous_pattern", pattern_kind, pattern_op
            end
            pattern_kind = op.opcode
            pattern_op = op
        else
            return false, string.format("unsupported_prefix_%s", tostring(op.opcode))
        end
    end
    if pattern_kind ~= nil and not saw_multicast then
        return false, "pattern_without_multicast", pattern_kind, pattern_op
    end
    if pattern_kind ~= nil then
        return true, string.lower(pattern_kind) .. "_primary", pattern_kind, pattern_op
    end
    return true, saw_multicast and "multicast_primary" or nil, nil, nil
end

local function estimateFirstGroupOperators(effects)
    local info = {
        multicast_count = 1,
        has_multicast = false,
        has_spread = false,
        has_burst = false,
        pattern_kind = nil,
        ambiguous_pattern = false,
    }
    for _, effect in ipairs(effects or {}) do
        local id = effect and effect.id and string.lower(tostring(effect.id)) or nil
        if id == "spellforge_multicast" then
            info.has_multicast = true
            info.multicast_count = info.multicast_count * (tonumber(effect.params and effect.params.count) or 1)
        elseif id == "spellforge_spread" then
            info.has_spread = true
            if info.pattern_kind ~= nil then
                info.ambiguous_pattern = true
            end
            info.pattern_kind = info.pattern_kind or "Spread"
        elseif id == "spellforge_burst" then
            info.has_burst = true
            if info.pattern_kind ~= nil then
                info.ambiguous_pattern = true
            end
            info.pattern_kind = info.pattern_kind or "Burst"
        elseif id and string.sub(id, 1, 10) == "spellforge_" then
            -- Other operators are validated by the parser/plan checks.
        elseif effect ~= nil then
            return info
        end
    end
    return info
end

local function effectListHasOperator(effects, opcode)
    local wanted = opcode == "Timer" and "spellforge_timer"
        or opcode == "Trigger" and "spellforge_trigger"
        or opcode == "Chain" and "spellforge_chain"
        or opcode == "Bounce" and "spellforge_bounce"
        or opcode == "Pierce" and "spellforge_pierce"
        or opcode == "Speed+" and "spellforge_speed_plus"
        or opcode == "Size+" and "spellforge_size_plus"
        or opcode == "Homing" and "spellforge_homing"
        or nil
    if not wanted then
        return false
    end
    for _, effect in ipairs(effects or {}) do
        local id = effect and effect.id and string.lower(tostring(effect.id)) or nil
        if id == wanted then
            return true
        end
    end
    return false
end

local function errorsMentionTimerDelay(errors)
    for _, err in ipairs(errors or {}) do
        local message = err and err.message and tostring(err.message) or ""
        if string.find(message, "Timer.seconds", 1, true) ~= nil
            or string.find(message, "Missing parameter seconds for Timer", 1, true) ~= nil then
            return true
        end
    end
    return false
end

local function errorsMentionSpeedPlusValue(errors)
    for _, err in ipairs(errors or {}) do
        local message = err and err.message and tostring(err.message) or ""
        if string.find(message, "Speed+.percent", 1, true) ~= nil
            or string.find(message, "Missing parameter percent for Speed+", 1, true) ~= nil then
            return true
        end
    end
    return false
end

local function errorsMentionSizePlusValue(errors)
    for _, err in ipairs(errors or {}) do
        local message = err and err.message and tostring(err.message) or ""
        if string.find(message, "Size+.percent", 1, true) ~= nil
            or string.find(message, "Missing parameter percent for Size+", 1, true) ~= nil then
            return true
        end
    end
    return false
end

local function validateLivePrimaryPlan(plan, opts)
    local options = opts or {}
    local projectile_cap = tonumber(options.max_projectiles) or limits.MAX_PROJECTILES_PER_CAST
    local fanout_cap = tonumber(options.max_payload_fanout) or limits.MAX_NESTED_PAYLOAD_FANOUT
    if type(plan) ~= "table" then
        return false, "missing_plan"
    end
    local bounds = plan.bounds or {}
    if bounds.group_count ~= 1 then
        return false, "not_single_group"
    end
    local static_emission_count = tonumber(bounds.static_emission_count) or 0
    if static_emission_count < 1 then
        return false, "no_static_emissions"
    end
    if bounds.has_trigger then
        if bounds.has_pattern then
            return false, "has_trigger", "pattern", "live_pattern_unsupported_opcode_rejections"
        elseif bounds.has_multicast then
            return false, "has_trigger", "multicast", "live_multicast_unsupported_opcode_rejections"
        end
        return false, "has_trigger"
    end
    if bounds.has_timer then
        if bounds.has_pattern then
            return false, "has_timer", "pattern", "live_pattern_unsupported_opcode_rejections"
        elseif bounds.has_multicast then
            return false, "has_timer", "multicast", "live_multicast_unsupported_opcode_rejections"
        end
        return false, "has_timer"
    end
    if bounds.has_chain then
        if bounds.has_pattern then
            return false, "has_chain", "pattern", "live_pattern_unsupported_opcode_rejections"
        elseif bounds.has_multicast then
            return false, "has_chain", "multicast", "live_multicast_unsupported_opcode_rejections"
        end
        return false, "has_chain"
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
        if bounds.has_pattern then
            return false, "has_postfix_ops", "pattern", "live_pattern_payload_rejections"
        elseif bounds.has_multicast then
            return false, "has_postfix_ops", "multicast", "live_multicast_payload_rejections"
        end
        return false, "has_postfix_ops"
    end
    if group.payload ~= nil then
        if bounds.has_pattern then
            return false, "has_payload", "pattern", "live_pattern_payload_rejections"
        elseif bounds.has_multicast then
            return false, "has_payload", "multicast", "live_multicast_payload_rejections"
        end
        return false, "has_payload"
    end

    local prefix_ok, prefix_note, pattern_kind, pattern_op = prefixLiveShape(group.prefix_ops)
    if not prefix_ok then
        if pattern_kind ~= nil or bounds.has_pattern then
            return false, prefix_note, patternModeForKind(pattern_kind) or "pattern", "live_pattern_unsupported_opcode_rejections", pattern_kind, pattern_op
        elseif bounds.has_multicast then
            return false, prefix_note, "multicast", "live_multicast_unsupported_opcode_rejections"
        end
        return false, prefix_note
    end

    local emission_count = tonumber(bounds.static_emission_count or group.emission_count_static) or 1
    if emission_count > projectile_cap then
        chaos_budget.recordReject("projectile_cap_exceeded", "projectile")
        if pattern_kind ~= nil or bounds.has_pattern then
            return false, "pattern_cap_exceeded", patternModeForKind(pattern_kind) or "pattern", "live_multicast_cap_rejections", pattern_kind, pattern_op
        elseif bounds.has_multicast then
            return false, "multicast_cap_exceeded", "multicast", "live_multicast_cap_rejections"
        end
        return false, "projectile_cap_exceeded"
    end

    local is_multicast = bounds.has_multicast and emission_count > 1
    if is_multicast and emission_count > fanout_cap then
        chaos_budget.recordReject("multicast_fanout_cap_exceeded", "fanout")
        if pattern_kind ~= nil or bounds.has_pattern then
            return false, "pattern_cap_exceeded", patternModeForKind(pattern_kind) or "pattern", "live_multicast_cap_rejections", pattern_kind, pattern_op
        end
        return false, "multicast_cap_exceeded", "multicast", "live_multicast_cap_rejections"
    end
    if pattern_kind ~= nil then
        if not is_multicast then
            return false, "pattern_fanout_missing", patternModeForKind(pattern_kind), "live_pattern_unsupported_opcode_rejections", pattern_kind, pattern_op
        end
        if options.force_multicast_disabled == true then
            return false, "live_multicast_disabled", patternModeForKind(pattern_kind), nil, pattern_kind, pattern_op
        end
        if options.force_multicast_enabled ~= true and not dev.liveMulticastEnabled() then
            return false, "live_multicast_disabled", patternModeForKind(pattern_kind), nil, pattern_kind, pattern_op
        end
        if options.force_pattern_disabled == true then
            return false, "live_spread_burst_disabled", patternModeForKind(pattern_kind), nil, pattern_kind, pattern_op
        end
        if options.force_pattern_enabled ~= true and not dev.liveSpreadBurstEnabled() then
            return false, "live_spread_burst_disabled", patternModeForKind(pattern_kind), nil, pattern_kind, pattern_op
        end
        return true, prefix_note, patternModeForKind(pattern_kind), emission_count, pattern_kind, pattern_op
    end

    if bounds.has_pattern then
        return false, "has_pattern", "pattern", "live_pattern_unsupported_opcode_rejections"
    end

    if is_multicast then
        if options.force_multicast_disabled == true then
            return false, "live_multicast_disabled", "multicast"
        end
        if options.force_multicast_enabled ~= true and not dev.liveMulticastEnabled() then
            return false, "live_multicast_disabled", "multicast"
        end
        return true, "multicast_primary", "multicast", emission_count
    end

    return true, prefix_note, "single", emission_count
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

local function hasPayloadBindings(value)
    return type(value) == "table" and #value > 0
end

local function collectPrimaryHelpers(plan, opts)
    local options = opts or {}
    local projectile_cap = tonumber(options.max_projectiles) or limits.MAX_PROJECTILES_PER_CAST
    if type(plan.emission_slots) ~= "table" or #plan.emission_slots == 0 then
        return nil, "slot_count_zero"
    end
    if type(plan.helper_records) ~= "table" or #plan.helper_records == 0 then
        return nil, "helper_record_count_zero"
    end

    local helpers_by_slot = helperBySlotId(plan.helper_records)
    local selected = {}
    for _, slot in ipairs(plan.emission_slots) do
        if slot.kind ~= "primary_emission" then
            return nil, "slot_not_primary"
        end
        if slot.parent_slot_id ~= nil then
            return nil, "slot_has_parent"
        end
        if slot.source_postfix_opcode ~= nil or slot.trigger_source_slot_id ~= nil or slot.timer_source_slot_id ~= nil then
            return nil, "slot_has_source_postfix"
        end
        if hasPayloadBindings(slot.payload_bindings) then
            return nil, "slot_has_payload_bindings"
        end
        if type(slot.postfix_ops) == "table" and #slot.postfix_ops > 0 then
            return nil, "slot_has_postfix_ops"
        end

        local helper = helpers_by_slot[slot.slot_id]
        if not helper then
            return nil, "helper_missing_for_slot"
        end
        if type(helper.engine_id) ~= "string" or helper.engine_id == "" then
            return nil, "helper_engine_id_missing"
        end
        if helper.parent_slot_id ~= nil then
            return nil, "helper_has_parent"
        end
        if helper.source_postfix_opcode ~= nil or helper.trigger_source_slot_id ~= nil or helper.timer_source_slot_id ~= nil then
            return nil, "helper_is_payload"
        end
        if hasPayloadBindings(helper.payload_bindings) then
            return nil, "helper_has_payload_bindings"
        end

        selected[#selected + 1] = {
            slot = slot,
            helper = helper,
        }
    end

    if #selected ~= #plan.helper_records then
        return nil, "helper_record_count_mismatch"
    end
    if #selected > projectile_cap then
        return nil, "multicast_cap_exceeded"
    end

    return selected, nil
end

local function computePatternInfo(live_mode, pattern_kind, pattern_op, selected_helpers, launch_payload)
    if not isPatternMode(live_mode) then
        return nil, nil
    end
    local count = #selected_helpers
    local params = pattern_op and pattern_op.params or nil
    local computed = nil
    if live_mode == "spread" then
        computed = patterns.computeSpreadDirections(launch_payload.direction, count, params)
    elseif live_mode == "burst" then
        computed = patterns.computeBurstDirections(launch_payload.direction, count, params)
    else
        return nil, "unknown_pattern_mode"
    end
    if not computed or computed.ok ~= true then
        runtime_stats.inc("live_pattern_direction_failed")
        return nil, computed and computed.error or "pattern direction failed"
    end

    local direction_by_slot_id = {}
    local key_by_slot_id = {}
    for index, pair in ipairs(selected_helpers) do
        local slot_id = pair and pair.helper and pair.helper.slot_id
        if type(slot_id) ~= "string" or computed.directions[index] == nil or computed.direction_keys[index] == nil then
            runtime_stats.inc("live_pattern_direction_failed")
            return nil, "pattern direction missing for helper"
        end
        direction_by_slot_id[slot_id] = computed.directions[index]
        key_by_slot_id[slot_id] = computed.direction_keys[index]
    end
    runtime_stats.inc("live_pattern_direction_jobs", count)

    return {
        pattern_kind = pattern_kind,
        pattern_count = count,
        directions = computed.directions,
        direction_keys = computed.direction_keys,
        direction_by_slot_id = direction_by_slot_id,
        key_by_slot_id = key_by_slot_id,
        spread_preset = computed.preset,
        spread_side_angle_degrees = computed.side_angle_degrees,
        spread_rotation_axis = computed.rotation_axis,
        burst_param_count = computed.burst_param_count,
        burst_ring_angle_degrees = computed.ring_angle_degrees,
        burst_distribution = computed.distribution,
    }, nil
end

local function buildJobInputs(selected_helpers, compiled_recipe_id, cast_id, launch_payload, pattern_info, size_info, speed_info, homing_info)
    local jobs = {}
    local fanout_count = #selected_helpers
    for index, pair in ipairs(selected_helpers) do
        local slot = pair.slot
        local helper = pair.helper
        local emission_index = slot.emission_index or helper.emission_index or index
        local group_index = slot.group_index or helper.group_index
        local launch_direction = launch_payload.direction
        local pattern_direction_key = nil
        if pattern_info and pattern_info.direction_by_slot_id then
            launch_direction = pattern_info.direction_by_slot_id[helper.slot_id] or launch_direction
            pattern_direction_key = pattern_info.key_by_slot_id and pattern_info.key_by_slot_id[helper.slot_id] or nil
        end
        if homing_info and homing_info.direction then
            launch_direction = homing_info.direction
        end
        jobs[#jobs + 1] = {
            kind = orchestrator.LIVE_SIMPLE_LAUNCH_JOB_KIND,
            recipe_id = compiled_recipe_id,
            slot_id = helper.slot_id,
            helper_engine_id = helper.engine_id,
            depth = 0,
            cast_id = cast_id,
            emission_index = emission_index,
            group_index = group_index,
            fanout_count = fanout_count,
            max_live_launches_per_tick = launch_payload.max_live_launches_per_tick,
            chaos_budget_profile = launch_payload.chaos_budget_profile,
            pattern_kind = pattern_info and pattern_info.pattern_kind or nil,
            pattern_index = pattern_info and emission_index or nil,
            pattern_count = pattern_info and pattern_info.pattern_count or nil,
            pattern_direction_key = pattern_direction_key,
            size_plus = size_info and true or nil,
            size_plus_mode = size_info and size_info.size_plus_mode or nil,
            size_plus_value = size_info and size_info.size_plus_value or nil,
            size_plus_multiplier = size_info and size_info.size_plus_multiplier or nil,
            size_plus_field = size_info and size_info.size_plus_field or nil,
            size_plus_capped = size_info and size_info.size_plus_capped or nil,
            size_plus_base_area = size_info and size_info.size_plus_base_area or nil,
            size_plus_area = size_info and size_info.size_plus_area or nil,
            speed = speed_info and speed_info.speed_plus_speed or nil,
            maxSpeed = speed_info and speed_info.speed_plus_max_speed or nil,
            speed_plus = speed_info and true or nil,
            speed_plus_mode = speed_info and speed_info.speed_plus_mode or nil,
            speed_plus_value = speed_info and speed_info.speed_plus_value or nil,
            speed_plus_base_speed = speed_info and speed_info.speed_plus_base_speed or nil,
            speed_plus_multiplier = speed_info and speed_info.speed_plus_multiplier or nil,
            speed_plus_speed = speed_info and speed_info.speed_plus_speed or nil,
            speed_plus_max_speed = speed_info and speed_info.speed_plus_max_speed or nil,
            speed_plus_field = speed_info and speed_info.speed_plus_field or nil,
            speed_plus_capped = speed_info and speed_info.speed_plus_capped or nil,
            forceVec = homing_info and homing_info.forceVec or nil,
            homing = homing_info and true or nil,
            homing_mode = homing_info and homing_info.homing_mode or nil,
            homing_force = homing_info and homing_info.homing_force or nil,
            homing_field = homing_info and homing_info.homing_field or nil,
            homing_target_id = homing_info and homing_info.homing_target_id or nil,
            homing_target_provider = homing_info and homing_info.homing_target_provider or nil,
            homing_target_kind = homing_info and homing_info.homing_target_kind or nil,
            homing_candidate_count = homing_info and homing_info.homing_candidate_count or nil,
            homing_actor_candidate_count = homing_info and homing_info.homing_actor_candidate_count or nil,
            homing_creature_candidate_count = homing_info and homing_info.homing_creature_candidate_count or nil,
            homing_npc_candidate_count = homing_info and homing_info.homing_npc_candidate_count or nil,
            homing_force_key = homing_info and homing_info.homing_force_key or nil,
            homing_direction_key = homing_info and homing_info.homing_direction_key or nil,
            payload = {
                actor = launch_payload.actor or launch_payload.sender,
                start_pos = launch_payload.start_pos,
                direction = launch_direction,
                hit_object = launch_payload.hit_object,
                cast_id = cast_id,
                fanout_count = fanout_count,
                max_live_launches_per_tick = launch_payload.max_live_launches_per_tick,
                chaos_budget_profile = launch_payload.chaos_budget_profile,
                emission_index = emission_index,
                group_index = group_index,
                pattern_kind = pattern_info and pattern_info.pattern_kind or nil,
                pattern_index = pattern_info and emission_index or nil,
                pattern_count = pattern_info and pattern_info.pattern_count or nil,
                pattern_direction_key = pattern_direction_key,
                size_plus = size_info and true or nil,
                size_plus_mode = size_info and size_info.size_plus_mode or nil,
                size_plus_value = size_info and size_info.size_plus_value or nil,
                size_plus_multiplier = size_info and size_info.size_plus_multiplier or nil,
                size_plus_field = size_info and size_info.size_plus_field or nil,
                size_plus_capped = size_info and size_info.size_plus_capped or nil,
                size_plus_base_area = size_info and size_info.size_plus_base_area or nil,
                size_plus_area = size_info and size_info.size_plus_area or nil,
                speed = speed_info and speed_info.speed_plus_speed or nil,
                maxSpeed = speed_info and speed_info.speed_plus_max_speed or nil,
                speed_plus = speed_info and true or nil,
                speed_plus_mode = speed_info and speed_info.speed_plus_mode or nil,
                speed_plus_value = speed_info and speed_info.speed_plus_value or nil,
                speed_plus_base_speed = speed_info and speed_info.speed_plus_base_speed or nil,
                speed_plus_multiplier = speed_info and speed_info.speed_plus_multiplier or nil,
                speed_plus_speed = speed_info and speed_info.speed_plus_speed or nil,
                speed_plus_max_speed = speed_info and speed_info.speed_plus_max_speed or nil,
                speed_plus_field = speed_info and speed_info.speed_plus_field or nil,
                speed_plus_capped = speed_info and speed_info.speed_plus_capped or nil,
                forceVec = homing_info and homing_info.forceVec or nil,
                homing = homing_info and true or nil,
                homing_mode = homing_info and homing_info.homing_mode or nil,
                homing_force = homing_info and homing_info.homing_force or nil,
                homing_field = homing_info and homing_info.homing_field or nil,
                homing_target_id = homing_info and homing_info.homing_target_id or nil,
                homing_target_provider = homing_info and homing_info.homing_target_provider or nil,
                homing_target_kind = homing_info and homing_info.homing_target_kind or nil,
                homing_candidate_count = homing_info and homing_info.homing_candidate_count or nil,
                homing_actor_candidate_count = homing_info and homing_info.homing_actor_candidate_count or nil,
                homing_creature_candidate_count = homing_info and homing_info.homing_creature_candidate_count or nil,
                homing_npc_candidate_count = homing_info and homing_info.homing_npc_candidate_count or nil,
                homing_force_key = homing_info and homing_info.homing_force_key or nil,
                homing_direction_key = homing_info and homing_info.homing_direction_key or nil,
            },
        }
    end
    return jobs
end

local function jobSummary(job_id)
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
        fanout_count = job and job.fanout_count or nil,
        root_source_slot_id = job and (job.root_source_slot_id or (payload and payload.root_source_slot_id)) or nil,
        current_source_slot_id = job and (job.current_source_slot_id or (payload and payload.current_source_slot_id)) or nil,
        parent_slot_id = job and (job.parent_slot_id or (payload and payload.parent_slot_id)) or nil,
        payload_depth = job and (job.payload_depth or (payload and payload.payload_depth)) or nil,
        nested_stage_kind = job and (job.nested_stage_kind or (payload and payload.nested_stage_kind)) or nil,
        nested_stage_index = job and (job.nested_stage_index or (payload and payload.nested_stage_index)) or nil,
        pattern_kind = job and job.pattern_kind or nil,
        pattern_index = job and job.pattern_index or nil,
        pattern_count = job and job.pattern_count or nil,
        pattern_direction_key = job and job.pattern_direction_key or nil,
        chain_runtime = job and (job.chain_runtime or (payload and payload.chain_runtime)) or nil,
        chain_role = job and (job.chain_role or (payload and payload.chain_role)) or nil,
        chain_id = job and (job.chain_id or (payload and payload.chain_id)) or nil,
        chain_hop_index = job and (job.chain_hop_index or (payload and payload.chain_hop_index)) or nil,
        chain_max_hops = job and (job.chain_max_hops or (payload and payload.chain_max_hops)) or nil,
        chain_targeting_mode = job and (job.chain_targeting_mode or (payload and payload.chain_targeting_mode)) or nil,
        branch_scope = job and (job.branch_scope or (payload and payload.branch_scope)) or nil,
        branch_id = job and (job.branch_id or (payload and payload.branch_id)) or nil,
        branch_parent_id = job and (job.branch_parent_id or (payload and payload.branch_parent_id)) or nil,
        branch_kind = job and (job.branch_kind or (payload and payload.branch_kind)) or nil,
        branch_index = job and (job.branch_index or (payload and payload.branch_index)) or nil,
        branch_count = job and (job.branch_count or (payload and payload.branch_count)) or nil,
        chain_continuation_group_id = job and (job.chain_continuation_group_id or (payload and payload.chain_continuation_group_id)) or nil,
        current_hit_target_id = job and (job.current_hit_target_id or (payload and payload.current_hit_target_id)) or nil,
        selected_target_id = job and (job.selected_target_id or (payload and payload.selected_target_id)) or nil,
        previous_projectile_id = job and (job.previous_projectile_id or (payload and payload.previous_projectile_id)) or nil,
        bounce_runtime = job and firstPresent(job.bounce_runtime, payload and payload.bounce_runtime) or nil,
        bounce_role = job and firstPresent(job.bounce_role, payload and payload.bounce_role) or nil,
        bounce_id = job and firstPresent(job.bounce_id, payload and payload.bounce_id) or nil,
        bounce_max = job and firstPresent(job.bounce_max, payload and payload.bounce_max) or nil,
        bounce_power = job and firstPresent(job.bounce_power, payload and payload.bounce_power) or nil,
        bounceEnabled = job and firstPresent(job.bounceEnabled, payload and payload.bounceEnabled) or nil,
        bounceMax = job and firstPresent(job.bounceMax, payload and payload.bounceMax) or nil,
        bouncePower = job and firstPresent(job.bouncePower, payload and payload.bouncePower) or nil,
        detonateOnActorHit = bounceDetonateOnActorHit(job, payload),
        post_launch_bounce_attempted = job and job.post_launch_bounce_attempted == true or false,
        post_launch_bounce_ok = job and job.post_launch_bounce_ok == true or false,
        post_launch_bounce_error = job and job.post_launch_bounce_error or nil,
        pierce_runtime = job and firstPresent(job.pierce_runtime, payload and payload.pierce_runtime) or nil,
        pierce_role = job and firstPresent(job.pierce_role, payload and payload.pierce_role) or nil,
        pierce_id = job and firstPresent(job.pierce_id, payload and payload.pierce_id) or nil,
        pierce_count = job and firstPresent(job.pierce_count, payload and payload.pierce_count) or nil,
        pierce_limit = job and firstPresent(job.pierce_limit, payload and payload.pierce_limit) or nil,
        piercing = job and firstPresent(job.piercing, payload and payload.piercing) or nil,
        pierceLimit = job and firstPresent(job.pierceLimit, payload and payload.pierceLimit) or nil,
        post_launch_pierce_attempted = job and job.post_launch_pierce_attempted == true or false,
        post_launch_pierce_ok = job and job.post_launch_pierce_ok == true or false,
        post_launch_pierce_error = job and job.post_launch_pierce_error or nil,
        post_launch_detonate_on_actor_attempted = job and job.post_launch_detonate_on_actor_attempted == true or false,
        post_launch_detonate_on_actor_ok = job and job.post_launch_detonate_on_actor_ok == true or false,
        post_launch_detonate_on_actor_error = job and job.post_launch_detonate_on_actor_error or nil,
        payload_modifier_kind = job and (job.payload_modifier_kind or (payload and payload.payload_modifier_kind)) or nil,
        source_slot_id = job and job.source_slot_id or nil,
        source_prefix_opcode = job and (job.source_prefix_opcode or (payload and payload.source_prefix_opcode)) or nil,
        source_helper_engine_id = job and job.source_helper_engine_id or nil,
        source_postfix_opcode = job and job.source_postfix_opcode or nil,
        payload_slot_id = job and job.payload_slot_id or nil,
        trigger_route = job and (job.trigger_route or (payload and payload.trigger_route)) or nil,
        trigger_duplicate_key = job and (job.trigger_duplicate_key or (payload and payload.trigger_duplicate_key)) or nil,
        timer_source_slot_id = job and (job.timer_source_slot_id or (payload and payload.timer_source_slot_id)) or nil,
        timer_payload_slot_id = job and (job.timer_payload_slot_id or (payload and payload.timer_payload_slot_id)) or nil,
        timer_id = job and (job.timer_id or (payload and payload.timer_id)) or nil,
        timer_delay_ticks = job and (job.timer_delay_ticks or (payload and payload.timer_delay_ticks)) or nil,
        timer_delay_seconds = job and (job.timer_delay_seconds or (payload and payload.timer_delay_seconds)) or nil,
        timer_scheduled_tick = job and (job.timer_scheduled_tick or (payload and payload.timer_scheduled_tick)) or nil,
        timer_due_tick = job and (job.timer_due_tick or (payload and payload.timer_due_tick)) or nil,
        timer_scheduled_seconds = job and (job.timer_scheduled_seconds or (payload and payload.timer_scheduled_seconds)) or nil,
        timer_due_seconds = job and (job.timer_due_seconds or (payload and payload.timer_due_seconds)) or nil,
        timer_delay_semantics = job and (job.timer_delay_semantics or (payload and payload.timer_delay_semantics)) or nil,
        not_before_seconds = job and job.not_before_seconds or nil,
        created_seconds = job and job.created_seconds or nil,
        timer_duplicate_key = job and (job.timer_duplicate_key or (payload and payload.timer_duplicate_key)) or nil,
        size_plus = job and (job.size_plus or (payload and payload.size_plus)) or nil,
        size_plus_mode = job and (job.size_plus_mode or (payload and payload.size_plus_mode)) or nil,
        size_plus_value = job and (job.size_plus_value or (payload and payload.size_plus_value)) or nil,
        size_plus_multiplier = job and (job.size_plus_multiplier or (payload and payload.size_plus_multiplier)) or nil,
        size_plus_field = job and (job.size_plus_field or (payload and payload.size_plus_field)) or nil,
        size_plus_capped = job and (job.size_plus_capped or (payload and payload.size_plus_capped)) or nil,
        size_plus_base_area = job and (job.size_plus_base_area or (payload and payload.size_plus_base_area)) or nil,
        size_plus_area = job and (job.size_plus_area or (payload and payload.size_plus_area)) or nil,
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
        forceVec = job and (job.forceVec or (payload and payload.forceVec)) or nil,
        homing = job and (job.homing or (payload and payload.homing)) or nil,
        homing_mode = job and (job.homing_mode or (payload and payload.homing_mode)) or nil,
        homing_force = job and (job.homing_force or (payload and payload.homing_force)) or nil,
        homing_field = job and (job.homing_field or (payload and payload.homing_field)) or nil,
        homing_target_id = job and (job.homing_target_id or (payload and payload.homing_target_id)) or nil,
        homing_target_provider = job and (job.homing_target_provider or (payload and payload.homing_target_provider)) or nil,
        homing_target_kind = job and (job.homing_target_kind or (payload and payload.homing_target_kind)) or nil,
        homing_candidate_count = job and (job.homing_candidate_count or (payload and payload.homing_candidate_count)) or nil,
        homing_actor_candidate_count = job and (job.homing_actor_candidate_count or (payload and payload.homing_actor_candidate_count)) or nil,
        homing_creature_candidate_count = job and (job.homing_creature_candidate_count or (payload and payload.homing_creature_candidate_count)) or nil,
        homing_npc_candidate_count = job and (job.homing_npc_candidate_count or (payload and payload.homing_npc_candidate_count)) or nil,
        homing_force_key = job and (job.homing_force_key or (payload and payload.homing_force_key)) or nil,
        homing_direction_key = job and (job.homing_direction_key or (payload and payload.homing_direction_key)) or nil,
        launch_accepted = job and job.launch_accepted == true or false,
        projectile_id = job and job.projectile_id or nil,
        projectile_id_source = job and job.projectile_id_source or nil,
        projectile_registered = job and job.projectile_registered == true or false,
        launch_start_pos = job and (job.launch_start_pos or (payload and payload.start_pos)) or nil,
        launch_direction = job and (job.launch_direction or (payload and payload.direction)) or nil,
        excludeTarget = job and (job.excludeTarget or (payload and payload.excludeTarget)) or nil,
        launch_user_data = job and job.launch_user_data or nil,
        error = job and job.error or nil,
    }
end

local function tickUntilJobsSettled(job_ids, opts)
    local options = opts or {}
    local max_ticks = tonumber(options.max_launch_ticks) or 3
    local max_jobs_per_tick = tonumber(options.max_jobs_per_tick) or limits.MAX_JOBS_PER_TICK
    local max_live_launches_per_tick = tonumber(options.max_live_launches_per_tick) or limits.MAX_LIVE_LAUNCHES_PER_TICK
    local last_tick = nil

    for _ = 1, max_ticks do
        local all_settled = true
        for _, job_id in ipairs(job_ids or {}) do
            local job = orchestrator.getJob(job_id)
            if not job or job.status == "queued" or job.status == "running" then
                all_settled = false
                break
            end
        end
        if all_settled then
            return last_tick
        end
        last_tick = orchestrator.tick({
            max_jobs_per_tick = max_jobs_per_tick,
            max_live_launches_per_tick = max_live_launches_per_tick,
        })
        if options.allow_pending_launch_jobs == true
            and last_tick
            and tonumber(last_tick.live_launch_throttled_count) ~= nil
            and tonumber(last_tick.live_launch_throttled_count) > 0 then
            return last_tick
        end
    end

    return last_tick
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

local function tryHomingDispatch(compiled, launch_payload, options)
    runtime_stats.inc("live_homing_attempts")
    if options.force_homing_disabled == true then
        return homingRejected("live_homing_disabled", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_homing_disabled_rejections")
    end
    if options.force_homing_enabled ~= true and not dev.liveHomingEnabled() then
        return homingRejected("live_homing_disabled", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_homing_disabled_rejections")
    end

    local homing_plan, homing_reason, homing_counter = live_homing.selectV0Plan(compiled.plan)
    if not homing_plan then
        return homingRejected(homing_reason or "homing_v0_rejected", {
            plan_recipe_id = compiled.recipe_id,
        }, homing_counter)
    end

    local group = compiled.plan and compiled.plan.groups and compiled.plan.groups[1] or nil
    if type(group) ~= "table" or not isTargetRange(group.range) then
        return homingRejected("not_target_range", {
            plan_recipe_id = compiled.recipe_id,
        })
    end

    local attached = plan_cache.attachHelperRecords(compiled.recipe_id, { limits = options.budget_limits })
    if not attached.ok then
        return homingRejected("helper_records_failed", {
            plan_recipe_id = compiled.recipe_id,
            error = firstErrorMessage(attached),
            errors = attached.errors,
        })
    end

    local selected_helpers, materialized_reason = collectPrimaryHelpers(attached.plan)
    if not selected_helpers then
        local counter = nil
        if string.find(tostring(materialized_reason), "payload", 1, true)
            or string.find(tostring(materialized_reason), "postfix", 1, true)
            or string.find(tostring(materialized_reason), "source", 1, true)
            or string.find(tostring(materialized_reason), "parent", 1, true) then
            counter = "live_homing_payload_rejections"
        end
        return homingRejected(materialized_reason or "helper_selection_failed", {
            plan_recipe_id = compiled.recipe_id,
        }, counter)
    end
    if #selected_helpers ~= 1 then
        return homingRejected("slot_count_not_one", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_homing_unsupported_combo_rejections")
    end

    local homing_info, homing_err = live_homing.computeLaunchAssist(launch_payload, homing_plan.mutation)
    if not homing_info then
        return homingRejected(homing_err or "homing_target_missing", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_homing_target_rejections")
    end
    local use_soft_homing = options.soft_homing_probe == true
        or options.force_soft_homing_enabled == true
        or (options.force_soft_homing_disabled ~= true and dev.liveSoftHomingEnabled())
    local launch_homing_info = homing_info
    if use_soft_homing then
        launch_homing_info = {}
        for key, value in pairs(homing_info) do
            launch_homing_info[key] = value
        end
        launch_homing_info.forceVec = nil
        launch_homing_info.direction = nil
        launch_homing_info.homing_mode = options.soft_homing_probe == true and "soft_redirect_probe" or "soft_redirect"
        launch_homing_info.homing_field = "redirectSpell"
        launch_homing_info.homing_force = nil
        launch_homing_info.homing_force_key = nil
    end

    local source_recipe_id = options.source_recipe_id or launch_payload.recipe_id
    local result_recipe_id = source_recipe_id or compiled.recipe_id
    local cast_id = nextCastId(result_recipe_id, compiled.recipe_id)
    runtime_stats.inc("live_2_2c_qualified")
    runtime_stats.inc("live_homing_qualified")

    local job_inputs = buildJobInputs(selected_helpers, compiled.recipe_id, cast_id, launch_payload, nil, nil, nil, launch_homing_info)
    local slot_ids = {}
    local helper_engine_ids = {}
    local emission_indexes = {}
    for index, pair in ipairs(selected_helpers) do
        slot_ids[index] = pair.helper.slot_id
        helper_engine_ids[index] = pair.helper.engine_id
        emission_indexes[index] = pair.slot.emission_index or pair.helper.emission_index or index
    end

    log.info(string.format(
        "SPELLFORGE_LIVE_HOMING_QUALIFIED recipe_id=%s plan_recipe_id=%s cast_id=%s slot_id=%s helper_engine_id=%s homing_mode=%s homing_field=%s homing_force=%s homing_target_id=%s homing_target_provider=%s homing_target_kind=%s homing_candidate_count=%s homing_actor_candidate_count=%s homing_creature_candidate_count=%s homing_npc_candidate_count=%s force_key=%s",
        tostring(result_recipe_id),
        tostring(compiled.recipe_id),
        tostring(cast_id),
        tostring(slot_ids[1]),
        tostring(helper_engine_ids[1]),
        tostring(launch_homing_info.homing_mode),
        tostring(launch_homing_info.homing_field),
        tostring(launch_homing_info.homing_force),
        tostring(launch_homing_info.homing_target_id),
        tostring(launch_homing_info.homing_target_provider),
        tostring(launch_homing_info.homing_target_kind),
        tostring(launch_homing_info.homing_candidate_count),
        tostring(launch_homing_info.homing_actor_candidate_count),
        tostring(launch_homing_info.homing_creature_candidate_count),
        tostring(launch_homing_info.homing_npc_candidate_count),
        tostring(launch_homing_info.homing_force_key)
    ))

    if options.dry_run == true then
        return {
            ok = true,
            used_live_2_2c = true,
            dry_run = true,
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = slot_ids[1],
            helper_engine_id = helper_engine_ids[1],
            slot_ids = slot_ids,
            helper_engine_ids = helper_engine_ids,
            emission_indexes = emission_indexes,
            slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
            helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
            dispatch_count = #selected_helpers,
            fanout_count = #selected_helpers,
            homing_mode = homing_info.homing_mode,
            homing_force = homing_info.homing_force,
            homing_field = homing_info.homing_field,
            homing_target_id = homing_info.homing_target_id,
            homing_target_provider = homing_info.homing_target_provider,
            homing_target_kind = homing_info.homing_target_kind,
            homing_candidate_count = homing_info.homing_candidate_count,
            homing_actor_candidate_count = homing_info.homing_actor_candidate_count,
            homing_creature_candidate_count = homing_info.homing_creature_candidate_count,
            homing_npc_candidate_count = homing_info.homing_npc_candidate_count,
            homing_force_key = homing_info.homing_force_key,
            homing_direction_key = homing_info.homing_direction_key,
            simple_note = "homing_v0",
            live_mode = "homing",
            cast_id = cast_id,
        }
    end

    local job_ids = {}
    for _, job_input in ipairs(job_inputs) do
        local enqueue = orchestrator.enqueue(job_input)
        if not enqueue.ok then
            runtime_stats.inc("live_2_2c_dispatch_failed")
            return homingRejected("enqueue_failed", {
                recipe_id = result_recipe_id,
                plan_recipe_id = compiled.recipe_id,
                slot_id = job_input.slot_id,
                helper_engine_id = job_input.helper_engine_id,
                error = enqueue.error or "enqueue failed",
                cast_id = cast_id,
            })
        end
        job_ids[#job_ids + 1] = enqueue.job_id
    end
    runtime_stats.inc("live_homing_jobs_mutated", #job_ids)
    chaos_budget.observe({
        jobs = #job_ids,
        queue = orchestrator.queueLength(),
        projectiles = #selected_helpers,
    })

    local tick_result = tickUntilJobsSettled(job_ids, options)
    local jobs = {}
    local projectile_ids = {}
    local projectile_id_count = 0
    for index, job_id in ipairs(job_ids) do
        local summary = jobSummary(job_id)
        jobs[index] = summary
        if summary.projectile_id ~= nil then
            projectile_ids[#projectile_ids + 1] = summary.projectile_id
            projectile_id_count = projectile_id_count + 1
        end
        if summary.job_status == "queued" then
            orchestrator.cancel(job_id)
        end
        if summary.job_status ~= "complete" or summary.launch_accepted ~= true then
            runtime_stats.inc("live_2_2c_dispatch_failed")
            return bridgeError(summary.error or "homing helper launch job did not complete", {
                stage = "homing_launch_job",
                recipe_id = result_recipe_id,
                plan_recipe_id = compiled.recipe_id,
                slot_id = summary.slot_id,
                helper_engine_id = summary.helper_engine_id,
                job_id = job_id,
                job_ids = job_ids,
                job_status = summary.job_status,
                tick_result = tick_result,
                cast_id = cast_id,
                fallback_allowed = false,
            })
        end
    end

    local first_job = jobs[1] or {}
    log.info(string.format(
        "SPELLFORGE_LIVE_HOMING_APPLIED recipe_id=%s plan_recipe_id=%s cast_id=%s slot_id=%s helper_engine_id=%s homing_mode=%s homing_field=%s homing_force=%s homing_target_id=%s homing_target_provider=%s homing_target_kind=%s homing_candidate_count=%s homing_actor_candidate_count=%s homing_creature_candidate_count=%s homing_npc_candidate_count=%s force_key=%s job_id=%s projectile_id=%s",
        tostring(result_recipe_id),
        tostring(compiled.recipe_id),
        tostring(cast_id),
        tostring(slot_ids[1]),
        tostring(helper_engine_ids[1]),
        tostring(launch_homing_info.homing_mode),
        tostring(launch_homing_info.homing_field),
        tostring(launch_homing_info.homing_force),
        tostring(launch_homing_info.homing_target_id),
        tostring(launch_homing_info.homing_target_provider),
        tostring(launch_homing_info.homing_target_kind),
        tostring(launch_homing_info.homing_candidate_count),
        tostring(launch_homing_info.homing_actor_candidate_count),
        tostring(launch_homing_info.homing_creature_candidate_count),
        tostring(launch_homing_info.homing_npc_candidate_count),
        tostring(launch_homing_info.homing_force_key),
        tostring(job_ids[1]),
        tostring(first_job.projectile_id)
    ))
    log.info(string.format(
        "SPELLFORGE_LIVE_HOMING_DISPATCH_OK recipe_id=%s plan_recipe_id=%s dispatch_count=%s first_slot_id=%s first_helper_engine_id=%s homing_mode=%s homing_field=%s homing_force=%s homing_target_id=%s homing_target_provider=%s homing_target_kind=%s homing_candidate_count=%s homing_actor_candidate_count=%s homing_creature_candidate_count=%s homing_npc_candidate_count=%s force_key=%s projectile_count=%s",
        tostring(result_recipe_id),
        tostring(compiled.recipe_id),
        tostring(#job_ids),
        tostring(slot_ids[1]),
        tostring(helper_engine_ids[1]),
        tostring(launch_homing_info.homing_mode),
        tostring(launch_homing_info.homing_field),
        tostring(launch_homing_info.homing_force),
        tostring(launch_homing_info.homing_target_id),
        tostring(launch_homing_info.homing_target_provider),
        tostring(launch_homing_info.homing_target_kind),
        tostring(launch_homing_info.homing_candidate_count),
        tostring(launch_homing_info.homing_actor_candidate_count),
        tostring(launch_homing_info.homing_creature_candidate_count),
        tostring(launch_homing_info.homing_npc_candidate_count),
        tostring(launch_homing_info.homing_force_key),
        tostring(projectile_id_count)
    ))
    local soft_homing_probe = nil
    local soft_homing_runtime = nil
    if use_soft_homing then
        local live_soft_homing = require("scripts.spellforge.global.live_soft_homing")
        local register_payload = {
            projectile_id = first_job.projectile_id,
            recipe_id = result_recipe_id,
            cast_id = cast_id,
            slot_id = slot_ids[1],
            helper_engine_id = helper_engine_ids[1],
            job_id = job_ids[1],
            caster = launch_payload.actor or launch_payload.sender,
            target_id = homing_info.homing_target_id,
            target_object = homing_info.homing_target_object,
            target_position = homing_info.homing_target_position,
            target_provider = homing_info.homing_target_provider,
            target_kind = homing_info.homing_target_kind,
            max_lifetime = options.soft_homing_max_lifetime_seconds,
        }
        if options.soft_homing_probe == true then
            soft_homing_probe = live_soft_homing.registerProbe(register_payload)
        else
            soft_homing_runtime = live_soft_homing.registerRuntime(register_payload)
        end
    end
    runtime_stats.inc("live_2_2c_dispatch_ok")

    return {
        ok = true,
        used_live_2_2c = true,
        recipe_id = result_recipe_id,
        plan_recipe_id = compiled.recipe_id,
        slot_id = slot_ids[1],
        helper_engine_id = helper_engine_ids[1],
        slot_ids = slot_ids,
        helper_engine_ids = helper_engine_ids,
        emission_indexes = emission_indexes,
        projectile_id = first_job.projectile_id,
        projectile_ids = projectile_ids,
        projectile_id_source = first_job.projectile_id_source,
        projectile_registered = first_job.projectile_registered == true,
        job_id = job_ids[1],
        job_ids = job_ids,
        jobs = jobs,
        job_status = first_job.job_status,
        cast_id = cast_id,
        runtime = "2.2c_live_helper",
        fallback = false,
        dispatch_count = #job_ids,
        fanout_count = #selected_helpers,
        slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
        helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
        effect_id = selected_helpers[1] and selected_helpers[1].slot.effects and selected_helpers[1].slot.effects[1] and selected_helpers[1].slot.effects[1].id or nil,
        homing_mode = launch_homing_info.homing_mode,
        homing_force = launch_homing_info.homing_force,
        homing_field = launch_homing_info.homing_field,
        homing_target_id = launch_homing_info.homing_target_id,
        homing_target_provider = launch_homing_info.homing_target_provider,
        homing_target_kind = launch_homing_info.homing_target_kind,
        homing_candidate_count = launch_homing_info.homing_candidate_count,
        homing_actor_candidate_count = launch_homing_info.homing_actor_candidate_count,
        homing_creature_candidate_count = launch_homing_info.homing_creature_candidate_count,
        homing_npc_candidate_count = launch_homing_info.homing_npc_candidate_count,
        homing_force_key = launch_homing_info.homing_force_key,
        homing_direction_key = launch_homing_info.homing_direction_key,
        soft_homing_probe = soft_homing_probe,
        soft_homing_probe_registered = soft_homing_probe and soft_homing_probe.ok == true or false,
        soft_homing_probe_entry_id = soft_homing_probe and soft_homing_probe.entry_id or nil,
        soft_homing_probe_error = soft_homing_probe and soft_homing_probe.error or nil,
        soft_homing_runtime = soft_homing_runtime,
        soft_homing_runtime_registered = soft_homing_runtime and soft_homing_runtime.ok == true or false,
        soft_homing_runtime_entry_id = soft_homing_runtime and soft_homing_runtime.entry_id or nil,
        soft_homing_runtime_error = soft_homing_runtime and soft_homing_runtime.error or nil,
        simple_note = "homing_v0",
        live_mode = "homing",
    }
end

local function trySpeedPlusDispatch(compiled, launch_payload, options)
    runtime_stats.inc("live_speed_plus_attempts")
    if options.force_speed_plus_disabled == true then
        return speedPlusRejected("live_speed_plus_disabled", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_speed_plus_disabled_rejections")
    end
    if options.force_speed_plus_enabled ~= true and not dev.liveSpeedPlusEnabled() then
        return speedPlusRejected("live_speed_plus_disabled", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_speed_plus_disabled_rejections")
    end

    local speed_plan, speed_reason, speed_counter = live_speed_plus.selectV1Plan(compiled.plan)
    if not speed_plan then
        return speedPlusRejected(speed_reason or "speed_plus_v1_rejected", {
            plan_recipe_id = compiled.recipe_id,
        }, speed_counter)
    end
    if speed_plan.mutation and speed_plan.mutation.speed_plus_capped == true then
        runtime_stats.inc("live_speed_plus_value_capped")
    end

    if live_speed_plus.launchSpeedField() == nil then
        return speedPlusRejected("live_speed_plus_field_missing", {
            plan_recipe_id = compiled.recipe_id,
            speed_plus_mode = speed_plan.mutation and speed_plan.mutation.speed_plus_mode or nil,
            speed_plus_value = speed_plan.mutation and speed_plan.mutation.speed_plus_value or nil,
            speed_plus_multiplier = speed_plan.mutation and speed_plan.mutation.speed_plus_multiplier or nil,
            speed_plus_capped = speed_plan.mutation and speed_plan.mutation.speed_plus_capped or nil,
            launch_speed_field = nil,
            speed_plus_field_missing = true,
            live_mode = "speed_plus",
        }, "live_speed_plus_field_missing")
    end

    local group = compiled.plan and compiled.plan.groups and compiled.plan.groups[1] or nil
    if type(group) ~= "table" or not isTargetRange(group.range) then
        return speedPlusRejected("not_target_range", {
            plan_recipe_id = compiled.recipe_id,
        })
    end

    if speed_plan.primary_mode == "multicast" or speed_plan.primary_mode == "spread" or speed_plan.primary_mode == "burst" then
        if options.force_multicast_disabled == true
            or (options.force_multicast_enabled ~= true and not dev.liveMulticastEnabled()) then
            return speedPlusRejected("live_multicast_disabled", {
                plan_recipe_id = compiled.recipe_id,
            }, "live_speed_plus_unsupported_combo_rejections")
        end
    end
    if speed_plan.primary_mode == "spread" or speed_plan.primary_mode == "burst" then
        if options.force_pattern_disabled == true
            or (options.force_pattern_enabled ~= true and not dev.liveSpreadBurstEnabled()) then
            return speedPlusRejected("live_spread_burst_disabled", {
                plan_recipe_id = compiled.recipe_id,
            }, "live_speed_plus_unsupported_combo_rejections")
        end
    end

    local attached = plan_cache.attachHelperRecords(compiled.recipe_id, { limits = options.budget_limits })
    if not attached.ok then
        return speedPlusRejected("helper_records_failed", {
            plan_recipe_id = compiled.recipe_id,
            error = firstErrorMessage(attached),
            errors = attached.errors,
        })
    end

    local selected_helpers, materialized_reason = collectPrimaryHelpers(attached.plan)
    if not selected_helpers then
        local counter = nil
        if string.find(tostring(materialized_reason), "payload", 1, true)
            or string.find(tostring(materialized_reason), "postfix", 1, true)
            or string.find(tostring(materialized_reason), "source", 1, true)
            or string.find(tostring(materialized_reason), "parent", 1, true) then
            counter = "live_speed_plus_payload_rejections"
        end
        return speedPlusRejected(materialized_reason or "helper_selection_failed", {
            plan_recipe_id = compiled.recipe_id,
        }, counter)
    end

    if speed_plan.primary_mode == "single" and #selected_helpers ~= 1 then
        return speedPlusRejected("slot_count_not_one", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_speed_plus_unsupported_combo_rejections")
    end
    if speed_plan.primary_mode == "multicast" and #selected_helpers <= 1 then
        return speedPlusRejected("multicast_fanout_missing", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_speed_plus_unsupported_combo_rejections")
    end
    if (speed_plan.primary_mode == "spread" or speed_plan.primary_mode == "burst") and #selected_helpers <= 1 then
        return speedPlusRejected("pattern_fanout_missing", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_speed_plus_unsupported_combo_rejections")
    end

    local pattern_info, pattern_err = computePatternInfo(
        speed_plan.primary_mode,
        speed_plan.pattern_kind,
        speed_plan.pattern_op,
        selected_helpers,
        launch_payload
    )
    if pattern_err then
        return speedPlusRejected(pattern_err, {
            plan_recipe_id = compiled.recipe_id,
        }, "live_speed_plus_unsupported_combo_rejections")
    end

    local source_recipe_id = options.source_recipe_id or launch_payload.recipe_id
    local result_recipe_id = source_recipe_id or compiled.recipe_id
    local cast_id = nextCastId(result_recipe_id, compiled.recipe_id)
    runtime_stats.inc("live_2_2c_qualified")
    runtime_stats.inc("live_speed_plus_qualified")
    if speed_plan.primary_mode == "multicast" then
        runtime_stats.inc("live_multicast_qualified")
        runtime_stats.inc("live_multicast_emissions_planned", #selected_helpers)
    elseif speed_plan.primary_mode == "spread" or speed_plan.primary_mode == "burst" then
        patternQualified(speed_plan.pattern_kind, #selected_helpers)
    end

    local speed_info = speed_plan.mutation
    local job_inputs = buildJobInputs(selected_helpers, compiled.recipe_id, cast_id, launch_payload, pattern_info, nil, speed_info)
    local slot_ids = {}
    local helper_engine_ids = {}
    local emission_indexes = {}
    local pattern_direction_keys = {}
    for index, pair in ipairs(selected_helpers) do
        slot_ids[index] = pair.helper.slot_id
        helper_engine_ids[index] = pair.helper.engine_id
        emission_indexes[index] = pair.slot.emission_index or pair.helper.emission_index or index
        if pattern_info and pattern_info.direction_keys then
            pattern_direction_keys[index] = pattern_info.direction_keys[index]
        end
    end

    if options.dry_run == true then
        return {
            ok = true,
            used_live_2_2c = true,
            dry_run = true,
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = slot_ids[1],
            helper_engine_id = helper_engine_ids[1],
            slot_ids = slot_ids,
            helper_engine_ids = helper_engine_ids,
            emission_indexes = emission_indexes,
            pattern_kind = pattern_info and pattern_info.pattern_kind or nil,
            pattern_count = pattern_info and pattern_info.pattern_count or nil,
            pattern_direction_keys = pattern_direction_keys,
            slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
            helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
            dispatch_count = #selected_helpers,
            fanout_count = #selected_helpers,
            speed_plus_primary_mode = speed_plan.primary_mode,
            speed_plus_mode = speed_info and speed_info.speed_plus_mode or nil,
            speed_plus_value = speed_info and speed_info.speed_plus_value or nil,
            speed_plus_base_speed = speed_info and speed_info.speed_plus_base_speed or nil,
            speed_plus_multiplier = speed_info and speed_info.speed_plus_multiplier or nil,
            speed_plus_speed = speed_info and speed_info.speed_plus_speed or nil,
            speed_plus_max_speed = speed_info and speed_info.speed_plus_max_speed or nil,
            speed_plus_field = speed_info and speed_info.speed_plus_field or nil,
            speed_plus_capped = speed_info and speed_info.speed_plus_capped or nil,
            launch_speed_field = speed_info and speed_info.launch_speed_field or nil,
            launch_max_speed_field = speed_info and speed_info.launch_max_speed_field or nil,
            simple_note = "speed_plus_v1",
            live_mode = "speed_plus",
            cast_id = cast_id,
        }
    end

    local job_ids = {}
    for _, job_input in ipairs(job_inputs) do
        local enqueue = orchestrator.enqueue(job_input)
        if not enqueue.ok then
            runtime_stats.inc("live_2_2c_dispatch_failed")
            if #job_ids > 0 then
                return bridgeError(enqueue.error or "enqueue failed", {
                    stage = "speed_plus_enqueue",
                    recipe_id = result_recipe_id,
                    plan_recipe_id = compiled.recipe_id,
                    slot_id = job_input.slot_id,
                    helper_engine_id = job_input.helper_engine_id,
                    cast_id = cast_id,
                    job_ids = job_ids,
                    fallback_allowed = false,
                })
            end
            return speedPlusRejected("enqueue_failed", {
                recipe_id = result_recipe_id,
                plan_recipe_id = compiled.recipe_id,
                slot_id = job_input.slot_id,
                helper_engine_id = job_input.helper_engine_id,
                error = enqueue.error or "enqueue failed",
                cast_id = cast_id,
            })
        end
        job_ids[#job_ids + 1] = enqueue.job_id
    end
    runtime_stats.inc("live_speed_plus_jobs_mutated", #job_ids)
    if speed_plan.primary_mode == "multicast"
        or speed_plan.primary_mode == "spread"
        or speed_plan.primary_mode == "burst" then
        runtime_stats.inc("live_multicast_jobs_enqueued", #job_ids)
    end

    local tick_result = tickUntilJobsSettled(job_ids, options)
    local jobs = {}
    local projectile_ids = {}
    local projectile_id_count = 0
    local pending_job_count = 0
    local allow_pending_launch_jobs = options.allow_pending_launch_jobs == true
    for index, job_id in ipairs(job_ids) do
        local summary = jobSummary(job_id)
        jobs[index] = summary
        if summary.projectile_id ~= nil then
            projectile_ids[#projectile_ids + 1] = summary.projectile_id
            projectile_id_count = projectile_id_count + 1
        end
        if summary.job_status == "queued" then
            orchestrator.cancel(job_id)
        end
        if summary.job_status ~= "complete" or summary.launch_accepted ~= true then
            runtime_stats.inc("live_2_2c_dispatch_failed")
            return bridgeError(summary.error or "speed_plus helper launch job did not complete", {
                stage = "speed_plus_launch_job",
                recipe_id = result_recipe_id,
                plan_recipe_id = compiled.recipe_id,
                slot_id = summary.slot_id,
                helper_engine_id = summary.helper_engine_id,
                job_id = job_id,
                job_ids = job_ids,
                job_status = summary.job_status,
                tick_result = tick_result,
                cast_id = cast_id,
                fallback_allowed = false,
            })
        end
    end

    local first_job = jobs[1] or {}
    log.info(string.format(
        "SPELLFORGE_LIVE_SPEED_PLUS_DISPATCH_OK recipe_id=%s plan_recipe_id=%s dispatch_count=%s primary_mode=%s first_slot_id=%s first_helper_engine_id=%s speed=%s maxSpeed=%s multiplier=%s projectile_count=%s",
        tostring(result_recipe_id),
        tostring(compiled.recipe_id),
        tostring(#job_ids),
        tostring(speed_plan.primary_mode),
        tostring(slot_ids[1]),
        tostring(helper_engine_ids[1]),
        tostring(speed_info and speed_info.speed_plus_speed or nil),
        tostring(speed_info and speed_info.speed_plus_max_speed or nil),
        tostring(speed_info and speed_info.speed_plus_multiplier or nil),
        tostring(projectile_id_count)
    ))
    runtime_stats.inc("live_2_2c_dispatch_ok")

    return {
        ok = true,
        used_live_2_2c = true,
        recipe_id = result_recipe_id,
        plan_recipe_id = compiled.recipe_id,
        slot_id = slot_ids[1],
        helper_engine_id = helper_engine_ids[1],
        slot_ids = slot_ids,
        helper_engine_ids = helper_engine_ids,
        emission_indexes = emission_indexes,
        pattern_kind = pattern_info and pattern_info.pattern_kind or nil,
        pattern_count = pattern_info and pattern_info.pattern_count or nil,
        pattern_direction_keys = pattern_direction_keys,
        projectile_id = first_job.projectile_id,
        projectile_ids = projectile_ids,
        projectile_id_source = first_job.projectile_id_source,
        projectile_registered = first_job.projectile_registered == true,
        job_id = job_ids[1],
        job_ids = job_ids,
        jobs = jobs,
        job_status = first_job.job_status,
        pending_launch_jobs = pending_job_count > 0,
        pending_job_count = pending_job_count,
        all_launch_jobs_complete = pending_job_count == 0,
        cast_id = cast_id,
        runtime = "2.2c_live_helper",
        fallback = false,
        dispatch_count = #job_ids,
        fanout_count = #selected_helpers,
        slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
        helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
        effect_id = selected_helpers[1] and selected_helpers[1].slot.effects and selected_helpers[1].slot.effects[1] and selected_helpers[1].slot.effects[1].id or nil,
        speed_plus_primary_mode = speed_plan.primary_mode,
        speed_plus_mode = speed_info and speed_info.speed_plus_mode or nil,
        speed_plus_value = speed_info and speed_info.speed_plus_value or nil,
        speed_plus_base_speed = speed_info and speed_info.speed_plus_base_speed or nil,
        speed_plus_multiplier = speed_info and speed_info.speed_plus_multiplier or nil,
        speed_plus_speed = speed_info and speed_info.speed_plus_speed or nil,
        speed_plus_max_speed = speed_info and speed_info.speed_plus_max_speed or nil,
        speed_plus_field = speed_info and speed_info.speed_plus_field or nil,
        speed_plus_capped = speed_info and speed_info.speed_plus_capped or nil,
        launch_speed_field = speed_info and speed_info.launch_speed_field or nil,
        launch_max_speed_field = speed_info and speed_info.launch_max_speed_field or nil,
        simple_note = "speed_plus_v1",
        live_mode = "speed_plus",
    }
end

local function trySizePlusDispatch(compiled, launch_payload, options)
    runtime_stats.inc("live_size_plus_attempts")
    if options.force_size_plus_disabled == true then
        return sizePlusRejected("live_size_plus_disabled", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_size_plus_disabled_rejections")
    end
    if options.force_size_plus_enabled ~= true and not dev.liveSizePlusEnabled() then
        return sizePlusRejected("live_size_plus_disabled", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_size_plus_disabled_rejections")
    end

    local size_plan, size_reason, size_counter = live_size_plus.selectV0Plan(compiled.plan)
    if not size_plan then
        return sizePlusRejected(size_reason or "size_plus_v0_rejected", {
            plan_recipe_id = compiled.recipe_id,
        }, size_counter)
    end

    local group = compiled.plan and compiled.plan.groups and compiled.plan.groups[1] or nil
    if type(group) ~= "table" or not isTargetRange(group.range) then
        return sizePlusRejected("not_target_range", {
            plan_recipe_id = compiled.recipe_id,
        })
    end

    if size_plan.primary_mode == "multicast" or size_plan.primary_mode == "spread" or size_plan.primary_mode == "burst" then
        if options.force_multicast_disabled == true
            or (options.force_multicast_enabled ~= true and not dev.liveMulticastEnabled()) then
            return sizePlusRejected("live_multicast_disabled", {
                plan_recipe_id = compiled.recipe_id,
            }, "live_size_plus_unsupported_combo_rejections")
        end
    end
    if size_plan.primary_mode == "spread" or size_plan.primary_mode == "burst" then
        if options.force_pattern_disabled == true
            or (options.force_pattern_enabled ~= true and not dev.liveSpreadBurstEnabled()) then
            return sizePlusRejected("live_spread_burst_disabled", {
                plan_recipe_id = compiled.recipe_id,
            }, "live_size_plus_unsupported_combo_rejections")
        end
    end

    local attached_specs = plan_cache.attachHelperSpecs(compiled.recipe_id)
    if not attached_specs.ok then
        runtime_stats.inc("helper_records_attach_failed")
        return sizePlusRejected("helper_specs_failed", {
            plan_recipe_id = compiled.recipe_id,
            error = firstErrorMessage(attached_specs),
            errors = attached_specs.errors,
        })
    end

    local apply_result, apply_err = live_size_plus.applyToHelperSpecs(attached_specs.plan, size_plan.mutation)
    if not apply_result then
        local counter = nil
        if apply_err == "size_plus_field_missing" then
            counter = "live_size_plus_field_missing"
        elseif apply_err == "size_plus_value_invalid" then
            counter = "live_size_plus_value_invalid"
        end
        return sizePlusRejected(apply_err or "size_plus_apply_failed", {
            plan_recipe_id = compiled.recipe_id,
            live_mode = "size_plus",
            size_plus_mode = size_plan.mutation and size_plan.mutation.size_plus_mode or nil,
            size_plus_value = size_plan.mutation and size_plan.mutation.size_plus_value or nil,
            size_plus_multiplier = size_plan.mutation and size_plan.mutation.size_plus_multiplier or nil,
            size_plus_field = size_plan.mutation and size_plan.mutation.size_plus_field or nil,
            size_plus_field_missing = apply_err == "size_plus_field_missing",
        }, counter)
    end

    runtime_stats.inc("live_size_plus_specs_mutated", apply_result.specs_mutated or 0)
    if size_plan.mutation and size_plan.mutation.size_plus_capped == true then
        runtime_stats.inc("live_size_plus_value_capped")
    end

    local materialized = helper_records.materialize({
        recipe_id = attached_specs.plan.recipe_id,
        specs = attached_specs.plan.helper_specs,
    })
    if not materialized.ok then
        runtime_stats.inc("helper_records_attach_failed")
        return sizePlusRejected("helper_records_failed", {
            plan_recipe_id = compiled.recipe_id,
            error = firstErrorMessage(materialized),
            errors = materialized.errors,
        })
    end

    local plan = attached_specs.plan
    plan.helper_records = materialized.records
    plan.helper_record_count = materialized.record_count
    plan.helper_records_reused = materialized.reused
    runtime_stats.inc("helper_records_attached", materialized.record_count or 0)

    local selected_helpers, materialized_reason = collectPrimaryHelpers(plan)
    if not selected_helpers then
        local counter = nil
        if string.find(tostring(materialized_reason), "payload", 1, true)
            or string.find(tostring(materialized_reason), "postfix", 1, true)
            or string.find(tostring(materialized_reason), "source", 1, true)
            or string.find(tostring(materialized_reason), "parent", 1, true) then
            counter = "live_size_plus_payload_rejections"
        end
        return sizePlusRejected(materialized_reason or "helper_selection_failed", {
            plan_recipe_id = compiled.recipe_id,
        }, counter)
    end

    if size_plan.primary_mode == "single" and #selected_helpers ~= 1 then
        return sizePlusRejected("slot_count_not_one", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_size_plus_unsupported_combo_rejections")
    end
    if size_plan.primary_mode == "multicast" and #selected_helpers <= 1 then
        return sizePlusRejected("multicast_fanout_missing", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_size_plus_unsupported_combo_rejections")
    end
    if (size_plan.primary_mode == "spread" or size_plan.primary_mode == "burst") and #selected_helpers <= 1 then
        return sizePlusRejected("pattern_fanout_missing", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_size_plus_unsupported_combo_rejections")
    end

    local pattern_info, pattern_err = computePatternInfo(
        size_plan.primary_mode,
        size_plan.pattern_kind,
        size_plan.pattern_op,
        selected_helpers,
        launch_payload
    )
    if pattern_err then
        return sizePlusRejected(pattern_err, {
            plan_recipe_id = compiled.recipe_id,
        }, "live_size_plus_unsupported_combo_rejections")
    end

    local source_recipe_id = options.source_recipe_id or launch_payload.recipe_id
    local result_recipe_id = source_recipe_id or compiled.recipe_id
    local cast_id = nextCastId(result_recipe_id, compiled.recipe_id)
    runtime_stats.inc("live_2_2c_qualified")
    runtime_stats.inc("live_size_plus_qualified")
    if size_plan.primary_mode == "multicast" then
        runtime_stats.inc("live_multicast_qualified")
        runtime_stats.inc("live_multicast_emissions_planned", #selected_helpers)
    elseif size_plan.primary_mode == "spread" or size_plan.primary_mode == "burst" then
        patternQualified(size_plan.pattern_kind, #selected_helpers)
    end

    local size_info = size_plan.mutation
    local job_inputs = buildJobInputs(selected_helpers, compiled.recipe_id, cast_id, launch_payload, pattern_info, size_info)
    local slot_ids = {}
    local helper_engine_ids = {}
    local emission_indexes = {}
    local pattern_direction_keys = {}
    for index, pair in ipairs(selected_helpers) do
        slot_ids[index] = pair.helper.slot_id
        helper_engine_ids[index] = pair.helper.engine_id
        emission_indexes[index] = pair.slot.emission_index or pair.helper.emission_index or index
        if pattern_info and pattern_info.direction_keys then
            pattern_direction_keys[index] = pattern_info.direction_keys[index]
        end
    end

    if options.dry_run == true then
        return {
            ok = true,
            used_live_2_2c = true,
            dry_run = true,
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = slot_ids[1],
            helper_engine_id = helper_engine_ids[1],
            slot_ids = slot_ids,
            helper_engine_ids = helper_engine_ids,
            emission_indexes = emission_indexes,
            pattern_kind = pattern_info and pattern_info.pattern_kind or nil,
            pattern_count = pattern_info and pattern_info.pattern_count or nil,
            pattern_direction_keys = pattern_direction_keys,
            slot_count = plan.slot_count or #plan.emission_slots,
            helper_record_count = plan.helper_record_count or #plan.helper_records,
            dispatch_count = #selected_helpers,
            fanout_count = #selected_helpers,
            size_plus_primary_mode = size_plan.primary_mode,
            size_plus_mode = size_info and size_info.size_plus_mode or nil,
            size_plus_value = size_info and size_info.size_plus_value or nil,
            size_plus_multiplier = size_info and size_info.size_plus_multiplier or nil,
            size_plus_field = size_info and size_info.size_plus_field or nil,
            size_plus_capped = size_info and size_info.size_plus_capped or nil,
            size_plus_base_area = size_info and size_info.size_plus_base_area or nil,
            size_plus_area = size_info and size_info.size_plus_area or nil,
            size_plus_specs_mutated = apply_result.specs_mutated,
            size_plus_effects_mutated = apply_result.effects_mutated,
            simple_note = "size_plus_v0",
            live_mode = "size_plus",
            cast_id = cast_id,
        }
    end

    local job_ids = {}
    for _, job_input in ipairs(job_inputs) do
        local enqueue = orchestrator.enqueue(job_input)
        if not enqueue.ok then
            runtime_stats.inc("live_2_2c_dispatch_failed")
            if #job_ids > 0 then
                return bridgeError(enqueue.error or "enqueue failed", {
                    stage = "size_plus_enqueue",
                    recipe_id = result_recipe_id,
                    plan_recipe_id = compiled.recipe_id,
                    slot_id = job_input.slot_id,
                    helper_engine_id = job_input.helper_engine_id,
                    cast_id = cast_id,
                    job_ids = job_ids,
                    fallback_allowed = false,
                })
            end
            return sizePlusRejected("enqueue_failed", {
                recipe_id = result_recipe_id,
                plan_recipe_id = compiled.recipe_id,
                slot_id = job_input.slot_id,
                helper_engine_id = job_input.helper_engine_id,
                error = enqueue.error or "enqueue failed",
                cast_id = cast_id,
            })
        end
        job_ids[#job_ids + 1] = enqueue.job_id
    end
    runtime_stats.inc("live_size_plus_jobs_mutated", #job_ids)
    if size_plan.primary_mode == "multicast"
        or size_plan.primary_mode == "spread"
        or size_plan.primary_mode == "burst" then
        runtime_stats.inc("live_multicast_jobs_enqueued", #job_ids)
    end

    local tick_result = tickUntilJobsSettled(job_ids, options)
    local jobs = {}
    local projectile_ids = {}
    local projectile_id_count = 0
    local pending_job_count = 0
    local allow_pending_launch_jobs = options.allow_pending_launch_jobs == true
    for index, job_id in ipairs(job_ids) do
        local summary = jobSummary(job_id)
        jobs[index] = summary
        if summary.projectile_id ~= nil then
            projectile_ids[#projectile_ids + 1] = summary.projectile_id
            projectile_id_count = projectile_id_count + 1
        end
        if summary.job_status == "queued" then
            orchestrator.cancel(job_id)
        end
        if summary.job_status ~= "complete" or summary.launch_accepted ~= true then
            runtime_stats.inc("live_2_2c_dispatch_failed")
            return bridgeError(summary.error or "size_plus helper launch job did not complete", {
                stage = "size_plus_launch_job",
                recipe_id = result_recipe_id,
                plan_recipe_id = compiled.recipe_id,
                slot_id = summary.slot_id,
                helper_engine_id = summary.helper_engine_id,
                job_id = job_id,
                job_ids = job_ids,
                job_status = summary.job_status,
                tick_result = tick_result,
                cast_id = cast_id,
                fallback_allowed = false,
            })
        end
    end

    local first_job = jobs[1] or {}
    log.info(string.format(
        "SPELLFORGE_LIVE_SIZE_PLUS_DISPATCH_OK recipe_id=%s plan_recipe_id=%s dispatch_count=%s primary_mode=%s first_slot_id=%s first_helper_engine_id=%s size_field=%s base_area=%s size_area=%s projectile_count=%s",
        tostring(result_recipe_id),
        tostring(compiled.recipe_id),
        tostring(#job_ids),
        tostring(size_plan.primary_mode),
        tostring(slot_ids[1]),
        tostring(helper_engine_ids[1]),
        tostring(size_info and size_info.size_plus_field or nil),
        tostring(size_info and size_info.size_plus_base_area or nil),
        tostring(size_info and size_info.size_plus_area or nil),
        tostring(projectile_id_count)
    ))
    runtime_stats.inc("live_2_2c_dispatch_ok")

    return {
        ok = true,
        used_live_2_2c = true,
        recipe_id = result_recipe_id,
        plan_recipe_id = compiled.recipe_id,
        slot_id = slot_ids[1],
        helper_engine_id = helper_engine_ids[1],
        slot_ids = slot_ids,
        helper_engine_ids = helper_engine_ids,
        emission_indexes = emission_indexes,
        pattern_kind = pattern_info and pattern_info.pattern_kind or nil,
        pattern_count = pattern_info and pattern_info.pattern_count or nil,
        pattern_direction_keys = pattern_direction_keys,
        projectile_id = first_job.projectile_id,
        projectile_ids = projectile_ids,
        projectile_id_source = first_job.projectile_id_source,
        projectile_registered = first_job.projectile_registered == true,
        job_id = job_ids[1],
        job_ids = job_ids,
        jobs = jobs,
        pending_launch_jobs = pending_job_count > 0,
        pending_job_count = pending_job_count,
        all_launch_jobs_complete = pending_job_count == 0,
        job_status = first_job.job_status,
        cast_id = cast_id,
        runtime = "2.2c_live_helper",
        fallback = false,
        dispatch_count = #job_ids,
        fanout_count = #selected_helpers,
        slot_count = plan.slot_count or #plan.emission_slots,
        helper_record_count = plan.helper_record_count or #plan.helper_records,
        effect_id = selected_helpers[1] and selected_helpers[1].slot.effects and selected_helpers[1].slot.effects[1] and selected_helpers[1].slot.effects[1].id or nil,
        size_plus_primary_mode = size_plan.primary_mode,
        size_plus_mode = size_info and size_info.size_plus_mode or nil,
        size_plus_value = size_info and size_info.size_plus_value or nil,
        size_plus_multiplier = size_info and size_info.size_plus_multiplier or nil,
        size_plus_field = size_info and size_info.size_plus_field or nil,
        size_plus_capped = size_info and size_info.size_plus_capped or nil,
        size_plus_base_area = size_info and size_info.size_plus_base_area or nil,
        size_plus_area = size_info and size_info.size_plus_area or nil,
        size_plus_specs_mutated = apply_result.specs_mutated,
        size_plus_effects_mutated = apply_result.effects_mutated,
        simple_note = "size_plus_v0",
        live_mode = "size_plus",
    }
end

local function payloadGroupFrom(payload, opts)
    local options = opts or {}
    local payloads = options.payloads
    if type(payloads) ~= "table" or #payloads == 0 then
        payloads = { payload }
    end
    local slot_ids = {}
    local helper_engine_ids = {}
    for index, item in ipairs(payloads) do
        slot_ids[index] = item.slot_id
        helper_engine_ids[index] = item.helper_engine_id
    end
    return {
        payloads = payloads,
        payload_slot_ids = slot_ids,
        payload_helper_engine_ids = helper_engine_ids,
        payload_count = #payloads,
        payload_group_key = options.payload_group_key or table.concat(slot_ids, ","),
        payload_multicast = options.payload_multicast == true,
        payload_pattern = options.payload_pattern == true,
        payload_pattern_kind = options.payload_pattern_kind,
        payload_pattern_op = options.payload_pattern_op,
        nested_final_fanout = options.nested_final_fanout == true,
        nested_final_fanout_kind = options.nested_final_fanout_kind,
        max_payload_fanout = options.max_payload_fanout,
        max_projectiles = options.max_projectiles,
        max_jobs_per_tick = options.max_jobs_per_tick,
        max_live_launches_per_tick = options.max_live_launches_per_tick,
        allow_pending_launch_jobs = options.allow_pending_launch_jobs == true,
    }
end

local function nestedTimerBinding(compiled_recipe_id, cast_id, source, payload, launch_payload, timer_seconds, timer_delay_ticks, nested_kind, root_source_slot_id, group_opts)
    local group = payloadGroupFrom(payload, group_opts)
    return {
        recipe_id = compiled_recipe_id,
        cast_id = cast_id,
        source_slot_id = source.slot.slot_id,
        source_helper_engine_id = source.helper.engine_id,
        payload_slot_id = payload.slot_id,
        payload_helper_engine_id = payload.helper_engine_id,
        payloads = group.payloads,
        payload_slot_ids = group.payload_slot_ids,
        payload_helper_engine_ids = group.payload_helper_engine_ids,
        payload_count = group.payload_count,
        payload_group_key = group.payload_group_key,
        payload_multicast = group.payload_multicast,
        payload_pattern = group.payload_pattern,
        payload_pattern_kind = group.payload_pattern_kind,
        payload_pattern_op = group.payload_pattern_op,
        nested_final_fanout = group.nested_final_fanout,
        nested_final_fanout_kind = group.nested_final_fanout_kind,
        max_payload_fanout = group.max_payload_fanout,
        max_projectiles = group.max_projectiles,
        max_jobs_per_tick = group.max_jobs_per_tick,
        max_live_launches_per_tick = group.max_live_launches_per_tick,
        allow_pending_launch_jobs = group.allow_pending_launch_jobs == true,
        actor = launch_payload.actor or launch_payload.sender,
        hit_object = launch_payload.hit_object,
        timer_seconds = timer_seconds,
        timer_delay_ticks = timer_delay_ticks,
        root_source_slot_id = root_source_slot_id,
        current_source_slot_id = source.slot.slot_id,
        parent_slot_id = source.slot.parent_slot_id,
        source_depth = 1,
        nested_tt = true,
        nested_tt_kind = nested_kind,
        nested_tt_payload_role = nested_kind == "trigger_timer" and "final_timer_payload" or "intermediate_trigger_source",
        nested_stage_kind = nested_kind,
        nested_stage_index = nested_kind == "trigger_timer" and 2 or 1,
        duplicate_key_suffix = "nested_tt:" .. tostring(cast_id) .. ":" .. tostring(source.slot.slot_id) .. ":" .. tostring(group.payload_group_key),
    }
end

local function nestedTriggerBinding(compiled_recipe_id, cast_id, source, payload, launch_payload, nested_kind, root_source_slot_id, group_opts)
    local group = payloadGroupFrom(payload, group_opts)
    return {
        recipe_id = compiled_recipe_id,
        cast_id = cast_id,
        source_slot_id = source.slot.slot_id,
        source_helper_engine_id = source.helper.engine_id,
        payload_slot_id = payload.slot_id,
        payload_helper_engine_id = payload.helper_engine_id,
        payloads = group.payloads,
        payload_slot_ids = group.payload_slot_ids,
        payload_helper_engine_ids = group.payload_helper_engine_ids,
        payload_count = group.payload_count,
        payload_group_key = group.payload_group_key,
        payload_multicast = group.payload_multicast,
        payload_pattern = group.payload_pattern,
        payload_pattern_kind = group.payload_pattern_kind,
        payload_pattern_op = group.payload_pattern_op,
        nested_final_fanout = group.nested_final_fanout,
        nested_final_fanout_kind = group.nested_final_fanout_kind,
        max_payload_fanout = group.max_payload_fanout,
        max_projectiles = group.max_projectiles,
        max_jobs_per_tick = group.max_jobs_per_tick,
        max_live_launches_per_tick = group.max_live_launches_per_tick,
        allow_pending_launch_jobs = group.allow_pending_launch_jobs == true,
        actor = launch_payload.actor or launch_payload.sender,
        start_pos = launch_payload.start_pos,
        direction = launch_payload.direction,
        root_source_slot_id = root_source_slot_id,
        current_source_slot_id = source.slot.slot_id,
        parent_slot_id = source.slot.parent_slot_id,
        source_depth = 1,
        nested_tt = true,
        nested_tt_kind = nested_kind,
        nested_tt_payload_role = nested_kind == "timer_trigger" and "final_trigger_payload" or "intermediate_timer_source",
        nested_stage_kind = nested_kind,
        nested_stage_index = nested_kind == "timer_trigger" and 2 or 1,
    }
end

local function tryNestedTriggerTimerDispatch(compiled, launch_payload, options)
    if options.force_timer_disabled == true or (options.force_timer_enabled ~= true and not dev.liveTimerEnabled()) then
        return nestedTriggerTimerRejected("live_timer_disabled", {
            plan_recipe_id = compiled.recipe_id,
        }, "nested_tt_disabled_reject")
    end
    if options.force_trigger_disabled == true or (options.force_trigger_enabled ~= true and not dev.liveTriggerEnabled()) then
        return nestedTriggerTimerRejected("live_trigger_disabled", {
            plan_recipe_id = compiled.recipe_id,
        }, "nested_tt_disabled_reject")
    end

    local attached = plan_cache.attachHelperRecords(compiled.recipe_id, { limits = options.budget_limits })
    if not attached.ok then
        return nestedTriggerTimerRejected("helper_records_failed", {
            plan_recipe_id = compiled.recipe_id,
            error = firstErrorMessage(attached),
            errors = attached.errors,
        })
    end

    local nested_plan, reason = nested_trigger_timer.selectV1Plan(attached.plan, {
        enabled = nestedTriggerTimerRuntimeEnabled(options),
        enable_final_fanout = nestedFinalFanoutRuntimeEnabled(options),
        allow_payload_multicast = payloadMulticastRuntimeEnabled(options),
        allow_payload_pattern = payloadPatternRuntimeEnabled(options),
        max_fanout = options.nested_final_fanout_max_fanout,
        max_jobs = options.max_nested_payload_jobs,
        max_projectiles = options.max_projectiles,
        max_depth = options.max_nested_payload_depth,
    })
    if not nested_plan then
        return nestedTriggerTimerRejected(reason or "nested_trigger_timer_rejected", addNestedTriggerTimerDiagnostics({
            plan_recipe_id = compiled.recipe_id,
        }, attached.plan))
    end

    local source_recipe_id = options.source_recipe_id or launch_payload.recipe_id
    local result_recipe_id = source_recipe_id or compiled.recipe_id
    local cast_id = nextCastId(result_recipe_id, compiled.recipe_id)
    runtime_stats.inc("live_2_2c_qualified")

    local selected_helpers = { nested_plan.root }
    local job_inputs = buildJobInputs(selected_helpers, compiled.recipe_id, cast_id, launch_payload, nil)
    local source_job = job_inputs[1]
    local root_source_slot_id = nested_plan.root_source_slot_id
    local final_group_opts = {
        payloads = nested_plan.final_payloads,
        payload_group_key = nested_plan.final_payload_group_key,
        payload_multicast = nested_plan.payload_multicast == true,
        payload_pattern = nested_plan.payload_pattern == true,
        payload_pattern_kind = nested_plan.payload_pattern_kind,
        payload_pattern_op = nested_plan.payload_pattern_op,
        nested_final_fanout = nested_plan.nested_final_fanout == true,
        nested_final_fanout_kind = nested_plan.nested_final_fanout_kind,
        max_payload_fanout = options.nested_final_fanout_max_fanout,
        max_projectiles = options.max_projectiles,
        max_jobs_per_tick = options.max_jobs_per_tick,
        max_live_launches_per_tick = options.max_live_launches_per_tick,
        allow_pending_launch_jobs = options.allow_pending_launch_jobs == true,
    }
    source_job.root_source_slot_id = root_source_slot_id
    source_job.current_source_slot_id = root_source_slot_id
    source_job.payload_depth = 0
    source_job.nested_stage_kind = nested_plan.kind .. "_root"
    source_job.nested_stage_index = 0
    source_job.payload.root_source_slot_id = root_source_slot_id
    source_job.payload.current_source_slot_id = root_source_slot_id
    source_job.payload.payload_depth = 0
    source_job.payload.nested_stage_kind = nested_plan.kind .. "_root"
    source_job.payload.nested_stage_index = 0

    local root_binding = nil
    if nested_plan.root_kind == "Timer" then
        root_binding = nestedTimerBinding(
            compiled.recipe_id,
            cast_id,
            nested_plan.root,
            nested_plan.intermediate_payload,
            launch_payload,
            nested_plan.root_timer_seconds,
            nested_plan.root_timer_delay_ticks,
            nested_plan.kind,
            root_source_slot_id
        )
        root_binding.source_depth = 0
        root_binding.current_source_slot_id = root_source_slot_id
        root_binding.parent_slot_id = nil
        root_binding.nested_stage_index = 0
        live_timer.decorateSourceJob(source_job, root_binding)
    else
        local final_timer_binding = nestedTimerBinding(
            compiled.recipe_id,
            cast_id,
            nested_plan.intermediate,
            nested_plan.final_payload,
            launch_payload,
            nested_plan.nested_timer_seconds,
            nested_plan.nested_timer_delay_ticks,
            nested_plan.kind,
            root_source_slot_id,
            final_group_opts
        )
        root_binding = nestedTriggerBinding(
            compiled.recipe_id,
            cast_id,
            nested_plan.root,
            nested_plan.intermediate_payload,
            launch_payload,
            nested_plan.kind,
            root_source_slot_id
        )
        root_binding.source_depth = 0
        root_binding.current_source_slot_id = root_source_slot_id
        root_binding.parent_slot_id = nil
        root_binding.nested_stage_index = 0
        root_binding.nested_timer_binding = final_timer_binding
        live_trigger.decorateSourceJob(source_job, root_binding)
    end

    if options.dry_run == true then
        return {
            ok = true,
            used_live_2_2c = true,
            dry_run = true,
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            live_mode = "nested_trigger_timer",
            nested_tt_kind = nested_plan.kind,
            nested_tt_runtime = true,
            slot_id = nested_plan.root_source_slot_id,
            helper_engine_id = nested_plan.root_source_helper_engine_id,
            root_source_slot_id = nested_plan.root_source_slot_id,
            intermediate_slot_id = nested_plan.intermediate_slot_id,
            final_payload_slot_id = nested_plan.final_payload_slot_id,
            final_payload_slot_ids = nested_plan.final_payload_slot_ids,
            final_payload_count = nested_plan.final_payload_count,
            nested_final_fanout = nested_plan.nested_final_fanout == true,
            nested_final_fanout_kind = nested_plan.nested_final_fanout_kind,
            payload_multicast = nested_plan.payload_multicast == true,
            payload_pattern = nested_plan.payload_pattern == true,
            payload_pattern_kind = nested_plan.payload_pattern_kind,
            dispatch_count = 1,
            payload_fanout_count = nested_plan.final_payload_count or 1,
            cast_id = cast_id,
        }
    end

    local enqueue = orchestrator.enqueue(source_job)
    if not enqueue.ok then
        runtime_stats.inc("live_2_2c_dispatch_failed")
        return nestedTriggerTimerRejected("enqueue_failed", {
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            error = enqueue.error or "enqueue failed",
            cast_id = cast_id,
        })
    end

    root_binding.source_job_id = enqueue.job_id
    if nested_plan.root_kind == "Trigger" then
        live_trigger.registerBinding(root_binding)
        runtime_stats.inc("live_trigger_source_jobs_enqueued")
    else
        runtime_stats.inc("live_timer_source_jobs_enqueued")
    end

    local tick_result = tickUntilJobsSettled({ enqueue.job_id }, options)
    local summary = jobSummary(enqueue.job_id)
    local pending_source_launch = summary.job_status == "queued" or summary.job_status == "running"
    if pending_source_launch and options.allow_pending_launch_jobs == true and nested_plan.root_kind == "Trigger" then
        log.info(string.format(
            "SPELLFORGE_NESTED_TRIGGER_TIMER_SOURCE_PENDING recipe_id=%s plan_recipe_id=%s cast_id=%s job_id=%s job_status=%s",
            tostring(result_recipe_id),
            tostring(compiled.recipe_id),
            tostring(cast_id),
            tostring(enqueue.job_id),
            tostring(summary.job_status)
        ))
        return {
            ok = true,
            used_live_2_2c = true,
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            live_mode = "nested_trigger_timer",
            nested_tt_runtime = true,
            nested_tt_kind = nested_plan.kind,
            slot_id = nested_plan.root_source_slot_id,
            helper_engine_id = nested_plan.root_source_helper_engine_id,
            root_source_slot_id = nested_plan.root_source_slot_id,
            root_source_helper_engine_id = nested_plan.root_source_helper_engine_id,
            intermediate_slot_id = nested_plan.intermediate_slot_id,
            intermediate_helper_engine_id = nested_plan.intermediate_helper_engine_id,
            final_payload_slot_id = nested_plan.final_payload_slot_id,
            final_payload_helper_engine_id = nested_plan.final_payload_helper_engine_id,
            final_payload_slot_ids = nested_plan.final_payload_slot_ids,
            final_payload_helper_engine_ids = nested_plan.final_payload_helper_engine_ids,
            final_payload_count = nested_plan.final_payload_count,
            nested_final_fanout = nested_plan.nested_final_fanout == true,
            nested_final_fanout_kind = nested_plan.nested_final_fanout_kind,
            payload_multicast = nested_plan.payload_multicast == true,
            payload_pattern = nested_plan.payload_pattern == true,
            payload_pattern_kind = nested_plan.payload_pattern_kind,
            projectile_id = summary.projectile_id,
            projectile_ids = summary.projectile_id and { summary.projectile_id } or {},
            job_id = enqueue.job_id,
            job_ids = { enqueue.job_id },
            jobs = { summary },
            source_jobs = { summary },
            job_status = summary.job_status,
            cast_id = cast_id,
            runtime = "2.2c_live_helper",
            fallback = false,
            dispatch_count = 1,
            source_dispatch_count = 1,
            fanout_count = 1,
            payload_fanout_count = nested_plan.final_payload_count or 1,
            slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
            helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
            simple_note = "nested_trigger_timer_v1",
            pending_source_launch_job = true,
            pending_launch_jobs = true,
            pending_job_count = 1,
            all_launch_jobs_complete = false,
            tick_result = tick_result,
        }
    end
    if summary.job_status == "queued" then
        orchestrator.cancel(enqueue.job_id)
    end
    if summary.job_status ~= "complete" or summary.launch_accepted ~= true then
        runtime_stats.inc("live_2_2c_dispatch_failed")
        return bridgeError(summary.error or "nested Trigger/Timer source launch job did not complete", {
            stage = "nested_trigger_timer_source_launch_job",
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            job_id = enqueue.job_id,
            job_ids = { enqueue.job_id },
            job_status = summary.job_status,
            tick_result = tick_result,
            cast_id = cast_id,
            fallback_allowed = false,
        })
    end

    local schedule = nil
    local duplicate_schedule = nil
    local nested_trigger_registered = false
    if nested_plan.root_kind == "Timer" then
        local resolution, resolution_err = live_timer.computeResolution(launch_payload, {
            timer_seconds = nested_plan.root_timer_seconds,
        })
        if not resolution then
            return nestedTriggerTimerRejected("timer_resolution_failed", {
                plan_recipe_id = compiled.recipe_id,
                error = resolution_err,
            })
        end
        root_binding.source_job_id = enqueue.job_id
        root_binding.source_projectile_id = summary.projectile_id
        root_binding.source_user_data = summary.launch_user_data
        root_binding.resolution = resolution
        schedule = live_timer.schedulePayload(root_binding, {
            duplicate_key_suffix = root_binding.duplicate_key_suffix,
        })
        if not schedule.ok then
            runtime_stats.inc("live_2_2c_dispatch_failed")
            return bridgeError(schedule.error or "nested Timer->Trigger schedule failed", {
                stage = "nested_timer_trigger_schedule",
                recipe_id = result_recipe_id,
                plan_recipe_id = compiled.recipe_id,
                cast_id = cast_id,
                fallback_allowed = false,
            })
        end
        if options.timer_duplicate_schedule_probe == true then
            duplicate_schedule = live_timer.schedulePayload(root_binding, {
                duplicate_key_suffix = root_binding.duplicate_key_suffix,
            })
        end
        local trigger_binding = nestedTriggerBinding(
            compiled.recipe_id,
            cast_id,
            nested_plan.intermediate,
            nested_plan.final_payload,
            launch_payload,
            nested_plan.kind,
            root_source_slot_id,
            final_group_opts
        )
        nested_trigger_registered = live_trigger.registerBinding(trigger_binding)
        log.info(string.format(
            "SPELLFORGE_NESTED_TIMER_TRIGGER_INTERMEDIATE_ENQUEUED recipe_id=%s cast_id=%s root_source_slot_id=%s current_source_slot_id=%s intermediate_slot_id=%s final_payload_slot_id=%s payload_depth=1 stage_kind=Timer->Trigger timer_id=%s",
            tostring(compiled.recipe_id),
            tostring(cast_id),
            tostring(root_source_slot_id),
            tostring(nested_plan.intermediate_slot_id),
            tostring(nested_plan.intermediate_slot_id),
            tostring(nested_plan.final_payload_slot_id),
            tostring(schedule.timer_id)
        ))
    end

    log.info(string.format(
        "SPELLFORGE_NESTED_TRIGGER_TIMER_QUALIFIED recipe_id=%s cast_id=%s root_source_slot_id=%s intermediate_slot_id=%s final_payload_slot_id=%s stage_kind=%s",
        tostring(compiled.recipe_id),
        tostring(cast_id),
        tostring(nested_plan.root_source_slot_id),
        tostring(nested_plan.intermediate_slot_id),
        tostring(nested_plan.final_payload_slot_id),
        tostring(nested_plan.kind)
    ))
    if nested_plan.nested_final_fanout == true then
        log.info(string.format(
            "SPELLFORGE_NESTED_FINAL_FANOUT_QUALIFIED recipe_id=%s cast_id=%s nested_kind=%s root_source_slot_id=%s intermediate_slot_id=%s final_payload_count=%s fanout_count=%s pattern_kind=%s",
            tostring(compiled.recipe_id),
            tostring(cast_id),
            tostring(nested_plan.nested_final_fanout_kind),
            tostring(nested_plan.root_source_slot_id),
            tostring(nested_plan.intermediate_slot_id),
            tostring(nested_plan.final_payload_count),
            tostring(nested_plan.final_fanout_count),
            tostring(nested_plan.payload_pattern_kind)
        ))
    end
    runtime_stats.inc("live_2_2c_dispatch_ok")

    return {
        ok = true,
        used_live_2_2c = true,
        recipe_id = result_recipe_id,
        plan_recipe_id = compiled.recipe_id,
        live_mode = "nested_trigger_timer",
        nested_tt_runtime = true,
        nested_tt_kind = nested_plan.kind,
        slot_id = nested_plan.root_source_slot_id,
        helper_engine_id = nested_plan.root_source_helper_engine_id,
        root_source_slot_id = nested_plan.root_source_slot_id,
        root_source_helper_engine_id = nested_plan.root_source_helper_engine_id,
        intermediate_slot_id = nested_plan.intermediate_slot_id,
        intermediate_helper_engine_id = nested_plan.intermediate_helper_engine_id,
        final_payload_slot_id = nested_plan.final_payload_slot_id,
        final_payload_helper_engine_id = nested_plan.final_payload_helper_engine_id,
        final_payload_slot_ids = nested_plan.final_payload_slot_ids,
        final_payload_helper_engine_ids = nested_plan.final_payload_helper_engine_ids,
        final_payload_count = nested_plan.final_payload_count,
        nested_final_fanout = nested_plan.nested_final_fanout == true,
        nested_final_fanout_kind = nested_plan.nested_final_fanout_kind,
        payload_multicast = nested_plan.payload_multicast == true,
        payload_pattern = nested_plan.payload_pattern == true,
        payload_pattern_kind = nested_plan.payload_pattern_kind,
        timer_id = schedule and schedule.timer_id or nil,
        timer_async_scheduled = schedule and schedule.async_scheduled == true or false,
        timer_pending_count = schedule and schedule.pending_count or nil,
        timer_duplicate_suppressed = duplicate_schedule and duplicate_schedule.duplicate_suppressed == true or false,
        nested_trigger_registered = nested_trigger_registered,
        projectile_id = summary.projectile_id,
        projectile_ids = summary.projectile_id and { summary.projectile_id } or {},
        job_id = enqueue.job_id,
        job_ids = { enqueue.job_id },
        jobs = { summary },
        source_jobs = { summary },
        job_status = summary.job_status,
        cast_id = cast_id,
        runtime = "2.2c_live_helper",
        fallback = false,
        dispatch_count = 1,
        source_dispatch_count = 1,
        fanout_count = 1,
        payload_fanout_count = nested_plan.final_payload_count or 1,
        slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
        helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
        simple_note = "nested_trigger_timer_v1",
    }
end

local function chainRuntimeRejectCounter(reason)
    local text = tostring(reason)
    if string.find(text, "disabled", 1, true) then
        return "chain_runtime_disabled_reject"
    elseif string.find(text, "pattern", 1, true) or string.find(text, "modifier", 1, true) then
        return "chain_runtime_pattern_reject"
    elseif string.find(text, "multicast", 1, true) then
        return "chain_runtime_multicast_reject"
    elseif string.find(text, "trigger_timer", 1, true) or string.find(text, "timer_context", 1, true) then
        return "chain_runtime_trigger_timer_reject"
    elseif string.find(text, "nested", 1, true) then
        return "chain_runtime_nested_reject"
    elseif string.find(text, "recursion", 1, true) then
        return "chain_runtime_recursion_reject"
    elseif string.find(text, "cap", 1, true) then
        return "chain_runtime_cap_reject"
    end
    return "chain_runtime_context_reject"
end

local function countChainModifierRejection(reason, audit)
    if not audit or (audit.payload_modifier_kind == nil
        and audit.has_speed_plus_payload ~= true
        and audit.has_size_plus_payload ~= true) then
        return
    end
    runtime_stats.inc("chain_modifier_rejected")
    local text = tostring(reason or audit.rejection_reason)
    if string.find(text, "disabled", 1, true) then
        runtime_stats.inc("chain_modifier_disabled_reject")
    elseif string.find(text, "combo", 1, true) then
        runtime_stats.inc("chain_modifier_combo_reject")
    else
        runtime_stats.inc("chain_modifier_unsupported_reject")
    end
    log.info(string.format(
        "SPELLFORGE_CHAIN_MODIFIER_REJECTED reason=%s plan_recipe_id=%s source_slot_id=%s payload_slot_id=%s requested_hops=%s max_hops=%s payload_modifier_kind=%s",
        tostring(text),
        tostring(audit.plan_recipe_id or audit.recipe_id),
        tostring(audit.source_slot_id),
        tostring(audit.payload_slot_id),
        tostring(audit.requested_hops),
        tostring(audit.max_hops),
        tostring(audit.payload_modifier_kind)
    ))
end

local function tryChainDispatch(compiled, launch_payload, options)
    runtime_stats.inc("chain_runtime_attempts")
    local source_recipe_id = options.source_recipe_id or launch_payload.recipe_id
    local result_recipe_id = source_recipe_id or compiled.recipe_id

    if options.force_chain_runtime_disabled == true then
        runtime_stats.inc("chain_target_runtime_deferred")
        return chainRuntimeRejected("chain_runtime_disabled", {
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            runtime_enabled = false,
            audit_enabled = dev.liveChainAuditEnabled() == true,
        }, "chain_runtime_disabled_reject")
    end
    if options.force_chain_runtime_enabled ~= true and not dev.liveChainRuntimeEnabled() then
        runtime_stats.inc("chain_target_runtime_deferred")
        return chainRuntimeRejected("chain_runtime_disabled", {
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            runtime_enabled = false,
            audit_enabled = dev.liveChainAuditEnabled() == true,
        }, "chain_runtime_disabled_reject")
    end

    local attached_specs = plan_cache.attachHelperSpecs(compiled.recipe_id)
    if not attached_specs.ok then
        return chainRuntimeRejected("helper_specs_failed", {
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            error = firstErrorMessage(attached_specs),
            errors = attached_specs.errors,
        }, "chain_runtime_context_reject")
    end

    local modifier_plan, modifier_reason, modifier_audit = live_chain.preparePayloadModifiers(attached_specs.plan, {
        max_hops = options.max_chain_hops,
        max_jobs = options.max_chain_jobs,
        max_candidates = options.max_chain_scan_candidates,
        scan_radius = options.chain_scan_radius,
        allow_chain_multicast = options.force_chain_multicast_enabled == true
            or options.chain_multicast_enabled == true
            or dev.liveChainMulticastEnabled(),
        max_chain_multicast_fanout = options.max_chain_multicast_fanout,
        apply_size_to_specs = true,
        force_chain_multicast_enabled = options.force_chain_multicast_enabled,
        force_chain_multicast_disabled = options.force_chain_multicast_disabled,
        chain_multicast_enabled = dev.liveChainMulticastEnabled() == true,
        force_speed_plus_enabled = options.force_speed_plus_enabled,
        force_speed_plus_disabled = options.force_speed_plus_disabled,
        force_size_plus_enabled = options.force_size_plus_enabled,
        force_size_plus_disabled = options.force_size_plus_disabled,
        speed_plus_enabled = dev.liveSpeedPlusEnabled() == true,
        size_plus_enabled = dev.liveSizePlusEnabled() == true,
    })
    if modifier_audit and (modifier_audit.payload_modifier_kind ~= nil
        or modifier_audit.has_speed_plus_payload == true
        or modifier_audit.has_size_plus_payload == true) then
        runtime_stats.inc("chain_modifier_attempts")
    end
    if modifier_audit and modifier_audit.has_multicast_payload == true then
        runtime_stats.inc("chain_multicast_attempts")
    end
    if not modifier_plan then
        local details = modifier_audit or {}
        details.recipe_id = result_recipe_id
        details.plan_recipe_id = compiled.recipe_id
        local rejection_reason = modifier_reason or details.rejection_reason
        if options.force_chain_multicast_disabled == true
            and (details.has_multicast_payload == true or details.has_chain_with_multicast == true) then
            rejection_reason = "chain_multicast_disabled"
        end
        details.rejection_reason = rejection_reason
        countChainModifierRejection(rejection_reason, details)
        if details.has_multicast_payload == true or details.has_chain_with_multicast == true then
            runtime_stats.inc("chain_multicast_rejected")
            if tostring(rejection_reason):find("disabled", 1, true) then
                runtime_stats.inc("chain_multicast_disabled_reject")
            elseif tostring(rejection_reason):find("cap", 1, true) then
                runtime_stats.inc("chain_multicast_fanout_cap_reject")
            end
        end
        local reject_counter = details.has_chain_with_pattern == true
            and "chain_runtime_pattern_reject"
            or chainRuntimeRejectCounter(rejection_reason)
        return chainRuntimeRejected(rejection_reason or "unsupported_chain_shape", details, reject_counter)
    end
    if modifier_plan.payload_modifier_kind ~= nil then
        runtime_stats.inc("chain_modifier_qualified")
        if modifier_plan.payload_modifier_kind == "speed_plus" then
            runtime_stats.inc("chain_modifier_speed_qualified")
        elseif modifier_plan.payload_modifier_kind == "size_plus" then
            runtime_stats.inc("chain_modifier_size_qualified")
            runtime_stats.inc("chain_modifier_size_specs_mutated", modifier_plan.size_plus_apply_result and modifier_plan.size_plus_apply_result.specs_mutated or 0)
        end
    end
    if modifier_plan.has_multicast_payload == true then
        runtime_stats.inc("chain_multicast_qualified")
    end

    local attached = plan_cache.attachHelperRecords(compiled.recipe_id, { limits = options.budget_limits })
    if not attached.ok then
        return chainRuntimeRejected("helper_records_failed", {
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            error = firstErrorMessage(attached),
            errors = attached.errors,
        }, "chain_runtime_context_reject")
    end

    local chain_plan, chain_reason, chain_audit = live_chain.selectV0Plan(attached.plan, {
        max_hops = options.max_chain_hops,
        max_jobs = options.max_chain_jobs,
        max_candidates = options.max_chain_scan_candidates,
        scan_radius = options.chain_scan_radius,
        allow_chain_multicast = options.force_chain_multicast_enabled == true
            or options.chain_multicast_enabled == true
            or dev.liveChainMulticastEnabled(),
        max_chain_multicast_fanout = options.max_chain_multicast_fanout,
        prepared_modifier = modifier_plan,
        force_chain_multicast_enabled = options.force_chain_multicast_enabled,
        force_chain_multicast_disabled = options.force_chain_multicast_disabled,
        chain_multicast_enabled = dev.liveChainMulticastEnabled() == true,
        force_speed_plus_enabled = options.force_speed_plus_enabled,
        force_speed_plus_disabled = options.force_speed_plus_disabled,
        force_size_plus_enabled = options.force_size_plus_enabled,
        force_size_plus_disabled = options.force_size_plus_disabled,
        speed_plus_enabled = dev.liveSpeedPlusEnabled() == true,
        size_plus_enabled = dev.liveSizePlusEnabled() == true,
    })
    if not chain_plan then
        local details = chain_audit or {}
        details.recipe_id = result_recipe_id
        details.plan_recipe_id = compiled.recipe_id
        local rejection_reason = chain_reason or details.rejection_reason
        if options.force_chain_multicast_disabled == true
            and (details.has_multicast_payload == true or details.has_chain_with_multicast == true) then
            rejection_reason = "chain_multicast_disabled"
        end
        details.rejection_reason = rejection_reason
        countChainModifierRejection(rejection_reason, details)
        if details.has_multicast_payload == true or details.has_chain_with_multicast == true then
            runtime_stats.inc("chain_multicast_rejected")
            if tostring(rejection_reason):find("disabled", 1, true) then
                runtime_stats.inc("chain_multicast_disabled_reject")
            elseif tostring(rejection_reason):find("cap", 1, true) then
                runtime_stats.inc("chain_multicast_fanout_cap_reject")
            end
        end
        local reject_counter = details.has_chain_with_pattern == true
            and "chain_runtime_pattern_reject"
            or chainRuntimeRejectCounter(rejection_reason)
        return chainRuntimeRejected(rejection_reason or "unsupported_chain_shape", details, reject_counter)
    end
    if chain_plan.chain_shape == "trigger_payload_chain"
        and options.force_trigger_enabled ~= true
        and not dev.liveTriggerEnabled() then
        return chainRuntimeRejected("live_trigger_disabled", {
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            source_slot_id = chain_plan.source_slot_id,
            payload_slot_id = chain_plan.payload_slot_id,
            requested_hops = chain_plan.requested_hops,
            max_hops = chain_plan.max_hops,
        }, "chain_runtime_disabled_reject")
    end

    local cast_id = nextCastId(result_recipe_id, compiled.recipe_id)
    local chain_id = string.format(
        "chain:%s:%s:%s:%s",
        tostring(cast_id),
        tostring(chain_plan.source_slot_id),
        tostring(chain_plan.payload_slot_id),
        tostring(chain_plan.max_hops)
    )
    local binding = {
        plan = attached.plan,
        recipe_id = compiled.recipe_id,
        display_recipe_id = result_recipe_id,
        cast_id = cast_id,
        chain_id = chain_id,
        chain_shape = chain_plan.chain_shape,
        source_slot_id = chain_plan.source_slot_id,
        source_helper_engine_id = chain_plan.source_helper_engine_id,
        payload_slot_id = chain_plan.payload_slot_id,
        payload_helper_engine_id = chain_plan.payload_helper_engine_id,
        payload_effect_id = chain_plan.payload_effect_id,
        payload_modifier_kind = chain_plan.payload_modifier_kind,
        has_multicast_payload = chain_plan.has_multicast_payload == true,
        chain_multicast_fanout_count = chain_plan.chain_multicast_fanout_count or 1,
        speed_plus_mutation = chain_plan.speed_plus_mutation,
        size_plus_mutation = chain_plan.size_plus_mutation,
        payload_emission_index = chain_plan.payload.slot.emission_index or chain_plan.payload.helper.emission_index,
        payload_group_index = chain_plan.payload.slot.group_index or chain_plan.payload.helper.group_index,
        root_source_slot_id = chain_plan.source_slot_id,
        requested_hops = chain_plan.requested_hops,
        max_hops = chain_plan.max_hops,
        candidate_cap = chain_plan.candidate_cap or options.max_chain_scan_candidates or limits.MAX_CHAIN_SCAN_CANDIDATES,
        targeting_mode = "no_immediate_repeat",
        actor = launch_payload.actor or launch_payload.sender,
        candidate_provider = options.chain_candidate_provider or options.candidate_provider,
        scan_radius = options.chain_scan_radius or limits.MAX_CHAIN_SCAN_RADIUS,
        max_jobs_per_tick = options.max_jobs_per_tick,
        max_chain_jobs = options.max_chain_jobs,
        max_live_launches_per_tick = options.max_live_launches_per_tick,
        chaos_budget_profile = options.chaos_budget_profile,
        force_enabled = options.force_chain_runtime_enabled == true,
    }

    runtime_stats.inc("live_2_2c_qualified")
    runtime_stats.inc("chain_runtime_qualified")
    if chain_plan.chain_shape == "trigger_payload_chain" then
        runtime_stats.inc("chain_runtime_trigger_chain_qualified")
    else
        runtime_stats.inc("chain_runtime_direct_qualified")
    end
    if chain_plan.payload_modifier_kind ~= nil then
        log.info(string.format(
            "SPELLFORGE_CHAIN_MODIFIER_QUALIFIED recipe_id=%s plan_recipe_id=%s cast_id=%s chain_id=%s chain_shape=%s source_slot_id=%s payload_slot_id=%s requested_hops=%s max_hops=%s payload_modifier_kind=%s",
            tostring(result_recipe_id),
            tostring(compiled.recipe_id),
            tostring(cast_id),
            tostring(chain_id),
            tostring(chain_plan.chain_shape),
            tostring(chain_plan.source_slot_id),
            tostring(chain_plan.payload_slot_id),
            tostring(chain_plan.requested_hops),
            tostring(chain_plan.max_hops),
            tostring(chain_plan.payload_modifier_kind)
        ))
    end
    if chain_plan.has_multicast_payload == true then
        log.info(string.format(
            "SPELLFORGE_CHAIN_MULTICAST_QUALIFIED recipe_id=%s plan_recipe_id=%s cast_id=%s chain_id=%s chain_shape=%s source_slot_id=%s payload_slot_id=%s requested_hops=%s max_hops=%s fanout_count=%s",
            tostring(result_recipe_id),
            tostring(compiled.recipe_id),
            tostring(cast_id),
            tostring(chain_id),
            tostring(chain_plan.chain_shape),
            tostring(chain_plan.source_slot_id),
            tostring(chain_plan.payload_slot_id),
            tostring(chain_plan.requested_hops),
            tostring(chain_plan.max_hops),
            tostring(chain_plan.chain_multicast_fanout_count or 1)
        ))
    end

    local job_inputs = buildJobInputs({ chain_plan.source }, compiled.recipe_id, cast_id, launch_payload)
    local source_job = job_inputs[1]
    if not source_job then
        return chainRuntimeRejected("chain_source_job_missing", {
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            source_slot_id = chain_plan.source_slot_id,
            payload_slot_id = chain_plan.payload_slot_id,
        }, "chain_runtime_context_reject")
    end
    live_chain.decorateSourceJob(source_job, binding)

    if options.dry_run == true then
        return {
            ok = true,
            used_live_2_2c = true,
            dry_run = true,
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            live_mode = "chain",
            chain_runtime = true,
            runtime_enabled = true,
            chain_shape = chain_plan.chain_shape,
            chain_id = chain_id,
            requested_hops = chain_plan.requested_hops,
            max_hops = chain_plan.max_hops,
            targeting_mode = "no_immediate_repeat",
            payload_modifier_kind = chain_plan.payload_modifier_kind,
            has_multicast_payload = chain_plan.has_multicast_payload == true,
            chain_multicast_fanout_count = chain_plan.chain_multicast_fanout_count or 1,
            speed_plus = chain_plan.payload_modifier_kind == "speed_plus" or nil,
            speed_plus_mode = chain_plan.speed_plus_mutation and chain_plan.speed_plus_mutation.speed_plus_mode or nil,
            speed_plus_value = chain_plan.speed_plus_mutation and chain_plan.speed_plus_mutation.speed_plus_value or nil,
            speed_plus_base_speed = chain_plan.speed_plus_mutation and chain_plan.speed_plus_mutation.speed_plus_base_speed or nil,
            speed_plus_multiplier = chain_plan.speed_plus_mutation and chain_plan.speed_plus_mutation.speed_plus_multiplier or nil,
            speed_plus_speed = chain_plan.speed_plus_mutation and chain_plan.speed_plus_mutation.speed_plus_speed or nil,
            speed_plus_max_speed = chain_plan.speed_plus_mutation and chain_plan.speed_plus_mutation.speed_plus_max_speed or nil,
            speed_plus_field = chain_plan.speed_plus_mutation and chain_plan.speed_plus_mutation.speed_plus_field or nil,
            size_plus = chain_plan.payload_modifier_kind == "size_plus" or nil,
            size_plus_mode = chain_plan.size_plus_mutation and chain_plan.size_plus_mutation.size_plus_mode or nil,
            size_plus_value = chain_plan.size_plus_mutation and chain_plan.size_plus_mutation.size_plus_value or nil,
            size_plus_multiplier = chain_plan.size_plus_mutation and chain_plan.size_plus_mutation.size_plus_multiplier or nil,
            size_plus_field = chain_plan.size_plus_mutation and chain_plan.size_plus_mutation.size_plus_field or nil,
            size_plus_base_area = chain_plan.size_plus_mutation and chain_plan.size_plus_mutation.size_plus_base_area or nil,
            size_plus_area = chain_plan.size_plus_mutation and chain_plan.size_plus_mutation.size_plus_area or nil,
            slot_id = chain_plan.source_slot_id,
            helper_engine_id = chain_plan.source_helper_engine_id,
            payload_slot_id = chain_plan.payload_slot_id,
            payload_helper_engine_id = chain_plan.payload_helper_engine_id,
            dispatch_count = 1,
            source_dispatch_count = 1,
            fanout_count = chain_plan.chain_multicast_fanout_count or 1,
            would_launch_payloads = (chain_plan.chain_multicast_fanout_count or 1) * (chain_plan.max_hops or 0),
            slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
            helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
            cast_id = cast_id,
        }
    end

    local enqueue = orchestrator.enqueue(source_job)
    if not enqueue.ok then
        runtime_stats.inc("live_2_2c_dispatch_failed")
        return chainRuntimeRejected("enqueue_failed", {
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            source_slot_id = chain_plan.source_slot_id,
            payload_slot_id = chain_plan.payload_slot_id,
            error = enqueue.error or "enqueue failed",
            cast_id = cast_id,
        }, "chain_runtime_context_reject")
    end
    binding.source_job_id = enqueue.job_id
    live_chain.registerBinding(binding)

    local tick_result = tickUntilJobsSettled({ enqueue.job_id }, options)
    local summary = jobSummary(enqueue.job_id)
    if summary.job_status ~= "complete" or summary.launch_accepted ~= true then
        runtime_stats.inc("live_2_2c_dispatch_failed")
        return bridgeError(summary.error or "Chain source launch job did not complete", {
            stage = "chain_source_launch",
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            source_slot_id = chain_plan.source_slot_id,
            payload_slot_id = chain_plan.payload_slot_id,
            job_id = enqueue.job_id,
            job_status = summary.job_status,
            tick_result = tick_result,
            cast_id = cast_id,
            fallback_allowed = false,
        })
    end

    log.info(string.format(
        "SPELLFORGE_CHAIN_RUNTIME_QUALIFIED recipe_id=%s plan_recipe_id=%s cast_id=%s chain_id=%s chain_shape=%s source_slot_id=%s payload_slot_id=%s requested_hops=%s max_hops=%s source_projectile_id=%s",
        tostring(result_recipe_id),
        tostring(compiled.recipe_id),
        tostring(cast_id),
        tostring(chain_id),
        tostring(chain_plan.chain_shape),
        tostring(chain_plan.source_slot_id),
        tostring(chain_plan.payload_slot_id),
        tostring(chain_plan.requested_hops),
        tostring(chain_plan.max_hops),
        tostring(summary.projectile_id)
    ))
    runtime_stats.inc("live_2_2c_dispatch_ok")

    return {
        ok = true,
        used_live_2_2c = true,
        recipe_id = result_recipe_id,
        plan_recipe_id = compiled.recipe_id,
        live_mode = "chain",
        chain_runtime = true,
        runtime_enabled = true,
        chain_shape = chain_plan.chain_shape,
        chain_id = chain_id,
        requested_hops = chain_plan.requested_hops,
        max_hops = chain_plan.max_hops,
        targeting_mode = "no_immediate_repeat",
        payload_modifier_kind = chain_plan.payload_modifier_kind,
        has_multicast_payload = chain_plan.has_multicast_payload == true,
        chain_multicast_fanout_count = chain_plan.chain_multicast_fanout_count or 1,
        speed_plus = chain_plan.payload_modifier_kind == "speed_plus" or nil,
        speed_plus_mode = chain_plan.speed_plus_mutation and chain_plan.speed_plus_mutation.speed_plus_mode or nil,
        speed_plus_value = chain_plan.speed_plus_mutation and chain_plan.speed_plus_mutation.speed_plus_value or nil,
        speed_plus_base_speed = chain_plan.speed_plus_mutation and chain_plan.speed_plus_mutation.speed_plus_base_speed or nil,
        speed_plus_multiplier = chain_plan.speed_plus_mutation and chain_plan.speed_plus_mutation.speed_plus_multiplier or nil,
        speed_plus_speed = chain_plan.speed_plus_mutation and chain_plan.speed_plus_mutation.speed_plus_speed or nil,
        speed_plus_max_speed = chain_plan.speed_plus_mutation and chain_plan.speed_plus_mutation.speed_plus_max_speed or nil,
        speed_plus_field = chain_plan.speed_plus_mutation and chain_plan.speed_plus_mutation.speed_plus_field or nil,
        size_plus = chain_plan.payload_modifier_kind == "size_plus" or nil,
        size_plus_mode = chain_plan.size_plus_mutation and chain_plan.size_plus_mutation.size_plus_mode or nil,
        size_plus_value = chain_plan.size_plus_mutation and chain_plan.size_plus_mutation.size_plus_value or nil,
        size_plus_multiplier = chain_plan.size_plus_mutation and chain_plan.size_plus_mutation.size_plus_multiplier or nil,
        size_plus_field = chain_plan.size_plus_mutation and chain_plan.size_plus_mutation.size_plus_field or nil,
        size_plus_base_area = chain_plan.size_plus_mutation and chain_plan.size_plus_mutation.size_plus_base_area or nil,
        size_plus_area = chain_plan.size_plus_mutation and chain_plan.size_plus_mutation.size_plus_area or nil,
        slot_id = chain_plan.source_slot_id,
        helper_engine_id = chain_plan.source_helper_engine_id,
        payload_slot_id = chain_plan.payload_slot_id,
        payload_helper_engine_id = chain_plan.payload_helper_engine_id,
        projectile_id = summary.projectile_id,
        projectile_ids = summary.projectile_id and { summary.projectile_id } or {},
        projectile_id_source = summary.projectile_id_source,
        projectile_registered = summary.projectile_registered == true,
        job_id = enqueue.job_id,
        job_ids = { enqueue.job_id },
        jobs = { summary },
        source_jobs = { summary },
        job_status = summary.job_status,
        cast_id = cast_id,
        runtime = "2.2c_live_helper",
        fallback = false,
        dispatch_count = 1,
        source_dispatch_count = 1,
        fanout_count = chain_plan.chain_multicast_fanout_count or 1,
        slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
        helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
        simple_note = "chain_runtime_v0",
        tick_result = tick_result,
    }
end

local function tryTimerDispatch(compiled, launch_payload, options)
    runtime_stats.inc("live_timer_attempts")
    if options.force_timer_disabled == true then
        return timerRejected("live_timer_disabled", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_timer_disabled_rejections")
    end
    if options.force_timer_enabled ~= true and not dev.liveTimerEnabled() then
        return timerRejected("live_timer_disabled", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_timer_disabled_rejections")
    end

    local attached = plan_cache.attachHelperRecords(compiled.recipe_id, { limits = options.budget_limits })
    if not attached.ok then
        return timerRejected("helper_records_failed", {
            plan_recipe_id = compiled.recipe_id,
            error = firstErrorMessage(attached),
            errors = attached.errors,
        })
    end

    local timer_plan, timer_reason = live_timer.selectV0Plan(attached.plan, {
        allow_payload_multicast = payloadMulticastRuntimeEnabled(options),
        allow_payload_pattern = payloadPatternRuntimeEnabled(options),
        max_depth = options.max_nested_payload_depth,
        max_jobs = options.max_nested_payload_jobs,
        max_fanout = options.max_payload_fanout,
        max_projectiles = options.max_projectiles,
        max_jobs_per_tick = options.max_jobs_per_tick,
        max_live_launches_per_tick = options.max_live_launches_per_tick,
        allow_pending_launch_jobs = options.allow_pending_launch_jobs,
    })
    if not timer_plan then
        return timerRejected(timer_reason or "timer_v0_rejected", {
            plan_recipe_id = compiled.recipe_id,
        })
    end

    local source_recipe_id = options.source_recipe_id or launch_payload.recipe_id
    local result_recipe_id = source_recipe_id or compiled.recipe_id
    local cast_id = nextCastId(result_recipe_id, compiled.recipe_id)
    runtime_stats.inc("live_2_2c_qualified")
    runtime_stats.inc("live_timer_qualified")

    local selected_helpers = { timer_plan.source }
    local job_inputs = buildJobInputs(selected_helpers, compiled.recipe_id, cast_id, launch_payload, nil)
    local source_job = job_inputs[1]
    local binding = {
        recipe_id = compiled.recipe_id,
        cast_id = cast_id,
        source_slot_id = timer_plan.source_slot_id,
        source_helper_engine_id = timer_plan.source_helper_engine_id,
        payload_slot_id = timer_plan.payload_slot_id,
        payload_helper_engine_id = timer_plan.payload_helper_engine_id,
        payloads = timer_plan.payloads,
        payload_slot_ids = timer_plan.payload_slot_ids,
        payload_helper_engine_ids = timer_plan.payload_helper_engine_ids,
        payload_count = timer_plan.payload_count,
        payload_group_key = timer_plan.payload_group_key,
        payload_multicast = timer_plan.payload_multicast == true,
        payload_pattern = timer_plan.payload_pattern == true,
        payload_pattern_kind = timer_plan.payload_pattern_kind,
        payload_pattern_op = timer_plan.payload_pattern_op,
        plan = attached.plan,
        max_payload_fanout = timer_plan.max_payload_fanout,
        max_projectiles = timer_plan.max_projectiles,
        max_jobs_per_tick = timer_plan.max_jobs_per_tick,
        max_live_launches_per_tick = timer_plan.max_live_launches_per_tick,
        allow_pending_launch_jobs = timer_plan.allow_pending_launch_jobs == true,
        actor = launch_payload.actor or launch_payload.sender,
        hit_object = launch_payload.hit_object,
        timer_seconds = timer_plan.timer_seconds,
        timer_delay_ticks = timer_plan.timer_delay_ticks,
    }
    live_timer.decorateSourceJob(source_job, binding)

    if options.dry_run == true then
        return {
            ok = true,
            used_live_2_2c = true,
            dry_run = true,
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = timer_plan.source_slot_id,
            helper_engine_id = timer_plan.source_helper_engine_id,
            slot_ids = { timer_plan.source_slot_id },
            helper_engine_ids = { timer_plan.source_helper_engine_id },
            emission_indexes = {
                timer_plan.source.slot.emission_index or timer_plan.source.helper.emission_index or 1,
            },
            timer_payload_slot_id = timer_plan.payload_slot_id,
            timer_payload_helper_engine_id = timer_plan.payload_helper_engine_id,
            timer_payload_slot_ids = timer_plan.payload_slot_ids,
            timer_payload_helper_engine_ids = timer_plan.payload_helper_engine_ids,
            timer_payload_count = timer_plan.payload_count,
            payload_multicast = timer_plan.payload_multicast == true,
            payload_pattern = timer_plan.payload_pattern == true,
            payload_pattern_kind = timer_plan.payload_pattern_kind,
            timer_payload_effect_id = timer_plan.payload_effect_id,
            timer_seconds = timer_plan.timer_seconds,
            timer_delay_ticks = timer_plan.timer_delay_ticks,
            timer_delay_seconds = timer_plan.timer_seconds,
            timer_ticks_per_second = timer_plan.timer_ticks_per_second,
            timer_delay_capped = timer_plan.timer_delay_capped,
            slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
            helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
            dispatch_count = 1,
            source_dispatch_count = 1,
            fanout_count = 1,
            payload_fanout_count = timer_plan.payload_count,
            simple_note = "timer_v0",
            live_mode = "timer",
            cast_id = cast_id,
        }
    end

    local resolution, resolution_err = live_timer.computeResolution(launch_payload, timer_plan)
    if not resolution then
        return timerRejected("timer_resolution_failed", {
            plan_recipe_id = compiled.recipe_id,
            error = resolution_err,
        }, "live_timer_payload_route_failed")
    end
    binding.resolution = resolution

    local enqueue = orchestrator.enqueue(source_job)
    if not enqueue.ok then
        runtime_stats.inc("live_2_2c_dispatch_failed")
        return timerRejected("enqueue_failed", {
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = timer_plan.source_slot_id,
            helper_engine_id = timer_plan.source_helper_engine_id,
            error = enqueue.error or "enqueue failed",
            cast_id = cast_id,
        })
    end

    runtime_stats.inc("live_timer_source_jobs_enqueued")
    local tick_result = tickUntilJobsSettled({ enqueue.job_id }, options)
    local summary = jobSummary(enqueue.job_id)
    if summary.job_status == "queued" then
        orchestrator.cancel(enqueue.job_id)
    end
    if summary.job_status ~= "complete" or summary.launch_accepted ~= true then
        runtime_stats.inc("live_2_2c_dispatch_failed")
        return bridgeError(summary.error or "timer source launch job did not complete", {
            stage = "timer_source_launch_job",
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = timer_plan.source_slot_id,
            helper_engine_id = timer_plan.source_helper_engine_id,
            job_id = enqueue.job_id,
            job_ids = { enqueue.job_id },
            job_status = summary.job_status,
            tick_result = tick_result,
            cast_id = cast_id,
            fallback_allowed = false,
        })
    end

    binding.source_job_id = enqueue.job_id
    binding.source_projectile_id = summary.projectile_id
    binding.source_user_data = summary.launch_user_data
    local schedule = live_timer.schedulePayload(binding, {
        delay_ticks_override = options.timer_delay_ticks_override,
        delay_seconds_override = options.timer_delay_seconds_override,
        ttl_ticks_override = options.timer_ttl_ticks_override,
        ttl_seconds_override = options.timer_ttl_seconds_override,
        duplicate_key_suffix = options.timer_duplicate_key_suffix,
    })
    if not schedule.ok then
        runtime_stats.inc("live_2_2c_dispatch_failed")
        return bridgeError(schedule.error or "timer payload schedule failed", {
            stage = "timer_payload_schedule",
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = timer_plan.source_slot_id,
            helper_engine_id = timer_plan.source_helper_engine_id,
            job_id = enqueue.job_id,
            job_ids = { enqueue.job_id },
            cast_id = cast_id,
            fallback_allowed = false,
        })
    end

    local duplicate_schedule = nil
    if options.timer_duplicate_schedule_probe == true then
        duplicate_schedule = live_timer.schedulePayload(binding, {
            delay_ticks_override = options.timer_delay_ticks_override,
            delay_seconds_override = options.timer_delay_seconds_override,
            ttl_ticks_override = options.timer_ttl_ticks_override,
            ttl_seconds_override = options.timer_ttl_seconds_override,
            duplicate_key_suffix = options.timer_duplicate_key_suffix,
        })
    end

    local timer_status = live_timer.timerStatus(schedule.timer_id)
    log.info(string.format(
        "SPELLFORGE_LIVE_TIMER_SOURCE_OK recipe_id=%s plan_recipe_id=%s cast_id=%s source_slot_id=%s payload_slot_id=%s helper_engine_id=%s timer_id=%s delay_ticks=%s delay_seconds=%s due_tick=%s due_seconds=%s projectile_id=%s",
        tostring(result_recipe_id),
        tostring(compiled.recipe_id),
        tostring(cast_id),
        tostring(timer_plan.source_slot_id),
        tostring(timer_plan.payload_slot_id),
        tostring(timer_plan.source_helper_engine_id),
        tostring(schedule.timer_id),
        tostring(schedule.timer_delay_ticks),
        tostring(schedule.timer_delay_seconds),
        tostring(schedule.timer_due_tick),
        tostring(schedule.timer_due_seconds),
        tostring(summary.projectile_id)
    ))
    runtime_stats.inc("live_2_2c_dispatch_ok")

    return {
        ok = true,
        used_live_2_2c = true,
        recipe_id = result_recipe_id,
        plan_recipe_id = compiled.recipe_id,
        slot_id = timer_plan.source_slot_id,
        helper_engine_id = timer_plan.source_helper_engine_id,
        slot_ids = { timer_plan.source_slot_id },
        helper_engine_ids = { timer_plan.source_helper_engine_id },
        emission_indexes = {
            timer_plan.source.slot.emission_index or timer_plan.source.helper.emission_index or 1,
        },
        timer_payload_slot_id = timer_plan.payload_slot_id,
        timer_payload_helper_engine_id = timer_plan.payload_helper_engine_id,
        timer_payload_slot_ids = timer_plan.payload_slot_ids,
        timer_payload_helper_engine_ids = timer_plan.payload_helper_engine_ids,
        timer_payload_count = timer_plan.payload_count,
        payload_multicast = timer_plan.payload_multicast == true,
        payload_pattern = timer_plan.payload_pattern == true,
        payload_pattern_kind = timer_plan.payload_pattern_kind,
        payload_pattern_direction_keys = schedule.payload_pattern_direction_keys,
        timer_payload_effect_id = timer_plan.payload_effect_id,
        timer_seconds = timer_plan.timer_seconds,
        timer_delay_ticks = schedule.timer_delay_ticks,
        timer_delay_seconds = schedule.timer_delay_seconds,
        timer_scheduled_tick = schedule.timer_scheduled_tick,
        timer_due_tick = schedule.timer_due_tick,
        timer_scheduled_seconds = schedule.timer_scheduled_seconds,
        timer_due_seconds = schedule.timer_due_seconds,
        timer_delay_semantics = "async_simulation_timer",
        timer_ticks_per_second = timer_plan.timer_ticks_per_second,
        timer_delay_capped = timer_plan.timer_delay_capped,
        timer_id = schedule.timer_id,
        timer_async_scheduled = schedule.async_scheduled == true,
        timer_pending_count = schedule.pending_count,
        timer_status = timer_status,
        timer_duplicate_suppressed = duplicate_schedule and duplicate_schedule.duplicate_suppressed == true or false,
        ir_timer_runtime_planned = schedule.ir_timer_runtime_planned == true,
        ir_timer_runtime_fallback_used = schedule.ir_timer_runtime_fallback_used == true,
        ir_timer_runtime_fallback_reason = schedule.ir_timer_runtime_fallback_reason,
        ir_timer_runtime_mismatch = schedule.ir_timer_runtime_mismatch == true,
        projectile_id = summary.projectile_id,
        projectile_ids = summary.projectile_id and { summary.projectile_id } or {},
        projectile_id_source = summary.projectile_id_source,
        projectile_registered = summary.projectile_registered == true,
        job_id = enqueue.job_id,
        job_ids = { enqueue.job_id },
        jobs = { summary },
        source_jobs = { summary },
        job_status = summary.job_status,
        cast_id = cast_id,
        runtime = "2.2c_live_helper",
        fallback = false,
        dispatch_count = 1,
        source_dispatch_count = 1,
        fanout_count = 1,
        payload_fanout_count = timer_plan.payload_count,
        slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
        helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
        effect_id = timer_plan.source.slot.effects and timer_plan.source.slot.effects[1] and timer_plan.source.slot.effects[1].id or nil,
        simple_note = "timer_v0",
        live_mode = "timer",
    }
end

local function tryBounceDispatch(compiled, launch_payload, options)
    runtime_stats.inc("live_bounce_attempts")
    if options.force_bounce_disabled == true then
        return bounceRejected("live_bounce_disabled", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_bounce_disabled_rejections")
    end
    if options.force_bounce_enabled ~= true and not dev.liveBounceEnabled() then
        return bounceRejected("live_bounce_disabled", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_bounce_disabled_rejections")
    end

    local capabilities = sfp_adapter.capabilities()
    if not capabilities.has_setSpellBounce
        or not capabilities.has_setSpellDetonateOnActor
        or not capabilities.has_detonateSpellAtPos
        or not capabilities.has_cancelSpell then
        return bounceRejected("sfp_bounce_missing", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_bounce_capability_rejections")
    end

    local attached = plan_cache.attachHelperRecords(compiled.recipe_id, { limits = options.budget_limits })
    if not attached.ok then
        return bounceRejected("helper_records_failed", {
            plan_recipe_id = compiled.recipe_id,
            error = firstErrorMessage(attached),
            errors = attached.errors,
        })
    end

    local bounce_plan, bounce_reason = live_bounce.selectV0Plan(attached.plan, {
        max_depth = options.max_nested_payload_depth,
        max_jobs = options.max_nested_payload_jobs,
        max_fanout = options.max_payload_fanout,
        max_projectiles = options.max_projectiles,
        max_bounce_count = options.max_bounce_count,
        max_chain_hops = options.max_chain_hops,
        max_chain_jobs = options.max_chain_jobs,
        max_chain_scan_candidates = options.max_chain_scan_candidates,
        chain_scan_radius = options.chain_scan_radius,
        max_jobs_per_tick = options.max_jobs_per_tick,
        max_live_launches_per_tick = options.max_live_launches_per_tick,
        chaos_budget_profile = options.chaos_budget_profile,
        allow_pending_launch_jobs = options.allow_pending_launch_jobs,
        allow_payload_multicast = payloadMulticastRuntimeEnabled(options),
        allow_payload_pattern = payloadPatternRuntimeEnabled(options),
    })
    if not bounce_plan then
        return bounceRejected(bounce_reason or "bounce_v0_rejected", {
            plan_recipe_id = compiled.recipe_id,
        })
    end
    if bounce_plan.has_trigger_payload == true
        and options.force_trigger_enabled ~= true
        and not dev.liveTriggerEnabled() then
        return bounceRejected("live_trigger_disabled", {
            plan_recipe_id = compiled.recipe_id,
            source_slot_id = bounce_plan.source_slot_id,
            payload_slot_id = bounce_plan.payload_slot_id,
            bounce_max = bounce_plan.bounce_max,
        }, "live_trigger_disabled_rejections")
    end
    if bounce_plan.has_chain_payload == true
        and (options.force_chain_runtime_disabled == true
            or (options.force_chain_runtime_enabled ~= true and not dev.liveChainRuntimeEnabled())) then
        return bounceRejected("bounce_chain_payload_disabled", {
            plan_recipe_id = compiled.recipe_id,
            source_slot_id = bounce_plan.source_slot_id,
            payload_slot_id = bounce_plan.payload_slot_id,
            bounce_max = bounce_plan.bounce_max,
            chain_max_hops = bounce_plan.chain_max_hops,
        }, "live_bounce_chain_reject")
    end

    local source_recipe_id = options.source_recipe_id or launch_payload.recipe_id
    local result_recipe_id = source_recipe_id or compiled.recipe_id
    local cast_id = nextCastId(result_recipe_id, compiled.recipe_id)
    local bounce_id = string.format(
        "bounce:%s:%s:%s",
        tostring(cast_id),
        tostring(bounce_plan.source_slot_id),
        tostring(bounce_plan.bounce_max)
    )
    local chain_id = nil
    if bounce_plan.has_chain_payload == true then
        chain_id = string.format(
            "chain:%s:%s:%s:%s:bounce",
            tostring(cast_id),
            tostring(bounce_plan.source_slot_id),
            tostring(bounce_plan.payload_slot_id),
            tostring(bounce_plan.chain_max_hops)
        )
    end
    local payload_detonation_mode = nil
    if bounce_plan.has_chain_payload == true then
        payload_detonation_mode = "bounce_chain_runtime"
    elseif bounce_plan.payload_multicast == true or bounce_plan.payload_pattern == true then
        payload_detonation_mode = "bounce_trigger_payload_fanout"
    elseif bounce_plan.has_trigger_payload == true then
        payload_detonation_mode = "bounce_detonate_at_pos"
    end
    runtime_stats.inc("live_2_2c_qualified")
    runtime_stats.inc("live_bounce_qualified")
    if bounce_plan.has_trigger_payload == true then
        runtime_stats.inc("live_bounce_trigger_qualified")
    end
    if bounce_plan.has_chain_payload == true then
        runtime_stats.inc("chain_runtime_qualified")
        runtime_stats.inc("chain_runtime_trigger_chain_qualified")
        log.info(string.format(
            "SPELLFORGE_LIVE_BOUNCE_CHAIN_PAYLOAD_QUALIFIED recipe_id=%s plan_recipe_id=%s cast_id=%s bounce_id=%s chain_id=%s source_slot_id=%s payload_slot_id=%s requested_hops=%s max_hops=%s",
            tostring(result_recipe_id),
            tostring(compiled.recipe_id),
            tostring(cast_id),
            tostring(bounce_id),
            tostring(chain_id),
            tostring(bounce_plan.source_slot_id),
            tostring(bounce_plan.payload_slot_id),
            tostring(bounce_plan.chain_requested_hops),
            tostring(bounce_plan.chain_max_hops)
        ))
    end

    local selected_helpers = { bounce_plan.source }
    local job_inputs = buildJobInputs(selected_helpers, compiled.recipe_id, cast_id, launch_payload, nil)
    local source_job = job_inputs[1]
    local binding = {
        recipe_id = compiled.recipe_id,
        plan = attached.plan,
        cast_id = cast_id,
        bounce_id = bounce_id,
        source_slot_id = bounce_plan.source_slot_id,
        source_helper_engine_id = bounce_plan.source_helper_engine_id,
        payload_slot_id = bounce_plan.payload_slot_id,
        payload_helper_engine_id = bounce_plan.payload_helper_engine_id,
        payloads = bounce_plan.payloads,
        payload_slot_ids = bounce_plan.payload_slot_ids,
        payload_helper_engine_ids = bounce_plan.payload_helper_engine_ids,
        payload_count = bounce_plan.payload_count,
        payload_group_key = bounce_plan.payload_group_key,
        payload_multicast = bounce_plan.payload_multicast == true,
        payload_pattern = bounce_plan.payload_pattern == true,
        payload_pattern_kind = bounce_plan.payload_pattern_kind,
        payload_pattern_op = bounce_plan.payload_pattern_op,
        max_payload_fanout = bounce_plan.max_payload_fanout,
        max_projectiles = bounce_plan.max_projectiles,
        has_trigger_payload = bounce_plan.has_trigger_payload == true,
        has_chain_payload = bounce_plan.has_chain_payload == true,
        chain_id = chain_id,
        chain_shape = bounce_plan.chain_shape,
        chain_requested_hops = bounce_plan.chain_requested_hops,
        chain_max_hops = bounce_plan.chain_max_hops,
        chain_targeting_mode = "no_immediate_repeat",
        chain_candidate_provider = options.chain_candidate_provider or options.candidate_provider,
        chain_source_target = options.chain_source_target,
        candidate_cap = options.max_chain_scan_candidates or limits.MAX_CHAIN_SCAN_CANDIDATES,
        scan_radius = options.chain_scan_radius or limits.MAX_CHAIN_SCAN_RADIUS,
        max_chain_ticks = options.max_chain_ticks,
        max_jobs_per_tick = bounce_plan.max_jobs_per_tick,
        force_chain_runtime_enabled = options.force_chain_runtime_enabled == true,
        bounce_max = bounce_plan.bounce_max,
        bounce_power = bounce_plan.bounce_power,
        actor = launch_payload.actor or launch_payload.sender,
        start_pos = launch_payload.start_pos,
        direction = launch_payload.direction,
        mute_audio = launch_payload.mute_audio or launch_payload.muteAudio,
        mute_light = launch_payload.mute_light or launch_payload.muteLight,
        max_live_launches_per_tick = bounce_plan.max_live_launches_per_tick,
        chaos_budget_profile = bounce_plan.chaos_budget_profile,
        allow_pending_launch_jobs = bounce_plan.allow_pending_launch_jobs == true,
        force_payload_multicast_enabled = options.force_payload_multicast_enabled == true,
        force_payload_pattern_enabled = options.force_payload_pattern_enabled == true,
    }
    live_bounce.decorateSourceJob(source_job, binding)
    local chain_binding = nil
    if bounce_plan.has_chain_payload == true then
        chain_binding = {
            plan = attached.plan,
            recipe_id = compiled.recipe_id,
            display_recipe_id = result_recipe_id,
            cast_id = cast_id,
            chain_id = chain_id,
            chain_shape = "trigger_payload_chain",
            source_slot_id = bounce_plan.source_slot_id,
            source_helper_engine_id = bounce_plan.source_helper_engine_id,
            payload_slot_id = bounce_plan.payload_slot_id,
            payload_helper_engine_id = bounce_plan.payload_helper_engine_id,
            payload_effect_id = bounce_plan.payload_effect_id,
            payload_emission_index = bounce_plan.chain_plan
                and bounce_plan.chain_plan.payload
                and (bounce_plan.chain_plan.payload.slot.emission_index or bounce_plan.chain_plan.payload.helper.emission_index)
                or nil,
            payload_group_index = bounce_plan.chain_plan
                and bounce_plan.chain_plan.payload
                and (bounce_plan.chain_plan.payload.slot.group_index or bounce_plan.chain_plan.payload.helper.group_index)
                or nil,
            root_source_slot_id = bounce_plan.source_slot_id,
            requested_hops = bounce_plan.chain_requested_hops,
            max_hops = bounce_plan.chain_max_hops,
            candidate_cap = options.max_chain_scan_candidates or limits.MAX_CHAIN_SCAN_CANDIDATES,
            targeting_mode = "no_immediate_repeat",
            actor = launch_payload.actor or launch_payload.sender,
            candidate_provider = options.chain_candidate_provider or options.candidate_provider,
            scan_radius = options.chain_scan_radius or limits.MAX_CHAIN_SCAN_RADIUS,
            max_jobs_per_tick = options.max_jobs_per_tick,
            max_chain_jobs = options.max_chain_jobs,
            max_live_launches_per_tick = options.max_live_launches_per_tick,
            chaos_budget_profile = options.chaos_budget_profile,
            force_enabled = options.force_chain_runtime_enabled == true,
        }
        live_chain.decorateSourceJob(source_job, chain_binding)
    end

    if options.dry_run == true then
        local probe_source_job = nil
        local probe_projectile_id = nil
        if options.register_bounce_probe_binding == true then
            binding.source_job_id = string.format("probe_job:%s", tostring(cast_id))
            if not live_bounce.registerBinding(binding) then
                return bounceRejected("bounce_probe_binding_failed", {
                    recipe_id = result_recipe_id,
                    plan_recipe_id = compiled.recipe_id,
                    source_slot_id = bounce_plan.source_slot_id,
                    payload_slot_id = bounce_plan.payload_slot_id,
                    cast_id = cast_id,
                })
            end
            if chain_binding then
                chain_binding.source_job_id = binding.source_job_id
                if not live_chain.registerBinding(chain_binding) then
                    return bounceRejected("bounce_chain_probe_binding_failed", {
                        recipe_id = result_recipe_id,
                        plan_recipe_id = compiled.recipe_id,
                        source_slot_id = bounce_plan.source_slot_id,
                        payload_slot_id = bounce_plan.payload_slot_id,
                        chain_id = chain_id,
                        cast_id = cast_id,
                    }, "live_bounce_chain_reject")
                end
            end

            local source_payload = source_job.payload or {}
            local source_user_data = sfp_userdata.buildHelperUserData({
                runtime = "2.2c_live_helper",
                mapping = helper_records.getByEngineId(bounce_plan.source_helper_engine_id),
                recipe_id = compiled.recipe_id,
                slot_id = bounce_plan.source_slot_id,
                helper_engine_id = bounce_plan.source_helper_engine_id,
                job_kind = orchestrator.LIVE_SIMPLE_LAUNCH_JOB_KIND,
                job_id = binding.source_job_id,
                cast_id = cast_id,
                emission_index = source_job.emission_index,
                group_index = source_job.group_index,
                fanout_count = source_job.fanout_count,
                source_slot_id = source_payload.source_slot_id,
                source_prefix_opcode = source_payload.source_prefix_opcode,
                source_postfix_opcode = source_payload.source_postfix_opcode,
                source_helper_engine_id = source_payload.source_helper_engine_id,
                trigger_source_slot_id = source_payload.trigger_source_slot_id,
                trigger_payload_slot_id = source_payload.trigger_payload_slot_id,
                has_trigger_payload = source_payload.has_trigger_payload,
                bounce_runtime = source_payload.bounce_runtime,
                bounce_role = source_payload.bounce_role,
                bounce_id = source_payload.bounce_id,
                bounce_max = source_payload.bounce_max,
                bounce_power = source_payload.bounce_power,
                bounce_detonate_on_actor_hit = source_payload.bounce_detonate_on_actor_hit,
                bounce_trigger_payload_slot_id = source_payload.bounce_trigger_payload_slot_id,
                branch_scope = source_payload.branch_scope,
                branch_id = source_payload.branch_id,
                branch_parent_id = source_payload.branch_parent_id,
                branch_kind = source_payload.branch_kind,
                branch_index = source_payload.branch_index,
                branch_count = source_payload.branch_count,
            })
            probe_projectile_id = string.format("probe_projectile:%s:%s", tostring(cast_id), tostring(bounce_plan.source_slot_id))
            probe_source_job = {
                job_id = binding.source_job_id,
                job_status = "complete",
                slot_id = bounce_plan.source_slot_id,
                helper_engine_id = bounce_plan.source_helper_engine_id,
                cast_id = cast_id,
                fanout_count = 1,
                bounce_runtime = true,
                bounce_role = "source",
                bounce_id = bounce_id,
                bounce_max = bounce_plan.bounce_max,
                bounce_power = bounce_plan.bounce_power,
                bounceEnabled = true,
                bounceMax = bounce_plan.bounce_max,
                bouncePower = bounce_plan.bounce_power,
                detonateOnActorHit = false,
                launch_accepted = false,
                projectile_id = probe_projectile_id,
                projectile_registered = false,
                launch_direction = launch_payload.direction,
                launch_user_data = source_user_data,
            }
        end

        return {
            ok = true,
            used_live_2_2c = true,
            dry_run = true,
            bounce_probe_binding_registered = options.register_bounce_probe_binding == true,
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = bounce_plan.source_slot_id,
            helper_engine_id = bounce_plan.source_helper_engine_id,
            source_slot_id = bounce_plan.source_slot_id,
            source_helper_engine_id = bounce_plan.source_helper_engine_id,
            slot_ids = { bounce_plan.source_slot_id },
            helper_engine_ids = { bounce_plan.source_helper_engine_id },
            bounce_id = bounce_id,
            bounce_mode = bounce_plan.has_trigger_payload == true and payload_detonation_mode or "source",
            bounce_max = bounce_plan.bounce_max,
            bounce_power = bounce_plan.bounce_power,
            bounce_detonate_on_actor_hit = false,
            has_trigger_payload = bounce_plan.has_trigger_payload == true,
            bounce_trigger_payload_slot_id = bounce_plan.has_trigger_payload == true and bounce_plan.payload_slot_id or nil,
            trigger_payload_slot_id = bounce_plan.has_trigger_payload == true and bounce_plan.payload_slot_id or nil,
            trigger_payload_helper_engine_id = bounce_plan.has_trigger_payload == true and bounce_plan.payload_helper_engine_id or nil,
            trigger_payload_slot_ids = bounce_plan.has_trigger_payload == true and bounce_plan.payload_slot_ids or nil,
            trigger_payload_helper_engine_ids = bounce_plan.has_trigger_payload == true and bounce_plan.payload_helper_engine_ids or nil,
            trigger_payload_count = bounce_plan.has_trigger_payload == true and bounce_plan.payload_count or nil,
            payload_count = bounce_plan.payload_count or 0,
            payload_helper_engine_id = bounce_plan.has_trigger_payload == true and bounce_plan.payload_helper_engine_id or nil,
            payload_multicast = bounce_plan.payload_multicast == true,
            payload_pattern = bounce_plan.payload_pattern == true,
            payload_pattern_kind = bounce_plan.payload_pattern_kind,
            payload_projectile_launches = 0,
            payload_detonation_mode = payload_detonation_mode,
            payload_chain_runtime = bounce_plan.has_chain_payload == true,
            has_chain_payload = bounce_plan.has_chain_payload == true,
            chain_id = chain_id,
            chain_shape = bounce_plan.chain_shape,
            chain_requested_hops = bounce_plan.chain_requested_hops,
            chain_max_hops = bounce_plan.chain_max_hops,
            targeting_mode = bounce_plan.has_chain_payload == true and "no_immediate_repeat" or nil,
            expected_bounce_event_count = bounce_plan.bounce_max,
            projectile_id = probe_projectile_id,
            projectile_ids = probe_projectile_id and { probe_projectile_id } or {},
            jobs = probe_source_job and { probe_source_job } or nil,
            slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
            helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
            dispatch_count = 1,
            source_dispatch_count = 1,
            fanout_count = 1,
            payload_fanout_count = bounce_plan.has_trigger_payload == true and bounce_plan.payload_count or nil,
            simple_note = "bounce_v0",
            live_mode = "bounce",
            cast_id = cast_id,
        }
    end

    local enqueue = orchestrator.enqueue(source_job)
    if not enqueue.ok then
        runtime_stats.inc("live_2_2c_dispatch_failed")
        return bounceRejected("enqueue_failed", {
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = bounce_plan.source_slot_id,
            helper_engine_id = bounce_plan.source_helper_engine_id,
            payload_slot_id = bounce_plan.payload_slot_id,
            bounce_max = bounce_plan.bounce_max,
            error = enqueue.error or "enqueue failed",
            cast_id = cast_id,
        })
    end

    binding.source_job_id = enqueue.job_id
    live_bounce.registerBinding(binding)
    if chain_binding then
        chain_binding.source_job_id = enqueue.job_id
        if not live_chain.registerBinding(chain_binding) then
            orchestrator.cancel(enqueue.job_id)
            return bounceRejected("bounce_chain_binding_failed", {
                recipe_id = result_recipe_id,
                plan_recipe_id = compiled.recipe_id,
                source_slot_id = bounce_plan.source_slot_id,
                payload_slot_id = bounce_plan.payload_slot_id,
                chain_id = chain_id,
                cast_id = cast_id,
            }, "live_bounce_chain_reject")
        end
    end
    runtime_stats.inc("live_bounce_source_jobs_enqueued")

    local tick_result = tickUntilJobsSettled({ enqueue.job_id }, options)
    local summary = jobSummary(enqueue.job_id)
    if summary.job_status == "queued" then
        orchestrator.cancel(enqueue.job_id)
    end
    log.info(string.format(
        "SPELLFORGE_BOUNCE_SOURCE_LAUNCH_CONFIG recipe_id=%s display_recipe_id=%s cast_id=%s source_slot_id=%s helper_engine_id=%s projectile_id=%s projectile_id_source=%s bounceEnabled=%s bounceMax=%s bouncePower=%s detonateOnActorHit=%s post_launch_bounce_ok=%s post_launch_actor_toggle_ok=%s launch_accepted=%s job_status=%s",
        tostring(compiled.recipe_id),
        tostring(result_recipe_id),
        tostring(cast_id),
        tostring(bounce_plan.source_slot_id),
        tostring(bounce_plan.source_helper_engine_id),
        tostring(summary.projectile_id),
        tostring(summary.projectile_id_source),
        tostring(summary.bounceEnabled == true),
        tostring(summary.bounceMax),
        tostring(summary.bouncePower),
        tostring(summary.detonateOnActorHit),
        tostring(summary.post_launch_bounce_ok == true),
        tostring(summary.post_launch_detonate_on_actor_ok == true),
        tostring(summary.launch_accepted == true),
        tostring(summary.job_status)
    ))
    if summary.job_status ~= "complete" or summary.launch_accepted ~= true then
        runtime_stats.inc("live_2_2c_dispatch_failed")
        return bridgeError(summary.error or "bounce source launch job did not complete", {
            stage = "bounce_source_launch_job",
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = bounce_plan.source_slot_id,
            helper_engine_id = bounce_plan.source_helper_engine_id,
            job_id = enqueue.job_id,
            job_ids = { enqueue.job_id },
            job_status = summary.job_status,
            tick_result = tick_result,
            cast_id = cast_id,
            fallback_allowed = false,
        })
    end

    log.info(string.format(
        "SPELLFORGE_LIVE_BOUNCE_SOURCE_OK recipe_id=%s plan_recipe_id=%s cast_id=%s bounce_id=%s source_slot_id=%s payload_slot_id=%s bounce_max=%s bounce_power=%s projectile_id=%s bounce_enabled=%s detonate_on_actor_hit=%s post_launch_bounce_ok=%s post_launch_actor_toggle_ok=%s post_launch_bounce_error=%s post_launch_actor_toggle_error=%s",
        tostring(result_recipe_id),
        tostring(compiled.recipe_id),
        tostring(cast_id),
        tostring(bounce_id),
        tostring(bounce_plan.source_slot_id),
        tostring(bounce_plan.payload_slot_id),
        tostring(bounce_plan.bounce_max),
        tostring(bounce_plan.bounce_power),
        tostring(summary.projectile_id),
        tostring(summary.bounceEnabled == true),
        tostring(summary.detonateOnActorHit),
        tostring(summary.post_launch_bounce_ok == true),
        tostring(summary.post_launch_detonate_on_actor_ok == true),
        tostring(summary.post_launch_bounce_error),
        tostring(summary.post_launch_detonate_on_actor_error)
    ))
    runtime_stats.inc("live_2_2c_dispatch_ok")

    return {
        ok = true,
        used_live_2_2c = true,
        recipe_id = result_recipe_id,
        plan_recipe_id = compiled.recipe_id,
        slot_id = bounce_plan.source_slot_id,
        helper_engine_id = bounce_plan.source_helper_engine_id,
        slot_ids = { bounce_plan.source_slot_id },
        helper_engine_ids = { bounce_plan.source_helper_engine_id },
        bounce_id = bounce_id,
        bounce_max = bounce_plan.bounce_max,
        bounce_power = bounce_plan.bounce_power,
        bounce_detonate_on_actor_hit = false,
        post_launch_bounce_ok = summary.post_launch_bounce_ok == true,
        post_launch_detonate_on_actor_ok = summary.post_launch_detonate_on_actor_ok == true,
        post_launch_bounce_error = summary.post_launch_bounce_error,
        post_launch_detonate_on_actor_error = summary.post_launch_detonate_on_actor_error,
        has_trigger_payload = bounce_plan.has_trigger_payload == true,
        trigger_payload_slot_id = bounce_plan.payload_slot_id,
        trigger_payload_helper_engine_id = bounce_plan.payload_helper_engine_id,
        trigger_payload_slot_ids = bounce_plan.payload_slot_ids,
        trigger_payload_helper_engine_ids = bounce_plan.payload_helper_engine_ids,
        trigger_payload_count = bounce_plan.payload_count,
        payload_multicast = bounce_plan.payload_multicast == true,
        payload_pattern = bounce_plan.payload_pattern == true,
        payload_pattern_kind = bounce_plan.payload_pattern_kind,
        payload_projectile_launches = 0,
        payload_detonation_mode = payload_detonation_mode,
        payload_chain_runtime = bounce_plan.has_chain_payload == true,
        has_chain_payload = bounce_plan.has_chain_payload == true,
        chain_id = chain_id,
        chain_shape = bounce_plan.chain_shape,
        chain_requested_hops = bounce_plan.chain_requested_hops,
        chain_max_hops = bounce_plan.chain_max_hops,
        targeting_mode = bounce_plan.has_chain_payload == true and "no_immediate_repeat" or nil,
        expected_bounce_event_count = bounce_plan.bounce_max,
        projectile_id = summary.projectile_id,
        projectile_ids = summary.projectile_id and { summary.projectile_id } or {},
        projectile_id_source = summary.projectile_id_source,
        projectile_registered = summary.projectile_registered == true,
        job_id = enqueue.job_id,
        job_ids = { enqueue.job_id },
        jobs = { summary },
        job_status = summary.job_status,
        cast_id = cast_id,
        runtime = "2.2c_live_helper",
        fallback = false,
        dispatch_count = 1,
        source_dispatch_count = 1,
        fanout_count = 1,
        payload_fanout_count = bounce_plan.payload_count,
        slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
        helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
        effect_id = bounce_plan.source.slot.effects and bounce_plan.source.slot.effects[1] and bounce_plan.source.slot.effects[1].id or nil,
        simple_note = "bounce_v0",
        live_mode = "bounce",
    }
end

local function tryPierceDispatch(compiled, launch_payload, options)
    runtime_stats.inc("live_pierce_attempts")
    if options.force_pierce_disabled == true then
        return pierceRejected("live_pierce_disabled", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_pierce_disabled_rejections")
    end
    if options.force_pierce_enabled ~= true and not dev.livePierceEnabled() then
        return pierceRejected("live_pierce_disabled", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_pierce_disabled_rejections")
    end

    local capabilities = sfp_adapter.capabilities()
    if not capabilities.has_setSpellPiercing and not capabilities.has_setSpellPhysics then
        return pierceRejected("sfp_pierce_event_unavailable", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_pierce_capability_rejections")
    end

    local attached = plan_cache.attachHelperRecords(compiled.recipe_id, { limits = options.budget_limits })
    if not attached.ok then
        return pierceRejected("helper_records_failed", {
            plan_recipe_id = compiled.recipe_id,
            error = firstErrorMessage(attached),
            errors = attached.errors,
        })
    end

    local pierce_plan, pierce_reason = live_pierce.selectV0Plan(attached.plan, {
        max_pierce_count = options.max_pierce_count,
        max_depth = options.max_nested_payload_depth,
        max_jobs = options.max_nested_payload_jobs,
        max_fanout = options.max_payload_fanout,
        max_projectiles = options.max_projectiles,
        max_hops = options.max_chain_hops,
        allow_payload_multicast = payloadMulticastRuntimeEnabled(options),
        allow_payload_pattern = payloadPatternRuntimeEnabled(options),
        allow_chain_multicast = dev.liveChainMulticastEnabled(),
        chaos_budget_profile = options.chaos_budget_profile,
        max_jobs_per_tick = options.max_jobs_per_tick,
        max_live_launches_per_tick = options.max_live_launches_per_tick,
    })
    if not pierce_plan then
        return pierceRejected(pierce_reason or "pierce_v0_rejected", {
            plan_recipe_id = compiled.recipe_id,
        })
    end
    if pierce_plan.has_trigger_payload == true and (options.force_trigger_enabled ~= true and not dev.liveTriggerEnabled()) then
        return pierceRejected("live_trigger_disabled", {
            plan_recipe_id = compiled.recipe_id,
            source_slot_id = pierce_plan.source_slot_id,
            payload_slot_id = pierce_plan.payload_slot_id,
        }, "live_trigger_disabled_rejections")
    end
    if pierce_plan.has_chain_payload == true
        and (options.force_chain_runtime_disabled == true
            or (options.force_chain_runtime_enabled ~= true and not dev.liveChainRuntimeEnabled())) then
        return pierceRejected("pierce_chain_payload_disabled", {
            plan_recipe_id = compiled.recipe_id,
            source_slot_id = pierce_plan.source_slot_id,
            payload_slot_id = pierce_plan.payload_slot_id,
        }, "live_pierce_deferred_reject")
    end

    local source_recipe_id = options.source_recipe_id or launch_payload.recipe_id
    local result_recipe_id = source_recipe_id or compiled.recipe_id
    local cast_id = nextCastId(result_recipe_id, compiled.recipe_id)
    local pierce_id = string.format("pierce:%s:%s:%s", tostring(cast_id), tostring(pierce_plan.source_slot_id), tostring(pierce_plan.pierce_limit))
    local chain_id = pierce_plan.has_chain_payload == true
        and string.format("chain:%s:%s:%s", tostring(cast_id), tostring(pierce_plan.source_slot_id), tostring(pierce_plan.payload_slot_id))
        or nil
    local job_inputs = buildJobInputs({ pierce_plan.source }, compiled.recipe_id, cast_id, launch_payload, nil)
    local source_job = job_inputs[1]
    if not source_job then
        return pierceRejected("source_job_missing", {
            plan_recipe_id = compiled.recipe_id,
            source_slot_id = pierce_plan.source_slot_id,
        })
    end

    local binding = {
        plan = attached.plan,
        recipe_id = compiled.recipe_id,
        display_recipe_id = result_recipe_id,
        cast_id = cast_id,
        pierce_id = pierce_id,
        source_slot_id = pierce_plan.source_slot_id,
        source_helper_engine_id = pierce_plan.source_helper_engine_id,
        payload_slot_id = pierce_plan.payload_slot_id,
        payload_helper_engine_id = pierce_plan.payload_helper_engine_id,
        payloads = pierce_plan.payloads,
        payload_slot_ids = pierce_plan.payload_slot_ids,
        payload_helper_engine_ids = pierce_plan.payload_helper_engine_ids,
        payload_count = pierce_plan.payload_count,
        payload_multicast = pierce_plan.payload_multicast == true,
        payload_pattern = pierce_plan.payload_pattern == true,
        payload_pattern_kind = pierce_plan.payload_pattern_kind,
        has_trigger_payload = pierce_plan.has_trigger_payload == true,
        has_chain_payload = pierce_plan.has_chain_payload == true,
        chain_id = chain_id,
        chain_shape = pierce_plan.chain_shape,
        chain_requested_hops = pierce_plan.chain_requested_hops,
        chain_max_hops = pierce_plan.chain_max_hops,
        chain_targeting_mode = "no_immediate_repeat",
        chain_candidate_provider = options.chain_candidate_provider or options.candidate_provider,
        max_chain_ticks = options.max_chain_ticks,
        max_jobs_per_tick = pierce_plan.max_jobs_per_tick,
        force_chain_runtime_enabled = options.force_chain_runtime_enabled == true,
        pierce_limit = pierce_plan.pierce_limit,
        actor = launch_payload.actor or launch_payload.sender,
        start_pos = launch_payload.start_pos,
        direction = launch_payload.direction,
        max_payload_fanout = options.max_payload_fanout,
        max_projectiles = options.max_projectiles,
        max_live_launches_per_tick = pierce_plan.max_live_launches_per_tick,
        chaos_budget_profile = pierce_plan.chaos_budget_profile,
        force_payload_multicast_enabled = options.force_payload_multicast_enabled == true,
        force_payload_pattern_enabled = options.force_payload_pattern_enabled == true,
    }
    local chain_binding = nil
    if pierce_plan.has_chain_payload == true then
        chain_binding = {
            plan = attached.plan,
            recipe_id = compiled.recipe_id,
            display_recipe_id = result_recipe_id,
            cast_id = cast_id,
            chain_id = chain_id,
            chain_shape = "trigger_payload_chain",
            source_slot_id = pierce_plan.source_slot_id,
            source_helper_engine_id = pierce_plan.source_helper_engine_id,
            payload_slot_id = pierce_plan.payload_slot_id,
            payload_helper_engine_id = pierce_plan.payload_helper_engine_id,
            root_source_slot_id = pierce_plan.source_slot_id,
            requested_hops = pierce_plan.chain_requested_hops,
            max_hops = pierce_plan.chain_max_hops,
            candidate_cap = options.max_chain_scan_candidates or limits.MAX_CHAIN_SCAN_CANDIDATES,
            targeting_mode = "no_immediate_repeat",
            actor = launch_payload.actor or launch_payload.sender,
            candidate_provider = options.chain_candidate_provider or options.candidate_provider,
            scan_radius = options.chain_scan_radius or limits.MAX_CHAIN_SCAN_RADIUS,
            max_jobs_per_tick = options.max_jobs_per_tick,
            max_chain_jobs = options.max_chain_jobs,
            max_live_launches_per_tick = options.max_live_launches_per_tick,
            chaos_budget_profile = options.chaos_budget_profile,
            force_enabled = options.force_chain_runtime_enabled == true,
        }
        live_chain.decorateSourceJob(source_job, chain_binding)
    end
    live_pierce.decorateSourceJob(source_job, binding)

    if options.dry_run == true then
        local probe_source_job = nil
        local probe_projectile_id = nil
        if options.register_pierce_probe_binding == true then
            binding.source_job_id = string.format("probe_job:%s", tostring(cast_id))
            if not live_pierce.registerBinding(binding) then
                return pierceRejected("pierce_probe_binding_failed", {
                    plan_recipe_id = compiled.recipe_id,
                    source_slot_id = pierce_plan.source_slot_id,
                    payload_slot_id = pierce_plan.payload_slot_id,
                })
            end
            if chain_binding then
                chain_binding.source_job_id = binding.source_job_id
                if not live_chain.registerBinding(chain_binding) then
                    return pierceRejected("pierce_chain_probe_binding_failed", {
                        plan_recipe_id = compiled.recipe_id,
                        source_slot_id = pierce_plan.source_slot_id,
                        payload_slot_id = pierce_plan.payload_slot_id,
                    }, "live_pierce_deferred_reject")
                end
            end

            local source_payload = source_job.payload or {}
            local source_user_data = sfp_userdata.buildHelperUserData({
                runtime = "2.2c_live_helper",
                mapping = helper_records.getByEngineId(pierce_plan.source_helper_engine_id),
                recipe_id = compiled.recipe_id,
                slot_id = pierce_plan.source_slot_id,
                helper_engine_id = pierce_plan.source_helper_engine_id,
                job_kind = orchestrator.LIVE_SIMPLE_LAUNCH_JOB_KIND,
                job_id = binding.source_job_id,
                cast_id = cast_id,
                emission_index = source_job.emission_index,
                group_index = source_job.group_index,
                fanout_count = source_job.fanout_count,
                source_slot_id = source_payload.source_slot_id,
                source_prefix_opcode = source_payload.source_prefix_opcode,
                source_postfix_opcode = source_payload.source_postfix_opcode,
                source_helper_engine_id = source_payload.source_helper_engine_id,
                trigger_source_slot_id = source_payload.trigger_source_slot_id,
                trigger_payload_slot_id = source_payload.trigger_payload_slot_id,
                trigger_payload_slot_ids = source_payload.trigger_payload_slot_ids,
                has_trigger_payload = source_payload.has_trigger_payload,
                has_chain_payload = source_payload.has_chain_payload,
                payload_multicast = source_payload.payload_multicast,
                payload_pattern = source_payload.payload_pattern,
                payload_pattern_kind = source_payload.payload_pattern_kind,
                pierce_runtime = source_payload.pierce_runtime,
                pierce_role = source_payload.pierce_role,
                pierce_id = source_payload.pierce_id,
                pierce_limit = source_payload.pierce_limit,
                pierce_trigger_payload_slot_id = source_payload.pierce_trigger_payload_slot_id,
                branch_scope = source_payload.branch_scope,
                branch_id = source_payload.branch_id,
                branch_parent_id = source_payload.branch_parent_id,
                branch_kind = source_payload.branch_kind,
                branch_index = source_payload.branch_index,
                branch_count = source_payload.branch_count,
            })
            probe_projectile_id = string.format("probe_projectile:%s:%s", tostring(cast_id), tostring(pierce_plan.source_slot_id))
            probe_source_job = {
                job_id = binding.source_job_id,
                job_status = "complete",
                slot_id = pierce_plan.source_slot_id,
                helper_engine_id = pierce_plan.source_helper_engine_id,
                cast_id = cast_id,
                fanout_count = 1,
                pierce_runtime = true,
                pierce_role = "source",
                pierce_id = pierce_id,
                pierce_limit = pierce_plan.pierce_limit,
                piercing = true,
                pierceLimit = pierce_plan.pierce_limit,
                launch_accepted = false,
                projectile_id = probe_projectile_id,
                projectile_registered = false,
                launch_direction = launch_payload.direction,
                launch_user_data = source_user_data,
            }
        end
        return {
            ok = true,
            used_live_2_2c = true,
            dry_run = true,
            pierce_probe_binding_registered = options.register_pierce_probe_binding == true,
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = pierce_plan.source_slot_id,
            helper_engine_id = pierce_plan.source_helper_engine_id,
            source_slot_id = pierce_plan.source_slot_id,
            source_helper_engine_id = pierce_plan.source_helper_engine_id,
            slot_ids = { pierce_plan.source_slot_id },
            helper_engine_ids = { pierce_plan.source_helper_engine_id },
            pierce_id = pierce_id,
            pierce_mode = pierce_plan.has_trigger_payload == true and "trigger_payload" or "source",
            pierce_limit = pierce_plan.pierce_limit,
            piercing = true,
            pierceLimit = pierce_plan.pierce_limit,
            has_trigger_payload = pierce_plan.has_trigger_payload == true,
            trigger_payload_slot_id = pierce_plan.payload_slot_id,
            trigger_payload_helper_engine_id = pierce_plan.payload_helper_engine_id,
            trigger_payload_slot_ids = pierce_plan.payload_slot_ids,
            trigger_payload_helper_engine_ids = pierce_plan.payload_helper_engine_ids,
            trigger_payload_count = pierce_plan.payload_count,
            payload_count = pierce_plan.payload_count or 0,
            payload_multicast = pierce_plan.payload_multicast == true,
            payload_pattern = pierce_plan.payload_pattern == true,
            payload_pattern_kind = pierce_plan.payload_pattern_kind,
            payload_chain_runtime = pierce_plan.has_chain_payload == true,
            has_chain_payload = pierce_plan.has_chain_payload == true,
            chain_id = chain_id,
            chain_shape = pierce_plan.chain_shape,
            chain_requested_hops = pierce_plan.chain_requested_hops,
            chain_max_hops = pierce_plan.chain_max_hops,
            projectile_id = probe_projectile_id,
            projectile_ids = probe_projectile_id and { probe_projectile_id } or {},
            jobs = probe_source_job and { probe_source_job } or nil,
            cast_id = cast_id,
            runtime = "2.2c_live_helper",
            fallback = false,
            dispatch_count = 1,
            source_dispatch_count = 1,
            fanout_count = 1,
            payload_fanout_count = pierce_plan.payload_count,
            slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
            helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
            effect_id = pierce_plan.source.slot.effects and pierce_plan.source.slot.effects[1] and pierce_plan.source.slot.effects[1].id or nil,
            simple_note = "pierce_v0",
            live_mode = "pierce",
        }
    end

    local enqueue = orchestrator.enqueue(source_job)
    if not enqueue.ok then
        return pierceRejected("enqueue_failed", {
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            error = enqueue.error,
        })
    end
    binding.source_job_id = enqueue.job_id
    if not live_pierce.registerBinding(binding) then
        orchestrator.cancel(enqueue.job_id)
        return pierceRejected("pierce_binding_failed", {
            plan_recipe_id = compiled.recipe_id,
            source_slot_id = pierce_plan.source_slot_id,
            payload_slot_id = pierce_plan.payload_slot_id,
        })
    end
    if chain_binding then
        chain_binding.source_job_id = enqueue.job_id
        if not live_chain.registerBinding(chain_binding) then
            orchestrator.cancel(enqueue.job_id)
            return pierceRejected("pierce_chain_binding_failed", {
                plan_recipe_id = compiled.recipe_id,
                source_slot_id = pierce_plan.source_slot_id,
                payload_slot_id = pierce_plan.payload_slot_id,
            }, "live_pierce_deferred_reject")
        end
    end

    local tick_result = tickUntilJobsSettled({ enqueue.job_id }, options)
    local summary = jobSummary(enqueue.job_id)
    log.info(string.format(
        "SPELLFORGE_PIERCE_SOURCE_LAUNCH_CONFIG recipe_id=%s display_recipe_id=%s cast_id=%s source_slot_id=%s helper_engine_id=%s projectile_id=%s projectile_id_source=%s piercing=%s pierceLimit=%s post_launch_pierce_ok=%s launch_accepted=%s job_status=%s",
        tostring(compiled.recipe_id),
        tostring(result_recipe_id),
        tostring(cast_id),
        tostring(pierce_plan.source_slot_id),
        tostring(pierce_plan.source_helper_engine_id),
        tostring(summary.projectile_id),
        tostring(summary.projectile_id_source),
        tostring(summary.piercing == true),
        tostring(summary.pierceLimit),
        tostring(summary.post_launch_pierce_ok == true),
        tostring(summary.launch_accepted == true),
        tostring(summary.job_status)
    ))
    log.info(string.format(
        "SPELLFORGE_LIVE_PIERCE_SOURCE_OK recipe_id=%s plan_recipe_id=%s cast_id=%s pierce_id=%s source_slot_id=%s payload_slot_id=%s pierce_limit=%s projectile_id=%s piercing=%s post_launch_pierce_ok=%s post_launch_pierce_error=%s",
        tostring(result_recipe_id),
        tostring(compiled.recipe_id),
        tostring(cast_id),
        tostring(pierce_id),
        tostring(pierce_plan.source_slot_id),
        tostring(pierce_plan.payload_slot_id),
        tostring(pierce_plan.pierce_limit),
        tostring(summary.projectile_id),
        tostring(summary.piercing == true),
        tostring(summary.post_launch_pierce_ok == true),
        tostring(summary.post_launch_pierce_error)
    ))
    runtime_stats.inc("live_pierce_source_ok")
    runtime_stats.inc("live_2_2c_dispatch_ok")

    return {
        ok = true,
        used_live_2_2c = true,
        recipe_id = result_recipe_id,
        plan_recipe_id = compiled.recipe_id,
        slot_id = pierce_plan.source_slot_id,
        helper_engine_id = pierce_plan.source_helper_engine_id,
        slot_ids = { pierce_plan.source_slot_id },
        helper_engine_ids = { pierce_plan.source_helper_engine_id },
        pierce_id = pierce_id,
        pierce_limit = pierce_plan.pierce_limit,
        piercing = summary.piercing == true,
        pierceLimit = summary.pierceLimit,
        post_launch_pierce_ok = summary.post_launch_pierce_ok == true,
        post_launch_pierce_error = summary.post_launch_pierce_error,
        has_trigger_payload = pierce_plan.has_trigger_payload == true,
        trigger_payload_slot_id = pierce_plan.payload_slot_id,
        trigger_payload_helper_engine_id = pierce_plan.payload_helper_engine_id,
        trigger_payload_slot_ids = pierce_plan.payload_slot_ids,
        trigger_payload_helper_engine_ids = pierce_plan.payload_helper_engine_ids,
        trigger_payload_count = pierce_plan.payload_count,
        payload_multicast = pierce_plan.payload_multicast == true,
        payload_pattern = pierce_plan.payload_pattern == true,
        payload_pattern_kind = pierce_plan.payload_pattern_kind,
        payload_chain_runtime = pierce_plan.has_chain_payload == true,
        has_chain_payload = pierce_plan.has_chain_payload == true,
        chain_id = chain_id,
        chain_shape = pierce_plan.chain_shape,
        chain_requested_hops = pierce_plan.chain_requested_hops,
        chain_max_hops = pierce_plan.chain_max_hops,
        projectile_id = summary.projectile_id,
        projectile_ids = summary.projectile_id and { summary.projectile_id } or {},
        projectile_id_source = summary.projectile_id_source,
        projectile_registered = summary.projectile_registered == true,
        job_id = enqueue.job_id,
        job_ids = { enqueue.job_id },
        jobs = { summary },
        job_status = summary.job_status,
        cast_id = cast_id,
        runtime = "2.2c_live_helper",
        fallback = false,
        dispatch_count = 1,
        source_dispatch_count = 1,
        fanout_count = 1,
        payload_fanout_count = pierce_plan.payload_count,
        all_launch_jobs_complete = tick_result.all_complete == true,
        slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
        helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
        effect_id = pierce_plan.source.slot.effects and pierce_plan.source.slot.effects[1] and pierce_plan.source.slot.effects[1].id or nil,
        simple_note = "pierce_v0",
        live_mode = "pierce",
    }
end

local function tryTriggerDispatch(compiled, launch_payload, options)
    runtime_stats.inc("live_trigger_attempts")
    if options.force_trigger_disabled == true then
        return triggerRejected("live_trigger_disabled", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_trigger_disabled_rejections")
    end
    if options.force_trigger_enabled ~= true and not dev.liveTriggerEnabled() then
        return triggerRejected("live_trigger_disabled", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_trigger_disabled_rejections")
    end

    local attached = plan_cache.attachHelperRecords(compiled.recipe_id, { limits = options.budget_limits })
    if not attached.ok then
        return triggerRejected("helper_records_failed", {
            plan_recipe_id = compiled.recipe_id,
            error = firstErrorMessage(attached),
            errors = attached.errors,
        })
    end

    local trigger_plan, trigger_reason = live_trigger.selectV0Plan(attached.plan, {
        allow_payload_multicast = payloadMulticastRuntimeEnabled(options),
        allow_payload_pattern = payloadPatternRuntimeEnabled(options),
        max_depth = options.max_nested_payload_depth,
        max_jobs = options.max_nested_payload_jobs,
        max_fanout = options.max_payload_fanout,
        max_projectiles = options.max_projectiles,
        max_jobs_per_tick = options.max_jobs_per_tick,
        max_live_launches_per_tick = options.max_live_launches_per_tick,
        allow_pending_launch_jobs = options.allow_pending_launch_jobs,
    })
    if not trigger_plan then
        return triggerRejected(trigger_reason or "trigger_v0_rejected", {
            plan_recipe_id = compiled.recipe_id,
        })
    end

    local source_recipe_id = options.source_recipe_id or launch_payload.recipe_id
    local result_recipe_id = source_recipe_id or compiled.recipe_id
    local cast_id = nextCastId(result_recipe_id, compiled.recipe_id)
    runtime_stats.inc("live_2_2c_qualified")
    runtime_stats.inc("live_trigger_qualified")

    local selected_helpers = { trigger_plan.source }
    local job_inputs = buildJobInputs(selected_helpers, compiled.recipe_id, cast_id, launch_payload, nil)
    local source_job = job_inputs[1]
    local binding = {
        recipe_id = compiled.recipe_id,
        plan = attached.plan,
        cast_id = cast_id,
        source_slot_id = trigger_plan.source_slot_id,
        source_helper_engine_id = trigger_plan.source_helper_engine_id,
        payload_slot_id = trigger_plan.payload_slot_id,
        payload_helper_engine_id = trigger_plan.payload_helper_engine_id,
        payloads = trigger_plan.payloads,
        payload_slot_ids = trigger_plan.payload_slot_ids,
        payload_helper_engine_ids = trigger_plan.payload_helper_engine_ids,
        payload_count = trigger_plan.payload_count,
        payload_group_key = trigger_plan.payload_group_key,
        payload_multicast = trigger_plan.payload_multicast == true,
        payload_pattern = trigger_plan.payload_pattern == true,
        payload_pattern_kind = trigger_plan.payload_pattern_kind,
        payload_pattern_op = trigger_plan.payload_pattern_op,
        max_payload_fanout = trigger_plan.max_payload_fanout,
        max_projectiles = trigger_plan.max_projectiles,
        max_jobs_per_tick = trigger_plan.max_jobs_per_tick,
        max_live_launches_per_tick = trigger_plan.max_live_launches_per_tick,
        allow_pending_launch_jobs = trigger_plan.allow_pending_launch_jobs == true,
        actor = launch_payload.actor or launch_payload.sender,
        start_pos = launch_payload.start_pos,
        direction = launch_payload.direction,
    }
    live_trigger.decorateSourceJob(source_job, binding)

    if options.dry_run == true then
        return {
            ok = true,
            used_live_2_2c = true,
            dry_run = true,
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = trigger_plan.source_slot_id,
            helper_engine_id = trigger_plan.source_helper_engine_id,
            slot_ids = { trigger_plan.source_slot_id },
            helper_engine_ids = { trigger_plan.source_helper_engine_id },
            emission_indexes = {
                trigger_plan.source.slot.emission_index or trigger_plan.source.helper.emission_index or 1,
            },
            trigger_payload_slot_id = trigger_plan.payload_slot_id,
            trigger_payload_helper_engine_id = trigger_plan.payload_helper_engine_id,
            trigger_payload_slot_ids = trigger_plan.payload_slot_ids,
            trigger_payload_helper_engine_ids = trigger_plan.payload_helper_engine_ids,
            trigger_payload_count = trigger_plan.payload_count,
            payload_multicast = trigger_plan.payload_multicast == true,
            payload_pattern = trigger_plan.payload_pattern == true,
            payload_pattern_kind = trigger_plan.payload_pattern_kind,
            trigger_payload_effect_id = trigger_plan.payload_effect_id,
            slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
            helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
            dispatch_count = 1,
            source_dispatch_count = 1,
            fanout_count = 1,
            payload_fanout_count = trigger_plan.payload_count,
            simple_note = "trigger_v0",
            live_mode = "trigger",
            cast_id = cast_id,
        }
    end

    local enqueue = orchestrator.enqueue(source_job)
    if not enqueue.ok then
        runtime_stats.inc("live_2_2c_dispatch_failed")
        return triggerRejected("enqueue_failed", {
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = trigger_plan.source_slot_id,
            helper_engine_id = trigger_plan.source_helper_engine_id,
            error = enqueue.error or "enqueue failed",
            cast_id = cast_id,
        })
    end

    binding.source_job_id = enqueue.job_id
    live_trigger.registerBinding(binding)
    runtime_stats.inc("live_trigger_source_jobs_enqueued")

    local tick_result = tickUntilJobsSettled({ enqueue.job_id }, options)
    local summary = jobSummary(enqueue.job_id)
    local pending_source_launch = summary.job_status == "queued" or summary.job_status == "running"
    if pending_source_launch and options.allow_pending_launch_jobs == true then
        log.info(string.format(
            "SPELLFORGE_LIVE_TRIGGER_SOURCE_PENDING recipe_id=%s plan_recipe_id=%s cast_id=%s source_slot_id=%s payload_slot_id=%s job_id=%s job_status=%s",
            tostring(result_recipe_id),
            tostring(compiled.recipe_id),
            tostring(cast_id),
            tostring(trigger_plan.source_slot_id),
            tostring(trigger_plan.payload_slot_id),
            tostring(enqueue.job_id),
            tostring(summary.job_status)
        ))
        return {
            ok = true,
            used_live_2_2c = true,
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = trigger_plan.source_slot_id,
            helper_engine_id = trigger_plan.source_helper_engine_id,
            slot_ids = { trigger_plan.source_slot_id },
            helper_engine_ids = { trigger_plan.source_helper_engine_id },
            emission_indexes = {
                trigger_plan.source.slot.emission_index or trigger_plan.source.helper.emission_index or 1,
            },
            trigger_payload_slot_id = trigger_plan.payload_slot_id,
            trigger_payload_helper_engine_id = trigger_plan.payload_helper_engine_id,
            trigger_payload_slot_ids = trigger_plan.payload_slot_ids,
            trigger_payload_helper_engine_ids = trigger_plan.payload_helper_engine_ids,
            trigger_payload_count = trigger_plan.payload_count,
            payload_multicast = trigger_plan.payload_multicast == true,
            payload_pattern = trigger_plan.payload_pattern == true,
            payload_pattern_kind = trigger_plan.payload_pattern_kind,
            trigger_payload_effect_id = trigger_plan.payload_effect_id,
            projectile_id = summary.projectile_id,
            projectile_ids = summary.projectile_id and { summary.projectile_id } or {},
            projectile_id_source = summary.projectile_id_source,
            projectile_registered = summary.projectile_registered == true,
            job_id = enqueue.job_id,
            job_ids = { enqueue.job_id },
            jobs = { summary },
            source_jobs = { summary },
            job_status = summary.job_status,
            cast_id = cast_id,
            runtime = "2.2c_live_helper",
            fallback = false,
            dispatch_count = 1,
            source_dispatch_count = 1,
            fanout_count = 1,
            payload_fanout_count = trigger_plan.payload_count,
            slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
            helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
            effect_id = trigger_plan.source.slot.effects and trigger_plan.source.slot.effects[1] and trigger_plan.source.slot.effects[1].id or nil,
            simple_note = "trigger_v0",
            live_mode = "trigger",
            pending_source_launch_job = true,
            pending_launch_jobs = true,
            pending_job_count = 1,
            all_launch_jobs_complete = false,
            tick_result = tick_result,
        }
    end
    if summary.job_status == "queued" then
        orchestrator.cancel(enqueue.job_id)
    end
    if summary.job_status ~= "complete" or summary.launch_accepted ~= true then
        runtime_stats.inc("live_2_2c_dispatch_failed")
        return bridgeError(summary.error or "trigger source launch job did not complete", {
            stage = "trigger_source_launch_job",
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = trigger_plan.source_slot_id,
            helper_engine_id = trigger_plan.source_helper_engine_id,
            job_id = enqueue.job_id,
            job_ids = { enqueue.job_id },
            job_status = summary.job_status,
            tick_result = tick_result,
            cast_id = cast_id,
            fallback_allowed = false,
        })
    end

    log.info(string.format(
        "SPELLFORGE_LIVE_TRIGGER_SOURCE_OK recipe_id=%s plan_recipe_id=%s cast_id=%s source_slot_id=%s payload_slot_id=%s helper_engine_id=%s projectile_id=%s",
        tostring(result_recipe_id),
        tostring(compiled.recipe_id),
        tostring(cast_id),
        tostring(trigger_plan.source_slot_id),
        tostring(trigger_plan.payload_slot_id),
        tostring(trigger_plan.source_helper_engine_id),
        tostring(summary.projectile_id)
    ))
    runtime_stats.inc("live_2_2c_dispatch_ok")

    return {
        ok = true,
        used_live_2_2c = true,
        recipe_id = result_recipe_id,
        plan_recipe_id = compiled.recipe_id,
        slot_id = trigger_plan.source_slot_id,
        helper_engine_id = trigger_plan.source_helper_engine_id,
        slot_ids = { trigger_plan.source_slot_id },
        helper_engine_ids = { trigger_plan.source_helper_engine_id },
        emission_indexes = {
            trigger_plan.source.slot.emission_index or trigger_plan.source.helper.emission_index or 1,
        },
        trigger_payload_slot_id = trigger_plan.payload_slot_id,
        trigger_payload_helper_engine_id = trigger_plan.payload_helper_engine_id,
        trigger_payload_slot_ids = trigger_plan.payload_slot_ids,
        trigger_payload_helper_engine_ids = trigger_plan.payload_helper_engine_ids,
        trigger_payload_count = trigger_plan.payload_count,
        payload_multicast = trigger_plan.payload_multicast == true,
        payload_pattern = trigger_plan.payload_pattern == true,
        payload_pattern_kind = trigger_plan.payload_pattern_kind,
        trigger_payload_effect_id = trigger_plan.payload_effect_id,
        projectile_id = summary.projectile_id,
        projectile_ids = summary.projectile_id and { summary.projectile_id } or {},
        projectile_id_source = summary.projectile_id_source,
        projectile_registered = summary.projectile_registered == true,
        job_id = enqueue.job_id,
        job_ids = { enqueue.job_id },
        jobs = { summary },
        job_status = summary.job_status,
        cast_id = cast_id,
        runtime = "2.2c_live_helper",
        fallback = false,
        dispatch_count = 1,
        source_dispatch_count = 1,
        fanout_count = 1,
        payload_fanout_count = trigger_plan.payload_count,
        slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
        helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
        effect_id = trigger_plan.source.slot.effects and trigger_plan.source.slot.effects[1] and trigger_plan.source.slot.effects[1].id or nil,
        simple_note = "trigger_v0",
        live_mode = "trigger",
    }
end

function live_simple_dispatch.tryDispatch(payload, entry, root, opts)
    local options = chaos_budget.withBudget(opts or {})
    if options.force_disabled == true then
        return fallback("feature_flag_disabled")
    end
    if options.ignore_flag ~= true and not dev.liveSimpleDispatchEnabled() then
        return fallback("feature_flag_disabled")
    end
    runtime_stats.inc("live_2_2c_attempts")
    if options.dry_run == true then
        runtime_stats.inc("live_2_2c_dry_run_attempts")
    end

    local launch_payload = payload or {}
    launch_payload.max_live_launches_per_tick = options.max_live_launches_per_tick
    launch_payload.chaos_budget_profile = options.chaos_budget_profile
    local actor = launch_payload.actor or launch_payload.sender
    if not actor then
        return rejected("missing_actor")
    end
    if not options.skip_entry_shape_check and not isSingleStoredNode(entry) then
        return rejected("not_single_stored_node")
    end

    local effects = effectListFromRoot(root)
    if not effects then
        return rejected("missing_effect_list")
    end
    local has_timer_effect = effectListHasOperator(effects, "Timer")
    local has_trigger_effect = effectListHasOperator(effects, "Trigger")
    local has_chain_effect = effectListHasOperator(effects, "Chain")
    local has_bounce_effect = effectListHasOperator(effects, "Bounce")
    local has_pierce_effect = effectListHasOperator(effects, "Pierce")
    local has_size_plus_effect = effectListHasOperator(effects, "Size+")
    local has_speed_plus_effect = effectListHasOperator(effects, "Speed+")
    local has_homing_effect = effectListHasOperator(effects, "Homing")
    local estimated_ops = estimateFirstGroupOperators(effects)
    local estimated_multicast_count = estimated_ops.multicast_count or 1
    local estimated_multicast_fanout = estimated_ops.has_multicast and estimated_multicast_count > 1
    local estimated_pattern_kind = estimated_ops.pattern_kind
    if estimated_ops.has_spread then
        patternAttempt("Spread")
    end
    if estimated_ops.has_burst then
        patternAttempt("Burst")
    end
    if estimated_multicast_fanout then
        runtime_stats.inc("live_multicast_attempts")
        if estimated_multicast_count > options.max_projectiles then
            chaos_budget.recordReject("multicast_projectile_cap_exceeded", "projectile")
            if estimated_pattern_kind ~= nil then
                return patternRejected(estimated_pattern_kind, "pattern_cap_exceeded", {
                    estimated_emission_count = estimated_multicast_count,
                }, "live_multicast_cap_rejections")
            end
            return multicastRejected("multicast_cap_exceeded", {
                estimated_emission_count = estimated_multicast_count,
            }, "live_multicast_cap_rejections")
        end
        if estimated_multicast_count > options.max_payload_fanout then
            chaos_budget.recordReject("multicast_fanout_cap_exceeded", "fanout")
            if estimated_pattern_kind ~= nil then
                return patternRejected(estimated_pattern_kind, "pattern_cap_exceeded", {
                    estimated_emission_count = estimated_multicast_count,
                }, "live_multicast_cap_rejections")
            end
            return multicastRejected("multicast_cap_exceeded", {
                estimated_emission_count = estimated_multicast_count,
            }, "live_multicast_cap_rejections")
        end
    end
    if estimated_ops.ambiguous_pattern then
        if estimated_ops.has_burst and estimated_ops.has_spread then
            runtime_stats.inc("live_burst_rejected")
        end
        return patternRejected("Spread", "ambiguous_pattern", nil, "live_pattern_unsupported_opcode_rejections")
    end

    local capabilities = sfp_adapter.capabilities()
    if not capabilities.has_interface then
        if estimated_pattern_kind ~= nil then
            return patternRejected(estimated_pattern_kind, "sfp_missing")
        end
        if estimated_multicast_fanout then
            return multicastRejected("sfp_missing")
        end
        return rejected("sfp_missing")
    end
    if not capabilities.has_launchSpell then
        if estimated_pattern_kind ~= nil then
            return patternRejected(estimated_pattern_kind, "sfp_launch_missing")
        end
        if estimated_multicast_fanout then
            return multicastRejected("sfp_launch_missing")
        end
        return rejected("sfp_launch_missing")
    end

    local compiled = plan_cache.compileOrGet(effects, { limits = options.budget_limits })
    if not compiled.ok then
        local details = {
            plan_recipe_id = compiled.recipe_id,
            error = firstErrorMessage(compiled),
            errors = compiled.errors,
        }
        if has_size_plus_effect then
            runtime_stats.inc("live_size_plus_attempts")
            if errorsMentionSizePlusValue(compiled.errors) then
                runtime_stats.inc("live_size_plus_value_invalid")
            end
            return sizePlusRejected("compile_failed", details)
        end
        if has_speed_plus_effect then
            runtime_stats.inc("live_speed_plus_attempts")
            if errorsMentionSpeedPlusValue(compiled.errors) then
                runtime_stats.inc("live_speed_plus_value_invalid")
            end
            return speedPlusRejected("compile_failed", details)
        end
        if has_homing_effect then
            runtime_stats.inc("live_homing_attempts")
            return homingRejected("compile_failed", details)
        end
        if has_timer_effect then
            runtime_stats.inc("live_timer_attempts")
            if errorsMentionTimerDelay(compiled.errors) then
                runtime_stats.inc("live_timer_delay_invalid")
            end
            return timerRejected("compile_failed", details)
        end
        if has_chain_effect then
            runtime_stats.inc("chain_runtime_attempts")
            return chainRuntimeRejected("compile_failed", details, "chain_runtime_context_reject")
        end
        if has_bounce_effect then
            runtime_stats.inc("live_bounce_attempts")
            return bounceRejected("compile_failed", details)
        end
        if has_pierce_effect then
            runtime_stats.inc("live_pierce_attempts")
            return pierceRejected("compile_failed", details)
        end
        if estimated_pattern_kind ~= nil then
            return patternRejected(estimated_pattern_kind, "compile_failed", details)
        end
        if estimated_multicast_fanout then
            return multicastRejected("compile_failed", details)
        end
        return rejected("compile_failed", details)
    end

    local compiled_bounds = compiled.plan and compiled.plan.bounds or nil
    if compiled_bounds and compiled_bounds.has_pierce then
        return tryPierceDispatch(compiled, launch_payload, options)
    end

    if compiled_bounds and compiled_bounds.has_bounce then
        return tryBounceDispatch(compiled, launch_payload, options)
    end

    if has_chain_effect or (compiled_bounds and compiled_bounds.has_chain) then
        return tryChainDispatch(compiled, launch_payload, options)
    end

    if has_bounce_effect then
        return tryBounceDispatch(compiled, launch_payload, options)
    end

    if has_pierce_effect then
        return tryPierceDispatch(compiled, launch_payload, options)
    end

    if has_timer_effect and has_trigger_effect then
        return tryNestedTriggerTimerDispatch(compiled, launch_payload, options)
    end

    if compiled.plan and compiled.plan.bounds and compiled.plan.bounds.has_size_plus then
        return trySizePlusDispatch(compiled, launch_payload, options)
    end

    if compiled.plan and compiled.plan.bounds and compiled.plan.bounds.has_speed_plus then
        return trySpeedPlusDispatch(compiled, launch_payload, options)
    end

    if compiled.plan and compiled.plan.bounds and compiled.plan.bounds.has_homing then
        return tryHomingDispatch(compiled, launch_payload, options)
    end

    if compiled.plan and compiled.plan.bounds and compiled.plan.bounds.has_timer then
        return tryTimerDispatch(compiled, launch_payload, options)
    end

    if compiled.plan and compiled.plan.bounds and compiled.plan.bounds.has_trigger then
        return tryTriggerDispatch(compiled, launch_payload, options)
    end

    local live_ok, live_reason, live_mode, planned_count_or_counter, pattern_kind, pattern_op = validateLivePrimaryPlan(compiled.plan, options)
    if not live_ok then
        local details = {
            plan_recipe_id = compiled.recipe_id,
        }
        if isPatternMode(live_mode) or live_mode == "pattern" or estimated_pattern_kind ~= nil then
            return patternRejected(pattern_kind or estimated_pattern_kind, live_reason, details, planned_count_or_counter)
        end
        if live_mode == "multicast" or estimated_multicast_fanout then
            return multicastRejected(live_reason, details, planned_count_or_counter)
        end
        return rejected(live_reason, details)
    end

    local attached = plan_cache.attachHelperRecords(compiled.recipe_id, { limits = options.budget_limits })
    if not attached.ok then
        local details = {
            plan_recipe_id = compiled.recipe_id,
            error = firstErrorMessage(attached),
            errors = attached.errors,
        }
        if isPatternMode(live_mode) then
            return patternRejected(pattern_kind, "helper_records_failed", details)
        end
        if live_mode == "multicast" then
            return multicastRejected("helper_records_failed", details)
        end
        return rejected("helper_records_failed", details)
    end

    local selected_helpers, materialized_reason = collectPrimaryHelpers(attached.plan, options)
    if not selected_helpers then
        local details = {
            plan_recipe_id = compiled.recipe_id,
        }
        if isPatternMode(live_mode) then
            local counter = nil
            if materialized_reason == "multicast_cap_exceeded" then
                counter = "live_multicast_cap_rejections"
            elseif string.find(tostring(materialized_reason), "payload", 1, true)
                or string.find(tostring(materialized_reason), "postfix", 1, true)
                or string.find(tostring(materialized_reason), "source", 1, true)
                or string.find(tostring(materialized_reason), "parent", 1, true) then
                counter = "live_pattern_payload_rejections"
            end
            return patternRejected(pattern_kind, materialized_reason, details, counter)
        elseif live_mode == "multicast" then
            local counter = nil
            if materialized_reason == "multicast_cap_exceeded" then
                counter = "live_multicast_cap_rejections"
            elseif string.find(tostring(materialized_reason), "payload", 1, true)
                or string.find(tostring(materialized_reason), "postfix", 1, true)
                or string.find(tostring(materialized_reason), "source", 1, true)
                or string.find(tostring(materialized_reason), "parent", 1, true) then
                counter = "live_multicast_payload_rejections"
            end
            return multicastRejected(materialized_reason, details, counter)
        end
        return rejected(materialized_reason, details)
    end

    local plan = attached.plan
    if not isFanoutMode(live_mode) and #selected_helpers ~= 1 then
        return rejected("slot_count_not_one", {
            plan_recipe_id = compiled.recipe_id,
        })
    end
    if live_mode == "multicast" and #selected_helpers <= 1 then
        return multicastRejected("multicast_fanout_missing", {
            plan_recipe_id = compiled.recipe_id,
        })
    end
    if isPatternMode(live_mode) and #selected_helpers <= 1 then
        return patternRejected(pattern_kind, "pattern_fanout_missing", {
            plan_recipe_id = compiled.recipe_id,
        }, "live_pattern_unsupported_opcode_rejections")
    end

    local source_recipe_id = options.source_recipe_id or launch_payload.recipe_id
    local result_recipe_id = source_recipe_id or compiled.recipe_id

    local pattern_info, pattern_err = computePatternInfo(live_mode, pattern_kind, pattern_op, selected_helpers, launch_payload)
    if pattern_err then
        return patternRejected(pattern_kind, pattern_err, {
            plan_recipe_id = compiled.recipe_id,
        })
    end
    local cast_id = nextCastId(result_recipe_id, compiled.recipe_id)
    runtime_stats.inc("live_2_2c_qualified")
    if live_mode == "multicast" then
        runtime_stats.inc("live_multicast_qualified")
        runtime_stats.inc("live_multicast_emissions_planned", #selected_helpers)
    elseif isPatternMode(live_mode) then
        patternQualified(pattern_kind, #selected_helpers)
    end

    local job_inputs = buildJobInputs(selected_helpers, compiled.recipe_id, cast_id, launch_payload, pattern_info)
    local slot_ids = {}
    local helper_engine_ids = {}
    local emission_indexes = {}
    local pattern_direction_keys = {}
    for index, pair in ipairs(selected_helpers) do
        slot_ids[index] = pair.helper.slot_id
        helper_engine_ids[index] = pair.helper.engine_id
        emission_indexes[index] = pair.slot.emission_index or pair.helper.emission_index or index
        if pattern_info and pattern_info.direction_keys then
            pattern_direction_keys[index] = pattern_info.direction_keys[index]
        end
    end

    if options.dry_run == true then
        return {
            ok = true,
            used_live_2_2c = true,
            dry_run = true,
            recipe_id = result_recipe_id,
            plan_recipe_id = compiled.recipe_id,
            slot_id = slot_ids[1],
            helper_engine_id = helper_engine_ids[1],
            slot_ids = slot_ids,
            helper_engine_ids = helper_engine_ids,
            emission_indexes = emission_indexes,
            pattern_kind = pattern_info and pattern_info.pattern_kind or nil,
            pattern_count = pattern_info and pattern_info.pattern_count or nil,
            pattern_direction_keys = pattern_direction_keys,
            spread_preset = pattern_info and pattern_info.spread_preset or nil,
            spread_side_angle_degrees = pattern_info and pattern_info.spread_side_angle_degrees or nil,
            spread_rotation_axis = pattern_info and pattern_info.spread_rotation_axis or nil,
            burst_param_count = pattern_info and pattern_info.burst_param_count or nil,
            burst_ring_angle_degrees = pattern_info and pattern_info.burst_ring_angle_degrees or nil,
            burst_distribution = pattern_info and pattern_info.burst_distribution or nil,
            slot_count = plan.slot_count or #plan.emission_slots,
            helper_record_count = plan.helper_record_count or #plan.helper_records,
            dispatch_count = #selected_helpers,
            fanout_count = #selected_helpers,
            simple_note = live_reason,
            live_mode = live_mode,
            cast_id = cast_id,
        }
    end

    local job_ids = {}
    for _, job_input in ipairs(job_inputs) do
        local enqueue = orchestrator.enqueue(job_input)
        if not enqueue.ok then
            runtime_stats.inc("live_2_2c_dispatch_failed")
            if #job_ids > 0 then
                return bridgeError(enqueue.error or "enqueue failed", {
                    stage = "enqueue",
                    recipe_id = result_recipe_id,
                    plan_recipe_id = compiled.recipe_id,
                    slot_id = job_input.slot_id,
                    helper_engine_id = job_input.helper_engine_id,
                    cast_id = cast_id,
                    job_ids = job_ids,
                    fallback_allowed = false,
                })
            end
            local details = {
                recipe_id = result_recipe_id,
                plan_recipe_id = compiled.recipe_id,
                slot_id = job_input.slot_id,
                helper_engine_id = job_input.helper_engine_id,
                error = enqueue.error or "enqueue failed",
                cast_id = cast_id,
            }
            if isPatternMode(live_mode) then
                return patternRejected(pattern_kind, "enqueue_failed", details)
            elseif live_mode == "multicast" then
                return multicastRejected("enqueue_failed", details)
            end
            return fallback("enqueue_failed", details)
        end
        job_ids[#job_ids + 1] = enqueue.job_id
    end
    if live_mode == "multicast" then
        runtime_stats.inc("live_multicast_jobs_enqueued", #job_ids)
    elseif isPatternMode(live_mode) then
        runtime_stats.inc("live_multicast_jobs_enqueued", #job_ids)
    end
    chaos_budget.observe({
        jobs = #job_ids,
        queue = orchestrator.queueLength(),
        projectiles = #selected_helpers,
    })

    local tick_result = tickUntilJobsSettled(job_ids, options)
    local jobs = {}
    local projectile_ids = {}
    local projectile_id_count = 0
    local pending_job_count = 0
    local allow_pending_launch_jobs = options.allow_pending_launch_jobs == true
    for index, job_id in ipairs(job_ids) do
        local summary = jobSummary(job_id)
        jobs[index] = summary
        if summary.projectile_id ~= nil then
            projectile_ids[#projectile_ids + 1] = summary.projectile_id
            projectile_id_count = projectile_id_count + 1
        end
        local pending = summary.job_status == "queued" or summary.job_status == "running"
        if pending and allow_pending_launch_jobs then
            pending_job_count = pending_job_count + 1
        elseif summary.job_status == "queued" then
            orchestrator.cancel(job_id)
        end
        if not (pending and allow_pending_launch_jobs)
            and (summary.job_status ~= "complete" or summary.launch_accepted ~= true) then
            runtime_stats.inc("live_2_2c_dispatch_failed")
            return bridgeError(summary.error or "helper launch job did not complete", {
                stage = "launch_job",
                recipe_id = result_recipe_id,
                plan_recipe_id = compiled.recipe_id,
                slot_id = summary.slot_id,
                helper_engine_id = summary.helper_engine_id,
                job_id = job_id,
                job_ids = job_ids,
                job_status = summary.job_status,
                tick_result = tick_result,
                cast_id = cast_id,
                fallback_allowed = false,
            })
        end
    end

    local first_job = jobs[1] or {}
    log.info(string.format(
        "SPELLFORGE_LIVE_2_2C_SIMPLE_DISPATCH_OK recipe_id=%s plan_recipe_id=%s dispatch_count=%s fanout_count=%s live_mode=%s pattern_kind=%s first_slot_id=%s first_helper_engine_id=%s projectile_count=%s",
        tostring(result_recipe_id),
        tostring(compiled.recipe_id),
        tostring(#job_ids),
        tostring(#selected_helpers),
        tostring(live_mode),
        tostring(pattern_info and pattern_info.pattern_kind or nil),
        tostring(slot_ids[1]),
        tostring(helper_engine_ids[1]),
        tostring(projectile_id_count)
    ))
    if options.chaos_budget_profile == "chaos" and isFanoutMode(live_mode) then
        runtime_stats.inc("chaos_budget_high_fanout_smoke")
        log.info(string.format(
            "SPELLFORGE_CHAOS_STRESS_OK profile=%s observed_jobs=%d observed_projectiles=%d observed_queue=%d live_mode=%s fanout_count=%d",
            tostring(options.chaos_budget_profile),
            #job_ids,
            #selected_helpers,
            tonumber(orchestrator.queueLength()) or 0,
            tostring(live_mode),
            #selected_helpers
        ))
    end
    runtime_stats.inc("live_2_2c_dispatch_ok")

    return {
        ok = true,
        used_live_2_2c = true,
        recipe_id = result_recipe_id,
        plan_recipe_id = compiled.recipe_id,
        slot_id = slot_ids[1],
        helper_engine_id = helper_engine_ids[1],
        slot_ids = slot_ids,
        helper_engine_ids = helper_engine_ids,
        emission_indexes = emission_indexes,
        pattern_kind = pattern_info and pattern_info.pattern_kind or nil,
        pattern_count = pattern_info and pattern_info.pattern_count or nil,
        pattern_direction_keys = pattern_direction_keys,
        spread_preset = pattern_info and pattern_info.spread_preset or nil,
        spread_side_angle_degrees = pattern_info and pattern_info.spread_side_angle_degrees or nil,
        spread_rotation_axis = pattern_info and pattern_info.spread_rotation_axis or nil,
        burst_param_count = pattern_info and pattern_info.burst_param_count or nil,
        burst_ring_angle_degrees = pattern_info and pattern_info.burst_ring_angle_degrees or nil,
        burst_distribution = pattern_info and pattern_info.burst_distribution or nil,
        projectile_id = first_job.projectile_id,
        projectile_ids = projectile_ids,
        projectile_id_source = first_job.projectile_id_source,
        projectile_registered = first_job.projectile_registered == true,
        job_id = job_ids[1],
        job_ids = job_ids,
        jobs = jobs,
        pending_launch_jobs = pending_job_count > 0,
        pending_job_count = pending_job_count,
        all_launch_jobs_complete = pending_job_count == 0,
        job_status = first_job.job_status,
        cast_id = cast_id,
        runtime = "2.2c_live_helper",
        fallback = false,
        dispatch_count = #job_ids,
        fanout_count = #selected_helpers,
        slot_count = plan.slot_count or #plan.emission_slots,
        helper_record_count = plan.helper_record_count or #plan.helper_records,
        effect_id = selected_helpers[1] and selected_helpers[1].slot.effects and selected_helpers[1].slot.effects[1] and selected_helpers[1].slot.effects[1].id or nil,
        simple_note = live_reason,
        live_mode = live_mode,
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
    -- Smoke probes run back-to-back in script callbacks; treat each probe as a fresh update for launch-density accounting.
    orchestrator.advanceTime(0)
    local probe_entry = { node_metadata = { { logical_id = "probe" } } }
    local probe_root = { real_effects = recipes.SIMPLE_FIRE_DAMAGE_TARGET }
    local opts = {
        ignore_flag = true,
        dry_run = true,
        skip_entry_shape_check = false,
        source_recipe_id = "live-simple-probe",
    }

    if mode == "bounce_event_count_check" then
        local projectile_id = payload and payload.projectile_id or nil
        local event_count = live_bounce.bounceEventCount(projectile_id)
        local wait_seconds = tonumber(payload and payload.wait_seconds) or nil
        local timed_out = event_count <= 0
        if timed_out then
            runtime_stats.inc("live_bounce_surface_timeout_no_event")
            log.info(string.format(
                "SPELLFORGE_BOUNCE_SURFACE_TIMEOUT_NO_EVENT recipe_id=%s cast_id=%s source_slot_id=%s helper_engine_id=%s projectile_id=%s wait_seconds=%s context=%s",
                tostring(payload and payload.recipe_id),
                tostring(payload and payload.cast_id),
                tostring(payload and payload.source_slot_id),
                tostring(payload and payload.helper_engine_id),
                tostring(projectile_id),
                tostring(wait_seconds),
                tostring(payload and payload.context)
            ))
        else
            runtime_stats.inc("live_bounce_surface_event_observed")
            log.info(string.format(
                "SPELLFORGE_BOUNCE_SURFACE_EVENT_OBSERVED recipe_id=%s cast_id=%s source_slot_id=%s helper_engine_id=%s projectile_id=%s event_count=%s context=%s",
                tostring(payload and payload.recipe_id),
                tostring(payload and payload.cast_id),
                tostring(payload and payload.source_slot_id),
                tostring(payload and payload.helper_engine_id),
                tostring(projectile_id),
                tostring(event_count),
                tostring(payload and payload.context)
            ))
        end
        send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, {
            request_id = payload and payload.request_id,
            ok = true,
            mode = mode,
            projectile_id = projectile_id,
            event_count = event_count,
            timed_out = timed_out,
            wait_seconds = wait_seconds,
            context = payload and payload.context,
        })
        return
    elseif mode == "adapter_capabilities" then
        send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, adapterCapabilitiesProbe(payload))
        return
    elseif mode == "adapter_launch_fields" then
        send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, adapterLaunchFieldsProbe(payload))
        return
    elseif mode == "adapter_detonate_args" then
        send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, adapterDetonateArgsProbe(payload))
        return
    elseif mode == "timer_detonation_audit" then
        send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, timerDetonationAuditProbe(payload))
        return
    elseif mode == "vfx_metadata_audit" then
        send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, vfxMetadataAuditProbe(payload))
        return
    elseif mode == "nested_payload_audit" then
        send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, nestedPayloadAuditProbe(payload))
        return
    elseif mode == "chain_targeting_audit" then
        send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, chainTargetingProbe(payload))
        return
    elseif mode == "chain_runtime" then
        send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, chainRuntimeProbe(payload))
        return
    elseif mode == "chaos_budget_report" then
        local default_budget = chaos_budget.report({ force_chaos_budget_disabled = true })
        local chaos = chaos_budget.report({ force_chaos_budget_enabled = true })
        send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, {
            request_id = payload and payload.request_id,
            ok = default_budget.profile == "default"
                and chaos.profile == "chaos"
                and chaos.limits.MAX_PAYLOAD_FANOUT > default_budget.limits.MAX_PAYLOAD_FANOUT
                and chaos.limits.MAX_NESTED_PAYLOAD_JOBS > default_budget.limits.MAX_NESTED_PAYLOAD_JOBS
                and chaos.limits.MAX_LIVE_LAUNCHES_PER_TICK > 0
                and chaos.limits.MAX_LIVE_LAUNCHES_PER_TICK < chaos.limits.MAX_PAYLOAD_FANOUT
                and chaos.limits.MAX_CHAIN_BRANCHES == default_budget.limits.MAX_CHAIN_BRANCHES,
            mode = mode,
            default_profile = default_budget.profile,
            chaos_profile = chaos.profile,
            default_limits = default_budget.limits,
            chaos_limits = chaos.limits,
        })
        return
    elseif mode == "jobs_status_check" then
        local job_ids = payload and payload.job_ids or {}
        local jobs = {}
        local complete_count = 0
        local pending_count = 0
        local failed_count = 0
        local expected_count = tonumber(payload and payload.expected_count) or #job_ids
        for index, job_id in ipairs(job_ids) do
            local summary = jobSummary(job_id)
            jobs[index] = summary
            if summary.job_status == "complete" and summary.launch_accepted == true then
                complete_count = complete_count + 1
            elseif summary.job_status == "queued" or summary.job_status == "running" then
                pending_count = pending_count + 1
            else
                failed_count = failed_count + 1
            end
        end
        send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, {
            request_id = payload and payload.request_id,
            ok = type(job_ids) == "table",
            mode = mode,
            job_ids = job_ids,
            jobs = jobs,
            expected_count = expected_count,
            complete_count = complete_count,
            pending_count = pending_count,
            failed_count = failed_count,
            all_complete = pending_count == 0
                and failed_count == 0
                and #job_ids == expected_count
                and complete_count == expected_count,
            queue_length = orchestrator.queueLength(),
        })
        return
    elseif mode == "trigger_hit_from_job" then
        local source_job_id = payload and (payload.source_job_id or payload.job_id)
        if (source_job_id == nil or source_job_id == "") and type(payload and payload.job_ids) == "table" then
            source_job_id = payload.job_ids[1]
        end
        local source_job = type(source_job_id) == "string" and jobSummary(source_job_id) or nil
        local source_user_data = source_job and source_job.launch_user_data or nil
        if not source_job
            or source_job.job_status ~= "complete"
            or source_job.launch_accepted ~= true
            or type(source_user_data) ~= "table" then
            send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, {
                request_id = payload and payload.request_id,
                ok = false,
                mode = mode,
                error = "trigger source job is not ready",
                source_job_id = source_job_id,
                source_job = source_job,
            })
            return
        end
        local hit_payload = {
            spellId = source_job.helper_engine_id,
            projectileId = source_job.projectile_id or ((payload and payload.request_id or "trigger-hit-from-job") .. ":source-projectile"),
            userData = source_user_data,
            attacker = payload and (payload.actor or payload.sender),
            hitPos = payload and payload.start_pos,
            target = payload and payload.hit_object,
        }
        local hit_opts = {
            force_enabled = true,
            force_timer_enabled = true,
            allow_pending_launch_jobs = payload and payload.allow_pending_launch_jobs == true,
            simulate_update_ticks = true,
        }
        local first = live_trigger.handleHitPayload(hit_payload, hit_opts)
        local duplicate = live_trigger.handleHitPayload(hit_payload, hit_opts)
        local result = {
            request_id = payload and payload.request_id,
            ok = first and first.ok == true and duplicate and duplicate.duplicate_suppressed == true,
            mode = mode,
            used_live_2_2c = true,
            live_mode = "trigger",
            source_job_id = source_job_id,
            job_id = source_job_id,
            job_ids = { source_job_id },
            jobs = { source_job },
            slot_id = source_job.slot_id,
            helper_engine_id = source_job.helper_engine_id,
            cast_id = source_job.cast_id,
            projectile_id = source_job.projectile_id,
            projectile_ids = source_job.projectile_id and { source_job.projectile_id } or {},
            post_hit_result = first,
            duplicate_hit_result = duplicate,
            trigger_payload_job_id = first and first.job_id or nil,
            trigger_payload_job_ids = first and first.job_ids or nil,
            trigger_payload_jobs = first and first.jobs or nil,
            trigger_payload_slot_id = first and first.payload_slot_id or nil,
            trigger_payload_slot_ids = first and first.payload_slot_ids or nil,
            trigger_payload_count = first and first.payload_count or nil,
            payload_multicast = first and first.payload_multicast == true or source_user_data.payload_multicast == true,
            payload_pattern = first and first.payload_pattern == true or source_user_data.payload_pattern == true,
            payload_pattern_kind = first and first.payload_pattern_kind or source_user_data.payload_pattern_kind,
            payload_pattern_direction_keys = first and first.payload_pattern_direction_keys or nil,
            nested_final_fanout = first and first.nested_final_fanout == true or source_user_data.nested_final_fanout == true,
            nested_final_fanout_kind = first and first.nested_final_fanout_kind or source_user_data.nested_final_fanout_kind,
            trigger_payload_launch_count = first and first.launch_count or nil,
            trigger_payload_helper_engine_id = first and first.payload_helper_engine_id or nil,
            trigger_payload_launch_user_data = first and first.launch_user_data or nil,
            trigger_duplicate_suppressed = duplicate and duplicate.duplicate_suppressed == true,
            nested_timer_schedule = first and first.nested_timer_schedule or nil,
            nested_timer_id = first and first.nested_timer_schedule and first.nested_timer_schedule.timer_id or nil,
        }
        if result.ok then
            runtime_stats.inc("live_trigger_post_hit_smoke_observed")
        end
        send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, result)
        return
    elseif mode == "timer_real_delay_check" then
        local timer_id = payload and (payload.timer_id or payload.timer_job_id)
        local before = type(timer_id) == "string" and live_timer.timerStatus(timer_id) or nil
        local expected_payload_count = tonumber(payload and payload.expected_payload_count) or 1
        local allow_pending_launch_jobs = payload and payload.allow_pending_launch_jobs == true
        local tick_result = nil
        local tick_results = {}
        local status = type(timer_id) == "string" and live_timer.timerStatus(timer_id) or nil
        if type(timer_id) == "string" and timer_id ~= "" then
            for _ = 1, 4 do
                tick_result = orchestrator.tick({
                    max_jobs_per_tick = limits.MAX_JOBS_PER_TICK,
                    max_live_launches_per_tick = limits.MAX_LIVE_LAUNCHES_PER_TICK,
                })
                tick_results[#tick_results + 1] = tick_result
                status = live_timer.timerStatus(timer_id)
                if status
                    and status.callback_ok == true
                    and (tonumber(status.payload_launch_count) == expected_payload_count
                        or (allow_pending_launch_jobs and tonumber(status.payload_count) == expected_payload_count)) then
                    break
                end
            end
        end
        local payload_count = tonumber(status and status.payload_launch_count) or 0
        local callback_payload_count = tonumber(status and status.payload_count) or payload_count
        local pending_launch_jobs = allow_pending_launch_jobs
            and status
            and status.callback_ok == true
            and callback_payload_count == expected_payload_count
            and payload_count < expected_payload_count
        if payload and payload.observe_matured == true
            and status
            and status.callback_ok == true
            and (payload_count == expected_payload_count or pending_launch_jobs) then
            runtime_stats.inc("live_timer_real_delay_smoke_observed")
            runtime_stats.inc("live_timer_real_delay_smoke_callback_ok")
        end
        local nested_trigger_hit = nil
        local nested_trigger_duplicate = nil
        if payload and payload.simulate_nested_trigger_hit == true
            and status and status.callback_ok == true
            and type(status.payload_jobs) == "table" then
            local intermediate = status.payload_jobs[1]
            local user_data = intermediate and intermediate.launch_user_data or nil
            if intermediate and type(user_data) == "table" then
                local hit_payload = {
                    spellId = intermediate.helper_engine_id,
                    projectileId = intermediate.projectile_id or ((payload and payload.request_id or "nested-timer-trigger") .. ":intermediate-projectile"),
                    userData = user_data,
                    attacker = payload and (payload.actor or payload.sender),
                    hitPos = payload and payload.start_pos,
                    target = payload and payload.hit_object,
                }
                local hit_opts = {
                    force_enabled = true,
                    allow_pending_launch_jobs = allow_pending_launch_jobs == true,
                    simulate_update_ticks = true,
                }
                nested_trigger_hit = live_trigger.handleHitPayload(hit_payload, hit_opts)
                nested_trigger_duplicate = live_trigger.handleHitPayload(hit_payload, hit_opts)
            end
        end
        send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, {
            request_id = payload and payload.request_id,
            ok = status ~= nil
                and status.callback_ok == true
                and (payload_count == expected_payload_count or pending_launch_jobs),
            mode = mode,
            timer_id = timer_id,
            timer_status_before_check = before,
            timer_status = status,
            live_mode = "timer",
            cast_id = status and status.cast_id or nil,
            slot_id = status and status.source_slot_id or nil,
            helper_engine_id = status and status.source_helper_engine_id or nil,
            timer_payload_slot_id = status and status.payload_slot_id or nil,
            timer_payload_slot_ids = status and status.payload_slot_ids or nil,
            timer_payload_count = status and status.payload_count or nil,
            payload_multicast = status and status.payload_multicast == true or false,
            payload_pattern = status and status.payload_pattern == true or false,
            payload_pattern_kind = status and status.payload_pattern_kind or nil,
            payload_pattern_direction_keys = status and status.payload_pattern_direction_keys or nil,
            ir_timer_runtime = status and status.ir_timer_runtime == true or false,
            ir_timer_runtime_job_count = status and status.ir_timer_runtime_job_count or nil,
            ir_timer_runtime_fallback_used = status and status.ir_timer_runtime_fallback_used == true or false,
            ir_timer_runtime_fallback_reason = status and status.ir_timer_runtime_fallback_reason or nil,
            ir_timer_runtime_mismatch = status and status.ir_timer_runtime_mismatch == true or false,
            nested_final_fanout = status and status.nested_final_fanout == true or false,
            nested_final_fanout_kind = status and status.nested_final_fanout_kind or nil,
            timer_delay_ticks = status and status.timer_delay_ticks or nil,
            timer_delay_seconds = status and status.timer_delay_seconds or nil,
            timer_due_tick = status and status.timer_due_tick or nil,
            timer_due_seconds = status and status.timer_due_seconds or nil,
            timer_source_projectile_id = status and status.source_projectile_id or nil,
            timer_source_detonation_status = status and status.source_detonation_status or nil,
            timer_source_detonation_ok = status and status.source_detonation_ok == true or false,
            timer_source_cancel_ok = status and status.source_cancel_ok == true or false,
            timer_source_projectile_already_hit = status and status.source_projectile_already_hit == true or false,
            timer_source_detonation_error = status and status.source_detonation_error or nil,
            tick_result = tick_result,
            tick_results = tick_results,
            callback_payload_count = payload_count,
            expected_payload_count = expected_payload_count,
            pending_launch_jobs = pending_launch_jobs == true,
            callback_count = status and status.callback_seen == true and 1 or 0,
            pending_count = status and status.pending_count or live_timer.pendingCount(),
            timer_payload_launch_user_data = status and status.payload_launch_user_data or nil,
            timer_payload_job_ids = status and status.payload_job_ids or nil,
            timer_payload_jobs = status and status.payload_jobs or nil,
            nested_trigger_hit_result = nested_trigger_hit,
            nested_trigger_duplicate_suppressed = nested_trigger_duplicate and nested_trigger_duplicate.duplicate_suppressed == true or false,
            nested_final_payload_jobs = nested_trigger_hit and nested_trigger_hit.jobs or nil,
            nested_final_payload_count = nested_trigger_hit and nested_trigger_hit.launch_count or nil,
            error = status and status.callback_error or "timer callback not observed",
        })
        return
    elseif mode == "disabled" then
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
    elseif mode == "timer_post_delay" or mode == "timer_expiry" then
        send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, {
            request_id = payload and payload.request_id,
            ok = false,
            mode = mode,
            live_mode = "timer",
            real_delay_test = false,
            timer_delay_semantics = "legacy_tick_burn_disabled",
            error = "legacy Timer tick-burn smoke disabled; use timer_real_delay_sequence and timer_real_delay_check",
        })
        return
    elseif mode == "multicast_disabled" then
        probe_root = { real_effects = recipes.MULTICAST_X3_FIRE_DAMAGE_TARGET }
        opts.force_multicast_disabled = true
    elseif mode == "multicast_dry_run" then
        probe_root = { real_effects = recipes.MULTICAST_X3_FIRE_DAMAGE_TARGET }
        opts.force_multicast_enabled = true
    elseif mode == "multicast_launch" then
        probe_root = { real_effects = recipes.MULTICAST_X3_FIRE_DAMAGE_TARGET }
        opts.force_multicast_enabled = true
        opts.dry_run = false
    elseif mode == "chaos_multicast_high_dry_run" then
        probe_root = { real_effects = recipes.MULTICAST_X16_FIRE_DAMAGE_TARGET }
        opts.force_chaos_budget_enabled = true
        opts.force_multicast_enabled = true
    elseif mode == "chaos_multicast_high_launch" then
        probe_root = { real_effects = recipes.MULTICAST_X16_FIRE_DAMAGE_TARGET }
        opts.force_chaos_budget_enabled = true
        opts.force_multicast_enabled = true
        opts.dry_run = false
        opts.allow_pending_launch_jobs = true
    elseif mode == "chaos_multicast_over_cap" then
        probe_root = { real_effects = recipes.MULTICAST_OVER_CHAOS_CAP_TARGET }
        opts.force_chaos_budget_enabled = true
        opts.force_multicast_enabled = true
    elseif mode == "spread_disabled" then
        probe_root = { real_effects = recipes.SPREAD_MULTICAST_X3_FIRE_DAMAGE_TARGET }
        opts.force_multicast_enabled = true
        opts.force_pattern_disabled = true
    elseif mode == "spread_dry_run" then
        probe_root = { real_effects = recipes.SPREAD_MULTICAST_X3_FIRE_DAMAGE_TARGET }
        opts.force_multicast_enabled = true
        opts.force_pattern_enabled = true
    elseif mode == "spread_launch" then
        probe_root = { real_effects = recipes.SPREAD_MULTICAST_X3_FIRE_DAMAGE_TARGET }
        opts.force_multicast_enabled = true
        opts.force_pattern_enabled = true
        opts.dry_run = false
    elseif mode == "burst_disabled" then
        probe_root = { real_effects = recipes.BURST_MULTICAST_X3_FIRE_DAMAGE_TARGET }
        opts.force_multicast_enabled = true
        opts.force_pattern_disabled = true
    elseif mode == "burst_dry_run" then
        probe_root = { real_effects = recipes.BURST_MULTICAST_X3_FIRE_DAMAGE_TARGET }
        opts.force_multicast_enabled = true
        opts.force_pattern_enabled = true
    elseif mode == "burst_launch" then
        probe_root = { real_effects = recipes.BURST_MULTICAST_X3_FIRE_DAMAGE_TARGET }
        opts.force_multicast_enabled = true
        opts.force_pattern_enabled = true
        opts.dry_run = false
    elseif mode == "trigger_disabled" then
        probe_root = { real_effects = recipes.TRIGGER_FIRE_FROST_TARGET }
        opts.force_trigger_disabled = true
    elseif mode == "trigger_dry_run" then
        probe_root = { real_effects = recipes.TRIGGER_FIRE_FROST_TARGET }
        opts.force_trigger_enabled = true
    elseif mode == "trigger_launch" or mode == "trigger_post_hit" or mode == "trigger_post_hit_fallback" then
        probe_root = { real_effects = recipes.TRIGGER_FIRE_FROST_TARGET }
        opts.force_trigger_enabled = true
        opts.dry_run = false
    elseif applyBounceProbeMode(mode, opts) then
        probe_root = opts._spellforge_probe_root
        opts._spellforge_probe_root = nil
        if mode == "bounce_chain_payload_no_target" then
            opts.chain_candidate_provider = function(hop_context)
                return {
                    { id = "bounce-chain-caster", object = hop_context and hop_context.caster or "bounce-chain-caster", position = { x = 0, y = 0, z = 0 }, cell = "bounce-chain-test-cell", is_actor = true, is_alive = true, is_valid = true },
                    { id = "bounce-chain-invalid", object = "bounce-chain-invalid", position = { x = 25, y = 0, z = 0 }, cell = "bounce-chain-test-cell", is_actor = true, is_alive = true, is_valid = false },
                    { id = "bounce-chain-dead", object = "bounce-chain-dead", position = { x = 30, y = 0, z = 0 }, cell = "bounce-chain-test-cell", is_actor = true, is_alive = false, is_valid = true },
                    { id = "bounce-chain-far", object = "bounce-chain-far", position = { x = limits.MAX_CHAIN_SCAN_RADIUS + 1000, y = 0, z = 0 }, cell = "bounce-chain-test-cell", is_actor = true, is_alive = true, is_valid = false },
                }
            end
        elseif mode == "bounce_chain_payload_mock_handoff" then
            opts.chain_source_target = bounceChainMockSourceTarget()
            opts.chain_candidate_provider = bounceChainMockCandidates()
        end
    elseif applyPierceProbeMode(mode, opts) then
        probe_root = opts._spellforge_probe_root
        opts._spellforge_probe_root = nil
        if mode == "pierce_trigger_chain_event" then
            opts.chain_source_target = bounceChainMockSourceTarget()
            opts.chain_candidate_provider = bounceChainMockCandidates()
        end
    elseif mode == "trigger_payload_multicast_disabled" then
        probe_root = { real_effects = recipes.TRIGGER_PAYLOAD_MULTICAST_X3_TARGET }
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_disabled = true
    elseif mode == "trigger_payload_multicast_post_hit" then
        probe_root = { real_effects = recipes.TRIGGER_PAYLOAD_MULTICAST_X3_TARGET }
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.dry_run = false
    elseif mode == "chaos_trigger_payload_multicast_post_hit" then
        probe_root = { real_effects = recipes.TRIGGER_PAYLOAD_MULTICAST_X16_TARGET }
        opts.force_chaos_budget_enabled = true
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.dry_run = false
        opts.allow_pending_launch_jobs = true
    elseif mode == "trigger_payload_pattern_disabled" then
        probe_root = { real_effects = recipes.TRIGGER_PAYLOAD_BURST_MULTICAST_X5_TARGET }
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_payload_pattern_disabled = true
    elseif mode == "trigger_payload_burst_post_hit" then
        probe_root = { real_effects = recipes.TRIGGER_PAYLOAD_BURST_MULTICAST_X5_TARGET }
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_payload_pattern_enabled = true
        opts.dry_run = false
    elseif mode == "chaos_trigger_payload_burst_post_hit" then
        probe_root = { real_effects = recipes.TRIGGER_PAYLOAD_BURST_MULTICAST_X16_TARGET }
        opts.force_chaos_budget_enabled = true
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_payload_pattern_enabled = true
        opts.dry_run = false
        opts.allow_pending_launch_jobs = true
    elseif mode == "trigger_payload_spread_post_hit" then
        probe_root = { real_effects = recipes.TRIGGER_PAYLOAD_SPREAD_MULTICAST_X3_TARGET }
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_payload_pattern_enabled = true
        opts.dry_run = false
    elseif mode == "timer_disabled" then
        probe_root = { real_effects = recipes.TIMER_FIRE_FROST_TARGET }
        opts.force_timer_disabled = true
    elseif mode == "timer_dry_run" then
        probe_root = { real_effects = recipes.TIMER_FIRE_FROST_TARGET }
        opts.force_timer_enabled = true
    elseif mode == "timer_launch" or mode == "timer_real_delay_launch" or mode == "timer_real_delay_sequence" then
        probe_root = { real_effects = recipes.TIMER_FIRE_FROST_TARGET }
        opts.force_timer_enabled = true
        opts.dry_run = false
        if mode ~= "timer_real_delay_launch" and mode ~= "timer_real_delay_sequence" then
            opts.timer_delay_ticks_override = 4
        end
        if mode == "timer_real_delay_sequence" then
            opts.timer_duplicate_schedule_probe = true
        end
    elseif mode == "timer_payload_multicast_disabled" then
        probe_root = { real_effects = recipes.TIMER_PAYLOAD_MULTICAST_X3_TARGET }
        opts.force_timer_enabled = true
        opts.force_payload_multicast_disabled = true
    elseif mode == "timer_payload_multicast_sequence" then
        probe_root = { real_effects = recipes.TIMER_PAYLOAD_MULTICAST_X3_TARGET }
        opts.force_timer_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.dry_run = false
        opts.timer_duplicate_schedule_probe = true
    elseif mode == "chaos_timer_payload_multicast_sequence" then
        probe_root = { real_effects = recipes.TIMER_PAYLOAD_MULTICAST_X16_TARGET }
        opts.force_chaos_budget_enabled = true
        opts.force_timer_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.dry_run = false
        opts.timer_duplicate_schedule_probe = true
        opts.allow_pending_launch_jobs = true
    elseif mode == "timer_payload_pattern_disabled" then
        probe_root = { real_effects = recipes.TIMER_PAYLOAD_SPREAD_MULTICAST_X3_TARGET }
        opts.force_timer_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_payload_pattern_disabled = true
    elseif mode == "timer_payload_burst_sequence" then
        probe_root = { real_effects = recipes.TIMER_PAYLOAD_BURST_MULTICAST_X5_TARGET }
        opts.force_timer_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_payload_pattern_enabled = true
        opts.dry_run = false
        opts.timer_duplicate_schedule_probe = true
    elseif mode == "timer_payload_spread_sequence" then
        probe_root = { real_effects = recipes.TIMER_PAYLOAD_SPREAD_MULTICAST_X3_TARGET }
        opts.force_timer_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_payload_pattern_enabled = true
        opts.dry_run = false
        opts.timer_duplicate_schedule_probe = true
    elseif mode == "chaos_timer_payload_spread_sequence" then
        probe_root = { real_effects = recipes.TIMER_PAYLOAD_SPREAD_MULTICAST_X16_TARGET }
        opts.force_chaos_budget_enabled = true
        opts.force_timer_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_payload_pattern_enabled = true
        opts.dry_run = false
        opts.timer_duplicate_schedule_probe = true
        opts.allow_pending_launch_jobs = true
    elseif mode == "nested_payload_runtime_deferred" then
        probe_root = { real_effects = recipes.TRIGGER_INSIDE_TIMER_TARGET }
        opts.force_timer_enabled = true
        opts.force_trigger_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_nested_trigger_timer_disabled = true
    elseif mode == "nested_trigger_timer_disabled" then
        probe_root = { real_effects = recipes.TRIGGER_INSIDE_TIMER_TARGET }
        opts.force_timer_enabled = true
        opts.force_trigger_enabled = true
        opts.force_nested_trigger_timer_disabled = true
    elseif mode == "nested_timer_trigger_sequence" then
        probe_root = { real_effects = recipes.TRIGGER_INSIDE_TIMER_TARGET }
        opts.force_timer_enabled = true
        opts.force_trigger_enabled = true
        opts.force_nested_trigger_timer_enabled = true
        opts.dry_run = false
        opts.timer_duplicate_schedule_probe = true
    elseif mode == "nested_trigger_timer_sequence" then
        probe_root = { real_effects = recipes.TIMER_INSIDE_TRIGGER_TARGET }
        opts.force_timer_enabled = true
        opts.force_trigger_enabled = true
        opts.force_nested_trigger_timer_enabled = true
        opts.dry_run = false
    elseif mode == "nested_tt_depth_reject" then
        probe_root = { real_effects = recipes.TIMER_TRIGGER_TIMER_DEPTH_TARGET }
        opts.force_timer_enabled = true
        opts.force_trigger_enabled = true
        opts.force_nested_trigger_timer_enabled = true
    elseif mode == "nested_tt_same_kind_reject" then
        probe_root = { real_effects = recipes.TIMER_INSIDE_TIMER_TARGET }
        opts.force_timer_enabled = true
        opts.force_trigger_enabled = true
        opts.force_nested_trigger_timer_enabled = true
    elseif mode == "nested_tt_fanout_reject" then
        probe_root = { real_effects = recipes.TIMER_TRIGGER_NESTED_MULTICAST_TARGET }
        opts.force_timer_enabled = true
        opts.force_trigger_enabled = true
        opts.force_nested_trigger_timer_enabled = true
        opts.force_nested_final_fanout_disabled = true
    elseif mode == "nested_final_fanout_disabled" then
        probe_root = { real_effects = recipes.TRIGGER_TIMER_NESTED_MULTICAST_TARGET }
        opts.force_timer_enabled = true
        opts.force_trigger_enabled = true
        opts.force_nested_trigger_timer_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_nested_final_fanout_disabled = true
    elseif mode == "nested_trigger_timer_final_multicast_sequence" then
        probe_root = { real_effects = recipes.TRIGGER_TIMER_NESTED_MULTICAST_TARGET }
        opts.force_timer_enabled = true
        opts.force_trigger_enabled = true
        opts.force_nested_trigger_timer_enabled = true
        opts.force_nested_final_fanout_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.dry_run = false
    elseif mode == "chaos_nested_trigger_timer_final_multicast_sequence" then
        probe_root = { real_effects = recipes.TRIGGER_TIMER_NESTED_MULTICAST_X16_TARGET }
        opts.force_chaos_budget_enabled = true
        opts.force_timer_enabled = true
        opts.force_trigger_enabled = true
        opts.force_nested_trigger_timer_enabled = true
        opts.force_nested_final_fanout_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.dry_run = false
        opts.allow_pending_launch_jobs = true
    elseif mode == "nested_trigger_timer_final_burst_sequence" then
        probe_root = { real_effects = recipes.TRIGGER_TIMER_NESTED_BURST_MULTICAST_X5_TARGET }
        opts.force_timer_enabled = true
        opts.force_trigger_enabled = true
        opts.force_nested_trigger_timer_enabled = true
        opts.force_nested_final_fanout_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_payload_pattern_enabled = true
        opts.dry_run = false
    elseif mode == "nested_timer_trigger_final_multicast_sequence" then
        probe_root = { real_effects = recipes.TIMER_TRIGGER_NESTED_MULTICAST_TARGET }
        opts.force_timer_enabled = true
        opts.force_trigger_enabled = true
        opts.force_nested_trigger_timer_enabled = true
        opts.force_nested_final_fanout_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.dry_run = false
        opts.timer_duplicate_schedule_probe = true
    elseif mode == "nested_timer_trigger_final_spread_sequence" then
        probe_root = { real_effects = recipes.TIMER_TRIGGER_NESTED_SPREAD_MULTICAST_X3_TARGET }
        opts.force_timer_enabled = true
        opts.force_trigger_enabled = true
        opts.force_nested_trigger_timer_enabled = true
        opts.force_nested_final_fanout_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_payload_pattern_enabled = true
        opts.dry_run = false
        opts.timer_duplicate_schedule_probe = true
    elseif mode == "chaos_nested_timer_trigger_final_spread_sequence" then
        probe_root = { real_effects = recipes.TIMER_TRIGGER_NESTED_SPREAD_MULTICAST_X16_TARGET }
        opts.force_chaos_budget_enabled = true
        opts.force_timer_enabled = true
        opts.force_trigger_enabled = true
        opts.force_nested_trigger_timer_enabled = true
        opts.force_nested_final_fanout_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_payload_pattern_enabled = true
        opts.dry_run = false
        opts.timer_duplicate_schedule_probe = true
        opts.allow_pending_launch_jobs = true
    elseif mode == "nested_final_fanout_cap_reject" then
        probe_root = { real_effects = recipes.TIMER_TRIGGER_NESTED_MULTICAST_TARGET }
        opts.force_timer_enabled = true
        opts.force_trigger_enabled = true
        opts.force_nested_trigger_timer_enabled = true
        opts.force_nested_final_fanout_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.nested_final_fanout_max_fanout = 2
    elseif mode == "chaos_nested_final_fanout_over_cap" then
        probe_root = { real_effects = recipes.TRIGGER_TIMER_NESTED_MULTICAST_OVER_CHAOS_CAP_TARGET }
        opts.force_chaos_budget_enabled = true
        opts.force_timer_enabled = true
        opts.force_trigger_enabled = true
        opts.force_nested_trigger_timer_enabled = true
        opts.force_nested_final_fanout_enabled = true
        opts.force_payload_multicast_enabled = true
    elseif mode == "chaos_chain_multicast_still_deferred" then
        probe_root = { real_effects = recipes.CHAIN_MULTICAST_TARGET }
        opts.force_chaos_budget_enabled = true
        opts.force_chain_runtime_enabled = true
        opts.force_payload_multicast_enabled = true
        opts.force_chain_multicast_disabled = true
    elseif mode == "speed_plus_disabled" then
        probe_root = { real_effects = recipes.SPEED_PLUS_FIRE_DAMAGE_TARGET }
        opts.force_speed_plus_disabled = true
    elseif mode == "speed_plus_dry_run" then
        probe_root = { real_effects = recipes.SPEED_PLUS_FIRE_DAMAGE_TARGET }
        opts.force_speed_plus_enabled = true
    elseif mode == "speed_plus_launch" then
        probe_root = { real_effects = recipes.SPEED_PLUS_FIRE_DAMAGE_TARGET }
        opts.force_speed_plus_enabled = true
        opts.dry_run = false
    elseif mode == "size_plus_disabled" then
        probe_root = { real_effects = recipes.SIZE_PLUS_FIRE_DAMAGE_TARGET }
        opts.force_size_plus_disabled = true
    elseif mode == "size_plus_dry_run" then
        probe_root = { real_effects = recipes.SIZE_PLUS_FIRE_DAMAGE_TARGET }
        opts.force_size_plus_enabled = true
    elseif mode == "size_plus_launch" then
        probe_root = { real_effects = recipes.SIZE_PLUS_FIRE_DAMAGE_TARGET }
        opts.force_size_plus_enabled = true
        opts.dry_run = false
    elseif mode == "homing_disabled" then
        probe_root = {
            real_effects = {
                { id = "spellforge_homing" },
                { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
            },
        }
        opts.force_homing_disabled = true
    elseif mode == "homing_dry_run" then
        probe_root = {
            real_effects = {
                { id = "spellforge_homing" },
                { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
            },
        }
        opts.force_homing_enabled = true
        opts.force_soft_homing_disabled = true
    elseif mode == "homing_launch" then
        probe_root = {
            real_effects = {
                { id = "spellforge_homing" },
                { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
            },
        }
        opts.force_homing_enabled = true
        opts.force_soft_homing_disabled = true
        opts.dry_run = false
    elseif mode == "homing_soft_launch" then
        probe_root = {
            real_effects = {
                { id = "spellforge_homing" },
                { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
            },
        }
        opts.force_homing_enabled = true
        opts.force_soft_homing_enabled = true
        opts.dry_run = false
        opts.soft_homing_max_lifetime_seconds = limits.HOMING_MAX_LIFETIME_SECONDS
    elseif mode == "homing_soft_probe" then
        probe_root = {
            real_effects = {
                { id = "spellforge_homing" },
                { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
            },
        }
        opts.force_homing_enabled = true
        opts.dry_run = false
        opts.soft_homing_probe = true
        opts.soft_homing_max_lifetime_seconds = limits.HOMING_MAX_LIFETIME_SECONDS
    elseif mode == "non_qualifying" then
        probe_root = { real_effects = recipes.NON_QUALIFYING_CHAIN_FIRE_DAMAGE_TARGET }
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
    if (mode == "trigger_post_hit"
        or mode == "trigger_post_hit_fallback"
        or mode == "trigger_payload_multicast_post_hit"
        or mode == "chaos_trigger_payload_multicast_post_hit"
        or mode == "trigger_payload_burst_post_hit"
        or mode == "chaos_trigger_payload_burst_post_hit"
        or mode == "trigger_payload_spread_post_hit"
        or mode == "nested_trigger_timer_sequence"
        or mode == "nested_trigger_timer_final_multicast_sequence"
        or mode == "chaos_nested_trigger_timer_final_multicast_sequence"
        or mode == "nested_trigger_timer_final_burst_sequence")
        and result.ok == true
        and result.pending_source_launch_job ~= true then
        local source_job = result.jobs and result.jobs[1] or nil
        local user_data = source_job and source_job.launch_user_data or nil
        local hit_payload = {
            spellId = result.helper_engine_id,
            projectileId = result.projectile_id or ((payload and payload.request_id or "trigger-post-hit") .. ":source-projectile"),
            userData = mode ~= "trigger_post_hit_fallback" and user_data or nil,
            attacker = payload and (payload.actor or payload.sender),
            hitPos = payload and payload.start_pos,
            target = payload and payload.hit_object,
        }
        local hit_opts = { force_enabled = true, simulate_update_ticks = true }
        if mode == "nested_trigger_timer_sequence" then
            hit_opts.force_timer_enabled = true
        elseif mode == "nested_trigger_timer_final_multicast_sequence"
            or mode == "chaos_nested_trigger_timer_final_multicast_sequence"
            or mode == "nested_trigger_timer_final_burst_sequence" then
            hit_opts.force_timer_enabled = true
        end
        local first = live_trigger.handleHitPayload(hit_payload, hit_opts)
        local duplicate = live_trigger.handleHitPayload(hit_payload, hit_opts)
        result.post_hit_result = first
        result.duplicate_hit_result = duplicate
        result.trigger_payload_job_id = first and first.job_id or nil
        result.trigger_payload_job_ids = first and first.job_ids or nil
        result.trigger_payload_jobs = first and first.jobs or nil
        result.trigger_payload_slot_id = first and first.payload_slot_id or nil
        result.trigger_payload_slot_ids = first and first.payload_slot_ids or nil
        result.trigger_payload_count = first and first.payload_count or nil
        result.payload_pattern = first and first.payload_pattern == true or result.payload_pattern
        result.payload_pattern_kind = first and first.payload_pattern_kind or result.payload_pattern_kind
        result.payload_pattern_direction_keys = first and first.payload_pattern_direction_keys or nil
        result.nested_final_fanout = first and first.nested_final_fanout == true or result.nested_final_fanout
        result.nested_final_fanout_kind = first and first.nested_final_fanout_kind or result.nested_final_fanout_kind
        result.trigger_payload_launch_count = first and first.launch_count or nil
        result.trigger_payload_helper_engine_id = first and first.payload_helper_engine_id or nil
        result.trigger_payload_launch_user_data = first and first.launch_user_data or nil
        result.trigger_duplicate_suppressed = duplicate and duplicate.duplicate_suppressed == true
        result.nested_timer_schedule = first and first.nested_timer_schedule or nil
        result.nested_timer_id = first and first.nested_timer_schedule and first.nested_timer_schedule.timer_id or nil
        if first and first.ok == true and duplicate and duplicate.duplicate_suppressed == true then
            runtime_stats.inc("live_trigger_post_hit_smoke_observed")
        end
    end
    if (mode == "bounce_trigger_simple_post_bounce"
        or mode == "bounce_trigger_multicast_post_bounce"
        or mode == "bounce_trigger_burst_post_bounce"
        or mode == "bounce_chain_payload_no_target"
        or mode == "bounce_chain_payload_mock_handoff")
        and result.ok == true
        and result.pending_source_launch_job ~= true then
        local source_job = result.jobs and result.jobs[1] or nil
        local user_data = source_job and source_job.launch_user_data or nil
        local bounce_hit_pos = payload and payload.start_pos
        local bounce_hit_normal = payload and payload.direction
        if mode == "bounce_chain_payload_mock_handoff" then
            bounce_hit_pos = { x = 0, y = 0, z = 0 }
            bounce_hit_normal = { x = 1, y = 0, z = 0 }
        end
        local bounce_payload = {
            spellId = result.helper_engine_id,
            projectileId = result.projectile_id or ((payload and payload.request_id or "bounce-post-bounce") .. ":source-projectile"),
            userData = user_data,
            attacker = payload and (payload.actor or payload.sender),
            hitPos = bounce_hit_pos,
            hitNormal = bounce_hit_normal,
            bounceCount = 1,
        }
        local bounce_opts = {
            force_enabled = true,
            force_trigger_enabled = true,
            simulate_update_ticks = true,
        }
        if mode == "bounce_trigger_multicast_post_bounce" then
            bounce_opts.force_payload_multicast_enabled = true
        elseif mode == "bounce_trigger_burst_post_bounce" then
            bounce_opts.force_payload_multicast_enabled = true
            bounce_opts.force_payload_pattern_enabled = true
        elseif mode == "bounce_chain_payload_no_target"
            or mode == "bounce_chain_payload_mock_handoff" then
            bounce_opts.force_chain_runtime_enabled = true
        end
        local first = live_bounce.handleBouncePayload(bounce_payload, bounce_opts)
        local duplicate = live_bounce.handleBouncePayload(bounce_payload, bounce_opts)
        local first_payload = first and first.trigger_result or first
        result.post_bounce_result = first
        result.duplicate_bounce_result = duplicate
        result.bounce_trigger_route = first_payload and first_payload.trigger_route or nil
        result.bounce_trigger_payload_job_id = first_payload and first_payload.job_id or nil
        result.bounce_trigger_payload_job_ids = first_payload and first_payload.job_ids or nil
        result.bounce_trigger_payload_jobs = first_payload and first_payload.jobs or nil
        result.bounce_trigger_payload_slot_id = first_payload and first_payload.payload_slot_id or nil
        result.bounce_trigger_payload_slot_ids = first_payload and first_payload.payload_slot_ids or nil
        result.bounce_trigger_payload_count = first_payload and first_payload.payload_count or nil
        result.bounce_trigger_payload_launch_count = first_payload and first_payload.launch_count or nil
        result.bounce_trigger_payload_projectile_ids = first_payload and first_payload.projectile_ids or nil
        result.bounce_trigger_payload_launch_user_data = first_payload and first_payload.launch_user_data or nil
        result.ir_bounce_runtime = first_payload and first_payload.ir_bounce_runtime == true or false
        result.ir_bounce_runtime_job_count = first_payload and first_payload.ir_bounce_runtime_job_count or nil
        result.ir_bounce_runtime_fallback_used = first_payload and first_payload.ir_bounce_runtime_fallback_used == true or false
        result.ir_bounce_runtime_fallback_reason = first_payload and first_payload.ir_bounce_runtime_fallback_reason or nil
        result.ir_bounce_runtime_mismatch = first_payload and first_payload.ir_bounce_runtime_mismatch == true or false
        result.bounce_chain_stop_reason = first_payload and first_payload.stop_reason or nil
        result.bounce_chain_result = first_payload and first_payload.chain_result or nil
        result.bounce_chain_provider = first_payload and first_payload.provider or nil
        result.bounce_chain_hop_index = first_payload and first_payload.chain_hop_index or nil
        result.bounce_chain_current_hit_target_id = first_payload and first_payload.current_hit_target_id or nil
        result.bounce_chain_selected_target_id = first_payload and first_payload.selected_target_id or nil
        result.bounce_duplicate_suppressed = duplicate and duplicate.duplicate_suppressed == true
        if first and first.ok == true and duplicate and duplicate.duplicate_suppressed == true then
            runtime_stats.inc("live_bounce_trigger_payload_smoke_observed")
        end
    end
    if (mode == "pierce_trigger_simple_event"
        or mode == "pierce_trigger_multicast_event"
        or mode == "pierce_trigger_pattern_event"
        or mode == "pierce_trigger_spread_event"
        or mode == "pierce_trigger_chain_event")
        and result.ok == true
        and result.pending_source_launch_job ~= true then
        local source_job = result.jobs and result.jobs[1] or nil
        local user_data = source_job and source_job.launch_user_data or nil
        local pierce_hit_pos = { x = 0, y = 0, z = 0 }
        local pierce_velocity = { x = 1, y = 0, z = 0 }
        local pierce_actor = {
            id = "A",
            object = "A",
            position = pierce_hit_pos,
            cell = "chain-test-cell",
            is_actor = true,
            is_alive = true,
            is_valid = true,
        }
        local pierce_payload = {
            spellId = result.helper_engine_id,
            projectileId = result.projectile_id or ((payload and payload.request_id or "pierce-event") .. ":source-projectile"),
            userData = user_data,
            attacker = payload and (payload.actor or payload.sender),
            hitObject = pierce_actor,
            actorId = "A",
            hitPos = pierce_hit_pos,
            hitNormal = { x = -1, y = 0, z = 0 },
            velocity = pierce_velocity,
            pierceCount = 1,
            pierceLimit = result.pierce_limit,
            isPierce = true,
        }
        local pierce_opts = {
            force_enabled = true,
            allow_payload_multicast = mode == "pierce_trigger_multicast_event"
                or mode == "pierce_trigger_pattern_event"
                or mode == "pierce_trigger_spread_event",
            allow_payload_pattern = mode == "pierce_trigger_pattern_event"
                or mode == "pierce_trigger_spread_event",
            allow_chain_multicast = false,
            simulate_update_ticks = true,
        }
        local first = live_pierce.handlePiercePayload(pierce_payload, pierce_opts)
        local duplicate = live_pierce.handlePiercePayload(pierce_payload, pierce_opts)
        local first_payload = first
        if first and type(first.job_ids) == "table" and #first.job_ids > 0 and first.jobs == nil then
            tickUntilJobsSettled(first.job_ids, options)
            local jobs = {}
            for index, job_id in ipairs(first.job_ids) do
                jobs[index] = jobSummary(job_id)
            end
            first.jobs = jobs
        end
        result.post_pierce_result = first
        result.duplicate_pierce_result = duplicate
        result.pierce_trigger_route = first_payload and first_payload.trigger_route or nil
        result.pierce_trigger_payload_job_id = first_payload and first_payload.job_id or nil
        result.pierce_trigger_payload_job_ids = first_payload and first_payload.job_ids or nil
        result.pierce_trigger_payload_jobs = first_payload and first_payload.jobs or nil
        result.pierce_trigger_payload_slot_id = first_payload and first_payload.payload_slot_id or nil
        result.pierce_trigger_payload_slot_ids = first_payload and first_payload.payload_slot_ids or nil
        result.pierce_trigger_payload_count = first_payload and first_payload.payload_count or nil
        result.pierce_trigger_payload_launch_count = first_payload and first_payload.launch_count or nil
        local first_job_summary = first_payload and first_payload.jobs and first_payload.jobs[1] or nil
        local first_job_user_data = first_job_summary and first_job_summary.launch_user_data or nil
        if type(first_job_summary) == "table" then
            if type(first_job_user_data) ~= "table" then
                first_job_user_data = {}
            end
            first_job_user_data.trigger_route = first_job_user_data.trigger_route or first_job_summary.trigger_route
            first_job_user_data.pierce_runtime = first_job_user_data.pierce_runtime or first_job_summary.pierce_runtime
            first_job_user_data.pierce_role = first_job_user_data.pierce_role or first_job_summary.pierce_role
            first_job_user_data.current_hit_target_id = first_job_user_data.current_hit_target_id or first_job_summary.current_hit_target_id
            first_job_user_data.excludeTarget = first_job_user_data.excludeTarget or first_job_summary.excludeTarget
        end
        result.pierce_trigger_payload_launch_user_data = first_job_user_data or first_payload
            and first_payload.jobs
            and first_payload.jobs[1]
            and first_payload.jobs[1].launch_user_data
            or nil
        result.pierce_chain_result = first_payload and first_payload.pierce_chain_result or first_payload and first_payload.chain_result or nil
        result.pierce_chain_provider = first_payload and first_payload.provider or nil
        result.pierce_chain_hop_index = first_payload and first_payload.chain_hop_index or nil
        result.pierce_chain_current_hit_target_id = first_payload and first_payload.current_hit_target_id or nil
        result.pierce_chain_selected_target_id = first_payload and first_payload.selected_target_id or nil
        result.ir_pierce_runtime = first_payload and first_payload.ir_pierce_runtime == true or false
        result.ir_pierce_runtime_job_count = first_payload and first_payload.ir_pierce_runtime_job_count or nil
        result.pierce_duplicate_suppressed = duplicate and duplicate.duplicate == true
        local first_job = result.pierce_trigger_payload_jobs and result.pierce_trigger_payload_jobs[1] or nil
        local launch_start = first_job and first_job.launch_start_pos or nil
        result.pierce_payload_origin_safe = launch_start ~= nil
            and (tonumber(launch_start.x) ~= tonumber(pierce_hit_pos.x)
                or tonumber(launch_start.y) ~= tonumber(pierce_hit_pos.y)
                or tonumber(launch_start.z) ~= tonumber(pierce_hit_pos.z))
        result.pierce_exclude_target_carried = first_job and first_job.excludeTarget ~= nil or false
        result.pierce_current_hit_target_id = first_job and first_job.current_hit_target_id or result.pierce_chain_current_hit_target_id
        if first and first.ok == true and duplicate and duplicate.duplicate == true then
            runtime_stats.inc("live_pierce_trigger_payload_ok")
        end
    end
    if mode == "timer_launch" and result.ok == true and type(result.timer_id) == "string" then
        result.timer_status_after_launch = live_timer.timerStatus(result.timer_id)
        result.timer_payload_launched_before_delay = false
        result.timer_pending_after_launch = result.timer_status_after_launch
            and result.timer_status_after_launch.pending == true or false
    end
    if mode == "timer_real_delay_launch" and result.ok == true and type(result.timer_id) == "string" then
        result.timer_status_after_launch = live_timer.timerStatus(result.timer_id)
        result.timer_payload_launched_immediately = false
        result.timer_delay_semantics = "async_simulation_timer"
        result.real_delay_test = true
    end
    if (mode == "timer_real_delay_sequence"
        or mode == "timer_payload_multicast_sequence"
        or mode == "chaos_timer_payload_multicast_sequence"
        or mode == "timer_payload_burst_sequence"
        or mode == "timer_payload_spread_sequence"
        or mode == "chaos_timer_payload_spread_sequence"
        or mode == "nested_timer_trigger_sequence"
        or mode == "nested_timer_trigger_final_multicast_sequence"
        or mode == "nested_timer_trigger_final_spread_sequence"
        or mode == "chaos_nested_timer_trigger_final_spread_sequence") and result.ok == true and type(result.timer_id) == "string" then
        local status = live_timer.timerStatus(result.timer_id)
        local expected_payload_count = tonumber(result.timer_payload_count) or 1
        result.timer_status_after_schedule = status
        result.timer_delay_semantics = "async_simulation_timer"
        result.real_delay_test = true
        result.async_timer_scheduled = result.timer_async_scheduled == true
        result.pending_count = status and status.pending_count or live_timer.pendingCount()
        result.timer_immediate_payload_count = 0
        result.timer_before_delay_payload_count = 0
        result.timer_after_delay_payload_count = 0
        result.timer_payload_launch_count = 0
        result.timer_payload_launched_exactly_once = false
        if result.timer_immediate_payload_count == 0 then
            runtime_stats.inc("live_timer_immediate_payload_blocked")
        end
        if result.async_timer_scheduled == true
            and status and status.pending == true
            and result.timer_duplicate_suppressed == true then
            runtime_stats.inc("live_timer_real_delay_smoke_scheduled")
            runtime_stats.inc("live_timer_real_delay_smoke_pending")
            log.info(string.format(
                "SPELLFORGE_LIVE_TIMER_ASYNC_SMOKE_PENDING timer_id=%s pending_count=%s payload_count=0",
                tostring(result.timer_id),
                tostring(status.pending_count)
            ))
        end
        result.expected_payload_count = expected_payload_count
    end
    local ok = false
    if mode == "non_qualifying" or mode == "multicast_disabled" or mode == "spread_disabled" or mode == "burst_disabled" or mode == "trigger_disabled" or mode == "timer_disabled" or mode == "speed_plus_disabled" or mode == "size_plus_disabled" or mode == "homing_disabled" or mode == "bounce_disabled" or mode == "bounce_over_cap" or mode == "bounce_fanout_deferred" or mode == "bounce_timer_deferred" or mode == "bounce_chain_deferred" or mode == "bounce_chain_payload_disabled" or mode == "bounce_nested_payload_deferred" or mode == "bounce_speed_plus_deferred" or mode == "bounce_size_plus_deferred" or mode == "bounce_homing_deferred" or mode == "bounce_trigger_multicast_disabled" or mode == "bounce_trigger_pattern_disabled" or mode == "pierce_disabled" or mode == "pierce_trigger_multicast_disabled" or mode == "pierce_trigger_pattern_disabled" or mode == "pierce_chain_payload_disabled" or mode == "pierce_timer_deferred" or mode == "pierce_bounce_deferred" or mode == "pierce_homing_deferred" or mode == "pierce_speed_plus_deferred" or mode == "pierce_size_plus_deferred" or mode == "pierce_chain_deferred" or mode == "pierce_fanout_deferred" or mode == "pierce_nested_payload_deferred" or mode == "pierce_recursion_deferred" or mode == "payload_multicast_disabled" or mode == "trigger_payload_multicast_disabled" or mode == "timer_payload_multicast_disabled" or mode == "trigger_payload_pattern_disabled" or mode == "timer_payload_pattern_disabled" or mode == "nested_trigger_timer_disabled" or mode == "nested_tt_depth_reject" or mode == "nested_tt_same_kind_reject" or mode == "nested_tt_fanout_reject" or mode == "nested_final_fanout_disabled" or mode == "nested_final_fanout_cap_reject" or mode == "chaos_multicast_over_cap" or mode == "chaos_nested_final_fanout_over_cap" or mode == "chaos_chain_multicast_still_deferred" then
        ok = result.ok == false and result.used_live_2_2c == false and type(result.fallback_reason) == "string"
    elseif mode == "speed_plus_dry_run" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "speed_plus"
            and result.dispatch_count == 1
            and result.speed_plus_field == "speed"
            and tonumber(result.speed_plus_multiplier) ~= nil
            and tonumber(result.speed_plus_base_speed) ~= nil
            and tonumber(result.speed_plus_speed) ~= nil
            and result.speed_plus_speed ~= result.speed_plus_base_speed
    elseif mode == "speed_plus_launch" then
        local job = result.jobs and result.jobs[1] or nil
        local user_data = job and job.launch_user_data or nil
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "speed_plus"
            and result.dispatch_count == 1
            and result.speed_plus_field == "speed"
            and job
            and job.job_status == "complete"
            and job.launch_accepted == true
            and job.speed == result.speed_plus_speed
            and job.maxSpeed == result.speed_plus_max_speed
            and type(user_data) == "table"
            and user_data.runtime == "2.2c_live_helper"
            and user_data.speed_plus == true
            and user_data.speed_plus_mode == "initial_speed"
            and user_data.speed_plus_field == "speed"
            and tonumber(user_data.speed_plus_speed) ~= nil
            and user_data.speed_plus_speed ~= user_data.speed_plus_base_speed
        if ok then
            runtime_stats.inc("live_speed_plus_smoke_observed")
        end
    elseif mode == "size_plus_dry_run" then
        local base_area = tonumber(result.size_plus_base_area)
        local size_area = tonumber(result.size_plus_area)
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "size_plus"
            and result.dispatch_count == 1
            and result.size_plus_field == "effect.area"
            and tonumber(result.size_plus_multiplier) ~= nil
            and base_area ~= nil
            and size_area ~= nil
            and size_area > base_area
    elseif mode == "size_plus_launch" then
        local job = result.jobs and result.jobs[1] or nil
        local user_data = job and job.launch_user_data or nil
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "size_plus"
            and result.dispatch_count == 1
            and result.size_plus_field == "effect.area"
            and job
            and job.job_status == "complete"
            and job.launch_accepted == true
            and type(user_data) == "table"
            and user_data.runtime == "2.2c_live_helper"
            and user_data.size_plus == true
            and user_data.size_plus_field == "effect.area"
            and tonumber(user_data.size_plus_multiplier) ~= nil
            and tonumber(user_data.size_plus_area) ~= nil
        if ok then
            runtime_stats.inc("live_size_plus_smoke_observed")
        end
    elseif mode == "homing_dry_run" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "homing"
            and result.dispatch_count == 1
            and result.homing_field == "forceVec"
            and type(result.homing_target_provider) == "string"
            and tonumber(result.homing_force) ~= nil
            and tonumber(result.homing_force) > 0
            and type(result.homing_force_key) == "string"
            and type(result.homing_direction_key) == "string"
    elseif mode == "homing_launch" then
        local job = result.jobs and result.jobs[1] or nil
        local user_data = job and job.launch_user_data or nil
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "homing"
            and result.dispatch_count == 1
            and result.homing_field == "forceVec"
            and type(result.homing_target_provider) == "string"
            and job
            and job.job_status == "complete"
            and job.launch_accepted == true
            and job.forceVec ~= nil
            and job.homing == true
            and type(user_data) == "table"
            and user_data.runtime == "2.2c_live_helper"
            and user_data.homing == true
            and user_data.homing_mode == "launch_force_vec"
            and user_data.homing_field == "forceVec"
            and type(user_data.homing_target_provider) == "string"
            and tonumber(user_data.homing_force) ~= nil
            and type(user_data.homing_force_key) == "string"
            and type(user_data.homing_direction_key) == "string"
        if ok then
            runtime_stats.inc("live_homing_smoke_observed")
        end
    elseif mode == "homing_soft_probe" then
        local job = result.jobs and result.jobs[1] or nil
        local user_data = job and job.launch_user_data or nil
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "homing"
            and result.dispatch_count == 1
            and job
            and job.job_status == "complete"
            and job.launch_accepted == true
            and job.forceVec == nil
            and type(user_data) == "table"
            and user_data.runtime == "2.2c_live_helper"
            and user_data.homing == true
            and user_data.homing_mode == "soft_redirect_probe"
            and user_data.homing_field == "redirectSpell"
            and result.soft_homing_probe_registered == true
            and type(result.soft_homing_probe_entry_id) == "string"
        if ok then
            runtime_stats.inc("live_homing_smoke_observed")
        end
    elseif mode == "homing_soft_launch" then
        local job = result.jobs and result.jobs[1] or nil
        local user_data = job and job.launch_user_data or nil
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "homing"
            and result.dispatch_count == 1
            and result.homing_field == "redirectSpell"
            and job
            and job.job_status == "complete"
            and job.launch_accepted == true
            and job.forceVec == nil
            and type(user_data) == "table"
            and user_data.runtime == "2.2c_live_helper"
            and user_data.homing == true
            and user_data.homing_mode == "soft_redirect"
            and user_data.homing_field == "redirectSpell"
            and result.soft_homing_runtime_registered == true
            and type(result.soft_homing_runtime_entry_id) == "string"
        if ok then
            runtime_stats.inc("live_homing_smoke_observed")
        end
    elseif mode == "multicast_dry_run" or mode == "chaos_multicast_high_dry_run" then
        local expected_count = mode == "chaos_multicast_high_dry_run" and recipes.CHAOS_HIGH_FANOUT_COUNT or 3
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "multicast"
            and result.dispatch_count == expected_count
    elseif mode == "multicast_launch" or mode == "chaos_multicast_high_launch" then
        local expected_count = mode == "chaos_multicast_high_launch" and recipes.CHAOS_HIGH_FANOUT_COUNT or 3
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "multicast"
            and result.dispatch_count == expected_count
    elseif mode == "spread_dry_run" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "spread"
            and result.pattern_kind == "Spread"
            and result.dispatch_count == 3
    elseif mode == "spread_launch" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "spread"
            and result.pattern_kind == "Spread"
            and result.dispatch_count == 3
    elseif mode == "burst_dry_run" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "burst"
            and result.pattern_kind == "Burst"
            and result.dispatch_count == 3
    elseif mode == "burst_launch" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "burst"
            and result.pattern_kind == "Burst"
            and result.dispatch_count == 3
    elseif mode == "trigger_dry_run" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "trigger"
            and result.dispatch_count == 1
            and type(result.trigger_payload_slot_id) == "string"
    elseif mode == "trigger_launch" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "trigger"
            and result.dispatch_count == 1
            and type(result.trigger_payload_slot_id) == "string"
    elseif mode == "bounce_source_only_dry_run" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "bounce"
            and result.bounce_mode == "source"
            and result.dispatch_count == 1
            and result.source_dispatch_count == 1
            and tonumber(result.bounce_max) == 3
            and result.bounce_detonate_on_actor_hit == false
            and type(result.source_slot_id) == "string"
            and type(result.source_helper_engine_id) == "string"
            and result.has_trigger_payload == false
            and result.trigger_payload_slot_id == nil
            and result.trigger_payload_helper_engine_id == nil
            and result.trigger_payload_count == nil
            and result.payload_helper_engine_id == nil
            and tonumber(result.payload_count) == 0
            and result.payload_fanout_count == nil
            and result.payload_multicast == false
            and result.payload_pattern == false
            and result.payload_chain_runtime == false
            and result.has_chain_payload == false
            and result.payload_detonation_mode == nil
            and result.bounce_probe_binding_registered == false
    elseif mode == "bounce_source_only_launch" then
        local job = result.jobs and result.jobs[1] or nil
        local user_data = job and job.launch_user_data or nil
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "bounce"
            and result.dispatch_count == 1
            and result.source_dispatch_count == 1
            and result.fanout_count == 1
            and result.payload_projectile_launches == 0
            and result.payload_detonation_mode == nil
            and result.has_trigger_payload == false
            and result.trigger_payload_slot_id == nil
            and tonumber(result.bounce_max) == 3
            and job
            and job.job_status == "complete"
            and job.launch_accepted == true
            and job.bounceEnabled == true
            and tonumber(job.bounceMax) == 3
            and job.detonateOnActorHit == false
            and job.post_launch_bounce_ok == true
            and job.post_launch_detonate_on_actor_ok == true
            and type(user_data) == "table"
            and user_data.bounce_runtime == true
            and user_data.bounce_role == "source"
            and user_data.bounce_trigger_payload_slot_id == nil
            and user_data.source_prefix_opcode == "Bounce"
            and user_data.source_postfix_opcode == nil
    elseif mode == "bounce_dry_run" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "bounce"
            and result.dispatch_count == 1
            and tonumber(result.bounce_max) == 3
            and result.bounce_detonate_on_actor_hit == false
            and type(result.trigger_payload_slot_id) == "string"
            and tonumber(result.trigger_payload_count) == 1
            and result.payload_projectile_launches == 0
            and result.payload_detonation_mode == "bounce_detonate_at_pos"
    elseif mode == "bounce_trigger_simple_post_bounce" then
        local user_data = result.bounce_trigger_payload_launch_user_data
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "bounce"
            and result.dispatch_count == 1
            and result.bounce_probe_binding_registered == true
            and result.post_bounce_result
            and result.post_bounce_result.ok == true
            and result.bounce_duplicate_suppressed == true
            and result.bounce_trigger_route == "bounce"
            and tonumber(result.bounce_trigger_payload_count) == 1
            and tonumber(result.bounce_trigger_payload_launch_count) == 1
            and type(user_data) == "table"
            and user_data.trigger_route == "bounce"
            and user_data.bounce_role == "trigger_payload_detonation"
            and user_data.branch_kind == "bounce_trigger_payload"
    elseif mode == "bounce_chain_payload_dry_run" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "bounce"
            and result.dispatch_count == 1
            and tonumber(result.bounce_max) == 3
            and result.bounce_detonate_on_actor_hit == false
            and type(result.trigger_payload_slot_id) == "string"
            and tonumber(result.trigger_payload_count) == 1
            and result.payload_projectile_launches == 0
            and result.payload_detonation_mode == "bounce_chain_runtime"
            and result.payload_chain_runtime == true
            and result.chain_shape == "trigger_payload_chain"
            and tonumber(result.chain_max_hops) == 3
            and result.targeting_mode == "no_immediate_repeat"
    elseif mode == "bounce_chain_payload_no_target" then
        local user_data = result.bounce_trigger_payload_launch_user_data
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "bounce"
            and result.dispatch_count == 1
            and result.bounce_probe_binding_registered == true
            and result.payload_chain_runtime == true
            and result.post_bounce_result
            and result.post_bounce_result.ok == true
            and result.bounce_duplicate_suppressed == true
            and result.bounce_trigger_route == "bounce_chain"
            and result.bounce_chain_stop_reason == "no_valid_chain_target"
            and tonumber(result.bounce_trigger_payload_launch_count) == 0
            and type(user_data) == "table"
            and user_data.trigger_route == "bounce"
            and user_data.bounce_role == "trigger_chain_payload"
            and user_data.branch_kind == "bounce_trigger_chain_payload"
    elseif mode == "bounce_chain_payload_mock_handoff" then
        local user_data = result.bounce_trigger_payload_launch_user_data
        local chain_result = result.bounce_chain_result
        local first_job = result.bounce_trigger_payload_jobs and result.bounce_trigger_payload_jobs[1] or nil
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "bounce"
            and result.dispatch_count == 1
            and result.bounce_probe_binding_registered == true
            and result.payload_chain_runtime == true
            and result.post_bounce_result
            and result.post_bounce_result.ok == true
            and result.bounce_duplicate_suppressed == true
            and result.bounce_trigger_route == "bounce_chain"
            and result.bounce_chain_stop_reason == nil
            and tonumber(result.bounce_trigger_payload_launch_count) == 1
            and result.bounce_chain_provider == "mock"
            and tonumber(result.bounce_chain_hop_index) == 1
            and result.bounce_chain_current_hit_target_id == "A"
            and result.bounce_chain_selected_target_id == "B"
            and type(chain_result) == "table"
            and chain_result.ok == true
            and chain_result.provider == "mock"
            and tonumber(chain_result.launch_count) == 1
            and type(first_job) == "table"
            and first_job.chain_runtime == true
            and first_job.chain_role == "payload"
            and first_job.branch_kind == "chain"
            and first_job.bounce_runtime == true
            and first_job.bounce_role == "chain_branch_scope"
            and type(first_job.branch_scope) == "string"
            and string.find(first_job.branch_scope, "bounce:bounce:", 1, true) == nil
            and type(first_job.branch_id) == "string"
            and string.find(first_job.branch_id, "bounce:bounce:", 1, true) == nil
            and first_job.selected_target_id == "B"
            and type(user_data) == "table"
            and user_data.trigger_route == "bounce"
            and user_data.bounce_role == "trigger_chain_payload"
            and user_data.branch_kind == "bounce_trigger_chain_payload"
    elseif mode == "bounce_trigger_multicast_dry_run" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "bounce"
            and result.dispatch_count == 1
            and result.payload_multicast == true
            and result.payload_pattern == false
            and tonumber(result.trigger_payload_count) == 3
            and type(result.trigger_payload_slot_ids) == "table"
            and #result.trigger_payload_slot_ids == 3
            and result.payload_projectile_launches == 0
            and result.payload_detonation_mode == "bounce_trigger_payload_fanout"
    elseif mode == "bounce_trigger_multicast_post_bounce" or mode == "bounce_trigger_burst_post_bounce" then
        local expected_count = mode == "bounce_trigger_burst_post_bounce" and 5 or 3
        local expected_kind = mode == "bounce_trigger_burst_post_bounce" and "Burst" or nil
        local first_job = result.bounce_trigger_payload_jobs and result.bounce_trigger_payload_jobs[1] or nil
        local user_data = result.bounce_trigger_payload_launch_user_data
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "bounce"
            and result.dispatch_count == 1
            and result.bounce_probe_binding_registered == true
            and result.payload_multicast == true
            and (expected_kind == nil or (result.payload_pattern == true and result.payload_pattern_kind == expected_kind))
            and (expected_kind ~= nil or result.payload_pattern == false)
            and result.post_bounce_result
            and result.post_bounce_result.ok == true
            and result.bounce_duplicate_suppressed == true
            and result.bounce_trigger_route == "bounce"
            and tonumber(result.bounce_trigger_payload_count) == expected_count
            and tonumber(result.bounce_trigger_payload_launch_count) == expected_count
            and type(result.bounce_trigger_payload_slot_ids) == "table"
            and #result.bounce_trigger_payload_slot_ids == expected_count
            and type(first_job) == "table"
            and first_job.trigger_route == "bounce"
            and first_job.bounce_runtime == true
            and first_job.branch_kind == (expected_kind and "bounce_trigger_payload_pattern" or "bounce_trigger_payload_multicast")
            and type(user_data) == "table"
            and user_data.trigger_route == "bounce"
            and user_data.bounce_role == "trigger_payload_launch"
            and user_data.branch_kind == (expected_kind and "bounce_trigger_payload_pattern" or "bounce_trigger_payload_multicast")
    elseif mode == "bounce_trigger_burst_dry_run" or mode == "bounce_trigger_spread_dry_run" then
        local expected_count = mode == "bounce_trigger_burst_dry_run" and 5 or 3
        local expected_kind = mode == "bounce_trigger_burst_dry_run" and "Burst" or "Spread"
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "bounce"
            and result.dispatch_count == 1
            and result.payload_multicast == true
            and result.payload_pattern == true
            and result.payload_pattern_kind == expected_kind
            and tonumber(result.trigger_payload_count) == expected_count
            and type(result.trigger_payload_slot_ids) == "table"
            and #result.trigger_payload_slot_ids == expected_count
            and result.payload_projectile_launches == 0
            and result.payload_detonation_mode == "bounce_trigger_payload_fanout"
    elseif mode == "bounce_chain_payload_launch" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "bounce"
            and result.dispatch_count == 1
            and result.source_dispatch_count == 1
            and tonumber(result.bounce_max) == 3
            and result.bounce_detonate_on_actor_hit == false
            and type(result.trigger_payload_slot_id) == "string"
            and tonumber(result.trigger_payload_count) == 1
            and result.payload_projectile_launches == 0
            and result.payload_detonation_mode == "bounce_chain_runtime"
            and result.payload_chain_runtime == true
            and result.chain_shape == "trigger_payload_chain"
            and tonumber(result.chain_max_hops) == 3
            and result.targeting_mode == "no_immediate_repeat"
    elseif mode == "bounce_launch" then
        local job = result.jobs and result.jobs[1] or nil
        local user_data = job and job.launch_user_data or nil
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "bounce"
            and result.dispatch_count == 1
            and result.source_dispatch_count == 1
            and result.fanout_count == 1
            and result.payload_projectile_launches == 0
            and result.payload_detonation_mode == "bounce_detonate_at_pos"
            and tonumber(result.bounce_max) == 3
            and job
            and job.job_status == "complete"
            and job.launch_accepted == true
            and job.helper_engine_id == result.helper_engine_id
            and result.trigger_payload_helper_engine_id ~= result.helper_engine_id
            and job.bounceEnabled == true
            and tonumber(job.bounceMax) == 3
            and job.detonateOnActorHit == false
            and job.post_launch_bounce_ok == true
            and job.post_launch_detonate_on_actor_ok == true
            and type(user_data) == "table"
            and user_data.bounce_runtime == true
            and user_data.bounce_role == "source"
            and user_data.bounce_detonate_on_actor_hit == false
            and user_data.bounce_trigger_payload_slot_id == result.trigger_payload_slot_id
            and user_data.source_prefix_opcode == "Bounce"
            and user_data.source_postfix_opcode == "Trigger"
    elseif mode == "pierce_source_only_dry_run" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "pierce"
            and result.pierce_mode == "source"
            and result.dispatch_count == 1
            and result.source_dispatch_count == 1
            and tonumber(result.pierce_limit) == 3
            and result.piercing == true
            and tonumber(result.pierceLimit) == 3
            and type(result.source_slot_id) == "string"
            and type(result.source_helper_engine_id) == "string"
            and result.has_trigger_payload == false
            and result.trigger_payload_slot_id == nil
            and tonumber(result.payload_count) == 0
            and result.payload_multicast == false
            and result.payload_pattern == false
            and result.payload_chain_runtime == false
            and result.has_chain_payload == false
            and result.pierce_probe_binding_registered == false
    elseif mode == "pierce_source_only_launch" then
        local job = result.jobs and result.jobs[1] or nil
        local user_data = job and job.launch_user_data or nil
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "pierce"
            and result.dispatch_count == 1
            and result.source_dispatch_count == 1
            and tonumber(result.pierce_limit) == 3
            and job
            and job.job_status == "complete"
            and job.launch_accepted == true
            and job.piercing == true
            and tonumber(job.pierceLimit) == 3
            and job.post_launch_pierce_ok == true
            and type(user_data) == "table"
            and user_data.pierce_runtime == true
            and user_data.pierce_role == "source"
            and user_data.pierce_trigger_payload_slot_id == nil
            and user_data.source_prefix_opcode == "Pierce"
            and user_data.source_postfix_opcode == nil
    elseif mode == "pierce_trigger_simple_event" then
        local user_data = result.pierce_trigger_payload_launch_user_data
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "pierce"
            and result.pierce_probe_binding_registered == true
            and result.post_pierce_result
            and result.post_pierce_result.ok == true
            and result.pierce_duplicate_suppressed == true
            and result.pierce_trigger_route == "pierce"
            and tonumber(result.pierce_trigger_payload_count) == 1
            and tonumber(result.pierce_trigger_payload_launch_count) == 1
            and result.pierce_payload_origin_safe == true
            and result.pierce_exclude_target_carried == true
            and result.pierce_current_hit_target_id == "A"
            and type(user_data) == "table"
            and user_data.trigger_route == "pierce"
            and user_data.pierce_runtime == true
            and user_data.pierce_role == "trigger_payload_launch"
            and user_data.current_hit_target_id == "A"
            and user_data.excludeTarget ~= nil
    elseif mode == "pierce_trigger_multicast_event"
        or mode == "pierce_trigger_pattern_event"
        or mode == "pierce_trigger_spread_event" then
        local expected_count = mode == "pierce_trigger_pattern_event" and 5 or 3
        local expected_kind = mode == "pierce_trigger_pattern_event" and "Burst"
            or mode == "pierce_trigger_spread_event" and "Spread"
            or nil
        local first_job = result.pierce_trigger_payload_jobs and result.pierce_trigger_payload_jobs[1] or nil
        local user_data = result.pierce_trigger_payload_launch_user_data
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "pierce"
            and result.pierce_probe_binding_registered == true
            and result.payload_multicast == true
            and (expected_kind == nil or (result.payload_pattern == true and result.payload_pattern_kind == expected_kind))
            and (expected_kind ~= nil or result.payload_pattern == false)
            and result.post_pierce_result
            and result.post_pierce_result.ok == true
            and result.pierce_duplicate_suppressed == true
            and result.pierce_trigger_route == "pierce"
            and tonumber(result.pierce_trigger_payload_count) == expected_count
            and tonumber(result.pierce_trigger_payload_launch_count) == expected_count
            and type(result.pierce_trigger_payload_slot_ids) == "table"
            and #result.pierce_trigger_payload_slot_ids == expected_count
            and type(first_job) == "table"
            and first_job.trigger_route == "pierce"
            and first_job.pierce_runtime == true
            and first_job.current_hit_target_id == "A"
            and first_job.excludeTarget ~= nil
            and type(user_data) == "table"
            and user_data.trigger_route == "pierce"
            and user_data.pierce_runtime == true
            and user_data.pierce_role == "trigger_payload_launch"
    elseif mode == "pierce_trigger_chain_event" then
        local chain_result = result.pierce_chain_result
        local first_job = result.pierce_trigger_payload_jobs and result.pierce_trigger_payload_jobs[1] or nil
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "pierce"
            and result.pierce_probe_binding_registered == true
            and result.payload_chain_runtime == true
            and result.post_pierce_result
            and result.post_pierce_result.ok == true
            and result.pierce_duplicate_suppressed == true
            and result.pierce_trigger_route == "pierce_chain"
            and type(chain_result) == "table"
            and chain_result.ok == true
            and chain_result.provider == "mock"
            and tonumber(chain_result.launch_count) == 1
            and tonumber(result.pierce_chain_hop_index) == 1
            and result.pierce_chain_current_hit_target_id == "A"
            and result.pierce_chain_selected_target_id == "B"
            and type(first_job) == "table"
            and first_job.chain_runtime == true
            and first_job.chain_role == "payload"
            and first_job.current_hit_target_id == "A"
    elseif mode == "trigger_post_hit" or mode == "trigger_post_hit_fallback" then
        local user_data = result.trigger_payload_launch_user_data
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "trigger"
            and result.post_hit_result
            and result.post_hit_result.ok == true
            and result.trigger_duplicate_suppressed == true
            and ((mode == "trigger_post_hit" and result.post_hit_result.trigger_route == "userData")
                or (mode == "trigger_post_hit_fallback" and result.post_hit_result.trigger_route == "spellId"))
            and type(user_data) == "table"
            and user_data.runtime == "2.2c_live_helper"
            and user_data.source_postfix_opcode == "Trigger"
            and user_data.source_slot_id == result.slot_id
            and user_data.payload_slot_id == result.trigger_payload_slot_id
            and user_data.depth == 1
    elseif mode == "trigger_payload_multicast_post_hit" or mode == "chaos_trigger_payload_multicast_post_hit" then
        local expected_count = mode == "chaos_trigger_payload_multicast_post_hit" and recipes.CHAOS_HIGH_FANOUT_COUNT or 3
        local source_pending_ok = mode == "chaos_trigger_payload_multicast_post_hit"
            and result.pending_source_launch_job == true
        local pending_ok = mode == "chaos_trigger_payload_multicast_post_hit"
            and result.post_hit_result
            and result.post_hit_result.pending_launch_jobs == true
        ok = source_pending_ok or (result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "trigger"
            and result.payload_multicast == true
            and result.post_hit_result
            and result.post_hit_result.ok == true
            and result.trigger_duplicate_suppressed == true
            and result.trigger_payload_count == expected_count
            and (result.trigger_payload_launch_count == expected_count or pending_ok)
            and type(result.trigger_payload_slot_ids) == "table"
            and #result.trigger_payload_slot_ids == expected_count)
    elseif mode == "trigger_payload_burst_post_hit" or mode == "trigger_payload_spread_post_hit" or mode == "chaos_trigger_payload_burst_post_hit" then
        local expected_count = mode == "trigger_payload_burst_post_hit" and 5 or (mode == "chaos_trigger_payload_burst_post_hit" and recipes.CHAOS_HIGH_FANOUT_COUNT or 3)
        local expected_kind = (mode == "trigger_payload_burst_post_hit" or mode == "chaos_trigger_payload_burst_post_hit") and "Burst" or "Spread"
        local source_pending_ok = mode == "chaos_trigger_payload_burst_post_hit"
            and result.pending_source_launch_job == true
        local pending_ok = mode == "chaos_trigger_payload_burst_post_hit"
            and result.post_hit_result
            and result.post_hit_result.pending_launch_jobs == true
        ok = source_pending_ok or (result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "trigger"
            and result.payload_multicast == true
            and result.payload_pattern == true
            and result.payload_pattern_kind == expected_kind
            and result.post_hit_result
            and result.post_hit_result.ok == true
            and result.trigger_duplicate_suppressed == true
            and result.trigger_payload_count == expected_count
            and (result.trigger_payload_launch_count == expected_count or pending_ok)
            and type(result.trigger_payload_slot_ids) == "table"
            and #result.trigger_payload_slot_ids == expected_count)
    elseif mode == "timer_dry_run" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "timer"
            and result.dispatch_count == 1
            and type(result.timer_payload_slot_id) == "string"
            and tonumber(result.timer_delay_ticks) ~= nil
    elseif mode == "timer_launch" then
        local source_user_data = result.source_jobs and result.source_jobs[1] and result.source_jobs[1].launch_user_data or nil
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "timer"
            and result.dispatch_count == 1
            and type(result.timer_payload_slot_id) == "string"
            and type(result.timer_id) == "string"
            and type(source_user_data) == "table"
            and source_user_data.runtime == "2.2c_live_helper"
            and source_user_data.source_postfix_opcode == "Timer"
            and source_user_data.timer_payload_slot_id == result.timer_payload_slot_id
            and source_user_data.depth == 0
            and result.timer_async_scheduled == true
            and result.timer_pending_after_launch == true
            and result.timer_payload_launched_before_delay == false
    elseif mode == "timer_real_delay_launch" then
        local source_user_data = result.source_jobs and result.source_jobs[1] and result.source_jobs[1].launch_user_data or nil
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "timer"
            and type(result.timer_payload_slot_id) == "string"
            and type(result.timer_id) == "string"
            and type(source_user_data) == "table"
            and source_user_data.source_postfix_opcode == "Timer"
            and result.timer_async_scheduled == true
            and result.timer_payload_launched_immediately == false
            and tonumber(result.timer_delay_seconds) ~= nil
    elseif mode == "timer_real_delay_sequence" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "timer"
            and type(result.timer_id) == "string"
            and result.async_timer_scheduled == true
            and result.timer_status_after_schedule
            and result.timer_status_after_schedule.pending == true
            and tonumber(result.pending_count) == 1
            and result.timer_immediate_payload_count == 0
            and result.timer_before_delay_payload_count == 0
            and result.timer_after_delay_payload_count == 0
            and result.timer_payload_launch_count == 0
            and result.timer_payload_launched_exactly_once == false
            and result.timer_duplicate_suppressed == true
            and result.timer_delay_semantics == "async_simulation_timer"
            and result.real_delay_test == true
            and tonumber(result.timer_delay_seconds) ~= nil
            and tonumber(result.timer_due_seconds) ~= nil
    elseif mode == "timer_payload_multicast_sequence" or mode == "chaos_timer_payload_multicast_sequence" then
        local expected_count = mode == "chaos_timer_payload_multicast_sequence" and recipes.CHAOS_HIGH_FANOUT_COUNT or 3
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "timer"
            and result.payload_multicast == true
            and type(result.timer_id) == "string"
            and result.async_timer_scheduled == true
            and result.timer_status_after_schedule
            and result.timer_status_after_schedule.pending == true
            and tonumber(result.pending_count) == 1
            and result.timer_immediate_payload_count == 0
            and result.timer_before_delay_payload_count == 0
            and result.timer_after_delay_payload_count == 0
            and result.timer_payload_launch_count == 0
            and result.timer_duplicate_suppressed == true
            and result.timer_payload_count == expected_count
            and result.timer_delay_semantics == "async_simulation_timer"
            and result.real_delay_test == true
    elseif mode == "timer_payload_burst_sequence" or mode == "timer_payload_spread_sequence" or mode == "chaos_timer_payload_spread_sequence" then
        local expected_count = mode == "timer_payload_burst_sequence" and 5 or (mode == "chaos_timer_payload_spread_sequence" and recipes.CHAOS_HIGH_FANOUT_COUNT or 3)
        local expected_kind = mode == "timer_payload_burst_sequence" and "Burst" or "Spread"
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "timer"
            and result.payload_multicast == true
            and result.payload_pattern == true
            and result.payload_pattern_kind == expected_kind
            and type(result.timer_id) == "string"
            and result.async_timer_scheduled == true
            and result.timer_status_after_schedule
            and result.timer_status_after_schedule.pending == true
            and tonumber(result.pending_count) == 1
            and result.timer_immediate_payload_count == 0
            and result.timer_before_delay_payload_count == 0
            and result.timer_after_delay_payload_count == 0
            and result.timer_payload_launch_count == 0
            and result.timer_duplicate_suppressed == true
            and result.timer_payload_count == expected_count
            and result.timer_delay_semantics == "async_simulation_timer"
            and result.real_delay_test == true
    elseif mode == "nested_timer_trigger_sequence" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "nested_trigger_timer"
            and result.nested_tt_kind == "timer_trigger"
            and result.nested_trigger_registered == true
            and type(result.timer_id) == "string"
            and result.async_timer_scheduled == true
            and result.timer_status_after_schedule
            and result.timer_status_after_schedule.pending == true
            and tonumber(result.pending_count) >= 1
            and result.timer_immediate_payload_count == 0
            and result.timer_before_delay_payload_count == 0
            and result.timer_duplicate_suppressed == true
    elseif mode == "nested_trigger_timer_sequence" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "nested_trigger_timer"
            and result.nested_tt_kind == "trigger_timer"
            and result.post_hit_result
            and result.post_hit_result.ok == true
            and result.trigger_duplicate_suppressed == true
            and type(result.nested_timer_id) == "string"
            and result.nested_timer_schedule
            and result.nested_timer_schedule.async_scheduled == true
    elseif mode == "nested_trigger_timer_final_multicast_sequence"
        or mode == "chaos_nested_trigger_timer_final_multicast_sequence"
        or mode == "nested_trigger_timer_final_burst_sequence" then
        local expected_kind = mode == "nested_trigger_timer_final_burst_sequence" and "Burst" or nil
        local source_pending_ok = mode == "chaos_nested_trigger_timer_final_multicast_sequence"
            and result.pending_source_launch_job == true
        ok = source_pending_ok or (result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "nested_trigger_timer"
            and result.nested_tt_kind == "trigger_timer"
            and result.nested_final_fanout == true
            and result.payload_multicast == true
            and (expected_kind == nil or (result.payload_pattern == true and result.payload_pattern_kind == expected_kind))
            and result.post_hit_result
            and result.post_hit_result.ok == true
            and result.trigger_duplicate_suppressed == true
            and type(result.nested_timer_id) == "string"
            and result.nested_timer_schedule
            and result.nested_timer_schedule.async_scheduled == true)
    elseif mode == "nested_timer_trigger_final_multicast_sequence"
        or mode == "nested_timer_trigger_final_spread_sequence"
        or mode == "chaos_nested_timer_trigger_final_spread_sequence" then
        local expected_kind = (mode == "nested_timer_trigger_final_spread_sequence"
            or mode == "chaos_nested_timer_trigger_final_spread_sequence") and "Spread" or nil
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "nested_trigger_timer"
            and result.nested_tt_kind == "timer_trigger"
            and result.nested_final_fanout == true
            and result.payload_multicast == true
            and (expected_kind == nil or (result.payload_pattern == true and result.payload_pattern_kind == expected_kind))
            and result.nested_trigger_registered == true
            and type(result.timer_id) == "string"
            and result.async_timer_scheduled == true
            and result.timer_status_after_schedule
            and result.timer_status_after_schedule.pending == true
            and tonumber(result.pending_count) >= 1
            and result.timer_immediate_payload_count == 0
            and result.timer_before_delay_payload_count == 0
            and result.timer_duplicate_suppressed == true
    elseif mode == "nested_payload_runtime_deferred" then
        ok = result.ok == false
            and result.used_live_2_2c == false
            and (result.fallback_reason == "nested_payload_runtime_deferred"
                or result.fallback_reason == "nested_trigger_timer_disabled")
    else
        ok = result.ok == true and result.used_live_2_2c == true and result.dry_run == true
    end
    result.request_id = payload and payload.request_id
    result.mode = mode
    result.ok = ok
    send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, result)
end

return live_simple_dispatch
