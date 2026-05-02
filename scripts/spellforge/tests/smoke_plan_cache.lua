local plan_cache = require("scripts.spellforge.global.plan_cache")
local generated_lifecycle = require("scripts.spellforge.shared.generated_spell_lifecycle")
local recipe_model = require("scripts.spellforge.shared.recipe_model")
local saved_recipe_model = require("scripts.spellforge.shared.saved_recipe_model")
local ui_catalog = require("scripts.spellforge.global.ui_catalog")
local ui_contract = require("scripts.spellforge.global.ui_contract")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_plan_cache")
local dev = require("scripts.spellforge.shared.dev")

local state = {
    ran = false,
}

local function assertLine(ok, label, detail)
    if ok then
        log.info("PASS " .. label)
    else
        log.error("FAIL " .. label .. (detail and (" :: " .. detail) or ""))
    end
end

local function isNonEmptyString(v)
    return type(v) == "string" and v ~= ""
end

local function containsValue(values, expected)
    for _, value in ipairs(values or {}) do
        if value == expected then
            return true
        end
    end
    return false
end

local function run()
    if not dev.smokeTestsEnabled() then
        return
    end
    plan_cache.clearForTests()

    local fire_target = {
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    }

    local first = plan_cache.compileOrGet(fire_target)
    local recipe_id = first and first.recipe_id

    assertLine(first.ok == true and first.reused == false, "1 compile new plan")
    assertLine(isNonEmptyString(recipe_id), "1 recipe_id is non-empty")
    assertLine(first.plan and first.plan.bounds and first.plan.bounds.group_count == 1, "1 group_count is 1")
    assertLine(plan_cache.has(recipe_id), "1 plan exists in cache")

    local second = plan_cache.compileOrGet(fire_target)
    assertLine(second.ok == true and second.reused == true, "2 recompile same plan reused")
    assertLine(second.recipe_id == recipe_id, "2 recipe_id stable across recompiles")

    local changed_magnitude = {
        { id = "firedamage", range = 2, magnitudeMin = 11, magnitudeMax = 11, area = 0, duration = 1 },
    }
    local third = plan_cache.compileOrGet(changed_magnitude)
    assertLine(third.ok == true and third.reused == false, "3 changed magnitude compiles new plan")
    assertLine(third.recipe_id ~= recipe_id, "3 changed magnitude yields different recipe_id")

    local invalid = {
        { id = "spellforge_trigger" },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    }
    local invalid_result = plan_cache.compileOrGet(invalid)
    assertLine(invalid_result.ok == false, "4 parser failure returns ok=false")
    assertLine(type(invalid_result.errors) == "table" and #invalid_result.errors > 0, "4 parser failure has readable errors")
    assertLine(plan_cache.has(invalid_result.recipe_id) == false, "4 parser failure not cached as success")

    local multicast = {
        { id = "spellforge_multicast", params = { count = 3 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    }
    local multicast_result = plan_cache.compileOrGet(multicast)
    local multicast_bounds = multicast_result.plan and multicast_result.plan.bounds or {}
    assertLine(multicast_result.ok == true, "5 multicast compile succeeds")
    assertLine(multicast_bounds.has_multicast == true, "5 multicast summary has_multicast=true")
    assertLine(multicast_bounds.static_emission_count == 3, "5 multicast summary static_emission_count=3")

    local trigger = {
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
        { id = "spellforge_trigger" },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    }
    local trigger_result = plan_cache.compileOrGet(trigger)
    local trigger_bounds = trigger_result.plan and trigger_result.plan.bounds or {}
    local trigger_group = trigger_result.plan and trigger_result.plan.groups and trigger_result.plan.groups[1]
    assertLine(trigger_result.ok == true, "6 trigger compile succeeds")
    assertLine(trigger_bounds.has_trigger == true, "6 trigger summary has_trigger=true")
    assertLine(trigger_group and trigger_group.payload and type(trigger_group.payload.effects) == "table", "6 trigger payload metadata stored")

    local pattern = {
        { id = "spellforge_burst", params = { count = 5 } },
        { id = "spellforge_multicast", params = { count = 5 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    }
    local pattern_result = plan_cache.compileOrGet(pattern)
    local pattern_bounds = pattern_result.plan and pattern_result.plan.bounds or {}
    assertLine(pattern_result.ok == true, "7 pattern compile succeeds")
    assertLine(pattern_bounds.has_pattern == true, "7 pattern summary has_pattern=true")
    assertLine(pattern_bounds.has_multicast == true, "7 pattern summary has_multicast=true")

    plan_cache.clearForTests()
    assertLine(plan_cache.has(recipe_id) == false, "8 cache clear for tests")

    local normalized_recipe = recipe_model.normalize({
        title = "Smoke UI Recipe",
        effects = fire_target,
    })
    assertLine(normalized_recipe.ok == true, "9 ui recipe normalize succeeds")
    assertLine(normalized_recipe.recipe and normalized_recipe.recipe.schema_version == recipe_model.SCHEMA_VERSION, "9 ui recipe schema_version set")
    assertLine(normalized_recipe.effects and normalized_recipe.effects[1] and isNonEmptyString(normalized_recipe.effects[1].ui_id), "9 ui recipe assigns ui_id")

    local validate_result = ui_contract.validateRecipe({
        request_id = "smoke-ui-validate",
        recipe = normalized_recipe.recipe,
    })
    assertLine(validate_result.ok == true and validate_result.validation and validate_result.validation.ok == true, "10 ui validate succeeds")
    assertLine(isNonEmptyString(validate_result.recipe_id), "10 ui validate returns recipe_id")
    assertLine(validate_result.schema_version == recipe_model.SCHEMA_VERSION, "10 ui validate returns schema_version")

    local invalid_ui = ui_contract.validateRecipe({
        request_id = "smoke-ui-invalid",
        recipe = {
            effects = invalid,
        },
    })
    local invalid_issue = invalid_ui.errors and invalid_ui.errors[1]
    assertLine(invalid_ui.ok == false, "11 ui validate invalid recipe fails")
    assertLine(invalid_issue and isNonEmptyString(invalid_issue.code), "11 ui validate error has code")
    assertLine(invalid_issue and invalid_issue.severity == "error", "11 ui validate error has severity")
    assertLine(invalid_issue and isNonEmptyString(invalid_issue.path), "11 ui validate error has path")

    local preview_result = ui_contract.previewRecipe({
        request_id = "smoke-ui-preview",
        recipe = {
            title = "Smoke Trigger Preview",
            effects = trigger,
        },
    })
    local preview = preview_result.preview or {}
    assertLine(preview_result.ok == true, "12 ui preview succeeds")
    assertLine(preview.bounds and preview.bounds.has_trigger == true, "12 ui preview keeps trigger bounds")
    assertLine((preview.slot_count or 0) >= 2, "12 ui preview plans trigger payload slots")
    assertLine(preview.helper_spec_count == preview.slot_count, "12 ui preview helper specs match slots")
    assertLine(preview.materializes_records == false and preview.created_runtime_records == false, "12 ui preview does not materialize records")
    assertLine(preview.feature_matrix and preview.feature_matrix.version == "spellforge-feature-matrix-v1", "13 ui preview returns feature matrix")
    assertLine(containsValue(preview.feature_matrix and preview.feature_matrix.active_feature_ids, "trigger"), "13 ui feature matrix detects Trigger")
    assertLine(containsValue(preview.feature_matrix and preview.feature_matrix.required_flags, "SpellforgeDev.enable_live_trigger"), "13 ui feature matrix lists Trigger gate")

    local bounce_timer = {
        { id = "spellforge_bounce", params = { bounces = 3 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
        { id = "spellforge_timer", params = { seconds = 1.0 } },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    }
    local bounce_timer_preview = ui_contract.previewRecipe({
        request_id = "smoke-ui-feature-matrix-deferred",
        recipe = {
            title = "Smoke Bounce Timer Preview",
            effects = bounce_timer,
        },
    })
    local bounce_timer_matrix = bounce_timer_preview.preview and bounce_timer_preview.preview.feature_matrix or {}
    assertLine(bounce_timer_preview.ok == true, "14 ui feature matrix preview accepts deferred combo")
    assertLine(bounce_timer_matrix.live_runtime_status == "deferred", "14 ui feature matrix marks Bounce+Timer deferred")
    assertLine(containsValue(bounce_timer_matrix.deferred_reasons, "bounce_timer_deferred"), "14 ui feature matrix gives Bounce+Timer reason")

    local catalog = ui_catalog.build({ request_id = "smoke-ui-catalog" })
    assertLine(catalog.ok == true, "15 ui catalog succeeds")
    assertLine(catalog.catalog_version == "spellforge-ui-catalog-v1", "15 ui catalog version set")
    assertLine(catalog.schema_version == recipe_model.SCHEMA_VERSION, "15 ui catalog schema_version set")
    assertLine(catalog.operator_count == 10, "15 ui catalog operator_count=10")
    assertLine(catalog.operators_by_opcode and catalog.operators_by_opcode.Multicast and catalog.operators_by_opcode.Multicast.parameters.count.max ~= nil, "15 ui catalog exposes Multicast parameters")
    assertLine(catalog.operator_opcode_by_effect_id and catalog.operator_opcode_by_effect_id.spellforge_trigger == "Trigger", "15 ui catalog maps Trigger effect id")
    assertLine(catalog.feature_matrix and catalog.feature_matrix.version == "spellforge-feature-matrix-v1", "15 ui catalog includes feature matrix catalog")
    assertLine(catalog.events and catalog.events.preview_recipe == "Spellforge_PreviewRecipe", "15 ui catalog includes preview event name")
    assertLine(catalog.defaults and catalog.defaults.preview_launches_projectiles == false, "15 ui catalog marks preview dry-run")

    local saved_result = saved_recipe_model.create({
        id = "saved-smoke-1",
        title = "Saved Smoke",
        recipe = {
            effects = fire_target,
        },
    }, { now = 1000 })
    local saved_recipe = saved_result.saved_recipe or {}
    assertLine(saved_result.ok == true, "16 saved recipe create succeeds")
    assertLine(saved_recipe.schema_version == saved_recipe_model.SCHEMA_VERSION, "16 saved recipe schema_version set")
    assertLine(saved_recipe.title == "Saved Smoke", "16 saved recipe title preserved")
    assertLine(saved_recipe.recipe and saved_recipe.recipe.effects and isNonEmptyString(saved_recipe.recipe.effects[1].ui_id), "16 saved recipe effect ui_id assigned")

    local unsupported_saved = saved_recipe_model.create({
        id = "saved-smoke-bad-version",
        schema_version = "spellforge-saved-recipe-v0",
        recipe = {
            effects = fire_target,
        },
    })
    local unsupported_issue = unsupported_saved.errors and unsupported_saved.errors[1]
    assertLine(unsupported_saved.ok == false, "16 saved recipe unsupported version fails")
    assertLine(unsupported_issue and unsupported_issue.code == "unsupported_saved_recipe_schema_version", "16 saved recipe unsupported version has code")

    local lifecycle_entry = generated_lifecycle.newEntry(saved_recipe, { now = 1000 })
    local lifecycle_validated = generated_lifecycle.applyValidation(lifecycle_entry, validate_result, { now = 1001 })
    local lifecycle_previewed = generated_lifecycle.applyPreview(lifecycle_validated, preview_result, { now = 1002 })
    local lifecycle_pending = generated_lifecycle.markCompileRequested(lifecycle_previewed, "smoke-compile", { now = 1003 })
    local lifecycle_compiled = generated_lifecycle.applyCompileResult(lifecycle_pending, {
        ok = true,
        recipe_id = preview_result.recipe_id,
        spell_id = "spellforge_smoke_frontend",
    }, { now = 1004 })
    local changed_saved = saved_recipe_model.update(saved_recipe, {
        recipe_id = "changed-smoke-recipe-id",
    }, { now = 1005 })
    local lifecycle_stale = generated_lifecycle.markRecipeChanged(lifecycle_compiled, changed_saved.saved_recipe, { now = 1006 })
    local cleanup = generated_lifecycle.cleanupPlan(lifecycle_stale)
    local lifecycle_deleted = generated_lifecycle.markDeleted(lifecycle_stale, { now = 1007 })
    local unsupported_lifecycle = generated_lifecycle.validateEntry({
        lifecycle_version = "spellforge-generated-spell-lifecycle-v0",
    })
    local unsupported_lifecycle_issue = unsupported_lifecycle.errors and unsupported_lifecycle.errors[1]
    assertLine(lifecycle_entry.status == generated_lifecycle.STATUS_DRAFT, "17 lifecycle starts draft")
    assertLine(lifecycle_validated.status == generated_lifecycle.STATUS_VALIDATED, "17 lifecycle stores validation")
    assertLine(lifecycle_previewed.status == generated_lifecycle.STATUS_PREVIEWED, "17 lifecycle stores preview")
    assertLine(lifecycle_pending.status == generated_lifecycle.STATUS_COMPILE_PENDING and lifecycle_pending.compile_generation == 1, "17 lifecycle marks compile pending")
    assertLine(lifecycle_compiled.status == generated_lifecycle.STATUS_COMPILED and lifecycle_compiled.frontend_spell_id == "spellforge_smoke_frontend", "17 lifecycle stores compile result")
    assertLine(lifecycle_stale.status == generated_lifecycle.STATUS_STALE and lifecycle_stale.cleanup_required == true, "17 lifecycle marks recipe changes stale")
    assertLine(cleanup.needed == true and cleanup.spell_id == "spellforge_smoke_frontend" and cleanup.delete_compiled_record == true, "17 lifecycle cleanup plan targets compiled spell")
    assertLine(lifecycle_deleted.status == generated_lifecycle.STATUS_DELETED and lifecycle_deleted.cleanup_required == false, "17 lifecycle marks deleted")
    assertLine(unsupported_lifecycle.ok == false and unsupported_lifecycle_issue and unsupported_lifecycle_issue.code == "unsupported_lifecycle_version", "17 lifecycle unsupported version fails")

    log.info("smoke plan cache run complete")
end

return {
    engineHandlers = {
        onUpdate = function()
            if state.ran then
                return
            end
            state.ran = true
            run()
        end,
    },
}
