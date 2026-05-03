local async = require("openmw.async")
local core = require("openmw.core")
local self = require("openmw.self")
local types = require("openmw.types")

local events = require("scripts.spellforge.shared.events")
local generated_lifecycle = require("scripts.spellforge.shared.generated_spell_lifecycle")
local log = require("scripts.spellforge.shared.log").new("player.ui")
local storage = require("scripts.spellforge.player.storage")

local ui = {}

local REQUEST_TIMEOUT_SECONDS = 2.0

local state = {
    next_request_id = 1,
    pending = {},
    catalog = nil,
    validation_by_recipe_id = {},
    preview_by_recipe_id = {},
    lifecycle_by_saved_id = {},
}

local function nextRequestId(prefix)
    local id = state.next_request_id
    state.next_request_id = id + 1
    return string.format("%s-%d-%d", prefix or "ui", os.time(), id)
end

local function sendGlobal(event_name, payload)
    local p = payload or {}
    p.sender = self.object
    core.sendGlobalEvent(event_name, p)
end

local function structuredError(code, path, message)
    return {
        code = code,
        path = path or "",
        message = message,
        severity = "error",
    }
end

local function previewDeferredReasons(preview_result)
    local preview = preview_result and preview_result.preview or nil
    local matrix = preview and (preview.feature_matrix or preview.support) or {}
    if type(matrix.deferred_reasons) == "table" then
        return matrix.deferred_reasons
    end
    return {}
end

local function previewIsDeferred(preview_result)
    local preview = preview_result and preview_result.preview or nil
    local matrix = preview and (preview.feature_matrix or preview.support) or {}
    return matrix.live_runtime_status == "deferred" or #previewDeferredReasons(preview_result) > 0
end

local function deferredReasonSummary(preview_result)
    local reasons = previewDeferredReasons(preview_result)
    if #reasons > 0 then
        return table.concat(reasons, ", ")
    end
    return "runtime combo deferred"
end

local function cachedPreviewForSaved(saved)
    if type(saved) ~= "table" then
        return nil
    end
    local preview_recipe_id = saved.last_previewed_recipe_id or saved.recipe_id
    if type(preview_recipe_id) ~= "string" or preview_recipe_id == "" then
        return nil
    end
    return state.preview_by_recipe_id[preview_recipe_id]
end

local persistLifecycle

local function persistCompileResult(saved_recipe_id, payload)
    if type(saved_recipe_id) ~= "string" or saved_recipe_id == "" then
        return nil
    end
    local entry = state.lifecycle_by_saved_id[saved_recipe_id] or storage.getLifecycle(saved_recipe_id)
    if not entry then
        local saved = storage.get(saved_recipe_id)
        entry = saved and generated_lifecycle.newEntry(saved) or nil
    end
    if not entry then
        return nil
    end

    local next_entry = generated_lifecycle.applyCompileResult(entry, payload)
    state.lifecycle_by_saved_id[saved_recipe_id] = persistLifecycle(saved_recipe_id, next_entry)
    if payload and payload.ok == true and payload.recipe_id then
        storage.update(saved_recipe_id, {
            recipe_id = payload.recipe_id,
            last_validated_recipe_id = payload.recipe_id,
            last_previewed_recipe_id = payload.recipe_id,
        })
    end
    return state.lifecycle_by_saved_id[saved_recipe_id]
end

local function finishPending(request_id, payload)
    local pending = request_id and state.pending[request_id]
    if not pending then
        return false
    end
    state.pending[request_id] = nil
    if pending.timer then
        pending.timer:cancel()
    end
    if type(pending.callback) == "function" then
        pending.callback(payload)
    end
    return true
end

