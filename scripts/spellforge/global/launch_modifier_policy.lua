local limits = require("scripts.spellforge.shared.limits")
local log = require("scripts.spellforge.shared.log").new("global.launch_modifier_policy")
local plan_cache = require("scripts.spellforge.global.plan_cache")
local runtime_stats = require("scripts.spellforge.global.runtime_stats")
local live_size_plus = require("scripts.spellforge.global.live_size_plus")
local live_speed_plus = require("scripts.spellforge.global.live_speed_plus")

local launch_modifier_policy = {}

launch_modifier_policy.VERSION = "spellforge-launch-modifier-policy-v0"

local function hasPayloadBindings(entry)
    return type(entry and entry.payload_bindings) == "table" and #entry.payload_bindings > 0
end

local function hasPostfix(entry)
    return type(entry and entry.postfix_ops) == "table" and #entry.postfix_ops > 0
end

local function cloneWarnings(warnings)
    local out = {}
    for index, warning in ipairs(warnings or {}) do
        out[index] = warning
    end
    return out
end

local function emitDeferred(entry, reason, opts)
    if opts and opts.quiet == true then
        return
    end
    if opts and opts.policy_kind == "source" then
        runtime_stats.inc("source_modifier_policy_deferred")
        log.info(string.format(
            "SPELLFORGE_SOURCE_MODIFIER_POLICY_DEFERRED recipe_id=%s slot_id=%s reason=%s",
            tostring(entry and entry.recipe_id),
            tostring(entry and entry.slot_id),
            tostring(reason)
        ))
    else
        runtime_stats.inc("payload_modifier_policy_deferred")
        log.info(string.format(
            "SPELLFORGE_PAYLOAD_MODIFIER_POLICY_DEFERRED recipe_id=%s slot_id=%s reason=%s",
            tostring(entry and entry.recipe_id),
            tostring(entry and entry.slot_id),
            tostring(reason)
        ))
    end
end

local function emitOk(entry, kind, opts)
    if opts and opts.quiet == true then
        return
    end
    if opts and opts.policy_kind == "source" then
        runtime_stats.inc("source_modifier_policy_ok")
        log.info(string.format(
            "SPELLFORGE_SOURCE_MODIFIER_POLICY_OK recipe_id=%s slot_id=%s source_modifier_kind=%s",
            tostring(entry and entry.recipe_id),
            tostring(entry and entry.slot_id),
            tostring(kind)
        ))
    else
        runtime_stats.inc("payload_modifier_policy_ok")
        log.info(string.format(
            "SPELLFORGE_PAYLOAD_MODIFIER_POLICY_OK recipe_id=%s slot_id=%s payload_modifier_kind=%s",
            tostring(entry and entry.recipe_id),
            tostring(entry and entry.slot_id),
            tostring(kind)
        ))
    end
end

local function modifierKind(features)
    if features and features.speed_plus == true and features.size_plus == true then
        return "speed_plus_size_plus"
    elseif features and features.speed_plus == true then
        return "speed_plus"
    elseif features and features.size_plus == true then
        return "size_plus"
    end
    return nil
end

local function compatibilityReason(reason, opts)
    if opts and opts.compatibility == "chain" then
        if reason == "payload_speed_plus_disabled" then
            return "chain_speed_plus_disabled"
        elseif reason == "payload_size_plus_disabled" then
            return "chain_size_plus_disabled"
        elseif reason == "payload_speed_plus_field_missing" then
            return "chain_speed_plus_field_missing"
        elseif reason == "payload_size_plus_apply_failed" then
            return "chain_size_plus_apply_failed"
        elseif reason == "payload_modifier_combo_deferred" then
            return "chain_modifier_combo_deferred"
        elseif reason == "payload_modifier_cap_exceeded" then
            return "chain_multicast_fanout_cap_exceeded"
        elseif reason == "payload_modifier_unsupported_prefix" then
            return "chain_payload_modifier_deferred"
        end
    end
    return reason
end

