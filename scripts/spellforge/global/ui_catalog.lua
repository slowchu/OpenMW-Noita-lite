local events = require("scripts.spellforge.shared.events")
local feature_matrix = require("scripts.spellforge.global.feature_matrix")
local limits = require("scripts.spellforge.shared.limits")
local opcodes = require("scripts.spellforge.shared.opcodes")
local operator_params = require("scripts.spellforge.shared.operator_params")
local recipe_model = require("scripts.spellforge.shared.recipe_model")

local ui_catalog = {}

ui_catalog.VERSION = "spellforge-ui-catalog-v1"

local OPERATOR_EFFECT_IDS = {
    { effect_id = "spellforge_multicast", opcode = "Multicast" },
    { effect_id = "spellforge_spread", opcode = "Spread" },
    { effect_id = "spellforge_burst", opcode = "Burst" },
    { effect_id = "spellforge_speed_plus", opcode = "Speed+" },
    { effect_id = "spellforge_size_plus", opcode = "Size+" },
    { effect_id = "spellforge_chain", opcode = "Chain" },
    { effect_id = "spellforge_bounce", opcode = "Bounce" },
    { effect_id = "spellforge_homing", opcode = "Homing" },
    { effect_id = "spellforge_trigger", opcode = "Trigger" },
    { effect_id = "spellforge_timer", opcode = "Timer" },
}

local OPERATOR_ORDER = {
    "Multicast",
    "Spread",
    "Burst",
    "Speed+",
    "Size+",
    "Chain",
    "Bounce",
    "Homing",
    "Trigger",
    "Timer",
}

local RECIPE_EFFECT_FIELDS = {
    "id",
    "range",
    "area",
    "duration",
    "magnitudeMin",
    "magnitudeMax",
    "params",
    "areaVfxRecId",
    "areaVfxScale",
    "vfxRecId",
    "boltModel",
    "hitModel",
    "ui_id",
    "label",
}

local function cloneScalarMap(tbl)
    local out = {}
    for k, v in pairs(tbl or {}) do
        out[k] = v
    end
    return out
end

local function cloneArray(values)
    local out = {}
    for i, value in ipairs(values or {}) do
        out[i] = value
    end
    return out
end

