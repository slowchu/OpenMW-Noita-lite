local limits = require("scripts.spellforge.shared.limits")

local helper_record_specs = {}
local PRESENTATION_METADATA_FIELDS = {
    "areaVfxRecId",
    "areaVfxScale",
    "vfxRecId",
    "boltModel",
    "hitModel",
}

local ELEMENT_SCHOOL_BY_EFFECT_ID = {
    firedamage = { school = "destruction", element = "fire" },
    frostdamage = { school = "destruction", element = "frost" },
    shockdamage = { school = "destruction", element = "shock" },
}

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

local function cloneEffects(effects)
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
        for _, field in ipairs(PRESENTATION_METADATA_FIELDS) do
            if effect[field] ~= nil then
                cloned[field] = effect[field]
            end
        end
        out[i] = cloned
    end
    return out
end

local function normalizeEffectId(effect_id)
    if effect_id == nil then
        return nil
    end
    return string.lower(tostring(effect_id))
end

local function sanitizeForId(value)
    local s = tostring(value or "")
    return (string.gsub(s, "[^%w_]", "_"))
end

local function resolvePresentation(effects)
    local first = effects and effects[1]
    local normalized = normalizeEffectId(first and first.id)
    local mapped = normalized and ELEMENT_SCHOOL_BY_EFFECT_ID[normalized] or nil
    local presentation = {
        school = mapped and mapped.school or nil,
        element = mapped and mapped.element or nil,
    }
    if type(first) == "table" then
        for _, field in ipairs(PRESENTATION_METADATA_FIELDS) do
            if first[field] ~= nil then
                presentation[field] = first[field]
            end
        end
    end
    -- Do not synthesize areaVfxRecId from vfxRecId or boltModel here.
    -- Bolt presentation records are not guaranteed to be valid area statics.
    return presentation
end

function helper_record_specs.auditPresentationMetadata(spec_or_effect)
    local effect = spec_or_effect
    if type(spec_or_effect) == "table" and spec_or_effect.presentation then
        local p = spec_or_effect.presentation
        return {
            has_areaVfxRecId = p.areaVfxRecId ~= nil,
            has_areaVfxScale = p.areaVfxScale ~= nil,
            has_vfxRecId = p.vfxRecId ~= nil,
            has_boltModel = p.boltModel ~= nil,
            has_hitModel = p.hitModel ~= nil,
            spellforge_synthesizes_area_from_bolt = false,
        }
    end
    local p = resolvePresentation({ effect })
    return {
        has_areaVfxRecId = p.areaVfxRecId ~= nil,
        has_areaVfxScale = p.areaVfxScale ~= nil,
        has_vfxRecId = p.vfxRecId ~= nil,
        has_boltModel = p.boltModel ~= nil,
        has_hitModel = p.hitModel ~= nil,
        spellforge_synthesizes_area_from_bolt = false,
    }
end

local function hasOpcode(ops, opcode)
    for _, op in ipairs(ops or {}) do
        if op.opcode == opcode then
            return true
        end
    end
    return false
end

function helper_record_specs.generate(plan, slots_or_result, opts)
    local options = opts or {}
    local max_specs = (options.limits and options.limits.MAX_PROJECTILES_PER_CAST) or limits.MAX_PROJECTILES_PER_CAST
    local errors = {}
    local warnings = {}

    if type(plan) ~= "table" then
        appendError(errors, "plan", "plan must be a table")
    elseif type(plan.recipe_id) ~= "string" or plan.recipe_id == "" then
        appendError(errors, "plan.recipe_id", "plan.recipe_id must be a non-empty string")
    end

    local slots = slots_or_result
    if type(slots_or_result) == "table" and type(slots_or_result.slots) == "table" then
        slots = slots_or_result.slots
    end

    if type(slots) ~= "table" then
        appendError(errors, "slots", "slots must be an array or an allocation result containing slots")
    end

    if #errors > 0 then
        return {
            ok = false,
            errors = errors,
            warnings = warnings,
        }
    end

    if #slots > max_specs then
        appendError(errors, "slots", string.format("Spec count exceeds MAX_PROJECTILES_PER_CAST (%d)", max_specs))
        return {
            ok = false,
            recipe_id = plan.recipe_id,
            errors = errors,
            warnings = warnings,
        }
    end

    local specs = {}
    for index, slot in ipairs(slots) do
        if type(slot) ~= "table" or type(slot.slot_id) ~= "string" or slot.slot_id == "" then
            appendError(errors, string.format("slots[%d]", index), "slot must include a non-empty slot_id")
        else
            local effects = cloneEffects(slot.effects)
            local presentation = resolvePresentation(effects)
            local has_multicast = hasOpcode(slot.prefix_ops, "Multicast")

            local logical_id = string.format(
                "spellforge_helper_%s_%s",
                sanitizeForId(plan.recipe_id),
                sanitizeForId(slot.slot_id)
            )

            specs[#specs + 1] = {
                recipe_id = plan.recipe_id,
                slot_id = slot.slot_id,
                logical_id = logical_id,
                planned_name = string.format("Spellforge Helper %s", tostring(slot.slot_id)),
                internal = true,
                visible_to_player = false,
                engine_record_id = nil,
                engine_record_resolved = false,
                record_type = "spell",
                is_autocalc = false,
                cost = 0,
                range = slot.range,
                effects = effects,
                presentation = presentation,
                fanout = {
                    is_multicast = has_multicast,
                    is_copy = has_multicast and (slot.emission_index or 1) > 1,
                },
                routing = {
                    group_index = slot.group_index,
                    emission_index = slot.emission_index,
                    kind = slot.kind,
                    parent_slot_id = slot.parent_slot_id,
                    trigger_source_slot_id = slot.trigger_source_slot_id,
                    timer_source_slot_id = slot.timer_source_slot_id,
                    source_postfix_opcode = slot.source_postfix_opcode,
                    payload_bindings = slot.payload_bindings,
                    prefix_ops = cloneOps(slot.prefix_ops),
                    postfix_ops = cloneOps(slot.postfix_ops),
                },
                source = {
                    source_kind = plan.source_kind,
                    canonical_version = plan.canonical_version,
                },
            }
        end
    end

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
        specs = specs,
        spec_count = #specs,
        warnings = warnings,
    }
end

return helper_record_specs