local function reject(entry, reason, features, mutations, warnings, opts)
    local mapped = compatibilityReason(reason, opts)
    emitDeferred(entry, mapped, opts)
    return {
        ok = false,
        version = launch_modifier_policy.VERSION,
        rejection_reason = mapped,
        modifier_features = features or {},
        mutations = mutations or {},
        warnings = cloneWarnings(warnings),
    }
end

local function success(entry, features, mutations, warnings, opts)
    local kind = mutations and (mutations.payload_modifier_kind or mutations.source_modifier_kind) or nil
    if kind ~= nil then
        emitOk(entry, kind, opts)
    end
    return {
        ok = true,
        version = launch_modifier_policy.VERSION,
        rejection_reason = nil,
        modifier_features = features or {},
        mutations = mutations or {},
        warnings = cloneWarnings(warnings),
    }
end

local function multicastFanout(op)
    local count = tonumber(op and op.params and op.params.count) or 1
    if count ~= count or count == math.huge or count == -math.huge then
        return 1
    end
    return math.max(1, math.floor(count))
end

local function inspectPrefixOps(entry)
    local features = {
        speed_plus = false,
        size_plus = false,
        multicast = false,
        pattern = false,
        pattern_kind = nil,
        chain = false,
        pierce = false,
        bounce = false,
        homing = false,
    }
    local details = {
        speed_count = 0,
        speed_op = nil,
        size_count = 0,
        size_op = nil,
        multicast_count = 0,
        multicast_op = nil,
        pattern_count = 0,
        pattern_op = nil,
        chain_count = 0,
        chain_op = nil,
        pierce_count = 0,
        pierce_op = nil,
        bounce_count = 0,
        bounce_op = nil,
        homing_count = 0,
        homing_op = nil,
        unsupported_count = 0,
        unsupported_opcode = nil,
    }

    for _, op in ipairs(entry and entry.prefix_ops or {}) do
        local opcode = op and op.opcode
        if opcode == "Speed+" then
            features.speed_plus = true
            details.speed_count = details.speed_count + 1
            details.speed_op = details.speed_op or op
        elseif opcode == "Size+" then
            features.size_plus = true
            details.size_count = details.size_count + 1
            details.size_op = details.size_op or op
        elseif opcode == "Multicast" then
            features.multicast = true
            details.multicast_count = details.multicast_count + 1
            details.multicast_op = details.multicast_op or op
        elseif opcode == "Spread" or opcode == "Burst" then
            features.pattern = true
            details.pattern_count = details.pattern_count + 1
            if features.pattern_kind ~= nil and features.pattern_kind ~= opcode then
                details.pattern_ambiguous = true
            end
            features.pattern_kind = features.pattern_kind or opcode
            details.pattern_op = details.pattern_op or op
        elseif opcode == "Chain" then
            features.chain = true
            details.chain_count = details.chain_count + 1
            details.chain_op = details.chain_op or op
        elseif opcode == "Pierce" then
            features.pierce = true
            details.pierce_count = details.pierce_count + 1
            details.pierce_op = details.pierce_op or op
        elseif opcode == "Bounce" then
            features.bounce = true
            details.bounce_count = details.bounce_count + 1
            details.bounce_op = details.bounce_op or op
        elseif opcode == "Homing" then
            features.homing = true
            details.homing_count = details.homing_count + 1
            details.homing_op = details.homing_op or op
        else
            details.unsupported_count = details.unsupported_count + 1
            details.unsupported_opcode = details.unsupported_opcode or opcode
        end
    end

    return features, details
end

local function modifierEnabled(kind, opts)
    local options = opts or {}
    if kind == "speed_plus" then
        if options.force_speed_plus_disabled == true then
            return false
        end
        return options.force_speed_plus_enabled == true
            or options.speed_plus_enabled == true
            or options.allow_speed_plus == true
    elseif kind == "size_plus" then
        if options.force_size_plus_disabled == true then
            return false
        end
        return options.force_size_plus_enabled == true
            or options.size_plus_enabled == true
            or options.allow_size_plus == true
    end
    return true
