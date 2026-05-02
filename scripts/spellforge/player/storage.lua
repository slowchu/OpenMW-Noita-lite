local openmw_storage = require("openmw.storage")

local generated_lifecycle = require("scripts.spellforge.shared.generated_spell_lifecycle")
local saved_recipe_model = require("scripts.spellforge.shared.saved_recipe_model")

local storage = {}

local SECTION_NAME = "SpellforgeUi"
local KEY_SAVED_RECIPES = "saved_recipes"
local KEY_LIFECYCLES = "generated_spell_lifecycles"
local KEY_NEXT_ID = "next_saved_recipe_id"

local section = nil
local memory = {
    saved_recipes = {},
    generated_spell_lifecycles = {},
    next_saved_recipe_id = 1,
}
local cached_saved_recipes = nil
local cached_lifecycles = nil
local cached_next_saved_recipe_id = nil

local function initSection()
    if section ~= nil then
        return section
    end
    if type(openmw_storage.playerSection) == "function" then
        local ok, result = pcall(openmw_storage.playerSection, SECTION_NAME)
        if ok then
            section = result
        end
    end
    return section
end

local function sectionGet(key)
    local s = initSection()
    if s and type(s.get) == "function" then
        return s:get(key)
    end
    return memory[key]
end

local function sectionSet(key, value)
    local s = initSection()
    if s and type(s.set) == "function" then
        s:set(key, value)
        return
    end
    memory[key] = value
end

local function cloneValue(value, depth)
    if type(value) ~= "table" then
        return value
    end
    if (depth or 0) >= 5 then
        return tostring(value)
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = cloneValue(v, (depth or 0) + 1)
    end
    return out
end

local function loadIndex()
    if cached_saved_recipes ~= nil then
        return cloneValue(cached_saved_recipes, 0)
    end

    local value = sectionGet(KEY_SAVED_RECIPES)
    if type(value) ~= "table" then
        cached_saved_recipes = {}
        return {}
    end
    local out = {}
    for id, saved in pairs(value) do
        if type(id) == "string" and type(saved) == "table" then
            local normalized = saved_recipe_model.migrate(saved, { id = id })
            if normalized.ok then
                out[id] = normalized.saved_recipe
            end
        end
    end
    cached_saved_recipes = out
    return cloneValue(out, 0)
end

local function saveIndex(index)
    cached_saved_recipes = cloneValue(index or {}, 0)
    sectionSet(KEY_SAVED_RECIPES, cached_saved_recipes)
end

local function loadLifecycleIndex()
    if cached_lifecycles ~= nil then
        return cloneValue(cached_lifecycles, 0)
    end

    local value = sectionGet(KEY_LIFECYCLES)
    if type(value) ~= "table" then
        cached_lifecycles = {}
        return {}
    end
    local out = {}
    for id, entry in pairs(value) do
        if type(id) == "string" and type(entry) == "table" then
            local normalized = generated_lifecycle.validateEntry(entry)
            if normalized.ok then
                normalized.entry.saved_recipe_id = normalized.entry.saved_recipe_id or id
                out[id] = normalized.entry
            end
        end
    end
    cached_lifecycles = out
    return cloneValue(out, 0)
end

local function saveLifecycleIndex(index)
    cached_lifecycles = cloneValue(index or {}, 0)
    sectionSet(KEY_LIFECYCLES, cached_lifecycles)
end

local function nextSavedRecipeId(reserve)
    local next_id = cached_next_saved_recipe_id or tonumber(sectionGet(KEY_NEXT_ID)) or 1
    cached_next_saved_recipe_id = next_id
    if reserve then
        cached_next_saved_recipe_id = next_id + 1
        sectionSet(KEY_NEXT_ID, cached_next_saved_recipe_id)
    end
    return string.format("saved:%d", next_id)
end

