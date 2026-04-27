local core = require("openmw.core")
local limits = require("scripts.spellforge.shared.limits")
local records = require("scripts.spellforge.global.records")
local runtime_stats = require("scripts.spellforge.global.runtime_stats")
local log = require("scripts.spellforge.shared.log").new("global.helper_records")

local helper_records = {}
local PRESENTATION_METADATA_FIELDS = {
    "areaVfxRecId",
    "areaVfxScale",
    "vfxRecId",
    "boltModel",
    "hitModel",
}

local by_logical_id = {}
local by_engine_id = {}
local by_recipe_slot = {}

local function recipeSlotKey(recipe_id, slot_id)
    return string.format("%s::%s", tostring(recipe_id), tostring(slot_id))
end

local function appendError(errors, path, message)
    errors[#errors + 1] = {
        path = path,
        message = message,
    }
end

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

local function cloneEffects(effects, include_metadata)
    local out = {}
    for i, effect in ipairs(effects or {}) do
        local cloned = {
            id = effect.id,
            range = effect.range,
            area = effect.area,
            duration = effect.duration,
            magnitudeMin = effect.magnitudeMin,
            magnitudeMax = effect.magnitudeMax,
            params = cloneParams(effect.params),
        }
        if include_metadata then
            for _, field in ipairs(PRESENTATION_METADATA_FIELDS) do
                if effect[field] ~= nil then
                    cloned[field] = effect[field]
                end
            end
        end
        out[i] = cloned
    end
    return out
end

local function clonePresentation(presentation)
    local out = {
        school = presentation and presentation.school or nil,
        element = presentation and presentation.element or nil,
    }
    for _, field in ipairs(PRESENTATION_METADATA_FIELDS) do
        if presentation and presentation[field] ~= nil then
            out[field] = presentation[field]
        end
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

local function buildDraft(spec)
    return core.magic.spells.createRecordDraft {
        id = spec.logical_id,
        name = spec.planned_name or string.format("Spellforge Helper %s", tostring(spec.slot_id)),
        cost = spec.cost or 0,
        isAutocalc = spec.is_autocalc == true,
        effects = cloneEffects(spec.effects, false),
    }
end

local function toMapping(spec, engine_id, reused)
    return {
        recipe_id = spec.recipe_id,
        slot_id = spec.slot_id,
        group_index = spec.routing and spec.routing.group_index or nil,
        emission_index = spec.routing and spec.routing.emission_index or nil,
        kind = spec.routing and spec.routing.kind or nil,
        parent_slot_id = spec.routing and spec.routing.parent_slot_id or nil,
        trigger_source_slot_id = spec.routing and spec.routing.trigger_source_slot_id or nil,
        timer_source_slot_id = spec.routing and spec.routing.timer_source_slot_id or nil,
        source_postfix_opcode = spec.routing and spec.routing.source_postfix_opcode or nil,
        logical_id = spec.logical_id,
        engine_id = engine_id,
        internal = spec.internal == true,
        visible_to_player = spec.visible_to_player == true,
        effects = cloneEffects(spec.effects, true),
        presentation = clonePresentation(spec.presentation),
        payload_bindings = spec.routing and spec.routing.payload_bindings or nil,
        prefix_ops = cloneOps(spec.routing and spec.routing.prefix_ops),
        postfix_ops = cloneOps(spec.routing and spec.routing.postfix_ops),
        reused = reused == true,
    }
end

local function putMapping(mapping)
    by_logical_id[mapping.logical_id] = mapping
    by_engine_id[mapping.engine_id] = mapping
    by_recipe_slot[recipeSlotKey(mapping.recipe_id, mapping.slot_id)] = mapping
end

function helper_records.getByLogicalId(logical_id)
    return by_logical_id[logical_id]
end

function helper_records.getByEngineId(engine_id)
    return by_engine_id[engine_id]
end

function helper_records.getByRecipeSlot(recipe_id, slot_id)
    return by_recipe_slot[recipeSlotKey(recipe_id, slot_id)]
end

function helper_records.clearForTests()
    by_logical_id = {}
    by_engine_id = {}
    by_recipe_slot = {}
end