end

function launch_modifier_policy.gateHintsForModifierKinds(modifier_kinds, opts)
    local options = opts or {}
    local has_speed = false
    local has_size = false
    for _, kind in ipairs(modifier_kinds or {}) do
        if kind == "speed_plus" or kind == "speed_plus_size_plus" then
            has_speed = true
        end
        if kind == "size_plus" or kind == "speed_plus_size_plus" then
            has_size = true
        end
    end
    local force_speed_disabled = options.force_speed_plus_disabled == true
    local force_size_disabled = options.force_size_plus_disabled == true
    return {
        force_speed_plus_enabled = not force_speed_disabled
            and (options.force_speed_plus_enabled == true or has_speed),
        force_speed_plus_disabled = force_speed_disabled,
        speed_plus_enabled = not force_speed_disabled
            and (options.speed_plus_enabled == true or has_speed),
        force_size_plus_enabled = not force_size_disabled
            and (options.force_size_plus_enabled == true or has_size),
        force_size_plus_disabled = force_size_disabled,
        size_plus_enabled = not force_size_disabled
            and (options.size_plus_enabled == true or has_size),
    }
end

local function chainMulticastEnabled(opts)
    local options = opts or {}
    if options.force_chain_multicast_disabled == true then
        return false
    end
    return options.force_chain_multicast_enabled == true
        or options.allow_chain_multicast == true
        or options.chain_multicast_enabled == true
end

local function attachSizeAreaFromSpecs(plan, entry, mutation)
    if type(plan) ~= "table" or type(plan.helper_specs) ~= "table" or type(mutation) ~= "table" then
        return
    end
    for _, spec in ipairs(plan.helper_specs) do
        if spec and spec.slot_id == entry.slot_id then
            local effect = spec.effects and spec.effects[1] or nil
            if effect then
                mutation.size_plus_base_area = tonumber(effect._spellforge_size_plus_base_area or mutation.size_plus_base_area)
                mutation.size_plus_area = tonumber(effect.area or mutation.size_plus_area)
                return
            end
        end
    end
end

function launch_modifier_policy.copyMutationFields(target, mutation, kind, opts)
    if type(target) ~= "table" or type(mutation) ~= "table" then
        return
    end
    local options = opts or {}
    if options.kind_field then
        target[options.kind_field] = kind
    else
        target.payload_modifier_kind = kind
    end
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

function launch_modifier_policy.copyMutationSetFields(target, mutations, opts)
    if type(target) ~= "table" or type(mutations) ~= "table" then
        return {
            speed_plus = false,
            size_plus = false,
        }
    end
    local options = opts or {}
    local kind_field = options.kind_field or "payload_modifier_kind"
    local kind = mutations[kind_field] or mutations.payload_modifier_kind or mutations.source_modifier_kind
    local applied = {
        speed_plus = false,
        size_plus = false,
    }
    if type(mutations.speed_plus) == "table" then
        launch_modifier_policy.copyMutationFields(target, mutations.speed_plus, "speed_plus", options)
        applied.speed_plus = true
    end
    if type(mutations.size_plus) == "table" then
        launch_modifier_policy.copyMutationFields(target, mutations.size_plus, "size_plus", options)
        applied.size_plus = true
    end
    target[kind_field] = kind
    return applied
end