function storage.list()
    local index = loadIndex()
    local out = {}
    for _, saved in pairs(index) do
        out[#out + 1] = cloneValue(saved, 0)
    end
    table.sort(out, function(a, b)
        return tostring(a.title or a.id) < tostring(b.title or b.id)
    end)
    return out
end

function storage.get(saved_recipe_id)
    if type(saved_recipe_id) ~= "string" or saved_recipe_id == "" then
        return nil
    end
    local index = loadIndex()
    local saved = index[saved_recipe_id]
    return saved and cloneValue(saved, 0) or nil
end

function storage.save(input, opts)
    local options = opts or {}
    local explicit_id = input and input.id or options.id
    local id = explicit_id or nextSavedRecipeId(false)
    local normalized = saved_recipe_model.normalize(input or {}, {
        id = id,
        now = options.now,
        recipe_options = options.recipe_options,
    })
    if not normalized.ok then
        return normalized
    end

    if not explicit_id then
        nextSavedRecipeId(true)
    end

    local index = loadIndex()
    index[normalized.saved_recipe.id] = normalized.saved_recipe
    saveIndex(index)

    local lifecycle_index = loadLifecycleIndex()
    lifecycle_index[normalized.saved_recipe.id] = generated_lifecycle.newEntry(normalized.saved_recipe, { now = options.now })
    saveLifecycleIndex(lifecycle_index)

    return {
        ok = true,
        saved_recipe = cloneValue(normalized.saved_recipe, 0),
        errors = {},
        warnings = normalized.warnings or {},
    }
end

function storage.update(saved_recipe_id, patch, opts)
    local existing = storage.get(saved_recipe_id)
    if not existing then
        return {
            ok = false,
            errors = {
                {
                    code = "saved_recipe_not_found",
                    path = "saved_recipe.id",
                    message = string.format("No saved recipe found for id=%s", tostring(saved_recipe_id)),
                    severity = "error",
                },
            },
            warnings = {},
        }
    end

    local sanitized_patch = cloneValue(patch or {}, 0)
    sanitized_patch.id = saved_recipe_id

    local updated = saved_recipe_model.update(existing, sanitized_patch, opts)
    if not updated.ok then
        return updated
    end

    local index = loadIndex()
    index[saved_recipe_id] = updated.saved_recipe
    saveIndex(index)
    return {
        ok = true,
        saved_recipe = cloneValue(updated.saved_recipe, 0),
        errors = {},
        warnings = updated.warnings or {},
    }
end

function storage.delete(saved_recipe_id)
    if type(saved_recipe_id) ~= "string" or saved_recipe_id == "" then
        return {
            ok = false,
            deleted = false,
            saved_recipe_id = saved_recipe_id,
            errors = {
                {
                    code = "saved_recipe_id_required",
                    path = "saved_recipe.id",
                    message = "saved recipe id must be a non-empty string",
                    severity = "error",
                },
            },
        }
    end

    local index = loadIndex()
    local existed = index[saved_recipe_id] ~= nil
    index[saved_recipe_id] = nil
    saveIndex(index)

    local lifecycle_index = loadLifecycleIndex()
    lifecycle_index[saved_recipe_id] = nil
    saveLifecycleIndex(lifecycle_index)

    return {
        ok = true,
        deleted = existed,
        saved_recipe_id = saved_recipe_id,
    }
end

function storage.getLifecycle(saved_recipe_id)
    if type(saved_recipe_id) ~= "string" or saved_recipe_id == "" then
        return nil
    end
    local index = loadLifecycleIndex()
    local entry = index[saved_recipe_id]
    return entry and cloneValue(entry, 0) or nil
end

function storage.putLifecycle(saved_recipe_id, entry)
    if type(saved_recipe_id) ~= "string" or saved_recipe_id == "" then
        return {
            ok = false,
            errors = {
                {
                    code = "saved_recipe_id_required",
                    path = "saved_recipe.id",
                    message = "saved recipe id must be a non-empty string",
                    severity = "error",
                },
            },
            warnings = {},
        }
    end

    local validated = generated_lifecycle.validateEntry(entry)
    if not validated.ok then
        return validated
    end
    validated.entry.saved_recipe_id = validated.entry.saved_recipe_id or saved_recipe_id

    local index = loadLifecycleIndex()
    index[saved_recipe_id] = validated.entry
    saveLifecycleIndex(index)
    return {
        ok = true,
        lifecycle = cloneValue(validated.entry, 0),
        errors = {},
        warnings = validated.warnings or {},
    }
end

function storage.clearForTests()
    cached_saved_recipes = {}
    cached_lifecycles = {}
    cached_next_saved_recipe_id = 1
    sectionSet(KEY_SAVED_RECIPES, {})
    sectionSet(KEY_LIFECYCLES, {})
    sectionSet(KEY_NEXT_ID, 1)
end

return storage
