local limits = require("scripts.spellforge.shared.limits")
local nested_payload_audit = require("scripts.spellforge.global.nested_payload_audit")
local chaos_budget = require("scripts.spellforge.global.chaos_budget")

local payload_multicast = {}

local function hasOps(ops)
    return type(ops) == "table" and #ops > 0
end

local function hasPayloadBindings(value)
    return type(value) == "table" and #value > 0
end

local function hasOpcode(ops, opcode)
    for _, op in ipairs(ops or {}) do
        if op and op.opcode == opcode then
            return true
        end
    end
    return false
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

local function firstEffectId(helper)
    local first = helper and helper.effects and helper.effects[1] or nil
    return first and first.id or nil
end

local function sortByEmissionThenSlot(a, b)
    local ae = tonumber(a.emission_index) or 0
    local be = tonumber(b.emission_index) or 0
    if ae ~= be then
        return ae < be
    end
    return tostring(a.slot_id) < tostring(b.slot_id)
end

local function compactPayload(slot, helper)
    return {
        slot = slot,
        helper = helper,
        slot_id = slot.slot_id,
        helper_engine_id = helper.engine_id,
        effect_id = firstEffectId(helper),
        emission_index = slot.emission_index or helper.emission_index,
        group_index = slot.group_index or helper.group_index,
    }
end

local function reject(reason, details)
    local result = details or {}
    result.ok = false
    result.rejection_reason = reason
    return result
end

local function recordBudgetCap(category)
    chaos_budget.recordReject("payload_multicast_cap_exceeded", category)
end

local function cloneOp(op)
    if type(op) ~= "table" then
        return nil
    end
    return {
        opcode = op.opcode,
        effect_id = op.effect_id,
        params = op.params,
        index = op.index,
        payload_scope = op.payload_scope,
    }
end

local function payloadPrefixPolicy(slot, helper)
    local saw_multicast = false
    local pattern_kind = nil
    local pattern_op = nil
    for _, op in ipairs(slot.prefix_ops or {}) do
        local opcode = op and op.opcode
        if opcode == "Multicast" then
            saw_multicast = true
        elseif opcode == "Chain" then
            return nil, "payload_multicast_chain_deferred"
        elseif opcode == "Spread" or opcode == "Burst" then
            if pattern_kind ~= nil and pattern_kind ~= opcode then
                return nil, "payload_pattern_ambiguous"
            end
            pattern_kind = opcode
            pattern_op = pattern_op or op
        elseif opcode == "Speed+" then
            return nil, "payload_speed_plus_runtime_deferred"
        elseif opcode == "Size+" then
            return nil, "payload_size_plus_runtime_deferred"
        else
            return nil, "unsupported_payload_prefix_" .. tostring(opcode)
        end
    end

    for _, op in ipairs(helper.prefix_ops or {}) do
        local opcode = op and op.opcode
        if opcode == "Multicast" then
            saw_multicast = true
        elseif opcode == "Chain" then
            return nil, "payload_multicast_chain_deferred"
        elseif opcode == "Spread" or opcode == "Burst" then
            if pattern_kind ~= nil and pattern_kind ~= opcode then
                return nil, "payload_pattern_ambiguous"
            end
            pattern_kind = opcode
            pattern_op = pattern_op or op
        elseif opcode == "Speed+" then
            return nil, "payload_speed_plus_runtime_deferred"
        elseif opcode == "Size+" then
            return nil, "payload_size_plus_runtime_deferred"
        else
            return nil, "unsupported_payload_prefix_" .. tostring(opcode)
        end
    end

    return saw_multicast, nil, pattern_kind, cloneOp(pattern_op)
end