function launch_modifier_policy.inspectPayloadEntry(plan, ir, payload_entry, opts)
    local options = opts or {}
    if type(payload_entry) ~= "table" then
        return reject(payload_entry, "payload_modifier_unsupported_prefix", nil, nil, nil, options)
    end

    local features, details = inspectPrefixOps(payload_entry)
    local mutations = {
        payload_modifier_kind = nil,
        speed_plus = nil,
        size_plus = nil,
        chain_multicast_fanout_count = nil,
    }
    local warnings = {}

    if details.unsupported_count > 0 then
        return reject(payload_entry, "payload_modifier_unsupported_prefix", features, mutations, warnings, options)
    end
    if options.require_chain_prefix == true and details.chain_count ~= 1 then
        return reject(payload_entry, "payload_modifier_unsupported_prefix", features, mutations, warnings, options)
    end
    if details.speed_count > 1 or details.size_count > 1 then
        return reject(payload_entry, "payload_modifier_combo_deferred", features, mutations, warnings, options)
    end
    if details.pattern_ambiguous == true then
        return reject(payload_entry, "payload_modifier_pattern_deferred", features, mutations, warnings, options)
    end

    local has_modifier = features.speed_plus == true or features.size_plus == true
    if has_modifier then
        if features.pattern then
            return reject(payload_entry, "payload_modifier_pattern_deferred", features, mutations, warnings, options)
        end
        if features.homing then
            return reject(payload_entry, "payload_modifier_homing_deferred", features, mutations, warnings, options)
        end
        if (features.pierce or features.bounce) and options.allow_payload_source_modifiers ~= true then
            return reject(payload_entry, "payload_modifier_unsupported_prefix", features, mutations, warnings, options)
        end
        if (hasPostfix(payload_entry) or hasPayloadBindings(payload_entry)) and options.allow_nested_payload_modifiers ~= true then
            return reject(payload_entry, "payload_modifier_nested_deferred", features, mutations, warnings, options)
        end
    end

    if features.chain then
        if details.chain_count ~= 1 then
            return reject(payload_entry, "payload_modifier_unsupported_prefix", features, mutations, warnings, options)
        end
        if details.multicast_count > 1 then
            return reject(payload_entry, "payload_modifier_cap_exceeded", features, mutations, warnings, options)
        end
        if details.multicast_count == 1 and features.speed_plus and features.size_plus then
            return reject(payload_entry, "payload_modifier_combo_deferred", features, mutations, warnings, options)
        end
    elseif details.multicast_count > 1 then
        return reject(payload_entry, "payload_modifier_cap_exceeded", features, mutations, warnings, options)
    elseif details.multicast_count == 1 and features.speed_plus and features.size_plus then
        return reject(payload_entry, "payload_modifier_combo_deferred", features, mutations, warnings, options)
    end

    if features.multicast then
        local fanout_count = multicastFanout(details.multicast_op)
        mutations.chain_multicast_fanout_count = fanout_count
        if features.chain and not chainMulticastEnabled(options) then
            return reject(payload_entry, "chain_multicast_disabled", features, mutations, warnings, options)
        end
        local cap = tonumber(options.max_chain_multicast_fanout or options.max_payload_modifier_fanout or options.max_fanout)
            or limits.MAX_NESTED_PAYLOAD_FANOUT
        if fanout_count > cap then
            return reject(payload_entry, "payload_modifier_cap_exceeded", features, mutations, warnings, options)
        end
    end

    local mutation = nil
    local mutation_err = nil
    if features.speed_plus then
        if not modifierEnabled("speed_plus", options) then
            return reject(payload_entry, "payload_speed_plus_disabled", features, mutations, warnings, options)
        end
        if live_speed_plus.launchSpeedField() == nil then
            return reject(payload_entry, "payload_speed_plus_field_missing", features, mutations, warnings, options)
        end
        mutation, mutation_err = live_speed_plus.computeMutation(details.speed_op)
        if not mutation then
            return reject(payload_entry, mutation_err or "payload_modifier_unsupported_prefix", features, mutations, warnings, options)
        end
        mutations.speed_plus = mutation
    end
    if features.size_plus then
        if not modifierEnabled("size_plus", options) then
            return reject(payload_entry, "payload_size_plus_disabled", features, mutations, warnings, options)
        end
        mutation, mutation_err = live_size_plus.computeMutation(details.size_op)
        if not mutation then
            return reject(payload_entry, mutation_err or "payload_modifier_unsupported_prefix", features, mutations, warnings, options)
        end
        if options.apply_size_to_specs == true then
            local apply_result = nil
            apply_result, mutation_err = live_size_plus.applyToPayloadSlotHelperSpecs(plan, payload_entry.slot_id, mutation)
            if not apply_result then
                return reject(payload_entry, "payload_size_plus_apply_failed", features, mutations, warnings, options)
            end
            mutations.size_plus_apply_result = apply_result
        else
            attachSizeAreaFromSpecs(plan, payload_entry, mutation)
        end
        mutations.size_plus = mutation
    end
    mutations.payload_modifier_kind = modifierKind(features)

    return success(payload_entry, features, mutations, warnings, options)
