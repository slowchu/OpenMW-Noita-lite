local canonicalize_effect_list = require("scripts.spellforge.global.canonicalize_effect_list")
local feature_matrix = require("scripts.spellforge.global.feature_matrix")
local parser = require("scripts.spellforge.global.parser")
local plan_cache = require("scripts.spellforge.global.plan_cache")
local recipe_model = require("scripts.spellforge.shared.recipe_model")
local validation = require("scripts.spellforge.shared.validation_contract")

local ui_contract = {}

local function payloadInput(payload)
    local p = payload or {}
    if type(p.recipe) == "table" then
        return p.recipe
    end
    if type(p.effects) == "table" and (
        p.schema_version ~= nil
        or p.source_kind ~= nil
        or p.title ~= nil
        or p.name ~= nil
        or p.description ~= nil
    ) then
        return p
    end
    if type(p.effects) == "table" then
        return { effects = p.effects }
    end
    return p
end

local function appendIssues(out, issues, fallback_severity)
    for _, issue in ipairs(issues or {}) do
        out[#out + 1] = validation.cloneIssue(issue, fallback_severity)
    end
end

local function normalizedIssues(errors, warnings)
    return {
        errors = validation.cloneIssues(errors, "error"),
        warnings = validation.cloneIssues(warnings, "warning"),
    }
end

local function validationBlock(errors, warnings)
    local issues = normalizedIssues(errors, warnings)
    return {
        ok = #issues.errors == 0,
        errors = issues.errors,
        warnings = issues.warnings,
    }
end

local function resultBase(payload)
    return {
        request_id = payload and payload.request_id or nil,
        contract_version = recipe_model.CONTRACT_VERSION,
        schema_version = recipe_model.SCHEMA_VERSION,
        source_kind = recipe_model.SOURCE_KIND_EFFECT_LIST,
    }
end

local function failureResult(payload, recipe, recipe_id, errors, warnings)
    local validation_result = validationBlock(errors, warnings)
    local result = resultBase(payload)
    result.ok = false
    result.success = false
    result.recipe_id = recipe_id
    result.recipe = recipe
    result.effects = recipe and recipe.effects or nil
    result.validation = validation_result
    result.errors = validation_result.errors
    result.warnings = validation_result.warnings
    return result
end

function ui_contract.validateRecipe(payload)
    local options = payload and payload.options or nil
    local normalized = recipe_model.normalize(payloadInput(payload), options)
    local errors = {}
    local warnings = {}

    appendIssues(errors, normalized.errors, "error")
    appendIssues(warnings, normalized.warnings, "warning")

    local canonical
    local parse_result
    if normalized.ok then
        canonical = canonicalize_effect_list.run(normalized.effects, options)
        parse_result = parser.parseEffectList(normalized.effects, options)
        appendIssues(errors, parse_result.errors, "error")
        appendIssues(warnings, parse_result.warnings, "warning")
    end

    local validation_result = validationBlock(errors, warnings)
    local result = resultBase(payload)
    result.ok = validation_result.ok
    result.success = validation_result.ok
    result.recipe_id = canonical and canonical.recipe_id or nil
    result.canonical_version = canonical and "spellforge-effect-list-v1" or nil
    result.recipe = normalized.recipe
    result.effects = normalized.effects
    result.validation = validation_result
    result.errors = validation_result.errors
    result.warnings = validation_result.warnings
    result.groups = parse_result and parse_result.groups or nil
    return result
end

function ui_contract.previewRecipe(payload)
    local options = payload and payload.options or nil
    local normalized = recipe_model.normalize(payloadInput(payload), options)
    local errors = {}
    local warnings = {}

    appendIssues(errors, normalized.errors, "error")
    appendIssues(warnings, normalized.warnings, "warning")

    if not normalized.ok then
        return failureResult(payload, normalized.recipe, nil, errors, warnings)
    end

    local compiled = plan_cache.compileOrGet(normalized.effects, options)
    appendIssues(errors, compiled.errors, "error")
    appendIssues(warnings, compiled.warnings, "warning")
    if not compiled.ok then
        return failureResult(payload, normalized.recipe, compiled.recipe_id, errors, warnings)
    end

    local slots = plan_cache.attachEmissionSlots(compiled.recipe_id, options)
    appendIssues(errors, slots.errors, "error")
    appendIssues(warnings, slots.warnings, "warning")
    if not slots.ok then
        return failureResult(payload, normalized.recipe, compiled.recipe_id, errors, warnings)
    end

    local specs = plan_cache.attachHelperSpecs(compiled.recipe_id, options)
    appendIssues(errors, specs.errors, "error")
    appendIssues(warnings, specs.warnings, "warning")
    if not specs.ok then
        return failureResult(payload, normalized.recipe, compiled.recipe_id, errors, warnings)
    end

    local plan = specs.plan or slots.plan or compiled.plan or {}
    local matrix = feature_matrix.analyze(plan, options)
    local preview = {
        recipe_id = compiled.recipe_id,
        source_kind = plan.source_kind,
        canonical_version = plan.canonical_version,
        runtime_status = plan.runtime_status,
        bounds = plan.bounds,
        group_count = #(plan.groups or {}),
        groups = plan.groups,
        slot_count = plan.slot_count or #(plan.emission_slots or {}),
        slots = plan.emission_slots or {},
        helper_spec_count = plan.helper_spec_count or #(plan.helper_specs or {}),
        helper_specs = plan.helper_specs or {},
        created_runtime_records = plan.created_runtime_records == true,
        materializes_records = false,
        feature_matrix = matrix,
        support = {
            preview_status = matrix.preview_status,
            live_runtime_status = matrix.live_runtime_status,
            runtime_status = "not_compiled_by_preview",
            default_enabled = matrix.default_enabled,
            deferred_reasons = matrix.deferred_reasons,
            required_flags = matrix.required_flags,
            materializes_records = false,
            launches_projectiles = false,
        },
    }

    local validation_result = validationBlock(errors, warnings)
    local result = resultBase(payload)
    result.ok = validation_result.ok
    result.success = validation_result.ok
    result.recipe_id = compiled.recipe_id
    result.canonical_version = plan.canonical_version
    result.recipe = normalized.recipe
    result.effects = normalized.effects
    result.validation = validation_result
    result.errors = validation_result.errors
    result.warnings = validation_result.warnings
    result.preview = preview
    return result
end

return ui_contract
