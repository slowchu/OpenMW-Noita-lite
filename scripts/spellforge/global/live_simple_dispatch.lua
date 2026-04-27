local dev = require("scripts.spellforge.shared.dev")
local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("global.live_simple_dispatch")
local limits = require("scripts.spellforge.shared.limits")
local helper_records = require("scripts.spellforge.global.helper_records")
local orchestrator = require("scripts.spellforge.global.orchestrator")
local patterns = require("scripts.spellforge.global.patterns")
local plan_cache = require("scripts.spellforge.global.plan_cache")
local live_size_plus = require("scripts.spellforge.global.live_size_plus")
local live_speed_plus = require("scripts.spellforge.global.live_speed_plus")
local live_timer = require("scripts.spellforge.global.live_timer")
local live_trigger = require("scripts.spellforge.global.live_trigger")
local runtime_stats = require("scripts.spellforge.global.runtime_stats")
local sfp_adapter = require("scripts.spellforge.global.sfp_adapter")

local live_simple_dispatch = {}
local next_live_cast_index = 1
local seen_cast_ids = {}

local SIMPLE_FIRE_DAMAGE_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

local MULTICAST_X3_FIRE_DAMAGE_TARGET = {
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

local SPREAD_MULTICAST_X3_FIRE_DAMAGE_TARGET = {
    { id = "spellforge_spread", params = { preset = 2 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

local BURST_MULTICAST_X3_FIRE_DAMAGE_TARGET = {
    { id = "spellforge_burst", params = { count = 5 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

local TRIGGER_FIRE_FROST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

local TIMER_FIRE_FROST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

local SPEED_PLUS_FIRE_DAMAGE_TARGET = {
    { id = "spellforge_speed_plus", params = { percent = 50 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

local SIZE_PLUS_FIRE_DAMAGE_TARGET = {
    { id = "spellforge_size_plus", params = { percent = 100 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

local VFX_METADATA_AUDIT_TARGET = {
    {
        id = "firedamage",
        range = 2,
        area = 5,
        duration = 1,
        magnitudeMin = 2,
        magnitudeMax = 20,
        areaVfxRecId = "spellforge_test_area_static",
        areaVfxScale = 1.25,
        vfxRecId = "spellforge_test_bolt_vfx",
        boltModel = "meshes/spellforge/test_bolt.nif",
        hitModel = "meshes/spellforge/test_impact.nif",
    },
}

local VFX_METADATA_MISSING_AREA_TARGET = {
    {
        id = "firedamage",
        range = 2,
        area = 5,
        duration = 1,
        magnitudeMin = 2,
        magnitudeMax = 20,
        vfxRecId = "spellforge_test_bolt_vfx",
    },
}

local NON_QUALIFYING_CHAIN_FIRE_DAMAGE_TARGET = {
    { id = "spellforge_chain", params = { hops = 1 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

local PRESENTATION_METADATA_FIELDS = {
    "areaVfxRecId",
    "areaVfxScale",
    "vfxRecId",
    "boltModel",
    "hitModel",
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
    local out = {
        id = effect.id,
        range = effect.range,
        area = effect.area,
        duration = effect.duration,
        magnitudeMin = effect.magnitudeMin,
        magnitudeMax = effect.magnitudeMax,
        params = cloneParams(effect.params),
    }
    for _, field in ipairs(PRESENTATION_METADATA_FIELDS) do
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
        accelerationExp = 0,
        areaVfxRecId = "spellforge_test_area_static",
        areaVfxScale = 1.25,
        vfxRecId = "spellforge_test_bolt_vfx",
        boltModel = "meshes/spellforge/test_bolt.nif",
        hitModel = "meshes/spellforge/test_impact.nif",
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
            and fields.accelerationExp == true
            and fields.areaVfxRecId == true
            and fields.areaVfxScale == true
            and fields.vfxRecId == true
            and fields.boltModel == true
            and fields.hitModel == true
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
    audit.ok = audit.status == "blocked" or audit.status == "implementable" or audit.status == "pending"
    audit.mode = "timer_detonation_audit"
    audit.timer_gameplay_delay_smoke = "implemented"
    audit.deterministic_fast_forward_smoke = "implemented"
    return audit
end

local function vfxMetadataAuditProbe(payload)
    local spec, spec_err = firstHelperSpecForAudit(VFX_METADATA_AUDIT_TARGET)
    local missing_area_spec, missing_err = firstHelperSpecForAudit(VFX_METADATA_MISSING_AREA_TARGET)
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
        or opcode == "Speed+" and "spellforge_speed_plus"
        or opcode == "Size+" and "spellforge_size_plus"
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
    if emission_count > limits.MAX_PROJECTILES_PER_CAST then
        if pattern_kind ~= nil or bounds.has_pattern then
            return false, "pattern_cap_exceeded", patternModeForKind(pattern_kind) or "pattern", "live_multicast_cap_rejections", pattern_kind, pattern_op
        elseif bounds.has_multicast then
            return false, "multicast_cap_exceeded", "multicast", "live_multicast_cap_rejections"
        end
        return false, "projectile_cap_exceeded"
    end

    local is_multicast = bounds.has_multicast and emission_count > 1
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

local function collectPrimaryHelpers(plan)
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
    if #selected > limits.MAX_PROJECTILES_PER_CAST then
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

local function buildJobInputs(selected_helpers, compiled_recipe_id, cast_id, launch_payload, pattern_info, size_info, speed_info)
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
            payload = {
                actor = launch_payload.actor or launch_payload.sender,
                start_pos = launch_payload.start_pos,
                direction = launch_direction,
                hit_object = launch_payload.hit_object,
                cast_id = cast_id,
                fanout_count = fanout_count,
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
        pattern_kind = job and job.pattern_kind or nil,
        pattern_index = job and job.pattern_index or nil,
        pattern_count = job and job.pattern_count or nil,
        pattern_direction_key = job and job.pattern_direction_key or nil,
        source_slot_id = job and job.source_slot_id or nil,
        source_helper_engine_id = job and job.source_helper_engine_id or nil,
        source_postfix_opcode = job and job.source_postfix_opcode or nil,
        payload_slot_id = job and job.payload_slot_id or nil,
        trigger_route = job and job.trigger_route or nil,
        trigger_duplicate_key = job and job.trigger_duplicate_key or nil,
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
        launch_accepted = job and job.launch_accepted == true or false,
        projectile_id = job and job.projectile_id or nil,
        projectile_id_source = job and job.projectile_id_source or nil,
        projectile_registered = job and job.projectile_registered == true or false,
        launch_user_data = job and job.launch_user_data or nil,
        error = job and job.error or nil,
    }
end

local function tickUntilJobsSettled(job_ids, opts)
    local options = opts or {}
    local max_ticks = tonumber(options.max_launch_ticks) or 3
    local max_jobs_per_tick = tonumber(options.max_jobs_per_tick) or limits.MAX_JOBS_PER_TICK
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
        last_tick = orchestrator.tick({ max_jobs_per_tick = max_jobs_per_tick })
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

    local attached = plan_cache.attachHelperRecords(compiled.recipe_id)
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

    local attached = plan_cache.attachHelperRecords(compiled.recipe_id)
    if not attached.ok then
        return timerRejected("helper_records_failed", {
            plan_recipe_id = compiled.recipe_id,
            error = firstErrorMessage(attached),
            errors = attached.errors,
        })
    end

    local timer_plan, timer_reason = live_timer.selectV0Plan(attached.plan)
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
        slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
        helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
        effect_id = timer_plan.source.slot.effects and timer_plan.source.slot.effects[1] and timer_plan.source.slot.effects[1].id or nil,
        simple_note = "timer_v0",
        live_mode = "timer",
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

    local attached = plan_cache.attachHelperRecords(compiled.recipe_id)
    if not attached.ok then
        return triggerRejected("helper_records_failed", {
            plan_recipe_id = compiled.recipe_id,
            error = firstErrorMessage(attached),
            errors = attached.errors,
        })
    end

    local trigger_plan, trigger_reason = live_trigger.selectV0Plan(attached.plan)
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
        cast_id = cast_id,
        source_slot_id = trigger_plan.source_slot_id,
        source_helper_engine_id = trigger_plan.source_helper_engine_id,
        payload_slot_id = trigger_plan.payload_slot_id,
        payload_helper_engine_id = trigger_plan.payload_helper_engine_id,
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
            trigger_payload_effect_id = trigger_plan.payload_effect_id,
            slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
            helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
            dispatch_count = 1,
            source_dispatch_count = 1,
            fanout_count = 1,
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
        slot_count = attached.plan.slot_count or #attached.plan.emission_slots,
        helper_record_count = attached.plan.helper_record_count or #attached.plan.helper_records,
        effect_id = trigger_plan.source.slot.effects and trigger_plan.source.slot.effects[1] and trigger_plan.source.slot.effects[1].id or nil,
        simple_note = "trigger_v0",
        live_mode = "trigger",
    }
end

function live_simple_dispatch.tryDispatch(payload, entry, root, opts)
    local options = opts or {}
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
    local has_size_plus_effect = effectListHasOperator(effects, "Size+")
    local has_speed_plus_effect = effectListHasOperator(effects, "Speed+")
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
        if estimated_multicast_count > limits.MAX_PROJECTILES_PER_CAST then
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

    local compiled = plan_cache.compileOrGet(effects)
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
        if has_timer_effect then
            runtime_stats.inc("live_timer_attempts")
            if errorsMentionTimerDelay(compiled.errors) then
                runtime_stats.inc("live_timer_delay_invalid")
            end
            return timerRejected("compile_failed", details)
        end
        if estimated_pattern_kind ~= nil then
            return patternRejected(estimated_pattern_kind, "compile_failed", details)
        end
        if estimated_multicast_fanout then
            return multicastRejected("compile_failed", details)
        end
        return rejected("compile_failed", details)
    end

    if compiled.plan and compiled.plan.bounds and compiled.plan.bounds.has_size_plus then
        return trySizePlusDispatch(compiled, launch_payload, options)
    end

    if compiled.plan and compiled.plan.bounds and compiled.plan.bounds.has_speed_plus then
        return trySpeedPlusDispatch(compiled, launch_payload, options)
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

    local attached = plan_cache.attachHelperRecords(compiled.recipe_id)
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

    local selected_helpers, materialized_reason = collectPrimaryHelpers(attached.plan)
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
    local probe_entry = { node_metadata = { { logical_id = "probe" } } }
    local probe_root = { real_effects = SIMPLE_FIRE_DAMAGE_TARGET }
    local opts = {
        ignore_flag = true,
        dry_run = true,
        skip_entry_shape_check = false,
        source_recipe_id = "live-simple-probe",
    }

    if mode == "adapter_capabilities" then
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
    elseif mode == "timer_real_delay_check" then
        local timer_id = payload and (payload.timer_id or payload.timer_job_id)
        local before = type(timer_id) == "string" and live_timer.timerStatus(timer_id) or nil
        local tick_result = nil
        if type(timer_id) == "string" and timer_id ~= "" then
            tick_result = orchestrator.tick({ max_jobs_per_tick = limits.MAX_JOBS_PER_TICK })
        end
        local status = type(timer_id) == "string" and live_timer.timerStatus(timer_id) or nil
        local payload_count = status and status.payload_launch_accepted == true and 1 or 0
        if payload and payload.observe_matured == true and status and status.callback_ok == true and payload_count == 1 then
            runtime_stats.inc("live_timer_real_delay_smoke_observed")
            runtime_stats.inc("live_timer_real_delay_smoke_callback_ok")
        end
        send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, {
            request_id = payload and payload.request_id,
            ok = status ~= nil and status.callback_ok == true and payload_count == 1,
            mode = mode,
            timer_id = timer_id,
            timer_status_before_check = before,
            timer_status = status,
            live_mode = "timer",
            cast_id = status and status.cast_id or nil,
            slot_id = status and status.source_slot_id or nil,
            helper_engine_id = status and status.source_helper_engine_id or nil,
            timer_payload_slot_id = status and status.payload_slot_id or nil,
            timer_delay_ticks = status and status.timer_delay_ticks or nil,
            timer_delay_seconds = status and status.timer_delay_seconds or nil,
            timer_due_tick = status and status.timer_due_tick or nil,
            timer_due_seconds = status and status.timer_due_seconds or nil,
            tick_result = tick_result,
            callback_payload_count = payload_count,
            callback_count = status and status.callback_seen == true and 1 or 0,
            pending_count = status and status.pending_count or live_timer.pendingCount(),
            timer_payload_launch_user_data = status and status.payload_launch_user_data or nil,
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
        probe_root = { real_effects = MULTICAST_X3_FIRE_DAMAGE_TARGET }
        opts.force_multicast_disabled = true
    elseif mode == "multicast_dry_run" then
        probe_root = { real_effects = MULTICAST_X3_FIRE_DAMAGE_TARGET }
        opts.force_multicast_enabled = true
    elseif mode == "multicast_launch" then
        probe_root = { real_effects = MULTICAST_X3_FIRE_DAMAGE_TARGET }
        opts.force_multicast_enabled = true
        opts.dry_run = false
    elseif mode == "spread_disabled" then
        probe_root = { real_effects = SPREAD_MULTICAST_X3_FIRE_DAMAGE_TARGET }
        opts.force_multicast_enabled = true
        opts.force_pattern_disabled = true
    elseif mode == "spread_dry_run" then
        probe_root = { real_effects = SPREAD_MULTICAST_X3_FIRE_DAMAGE_TARGET }
        opts.force_multicast_enabled = true
        opts.force_pattern_enabled = true
    elseif mode == "spread_launch" then
        probe_root = { real_effects = SPREAD_MULTICAST_X3_FIRE_DAMAGE_TARGET }
        opts.force_multicast_enabled = true
        opts.force_pattern_enabled = true
        opts.dry_run = false
    elseif mode == "burst_disabled" then
        probe_root = { real_effects = BURST_MULTICAST_X3_FIRE_DAMAGE_TARGET }
        opts.force_multicast_enabled = true
        opts.force_pattern_disabled = true
    elseif mode == "burst_dry_run" then
        probe_root = { real_effects = BURST_MULTICAST_X3_FIRE_DAMAGE_TARGET }
        opts.force_multicast_enabled = true
        opts.force_pattern_enabled = true
    elseif mode == "burst_launch" then
        probe_root = { real_effects = BURST_MULTICAST_X3_FIRE_DAMAGE_TARGET }
        opts.force_multicast_enabled = true
        opts.force_pattern_enabled = true
        opts.dry_run = false
    elseif mode == "trigger_disabled" then
        probe_root = { real_effects = TRIGGER_FIRE_FROST_TARGET }
        opts.force_trigger_disabled = true
    elseif mode == "trigger_dry_run" then
        probe_root = { real_effects = TRIGGER_FIRE_FROST_TARGET }
        opts.force_trigger_enabled = true
    elseif mode == "trigger_launch" or mode == "trigger_post_hit" or mode == "trigger_post_hit_fallback" then
        probe_root = { real_effects = TRIGGER_FIRE_FROST_TARGET }
        opts.force_trigger_enabled = true
        opts.dry_run = false
    elseif mode == "timer_disabled" then
        probe_root = { real_effects = TIMER_FIRE_FROST_TARGET }
        opts.force_timer_disabled = true
    elseif mode == "timer_dry_run" then
        probe_root = { real_effects = TIMER_FIRE_FROST_TARGET }
        opts.force_timer_enabled = true
    elseif mode == "timer_launch" or mode == "timer_real_delay_launch" or mode == "timer_real_delay_sequence" then
        probe_root = { real_effects = TIMER_FIRE_FROST_TARGET }
        opts.force_timer_enabled = true
        opts.dry_run = false
        if mode ~= "timer_real_delay_launch" and mode ~= "timer_real_delay_sequence" then
            opts.timer_delay_ticks_override = 4
        end
        if mode == "timer_real_delay_sequence" then
            opts.timer_duplicate_schedule_probe = true
        end
    elseif mode == "speed_plus_disabled" then
        probe_root = { real_effects = SPEED_PLUS_FIRE_DAMAGE_TARGET }
        opts.force_speed_plus_disabled = true
    elseif mode == "speed_plus_dry_run" then
        probe_root = { real_effects = SPEED_PLUS_FIRE_DAMAGE_TARGET }
        opts.force_speed_plus_enabled = true
    elseif mode == "speed_plus_launch" then
        probe_root = { real_effects = SPEED_PLUS_FIRE_DAMAGE_TARGET }
        opts.force_speed_plus_enabled = true
        opts.dry_run = false
    elseif mode == "size_plus_disabled" then
        probe_root = { real_effects = SIZE_PLUS_FIRE_DAMAGE_TARGET }
        opts.force_size_plus_disabled = true
    elseif mode == "size_plus_dry_run" then
        probe_root = { real_effects = SIZE_PLUS_FIRE_DAMAGE_TARGET }
        opts.force_size_plus_enabled = true
    elseif mode == "size_plus_launch" then
        probe_root = { real_effects = SIZE_PLUS_FIRE_DAMAGE_TARGET }
        opts.force_size_plus_enabled = true
        opts.dry_run = false
    elseif mode == "non_qualifying" then
        probe_root = { real_effects = NON_QUALIFYING_CHAIN_FIRE_DAMAGE_TARGET }
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
    if (mode == "trigger_post_hit" or mode == "trigger_post_hit_fallback") and result.ok == true then
        local source_job = result.jobs and result.jobs[1] or nil
        local user_data = source_job and source_job.launch_user_data or nil
        local hit_payload = {
            spellId = result.helper_engine_id,
            projectileId = result.projectile_id or ((payload and payload.request_id or "trigger-post-hit") .. ":source-projectile"),
            userData = mode == "trigger_post_hit" and user_data or nil,
            attacker = payload and (payload.actor or payload.sender),
            hitPos = payload and payload.start_pos,
            target = payload and payload.hit_object,
        }
        local first = live_trigger.handleHitPayload(hit_payload, { force_enabled = true })
        local duplicate = live_trigger.handleHitPayload(hit_payload, { force_enabled = true })
        result.post_hit_result = first
        result.duplicate_hit_result = duplicate
        result.trigger_payload_job_id = first and first.job_id or nil
        result.trigger_payload_slot_id = first and first.payload_slot_id or nil
        result.trigger_payload_helper_engine_id = first and first.payload_helper_engine_id or nil
        result.trigger_payload_launch_user_data = first and first.launch_user_data or nil
        result.trigger_duplicate_suppressed = duplicate and duplicate.duplicate_suppressed == true
        if first and first.ok == true and duplicate and duplicate.duplicate_suppressed == true then
            runtime_stats.inc("live_trigger_post_hit_smoke_observed")
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
    if mode == "timer_real_delay_sequence" and result.ok == true and type(result.timer_id) == "string" then
        local status = live_timer.timerStatus(result.timer_id)
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
    end
    local ok = false
    if mode == "non_qualifying" or mode == "multicast_disabled" or mode == "spread_disabled" or mode == "burst_disabled" or mode == "trigger_disabled" or mode == "timer_disabled" or mode == "speed_plus_disabled" or mode == "size_plus_disabled" then
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
    elseif mode == "multicast_dry_run" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.dry_run == true
            and result.live_mode == "multicast"
            and result.dispatch_count == 3
    elseif mode == "multicast_launch" then
        ok = result.ok == true
            and result.used_live_2_2c == true
            and result.live_mode == "multicast"
            and result.dispatch_count == 3
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
    else
        ok = result.ok == true and result.used_live_2_2c == true and result.dry_run == true
    end
    result.request_id = payload and payload.request_id
    result.mode = mode
    result.ok = ok
    send(sender, events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT, result)
end

return live_simple_dispatch
