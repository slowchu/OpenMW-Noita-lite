local limits = require("scripts.spellforge.shared.limits")
local parser = require("scripts.spellforge.global.parser")

local emission_slots = {}
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

local function cloneOps(ops)
    local out = {}
    for i, op in ipairs(ops or {}) do
        out[i] = {
            opcode = op.opcode,
            effect_id = op.effect_id,
            params = cloneParams(op.params),
            index = op.index,
            payload_scope = op.payload_scope,
        }
    end
    return out
end

local function countMulticast(prefix_ops)
    local count = 1
    for _, op in ipairs(prefix_ops or {}) do
        if op.opcode == "Multicast" then
            count = count * (op.params and op.params.count or 1)
        end
    end
    return count
end

local function appendError(errors, path, message)
    errors[#errors + 1] = {
        path = path,
        message = message,
    }
end

local function hasPostfix(group, opcode)
    for _, op in ipairs(group.postfix_ops or {}) do
        if op.opcode == opcode then
            return true
        end
    end
    return false
end

local function hasPrefix(group, opcode)
    for _, op in ipairs(group.prefix_ops or {}) do
        if op.opcode == opcode then
            return true
        end
    end
    return false
end

local function parsePayloadGroups(payload_effects)
    local payload_parse = parser.parseEffectList(payload_effects)
    if payload_parse.ok then
        return payload_parse.groups, nil
    end
    return nil, payload_parse.errors
end

function emission_slots.allocate(plan, opts)
    local options = opts or {}
    local max_slots = (options.limits and options.limits.MAX_PROJECTILES_PER_CAST) or limits.MAX_PROJECTILES_PER_CAST
    local warnings = {}
    local errors = {}

    if type(plan) ~= "table" then
        appendError(errors, "plan", "plan must be a table")
        return { ok = false, errors = errors, warnings = warnings }
    end
    if type(plan.recipe_id) ~= "string" or plan.recipe_id == "" then
        appendError(errors, "plan.recipe_id", "plan.recipe_id must be a non-empty string")
    end
    if type(plan.groups) ~= "table" then
        appendError(errors, "plan.groups", "plan.groups must be an array")
    end
    if type(plan.parse_result) == "table" and plan.parse_result.ok == false then
        appendError(errors, "plan.parse_result", "plan.parse_result.ok is false")
    end
    if #errors > 0 then
        return { ok = false, errors = errors, warnings = warnings }
    end

    local slots = {}
    local slot_counter = 0

    local function nextSlotId()
        slot_counter = slot_counter + 1
        return string.format("%s:s%d", plan.recipe_id, slot_counter)
    end

    local function ensureCap(next_count, path)
        if next_count > max_slots then
            appendError(errors, path, string.format("Slot count exceeds MAX_PROJECTILES_PER_CAST (%d)", max_slots))
            return false
        end
        return true
    end

    local function allocateGroups(groups, parent_slot_id, source_slot_id, source_opcode, depth)
        if depth > limits.MAX_RECURSION_DEPTH then
            warnings[#warnings + 1] = {
                path = "slots",
                message = string.format("payload depth exceeded MAX_RECURSION_DEPTH (%d); truncating child slot planning", limits.MAX_RECURSION_DEPTH),
            }
            return
        end

        for group_index, group in ipairs(groups or {}) do
            local emission_count = group.emission_count_static or countMulticast(group.prefix_ops)
            local emission_count_number = tonumber(emission_count) or 1

            if hasPrefix(group, "Chain") then
                warnings[#warnings + 1] = {
                    path = string.format("groups[%d]", group_index),
                    message = "Chain metadata preserved only; chain runtime fanout is not implemented in slot allocator",
                }
            end

            for emission_index = 1, emission_count_number do
                if not ensureCap(#slots + 1, "slots") then
                    return
                end

                local slot_id = nextSlotId()
                local slot = {
                    slot_id = slot_id,
                    recipe_id = plan.recipe_id,
                    group_index = group_index,
                    emission_index = emission_index,
                    kind = parent_slot_id and "payload_emission" or "primary_emission",
                    range = group.range,
                    effects = cloneEffects(group.effects),
                    prefix_ops = cloneOps(group.prefix_ops),
                    postfix_ops = cloneOps(group.postfix_ops),
                    parent_slot_id = parent_slot_id,
                    trigger_source_slot_id = source_opcode == "Trigger" and source_slot_id or nil,
                    timer_source_slot_id = source_opcode == "Timer" and source_slot_id or nil,
                    source_postfix_opcode = source_opcode,
                    helper_record_id = nil,
                    runtime_record_created = false,
                    payload_bindings = {},
                }
                slots[#slots + 1] = slot

                if group.payload and type(group.payload.effects) == "table" and #group.payload.effects > 0 then
                    local payload_groups, payload_errors = parsePayloadGroups(group.payload.effects)
                    if payload_groups then
                        local payload_op = hasPostfix(group, "Trigger") and "Trigger" or (hasPostfix(group, "Timer") and "Timer" or "Payload")
                        slot.payload_bindings[#slot.payload_bindings + 1] = {
                            source_opcode = payload_op,
                            payload_scope = group.payload.scope,
                            planned_child_group_count = #payload_groups,
                        }
                        allocateGroups(payload_groups, slot_id, slot_id, payload_op, depth + 1)
                        if #errors > 0 then
                            return
                        end
                    else
                        warnings[#warnings + 1] = {
                            path = string.format("groups[%d].payload", group_index),
                            message = "payload parse failed for slot planning; preserving metadata only",
                            details = payload_errors,
                        }
                        slot.payload_bindings[#slot.payload_bindings + 1] = {
                            source_opcode = hasPostfix(group, "Trigger") and "Trigger" or (hasPostfix(group, "Timer") and "Timer" or "Payload"),
                            payload_scope = group.payload.scope,
                            planned_child_group_count = 0,
                            parse_ok = false,
                        }
                    end
                end
            end
        end
    end

    allocateGroups(plan.groups, nil, nil, nil, 1)

    if #errors > 0 then
        return {
            ok = false,
            recipe_id = plan.recipe_id,
            errors = errors,
            warnings = warnings,
        }
    end

    return {
        ok = true,
        recipe_id = plan.recipe_id,
        slots = slots,
        slot_count = #slots,
        warnings = warnings,
    }
end

return emission_slots
