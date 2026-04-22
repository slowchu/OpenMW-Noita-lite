local storage = require("openmw.storage")
local world = require("openmw.world")

local records = {}

local section = storage.globalSection("SpellforgeCompiled")
local KEY_RECIPE_INDEX = "recipe_index"
local in_memory = {
    by_recipe = section:get(KEY_RECIPE_INDEX) or {},
}

local function persist()
    section:set(KEY_RECIPE_INDEX, in_memory.by_recipe)
end

function records.getByRecipeId(recipe_id)
    return in_memory.by_recipe[recipe_id]
end

function records.put(recipe_id, payload)
    in_memory.by_recipe[recipe_id] = payload
    persist()
end

function records.createRecord(draft)
    return world.createRecord(draft)
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