end

function launch_modifier_policy.inspectSourceEntry(plan, ir, source_entry, opts)
    local options = {}
    for key, value in pairs(opts or {}) do
        options[key] = value
    end
    options.policy_kind = "source"
    if type(source_entry) ~= "table" then
        return reject(source_entry, "source_modifier_unsupported_prefix", nil, nil, nil, options)
    end

    local features, details = inspectPrefixOps(source_entry)
    local mutations = {
        source_modifier_kind = nil,
        speed_plus = nil,
        size_plus = nil,
        size_plus_apply_result = nil,
    }
    local warnings = {}
    local has_modifier = features.speed_plus == true or features.size_plus == true

    if details.unsupported_count > 0 then
        return reject(source_entry, "source_modifier_unsupported_prefix", features, mutations, warnings, options)
    end
    if details.speed_count > 1 or details.size_count > 1 then
        return reject(source_entry, "source_modifier_combo_deferred", features, mutations, warnings, options)
    end
    if features.speed_plus and features.size_plus then
        return reject(source_entry, "source_modifier_combo_deferred", features, mutations, warnings, options)
    end
    if details.pattern_ambiguous == true or features.pattern or features.multicast then
        if has_modifier or features.bounce or features.pierce then
            return reject(source_entry, "source_modifier_pattern_deferred", features, mutations, warnings, options)
        end
    end
    if features.homing then
        if has_modifier or features.bounce or features.pierce then
            return reject(source_entry, "source_modifier_homing_deferred", features, mutations, warnings, options)
        end
    end
    if features.chain then
        if features.bounce or features.pierce or has_modifier then
            return reject(source_entry, "source_modifier_chain_deferred", features, mutations, warnings, options)
        end
    end
    if has_modifier and (hasPostfix(source_entry) or hasPayloadBindings(source_entry)) then
        return reject(source_entry, "source_modifier_nested_deferred", features, mutations, warnings, options)
    end
    if features.bounce and features.pierce then
        return reject(source_entry, "source_modifier_unsupported_prefix", features, mutations, warnings, options)
    end
    if details.bounce_count > 1 or details.pierce_count > 1 or details.homing_count > 1 or details.chain_count > 1 then
        return reject(source_entry, "source_modifier_cap_exceeded", features, mutations, warnings, options)
    end
    if features.bounce and options.allow_bounce_source ~= true then
        return reject(source_entry, "source_modifier_unsupported_prefix", features, mutations, warnings, options)
    end
    if features.pierce and options.allow_pierce_source ~= true then
        return reject(source_entry, "source_modifier_unsupported_prefix", features, mutations, warnings, options)
    end

    local mutation = nil
    local mutation_err = nil
    if features.speed_plus then
        if not modifierEnabled("speed_plus", options) then
            return reject(source_entry, "source_speed_plus_disabled", features, mutations, warnings, options)
        end
        if live_speed_plus.launchSpeedField() == nil then
            return reject(source_entry, "source_speed_plus_field_missing", features, mutations, warnings, options)
        end
        mutation, mutation_err = live_speed_plus.computeMutation(details.speed_op)
        if not mutation then
            return reject(source_entry, mutation_err or "source_modifier_unsupported_prefix", features, mutations, warnings, options)
        end
        mutations.speed_plus = mutation
    end
    if features.size_plus then
        if not modifierEnabled("size_plus", options) then
            return reject(source_entry, "source_size_plus_disabled", features, mutations, warnings, options)
        end
        mutation, mutation_err = live_size_plus.computeMutation(details.size_op)
        if not mutation then
            return reject(source_entry, mutation_err or "source_modifier_unsupported_prefix", features, mutations, warnings, options)
        end
        if options.apply_size_to_specs == true then
            local apply_result = nil
            apply_result, mutation_err = live_size_plus.applyToPayloadSlotHelperSpecs(plan, source_entry.slot_id, mutation)
            if not apply_result then
                return reject(source_entry, "source_size_plus_apply_failed", features, mutations, warnings, options)
            end
            mutations.size_plus_apply_result = apply_result
        else
            attachSizeAreaFromSpecs(plan, source_entry, mutation)
        end
        mutations.size_plus = mutation
    end
    mutations.source_modifier_kind = modifierKind(features)

    return success(source_entry, features, mutations, warnings, options)
