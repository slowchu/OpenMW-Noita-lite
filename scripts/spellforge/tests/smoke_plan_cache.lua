local plan_cache = require("scripts.spellforge.global.plan_cache")
local continuation_planner = require("scripts.spellforge.global.continuation_planner")
local feature_matrix = require("scripts.spellforge.global.feature_matrix")
local feature_matrix_ir = require("scripts.spellforge.global.feature_matrix_ir")
local launch_modifier_policy = require("scripts.spellforge.global.launch_modifier_policy")
local live_bounce = require("scripts.spellforge.global.live_bounce")
local live_chain = require("scripts.spellforge.global.live_chain")
local live_pierce = require("scripts.spellforge.global.live_pierce")
local live_timer = require("scripts.spellforge.global.live_timer")
local live_trigger = require("scripts.spellforge.global.live_trigger")
local nested_trigger_timer = require("scripts.spellforge.global.nested_trigger_timer")
local runtime_ir = require("scripts.spellforge.global.runtime_ir")
local runtime_job_planner = require("scripts.spellforge.global.runtime_job_planner")
local generated_lifecycle = require("scripts.spellforge.shared.generated_spell_lifecycle")
local operator_params = require("scripts.spellforge.shared.operator_params")
local recipe_model = require("scripts.spellforge.shared.recipe_model")
local saved_recipe_model = require("scripts.spellforge.shared.saved_recipe_model")
local ui_catalog = require("scripts.spellforge.global.ui_catalog")
local ui_contract = require("scripts.spellforge.global.ui_contract")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_plan_cache")
local dev = require("scripts.spellforge.shared.dev")

local state = {
    ran = false,
}

local function assertLine(ok, label, detail)
    if ok then
        log.info("PASS " .. label)
    else
        log.error("FAIL " .. label .. (detail and (" :: " .. detail) or ""))
    end
end

local function isNonEmptyString(v)
    return type(v) == "string" and v ~= ""
end

local function containsValue(values, expected)
    for _, value in ipairs(values or {}) do
        if value == expected then
            return true
        end
    end
    return false
end

local function findOp(ops, opcode)
    for _, op in ipairs(ops or {}) do
        if op.opcode == opcode then
            return op
        end
    end
    return nil
end

local function targetEffect(id, magnitude)
    return {
        id = id,
        range = 2,
        magnitudeMin = magnitude,
        magnitudeMax = magnitude,
        area = 0,
        duration = 1,
    }
end

local function issueDetail(result)
    local issue = result and result.errors and result.errors[1]
    if issue then
        return string.format("%s:%s", tostring(issue.code), tostring(issue.message))
    end
    return result and tostring(result.error) or nil
end

local function irKindCount(ir, kind)
    return (ir
        and ir.counts
        and ir.counts.continuations_by_kind
        and ir.counts.continuations_by_kind[kind])
        or 0
end

local function sortedListText(values)
    local copy = {}
    for i, value in ipairs(values or {}) do
        copy[i] = tostring(value)
    end
    table.sort(copy)
    if #copy == 0 then
        return "none"
    end
    return table.concat(copy, ",")
end

local function matrixFieldText(matrix, field)
    if field == "contexts.primary" then
        return sortedListText(matrix and matrix.contexts and matrix.contexts.primary)
    elseif field == "contexts.payload" then
        return sortedListText(matrix and matrix.contexts and matrix.contexts.payload)
    elseif field == "contexts.nested_payload" then
        return sortedListText(matrix and matrix.contexts and matrix.contexts.nested_payload)
    elseif field == "active_feature_ids" then
        return sortedListText(matrix and matrix.active_feature_ids)
    elseif field == "combos" then
        return sortedListText(matrix and matrix.combos)
    elseif field == "deferred_reasons" then
        return sortedListText(matrix and matrix.deferred_reasons)
    elseif field == "required_flags" then
        return sortedListText(matrix and matrix.required_flags)
    end
    local value = matrix and matrix[field] or nil
    if value == nil then
        return "nil"
    end
    return tostring(value)
end

local function compareFeatureMatrix(label, current_matrix, ir_matrix)
    local fields = {
        "live_runtime_status",
        "active_feature_ids",
        "combos",
        "deferred_reasons",
        "required_flags",
        "contexts.primary",
        "contexts.payload",
        "contexts.nested_payload",
    }
    local ok = true
    for _, field in ipairs(fields) do
        local current_value = matrixFieldText(current_matrix, field)
        local ir_value = matrixFieldText(ir_matrix, field)
        if current_value ~= ir_value then
            ok = false
            log.error(string.format(
                "SPELLFORGE_IR_FEATURE_MATRIX_COMPARE_DIFF label=%s field=%s old=%s ir=%s",
                tostring(label),
                tostring(field),
                current_value,
                ir_value
            ))
        end
    end
    if ok then
        log.info("SPELLFORGE_IR_FEATURE_MATRIX_COMPARE_OK label=" .. tostring(label))
    end
    assertLine(ok, "22 IR feature matrix shadow " .. label .. " matches current analyzer")
end

local PLANNER_COMPARE_OPTS = {
    allow_payload_multicast = true,
    allow_payload_pattern = true,
    force_payload_multicast_enabled = true,
    force_payload_pattern_enabled = true,
    allow_nested_trigger_timer = true,
    allow_nested_final_fanout = true,
    enabled = true,
    enable_final_fanout = true,
    allow_chain_multicast = true,
    force_chain_multicast_enabled = true,
    force_chain_runtime_enabled = true,
    allow_payload_launch_modifiers = true,
    force_speed_plus_enabled = true,
    force_size_plus_enabled = true,
    max_jobs = 32,
    max_projectiles = 32,
    max_pierce_count = 3,
}

local function cloneOps(ops)
    local out = {}
    for i, op in ipairs(ops or {}) do
        local params = {}
        for key, value in pairs(op.params or {}) do
            params[key] = value
        end
        out[i] = {
            opcode = op.opcode,
            effect_id = op.effect_id,
            params = params,
            index = op.index,
            payload_scope = op.payload_scope,
        }
    end
    return out
end

local function syntheticHelperRecords(plan)
    local records = {}
    for i, spec in ipairs(plan.helper_specs or {}) do
        local routing = spec.routing or {}
        records[i] = {
            recipe_id = spec.recipe_id,
            slot_id = spec.slot_id,
            logical_id = spec.logical_id,
            engine_id = spec.engine_record_id or spec.logical_id,
            range = spec.range,
            effects = spec.effects,
            kind = routing.kind,
            group_index = routing.group_index,
            emission_index = routing.emission_index,
            parent_slot_id = routing.parent_slot_id,
            trigger_source_slot_id = routing.trigger_source_slot_id,
            timer_source_slot_id = routing.timer_source_slot_id,
            source_postfix_opcode = routing.source_postfix_opcode,
            payload_bindings = routing.payload_bindings,
            prefix_ops = cloneOps(routing.prefix_ops),
            postfix_ops = cloneOps(routing.postfix_ops),
        }
    end
    return records
end

local function selectorPlan(plan)
    local copy = {}
    for key, value in pairs(plan or {}) do
        copy[key] = value
    end
    copy.helper_records = syntheticHelperRecords(plan or {})
    copy.helper_record_count = #copy.helper_records
    return copy
end

local function clonePlannerCompareOptions()
    local out = {}
    for key, value in pairs(PLANNER_COMPARE_OPTS) do
        out[key] = value
    end
    return out
end

local function sourceEntryForEvent(plan, event)
    local source_slot_id = event and event.source_slot_id or nil
    if source_slot_id == nil then
        return nil
    end
    for _, slot in ipairs(plan and plan.emission_slots or {}) do
        if slot and slot.slot_id == source_slot_id then
            return slot
        end
    end
    return nil
end

local function hasSourceLaunchModifier(entry)
    for _, op in ipairs(entry and entry.prefix_ops or {}) do
        if op and (op.opcode == "Speed+" or op.opcode == "Size+") then
            return true
        end
    end
    return false
end

local function legacySelectorOptions(plan, event, source_kind)
    local opts = clonePlannerCompareOptions()
    local source_entry = sourceEntryForEvent(plan, event)
    if hasSourceLaunchModifier(source_entry) then
        opts.source_modifier_policy = launch_modifier_policy.inspectSourceEntry(
            plan,
            plan and plan.runtime_ir or nil,
            source_entry,
            {
                policy_kind = "source",
                apply_size_to_specs = false,
                allow_bounce_source = source_kind == "bounce",
                allow_pierce_source = source_kind == "pierce",
                force_speed_plus_enabled = opts.force_speed_plus_enabled,
                force_speed_plus_disabled = opts.force_speed_plus_disabled,
                speed_plus_enabled = opts.speed_plus_enabled == true,
                force_size_plus_enabled = opts.force_size_plus_enabled,
                force_size_plus_disabled = opts.force_size_plus_disabled,
                size_plus_enabled = opts.size_plus_enabled == true,
                quiet = true,
            }
        )
    end
    return opts
end

local function helperBySlot(plan)
    local by_slot = {}
    for _, helper in ipairs(plan.helper_records or {}) do
        by_slot[helper.slot_id] = helper
    end
    return by_slot
end

local function firstIrContinuation(ir, kind)
    for _, continuation in ipairs(ir.continuations or {}) do
        if continuation.kind == kind then
            return continuation
        end
    end
    return nil
end

local function rootPostfixContinuation(ir)
    for _, continuation in ipairs(ir.continuations or {}) do
        if continuation.kind == "Trigger" or continuation.kind == "Timer" then
            local source = ir.entries_by_slot_id and ir.entries_by_slot_id[continuation.source_slot_id] or nil
            if source and (source.payload_depth or 0) == 0 then
                return continuation
            end
        end
    end
    return nil
end

local function plannerEventForCase(label, ir)
    if string.find(label, "Pierce", 1, true) then
        local continuation = firstIrContinuation(ir, "Pierce")
        if continuation then
            return {
                event_kind = "pierce",
                source_slot_id = continuation.source_slot_id,
                source_prefix_opcode = "Pierce",
                source_postfix_opcode = firstIrContinuation(ir, "Trigger") and "Trigger" or nil,
                pierce_count = 1,
                pierce_limit = 3,
                current_hit_target_id = "smoke_pierced_actor",
                actor_id = "smoke_pierced_actor",
                projectile_id = "smoke_pierce_projectile",
            }
        end
    end
    if string.find(label, "Bounce", 1, true) then
        local continuation = firstIrContinuation(ir, "Bounce")
        if continuation then
            return {
                event_kind = "bounce",
                source_slot_id = continuation.source_slot_id,
                source_prefix_opcode = "Bounce",
                source_postfix_opcode = firstIrContinuation(ir, "Trigger") and "Trigger" or nil,
                bounce_index = 1,
            }
        end
    end
    if string.find(label, "Chain", 1, true) then
        if firstIrContinuation(ir, "Chain") then
            return {
                event_kind = "chain",
                source_prefix_opcode = "Chain",
            }
        end
    end
    local root = rootPostfixContinuation(ir)
    if root and root.kind == "Trigger" then
        return {
            event_kind = "trigger_hit",
            source_slot_id = root.source_slot_id,
            source_postfix_opcode = "Trigger",
        }
    elseif root and root.kind == "Timer" then
        return {
            event_kind = "timer_matured",
            source_slot_id = root.source_slot_id,
            source_postfix_opcode = "Timer",
        }
    end
    return nil
end

local function arrayText(values)
    local copy = {}
    for i, value in ipairs(values or {}) do
        copy[i] = tostring(value)
    end
    return #copy == 0 and "none" or table.concat(copy, ",")
end

local function normalizedFieldText(result, field)
    if field == "payload_slot_ids" or field == "payload_helper_engine_ids" then
        return arrayText(result and result[field])
    end
    if not result then
        return "nil"
    end
    local value = result[field]
    if value == nil then
        return "nil"
    end
    return tostring(value)
end

local function normalizePlannerResult(result)
    return {
        ok = result and result.ok == true,
        rejection_reason = result and result.rejection_reason or nil,
        source_slot_id = result and result.source_slot_id or nil,
        source_helper_engine_id = result and result.source_helper_engine_id or nil,
        payload_count = tonumber(result and result.payload_count) or 0,
        payload_slot_ids = result and result.payload_slot_ids or {},
        payload_helper_engine_ids = result and result.payload_helper_engine_ids or {},
        payload_multicast = result and result.payload_multicast == true or false,
        payload_pattern = result and result.payload_pattern == true or false,
        payload_pattern_kind = result and result.payload_pattern_kind or nil,
        has_chain_payload = result and result.has_chain_payload == true or false,
        chain_shape = result and result.chain_shape or nil,
    }