local function trackPending(request_id, kind, callback, meta)
    local metadata = meta or {}
    state.pending[request_id] = {
        kind = kind,
        callback = callback,
        saved_recipe_id = metadata.saved_recipe_id,
        timer = async:newUnsavableSimulationTimer(REQUEST_TIMEOUT_SECONDS, function()
            if not state.pending[request_id] then
                return
            end
            local pending = state.pending[request_id]
            state.pending[request_id] = nil
            local timeout_payload = {
                request_id = request_id,
                ok = false,
                success = false,
                errors = {
                    structuredError("ui_request_timeout", "request_id", string.format("%s request timed out", tostring(kind))),
                },
            }
            if pending.saved_recipe_id and kind == "compile" then
                timeout_payload.error = "ui_request_timeout"
                persistCompileResult(pending.saved_recipe_id, timeout_payload)
            end
            if type(pending.callback) == "function" then
                pending.callback(timeout_payload)
            end
        end),
    }
end

local function removeSpellFromSpellbook(spell_id)
    if type(spell_id) ~= "string" or spell_id == "" then
        return false, "missing spell id"
    end
    local actor_spells = types.Actor.spells(self)
    if not actor_spells or type(actor_spells.remove) ~= "function" then
        return false, "ActorSpells.remove unavailable"
    end
    local ok, err = pcall(actor_spells.remove, actor_spells, spell_id)
    if not ok then
        return false, tostring(err)
    end
    return true, nil
end

local function requestCleanup(entry, reason)
    local cleanup = entry and generated_lifecycle.cleanupPlan(entry) or nil
    if not cleanup or not cleanup.needed then
        return cleanup
    end

    local removed, remove_err = removeSpellFromSpellbook(cleanup.spell_id)
    cleanup.remove_from_spellbook = true
    cleanup.remove_from_spellbook_ok = removed == true
    cleanup.remove_from_spellbook_error = remove_err
    if not removed then
        log.warn(string.format(
            "SPELLFORGE_UI_SPELLBOOK_REMOVE_FAILED spell_id=%s reason=%s",
            tostring(cleanup.spell_id),
            tostring(remove_err)
        ))
    end

    sendGlobal(events.DELETE_COMPILED, {
        recipe_id = cleanup.recipe_id,
        spell_id = cleanup.spell_id,
        reason = reason or cleanup.reason,
    })
    return cleanup
end

function persistLifecycle(saved_recipe_id, entry)
    if type(saved_recipe_id) ~= "string" or saved_recipe_id == "" then
        return entry
    end
    local persisted = storage.putLifecycle(saved_recipe_id, entry)
    return persisted.ok and persisted.lifecycle or entry
end

local function lifecycleForSaved(saved_recipe)
    if not saved_recipe or type(saved_recipe.id) ~= "string" then
        return nil
    end
    local entry = state.lifecycle_by_saved_id[saved_recipe.id]
    if not entry then
        entry = storage.getLifecycle(saved_recipe.id) or generated_lifecycle.newEntry(saved_recipe)
        state.lifecycle_by_saved_id[saved_recipe.id] = persistLifecycle(saved_recipe.id, entry)
    end
    return entry
end

function ui.requestCatalog(callback, opts)
    local options = opts or {}
    if state.catalog and not options.force then
        if type(callback) == "function" then
            callback(state.catalog)
        end
        return {
            ok = true,
            request_id = nil,
            cached = true,
            catalog = state.catalog,
        }
    end

    local request_id = options.request_id or nextRequestId("ui-catalog")
    trackPending(request_id, "catalog", callback)
    sendGlobal(events.QUERY_UI_CATALOG, {
        request_id = request_id,
    })
    return {
        ok = true,
        request_id = request_id,
        cached = false,
    }
end

function ui.validateRecipe(recipe, callback, opts)
    local options = opts or {}
    local request_id = options.request_id or nextRequestId("ui-validate")
    trackPending(request_id, "validate", callback)
    sendGlobal(events.VALIDATE_RECIPE, {
        request_id = request_id,
        recipe = recipe,
        options = options.options,
    })
    return {
        ok = true,
        request_id = request_id,
    }
end

function ui.previewRecipe(recipe, callback, opts)
    local options = opts or {}
    local request_id = options.request_id or nextRequestId("ui-preview")
    trackPending(request_id, "preview", callback)
    sendGlobal(events.PREVIEW_RECIPE, {
        request_id = request_id,
        recipe = recipe,
        options = options.options,
    })
    return {
        ok = true,
        request_id = request_id,
    }
