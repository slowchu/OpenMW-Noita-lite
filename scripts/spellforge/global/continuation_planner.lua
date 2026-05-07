local limits = require("scripts.spellforge.shared.limits")
local launch_modifier_policy = require("scripts.spellforge.global.launch_modifier_policy")

local continuation_planner = {}

continuation_planner.VERSION = "spellforge-continuation-planner-v1"

local function hasOpcode(ops, opcode)
    for _, op in ipairs(ops or {}) do
        if op and op.opcode == opcode then
            return true, op
        end
    end
    return false, nil
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

local function hasPayloadBindings(entry)
    return type(entry and entry.payload_bindings) == "table" and #entry.payload_bindings > 0
end

local function helperId(entry)
    if type(entry) ~= "table" then
        return nil
    end
    return entry.helper_engine_id or entry.helper_logical_id
end

local function firstEffectId(entry)
    local first = entry and entry.effects and entry.effects[1] or nil
    return first and first.id or nil
end

local function entryBySlot(ir, slot_id)
    if type(slot_id) ~= "string" or slot_id == "" then
        return nil
    end
    if ir and ir.entries_by_slot_id and ir.entries_by_slot_id[slot_id] then
        return ir.entries_by_slot_id[slot_id]
    end
    for _, entry in ipairs(ir and ir.entries or {}) do
        if entry.slot_id == slot_id then
            return entry
        end
    end
    return nil
end

local function continuationBySourceKind(ir, source_slot_id, kind)
    for _, continuation in ipairs(ir and ir.continuations or {}) do
        if continuation.source_slot_id == source_slot_id and continuation.kind == kind then
            return continuation
        end
    end
    return nil
end

local function firstContinuation(ir, kind)
    for _, continuation in ipairs(ir and ir.continuations or {}) do
        if continuation.kind == kind then
            return continuation
        end
    end
    return nil
end

