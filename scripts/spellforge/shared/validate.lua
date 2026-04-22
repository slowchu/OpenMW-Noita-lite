local opcodes = require("scripts.spellforge.shared.opcodes")

local validate = {}

local DEFAULT_LIMITS = {
    max_depth = 3,
    max_emitters = 20,
}

local function appendError(errors, path, message)
    errors[#errors + 1] = { path = path, message = message }
end

local function validateParam(errors, path, opcode_name, spec, value, key)
    if spec.type == "integer" then
        if type(value) ~= "number" or value % 1 ~= 0 then
            appendError(errors, path, string.format("%s.%s must be an integer", opcode_name, key))
            return
        end
    elseif spec.type == "number" and type(value) ~= "number" then
        appendError(errors, path, string.format("%s.%s must be a number", opcode_name, key))
        return
    end

    if spec.min ~= nil and value < spec.min then
        appendError(errors, path, string.format("%s.%s must be >= %s", opcode_name, key, tostring(spec.min)))
    end
    if spec.max ~= nil and value > spec.max then
        appendError(errors, path, string.format("%s.%s must be <= %s", opcode_name, key, tostring(spec.max)))
    end
end

local function validateSequence(nodes, state, path, depth)
    local saw_emitter = false
    for i, node in ipairs(nodes) do
        local node_path = string.format("%s[%d]", path, i)

        if type(node) ~= "table" then
            appendError(state.errors, node_path, "Node must be a table")
            goto continue
        end

        if node.kind == "emitter" then
            saw_emitter = true
            state.emitter_count = state.emitter_count + 1
            if state.emitter_count > state.limits.max_emitters then
                appendError(state.errors, node_path, string.format("Emitter cap exceeded (%d)", state.limits.max_emitters))
            end

            local base_spell_id = node.base_spell_id
            if type(base_spell_id) ~= "string" or base_spell_id == "" then
                appendError(state.errors, node_path, "Emitter requires non-empty base_spell_id")
            elseif not state.known_base_spell_ids[base_spell_id] then
                appendError(state.errors, node_path, string.format("Unknown base spell ID: %s", base_spell_id))
            end
        elseif node.kind == "terminal" then
            local base_spell_id = node.base_spell_id
            if type(base_spell_id) ~= "string" or base_spell_id == "" then
                appendError(state.errors, node_path, "Terminal requires non-empty base_spell_id")
            elseif not state.known_base_spell_ids[base_spell_id] then
                appendError(state.errors, node_path, string.format("Unknown base spell ID: %s", base_spell_id))
            end
        else
            local opcode_name = node.opcode
            local def = opcodes[opcode_name]
            if not def then
                appendError(state.errors, node_path, string.format("Unknown opcode: %s", tostring(opcode_name)))
                goto continue
            end

            if def.kind == "scope_opener" and not saw_emitter then
                appendError(state.errors, node_path, "Trigger/Timer must be preceded by emitter in same scope")
            end

            local params = node.params or {}
            for key, spec in pairs(def.parameters) do
                if params[key] == nil then
                    appendError(state.errors, node_path, string.format("Missing parameter %s for %s", key, opcode_name))
                else
                    validateParam(state.errors, node_path, opcode_name, spec, params[key], key)
                end
            end
        end

        if node.payload ~= nil then
            if depth >= state.limits.max_depth then
                appendError(state.errors, node_path, string.format("Recursion depth cap exceeded (%d)", state.limits.max_depth))
            elseif type(node.payload) ~= "table" then
                appendError(state.errors, node_path, "Payload must be an array")
            else
                validateSequence(node.payload, state, node_path .. ".payload", depth + 1)
            end
        end

        ::continue::
    end
end

function validate.run(recipe, opts)
    local options = opts or {}
    local state = {
        limits = {
            max_depth = options.max_depth or DEFAULT_LIMITS.max_depth,
            max_emitters = options.max_emitters or DEFAULT_LIMITS.max_emitters,
        },
        known_base_spell_ids = options.known_base_spell_ids or {},
        emitter_count = 0,
        errors = {},
    }

    if type(recipe) ~= "table" or type(recipe.nodes) ~= "table" then
        return { ok = false, errors = { { path = "recipe", message = "Recipe must include nodes array" } } }
    end

    validateSequence(recipe.nodes, state, "recipe.nodes", 1)

    if #state.errors > 0 then
        return { ok = false, errors = state.errors }
    end
    return { ok = true }
end

return validate