end

local function normalizeLegacyTriggerTimer(result, reason)
    return {
        ok = result ~= nil,
        rejection_reason = result and nil or reason,
        source_slot_id = result and result.source_slot_id or nil,
        source_helper_engine_id = result and result.source_helper_engine_id or nil,
        payload_count = tonumber(result and result.payload_count) or 0,
        payload_slot_ids = result and result.payload_slot_ids or {},
        payload_helper_engine_ids = result and result.payload_helper_engine_ids or {},
        payload_multicast = result and result.payload_multicast == true or false,
        payload_pattern = result and result.payload_pattern == true or false,
        payload_pattern_kind = result and result.payload_pattern_kind or nil,
        has_chain_payload = false,
        chain_shape = nil,
    }
end

local function normalizeLegacyBounce(result, reason)
    return {
        ok = result ~= nil and result.ok == true,
        rejection_reason = result and nil or reason,
        source_slot_id = result and result.source_slot_id or nil,
        source_helper_engine_id = result and result.source_helper_engine_id or nil,
        payload_count = tonumber(result and result.payload_count) or 0,
        payload_slot_ids = result and result.payload_slot_ids or {},
        payload_helper_engine_ids = result and result.payload_helper_engine_ids or {},
        payload_multicast = result and result.payload_multicast == true or false,
        payload_pattern = result and result.payload_pattern == true or false,
        payload_pattern_kind = result and result.payload_pattern_kind or nil,
        has_chain_payload = result and result.has_chain_payload == true or false,
        chain_shape = result and result.chain_shape or nil,
    }
end

local function normalizeLegacyPierce(result, reason)
    return {
        ok = result ~= nil and result.ok == true,
        rejection_reason = result and nil or reason,
        source_slot_id = result and result.source_slot_id or nil,
        source_helper_engine_id = result and result.source_helper_engine_id or nil,
        payload_count = tonumber(result and result.payload_count) or 0,
        payload_slot_ids = result and result.payload_slot_ids or {},
        payload_helper_engine_ids = result and result.payload_helper_engine_ids or {},
        payload_multicast = result and result.payload_multicast == true or false,
        payload_pattern = result and result.payload_pattern == true or false,
        payload_pattern_kind = result and result.payload_pattern_kind or nil,
        has_chain_payload = result and result.has_chain_payload == true or false,
        chain_shape = result and result.chain_shape or nil,
    }
end

local function normalizeLegacyChain(plan, result, reason)
    if not result then
        return {
            ok = false,
            rejection_reason = reason,
            payload_count = 0,
            payload_slot_ids = {},
            payload_helper_engine_ids = {},
            payload_multicast = false,
            payload_pattern = false,
            has_chain_payload = false,
        }
    end
    local helpers = helperBySlot(plan)
    local payload_slot_ids = result.audit and result.audit.payload_slot_ids or nil
    if type(payload_slot_ids) ~= "table" or #payload_slot_ids == 0 then
        payload_slot_ids = { result.payload_slot_id }
    end
    local payload_helper_ids = {}
    for i, slot_id in ipairs(payload_slot_ids) do
        payload_helper_ids[i] = helpers[slot_id] and helpers[slot_id].engine_id or nil
    end
    return {
        ok = result.ok == true,
        rejection_reason = nil,
        source_slot_id = result.source_slot_id,
        source_helper_engine_id = result.source_helper_engine_id,
        payload_count = #payload_slot_ids,
        payload_slot_ids = payload_slot_ids,
        payload_helper_engine_ids = payload_helper_ids,
        payload_multicast = result.has_multicast_payload == true,
        payload_pattern = false,
        payload_pattern_kind = nil,
        has_chain_payload = true,
        chain_shape = result.chain_shape,
    }
end

local function normalizeLegacyNested(result, reason)
    if not result then
        return {
            ok = false,
            rejection_reason = reason,
            payload_count = 0,
            payload_slot_ids = {},
            payload_helper_engine_ids = {},
            payload_multicast = false,
            payload_pattern = false,
            has_chain_payload = false,
        }
    end
    return {
        ok = result.ok == true,
        rejection_reason = nil,
        source_slot_id = result.root_source_slot_id,
        source_helper_engine_id = result.root_source_helper_engine_id,
        payload_count = 1,
        payload_slot_ids = { result.intermediate_slot_id },
        payload_helper_engine_ids = { result.intermediate_helper_engine_id },
        payload_multicast = false,
        payload_pattern = false,
        payload_pattern_kind = nil,
        has_chain_payload = false,
        chain_shape = nil,
    }
end

local function legacyContinuationForCase(label, plan, event)
    local prepared = selectorPlan(plan)
    local result, reason = nil, nil
    if string.find(label, "nested Trigger Timer", 1, true)
        or string.find(label, "nested Timer Trigger", 1, true) then
        result, reason = nested_trigger_timer.selectV1Plan(prepared, PLANNER_COMPARE_OPTS)
        return normalizeLegacyNested(result, reason), "nested_trigger_timer.selectV1Plan"
    elseif event and event.event_kind == "bounce" then
        result, reason = live_bounce.selectV0Plan(prepared, legacySelectorOptions(prepared, event, "bounce"))
        return normalizeLegacyBounce(result, reason), "live_bounce.selectV0Plan"
    elseif event and event.event_kind == "pierce" then
        result, reason = live_pierce.selectV0Plan(prepared, legacySelectorOptions(prepared, event, "pierce"))
        return normalizeLegacyPierce(result, reason), "live_pierce.selectV0Plan"
    elseif event and event.event_kind == "chain" then
        result, reason = live_chain.selectV0Plan(prepared, PLANNER_COMPARE_OPTS)
        return normalizeLegacyChain(prepared, result, reason), "live_chain.selectV0Plan"
    elseif event and event.event_kind == "trigger_hit" then
        if string.find(label, "Homing", 1, true) then
            return nil, nil
        end
        result, reason = live_trigger.selectV0Plan(prepared, PLANNER_COMPARE_OPTS)
        return normalizeLegacyTriggerTimer(result, reason), "live_trigger.selectV0Plan"
    elseif event and event.event_kind == "timer_matured" then
        result, reason = live_timer.selectV0Plan(prepared, PLANNER_COMPARE_OPTS)
        return normalizeLegacyTriggerTimer(result, reason), "live_timer.selectV0Plan"
    end
    return nil, nil
end

local EXPECTED_PLANNER_DEFERRED = {
    ["deferred Homing composition"] = "homing_composition_deferred",
}

local function compareContinuationPlan(label, plan, ir)
    local event = plannerEventForCase(label, ir)
    if not event then
        return
    end

    local planner = continuation_planner.planFromEvent(plan, ir, event, PLANNER_COMPARE_OPTS)
    local normalized_planner = normalizePlannerResult(planner)
    local expected_deferred = EXPECTED_PLANNER_DEFERRED[label]
    if expected_deferred then
        local ok = normalized_planner.ok == false and normalized_planner.rejection_reason == expected_deferred
        if ok then
            log.info(string.format(
                "SPELLFORGE_IR_CONTINUATION_PLAN_DEFERRED label=%s reason=%s",
                tostring(label),
                tostring(expected_deferred)
            ))
        end
        assertLine(ok, "23 IR continuation planner " .. label .. " defers with stable reason", normalized_planner.rejection_reason)
        return
    end

    local legacy, selector_name = legacyContinuationForCase(label, plan, event)
    if not legacy then
        return
    end

    local fields = {
        "ok",
        "rejection_reason",
        "source_slot_id",
        "source_helper_engine_id",
        "payload_count",
        "payload_slot_ids",
        "payload_helper_engine_ids",
        "payload_multicast",
        "payload_pattern",
        "payload_pattern_kind",
        "has_chain_payload",
        "chain_shape",
    }
    if legacy.ok == false and normalized_planner.ok == false then
        fields = {
            "ok",
            "rejection_reason",
        }
    end
    local ok = true
    for _, field in ipairs(fields) do
        local legacy_value = normalizedFieldText(legacy, field)
        local planner_value = normalizedFieldText(normalized_planner, field)
        if legacy_value ~= planner_value then
            ok = false
            log.error(string.format(
                "SPELLFORGE_IR_CONTINUATION_PLAN_DIFF label=%s field=%s legacy=%s ir=%s selector=%s",
                tostring(label),
                tostring(field),
                legacy_value,
                planner_value,
                tostring(selector_name)
            ))
        end
    end
    if ok and normalized_planner.ok == false then
        log.info(string.format(
            "SPELLFORGE_IR_CONTINUATION_PLAN_DEFERRED label=%s reason=%s selector=%s event=%s",
            tostring(label),
            tostring(normalized_planner.rejection_reason),
            tostring(selector_name),
            tostring(event.event_kind)
        ))
    elseif ok then
        log.info(string.format(
            "SPELLFORGE_IR_CONTINUATION_PLAN_OK label=%s selector=%s event=%s payload_count=%s reason=%s",
            tostring(label),
            tostring(selector_name),
            tostring(event.event_kind),
            tostring(normalized_planner.payload_count),
            tostring(normalized_planner.rejection_reason)
        ))
    end
    assertLine(ok, "23 IR continuation planner " .. label .. " matches " .. tostring(selector_name))
end

local function runtimeKindForSmoke(semantic_kind, event_kind)
    if semantic_kind == "trigger_payload_launch"
        or semantic_kind == "bounce_trigger_payload_launch"
        or semantic_kind == "pierce_trigger_payload_launch"
        or semantic_kind == "trigger_nested_continuation" then
        return "live_trigger_payload_launch"
    elseif semantic_kind == "timer_payload_launch"
        or semantic_kind == "timer_nested_continuation" then
        return "live_timer_payload_launch"
    elseif semantic_kind == "chain_payload_hop" then
        return "live_chain_payload_launch"
    elseif semantic_kind == "chain_handoff" then
        return "live_chain_handoff"
    elseif event_kind == "timer_matured" then
        return "live_timer_payload_launch"
    elseif event_kind == "chain" or event_kind == "chain_hit" or event_kind == "chain_hop" then
        return "live_chain_payload_launch"
    end
    return semantic_kind or "dry_run_runtime_job"
end

local function valueText(value)
    if value == nil then
        return "nil"
    end
    return tostring(value)
end

local function sequenceText(values)
    if type(values) ~= "table" or #values == 0 then
        return "none"
    end
    local parts = {}
    for i, value in ipairs(values) do
        parts[i] = valueText(value)
    end
    return table.concat(parts, ",")
end

local function sequenceFromJobs(jobs, field)
    local out = {}
    for i, job in ipairs(jobs or {}) do
        out[i] = valueText(job and job[field])
    end
    return out
end

local function expectedBounceMax(ir, continuation, event)
    if not event or event.event_kind ~= "bounce" then
        return nil
    end
    if continuation and continuation.bounce_max ~= nil then
        return continuation.bounce_max
    end
    local source = ir and ir.entries_by_slot_id and continuation and ir.entries_by_slot_id[continuation.source_slot_id] or nil
    local bounce_op = source and findOp(source.prefix_ops, "Bounce") or nil
    local bounces = bounce_op and bounce_op.params and tonumber(bounce_op.params.bounces) or nil
    return bounces or 1
end