end

function launch_modifier_policy.applyToJob(plan, ir, payload_entry, job, event_context, opts)
    local inspected = launch_modifier_policy.inspectPayloadEntry(plan, ir, payload_entry, opts)
    if inspected.ok ~= true then
        return inspected
    end
    local mutations = inspected.mutations or {}
    local applied = launch_modifier_policy.copyMutationSetFields(job, mutations)
    if type(job.payload) == "table" then
        launch_modifier_policy.copyMutationSetFields(job.payload, mutations)
    end
    if applied.speed_plus == true then
        runtime_stats.inc("payload_speed_plus_policy_applied")
        log.info(string.format(
            "SPELLFORGE_PAYLOAD_SPEED_PLUS_POLICY_APPLIED recipe_id=%s event_kind=%s slot_id=%s payload_slot_id=%s speed_value=%s",
            tostring(job and job.recipe_id),
            tostring(event_context and event_context.event_kind),
            tostring(job and job.slot_id),
            tostring(job and job.payload_slot_id),
            tostring(mutations.speed_plus and mutations.speed_plus.speed_plus_speed)
        ))
    end
    if applied.size_plus == true then
        runtime_stats.inc("payload_size_plus_policy_applied")
        log.info(string.format(
            "SPELLFORGE_PAYLOAD_SIZE_PLUS_POLICY_APPLIED recipe_id=%s event_kind=%s slot_id=%s payload_slot_id=%s size_area=%s",
            tostring(job and job.recipe_id),
            tostring(event_context and event_context.event_kind),
            tostring(job and job.slot_id),
            tostring(job and job.payload_slot_id),
            tostring(mutations.size_plus and mutations.size_plus.size_plus_area)
        ))
    end
    if applied.speed_plus == true and applied.size_plus == true then
        runtime_stats.inc("payload_speed_size_plus_policy_applied")
        log.info(string.format(
            "SPELLFORGE_PAYLOAD_SPEED_SIZE_PLUS_POLICY_APPLIED recipe_id=%s event_kind=%s slot_id=%s payload_slot_id=%s speed_value=%s size_area=%s",
            tostring(job and job.recipe_id),
            tostring(event_context and event_context.event_kind),
            tostring(job and job.slot_id),
            tostring(job and job.payload_slot_id),
            tostring(mutations.speed_plus and mutations.speed_plus.speed_plus_speed),
            tostring(mutations.size_plus and mutations.size_plus.size_plus_area)
        ))
    end
    return inspected
end