function helper_records.materialize(specs_or_result, opts)
    local options = opts or {}
    local max_specs = (options.limits and options.limits.MAX_PROJECTILES_PER_CAST) or limits.MAX_PROJECTILES_PER_CAST
    local warnings = {}
    local errors = {}

    local specs = specs_or_result
    local recipe_id = nil
    if type(specs_or_result) == "table" and type(specs_or_result.specs) == "table" then
        specs = specs_or_result.specs
        recipe_id = specs_or_result.recipe_id
    end

    if type(specs) ~= "table" then
        appendError(errors, "specs", "specs must be an array or generator result containing specs")
        return { ok = false, errors = errors, warnings = warnings }
    end

    if #specs > max_specs then
        appendError(errors, "specs", string.format("Spec count exceeds MAX_PROJECTILES_PER_CAST (%d)", max_specs))
        return {
            ok = false,
            recipe_id = recipe_id,
            errors = errors,
            warnings = warnings,
        }
    end

    local materialized = {}
    local any_new = false

    for i, spec in ipairs(specs) do
        if type(spec) ~= "table" then
            appendError(errors, string.format("specs[%d]", i), "spec must be a table")
            break
        end
        if type(spec.logical_id) ~= "string" or spec.logical_id == "" then
            appendError(errors, string.format("specs[%d].logical_id", i), "logical_id must be a non-empty string")
            break
        end
        if type(spec.recipe_id) ~= "string" or spec.recipe_id == "" then
            appendError(errors, string.format("specs[%d].recipe_id", i), "recipe_id must be a non-empty string")
            break
        end
        if type(spec.slot_id) ~= "string" or spec.slot_id == "" then
            appendError(errors, string.format("specs[%d].slot_id", i), "slot_id must be a non-empty string")
            break
        end
        if type(spec.effects) ~= "table" or #spec.effects == 0 then
            appendError(errors, string.format("specs[%d].effects", i), "effects must be a non-empty array")
            break
        end

        recipe_id = recipe_id or spec.recipe_id

        local existing = helper_records.getByLogicalId(spec.logical_id)
        if existing then
            local reused_mapping = toMapping(spec, existing.engine_id, true)
            putMapping(reused_mapping)
            materialized[#materialized + 1] = reused_mapping
            runtime_stats.inc("helper_records_reused")
        else
            local draft = buildDraft(spec)
            local created_record, create_error = records.createRecord(draft)
            if create_error then
                local first = spec.effects and spec.effects[1] or nil
                local keys = {}
                for k in pairs(draft or {}) do
                    keys[#keys + 1] = tostring(k)
                end
                table.sort(keys)
                log.error(string.format(
                    "helper createRecord failed logical_id=%s slot_id=%s effect_count=%d first_effect={id=%s range=%s area=%s duration=%s min=%s max=%s} draft_keys=%s err=%s",
                    tostring(spec.logical_id),
                    tostring(spec.slot_id),
                    #(spec.effects or {}),
                    tostring(first and first.id),
                    tostring(first and first.range),
                    tostring(first and first.area),
                    tostring(first and first.duration),
                    tostring(first and first.magnitudeMin),
                    tostring(first and first.magnitudeMax),
                    table.concat(keys, ","),
                    tostring(create_error)
                ))
                appendError(errors, string.format("specs[%d]", i), string.format("world.createRecord failed: %s", tostring(create_error)))
                break
            end
            local engine_id = created_record and created_record.id or nil
            if type(engine_id) ~= "string" or engine_id == "" then
                appendError(errors, string.format("specs[%d]", i), "world.createRecord returned unusable engine id")
                break
            end

            local mapping = toMapping(spec, engine_id, false)
            putMapping(mapping)
            materialized[#materialized + 1] = mapping
            any_new = true
            runtime_stats.inc("helper_records_created")
        end
    end

    if #errors > 0 then
        return {
            ok = false,
            recipe_id = recipe_id,
            errors = errors,
            warnings = warnings,
            partial_records = materialized,
            partial_count = #materialized,
        }
    end

    return {
        ok = true,
        recipe_id = recipe_id,
        records = materialized,
        record_count = #materialized,
        reused = not any_new,
        warnings = warnings,
    }
end

return helper_records