local function expectedJobPlanFromContinuation(continuation, event, ir)
    local jobs = continuation and continuation.planned_jobs or {}
    local count = #jobs
    local pattern_kind = continuation and continuation.payload_pattern == true and continuation.payload_pattern_kind or nil
    local expected = {
        ok = continuation and continuation.ok == true,
        rejection_reason = continuation and continuation.rejection_reason or nil,
        source_slot_id = continuation and continuation.source_slot_id or nil,
        source_helper_engine_id = continuation and continuation.source_helper_engine_id or nil,
        planned_job_count = count,
        kind_sequence = {},
        slot_id_sequence = {},
        helper_engine_id_sequence = {},
        payload_slot_id_sequence = {},
        depth_sequence = {},
        fanout_count_sequence = {},
        branch_kind_sequence = {},
        branch_count_sequence = {},
        pattern_kind_sequence = {},
        pattern_count_sequence = {},
        pattern_index_sequence = {},
        trigger_source_slot_id_sequence = {},
        timer_source_slot_id_sequence = {},
        bounce_role_sequence = {},
        chain_role_sequence = {},
        source_event_bounce_role = event and event.event_kind == "bounce" and "source" or nil,
        source_event_bounce_max = expectedBounceMax(ir, continuation, event),
    }

    for index, job in ipairs(jobs) do
        local job_kind = job and job.job_kind or nil
        expected.kind_sequence[index] = runtimeKindForSmoke(job_kind, event and event.event_kind)
        expected.slot_id_sequence[index] = valueText(job and job.slot_id)
        expected.helper_engine_id_sequence[index] = valueText(job and job.helper_engine_id)
        expected.payload_slot_id_sequence[index] = valueText(job and job.payload_slot_id)
        expected.depth_sequence[index] = valueText(job and job.depth)
        expected.fanout_count_sequence[index] = valueText(count)
        expected.branch_kind_sequence[index] = valueText(job and job.branch_kind)
        expected.branch_count_sequence[index] = valueText(job and job.branch_count)
        expected.pattern_kind_sequence[index] = valueText(pattern_kind)
        expected.pattern_count_sequence[index] = valueText(pattern_kind and count or nil)
        expected.pattern_index_sequence[index] = valueText(pattern_kind and index or nil)
        if (event and event.source_postfix_opcode == "Trigger")
            or (continuation and continuation.continuation_kind == "Trigger") then
            expected.trigger_source_slot_id_sequence[index] = valueText(continuation and continuation.source_slot_id)
        else
            expected.trigger_source_slot_id_sequence[index] = "nil"
        end
        if (event and event.event_kind == "timer_matured")
            or (continuation and continuation.continuation_kind == "Timer") then
            expected.timer_source_slot_id_sequence[index] = valueText(continuation and continuation.source_slot_id)
        else
            expected.timer_source_slot_id_sequence[index] = "nil"
        end
        expected.bounce_role_sequence[index] = valueText(
            event and event.event_kind == "bounce"
                and (job_kind == "chain_handoff" and "trigger_chain_payload" or "trigger_payload_launch")
                or nil
        )
        expected.chain_role_sequence[index] = valueText(
            job_kind == "chain_handoff" and "source"
                or job_kind == "chain_payload_hop" and "payload"
                or nil
        )
    end
    return expected
end

local function normalizeRuntimeJobPlan(result)
    local jobs = result and result.planned_jobs or {}
    local source_event = result and result.source_event or nil
    return {
        ok = result and result.ok == true,
        rejection_reason = result and result.rejection_reason or nil,
        source_slot_id = result and result.source_slot_id or nil,
        source_helper_engine_id = result and result.source_helper_engine_id or nil,
        planned_job_count = tonumber(result and result.planned_job_count) or 0,
        kind_sequence = sequenceFromJobs(jobs, "kind"),
        slot_id_sequence = sequenceFromJobs(jobs, "slot_id"),
        helper_engine_id_sequence = sequenceFromJobs(jobs, "helper_engine_id"),
        payload_slot_id_sequence = sequenceFromJobs(jobs, "payload_slot_id"),
        depth_sequence = sequenceFromJobs(jobs, "depth"),
        fanout_count_sequence = sequenceFromJobs(jobs, "fanout_count"),
        branch_kind_sequence = sequenceFromJobs(jobs, "branch_kind"),
        branch_count_sequence = sequenceFromJobs(jobs, "branch_count"),
        pattern_kind_sequence = sequenceFromJobs(jobs, "pattern_kind"),
        pattern_count_sequence = sequenceFromJobs(jobs, "pattern_count"),
        pattern_index_sequence = sequenceFromJobs(jobs, "pattern_index"),
        trigger_source_slot_id_sequence = sequenceFromJobs(jobs, "trigger_source_slot_id"),
        timer_source_slot_id_sequence = sequenceFromJobs(jobs, "timer_source_slot_id"),
        bounce_role_sequence = sequenceFromJobs(jobs, "bounce_role"),
        chain_role_sequence = sequenceFromJobs(jobs, "chain_role"),
        source_event_bounce_role = source_event and source_event.bounce_role or nil,
        source_event_bounce_max = source_event and source_event.bounce_max or nil,
    }
end

local function runtimeJobFieldText(result, field)
    if string.sub(field, -9) == "_sequence" then
        return sequenceText(result and result[field])
    end
    return valueText(result and result[field])
end

local function compareRuntimeJobPlan(label, plan, ir)
    local event = plannerEventForCase(label, ir)
    if not event then
        return
    end

    local continuation = continuation_planner.planFromEvent(plan, ir, event, PLANNER_COMPARE_OPTS)
    local job_plan = runtime_job_planner.planJobs(plan, ir, continuation, event, PLANNER_COMPARE_OPTS)
    local expected = expectedJobPlanFromContinuation(continuation, event, ir)
    local actual = normalizeRuntimeJobPlan(job_plan)

    local fields = {
        "ok",
        "rejection_reason",
        "source_slot_id",
        "source_helper_engine_id",
        "planned_job_count",
        "kind_sequence",
        "slot_id_sequence",
        "helper_engine_id_sequence",
        "payload_slot_id_sequence",
        "depth_sequence",
        "fanout_count_sequence",
        "branch_kind_sequence",
        "branch_count_sequence",
        "pattern_kind_sequence",
        "pattern_count_sequence",
        "pattern_index_sequence",
        "trigger_source_slot_id_sequence",
        "timer_source_slot_id_sequence",
        "bounce_role_sequence",
        "chain_role_sequence",
        "source_event_bounce_role",
        "source_event_bounce_max",
    }
    if expected.ok == false and actual.ok == false then
        fields = {
            "ok",
            "rejection_reason",
        }
    end

    local ok = true
    for _, field in ipairs(fields) do
        local expected_value = runtimeJobFieldText(expected, field)
        local actual_value = runtimeJobFieldText(actual, field)
        if expected_value ~= actual_value then
            ok = false
            log.error(string.format(
                "SPELLFORGE_IR_RUNTIME_JOB_PLAN_DIFF label=%s field=%s legacy=%s ir=%s",
                tostring(label),
                tostring(field),
                expected_value,
                actual_value
            ))
        end
    end

    if ok and actual.ok == false then
        log.info(string.format(
            "SPELLFORGE_IR_RUNTIME_JOB_PLAN_DEFERRED label=%s reason=%s",
            tostring(label),
            tostring(actual.rejection_reason)
        ))
    elseif ok then
        log.info(string.format(
            "SPELLFORGE_IR_RUNTIME_JOB_PLAN_OK label=%s event=%s job_count=%s",
            tostring(label),
            tostring(event.event_kind),
            tostring(actual.planned_job_count)
        ))
    end
    assertLine(ok, "24 IR runtime job planner " .. label .. " matches continuation job expectations")
    if ok and actual.ok == false then
        return
    end
    if ok and string.find(label, "payload Speed Plus Size Plus", 1, true) then
        local job = job_plan and job_plan.planned_jobs and job_plan.planned_jobs[1] or nil
        local modifier_ok = job and job.payload_modifier_kind == "speed_plus_size_plus"
            and job.payload and job.payload.payload_modifier_kind == "speed_plus_size_plus"
            and job.speed_plus == true
            and job.size_plus == true
        if modifier_ok then
            log.info(string.format(
                "SPELLFORGE_IR_PAYLOAD_MODIFIER_JOB_PLAN_OK label=%s payload_modifier_kind=speed_plus_size_plus slot_id=%s",
                tostring(label),
                tostring(job.payload_slot_id)
            ))
        end
        assertLine(modifier_ok, "24 IR payload modifier job plan " .. label .. " applies Speed+ and Size+ policy")
    elseif ok and string.find(label, "payload Speed Plus", 1, true) then
        local job = job_plan and job_plan.planned_jobs and job_plan.planned_jobs[1] or nil
        local modifier_ok = job and job.payload_modifier_kind == "speed_plus"
            and job.payload and job.payload.payload_modifier_kind == "speed_plus"
            and job.speed_plus == true
        if modifier_ok then
            log.info(string.format(
                "SPELLFORGE_IR_PAYLOAD_MODIFIER_JOB_PLAN_OK label=%s payload_modifier_kind=speed_plus slot_id=%s",
                tostring(label),
                tostring(job.payload_slot_id)
            ))
        end
        assertLine(modifier_ok, "24 IR payload modifier job plan " .. label .. " applies Speed+ policy")
    elseif ok and string.find(label, "payload Size Plus", 1, true) then
        local job = job_plan and job_plan.planned_jobs and job_plan.planned_jobs[1] or nil
        local modifier_ok = job and job.payload_modifier_kind == "size_plus"
            and job.payload and job.payload.payload_modifier_kind == "size_plus"
            and job.size_plus == true
        if modifier_ok then
            log.info(string.format(
                "SPELLFORGE_IR_PAYLOAD_MODIFIER_JOB_PLAN_OK label=%s payload_modifier_kind=size_plus slot_id=%s",
                tostring(label),
                tostring(job.payload_slot_id)
            ))
        end
        assertLine(modifier_ok, "24 IR payload modifier job plan " .. label .. " applies Size+ policy")
    end
end

local function runtimeIrCase(label, effects, expected)
    local compiled = plan_cache.compileOrGet(effects)
    assertLine(compiled.ok == true, "21 runtime IR " .. label .. " compiles", issueDetail(compiled))
    if compiled.ok ~= true then
        return nil
    end

    local slots = plan_cache.attachEmissionSlots(compiled.recipe_id)
    assertLine(slots.ok == true, "21 runtime IR " .. label .. " attaches slots", issueDetail(slots))
    if slots.ok ~= true then
        return nil
    end

    local specs = plan_cache.attachHelperSpecs(compiled.recipe_id)
    assertLine(specs.ok == true, "21 runtime IR " .. label .. " attaches helper specs", issueDetail(specs))
    if specs.ok ~= true then
        return nil
    end

    local plan = specs.plan or slots.plan or compiled.plan
    local ir = runtime_ir.build(plan)
    assertLine(ir.ok == true, "21 runtime IR " .. label .. " builds", issueDetail(ir))
    if ir.ok ~= true then
        return nil
    end

    local invariants = runtime_ir.validateInvariants(ir, { require_helper_specs = true })
    assertLine(
        invariants.ok == true,
        "21 runtime IR " .. label .. " invariants pass",
        issueDetail(invariants)
    )

    local slot_count = #(plan.emission_slots or {})
    local helper_spec_count = #(plan.helper_specs or {})
    local counts = ir.counts or {}
    log.info(string.format(
        "SPELLFORGE_RUNTIME_IR_SUMMARY label=%s recipe_id=%s slots=%s entries=%s helper_specs=%s emit_groups=%s continuations=%s kinds=%s primary=%s payload=%s fanout=%s max_depth=%s",
        tostring(label),
        tostring(ir.recipe_id),
        tostring(counts.slot_count or 0),
        tostring(counts.entry_count or 0),
        tostring(counts.helper_spec_count or 0),
        tostring(counts.emit_group_count or 0),
        tostring(counts.continuation_count or 0),
        runtime_ir.kindSummary(counts),
        tostring(counts.primary_emit_count or 0),
        tostring(counts.payload_emit_count or 0),
        tostring(counts.fanout_entry_count or 0),
        tostring(counts.max_payload_depth or 0)
    ))

    local legacy_matrix = feature_matrix.legacyAnalyze(plan)
    local public_matrix = feature_matrix.analyze(plan)
    local ir_matrix = feature_matrix_ir.analyzeFromIr(ir)
    compareFeatureMatrix("legacy " .. label, legacy_matrix, ir_matrix)
    compareFeatureMatrix("public " .. label, public_matrix, ir_matrix)
    compareContinuationPlan(label, plan, ir)
    compareRuntimeJobPlan(label, plan, ir)

    assertLine(
        counts.slot_count == slot_count and counts.entry_count == slot_count,
        "21 runtime IR " .. label .. " mirrors slot count",
        string.format("ir_slots=%s entries=%s plan_slots=%s", tostring(counts.slot_count), tostring(counts.entry_count), tostring(slot_count))
    )
    assertLine(
        counts.helper_spec_count == helper_spec_count,
        "21 runtime IR " .. label .. " mirrors helper specs",
        string.format("ir_specs=%s plan_specs=%s", tostring(counts.helper_spec_count), tostring(helper_spec_count))
    )

    local want = expected or {}
    if want.no_continuations == true then
        assertLine((counts.continuation_count or 0) == 0, "21 runtime IR " .. label .. " has no continuations", "continuations=" .. tostring(counts.continuation_count))
    end
    for kind, min_count in pairs(want.continuations or {}) do
        assertLine(
            irKindCount(ir, kind) >= min_count,
            "21 runtime IR " .. label .. " has " .. kind .. " continuation",
            string.format("kind_count=%s min=%s", tostring(irKindCount(ir, kind)), tostring(min_count))
        )
    end
    if want.min_payload_depth then
        assertLine((counts.max_payload_depth or 0) >= want.min_payload_depth, "21 runtime IR " .. label .. " keeps payload depth", "depth=" .. tostring(counts.max_payload_depth))
    end
    if want.min_payload_entries then
        assertLine((counts.payload_emit_count or 0) >= want.min_payload_entries, "21 runtime IR " .. label .. " keeps payload entries", "payload=" .. tostring(counts.payload_emit_count))
    end
    if want.min_fanout_entries then
        assertLine((counts.fanout_entry_count or 0) >= want.min_fanout_entries, "21 runtime IR " .. label .. " keeps fanout entries", "fanout=" .. tostring(counts.fanout_entry_count))
    end

    return ir