local function entriesForContinuation(ir, continuation)
    local entries = {}
    for _, entry_id in ipairs(continuation and continuation.payload_entry_ids or {}) do
        local entry = ir and ir.entries_by_id and ir.entries_by_id[entry_id] or nil
        if entry then
            entries[#entries + 1] = entry
        end
    end
    table.sort(entries, function(a, b)
        local ae = tonumber(a.emission_index) or 0
        local be = tonumber(b.emission_index) or 0
        if ae ~= be then
            return ae < be
        end
        return tostring(a.slot_id) < tostring(b.slot_id)
    end)
    return entries
end

local function payloadSlotIds(entries)
    local ids = {}
    for i, entry in ipairs(entries or {}) do
        ids[i] = entry.slot_id
    end
    return ids
end

local function payloadHelperEngineIds(entries)
    local ids = {}
    for i, entry in ipairs(entries or {}) do
        ids[i] = helperId(entry)
    end
    return ids
end

local function payloadEffectIds(entries)
    local ids = {}
    for i, entry in ipairs(entries or {}) do
        ids[i] = firstEffectId(entry)
    end
    return ids
end

local function patternKind(entries)
    local kind = nil
    local op = nil
    for _, entry in ipairs(entries or {}) do
        local has_spread, spread_op = hasOpcode(entry.prefix_ops, "Spread")
        local has_burst, burst_op = hasOpcode(entry.prefix_ops, "Burst")
        if has_spread then
            if kind ~= nil and kind ~= "Spread" then
                return "ambiguous", nil
            end
            kind = "Spread"
            op = op or spread_op
        elseif has_burst then
            if kind ~= nil and kind ~= "Burst" then
                return "ambiguous", nil
            end
            kind = "Burst"
            op = op or burst_op
        end
    end
    return kind, op
end

local function payloadFeatures(entries)
    local features = {
        multicast = false,
        pattern = false,
        pattern_kind = nil,
        chain = false,
        pierce = false,
        speed_plus = false,
        size_plus = false,
        nested_postfix = false,
    }
    if #(entries or {}) > 1 then
        features.multicast = true
    end
    for _, entry in ipairs(entries or {}) do
        if entry.fanout and entry.fanout.has_multicast then
            features.multicast = true
        end
        if entry.fanout and entry.fanout.has_pattern then
            features.pattern = true
        end
        if hasOpcode(entry.prefix_ops, "Multicast") then
            features.multicast = true
        end
        if hasOpcode(entry.prefix_ops, "Spread") or hasOpcode(entry.prefix_ops, "Burst") then
            features.pattern = true
        end
        if hasOpcode(entry.prefix_ops, "Chain") then
            features.chain = true
        end
        if hasOpcode(entry.prefix_ops, "Pierce") then
            features.pierce = true
        end
        if hasOpcode(entry.prefix_ops, "Speed+") then
            features.speed_plus = true
        end
        if hasOpcode(entry.prefix_ops, "Size+") then
            features.size_plus = true
        end
        if hasOpcode(entry.postfix_ops, "Trigger")
            or hasOpcode(entry.postfix_ops, "Timer")
            or hasPayloadBindings(entry) then
            features.nested_postfix = true
        end
    end
    features.pattern_kind = patternKind(entries)
    if features.pattern_kind == "ambiguous" then
        features.pattern_kind = nil
        features.pattern_ambiguous = true
    end
    return features
end

local function payloadMulticastEnabled(options)
    if options.force_payload_multicast_disabled == true then
        return false
    end
    return options.force_payload_multicast_enabled == true
        or options.allow_payload_multicast == true
        or options.payload_multicast_enabled == true
end

local function payloadPatternEnabled(options)
    if options.force_payload_pattern_disabled == true then
        return false
    end
    return options.force_payload_pattern_enabled == true
        or options.allow_payload_pattern == true
        or options.payload_pattern_enabled == true
end

local function chainMulticastEnabled(options)
    if options.force_chain_multicast_disabled == true then
        return false
    end
    return options.force_chain_multicast_enabled == true
        or options.allow_chain_multicast == true
        or options.chain_multicast_enabled == true
end

local function clampPositiveInteger(value, default_value, hard_max)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then
        n = default_value or 1
    end
    n = math.floor(n)
    if n < 1 then
        n = 1
    end
    if hard_max and n > hard_max then
        n = hard_max
    end
    return n
end

local function reject(plan, ir, event, source_entry, continuation, reason)
    return {
        ok = false,
        version = continuation_planner.VERSION,
        event_kind = event and event.event_kind or nil,
        recipe_id = (ir and ir.recipe_id) or (plan and plan.recipe_id),
        source_slot_id = source_entry and source_entry.slot_id or (event and event.source_slot_id),
        source_helper_engine_id = helperId(source_entry),
        continuation_id = continuation and continuation.continuation_id or nil,
        continuation_kind = continuation and continuation.kind or nil,
        payload_count = 0,
        payload_slot_ids = {},
        payload_helper_engine_ids = {},
        payload_features = {
            multicast = false,
            pattern = false,
            pattern_kind = nil,
            chain = false,
            pierce = false,
        },
        planned_jobs = {},
        rejection_reason = reason,
    }
end

local function buildJobs(source_entry, payload_entries, event, job_kind, branch_kind)
    local jobs = {}
    local count = #payload_entries
    for index, entry in ipairs(payload_entries) do
        jobs[index] = {
            job_kind = job_kind,
            slot_id = entry.slot_id,
            helper_engine_id = helperId(entry),
            payload_slot_id = entry.slot_id,
            source_slot_id = source_entry and source_entry.slot_id or nil,
            depth = entry.payload_depth or ((source_entry and source_entry.payload_depth or 0) + 1),
            branch_kind = branch_kind,
            branch_index = index,
            branch_count = count,
            bounce_index = event and event.bounce_index or nil,
        }
    end
    return jobs
end

local function success(plan, ir, event, source_entry, continuation, payload_entries, features, jobs, extra)
    local first_payload = payload_entries and payload_entries[1] or nil
    local result = {
        ok = true,
        version = continuation_planner.VERSION,
        event_kind = event and event.event_kind or nil,
        recipe_id = (ir and ir.recipe_id) or (plan and plan.recipe_id),
        source_slot_id = source_entry and source_entry.slot_id or nil,
        source_helper_engine_id = helperId(source_entry),
        continuation_id = continuation and continuation.continuation_id or nil,
        continuation_kind = continuation and continuation.kind or nil,
        payload_count = #(payload_entries or {}),
        payload_slot_id = first_payload and first_payload.slot_id or nil,
        payload_helper_engine_id = helperId(first_payload),
        payload_slot_ids = payloadSlotIds(payload_entries),
        payload_helper_engine_ids = payloadHelperEngineIds(payload_entries),
        payload_effect_ids = payloadEffectIds(payload_entries),
        payload_features = {
            multicast = features and features.multicast == true or false,
            pattern = features and features.pattern == true or false,
            pattern_kind = features and features.pattern_kind or nil,
            chain = features and features.chain == true or false,
            pierce = features and features.pierce == true or false,
        },
        payload_multicast = features and features.multicast == true or false,
        payload_pattern = features and features.pattern == true or false,
        payload_pattern_kind = features and features.pattern_kind or nil,
        has_chain_payload = features and features.chain == true or false,
        planned_jobs = jobs or {},
        rejection_reason = nil,
    }
    for key, value in pairs(extra or {}) do
        result[key] = value
    end
    return result
end

local function validatePayloadSet(plan, ir, entries, features, options)
    local max_fanout = tonumber(options.max_fanout) or limits.MAX_NESTED_PAYLOAD_FANOUT
    local max_projectiles = tonumber(options.max_projectiles) or limits.MAX_PROJECTILES_PER_CAST
    if #entries == 0 then
        return "payload_missing"
    end
    if features.pattern_ambiguous then
        return "payload_pattern_ambiguous"
    end
    if features.nested_postfix then
        return "nested_payload_runtime_deferred"
    end
    if features.pierce then
        return "pierce_recursion_deferred"
    end
    if features.speed_plus or features.size_plus then
        local policy_options = options
        if features.chain then
            policy_options = {}
            for key, value in pairs(options or {}) do
                policy_options[key] = value
            end
            policy_options.compatibility = "chain"
            policy_options.require_chain_prefix = true
            policy_options.allow_chain_multicast = chainMulticastEnabled(options)
        end
        for _, entry in ipairs(entries or {}) do
            local policy = launch_modifier_policy.inspectPayloadEntry(plan, ir, entry, policy_options)
            if policy.ok ~= true then
                return policy.rejection_reason or "payload_modifier_combo_deferred"
            end
        end
    end
    if features.pattern and not features.multicast then
        return "payload_pattern_fanout_missing"
    end
    if features.multicast and not payloadMulticastEnabled(options) then
        return "payload_multicast_disabled"
    end
    if features.pattern and not payloadPatternEnabled(options) then
        return "payload_pattern_disabled"
    end
    if features.multicast and #entries > max_fanout then
        return "payload_multicast_fanout_cap_exceeded"
    end
    if features.multicast and #entries + 1 > max_projectiles then
        return "payload_multicast_projectile_cap_exceeded"
    end
    return nil
end

local function postfixOnly(entry, opcode)
    local ops = entry and entry.postfix_ops or nil
    return type(ops) == "table" and #ops == 1 and ops[1] and ops[1].opcode == opcode
end

local function findRootPostfixContinuation(ir, kind)
    for _, continuation in ipairs(ir and ir.continuations or {}) do
        if continuation.kind == kind then
            local source = entryBySlot(ir, continuation.source_slot_id)
            if source and (source.payload_depth or 0) == 0 then
                return continuation, source
            end
        end
    end
    return nil, nil
end

local function planPostfixEvent(plan, ir, event, kind, opts)
    local options = opts or {}
    local source_entry = entryBySlot(ir, event and event.source_slot_id)
    local continuation = nil
    if source_entry then
        continuation = continuationBySourceKind(ir, source_entry.slot_id, kind)
    else
        continuation, source_entry = findRootPostfixContinuation(ir, kind)
    end
    if not source_entry then
        return reject(plan, ir, event, nil, nil, kind == "Trigger" and "missing_trigger_source_slot" or "missing_timer_source_slot")
    end
    if hasOpcode(source_entry.prefix_ops, "Homing") then
        return reject(plan, ir, event, source_entry, continuation, "homing_composition_deferred")
    end
    if not continuation then
        return reject(plan, ir, event, source_entry, nil, kind == "Trigger" and "source_not_trigger" or "source_not_timer")
    end

    local payload_entries = entriesForContinuation(ir, continuation)
    local features = payloadFeatures(payload_entries)
    local payload_reason = validatePayloadSet(plan, ir, payload_entries, features, options)
    if payload_reason then
        if payload_reason == "nested_payload_runtime_deferred"
            and options.allow_nested_trigger_timer == true
            and #payload_entries == 1
            and features.chain ~= true
            and ((kind == "Trigger" and postfixOnly(payload_entries[1], "Timer"))
                or (kind == "Timer" and postfixOnly(payload_entries[1], "Trigger"))) then
            payload_reason = nil
        end
    end
    if payload_reason then
        return reject(plan, ir, event, source_entry, continuation, payload_reason)
    end

    local job_kind = kind == "Trigger" and "trigger_payload_launch" or "timer_payload_launch"
    local branch_kind = kind == "Trigger" and "trigger_payload" or "timer_payload"
    if features.chain then
        job_kind = "chain_handoff"
        branch_kind = string.lower(kind) .. "_chain_payload"
    elseif features.pattern then
        branch_kind = branch_kind .. "_pattern"
    elseif features.multicast then
        branch_kind = branch_kind .. "_multicast"
    elseif features.nested_postfix then
        job_kind = kind == "Trigger" and "trigger_nested_continuation" or "timer_nested_continuation"
        branch_kind = string.lower(kind) .. "_nested_continuation"
    end

    return success(plan, ir, event, source_entry, continuation, payload_entries, features, buildJobs(source_entry, payload_entries, event, job_kind, branch_kind), {
        nested_trigger_timer = features.nested_postfix == true,
        chain_shape = features.chain and "trigger_payload_chain" or nil,
    })
end

local function sourceHasOnlyBounce(entry)
    local prefix = entry and entry.prefix_ops or {}
    local bounce_count = countOpcode(prefix, "Bounce")
    return bounce_count == 1 and #prefix == 1
end

local function sourceHasLaunchModifier(entry)
    return hasOpcode(entry and entry.prefix_ops or nil, "Speed+")
        or hasOpcode(entry and entry.prefix_ops or nil, "Size+")
end

local function sourceModifierPolicyOptions(options, source_kind)
    local opts = {
        policy_kind = "source",
        apply_size_to_specs = false,
        allow_bounce_source = source_kind == "bounce",
        allow_pierce_source = source_kind == "pierce",
        force_speed_plus_enabled = options and options.force_speed_plus_enabled,
        force_speed_plus_disabled = options and options.force_speed_plus_disabled,
        speed_plus_enabled = options and options.speed_plus_enabled == true,
        force_size_plus_enabled = options and options.force_size_plus_enabled,
        force_size_plus_disabled = options and options.force_size_plus_disabled,
        size_plus_enabled = options and options.size_plus_enabled == true,
    }
    return opts
end

local function validateSourceLaunchModifier(plan, ir, source_entry, options, source_kind)
    if not sourceHasLaunchModifier(source_entry) then
        return nil
    end
    local policy = launch_modifier_policy.inspectSourceEntry(
        plan,
        ir,
        source_entry,
        sourceModifierPolicyOptions(options, source_kind)
    )
    if policy.ok ~= true then
        return policy.rejection_reason or "source_modifier_unsupported_prefix"
    end
    return nil
end

local function firstBounceContinuation(ir)
    local continuation = firstContinuation(ir, "Bounce")
    return continuation, continuation and entryBySlot(ir, continuation.source_slot_id) or nil
end

local function hasDirectBounceChain(ir, bounce_source_slot_id)
    for _, entry in ipairs(ir and ir.entries or {}) do
        if hasOpcode(entry.prefix_ops, "Chain")
            and not (entry.parent_slot_id == bounce_source_slot_id and entry.source_postfix_opcode == "Trigger") then
            return true
        end
    end
    return false
end

local function validateBounceSource(plan, ir, event, source_entry, bounce_continuation, options)
    if not source_entry then
        return "missing_bounce_source_slot"
    end
    local bounce_count, bounce_op = countOpcode(source_entry.prefix_ops, "Bounce")
    if bounce_count ~= 1 then
        return "source_slot_not_bounce"
    end
    local source_modifier_reason = validateSourceLaunchModifier(plan, ir, source_entry, options, "bounce")
    if source_modifier_reason then
        return source_modifier_reason
    end
    if hasOpcode(source_entry.prefix_ops, "Chain") or hasDirectBounceChain(ir, source_entry.slot_id) then
        return "bounce_chain_deferred"
    end
    if hasOpcode(source_entry.prefix_ops, "Homing") then
        return "bounce_homing_deferred"
    end
    if hasOpcode(source_entry.prefix_ops, "Multicast")
        or hasOpcode(source_entry.prefix_ops, "Spread")
        or hasOpcode(source_entry.prefix_ops, "Burst") then
        return "bounce_fanout_deferred"
    end
    if not sourceHasLaunchModifier(source_entry) and not sourceHasOnlyBounce(source_entry) then
        return "bounce_prefix_combo_deferred"
    end
    if hasOpcode(source_entry.postfix_ops, "Timer") then
        return "bounce_timer_deferred"
    end
    if hasOpcode(source_entry.postfix_ops, "Homing") then
        return "bounce_homing_deferred"
    end
    if hasOpcode(source_entry.postfix_ops, "Trigger") and not postfixOnly(source_entry, "Trigger") then
        return "bounce_postfix_deferred"
    end
    if #(source_entry.postfix_ops or {}) > 0 and not postfixOnly(source_entry, "Trigger") then
        return "bounce_postfix_deferred"
    end
    local bounce_max = clampPositiveInteger(bounce_op and bounce_op.params and bounce_op.params.bounces, 1, limits.MAX_BOUNCE_COUNT_HARD)
    local cap = tonumber(options.max_bounce_count) or limits.MAX_BOUNCE_COUNT
    if bounce_max > cap then
        return "bounce_count_cap_exceeded"
    end
    return nil
end

local function planBounceEvent(plan, ir, event, opts)
    local options = opts or {}
    local bounce_continuation = nil
    local source_entry = entryBySlot(ir, event and event.source_slot_id)
    if source_entry then
        bounce_continuation = continuationBySourceKind(ir, source_entry.slot_id, "Bounce")
    else
        bounce_continuation, source_entry = firstBounceContinuation(ir)
    end
    local source_reason = validateBounceSource(plan, ir, event, source_entry, bounce_continuation, options)
    if source_reason then
        return reject(plan, ir, event, source_entry, bounce_continuation, source_reason)
    end

    local has_trigger = postfixOnly(source_entry, "Trigger")
    if not has_trigger then
        local _, bounce_op = countOpcode(source_entry.prefix_ops, "Bounce")
        return success(plan, ir, event, source_entry, bounce_continuation, {}, {
            multicast = false,
            pattern = false,
            chain = false,
        }, {}, {
            bounce_mode = "source_only",
            bounce_max = clampPositiveInteger(bounce_op and bounce_op.params and bounce_op.params.bounces, 1, limits.MAX_BOUNCE_COUNT_HARD),
        })
    end

    local trigger_continuation = continuationBySourceKind(ir, source_entry.slot_id, "Trigger")
    if not trigger_continuation then
        return reject(plan, ir, event, source_entry, bounce_continuation, "source_trigger_binding_missing")
    end
    local payload_entries = entriesForContinuation(ir, trigger_continuation)
    local features = payloadFeatures(payload_entries)
    if features.chain then
        if #payload_entries ~= 1 then
            return reject(plan, ir, event, source_entry, trigger_continuation, "bounce_fanout_deferred")
        end
        if features.multicast or features.pattern then
            return reject(plan, ir, event, source_entry, trigger_continuation, "bounce_fanout_deferred")
        end
        if features.speed_plus or features.size_plus then
            return reject(plan, ir, event, source_entry, trigger_continuation, "bounce_chain_modifier_deferred")
        end
        if features.nested_postfix then
            return reject(plan, ir, event, source_entry, trigger_continuation, "chain_trigger_timer_deferred")
        end
        return success(plan, ir, event, source_entry, trigger_continuation, payload_entries, features, buildJobs(source_entry, payload_entries, event, "chain_handoff", "bounce_trigger_chain_payload"), {
            bounce_mode = "trigger_payload",
            chain_shape = "trigger_payload_chain",
        })
    end

    local payload_reason = validatePayloadSet(plan, ir, payload_entries, features, options)
    if payload_reason then
        return reject(plan, ir, event, source_entry, trigger_continuation, payload_reason)
    end
    local branch_kind = "bounce_trigger_payload"
    if features.pattern then
        branch_kind = "bounce_trigger_payload_pattern"
    elseif features.multicast then
        branch_kind = "bounce_trigger_payload_multicast"
    end
    return success(plan, ir, event, source_entry, trigger_continuation, payload_entries, features, buildJobs(source_entry, payload_entries, event, "bounce_trigger_payload_launch", branch_kind), {
        bounce_mode = "trigger_payload",
    })
end

local function sourceHasOnlyPierce(entry)
    local prefix = entry and entry.prefix_ops or {}
    local pierce_count = countOpcode(prefix, "Pierce")
    return pierce_count == 1 and #prefix == 1
end

local function firstPierceContinuation(ir)
    local continuation = firstContinuation(ir, "Pierce")
    return continuation, continuation and entryBySlot(ir, continuation.source_slot_id) or nil
end

local function hasDirectPierceChain(ir, pierce_source_slot_id)
    for _, entry in ipairs(ir and ir.entries or {}) do
        if hasOpcode(entry.prefix_ops, "Chain")
            and not (entry.parent_slot_id == pierce_source_slot_id and entry.source_postfix_opcode == "Trigger") then
            return true
        end
    end
    return false
end

local function validatePierceSource(plan, ir, event, source_entry, pierce_continuation, options)
    if not source_entry then
        return "missing_pierce_source_slot"
    end
    local pierce_count, pierce_op = countOpcode(source_entry.prefix_ops, "Pierce")
    if pierce_count ~= 1 then
        return "source_slot_not_pierce"
    end
    local source_modifier_reason = validateSourceLaunchModifier(plan, ir, source_entry, options, "pierce")
    if source_modifier_reason then
        return source_modifier_reason
    end
    if hasOpcode(source_entry.prefix_ops, "Bounce") then
        return "pierce_bounce_deferred"
    end
    if hasOpcode(source_entry.prefix_ops, "Chain") or hasDirectPierceChain(ir, source_entry.slot_id) then
        return "pierce_chain_deferred"
    end
    if hasOpcode(source_entry.prefix_ops, "Homing") then
        return "pierce_homing_deferred"
    end
    if hasOpcode(source_entry.prefix_ops, "Multicast")
        or hasOpcode(source_entry.prefix_ops, "Spread")
        or hasOpcode(source_entry.prefix_ops, "Burst") then
        return "pierce_fanout_deferred"
    end
    if not sourceHasLaunchModifier(source_entry) and not sourceHasOnlyPierce(source_entry) then
        return "pierce_modifier_deferred"
    end
    if hasOpcode(source_entry.postfix_ops, "Timer") then
        return "pierce_timer_deferred"
    end
    if hasOpcode(source_entry.postfix_ops, "Homing") then
        return "pierce_homing_deferred"
    end
    if hasOpcode(source_entry.postfix_ops, "Trigger") and not postfixOnly(source_entry, "Trigger") then
        return "pierce_nested_payload_deferred"
    end
    if #(source_entry.postfix_ops or {}) > 0 and not postfixOnly(source_entry, "Trigger") then
        return "pierce_nested_payload_deferred"
    end
    local pierce_limit = clampPositiveInteger(pierce_op and pierce_op.params and pierce_op.params.pierces, 1, limits.MAX_PIERCE_COUNT_HARD)
    local cap = tonumber(options.max_pierce_count) or limits.MAX_PIERCE_COUNT
    if pierce_limit > cap then
        return "pierce_count_cap_exceeded"
    end
    return nil
end

local function planPierceEvent(plan, ir, event, opts)
    local options = opts or {}
    local pierce_continuation = nil
    local source_entry = entryBySlot(ir, event and event.source_slot_id)
    if source_entry then
        pierce_continuation = continuationBySourceKind(ir, source_entry.slot_id, "Pierce")
    else
        pierce_continuation, source_entry = firstPierceContinuation(ir)
    end
    local source_reason = validatePierceSource(plan, ir, event, source_entry, pierce_continuation, options)
    if source_reason then
        return reject(plan, ir, event, source_entry, pierce_continuation, source_reason)
    end

    local _, pierce_op = countOpcode(source_entry.prefix_ops, "Pierce")
    local pierce_limit = clampPositiveInteger(pierce_op and pierce_op.params and pierce_op.params.pierces, 1, limits.MAX_PIERCE_COUNT_HARD)
    local has_trigger = postfixOnly(source_entry, "Trigger")
    if not has_trigger then
        return success(plan, ir, event, source_entry, pierce_continuation, {}, {
            multicast = false,
            pattern = false,
            chain = false,
        }, {}, {
            pierce_mode = "source_only",
            pierce_limit = pierce_limit,
        })
    end

    local trigger_continuation = continuationBySourceKind(ir, source_entry.slot_id, "Trigger")
    if not trigger_continuation then
        return reject(plan, ir, event, source_entry, pierce_continuation, "source_trigger_binding_missing")
    end
    local payload_entries = entriesForContinuation(ir, trigger_continuation)
    local features = payloadFeatures(payload_entries)
    if features.chain then
        if #payload_entries ~= 1 then
            return reject(plan, ir, event, source_entry, trigger_continuation, "pierce_fanout_deferred")
        end
        if features.multicast or features.pattern then
            return reject(plan, ir, event, source_entry, trigger_continuation, "pierce_fanout_deferred")
        end
        if features.speed_plus or features.size_plus then
            return reject(plan, ir, event, source_entry, trigger_continuation, "pierce_modifier_deferred")
        end
        if features.nested_postfix then
            return reject(plan, ir, event, source_entry, trigger_continuation, "pierce_nested_payload_deferred")
        end
        local _, chain_op = countOpcode(payload_entries[1] and payload_entries[1].prefix_ops or {}, "Chain")
        local requested_hops = clampPositiveInteger(chain_op and chain_op.params and chain_op.params.hops, 1, nil)
        local max_hops = tonumber(options.max_hops) or limits.MAX_CHAIN_HOPS
        if requested_hops > max_hops then
            return reject(plan, ir, event, source_entry, trigger_continuation, "chain_hop_cap_exceeded")
        end
        return success(plan, ir, event, source_entry, trigger_continuation, payload_entries, features, buildJobs(source_entry, payload_entries, event, "chain_handoff", "pierce_trigger_chain_payload"), {
            pierce_mode = "trigger_payload",
            pierce_limit = pierce_limit,
            chain_shape = "trigger_payload_chain",
            requested_hops = requested_hops,
            max_hops = math.min(requested_hops, max_hops),
        })
    end

    local payload_reason = validatePayloadSet(plan, ir, payload_entries, features, options)
    if payload_reason == "nested_payload_runtime_deferred" then
        payload_reason = "pierce_nested_payload_deferred"
    end
    if payload_reason then
        return reject(plan, ir, event, source_entry, trigger_continuation, payload_reason)
    end
    local branch_kind = "pierce_trigger_payload"
    if features.pattern then
        branch_kind = "pierce_trigger_payload_pattern"
    elseif features.multicast then
        branch_kind = "pierce_trigger_payload_multicast"
    end
    return success(plan, ir, event, source_entry, trigger_continuation, payload_entries, features, buildJobs(source_entry, payload_entries, event, "pierce_trigger_payload_launch", branch_kind), {
        pierce_mode = "trigger_payload",
        pierce_limit = pierce_limit,
    })
end

local function sortedChainEntries(ir)
    local entries = {}
    for _, entry in ipairs(ir and ir.entries or {}) do
        if hasOpcode(entry.prefix_ops, "Chain") then
            entries[#entries + 1] = entry
        end
    end
    table.sort(entries, function(a, b)
        local ag = tonumber(a.group_index) or 0
        local bg = tonumber(b.group_index) or 0
        if ag ~= bg then
            return ag < bg
        end
        local ae = tonumber(a.emission_index) or 0
        local be = tonumber(b.emission_index) or 0
        if ae ~= be then
            return ae < be
        end
        return tostring(a.slot_id) < tostring(b.slot_id)
    end)
    return entries
end

local function previousPrimaryEntry(ir, chain_entry)
    local previous = nil
    for _, entry in ipairs(ir and ir.entries or {}) do
        if entry.slot_id == chain_entry.slot_id then
            return previous
        end
        if entry.kind == "primary_emission" and entry.parent_slot_id == nil then
            previous = entry
        end
    end
    return nil
end

local function chainPayloadEntries(ir, first_entry, chain_entries, options)
    local has_multicast = hasOpcode(first_entry.prefix_ops, "Multicast") or #chain_entries > 1
    if not has_multicast then
        return { first_entry }, nil
    end
    if not chainMulticastEnabled(options) then
        return nil, "chain_multicast_disabled"
    end
    local cap = tonumber(options.max_chain_multicast_fanout) or limits.MAX_CHAIN_MULTICAST_FANOUT
    if #chain_entries > cap then
        return nil, "chain_multicast_fanout_cap_exceeded"
    end
    return chain_entries, nil
end

local function planChainEvent(plan, ir, event, opts)
    local options = opts or {}
    local chain_entries = sortedChainEntries(ir)
    if #chain_entries == 0 then
        return reject(plan, ir, event, nil, nil, "no_chain")
    end
    local first_entry = chain_entries[1]
    local chain_continuation = continuationBySourceKind(ir, first_entry.slot_id, "Chain")
    local chain_count, chain_op = countOpcode(first_entry.prefix_ops, "Chain")
    if chain_count ~= 1 then
        return reject(plan, ir, event, first_entry, chain_continuation, "chain_recursion_deferred")
    end
    if #chain_entries > 1 and not hasOpcode(first_entry.prefix_ops, "Multicast") then
        return reject(plan, ir, event, first_entry, chain_continuation, "chain_recursion_deferred")
    end
    if hasOpcode(first_entry.prefix_ops, "Spread") or hasOpcode(first_entry.prefix_ops, "Burst") then
        return reject(plan, ir, event, first_entry, chain_continuation, "chain_pattern_deferred")
    end
    if hasOpcode(first_entry.postfix_ops, "Trigger")
        or hasOpcode(first_entry.postfix_ops, "Timer")
        or hasPayloadBindings(first_entry) then
        return reject(plan, ir, event, first_entry, chain_continuation, "chain_trigger_timer_deferred")
    end
    if first_entry.payload_depth and first_entry.payload_depth >= 2 then
        return reject(plan, ir, event, first_entry, chain_continuation, "chain_nested_payload_deferred")
    end
    local source_entry = nil
    local chain_shape = nil
    if first_entry.parent_slot_id == nil then
        source_entry = previousPrimaryEntry(ir, first_entry)
        chain_shape = "source_chain_payload"
    elseif first_entry.source_postfix_opcode == "Trigger" then
        source_entry = entryBySlot(ir, first_entry.parent_slot_id)
        chain_shape = "trigger_payload_chain"
    elseif first_entry.source_postfix_opcode == "Timer" then
        return reject(plan, ir, event, first_entry, chain_continuation, "chain_timer_context_deferred")
    end
    if not source_entry then
        return reject(plan, ir, event, first_entry, chain_continuation, "chain_source_missing")
    end

    local requested_hops = clampPositiveInteger(chain_op and chain_op.params and chain_op.params.hops, 1, nil)
    local max_hops = tonumber(options.max_hops) or limits.MAX_CHAIN_HOPS
    if requested_hops > max_hops then
        return reject(plan, ir, event, source_entry, chain_continuation, "chain_hop_cap_exceeded")
    end

    local payload_entries, payload_reason = chainPayloadEntries(ir, first_entry, chain_entries, options)
    if payload_reason then
        return reject(plan, ir, event, source_entry, chain_continuation, payload_reason)
    end
    local features = payloadFeatures(payload_entries)
    features.chain = true
    if features.speed_plus or features.size_plus then
        for _, entry in ipairs(payload_entries or {}) do
            local policy = launch_modifier_policy.inspectPayloadEntry(plan, ir, entry, {
                compatibility = "chain",
                require_chain_prefix = true,
                allow_chain_multicast = chainMulticastEnabled(options),
                force_chain_multicast_enabled = options.force_chain_multicast_enabled,
                force_chain_multicast_disabled = options.force_chain_multicast_disabled,
                chain_multicast_enabled = options.chain_multicast_enabled == true,
                max_chain_multicast_fanout = options.max_chain_multicast_fanout,
                force_speed_plus_enabled = options.force_speed_plus_enabled,
                force_speed_plus_disabled = options.force_speed_plus_disabled,
                speed_plus_enabled = options.speed_plus_enabled == true,
                force_size_plus_enabled = options.force_size_plus_enabled,
                force_size_plus_disabled = options.force_size_plus_disabled,
                size_plus_enabled = options.size_plus_enabled == true,
            })
            if policy.ok ~= true then
                return reject(plan, ir, event, source_entry, chain_continuation, policy.rejection_reason or "chain_payload_modifier_deferred")
            end
        end
    end
    local jobs_per_hop = #payload_entries
    local max_jobs = tonumber(options.max_jobs) or limits.MAX_CHAIN_JOBS_PER_CAST
    if requested_hops * jobs_per_hop > max_jobs then
        return reject(plan, ir, event, source_entry, chain_continuation, "chain_job_cap_exceeded")
    end

    return success(plan, ir, event, source_entry, chain_continuation, payload_entries, features, buildJobs(source_entry, payload_entries, event, "chain_payload_hop", "chain_payload"), {
        chain_shape = chain_shape,
        requested_hops = requested_hops,
        max_hops = math.min(requested_hops, max_hops),
        has_multicast_payload = features.multicast == true,
        chain_multicast_fanout_count = #payload_entries,
    })
end

function continuation_planner.planFromEvent(plan, ir, event, opts)
    local options = opts or (event and event.options) or event or {}
    if type(ir) ~= "table" or ir.ok ~= true then
        return reject(plan, ir, event, nil, nil, "runtime_ir_required")
    end
    if type(event) ~= "table" then
        return reject(plan, ir, event, nil, nil, "event_required")
    end
    local event_kind = event.event_kind
    if event_kind == "trigger_hit" then
        return planPostfixEvent(plan, ir, event, "Trigger", options)
    elseif event_kind == "timer_matured" then
        return planPostfixEvent(plan, ir, event, "Timer", options)
    elseif event_kind == "bounce" then
        return planBounceEvent(plan, ir, event, options)
    elseif event_kind == "pierce" then
        return planPierceEvent(plan, ir, event, options)
    elseif event_kind == "chain" or event_kind == "chain_hit" or event_kind == "chain_hop" then
        return planChainEvent(plan, ir, event, options)
    end
    return reject(plan, ir, event, nil, nil, "unsupported_event_kind")
end

return continuation_planner