end

function ui.saveRecipe(input, opts)
    local saved = storage.save(input, opts)
    if saved.ok then
        local entry = storage.getLifecycle(saved.saved_recipe.id) or generated_lifecycle.newEntry(saved.saved_recipe)
        state.lifecycle_by_saved_id[saved.saved_recipe.id] = persistLifecycle(saved.saved_recipe.id, entry)
    end
    return saved
end

function ui.updateRecipe(saved_recipe_id, patch, opts)
    local updated = storage.update(saved_recipe_id, patch, opts)
    if updated.ok then
        local current = lifecycleForSaved(updated.saved_recipe) or generated_lifecycle.newEntry(updated.saved_recipe)
        local entry = generated_lifecycle.markRecipeChanged(current, updated.saved_recipe)
        state.lifecycle_by_saved_id[saved_recipe_id] = persistLifecycle(saved_recipe_id, entry)
    end
    return updated
end

function ui.deleteRecipe(saved_recipe_id)
    local saved = storage.get(saved_recipe_id)
    local entry = state.lifecycle_by_saved_id[saved_recipe_id]
    if saved and not entry then
        entry = lifecycleForSaved(saved)
    end

    local delete_entry = entry and generated_lifecycle.markDeleteRequested(entry) or nil
    if delete_entry then
        state.lifecycle_by_saved_id[saved_recipe_id] = persistLifecycle(saved_recipe_id, delete_entry)
    end

    local cleanup = requestCleanup(delete_entry, "delete_saved_recipe")

    local deleted = storage.delete(saved_recipe_id)
    if entry then
        state.lifecycle_by_saved_id[saved_recipe_id] = generated_lifecycle.markDeleted(delete_entry or entry)
    end
    deleted.cleanup = cleanup
    return deleted
end

function ui.validateSavedRecipe(saved_recipe_id, callback, opts)
    local saved = storage.get(saved_recipe_id)
    if not saved then
        local result = {
            ok = false,
            errors = {
                structuredError("saved_recipe_not_found", "saved_recipe.id", string.format("No saved recipe found for id=%s", tostring(saved_recipe_id))),
            },
        }
        if type(callback) == "function" then
            callback(result)
        end
        return result
    end

    return ui.validateRecipe(saved.recipe, function(result)
        local entry = lifecycleForSaved(saved)
        if entry then
            local next_entry = generated_lifecycle.applyValidation(entry, result)
            state.lifecycle_by_saved_id[saved.id] = persistLifecycle(saved.id, next_entry)
        end
        if result and result.ok == true and result.recipe_id then
            state.validation_by_recipe_id[result.recipe_id] = result
            storage.update(saved.id, {
                recipe_id = result.recipe_id,
                last_validated_recipe_id = result.recipe_id,
            })
        end
        if type(callback) == "function" then
            callback(result)
        end
    end, opts)
end

function ui.previewSavedRecipe(saved_recipe_id, callback, opts)
    local saved = storage.get(saved_recipe_id)
    if not saved then
        local result = {
            ok = false,
            errors = {
                structuredError("saved_recipe_not_found", "saved_recipe.id", string.format("No saved recipe found for id=%s", tostring(saved_recipe_id))),
            },
        }
        if type(callback) == "function" then
            callback(result)
        end
        return result
    end

    return ui.previewRecipe(saved.recipe, function(result)
        local entry = lifecycleForSaved(saved)
        if entry then
            local next_entry = generated_lifecycle.applyPreview(entry, result)
            state.lifecycle_by_saved_id[saved.id] = persistLifecycle(saved.id, next_entry)
        end
        if result and result.ok == true and result.recipe_id then
            state.preview_by_recipe_id[result.recipe_id] = result
            storage.update(saved.id, {
                recipe_id = result.recipe_id,
                last_previewed_recipe_id = result.recipe_id,
            })
        end
        if type(callback) == "function" then
            callback(result)
        end
    end, opts)
end