local function recipeEffectFields()
    local fields = cloneArray(RECIPE_EFFECT_FIELDS)
    for _, field in ipairs(operator_params.encodedFieldNames()) do
        fields[#fields + 1] = field
    end
    return fields
end

local function sortedKeys(tbl)
    local keys = {}
    for key in pairs(tbl or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

local function cloneParameters(parameters)
    local out = {}
    for _, key in ipairs(sortedKeys(parameters)) do
        out[key] = cloneScalarMap(parameters[key])
    end
    return out
end

local function buildOperator(opcode)
    local def = opcodes[opcode] or {}
    return {
        opcode = opcode,
        kind = def.kind,
        display_name = def.display_name or opcode,
        description = def.description,
        parameters = cloneParameters(def.parameters),
    }
end

local function buildOperators()
    local by_opcode = {}
    local list = {}
    for i, opcode in ipairs(OPERATOR_ORDER) do
        local entry = buildOperator(opcode)
        list[i] = entry
        by_opcode[opcode] = entry
    end
    return list, by_opcode
end

local function buildOperatorEffectIds()
    local list = {}
    local by_effect_id = {}
    for i, mapping in ipairs(OPERATOR_EFFECT_IDS) do
        local entry = {
            effect_id = mapping.effect_id,
            opcode = mapping.opcode,
        }
        list[i] = entry
        by_effect_id[mapping.effect_id] = mapping.opcode
    end
    return list, by_effect_id
end

local function buildLimits()
    return {
        max_projectiles_per_cast = limits.MAX_PROJECTILES_PER_CAST,
        max_projectiles_per_cast_hard = limits.MAX_PROJECTILES_PER_CAST_HARD,
        max_payload_fanout = limits.MAX_PAYLOAD_FANOUT,
        max_payload_fanout_hard = limits.MAX_PAYLOAD_FANOUT_HARD,
        max_chain_hops = limits.MAX_CHAIN_HOPS,
        max_chain_multicast_fanout = limits.MAX_CHAIN_MULTICAST_FANOUT,
        max_bounce_count = limits.MAX_BOUNCE_COUNT,
        max_bounce_count_hard = limits.MAX_BOUNCE_COUNT_HARD,
        max_nested_payload_depth = limits.MAX_NESTED_PAYLOAD_DEPTH,
        max_jobs_per_tick = limits.MAX_JOBS_PER_TICK,
        max_live_launches_per_tick = limits.MAX_LIVE_LAUNCHES_PER_TICK,
        max_homing_projectiles_active = limits.MAX_HOMING_PROJECTILES_ACTIVE,
        homing_redirect_blend = limits.HOMING_REDIRECT_BLEND,
    }
end

local function buildSupportTruth()
    return {
        bounce_v0 = {
            gates = {
                "SpellforgeDev.enable_live_2_2c_runtime",
                "SpellforgeDev.enable_live_bounce_v0",
            },
            supported_shapes = {
                "Bounce N -> simple target emitter",
                "Bounce N -> target emitter -> Trigger -> simple payload",
                "Bounce N -> target emitter -> Trigger -> payload Multicast",
                "Bounce N -> target emitter -> Trigger -> payload Spread/Burst + Multicast",
                "Bounce N -> target emitter -> Trigger -> Chain N -> simple payload",
            },
            observed_surfaces = {
                "actor/contact",
                "interior wall/static",
                "exterior wall/static",
                "terrain/ground",
            },
            chain_handoff = "Bounce events may not include a hit actor; Spellforge infers a Chain source near the bounce point when possible and stops safely when no candidates exist.",
            deferred = {
                "Bounce + Timer",
                "Bounce + Homing",
                "Bounce + source Speed+/Size+",
                "Bounce + direct source Chain",
                "Bounce + arbitrary nested payload runtime",
                "Bounce + recursion",
                "Bounce + post-launch steering",
                "per-projectile Lua brains",
            },
        },
    }
end

function ui_catalog.build(payload)
    local operators, operators_by_opcode = buildOperators()
    local operator_effect_ids, operator_opcode_by_effect_id = buildOperatorEffectIds()
    local p = payload or {}

    return {
        request_id = p.request_id,
        ok = true,
        catalog_version = ui_catalog.VERSION,
        contract_version = recipe_model.CONTRACT_VERSION,
        schema_version = recipe_model.SCHEMA_VERSION,
        source_kind = recipe_model.SOURCE_KIND_EFFECT_LIST,
        recipe_model = {
            schema_version = recipe_model.SCHEMA_VERSION,
            source_kind = recipe_model.SOURCE_KIND_EFFECT_LIST,
            effect_fields = recipeEffectFields(),
            generated_ui_id_prefix = "effect:",
        },
        events = {
            validate_recipe = events.VALIDATE_RECIPE,
            validate_result = events.VALIDATE_RESULT,
            preview_recipe = events.PREVIEW_RECIPE,
            preview_result = events.PREVIEW_RESULT,
            query_catalog = events.QUERY_UI_CATALOG,
            catalog_result = events.UI_CATALOG_RESULT,
        },
        operators = operators,
        operators_by_opcode = operators_by_opcode,
        operator_effect_ids = operator_effect_ids,
        operator_opcode_by_effect_id = operator_opcode_by_effect_id,
        operator_count = #operators,
        feature_matrix = {
            version = feature_matrix.VERSION,
            features = feature_matrix.catalog(),
        },
        support_truth = buildSupportTruth(),
        limits = buildLimits(),
        defaults = {
            live_runtime_enabled = false,
            preview_materializes_records = false,
            preview_launches_projectiles = false,
        },
    }
end

return ui_catalog
