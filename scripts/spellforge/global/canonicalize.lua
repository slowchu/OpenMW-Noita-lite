local canonicalize = {}

local function sortedKeys(tbl)
    local keys = {}
    for k in pairs(tbl or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

local function serializeNode(node)
    local parts = { tostring(node.opcode or "<nil>") }

    if node.base_spell_id then
        parts[#parts + 1] = "base=" .. tostring(node.base_spell_id)
    end

    if node.params then
        for _, key in ipairs(sortedKeys(node.params)) do
            parts[#parts + 1] = string.format("%s=%s", key, tostring(node.params[key]))
        end
    end

    if node.payload then
        local payload_parts = {}
        for i, child in ipairs(node.payload) do
            payload_parts[i] = serializeNode(child)
        end
        parts[#parts + 1] = "payload[" .. table.concat(payload_parts, ";") .. "]"
    end

    return "{" .. table.concat(parts, "|") .. "}"
end

local function serializeRecipe(recipe)
    local nodes = {}
    for i, node in ipairs(recipe.nodes or {}) do
        nodes[i] = serializeNode(node)
    end
    return table.concat(nodes, "->")
end

local function fnv1a32(input)
    local hash = 2166136261
    for i = 1, #input do
        hash = hash ~ string.byte(input, i)
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

function canonicalize.run(recipe)
    local canonical = serializeRecipe(recipe)
    return {
        canonical = canonical,
        recipe_id = fnv1a32(canonical),
    }
end

return canonicalize