function ui.requestCompileSavedRecipe(saved_recipe_id, callback, opts)
    local options = opts or {}
    local saved = storage.get(saved_recipe_id)
    if not saved then
        local result = {
            ok = false,
            errors = {
                structuredError("saved_recipe_not_found", "saved_recipe.id", string.format("No saved recipe found for id=%s", tostring(saved_recipe_id))),
            },
        }
        if type(callback) == "function" then
            callback(result)
        end
        return result
    end

    local entry = lifecycleForSaved(saved)
    local request_id = options.request_id or nextRequestId("ui-compile")
    local cached_preview = cachedPreviewForSaved(saved)
    if previewIsDeferred(cached_preview) then
        local reason_summary = deferredReasonSummary(cached_preview)
        local result = {
            request_id = request_id,
            ok = false,
            success = false,
            recipe_id = cached_preview.recipe_id,
            saved_recipe_id = saved.id,
            error = "ui_compile_deferred",
            deferred_reasons = previewDeferredReasons(cached_preview),
            errors = {
                structuredError("deferred_runtime_combo", "preview.feature_matrix.deferred_reasons", "Create blocked: " .. reason_summary),
            },
        }
        persistCompileResult(saved.id, result)
        log.warn(string.format(
            "SPELLFORGE_UI_COMPILE_DEFERRED saved_id=%s recipe_id=%s reason=%s",
            tostring(saved.id),
            tostring(cached_preview.recipe_id),
            reason_summary
        ))
        if type(callback) == "function" then
            callback(result)
        end
        return result
    end

    local cleanup = requestCleanup(entry, "recompile_saved_recipe")
    local pending_entry = generated_lifecycle.markCompileRequested(entry, request_id)
    state.lifecycle_by_saved_id[saved.id] = persistLifecycle(saved.id, pending_entry)
    trackPending(request_id, "compile", callback, { saved_recipe_id = saved.id })
    sendGlobal(events.COMPILE_RECIPE, {
        request_id = request_id,
        actor = self,
        actor_id = self.recordId,
        saved_recipe_id = saved.id,
        title = saved.title,
        recipe = saved.recipe,
    })
    return {
        ok = true,
        request_id = request_id,
        saved_recipe_id = saved.id,
        lifecycle = state.lifecycle_by_saved_id[saved.id],
        cleanup = cleanup,
        queued = true,
    }
end

function ui.requestRecompileSavedRecipe(saved_recipe_id, callback, opts)
    return ui.requestCompileSavedRecipe(saved_recipe_id, callback, opts)
end

function ui.getCachedCatalog()
    return state.catalog
end

function ui.getSavedRecipes()
    return storage.list()
end

function ui.getLifecycle(saved_recipe_id)
    local entry = state.lifecycle_by_saved_id[saved_recipe_id] or storage.getLifecycle(saved_recipe_id)
    if entry then
        state.lifecycle_by_saved_id[saved_recipe_id] = entry
    end
    return entry
end

function ui.handleCatalogResult(payload)
    if payload and payload.ok == true then
        state.catalog = payload
    end
    finishPending(payload and payload.request_id, payload)
end

function ui.handleValidateResult(payload)
    if payload and payload.recipe_id then
        state.validation_by_recipe_id[payload.recipe_id] = payload
    end
    finishPending(payload and payload.request_id, payload)
end

function ui.handlePreviewResult(payload)
    if payload and payload.recipe_id then
        state.preview_by_recipe_id[payload.recipe_id] = payload
    end
    finishPending(payload and payload.request_id, payload)
end

function ui.handleCompileResult(payload)
    local request_id = payload and payload.request_id
    local pending = request_id and state.pending[request_id]
    if pending and pending.saved_recipe_id then
        persistCompileResult(pending.saved_recipe_id, payload)
    end
    finishPending(request_id, payload)
end

function ui.clearForTests()
    state.pending = {}
    state.catalog = nil
    state.validation_by_recipe_id = {}
    state.preview_by_recipe_id = {}
    state.lifecycle_by_saved_id = {}
    storage.clearForTests()
end

return ui