local function auditAllowsPayloadMulticast(plan, fanout_count, options)
    options = options or {}
    local max_fanout = tonumber(options.max_fanout) or limits.MAX_NESTED_PAYLOAD_FANOUT
    local max_jobs = tonumber(options.max_jobs) or limits.MAX_NESTED_PAYLOAD_JOBS
    local max_projectiles = tonumber(options.max_projectiles) or limits.MAX_PROJECTILES_PER_CAST
    local audit = nested_payload_audit.inspectPlan(plan, {
        max_depth = options.max_depth or limits.MAX_NESTED_PAYLOAD_DEPTH,
        max_jobs = max_jobs,
        max_fanout = max_fanout,
    })
    if not audit.ok then
        return false, audit.rejection_reason or "nested_payload_audit_rejected", audit
    end
    if audit.has_chain then
        return false, "payload_multicast_chain_deferred", audit
    end
    if options.allow_nested_final_fanout == true then
        if audit.max_payload_depth ~= 2 then
            return false, "nested_final_fanout_depth_deferred", audit
        end
    elseif audit.max_payload_depth ~= 1 then
        return false, "nested_payload_runtime_deferred", audit
    end
    if audit.nested_payload_count > 0 and options.allow_nested_final_fanout ~= true then
        return false, "nested_payload_runtime_deferred", audit
    end
    if audit.has_pattern_payload and options.allow_payload_pattern ~= true then
        return false, "payload_pattern_runtime_deferred", audit
    end
    if audit.has_speed_plus_payload then
        return false, "payload_speed_plus_runtime_deferred", audit
    end
    if audit.has_size_plus_payload then
        return false, "payload_size_plus_runtime_deferred", audit
    end
    if fanout_count > max_fanout then
        recordBudgetCap("fanout")
        return false, "payload_multicast_fanout_cap_exceeded", audit
    end
    if audit.estimated_total_jobs > max_jobs then
        recordBudgetCap("job")
        return false, "payload_multicast_job_cap_exceeded", audit
    end
    if audit.estimated_total_jobs > max_projectiles then
        recordBudgetCap("projectile")
        return false, "payload_multicast_projectile_cap_exceeded", audit
    end
    return true, nil, audit
end

