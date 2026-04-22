local storage = require("openmw.storage")
local world = require("openmw.world")
local log = require("scripts.spellforge.shared.log").new("global.records")

local records = {}

local section = storage.globalSection("SpellforgeCompiled")
local KEY_RECIPE_INDEX = "recipe_index"

local function sanitizeGeneratedSpellIds(generated_spell_ids)
    local out = {}
    if type(generated_spell_ids) ~= "table" then
        return out
    end
    for i, spell_id in ipairs(generated_spell_ids) do
        if type(spell_id) == "string" then
            out[i] = spell_id
        end
    end
    return out
end

local function sanitizeGeneratedEngineSpellIds(generated_engine_spell_ids)
    local out = {}
    if type(generated_engine_spell_ids) ~= "table" then
        return out
    end
    for i, engine_id in ipairs(generated_engine_spell_ids) do
        if type(engine_id) == "string" then
            out[i] = engine_id
        end
    end
    return out
end

local function sanitizeEntry(entry)
    if type(entry) ~= "table" then
        return nil
    end
    local generated_spell_ids = sanitizeGeneratedSpellIds(entry.generated_spell_ids)
    local generated_engine_spell_ids = sanitizeGeneratedEngineSpellIds(entry.generated_engine_spell_ids)
    if #generated_engine_spell_ids == 0 and type(entry.frontend_spell_id) == "string" and entry.frontend_spell_id ~= "" then
        generated_engine_spell_ids[1] = entry.frontend_spell_id
    end
    local frontend_logical_id = type(entry.frontend_logical_id) == "string" and entry.frontend_logical_id or generated_spell_ids[1]
    return {
        canonical = type(entry.canonical) == "string" and entry.canonical or nil,
        frontend_spell_id = type(entry.frontend_spell_id) == "string" and entry.frontend_spell_id or nil,
        frontend_logical_id = frontend_logical_id,
        generated_spell_ids = generated_spell_ids,
        generated_engine_spell_ids = generated_engine_spell_ids,
    }
end

local function normalizeRecipeIndex(value)
    local normalized = {}
    if value == nil then
        return normalized
    end

    if type(value) == "table" then
        for k, v in pairs(value) do
            if type(k) == "string" then
                normalized[k] = sanitizeEntry(v)
            end
        end
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
        if entry.frontend_spell_id == spell_id then
            in_memory.by_recipe[recipe_id] = nil
            persist()
            return true, recipe_id
        end
    end
    return false, nil
end

return records
