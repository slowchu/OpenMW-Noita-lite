local limits = require("scripts.spellforge.shared.limits")
local opcodes = require("scripts.spellforge.shared.opcodes")

local parser = {}

local DEFAULT_OPERATOR_ID_TO_OPCODE = {
    spellforge_multicast = "Multicast",
    spellforge_spread = "Spread",
    spellforge_burst = "Burst",
    spellforge_speed_plus = "Speed+",
    spellforge_size_plus = "Size+",
    spellforge_chain = "Chain",
    spellforge_trigger = "Trigger",
    spellforge_timer = "Timer",
}

local PREFIX_OPS = {
    Multicast = true,
    Spread = true,
    Burst = true,
    ["Speed+"] = true,
    ["Size+"] = true,
    Chain = true,
}

local POSTFIX_OPS = {
    Trigger = true,
    Timer = true,
}

local function appendError(errors, index, message)
    errors[#errors + 1] = {
        path = string.format("effects[%d]", index),
        message = message,
    }
end

local function cloneEffect(effect)
    if type(effect) ~= "table" then
        return effect
    end
    local out = {}
    for k, v in pairs(effect) do
        out[k] = v
    end
    return out
end

local function cloneEffectSlice(effects, start_index)
    local out = {}
    for i = start_index, #effects do
        out[#out + 1] = cloneEffect(effects[i])
    end
    return out
end

local function normalizeId(value)
    if value == nil then
        return nil
    end
    return string.lower(tostring(value))
end

local function isSpellforgeLookingId(effect_id_norm)
    return type(effect_id_norm) == "string" and string.sub(effect_id_norm, 1, 10) == "spellforge_"
end

local function validateParam(errors, index, opcode_name, key, spec, value)
    if spec.type == "integer" then
        if type(value) ~= "number" or value % 1 ~= 0 then
            appendError(errors, index, string.format("%s.%s must be an integer", opcode_name, key))
            return
        end
    elseif spec.type == "number" then
        if type(value) ~= "number" then
            appendError(errors, index, string.format("%s.%s must be a number", opcode_name, key))
            return
        end
    end

    if spec.min ~= nil and value < spec.min then
        appendError(errors, index, string.format("%s.%s must be >= %s", opcode_name, key, tostring(spec.min)))
    end
    if spec.max ~= nil and value > spec.max then
        appendError(errors, index, string.format("%s.%s must be <= %s", opcode_name, key, tostring(spec.max)))
    end
end

local function validateOpcodeParams(errors, index, opcode_name, effect)
    local def = opcodes[opcode_name]
    if not def then
        appendError(errors, index, string.format("Unknown opcode: %s", tostring(opcode_name)))
        return
    end
    local params = effect.params or {}
    for key, spec in pairs(def.parameters or {}) do
        local value = params[key]
        if value == nil then
            appendError(errors, index, string.format("Missing parameter %s for %s", key, opcode_name))
        else
            validateParam(errors, index, opcode_name, key, spec, value)
        end
    end
end

local function computeEmissionCount(prefix_ops)
    local count = 1
    for _, op in ipairs(prefix_ops or {}) do
        if op.opcode == "Multicast" then
            count = count * (op.params and op.params.count or 1)
        end
    end
    return count
end

function parser.parseEffectList(effects, opts)
    local options = opts or {}
    local operator_id_to_opcode = options.operator_id_to_opcode or DEFAULT_OPERATOR_ID_TO_OPCODE
    local max_projectiles = (options.limits and options.limits.MAX_PROJECTILES_PER_CAST) or limits.MAX_PROJECTILES_PER_CAST

    if type(effects) ~= "table" then
        return {
            ok = false,
            errors = { { path = "effects", message = "effects must be an array" } },
            warnings = {},
        }
    end

    local groups = {}
    local warnings = {}
    local errors = {}
    local pending_prefix_ops = {}
    local total_static_emissions = 0

    local function flushEmitter(effect, index)
        local last_group = groups[#groups]
        local compatible_with_last = last_group
            and last_group.kind == "emitter_group"
            and #last_group.effects > 0
            and #pending_prefix_ops == 0
            and last_group.range == effect.range

        if compatible_with_last then
            last_group.effects[#last_group.effects + 1] = cloneEffect(effect)
            return last_group
        end

        local prefix_for_group = pending_prefix_ops
        pending_prefix_ops = {}

        local has_multicast = false
        local has_pattern = false
        for _, op in ipairs(prefix_for_group) do
            if op.opcode == "Multicast" then
                has_multicast = true
            end
            if op.opcode == "Burst" or op.opcode == "Spread" then
                has_pattern = true
            end
        end
        if has_pattern and not has_multicast then
            appendError(errors, index, "Burst/Spread requires Multicast in the same prefix chain")
        end

        local emission_count_static = computeEmissionCount(prefix_for_group)
        if emission_count_static > max_projectiles then
            appendError(errors, index, string.format("Emitter group static emissions exceed MAX_PROJECTILES_PER_CAST (%d)", max_projectiles))
        end
        total_static_emissions = total_static_emissions + emission_count_static
        if total_static_emissions > max_projectiles then
            appendError(errors, index, string.format("Recipe static emission estimate exceeds MAX_PROJECTILES_PER_CAST (%d)", max_projectiles))
        end

        local group = {
            kind = "emitter_group",
            range = effect.range,
            effects = { cloneEffect(effect) },
            prefix_ops = prefix_for_group,
            postfix_ops = {},
            payload = nil,
            emission_count_static = emission_count_static,
        }
        groups[#groups + 1] = group
        return group
    end

    for index, effect in ipairs(effects) do
        if type(effect) ~= "table" then
            appendError(errors, index, "Effect must be a table")
        else
            local effect_id_norm = normalizeId(effect.id)
            local opcode_name = effect_id_norm and operator_id_to_opcode[effect_id_norm] or nil

            if opcode_name then
                validateOpcodeParams(errors, index, opcode_name, effect)
                if PREFIX_OPS[opcode_name] then
                    pending_prefix_ops[#pending_prefix_ops + 1] = {
                        opcode = opcode_name,
                        effect_id = effect.id,
                        params = effect.params or {},
                        index = index,
                    }
                elseif POSTFIX_OPS[opcode_name] then
                    local last_group = groups[#groups]
                    if not last_group then
                        appendError(errors, index, string.format("%s has no preceding emitter group", opcode_name))
                    else
                        local op = {
                            opcode = opcode_name,
                            effect_id = effect.id,
                            params = effect.params or {},
                            index = index,
                            payload_scope = "remaining_effect_list_segment",
                        }
                        last_group.postfix_ops[#last_group.postfix_ops + 1] = op
                        last_group.payload = {
                            scope = "remaining_effect_list_segment",
                            effects = cloneEffectSlice(effects, index + 1),
                            note = "Trigger/Timer payload executes once per emission (runtime, not implemented in parser skeleton)",
                        }
                    end
                end
            else
                if isSpellforgeLookingId(effect_id_norm) then
                    appendError(errors, index, string.format("Unknown Spellforge operator effect ID: %s", tostring(effect.id)))
                end
                flushEmitter(effect, index)
            end
        end
    end

    if #pending_prefix_ops > 0 then
        local first = pending_prefix_ops[1]
        appendError(errors, first.index or #effects, string.format("%s must be followed by an emitter group", tostring(first.opcode)))
    end

    if #groups == 0 then
        appendError(errors, 1, "Recipe has no emitter groups")
    end

    if #errors > 0 then
        return {
            ok = false,
            errors = errors,
            warnings = warnings,
            groups = groups,
        }
    end

    return {
        ok = true,
        groups = groups,
        warnings = warnings,
    }
end

return parser