end

local function run()
    if not dev.smokeTestsEnabled() then
        return
    end
    plan_cache.clearForTests()

    local fire_target = {
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    }

    local first = plan_cache.compileOrGet(fire_target)
    local recipe_id = first and first.recipe_id

    assertLine(first.ok == true and first.reused == false, "1 compile new plan")
    assertLine(isNonEmptyString(recipe_id), "1 recipe_id is non-empty")
    assertLine(first.plan and first.plan.bounds and first.plan.bounds.group_count == 1, "1 group_count is 1")
    assertLine(plan_cache.has(recipe_id), "1 plan exists in cache")

    local second = plan_cache.compileOrGet(fire_target)
    assertLine(second.ok == true and second.reused == true, "2 recompile same plan reused")
    assertLine(second.recipe_id == recipe_id, "2 recipe_id stable across recompiles")

    local changed_magnitude = {
        { id = "firedamage", range = 2, magnitudeMin = 11, magnitudeMax = 11, area = 0, duration = 1 },
    }
    local third = plan_cache.compileOrGet(changed_magnitude)
    assertLine(third.ok == true and third.reused == false, "3 changed magnitude compiles new plan")
    assertLine(third.recipe_id ~= recipe_id, "3 changed magnitude yields different recipe_id")

    local invalid = {
        { id = "spellforge_trigger" },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    }
    local invalid_result = plan_cache.compileOrGet(invalid)
    assertLine(invalid_result.ok == false, "4 parser failure returns ok=false")
    assertLine(type(invalid_result.errors) == "table" and #invalid_result.errors > 0, "4 parser failure has readable errors")
    assertLine(plan_cache.has(invalid_result.recipe_id) == false, "4 parser failure not cached as success")

    local multicast = {
        { id = "spellforge_multicast", params = { count = 3 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    }
    local multicast_result = plan_cache.compileOrGet(multicast)
    local multicast_bounds = multicast_result.plan and multicast_result.plan.bounds or {}
    assertLine(multicast_result.ok == true, "5 multicast compile succeeds")
    assertLine(multicast_bounds.has_multicast == true, "5 multicast summary has_multicast=true")
    assertLine(multicast_bounds.static_emission_count == 3, "5 multicast summary static_emission_count=3")

    local trigger = {
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
        { id = "spellforge_trigger" },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    }
    local trigger_result = plan_cache.compileOrGet(trigger)
    local trigger_bounds = trigger_result.plan and trigger_result.plan.bounds or {}
    local trigger_group = trigger_result.plan and trigger_result.plan.groups and trigger_result.plan.groups[1]
    assertLine(trigger_result.ok == true, "6 trigger compile succeeds")
    assertLine(trigger_bounds.has_trigger == true, "6 trigger summary has_trigger=true")
    assertLine(trigger_group and trigger_group.payload and type(trigger_group.payload.effects) == "table", "6 trigger payload metadata stored")

    local pattern = {
        { id = "spellforge_burst", params = { count = 5 } },
        { id = "spellforge_multicast", params = { count = 5 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    }
    local pattern_result = plan_cache.compileOrGet(pattern)
    local pattern_bounds = pattern_result.plan and pattern_result.plan.bounds or {}
    assertLine(pattern_result.ok == true, "7 pattern compile succeeds")
    assertLine(pattern_bounds.has_pattern == true, "7 pattern summary has_pattern=true")
    assertLine(pattern_bounds.has_multicast == true, "7 pattern summary has_multicast=true")

    plan_cache.clearForTests()
    assertLine(plan_cache.has(recipe_id) == false, "8 cache clear for tests")

    local normalized_recipe = recipe_model.normalize({
        title = "Smoke UI Recipe",
        effects = fire_target,
    })
    assertLine(normalized_recipe.ok == true, "9 ui recipe normalize succeeds")
    assertLine(normalized_recipe.recipe and normalized_recipe.recipe.schema_version == recipe_model.SCHEMA_VERSION, "9 ui recipe schema_version set")
    assertLine(normalized_recipe.effects and normalized_recipe.effects[1] and isNonEmptyString(normalized_recipe.effects[1].ui_id), "9 ui recipe assigns ui_id")

    local validate_result = ui_contract.validateRecipe({
        request_id = "smoke-ui-validate",
        recipe = normalized_recipe.recipe,
    })
    assertLine(validate_result.ok == true and validate_result.validation and validate_result.validation.ok == true, "10 ui validate succeeds")
    assertLine(isNonEmptyString(validate_result.recipe_id), "10 ui validate returns recipe_id")
    assertLine(validate_result.schema_version == recipe_model.SCHEMA_VERSION, "10 ui validate returns schema_version")

    local invalid_ui = ui_contract.validateRecipe({
        request_id = "smoke-ui-invalid",
        recipe = {
            effects = invalid,
        },
    })
    local invalid_issue = invalid_ui.errors and invalid_ui.errors[1]
    assertLine(invalid_ui.ok == false, "11 ui validate invalid recipe fails")
    assertLine(invalid_issue and isNonEmptyString(invalid_issue.code), "11 ui validate error has code")
    assertLine(invalid_issue and invalid_issue.severity == "error", "11 ui validate error has severity")
    assertLine(invalid_issue and isNonEmptyString(invalid_issue.path), "11 ui validate error has path")

    local preview_result = ui_contract.previewRecipe({
        request_id = "smoke-ui-preview",
        recipe = {
            title = "Smoke Trigger Preview",
            effects = trigger,
        },
    })
    local preview = preview_result.preview or {}
    assertLine(preview_result.ok == true, "12 ui preview succeeds")
    assertLine(preview.bounds and preview.bounds.has_trigger == true, "12 ui preview keeps trigger bounds")
    assertLine((preview.slot_count or 0) >= 2, "12 ui preview plans trigger payload slots")
    assertLine(preview.helper_spec_count == preview.slot_count, "12 ui preview helper specs match slots")
    assertLine(preview.materializes_records == false and preview.created_runtime_records == false, "12 ui preview does not materialize records")
    assertLine(preview.feature_matrix and preview.feature_matrix.version == "spellforge-feature-matrix-v1", "13 ui preview returns feature matrix")
    assertLine(containsValue(preview.feature_matrix and preview.feature_matrix.active_feature_ids, "trigger"), "13 ui feature matrix detects Trigger")
    assertLine(containsValue(preview.feature_matrix and preview.feature_matrix.required_flags, "SpellforgeDev.enable_live_trigger"), "13 ui feature matrix lists Trigger gate")

    local bounce_timer = {
        { id = "spellforge_bounce", params = { bounces = 3 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
        { id = "spellforge_timer", params = { seconds = 1.0 } },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    }
    local bounce_timer_preview = ui_contract.previewRecipe({
        request_id = "smoke-ui-feature-matrix-deferred",
        recipe = {
            title = "Smoke Bounce Timer Preview",
            effects = bounce_timer,
        },
    })
    local bounce_timer_matrix = bounce_timer_preview.preview and bounce_timer_preview.preview.feature_matrix or {}
    assertLine(bounce_timer_preview.ok == true, "14 ui feature matrix preview accepts deferred combo")
    assertLine(bounce_timer_matrix.live_runtime_status == "deferred", "14 ui feature matrix marks Bounce+Timer deferred")
    assertLine(containsValue(bounce_timer_matrix.deferred_reasons, "bounce_timer_deferred"), "14 ui feature matrix gives Bounce+Timer reason")

    local bounce_trigger_multicast = {
        { id = "spellforge_bounce", params = { bounces = 5 } },
        { id = "firedamage", range = 2, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 1 },
        { id = "spellforge_trigger" },
        { id = "spellforge_multicast", params = { count = 8 } },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    }
    local bounce_trigger_multicast_preview = ui_contract.previewRecipe({
        request_id = "smoke-ui-bounce-trigger-multicast-supported",
        recipe = {
            title = "Smoke Bounce Trigger Multicast Preview",
            effects = bounce_trigger_multicast,
        },
    })
    local bounce_trigger_multicast_result = bounce_trigger_multicast_preview.preview or {}
    local bounce_trigger_multicast_matrix = bounce_trigger_multicast_result.feature_matrix or {}
    assertLine(bounce_trigger_multicast_preview.ok == true, "14b ui feature matrix preview accepts Bounce Trigger payload Multicast")
    assertLine(bounce_trigger_multicast_result.slot_count == 9, "14b ui preview plans Bounce Trigger payload Multicast slots")
    assertLine(bounce_trigger_multicast_matrix.live_runtime_status == "feature_gated", "14b ui feature matrix marks Bounce Trigger payload Multicast feature-gated")
    assertLine(containsValue(bounce_trigger_multicast_matrix.active_feature_ids, "payload_multicast"), "14b ui feature matrix detects Bounce Trigger payload Multicast")
    assertLine(containsValue(bounce_trigger_multicast_matrix.required_flags, "SpellforgeDev.enable_live_payload_multicast_v0"), "14b ui feature matrix lists payload Multicast gate")
    assertLine(not containsValue(bounce_trigger_multicast_matrix.required_flags, "SpellforgeDev.enable_live_multicast"), "14b ui feature matrix does not require primary Multicast gate for payload Multicast")
    assertLine(not containsValue(bounce_trigger_multicast_matrix.deferred_reasons, "bounce_trigger_payload_deferred"), "14b ui feature matrix does not defer Bounce Trigger payload Multicast")

    local bounce_trigger_chain = {
        { id = "spellforge_bounce", params = { bounces = 3 } },
        { id = "firedamage", range = 2, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 1 },
        { id = "spellforge_trigger" },
        { id = "spellforge_chain", params = { hops = 3 } },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    }
    local bounce_trigger_chain_preview = ui_contract.previewRecipe({
        request_id = "smoke-ui-bounce-trigger-chain-supported",
        recipe = {
            title = "Smoke Bounce Trigger Chain Preview",
            effects = bounce_trigger_chain,
        },
    })
    local bounce_trigger_chain_matrix = bounce_trigger_chain_preview.preview and bounce_trigger_chain_preview.preview.feature_matrix or {}
    assertLine(bounce_trigger_chain_preview.ok == true, "14c ui feature matrix preview accepts Bounce Trigger Chain")
    assertLine(bounce_trigger_chain_matrix.live_runtime_status == "feature_gated", "14c ui feature matrix marks Bounce Trigger Chain feature-gated")
    assertLine(containsValue(bounce_trigger_chain_matrix.active_feature_ids, "bounce"), "14c ui feature matrix detects Bounce for Trigger Chain")
    assertLine(containsValue(bounce_trigger_chain_matrix.active_feature_ids, "chain"), "14c ui feature matrix detects Chain for Bounce Trigger Chain")
    assertLine(containsValue(bounce_trigger_chain_matrix.combos, "bounce_trigger_chain"), "14c ui feature matrix reports Bounce Trigger Chain combo")
    assertLine(containsValue(bounce_trigger_chain_matrix.required_flags, "SpellforgeDev.enable_live_bounce_v0"), "14c ui feature matrix lists Bounce gate")
    assertLine(containsValue(bounce_trigger_chain_matrix.required_flags, "SpellforgeDev.enable_live_trigger"), "14c ui feature matrix lists Trigger gate")
    assertLine(containsValue(bounce_trigger_chain_matrix.required_flags, "SpellforgeDev.enable_live_chain_runtime_v0"), "14c ui feature matrix lists Chain runtime gate")
    assertLine(not containsValue(bounce_trigger_chain_matrix.required_flags, "SpellforgeDev.enable_live_chain_multicast_v0"), "14c ui feature matrix does not require Chain Multicast gate")
    assertLine(not containsValue(bounce_trigger_chain_matrix.deferred_reasons, "bounce_chain_deferred"), "14c ui feature matrix does not defer narrow Bounce Trigger Chain")

    local bounce_trigger_burst = {
        { id = "spellforge_bounce", params = { bounces = 3 } },
        { id = "firedamage", range = 2, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 1 },
        { id = "spellforge_trigger" },
        { id = "spellforge_burst", params = { count = 5 } },
        { id = "spellforge_multicast", params = { count = 5 } },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    }
    local bounce_trigger_burst_preview = ui_contract.previewRecipe({
        request_id = "smoke-ui-bounce-trigger-pattern-supported",
        recipe = {
            title = "Smoke Bounce Trigger Pattern Preview",
            effects = bounce_trigger_burst,
        },
    })
    local bounce_trigger_burst_matrix = bounce_trigger_burst_preview.preview and bounce_trigger_burst_preview.preview.feature_matrix or {}
    assertLine(bounce_trigger_burst_preview.ok == true, "14d ui feature matrix preview accepts Bounce Trigger Burst")
    assertLine(bounce_trigger_burst_matrix.live_runtime_status == "feature_gated", "14d ui feature matrix marks Bounce Trigger Burst feature-gated")
    assertLine(containsValue(bounce_trigger_burst_matrix.active_feature_ids, "payload_multicast"), "14d ui feature matrix detects payload Multicast for Bounce Trigger Burst")
    assertLine(containsValue(bounce_trigger_burst_matrix.active_feature_ids, "payload_pattern"), "14d ui feature matrix detects payload Pattern for Bounce Trigger Burst")
    assertLine(containsValue(bounce_trigger_burst_matrix.combos, "bounce_trigger_payload_pattern"), "14d ui feature matrix reports Bounce Trigger payload Pattern combo")
    assertLine(containsValue(bounce_trigger_burst_matrix.required_flags, "SpellforgeDev.enable_live_payload_multicast_v0"), "14d ui feature matrix lists payload Multicast gate")
    assertLine(containsValue(bounce_trigger_burst_matrix.required_flags, "SpellforgeDev.enable_live_payload_pattern_v0"), "14d ui feature matrix lists payload Pattern gate")
    assertLine(not containsValue(bounce_trigger_burst_matrix.required_flags, "SpellforgeDev.enable_live_multicast"), "14d ui feature matrix does not require primary Multicast gate for payload Pattern")
    assertLine(not containsValue(bounce_trigger_burst_matrix.required_flags, "SpellforgeDev.enable_live_spread_burst"), "14d ui feature matrix does not require primary Spread/Burst gate for payload Pattern")

    local bounce_direct_chain = {
        { id = "spellforge_bounce", params = { bounces = 3 } },
        { id = "firedamage", range = 2, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 1 },
        { id = "spellforge_chain", params = { hops = 3 } },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    }
    local bounce_direct_chain_preview = ui_contract.previewRecipe({
        request_id = "smoke-ui-bounce-direct-chain-deferred",
        recipe = {
            title = "Smoke Bounce Direct Chain Preview",
            effects = bounce_direct_chain,
        },
    })
    local bounce_direct_chain_matrix = bounce_direct_chain_preview.preview and bounce_direct_chain_preview.preview.feature_matrix or {}
    assertLine(bounce_direct_chain_preview.ok == true, "14e ui feature matrix preview accepts direct Bounce Chain")
    assertLine(bounce_direct_chain_matrix.live_runtime_status == "deferred", "14e ui feature matrix marks direct Bounce Chain deferred")
    assertLine(containsValue(bounce_direct_chain_matrix.deferred_reasons, "bounce_chain_deferred"), "14e ui feature matrix gives direct Bounce Chain reason")

    local bounce_homing = {
        { id = "spellforge_bounce", params = { bounces = 3 } },
        { id = "spellforge_homing" },
        { id = "firedamage", range = 2, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 1 },
    }
    local bounce_homing_preview = ui_contract.previewRecipe({
        request_id = "smoke-ui-bounce-homing-deferred",
        recipe = {
            title = "Smoke Bounce Homing Preview",
            effects = bounce_homing,
        },
    })
    local bounce_homing_matrix = bounce_homing_preview.preview and bounce_homing_preview.preview.feature_matrix or {}
    assertLine(bounce_homing_preview.ok == true, "14f ui feature matrix preview accepts Bounce Homing")
    assertLine(bounce_homing_matrix.live_runtime_status == "deferred", "14f ui feature matrix marks Bounce Homing deferred")
    assertLine(containsValue(bounce_homing_matrix.deferred_reasons, "bounce_homing_deferred"), "14f ui feature matrix gives Bounce Homing reason")

    local bounce_speed_plus = {
        { id = "spellforge_bounce", params = { bounces = 3 } },
        { id = "spellforge_speed_plus", params = { percent = 50 } },
        { id = "firedamage", range = 2, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 1 },
    }
    local bounce_speed_plus_preview = ui_contract.previewRecipe({
        request_id = "smoke-ui-bounce-speed-plus-source-policy",
        recipe = {
            title = "Smoke Bounce Speed Plus Preview",
            effects = bounce_speed_plus,
        },
    })
    local bounce_speed_plus_matrix = bounce_speed_plus_preview.preview and bounce_speed_plus_preview.preview.feature_matrix or {}
    assertLine(bounce_speed_plus_preview.ok == true, "14g ui feature matrix preview accepts Bounce Speed+")
    assertLine(bounce_speed_plus_matrix.live_runtime_status == "feature_gated", "14g ui feature matrix marks Bounce Speed+ feature-gated")
    assertLine(not containsValue(bounce_speed_plus_matrix.deferred_reasons, "bounce_modifier_deferred"), "14g ui feature matrix does not use event-specific Bounce modifier reason")

    local bounce_speed_size_plus = {
        { id = "spellforge_bounce", params = { bounces = 3 } },
        { id = "spellforge_speed_plus", params = { percent = 50 } },
        { id = "spellforge_size_plus", params = { percent = 125 } },
        { id = "firedamage", range = 2, magnitudeMin = 1, magnitudeMax = 1, area = 10, duration = 1 },
    }
    local bounce_speed_size_preview = ui_contract.previewRecipe({
        request_id = "smoke-ui-bounce-speed-size-plus-deferred",
        recipe = {
            title = "Smoke Bounce Speed Size Plus Preview",
            effects = bounce_speed_size_plus,
        },
    })
    local bounce_speed_size_matrix = bounce_speed_size_preview.preview and bounce_speed_size_preview.preview.feature_matrix or {}
    assertLine(bounce_speed_size_preview.ok == true, "14h ui feature matrix preview accepts Bounce Speed+ Size+")
    assertLine(bounce_speed_size_matrix.live_runtime_status == "deferred", "14h ui feature matrix marks Bounce Speed+ Size+ deferred")
    assertLine(containsValue(bounce_speed_size_matrix.deferred_reasons, "source_modifier_combo_deferred"), "14h ui feature matrix gives source modifier combo reason")

    local bounce_nested_payload = {
        { id = "spellforge_bounce", params = { bounces = 3 } },
        { id = "firedamage", range = 2, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 1 },
        { id = "spellforge_trigger" },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
        { id = "spellforge_trigger" },
        { id = "shockdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    }
    local bounce_nested_payload_preview = ui_contract.previewRecipe({
        request_id = "smoke-ui-bounce-nested-payload-deferred",
        recipe = {
            title = "Smoke Bounce Nested Payload Preview",
            effects = bounce_nested_payload,
        },
    })
    local bounce_nested_payload_matrix = bounce_nested_payload_preview.preview and bounce_nested_payload_preview.preview.feature_matrix or {}
    assertLine(bounce_nested_payload_preview.ok == true, "14h.1 ui feature matrix preview accepts Bounce nested payload")
    assertLine(bounce_nested_payload_matrix.live_runtime_status == "deferred", "14h.1 ui feature matrix marks Bounce nested payload deferred")
    assertLine(containsValue(bounce_nested_payload_matrix.deferred_reasons, "nested_payload_runtime_deferred"), "14h.1 ui feature matrix gives Bounce nested payload reason")

    local pierce_timer = {
        { id = "spellforge_pierce", params = { pierces = 3 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
        { id = "spellforge_timer", params = { seconds = 1.0 } },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    }
    local pierce_timer_preview = ui_contract.previewRecipe({
        request_id = "smoke-ui-pierce-timer-deferred",
        recipe = {
            title = "Smoke Pierce Timer Preview",
            effects = pierce_timer,
        },
    })
    local pierce_timer_matrix = pierce_timer_preview.preview and pierce_timer_preview.preview.feature_matrix or {}
    assertLine(pierce_timer_preview.ok == true, "14i ui feature matrix preview accepts Pierce Timer")
    assertLine(pierce_timer_matrix.live_runtime_status == "deferred", "14i ui feature matrix marks Pierce Timer deferred")
    assertLine(containsValue(pierce_timer_matrix.deferred_reasons, "pierce_timer_deferred"), "14i ui feature matrix gives Pierce Timer reason")

    local pierce_speed_plus_preview = ui_contract.previewRecipe({
        request_id = "smoke-ui-pierce-speed-plus-source-policy",
        recipe = {
            title = "Smoke Pierce Speed Plus Preview",
            effects = {
                { id = "spellforge_pierce", params = { pierces = 3 } },
                { id = "spellforge_speed_plus", params = { percent = 50 } },
                { id = "firedamage", range = 2, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 1 },
            },
        },
    })
    local pierce_speed_plus_matrix = pierce_speed_plus_preview.preview and pierce_speed_plus_preview.preview.feature_matrix or {}
    assertLine(pierce_speed_plus_preview.ok == true, "14i.1 ui feature matrix preview accepts Pierce Speed+")
    assertLine(pierce_speed_plus_matrix.live_runtime_status == "feature_gated", "14i.1 ui feature matrix marks Pierce Speed+ feature-gated")
    assertLine(not containsValue(pierce_speed_plus_matrix.deferred_reasons, "pierce_modifier_deferred"), "14i.1 ui feature matrix does not use event-specific Pierce modifier reason")

    local pierce_size_plus_preview = ui_contract.previewRecipe({
        request_id = "smoke-ui-pierce-size-plus-source-policy",
        recipe = {
            title = "Smoke Pierce Size Plus Preview",
            effects = {
                { id = "spellforge_pierce", params = { pierces = 3 } },
                { id = "spellforge_size_plus", params = { percent = 125 } },
                { id = "firedamage", range = 2, magnitudeMin = 1, magnitudeMax = 1, area = 10, duration = 1 },
            },
        },
    })
    local pierce_size_plus_matrix = pierce_size_plus_preview.preview and pierce_size_plus_preview.preview.feature_matrix or {}
    assertLine(pierce_size_plus_preview.ok == true, "14i.2 ui feature matrix preview accepts Pierce Size+")
    assertLine(pierce_size_plus_matrix.live_runtime_status == "feature_gated", "14i.2 ui feature matrix marks Pierce Size+ feature-gated")
    assertLine(not containsValue(pierce_size_plus_matrix.deferred_reasons, "pierce_modifier_deferred"), "14i.2 ui feature matrix does not use event-specific Pierce modifier reason")

    local pierce_trigger_chain = {
        { id = "spellforge_pierce", params = { pierces = 3 } },
        { id = "firedamage", range = 2, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 1 },
        { id = "spellforge_trigger" },
        { id = "spellforge_chain", params = { hops = 3 } },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    }
    local pierce_trigger_chain_preview = ui_contract.previewRecipe({
        request_id = "smoke-ui-pierce-trigger-chain-supported",
        recipe = {
            title = "Smoke Pierce Trigger Chain Preview",
            effects = pierce_trigger_chain,
        },
    })
    local pierce_trigger_chain_matrix = pierce_trigger_chain_preview.preview and pierce_trigger_chain_preview.preview.feature_matrix or {}
    assertLine(pierce_trigger_chain_preview.ok == true, "14j ui feature matrix preview accepts Pierce Trigger Chain")
    assertLine(pierce_trigger_chain_matrix.live_runtime_status == "feature_gated", "14j ui feature matrix marks Pierce Trigger Chain feature-gated")
    assertLine(containsValue(pierce_trigger_chain_matrix.active_feature_ids, "pierce"), "14j ui feature matrix detects Pierce")
    assertLine(containsValue(pierce_trigger_chain_matrix.combos, "pierce_trigger_chain"), "14j ui feature matrix reports Pierce Trigger Chain combo")
    assertLine(containsValue(pierce_trigger_chain_matrix.required_flags, "SpellforgeDev.enable_live_pierce_v0"), "14j ui feature matrix lists Pierce gate")
    assertLine(containsValue(pierce_trigger_chain_matrix.required_flags, "SpellforgeDev.enable_live_trigger"), "14j ui feature matrix lists Trigger gate")
    assertLine(containsValue(pierce_trigger_chain_matrix.required_flags, "SpellforgeDev.enable_live_chain_runtime_v0"), "14j ui feature matrix lists Chain runtime gate")

    local chain_speed_multicast = {
        { id = "firedamage", range = 2, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 1 },
        { id = "spellforge_chain", params = { hops = 3 } },
        { id = "spellforge_speed_plus", params = { percent = 50 } },
        { id = "spellforge_multicast", params = { count = 3 } },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    }
    local chain_speed_multicast_preview = ui_contract.previewRecipe({
        request_id = "smoke-ui-chain-speed-multicast-supported",
        recipe = {
            title = "Smoke Chain Speed Multicast Preview",
            effects = chain_speed_multicast,
        },
    })
    local chain_speed_multicast_matrix = chain_speed_multicast_preview.preview and chain_speed_multicast_preview.preview.feature_matrix or {}
    assertLine(chain_speed_multicast_preview.ok == true, "14k ui feature matrix preview accepts Chain Speed+ Multicast")
    assertLine(chain_speed_multicast_matrix.live_runtime_status == "feature_gated", "14k ui feature matrix marks Chain Speed+ Multicast feature-gated")
    assertLine(containsValue(chain_speed_multicast_matrix.active_feature_ids, "chain"), "14k ui feature matrix detects Chain")
    assertLine(containsValue(chain_speed_multicast_matrix.active_feature_ids, "chain_multicast"), "14k ui feature matrix detects Chain Multicast")
    assertLine(containsValue(chain_speed_multicast_matrix.active_feature_ids, "speed_plus"), "14k ui feature matrix detects Speed+")
    assertLine(containsValue(chain_speed_multicast_matrix.required_flags, "SpellforgeDev.enable_live_chain_runtime_v0"), "14k ui feature matrix lists Chain runtime gate")
    assertLine(containsValue(chain_speed_multicast_matrix.required_flags, "SpellforgeDev.enable_live_chain_multicast_v0"), "14k ui feature matrix lists Chain Multicast gate")
    assertLine(containsValue(chain_speed_multicast_matrix.required_flags, "SpellforgeDev.enable_live_speed_plus"), "14k ui feature matrix lists Speed+ gate")
    assertLine(not containsValue(chain_speed_multicast_matrix.deferred_reasons, "chain_modifier_combo_deferred"), "14k ui feature matrix does not defer single Chain Speed+ Multicast")

    local chain_speed_size_multicast = {
        { id = "firedamage", range = 2, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 1 },
        { id = "spellforge_chain", params = { hops = 3 } },
        { id = "spellforge_speed_plus", params = { percent = 50 } },
        { id = "spellforge_size_plus", params = { percent = 125 } },
        { id = "spellforge_multicast", params = { count = 3 } },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    }
    local chain_speed_size_multicast_preview = ui_contract.previewRecipe({
        request_id = "smoke-ui-chain-speed-size-multicast-deferred",
        recipe = {
            title = "Smoke Chain Speed Size Multicast Preview",
            effects = chain_speed_size_multicast,
        },
    })
    local chain_speed_size_multicast_matrix = chain_speed_size_multicast_preview.preview and chain_speed_size_multicast_preview.preview.feature_matrix or {}
    assertLine(chain_speed_size_multicast_preview.ok == true, "14l ui feature matrix preview accepts Chain Speed+ Size+ Multicast")
    assertLine(chain_speed_size_multicast_matrix.live_runtime_status == "deferred", "14l ui feature matrix marks Chain Speed+ Size+ Multicast deferred")
    assertLine(containsValue(chain_speed_size_multicast_matrix.deferred_reasons, "chain_modifier_combo_deferred"), "14l ui feature matrix gives Chain modifier combo reason")

    local catalog = ui_catalog.build({ request_id = "smoke-ui-catalog" })
    assertLine(catalog.ok == true, "15 ui catalog succeeds")
    assertLine(catalog.catalog_version == "spellforge-ui-catalog-v1", "15 ui catalog version set")
    assertLine(catalog.schema_version == recipe_model.SCHEMA_VERSION, "15 ui catalog schema_version set")
    assertLine(catalog.operator_count == 11, "15 ui catalog operator_count=11")
    assertLine(catalog.operators_by_opcode and catalog.operators_by_opcode.Multicast and catalog.operators_by_opcode.Multicast.parameters.count.max ~= nil, "15 ui catalog exposes Multicast parameters")
    assertLine(catalog.operator_opcode_by_effect_id and catalog.operator_opcode_by_effect_id.spellforge_trigger == "Trigger", "15 ui catalog maps Trigger effect id")
    assertLine(catalog.feature_matrix and catalog.feature_matrix.version == "spellforge-feature-matrix-v1", "15 ui catalog includes feature matrix catalog")
    assertLine(catalog.events and catalog.events.preview_recipe == "Spellforge_PreviewRecipe", "15 ui catalog includes preview event name")
    assertLine(catalog.defaults and catalog.defaults.preview_launches_projectiles == false, "15 ui catalog marks preview dry-run")
    assertLine(containsValue(catalog.recipe_model and catalog.recipe_model.effect_fields, operator_params.encodedFieldName("count")), "15 ui catalog exposes scalar count param field")
    assertLine(containsValue(catalog.recipe_model and catalog.recipe_model.effect_fields, operator_params.encodedFieldName("seconds")), "15 ui catalog exposes scalar seconds param field")
    assertLine(catalog.support_truth and catalog.support_truth.bounce_v0 and containsValue(catalog.support_truth.bounce_v0.observed_surfaces, "exterior wall/static"), "15 ui catalog records Bounce exterior surface support")
    assertLine(catalog.support_truth and catalog.support_truth.bounce_v0 and containsValue(catalog.support_truth.bounce_v0.supported_shapes, "Bounce N -> target emitter -> Trigger -> Chain N -> simple payload"), "15 ui catalog records Bounce Trigger Chain support")

    local saved_result = saved_recipe_model.create({
        id = "saved-smoke-1",
        title = "Saved Smoke",
        recipe = {
            effects = fire_target,
        },
    }, { now = 1000 })
    local saved_recipe = saved_result.saved_recipe or {}
    assertLine(saved_result.ok == true, "16 saved recipe create succeeds")
    assertLine(saved_recipe.schema_version == saved_recipe_model.SCHEMA_VERSION, "16 saved recipe schema_version set")
    assertLine(saved_recipe.title == "Saved Smoke", "16 saved recipe title preserved")
    assertLine(saved_recipe.recipe and saved_recipe.recipe.effects and isNonEmptyString(saved_recipe.recipe.effects[1].ui_id), "16 saved recipe effect ui_id assigned")

    local unsupported_saved = saved_recipe_model.create({
        id = "saved-smoke-bad-version",
        schema_version = "spellforge-saved-recipe-v0",
        recipe = {
            effects = fire_target,
        },
    })
    local unsupported_issue = unsupported_saved.errors and unsupported_saved.errors[1]
    assertLine(unsupported_saved.ok == false, "16 saved recipe unsupported version fails")
    assertLine(unsupported_issue and unsupported_issue.code == "unsupported_saved_recipe_schema_version", "16 saved recipe unsupported version has code")

    local timer_burst_payload = {
        { id = "firedamage", range = 2, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 1 },
        { id = "spellforge_timer", params = { seconds = 1.0 } },
        { id = "spellforge_multicast", params = { count = 8 } },
        { id = "spellforge_burst", params = { count = 8 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    }
    local timer_burst_preview = ui_contract.previewRecipe({
        request_id = "smoke-ui-timer-burst-payload",
        recipe = {
            title = "Smoke Timer Burst Payload",
            effects = timer_burst_payload,
        },
    })
    local timer_burst = timer_burst_preview.preview or {}
    local timer_burst_matrix = timer_burst.feature_matrix or {}
    assertLine(timer_burst_preview.ok == true, "17 ui preview Timer payload Burst succeeds")
    assertLine(timer_burst.bounds and timer_burst.bounds.has_timer == true, "17 ui preview Timer payload Burst keeps Timer bounds")
    assertLine(timer_burst.slot_count == 9 and timer_burst.helper_spec_count == 9, "17 ui preview Timer payload Burst plans eight payload slots")
    assertLine(containsValue(timer_burst_matrix.active_feature_ids, "timer"), "17 ui feature matrix detects Timer payload Burst timer")
    assertLine(containsValue(timer_burst_matrix.active_feature_ids, "payload_pattern"), "17 ui feature matrix detects Timer payload Burst pattern")

    local event_safe_timer_burst_payload = {
        { id = "firedamage", range = 2, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 1 },
        { id = "spellforge_timer", spellforge_param_seconds = 1.0 },
        { id = "spellforge_multicast", spellforge_param_count = 8 },
        { id = "spellforge_burst", spellforge_param_count = 8 },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    }
    local event_safe_preview = ui_contract.previewRecipe({
        request_id = "smoke-ui-timer-burst-event-safe-payload",
        recipe = {
            title = "Smoke Timer Burst Event Safe Payload",
            effects = event_safe_timer_burst_payload,
        },
    })
    local event_safe = event_safe_preview.preview or {}
    assertLine(event_safe_preview.ok == true, "18 ui preview event-safe Timer payload Burst succeeds")
    assertLine(event_safe.slot_count == 9 and event_safe.helper_spec_count == 9, "18 ui preview event-safe Timer payload Burst keeps scalar params")
    assertLine(event_safe_preview.effects and event_safe_preview.effects[3] and event_safe_preview.effects[3].params and event_safe_preview.effects[3].params.count == 8, "18 ui preview event-safe Multicast restores params")
    assertLine(event_safe_preview.effects and event_safe_preview.effects[4] and event_safe_preview.effects[4].params and event_safe_preview.effects[4].params.count == 8, "18 ui preview event-safe Burst restores params")

    local event_safe_all_params = {
        { id = "spellforge_speed_plus", spellforge_param_percent = "75" },
        { id = "spellforge_size_plus", spellforge_param_percent = "125" },
        { id = "spellforge_chain", spellforge_param_hops = "2" },
        { id = "spellforge_bounce", spellforge_param_bounces = "2" },
        { id = "spellforge_multicast", spellforge_param_count = "4" },
        { id = "spellforge_spread", spellforge_param_preset = "2" },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
        { id = "spellforge_timer", spellforge_param_seconds = "1.5" },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    }
    local event_safe_all = ui_contract.validateRecipe({
        request_id = "smoke-ui-event-safe-all-operator-params",
        recipe = {
            title = "Smoke Event Safe Operator Params",
            effects = event_safe_all_params,
        },
    })
    local event_safe_all_group = event_safe_all.groups and event_safe_all.groups[1] or {}
    local event_safe_speed = findOp(event_safe_all_group.prefix_ops, "Speed+")
    local event_safe_size = findOp(event_safe_all_group.prefix_ops, "Size+")
    local event_safe_chain = findOp(event_safe_all_group.prefix_ops, "Chain")
    local event_safe_bounce = findOp(event_safe_all_group.prefix_ops, "Bounce")
    local event_safe_multicast = findOp(event_safe_all_group.prefix_ops, "Multicast")
    local event_safe_spread = findOp(event_safe_all_group.prefix_ops, "Spread")
    local event_safe_timer = findOp(event_safe_all_group.postfix_ops, "Timer")
    assertLine(event_safe_all.ok == true, "19 ui validate event-safe all operator params succeeds")
    assertLine(event_safe_speed and event_safe_speed.params and event_safe_speed.params.percent == 75, "19 event-safe Speed+ percent restored")
    assertLine(event_safe_size and event_safe_size.params and event_safe_size.params.percent == 125, "19 event-safe Size+ percent restored")
    assertLine(event_safe_chain and event_safe_chain.params and event_safe_chain.params.hops == 2, "19 event-safe Chain hops restored")
    assertLine(event_safe_bounce and event_safe_bounce.params and event_safe_bounce.params.bounces == 2, "19 event-safe Bounce bounces restored")
    assertLine(event_safe_multicast and event_safe_multicast.params and event_safe_multicast.params.count == 4, "19 event-safe Multicast count restored")
    assertLine(event_safe_spread and event_safe_spread.params and event_safe_spread.params.preset == 2, "19 event-safe Spread preset restored")
    assertLine(event_safe_timer and event_safe_timer.params and event_safe_timer.params.seconds == 1.5, "19 event-safe Timer seconds restored")

    local lifecycle_entry = generated_lifecycle.newEntry(saved_recipe, { now = 1000 })
    local lifecycle_validated = generated_lifecycle.applyValidation(lifecycle_entry, validate_result, { now = 1001 })
    local lifecycle_previewed = generated_lifecycle.applyPreview(lifecycle_validated, preview_result, { now = 1002 })
    local lifecycle_pending = generated_lifecycle.markCompileRequested(lifecycle_previewed, "smoke-compile", { now = 1003 })
    local lifecycle_compiled = generated_lifecycle.applyCompileResult(lifecycle_pending, {
        ok = true,
        recipe_id = preview_result.recipe_id,
        spell_id = "spellforge_smoke_frontend",
    }, { now = 1004 })
    local changed_saved = saved_recipe_model.update(saved_recipe, {
        recipe_id = "changed-smoke-recipe-id",
    }, { now = 1005 })
    local lifecycle_stale = generated_lifecycle.markRecipeChanged(lifecycle_compiled, changed_saved.saved_recipe, { now = 1006 })
    local cleanup = generated_lifecycle.cleanupPlan(lifecycle_stale)
    local lifecycle_deleted = generated_lifecycle.markDeleted(lifecycle_stale, { now = 1007 })
    local unsupported_lifecycle = generated_lifecycle.validateEntry({
        lifecycle_version = "spellforge-generated-spell-lifecycle-v0",
    })
    local unsupported_lifecycle_issue = unsupported_lifecycle.errors and unsupported_lifecycle.errors[1]
    assertLine(lifecycle_entry.status == generated_lifecycle.STATUS_DRAFT, "20 lifecycle starts draft")
    assertLine(lifecycle_validated.status == generated_lifecycle.STATUS_VALIDATED, "20 lifecycle stores validation")
    assertLine(lifecycle_previewed.status == generated_lifecycle.STATUS_PREVIEWED, "20 lifecycle stores preview")
    assertLine(lifecycle_pending.status == generated_lifecycle.STATUS_COMPILE_PENDING and lifecycle_pending.compile_generation == 1, "20 lifecycle marks compile pending")
    assertLine(lifecycle_compiled.status == generated_lifecycle.STATUS_COMPILED and lifecycle_compiled.frontend_spell_id == "spellforge_smoke_frontend", "20 lifecycle stores compile result")
    assertLine(lifecycle_stale.status == generated_lifecycle.STATUS_STALE and lifecycle_stale.cleanup_required == true, "20 lifecycle marks recipe changes stale")
    assertLine(cleanup.needed == true and cleanup.spell_id == "spellforge_smoke_frontend" and cleanup.delete_compiled_record == true, "20 lifecycle cleanup plan targets compiled spell")
    assertLine(lifecycle_deleted.status == generated_lifecycle.STATUS_DELETED and lifecycle_deleted.cleanup_required == false, "20 lifecycle marks deleted")
    assertLine(unsupported_lifecycle.ok == false and unsupported_lifecycle_issue and unsupported_lifecycle_issue.code == "unsupported_lifecycle_version", "20 lifecycle unsupported version fails")

    local timer_simple = {
        targetEffect("firedamage", 1),
        { id = "spellforge_timer", params = { seconds = 1.0 } },
        targetEffect("frostdamage", 8),
    }
    local trigger_payload_multicast = {
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        { id = "spellforge_multicast", params = { count = 3 } },
        targetEffect("frostdamage", 8),
    }
    local trigger_payload_speed_plus = {
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        { id = "spellforge_speed_plus", params = { percent = 50 } },
        targetEffect("frostdamage", 8),
    }
    local trigger_payload_size_plus = {
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        { id = "spellforge_size_plus", params = { percent = 125 } },
        targetEffect("frostdamage", 8),
    }
    local trigger_payload_speed_size_plus = {
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        { id = "spellforge_speed_plus", params = { percent = 50 } },
        { id = "spellforge_size_plus", params = { percent = 125 } },
        targetEffect("frostdamage", 8),
    }
    local trigger_payload_speed_plus_multicast = {
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        { id = "spellforge_speed_plus", params = { percent = 50 } },
        { id = "spellforge_multicast", params = { count = 3 } },
        targetEffect("frostdamage", 8),
    }
    local trigger_payload_size_plus_multicast = {
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        { id = "spellforge_size_plus", params = { percent = 125 } },
        { id = "spellforge_multicast", params = { count = 3 } },
        targetEffect("frostdamage", 8),
    }
    local trigger_payload_pattern = {
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        { id = "spellforge_burst", params = { count = 5 } },
        { id = "spellforge_multicast", params = { count = 5 } },
        targetEffect("frostdamage", 8),
    }
    local primary_spread_multicast = {
        { id = "spellforge_spread", params = { preset = 2 } },
        { id = "spellforge_multicast", params = { count = 3 } },
        targetEffect("firedamage", 10),
    }
    local trigger_payload_spread = {
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        { id = "spellforge_spread", params = { preset = 2 } },
        { id = "spellforge_multicast", params = { count = 3 } },
        targetEffect("frostdamage", 8),
    }
    local timer_payload_multicast = {
        targetEffect("firedamage", 1),
        { id = "spellforge_timer", params = { seconds = 1.0 } },
        { id = "spellforge_multicast", params = { count = 3 } },
        targetEffect("frostdamage", 8),
    }
    local timer_payload_speed_plus = {
        targetEffect("firedamage", 1),
        { id = "spellforge_timer", params = { seconds = 1.0 } },
        { id = "spellforge_speed_plus", params = { percent = 50 } },
        targetEffect("frostdamage", 8),
    }
    local timer_payload_size_plus = {
        targetEffect("firedamage", 1),
        { id = "spellforge_timer", params = { seconds = 1.0 } },
        { id = "spellforge_size_plus", params = { percent = 125 } },
        targetEffect("frostdamage", 8),
    }
    local timer_payload_speed_size_plus = {
        targetEffect("firedamage", 1),
        { id = "spellforge_timer", params = { seconds = 1.0 } },
        { id = "spellforge_speed_plus", params = { percent = 50 } },
        { id = "spellforge_size_plus", params = { percent = 125 } },
        targetEffect("frostdamage", 8),
    }
    local timer_payload_spread = {
        targetEffect("firedamage", 1),
        { id = "spellforge_timer", params = { seconds = 1.0 } },
        { id = "spellforge_spread", params = { preset = 2 } },
        { id = "spellforge_multicast", params = { count = 3 } },
        targetEffect("frostdamage", 8),
    }
    local trigger_timer_nested = {
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        targetEffect("frostdamage", 8),
        { id = "spellforge_timer", params = { seconds = 1.0 } },
        targetEffect("shockdamage", 6),
    }
    local timer_trigger_nested = {
        targetEffect("firedamage", 1),
        { id = "spellforge_timer", params = { seconds = 1.0 } },
        targetEffect("frostdamage", 8),
        { id = "spellforge_trigger" },
        targetEffect("shockdamage", 6),
    }
    local trigger_timer_final_fanout = {
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        targetEffect("frostdamage", 8),
        { id = "spellforge_timer", params = { seconds = 1.0 } },
        { id = "spellforge_burst", params = { count = 5 } },
        { id = "spellforge_multicast", params = { count = 5 } },
        targetEffect("shockdamage", 6),
    }
    local timer_trigger_final_fanout = {
        targetEffect("firedamage", 1),
        { id = "spellforge_timer", params = { seconds = 1.0 } },
        targetEffect("frostdamage", 8),
        { id = "spellforge_trigger" },
        { id = "spellforge_spread", params = { preset = 2 } },
        { id = "spellforge_multicast", params = { count = 3 } },
        targetEffect("shockdamage", 6),
    }
    local chain_simple = {
        targetEffect("firedamage", 1),
        { id = "spellforge_chain", params = { hops = 3 } },
        targetEffect("frostdamage", 8),
    }
    local chain_payload_multicast = {
        targetEffect("firedamage", 1),
        { id = "spellforge_chain", params = { hops = 3 } },
        { id = "spellforge_multicast", params = { count = 3 } },
        targetEffect("frostdamage", 8),
    }
    local chain_payload_speed_plus_multicast = {
        targetEffect("firedamage", 1),
        { id = "spellforge_chain", params = { hops = 3 } },
        { id = "spellforge_speed_plus", params = { percent = 50 } },
        { id = "spellforge_multicast", params = { count = 3 } },
        targetEffect("frostdamage", 8),
    }
    local chain_payload_size_plus_multicast = {
        targetEffect("firedamage", 1),
        { id = "spellforge_chain", params = { hops = 3 } },
        { id = "spellforge_size_plus", params = { percent = 125 } },
        { id = "spellforge_multicast", params = { count = 3 } },
        targetEffect("frostdamage", 8),
    }
    local trigger_chain_payload_speed_plus_multicast = {
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        { id = "spellforge_chain", params = { hops = 3 } },
        { id = "spellforge_speed_plus", params = { percent = 50 } },
        { id = "spellforge_multicast", params = { count = 3 } },
        targetEffect("frostdamage", 8),
    }
    local trigger_chain_payload_size_plus_multicast = {
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        { id = "spellforge_chain", params = { hops = 3 } },
        { id = "spellforge_size_plus", params = { percent = 125 } },
        { id = "spellforge_multicast", params = { count = 3 } },
        targetEffect("frostdamage", 8),
    }
    local chain_payload_speed_plus = {
        targetEffect("firedamage", 1),
        { id = "spellforge_chain", params = { hops = 3 } },
        { id = "spellforge_speed_plus", params = { percent = 50 } },
        targetEffect("frostdamage", 8),
    }
    local chain_payload_size_plus = {
        targetEffect("firedamage", 1),
        { id = "spellforge_chain", params = { hops = 3 } },
        { id = "spellforge_size_plus", params = { percent = 125 } },
        targetEffect("frostdamage", 8),
    }
    local chain_payload_speed_size_plus = {
        targetEffect("firedamage", 1),
        { id = "spellforge_chain", params = { hops = 3 } },
        { id = "spellforge_speed_plus", params = { percent = 50 } },
        { id = "spellforge_size_plus", params = { percent = 125 } },
        targetEffect("frostdamage", 8),
    }
    local bounce_source = {
        { id = "spellforge_bounce", params = { bounces = 3 } },
        targetEffect("firedamage", 1),
    }
    local bounce_trigger_simple = {
        { id = "spellforge_bounce", params = { bounces = 3 } },
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        targetEffect("frostdamage", 8),
    }
    local bounce_size_plus = {
        { id = "spellforge_bounce", params = { bounces = 3 } },
        { id = "spellforge_size_plus", params = { percent = 125 } },
        targetEffect("firedamage", 1),
    }
    local bounce_speed_size_plus = {
        { id = "spellforge_bounce", params = { bounces = 3 } },
        { id = "spellforge_speed_plus", params = { percent = 50 } },
        { id = "spellforge_size_plus", params = { percent = 125 } },
        targetEffect("firedamage", 1),
    }
    local pierce_source = {
        { id = "spellforge_pierce", params = { pierces = 3 } },
        targetEffect("firedamage", 1),
    }
    local pierce_trigger_simple = {
        { id = "spellforge_pierce", params = { pierces = 3 } },
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        targetEffect("frostdamage", 8),
    }
    local pierce_trigger_multicast = {
        { id = "spellforge_pierce", params = { pierces = 3 } },
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        { id = "spellforge_multicast", params = { count = 3 } },
        targetEffect("frostdamage", 8),
    }
    local pierce_trigger_burst = {
        { id = "spellforge_pierce", params = { pierces = 3 } },
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        { id = "spellforge_burst", params = { count = 5 } },
        { id = "spellforge_multicast", params = { count = 5 } },
        targetEffect("frostdamage", 8),
    }
    local pierce_trigger_spread = {
        { id = "spellforge_pierce", params = { pierces = 3 } },
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        { id = "spellforge_spread", params = { preset = 2 } },
        { id = "spellforge_multicast", params = { count = 3 } },
        targetEffect("frostdamage", 8),
    }
    local pierce_direct_chain = {
        { id = "spellforge_pierce", params = { pierces = 3 } },
        targetEffect("firedamage", 1),
        { id = "spellforge_chain", params = { hops = 3 } },
        targetEffect("frostdamage", 8),
    }
    local pierce_bounce = {
        { id = "spellforge_pierce", params = { pierces = 3 } },
        { id = "spellforge_bounce", params = { bounces = 3 } },
        targetEffect("firedamage", 1),
    }
    local pierce_homing = {
        { id = "spellforge_pierce", params = { pierces = 3 } },
        { id = "spellforge_homing" },
        targetEffect("firedamage", 1),
    }
    local pierce_speed_plus = {
        { id = "spellforge_pierce", params = { pierces = 3 } },
        { id = "spellforge_speed_plus", params = { percent = 50 } },
        targetEffect("firedamage", 1),
    }
    local pierce_size_plus = {
        { id = "spellforge_pierce", params = { pierces = 3 } },
        { id = "spellforge_size_plus", params = { percent = 125 } },
        targetEffect("firedamage", 1),
    }
    local pierce_speed_size_plus = {
        { id = "spellforge_pierce", params = { pierces = 3 } },
        { id = "spellforge_speed_plus", params = { percent = 50 } },
        { id = "spellforge_size_plus", params = { percent = 125 } },
        targetEffect("firedamage", 1),
    }
    local pierce_source_multicast = {
        { id = "spellforge_pierce", params = { pierces = 3 } },
        { id = "spellforge_multicast", params = { count = 3 } },
        targetEffect("firedamage", 1),
    }
    local pierce_nested_payload = {
        { id = "spellforge_pierce", params = { pierces = 3 } },
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        targetEffect("frostdamage", 8),
        { id = "spellforge_trigger" },
        targetEffect("shockdamage", 8),
    }
    local pierce_recursion = {
        { id = "spellforge_pierce", params = { pierces = 3 } },
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        { id = "spellforge_pierce", params = { pierces = 2 } },
        targetEffect("frostdamage", 8),
    }
    local homing_simple = {
        { id = "spellforge_homing" },
        targetEffect("firedamage", 8),
    }
    local homing_composition = {
        { id = "spellforge_homing" },
        targetEffect("firedamage", 1),
        { id = "spellforge_trigger" },
        targetEffect("frostdamage", 8),
    }

    runtimeIrCase("simple projectile", fire_target, { no_continuations = true })
    runtimeIrCase("primary Multicast", multicast, { no_continuations = true, min_fanout_entries = 3 })
    runtimeIrCase("primary Burst Multicast", pattern, { no_continuations = true, min_fanout_entries = 5 })
    runtimeIrCase("primary Spread Multicast", primary_spread_multicast, { no_continuations = true, min_fanout_entries = 3 })
    runtimeIrCase("Trigger simple payload", trigger, { continuations = { Trigger = 1 }, min_payload_entries = 1, min_payload_depth = 1 })
    runtimeIrCase("Timer simple payload", timer_simple, { continuations = { Timer = 1 }, min_payload_entries = 1, min_payload_depth = 1 })
    runtimeIrCase("Trigger payload Speed Plus", trigger_payload_speed_plus, { continuations = { Trigger = 1 }, min_payload_entries = 1, min_payload_depth = 1 })
    runtimeIrCase("Trigger payload Size Plus", trigger_payload_size_plus, { continuations = { Trigger = 1 }, min_payload_entries = 1, min_payload_depth = 1 })
    runtimeIrCase("Trigger payload Speed Plus Size Plus", trigger_payload_speed_size_plus, { continuations = { Trigger = 1 }, min_payload_entries = 1, min_payload_depth = 1 })
    runtimeIrCase("Trigger payload Multicast", trigger_payload_multicast, { continuations = { Trigger = 1 }, min_payload_entries = 3, min_payload_depth = 1, min_fanout_entries = 3 })
    runtimeIrCase("Trigger payload Speed Plus Multicast", trigger_payload_speed_plus_multicast, { continuations = { Trigger = 1 }, min_payload_entries = 3, min_payload_depth = 1, min_fanout_entries = 3 })
    runtimeIrCase("Trigger payload Size Plus Multicast", trigger_payload_size_plus_multicast, { continuations = { Trigger = 1 }, min_payload_entries = 3, min_payload_depth = 1, min_fanout_entries = 3 })
    runtimeIrCase("Trigger payload Burst", trigger_payload_pattern, { continuations = { Trigger = 1 }, min_payload_entries = 5, min_payload_depth = 1, min_fanout_entries = 5 })
    runtimeIrCase("Trigger payload Spread", trigger_payload_spread, { continuations = { Trigger = 1 }, min_payload_entries = 3, min_payload_depth = 1, min_fanout_entries = 3 })
    runtimeIrCase("Timer payload Multicast", timer_payload_multicast, { continuations = { Timer = 1 }, min_payload_entries = 3, min_payload_depth = 1, min_fanout_entries = 3 })
    runtimeIrCase("Timer payload Speed Plus", timer_payload_speed_plus, { continuations = { Timer = 1 }, min_payload_entries = 1, min_payload_depth = 1 })
    runtimeIrCase("Timer payload Size Plus", timer_payload_size_plus, { continuations = { Timer = 1 }, min_payload_entries = 1, min_payload_depth = 1 })
    runtimeIrCase("Timer payload Speed Plus Size Plus", timer_payload_speed_size_plus, { continuations = { Timer = 1 }, min_payload_entries = 1, min_payload_depth = 1 })
    runtimeIrCase("Timer payload Burst", timer_burst_payload, { continuations = { Timer = 1 }, min_payload_entries = 8, min_payload_depth = 1, min_fanout_entries = 8 })
    runtimeIrCase("Timer payload Spread", timer_payload_spread, { continuations = { Timer = 1 }, min_payload_entries = 3, min_payload_depth = 1, min_fanout_entries = 3 })
    runtimeIrCase("nested Trigger Timer", trigger_timer_nested, { continuations = { Trigger = 1, Timer = 1 }, min_payload_entries = 2, min_payload_depth = 2 })
    runtimeIrCase("nested Timer Trigger", timer_trigger_nested, { continuations = { Timer = 1, Trigger = 1 }, min_payload_entries = 2, min_payload_depth = 2 })
    runtimeIrCase("nested Trigger Timer final fanout", trigger_timer_final_fanout, { continuations = { Trigger = 1, Timer = 1 }, min_payload_entries = 6, min_payload_depth = 2, min_fanout_entries = 5 })
    runtimeIrCase("nested Timer Trigger final fanout", timer_trigger_final_fanout, { continuations = { Timer = 1, Trigger = 1 }, min_payload_entries = 4, min_payload_depth = 2, min_fanout_entries = 3 })
    runtimeIrCase("Chain simple payload", chain_simple, { continuations = { Chain = 1 } })
    runtimeIrCase("Chain payload Speed Plus", chain_payload_speed_plus, { continuations = { Chain = 1 } })
    runtimeIrCase("Chain payload Size Plus", chain_payload_size_plus, { continuations = { Chain = 1 } })
    runtimeIrCase("Chain payload Speed Plus Size Plus", chain_payload_speed_size_plus, { continuations = { Chain = 1 } })
    runtimeIrCase("Chain payload Multicast", chain_payload_multicast, { continuations = { Chain = 1 }, min_fanout_entries = 3 })
    runtimeIrCase("Chain payload Speed Plus Multicast", chain_payload_speed_plus_multicast, { continuations = { Chain = 1 }, min_fanout_entries = 3 })
    runtimeIrCase("Chain payload Size Plus Multicast", chain_payload_size_plus_multicast, { continuations = { Chain = 1 }, min_fanout_entries = 3 })
    runtimeIrCase("deferred Chain payload Speed Plus Size Plus Multicast", chain_speed_size_multicast, { continuations = { Chain = 1 }, min_fanout_entries = 3 })
    runtimeIrCase("Trigger Chain payload Speed Plus Multicast", trigger_chain_payload_speed_plus_multicast, { continuations = { Trigger = 1, Chain = 1 }, min_payload_entries = 3, min_payload_depth = 1, min_fanout_entries = 3 })
    runtimeIrCase("Trigger Chain payload Size Plus Multicast", trigger_chain_payload_size_plus_multicast, { continuations = { Trigger = 1, Chain = 1 }, min_payload_entries = 3, min_payload_depth = 1, min_fanout_entries = 3 })
    runtimeIrCase("Bounce source", bounce_source, { continuations = { Bounce = 1 } })
    runtimeIrCase("Bounce Trigger simple payload", bounce_trigger_simple, { continuations = { Bounce = 1, Trigger = 1 }, min_payload_entries = 1, min_payload_depth = 1 })
    runtimeIrCase("Bounce Trigger payload Multicast", bounce_trigger_multicast, { continuations = { Bounce = 1, Trigger = 1 }, min_payload_entries = 8, min_payload_depth = 1, min_fanout_entries = 8 })
    runtimeIrCase("Bounce Trigger payload Pattern", bounce_trigger_burst, { continuations = { Bounce = 1, Trigger = 1 }, min_payload_entries = 5, min_payload_depth = 1, min_fanout_entries = 5 })
    runtimeIrCase("Bounce Trigger Chain", bounce_trigger_chain, { continuations = { Bounce = 1, Trigger = 1, Chain = 1 }, min_payload_entries = 1, min_payload_depth = 1 })
    runtimeIrCase("deferred Bounce Timer", bounce_timer, { continuations = { Bounce = 1, Timer = 1 }, min_payload_entries = 1, min_payload_depth = 1 })
    runtimeIrCase("deferred direct Bounce Chain", bounce_direct_chain, { continuations = { Bounce = 1, Chain = 1 } })
    runtimeIrCase("deferred Bounce Homing", bounce_homing, { continuations = { Bounce = 1 } })
    runtimeIrCase("Bounce source Speed Plus", bounce_speed_plus, { continuations = { Bounce = 1 } })
    runtimeIrCase("Bounce source Size Plus", bounce_size_plus, { continuations = { Bounce = 1 } })
    runtimeIrCase("deferred Bounce source Speed Plus Size Plus", bounce_speed_size_plus, { continuations = { Bounce = 1 } })
    runtimeIrCase("deferred Bounce nested payload", bounce_nested_payload, { continuations = { Bounce = 1, Trigger = 2 }, min_payload_entries = 2, min_payload_depth = 2 })
    runtimeIrCase("Pierce source", pierce_source, { continuations = { Pierce = 1 } })
    runtimeIrCase("Pierce Trigger simple payload", pierce_trigger_simple, { continuations = { Pierce = 1, Trigger = 1 }, min_payload_entries = 1, min_payload_depth = 1 })
    runtimeIrCase("Pierce Trigger payload Multicast", pierce_trigger_multicast, { continuations = { Pierce = 1, Trigger = 1 }, min_payload_entries = 3, min_payload_depth = 1, min_fanout_entries = 3 })
    runtimeIrCase("Pierce Trigger payload Pattern", pierce_trigger_burst, { continuations = { Pierce = 1, Trigger = 1 }, min_payload_entries = 5, min_payload_depth = 1, min_fanout_entries = 5 })
    runtimeIrCase("Pierce Trigger payload Spread", pierce_trigger_spread, { continuations = { Pierce = 1, Trigger = 1 }, min_payload_entries = 3, min_payload_depth = 1, min_fanout_entries = 3 })
    runtimeIrCase("Pierce Trigger Chain", pierce_trigger_chain, { continuations = { Pierce = 1, Trigger = 1, Chain = 1 }, min_payload_entries = 1, min_payload_depth = 1 })
    runtimeIrCase("deferred Pierce Timer", pierce_timer, { continuations = { Pierce = 1, Timer = 1 }, min_payload_entries = 1, min_payload_depth = 1 })
    runtimeIrCase("deferred direct Pierce Chain", pierce_direct_chain, { continuations = { Pierce = 1, Chain = 1 } })
    runtimeIrCase("deferred Pierce Bounce", pierce_bounce, { continuations = { Pierce = 1, Bounce = 1 } })
    runtimeIrCase("deferred Pierce Homing", pierce_homing, { continuations = { Pierce = 1 } })
    runtimeIrCase("Pierce source Speed Plus", pierce_speed_plus, { continuations = { Pierce = 1 } })
    runtimeIrCase("Pierce source Size Plus", pierce_size_plus, { continuations = { Pierce = 1 } })
    runtimeIrCase("deferred Pierce source Speed Plus Size Plus", pierce_speed_size_plus, { continuations = { Pierce = 1 } })
    runtimeIrCase("deferred source Pierce Multicast", pierce_source_multicast, { continuations = { Pierce = 1 }, min_fanout_entries = 3 })
    runtimeIrCase("deferred Pierce nested payload", pierce_nested_payload, { continuations = { Pierce = 1, Trigger = 2 }, min_payload_entries = 2, min_payload_depth = 2 })
    runtimeIrCase("deferred Pierce recursion", pierce_recursion, { continuations = { Pierce = 2, Trigger = 1 }, min_payload_entries = 1, min_payload_depth = 1 })
    runtimeIrCase("Homing simple", homing_simple, { no_continuations = true })
    runtimeIrCase("deferred Homing composition", homing_composition, { continuations = { Trigger = 1 }, min_payload_entries = 1, min_payload_depth = 1 })

    log.info("smoke plan cache run complete")
end

return {
    engineHandlers = {
        onUpdate = function()
            if state.ran then
                return
            end
            state.ran = true
            run()
        end,
    },
}
