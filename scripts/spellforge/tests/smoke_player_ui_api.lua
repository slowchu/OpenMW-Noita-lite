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

local function finish()
    if state.finished then
        return
    end
    state.finished = true
    state.running = false
    log.info("smoke player ui api run complete")
end

local function deleteStep()
    local deleted = ui.deleteRecipe(SMOKE_SAVED_ID)
    local lifecycle = ui.getLifecycle(SMOKE_SAVED_ID) or {}
    assertLine(deleted.ok == true and deleted.deleted == true, "6 delete saved recipe succeeds")
    assertLine(deleted.cleanup and deleted.cleanup.needed == false, "6 delete avoids compiled cleanup before compile")
    assertLine(findSaved(SMOKE_SAVED_ID) == nil, "6 delete removes saved recipe")
    assertLine(lifecycle.status == generated_lifecycle.STATUS_DELETED, "6 delete marks lifecycle deleted")
    assertLine(spellbookHas(SMOKE_FAKE_SPELL_ID) == false, "6 delete leaves spellbook unpolluted")
    finish()
end

local function compileDeferredStep()
    local result = ui.requestCompileSavedRecipe(SMOKE_SAVED_ID)
    local lifecycle = ui.getLifecycle(SMOKE_SAVED_ID) or {}
    local first_error = result.errors and result.errors[1]
    assertLine(result.ok == false, "5 compile saved recipe defers")
    assertLine(first_error and first_error.code == "ui_compile_deferred", "5 compile defer returns structured code")
    assertLine(lifecycle.status == generated_lifecycle.STATUS_ERROR and lifecycle.compile_generation == 1, "5 compile defer updates lifecycle")
    assertLine(spellbookHas(SMOKE_FAKE_SPELL_ID) == false, "5 compile defer leaves spellbook unpolluted")
    deleteStep()
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
        compileDeferredStep()
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
    catalogStep()
end

return {
    eventHandlers = {
        [events.UI_CATALOG_RESULT] = ui.handleCatalogResult,
        [events.VALIDATE_RESULT] = ui.handleValidateResult,
        [events.PREVIEW_RESULT] = ui.handlePreviewResult,
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