function launch_modifier_policy.applySourcePolicyToLaunchSpec(plan, ir, source_entry, launch_spec, event_context, opts)
    local options = opts or {}
    local inspected = options.inspection
    if type(inspected) ~= "table" then
        inspected = launch_modifier_policy.inspectSourceEntry(plan, ir, source_entry, options)
    end
    if inspected.ok ~= true then
        if type(launch_spec) == "table" then
            launch_spec.source_modifier_rejection_reason = inspected.rejection_reason
            if type(launch_spec.payload) == "table" then
                launch_spec.payload.source_modifier_rejection_reason = inspected.rejection_reason
            end
        end
        return inspected
    end

    local mutations = inspected.mutations or {}
    local applied = launch_modifier_policy.copyMutationSetFields(launch_spec, mutations, {
        kind_field = "source_modifier_kind",
    })
    if type(launch_spec.payload) == "table" then
        launch_modifier_policy.copyMutationSetFields(launch_spec.payload, mutations, {
            kind_field = "source_modifier_kind",
        })
    end
    if applied.speed_plus == true then
        runtime_stats.inc("source_speed_plus_policy_applied")
        log.info(string.format(
            "SPELLFORGE_SOURCE_SPEED_PLUS_POLICY_APPLIED recipe_id=%s event_kind=%s slot_id=%s speed_value=%s",
            tostring(launch_spec and launch_spec.recipe_id),
            tostring(event_context and event_context.event_kind),
            tostring(launch_spec and launch_spec.slot_id),
            tostring(mutations.speed_plus and mutations.speed_plus.speed_plus_speed)
        ))
    end
    if applied.size_plus == true then
        runtime_stats.inc("source_size_plus_policy_applied")
        log.info(string.format(
            "SPELLFORGE_SOURCE_SIZE_PLUS_POLICY_APPLIED recipe_id=%s event_kind=%s slot_id=%s size_area=%s",
            tostring(launch_spec and launch_spec.recipe_id),
            tostring(event_context and event_context.event_kind),
            tostring(launch_spec and launch_spec.slot_id),
            tostring(mutations.size_plus and mutations.size_plus.size_plus_area)
        ))
    end
    return inspected
end

function launch_modifier_policy.preparePlanPayloadModifiers(plan, opts)
    local options = opts or {}
    local modifiers = {}
    local inspected_count = 0
    for _, slot in ipairs(plan and plan.emission_slots or {}) do
        if slot and slot.kind == "payload_emission" then
            if options.source_opcode == nil or slot.source_postfix_opcode == options.source_opcode then
                if options.source_slot_id == nil or slot.parent_slot_id == options.source_slot_id then
                    local inspection = launch_modifier_policy.inspectPayloadEntry(plan, nil, slot, options)
                    if inspection.ok ~= true then
                        return nil, inspection.rejection_reason, {
                            ok = false,
                            rejection_reason = inspection.rejection_reason,
                            payload_slot_id = slot.slot_id,
                            modifier_features = inspection.modifier_features,
                        }
                    end
                    if inspection.mutations and inspection.mutations.payload_modifier_kind ~= nil then
                        inspected_count = inspected_count + 1
                        modifiers[slot.slot_id] = inspection
                    end
                end
            end
        end
    end
    return {
        ok = true,
        modifier_count = inspected_count,
        modifiers_by_slot_id = modifiers,
    }, nil, nil
end

function launch_modifier_policy.prepareCachedPlanPayloadModifiers(recipe_id, opts)
    local options = opts or {}
    local attached_specs = plan_cache.attachHelperSpecs(recipe_id, options.helper_spec_options)
    if not attached_specs.ok then
        return nil, "helper_specs_failed", {
            ok = false,
            rejection_reason = "helper_specs_failed",
            recipe_id = recipe_id,
            error = attached_specs.error,
            errors = attached_specs.errors,
            warnings = attached_specs.warnings,
        }
    end

    local prepared, prepare_reason, details = launch_modifier_policy.preparePlanPayloadModifiers(attached_specs.plan, options)
    if not prepared then
        details = details or {}
        details.ok = false
        details.recipe_id = recipe_id
        details.rejection_reason = details.rejection_reason or prepare_reason or "payload_modifier_combo_deferred"
        return nil, details.rejection_reason, details
    end

    prepared.recipe_id = recipe_id
    prepared.plan = attached_specs.plan
    prepared.spec_count = attached_specs.spec_count
    prepared.warnings = attached_specs.warnings
    return prepared, nil, nil
end

return launch_modifier_policy
