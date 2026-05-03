local async = require("openmw.async")
local self = require("openmw.self")
local types = require("openmw.types")

local events = require("scripts.spellforge.shared.events")
local generated_lifecycle = require("scripts.spellforge.shared.generated_spell_lifecycle")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_player_ui_api")
local dev = require("scripts.spellforge.shared.dev")
local ui = require("scripts.spellforge.player.ui")

local state = {
    scheduled = false,
    running = false,
    finished = false,
}

local SMOKE_SAVED_ID = "saved:smoke-player-ui-api"
local SMOKE_DEFERRED_ID = "saved:smoke-player-ui-api-deferred"
local SMOKE_FAKE_SPELL_ID = "spellforge_smoke_player_ui_api_frontend"

local function assertLine(ok, label, detail)
    if ok then
        log.info("PASS " .. label)
    else
        log.error("FAIL " .. label .. (detail and (" :: " .. detail) or ""))
    end
end

local function isNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function smokeRecipe()
    return {
        id = SMOKE_SAVED_ID,
        title = "Smoke Player UI API",
        recipe = {
            effects = {
                { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
            },
        },
    }
end

local function deferredRecipe()
    return {
        id = SMOKE_DEFERRED_ID,
        title = "Smoke Player UI API Deferred",
        recipe = {
            effects = {
                { id = "spellforge_bounce", params = { bounces = 5 } },
                { id = "firedamage", range = 2, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 1 },
                { id = "spellforge_timer", params = { seconds = 1.0 } },
                { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
            },
        },
    }
end

local function findSaved(saved_recipe_id)
    for _, saved in ipairs(ui.getSavedRecipes() or {}) do
        if saved and saved.id == saved_recipe_id then
            return saved
        end
    end
    return nil
end

local function spellbookHas(spell_id)
    local actor_spells = types.Actor.spells(self)
    for _, entry in pairs(actor_spells) do
        if entry and entry.id == spell_id then
            return true
        end
    end
    return false
end

local function containsValue(values, expected)
    for _, value in ipairs(values or {}) do
        if value == expected then
            return true
        end
    end
    return false
end

local function finish()
    if state.finished then
        return
    end
    state.finished = true
    state.running = false
    log.info("smoke player ui api run complete")
end

local function deferredCompileGuardStep()
    ui.deleteRecipe(SMOKE_DEFERRED_ID)

    local saved = ui.saveRecipe(deferredRecipe(), { now = 1001 })
    assertLine(saved.ok == true and saved.saved_recipe and saved.saved_recipe.id == SMOKE_DEFERRED_ID, "7 deferred save recipe succeeds")

    local preview_request = ui.previewSavedRecipe(SMOKE_DEFERRED_ID, function(result)
        local preview = result and result.preview or {}
        local matrix = preview.feature_matrix or {}
        assertLine(result and result.ok == true, "7 deferred preview saved recipe succeeds")
        assertLine(matrix.live_runtime_status == "deferred", "7 deferred preview marks runtime deferred")
        assertLine(containsValue(matrix.deferred_reasons, "bounce_timer_deferred"), "7 deferred preview gives Bounce Timer reason")

        local compile_callback_seen = false
        local compile_request = ui.requestCompileSavedRecipe(SMOKE_DEFERRED_ID, function(compile_result)
            compile_callback_seen = true
            local lifecycle = ui.getLifecycle(SMOKE_DEFERRED_ID) or {}
            assertLine(compile_result and compile_result.ok == false, "7 deferred compile blocks request")
            assertLine(compile_result and compile_result.error == "ui_compile_deferred", "7 deferred compile returns readable error")
            assertLine(lifecycle.status == generated_lifecycle.STATUS_ERROR, "7 deferred compile updates lifecycle error")
        end, { request_id = "smoke-player-ui-api-deferred-compile" })
        assertLine(compile_request and compile_request.ok == false, "7 deferred compile returned synchronously")
        assertLine(compile_callback_seen == true, "7 deferred compile callback invoked synchronously")
        ui.deleteRecipe(SMOKE_DEFERRED_ID)
        finish()
    end, { request_id = "smoke-player-ui-api-deferred-preview" })
    assertLine(preview_request.ok == true and isNonEmptyString(preview_request.request_id), "7 deferred preview request queued")
end

local function deleteStep(compiled_spell_id)
    local deleted = ui.deleteRecipe(SMOKE_SAVED_ID)
    local lifecycle = ui.getLifecycle(SMOKE_SAVED_ID) or {}
    assertLine(deleted.ok == true and deleted.deleted == true, "6 delete saved recipe succeeds")
    assertLine(deleted.cleanup and deleted.cleanup.needed == true, "6 delete requests compiled cleanup")
    assertLine(deleted.cleanup and deleted.cleanup.remove_from_spellbook_ok == true, "6 delete removes compiled spell from spellbook")
    assertLine(findSaved(SMOKE_SAVED_ID) == nil, "6 delete removes saved recipe")
    assertLine(lifecycle.status == generated_lifecycle.STATUS_DELETED, "6 delete marks lifecycle deleted")
    async:newUnsavableSimulationTimer(0.1, function()
        assertLine(compiled_spell_id == nil or spellbookHas(compiled_spell_id) == false, "6 delete leaves spellbook unpolluted")
        deferredCompileGuardStep()
    end)
end

local function compileStep()
    local request = ui.requestCompileSavedRecipe(SMOKE_SAVED_ID, function(result)
        local lifecycle = ui.getLifecycle(SMOKE_SAVED_ID) or {}
        assertLine(result and result.ok == true, "5 compile saved recipe succeeds")
        assertLine(isNonEmptyString(result and result.recipe_id), "5 compile returns recipe_id")
        assertLine(isNonEmptyString(result and result.spell_id), "5 compile returns spell_id")
        assertLine(lifecycle.status == generated_lifecycle.STATUS_COMPILED and lifecycle.compile_generation == 1, "5 compile updates lifecycle")
        assertLine(spellbookHas(result and result.spell_id) == true, "5 compile adds generated spell to spellbook")
        assertLine(spellbookHas(SMOKE_FAKE_SPELL_ID) == false, "5 compile leaves unrelated spellbook entries alone")
        deleteStep(result and result.spell_id)
    end, { request_id = "smoke-player-ui-api-compile" })
    assertLine(request.ok == true and isNonEmptyString(request.request_id), "5 compile request queued")
end

local function previewStep()
    local request = ui.previewSavedRecipe(SMOKE_SAVED_ID, function(result)
        local lifecycle = ui.getLifecycle(SMOKE_SAVED_ID) or {}
        local saved = findSaved(SMOKE_SAVED_ID) or {}
        local preview = result and result.preview or {}
        local recipe_id = result and result.recipe_id
        assertLine(result and result.ok == true, "4 preview saved recipe succeeds")
        assertLine(preview.materializes_records == false and preview.created_runtime_records == false, "4 preview remains dry-run")
        assertLine(lifecycle.status == generated_lifecycle.STATUS_PREVIEWED, "4 preview updates lifecycle")
        assertLine(isNonEmptyString(saved.last_previewed_recipe_id) and saved.last_previewed_recipe_id == recipe_id, "4 preview persists recipe_id")
        compileStep()
    end, { request_id = "smoke-player-ui-api-preview" })
    assertLine(request.ok == true and isNonEmptyString(request.request_id), "4 preview request queued")
end

local function validateStep()
    local request = ui.validateSavedRecipe(SMOKE_SAVED_ID, function(result)
        local lifecycle = ui.getLifecycle(SMOKE_SAVED_ID) or {}
        local saved = findSaved(SMOKE_SAVED_ID) or {}
        local recipe_id = result and result.recipe_id
        assertLine(result and result.ok == true, "3 validate saved recipe succeeds")
        assertLine(isNonEmptyString(recipe_id), "3 validate returns recipe_id")
        assertLine(lifecycle.status == generated_lifecycle.STATUS_VALIDATED, "3 validate updates lifecycle")
        assertLine(isNonEmptyString(saved.last_validated_recipe_id) and saved.last_validated_recipe_id == recipe_id, "3 validate persists recipe_id")
        previewStep()
    end, { request_id = "smoke-player-ui-api-validate" })
    assertLine(request.ok == true and isNonEmptyString(request.request_id), "3 validate request queued")
end

local function saveStep()
    local saved = ui.saveRecipe(smokeRecipe(), { now = 1000 })
    local stored = findSaved(SMOKE_SAVED_ID)
    local lifecycle = ui.getLifecycle(SMOKE_SAVED_ID) or {}
    assertLine(saved.ok == true and saved.saved_recipe and saved.saved_recipe.id == SMOKE_SAVED_ID, "2 save recipe succeeds")
    assertLine(stored and stored.title == "Smoke Player UI API", "2 saved recipe listed")
    assertLine(lifecycle.status == generated_lifecycle.STATUS_DRAFT, "2 save creates draft lifecycle")
    validateStep()
end

local function catalogStep()
    local request = ui.requestCatalog(function(result)
        assertLine(result and result.ok == true, "1 catalog request succeeds")
        assertLine(result and result.operator_count == 10, "1 catalog operator_count=10")
        assertLine(ui.getCachedCatalog() ~= nil, "1 catalog cached")

        local cached_callback_seen = false
        local cached = ui.requestCatalog(function(cached_result)
            cached_callback_seen = true
            assertLine(cached_result and cached_result.ok == true, "1 cached catalog callback succeeds")
        end)
        assertLine(cached.ok == true and cached.cached == true, "1 cached catalog returned synchronously")
        assertLine(cached_callback_seen == true, "1 cached catalog callback was invoked")
        saveStep()
    end, {
        force = true,
        request_id = "smoke-player-ui-api-catalog",
    })
    assertLine(request.ok == true and isNonEmptyString(request.request_id), "1 catalog request queued")
end

local function run()
    if not dev.smokeTestsEnabled() then
        return
    end
    if state.running or state.finished then
        return
    end
    state.running = true

    ui.deleteRecipe(SMOKE_SAVED_ID)
    ui.deleteRecipe(SMOKE_DEFERRED_ID)
    catalogStep()
end

return {
    eventHandlers = {
        [events.UI_CATALOG_RESULT] = ui.handleCatalogResult,
        [events.VALIDATE_RESULT] = ui.handleValidateResult,
        [events.PREVIEW_RESULT] = ui.handlePreviewResult,
        [events.COMPILE_RESULT] = ui.handleCompileResult,
    },
    engineHandlers = {
        onUpdate = function()
            if state.scheduled then
                return
            end
            state.scheduled = true
            async:newUnsavableSimulationTimer(0.25, run)
        end,
    },
}