function payload_multicast.resolvePayloadHelpersForSource(plan, source_slot, opts)
    local options = opts or {}
    local source_opcode = options.source_opcode
    if type(plan) ~= "table" then
        return reject("missing_plan")
    end
    if type(source_slot) ~= "table" or type(source_slot.slot_id) ~= "string" then
        return reject("missing_source_slot")
    end
    if source_opcode ~= "Trigger" and source_opcode ~= "Timer" then
        return reject("unsupported_payload_source_opcode")
    end
    if type(plan.emission_slots) ~= "table" or #plan.emission_slots == 0 then
        return reject("slot_count_zero")
    end
    if type(plan.helper_records) ~= "table" or #plan.helper_records == 0 then
        return reject("helper_record_count_zero")
    end

    local helpers_by_slot = helperBySlotId(plan.helper_records)
    local payloads = {}
    local saw_multicast = false
    local saw_pattern = false
    local pattern_kind = nil
    local pattern_op = nil
    local saw_unrelated_payload = false

    for _, slot in ipairs(plan.emission_slots) do
        if slot.kind == "payload_emission" then
            if slot.parent_slot_id == source_slot.slot_id and slot.source_postfix_opcode == source_opcode then
                local helper = helpers_by_slot[slot.slot_id]
                if not helper or type(helper.engine_id) ~= "string" or helper.engine_id == "" then
                    return reject("payload_helper_missing")
                end
                if helper.parent_slot_id ~= source_slot.slot_id or helper.source_postfix_opcode ~= source_opcode then
                    return reject("payload_helper_mapping_mismatch")
                end
                if source_opcode == "Trigger" then
                    if slot.trigger_source_slot_id ~= source_slot.slot_id or helper.trigger_source_slot_id ~= source_slot.slot_id then
                        return reject("payload_trigger_source_mismatch")
                    end
                    if slot.timer_source_slot_id ~= nil or helper.timer_source_slot_id ~= nil then
                        return reject("payload_timer_source_rejected")
                    end
                else
                    if slot.timer_source_slot_id ~= source_slot.slot_id or helper.timer_source_slot_id ~= source_slot.slot_id then
                        return reject("payload_timer_source_mismatch")
                    end
                    if slot.trigger_source_slot_id ~= nil or helper.trigger_source_slot_id ~= nil then
                        return reject("payload_trigger_source_rejected")
                    end
                end
                if hasOps(slot.postfix_ops) or hasOps(helper.postfix_ops) then
                    return reject("nested_payload_runtime_deferred")
                end
                if hasPayloadBindings(slot.payload_bindings) or hasPayloadBindings(helper.payload_bindings) then
                    return reject("nested_payload_runtime_deferred")
                end

                local prefix_multicast, prefix_reason, prefix_pattern_kind, prefix_pattern_op = payloadPrefixPolicy(slot, helper)
                if prefix_reason then
                    return reject(prefix_reason, {
                        detected_payload_pattern = prefix_reason == "payload_pattern_ambiguous",
                    })
                end
                if prefix_pattern_kind ~= nil then
                    if pattern_kind ~= nil and pattern_kind ~= prefix_pattern_kind then
                        return reject("payload_pattern_ambiguous", {
                            detected_payload_pattern = true,
                        })
                    end
                    saw_pattern = true
                    pattern_kind = prefix_pattern_kind
                    pattern_op = pattern_op or prefix_pattern_op
                end
                saw_multicast = saw_multicast or prefix_multicast == true
                payloads[#payloads + 1] = compactPayload(slot, helper)
            else
                saw_unrelated_payload = true
            end
        end
    end

    if #payloads == 0 then
        return reject("payload_missing")
    end
    table.sort(payloads, sortByEmissionThenSlot)

    local is_payload_multicast = saw_multicast or #payloads > 1
    local is_payload_pattern = saw_pattern == true
    local max_fanout = tonumber(options.max_fanout) or limits.MAX_NESTED_PAYLOAD_FANOUT
    local max_projectiles = tonumber(options.max_projectiles) or limits.MAX_PROJECTILES_PER_CAST
    if #payloads > 1 and not saw_multicast then
        return reject("multiple_payloads_without_multicast")
    end
    if is_payload_pattern and not is_payload_multicast then
        return reject("payload_pattern_fanout_missing", {
            detected_payload_pattern = true,
            payload_count = #payloads,
            fanout_count = #payloads,
        })
    end
    if is_payload_multicast and options.allow_payload_multicast ~= true then
        return reject("payload_multicast_disabled", {
            detected_payload_multicast = true,
            detected_payload_pattern = is_payload_pattern,
            payload_count = #payloads,
            fanout_count = #payloads,
        })
    end
    if is_payload_pattern and options.allow_payload_pattern ~= true then
        return reject("payload_pattern_disabled", {
            detected_payload_multicast = true,
            detected_payload_pattern = true,
            payload_count = #payloads,
            fanout_count = #payloads,
            pattern_kind = pattern_kind,
        })
    end
    if is_payload_multicast then
        if #payloads > max_fanout then
            recordBudgetCap("fanout")
            return reject("payload_multicast_fanout_cap_exceeded", {
                detected_payload_multicast = true,
                detected_payload_pattern = is_payload_pattern,
                payload_count = #payloads,
                fanout_count = #payloads,
                fanout_cap = max_fanout,
            })
        end
        if #payloads + 1 > max_projectiles then
            recordBudgetCap("projectile")
            return reject("payload_multicast_projectile_cap_exceeded", {
                detected_payload_multicast = true,
                detected_payload_pattern = is_payload_pattern,
                payload_count = #payloads,
                fanout_count = #payloads,
                projectile_cap = max_projectiles,
            })
        end
        local audit_ok, audit_reason, audit = auditAllowsPayloadMulticast(plan, #payloads, options)
        if not audit_ok then
            return reject(audit_reason, {
                detected_payload_multicast = true,
                detected_payload_pattern = is_payload_pattern,
                payload_count = #payloads,
                fanout_count = #payloads,
                audit = audit,
            })
        end
    elseif saw_unrelated_payload and options.allow_nested_final_fanout ~= true then
        -- A simple v0 source must not hide extra payload structure elsewhere.
        return reject("nested_payload_runtime_deferred")
    end

    local payload_slot_ids = {}
    local payload_helper_engine_ids = {}
    local payload_effect_ids = {}
    local payload_group_key_parts = {}
    for index, payload in ipairs(payloads) do
        payload_slot_ids[index] = payload.slot_id
        payload_helper_engine_ids[index] = payload.helper_engine_id
        payload_effect_ids[index] = payload.effect_id
        payload_group_key_parts[index] = payload.slot_id
    end

    return {
        ok = true,
        source_slot_id = source_slot.slot_id,
        source_opcode = source_opcode,
        payload_count = #payloads,
        payload_slots = payloads,
        payload_helpers = payloads,
        payload_slot_ids = payload_slot_ids,
        payload_helper_engine_ids = payload_helper_engine_ids,
        payload_effect_ids = payload_effect_ids,
        payload_slot_id = payload_slot_ids[1],
        payload_helper_engine_id = payload_helper_engine_ids[1],
        payload_effect_id = payload_effect_ids[1],
        fanout_count = #payloads,
        detected_payload_multicast = is_payload_multicast,
        detected_payload_pattern = is_payload_pattern,
        is_payload_multicast = is_payload_multicast,
        is_payload_pattern = is_payload_pattern,
        pattern_kind = pattern_kind,
        pattern_op = pattern_op,
        payload_group_key = table.concat(payload_group_key_parts, ","),
        audit_only = false,
    }
end

return payload_multicast
