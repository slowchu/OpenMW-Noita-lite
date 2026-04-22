local storage = require("openmw.storage")
local world = require("openmw.world")
local log = require("scripts.spellforge.shared.log").new("global.records")

local records = {}

local section = storage.globalSection("SpellforgeCompiled")
local KEY_RECIPE_INDEX = "recipe_index"

local function sanitizeStringArray(values)
    local out = {}
    if type(values) ~= "table" then
        return out
    end
    for i, value in ipairs(values) do
        if type(value) == "string" then
            out[i] = value
        end
    end
    return out
end

local function sanitizeNodeEntry(entry)
    if type(entry) ~= "table" then
        return nil
    end
    return {
        node_index = tonumber(entry.node_index) or 0,
        node_path = type(entry.node_path) == "table" and entry.node_path or {},
        base_spell_id = type(entry.base_spell_id) == "string" and entry.base_spell_id or nil,
        logical_id = type(entry.logical_id) == "string" and entry.logical_id or nil,
        engine_id = type(entry.engine_id) == "string" and entry.engine_id or nil,
        real_effects = type(entry.real_effects) == "table" and entry.real_effects or {},
        payload = type(entry.payload) == "table" and entry.payload or nil,
        trigger = type(entry.trigger) == "table" and entry.trigger or nil,
        launch_mods = type(entry.launch_mods) == "table" and entry.launch_mods or {},
    }
end

local function sanitizeNodeEntries(node_entries)
    local out = {}
    if type(node_entries) ~= "table" then
        return out
    end
    for i, entry in ipairs(node_entries) do
        local sanitized = sanitizeNodeEntry(entry)
        if sanitized then
            out[i] = sanitized
        end
    end
    return out
end

local function sanitizeEntry(entry)
    if type(entry) ~= "table" then
        return nil
    end
    local generated_spell_ids = sanitizeStringArray(entry.generated_spell_ids)
    local generated_engine_spell_ids = sanitizeStringArray(entry.generated_engine_spell_ids)
    if #generated_engine_spell_ids == 0 and type(entry.frontend_spell_id) == "string" and entry.frontend_spell_id ~= "" then
        generated_engine_spell_ids[1] = entry.frontend_spell_id
    end
    return {
        canonical = type(entry.canonical) == "string" and entry.canonical or nil,
        frontend_spell_id = type(entry.frontend_spell_id) == "string" and entry.frontend_spell_id or nil,
        frontend_logical_id = type(entry.frontend_logical_id) == "string" and entry.frontend_logical_id or nil,
        generated_spell_ids = generated_spell_ids,
        generated_engine_spell_ids = generated_engine_spell_ids,
        node_entries = sanitizeNodeEntries(entry.node_entries),
        recipe = type(entry.recipe) == "table" and entry.recipe or nil,
    }
end

local function normalizeRecipeIndex(value)
    local normalized = {}
    if value == nil then
        return normalized
    end

    local ok, err = pcall(function()
        for k, v in pairs(value) do
            if type(k) == "string" then
                normalized[k] = sanitizeEntry(v)
            end
        end
    end)
    if not ok then
        log.error(string.format("records.normalizeRecipeIndex failed: %s", tostring(err)))
        return {}
    end

    return normalized
end

local in_memory = {
    by_recipe = normalizeRecipeIndex(section:get(KEY_RECIPE_INDEX)),
}

local function persist()
    section:set(KEY_RECIPE_INDEX, in_memory.by_recipe)
end

function records.getByRecipeId(recipe_id)
    return in_memory.by_recipe[recipe_id]
end

function records.put(recipe_id, payload)
    in_memory.by_recipe[recipe_id] = sanitizeEntry(payload)
    persist()
end

function records.createRecord(draft)
    local ok, created_or_err = pcall(world.createRecord, draft)
    if not ok then
        log.error(string.format("records.createRecord failed: %s", tostring(created_or_err)))
        return nil, created_or_err
    end
    return created_or_err, nil
end

function records.deleteBySpellId(spell_id)
    for recipe_id, entry in pairs(in_memory.by_recipe) do
        if entry and entry.frontend_spell_id == spell_id then
            in_memory.by_recipe[recipe_id] = nil
            persist()
            return true, recipe_id
        end
    end
    return false, nil
end

function records.findByEngineSpellId(engine_id)
    if type(engine_id) ~= "string" or engine_id == "" then
        return nil, nil
    end
    for recipe_id, entry in pairs(in_memory.by_recipe) do
        if entry and entry.frontend_spell_id == engine_id then
            return recipe_id, entry
        end
        for _, generated_engine_id in ipairs(entry and entry.generated_engine_spell_ids or {}) do
            if generated_engine_id == engine_id then
                return recipe_id, entry
            end
        end
    end
    return nil, nil
end

function records.findNodeByEngineSpellId(engine_id)
    if type(engine_id) ~= "string" or engine_id == "" then
        return nil, nil, nil
    end
    for recipe_id, entry in pairs(in_memory.by_recipe) do
        for _, node_entry in ipairs(entry and entry.node_entries or {}) do
            if node_entry and node_entry.engine_id == engine_id then
                return recipe_id, entry, node_entry
            end
        end
    end
    return nil, nil, nil
end

return records
