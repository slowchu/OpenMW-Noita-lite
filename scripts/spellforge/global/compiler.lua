local core = require("openmw.core")
local types = require("openmw.types")

local validate = require("scripts.spellforge.shared.validate")
local canonicalize = require("scripts.spellforge.global.canonicalize")
local plan_cache = require("scripts.spellforge.global.plan_cache")
local records = require("scripts.spellforge.global.records")
local events = require("scripts.spellforge.shared.events")
local recipe_model = require("scripts.spellforge.shared.recipe_model")
local log = require("scripts.spellforge.shared.log").new("global.compiler")

local compiler = {}

local MARKER_EFFECT_ID_DEFAULT = "spellforge_composed"
local MARKER_EFFECT_ID_TARGET = "spellforge_marker_target"
local MARKER_EFFECT_ID_TARGET_DESTRUCTION = "spellforge_marker_target_destruction"

local KNOWN_BASE_SPELL_IDS = {}
for _, record in pairs(core.magic.spells.records) do
    if record and type(record.id) == "string" and record.id ~= "" then
        KNOWN_BASE_SPELL_IDS[record.id] = true
    end
end

local OPERATOR_EFFECT_IDS = {
    spellforge_multicast = true,
    spellforge_spread = true,
    spellforge_burst = true,
    spellforge_speed_plus = true,
    spellforge_size_plus = true,
    spellforge_chain = true,
    spellforge_bounce = true,
    spellforge_homing = true,
    spellforge_trigger = true,
    spellforge_timer = true,
}

local function cloneEffects(effects)
    local out = {}
    for i, effect in ipairs(effects or {}) do
        out[i] = {
            id = effect.id,
            range = effect.range,
            area = effect.area,
            duration = effect.duration,
            magnitudeMin = effect.magnitudeMin,
            magnitudeMax = effect.magnitudeMax,
        }
    end
    return out
end

local function cloneEffectListEffects(effects, include_params)
    local out = {}
    for i, effect in ipairs(effects or {}) do
        local cloned = {
            id = effect.id,
            range = effect.range,
            area = effect.area,
            duration = effect.duration,
            magnitudeMin = effect.magnitudeMin,
            magnitudeMax = effect.magnitudeMax,
            ui_id = effect.ui_id,
        }
        if include_params and type(effect.params) == "table" then
            cloned.params = {}
            for k, v in pairs(effect.params) do
                cloned.params[k] = v
            end
        end
        out[i] = cloned
    end
    return out
end

local function collectEmitters(nodes, out)
    -- Transitional 2.2b scaffolding:
    -- this walks prototype node trees instead of parsing ordered effect lists.
    -- TODO(2.2c): replace with effect-list parser + emitter-group binding.
    for _, node in ipairs(nodes or {}) do
        if node.kind == "emitter" then
            out[#out + 1] = node
        end
        if node.payload then
            collectEmitters(node.payload, out)
        end
    end
end

local function normalizeEffectId(effect_id)
    if effect_id == nil then
        return nil
    end
    return string.lower(tostring(effect_id))
end

local function isOperatorEffect(effect)
    return OPERATOR_EFFECT_IDS[normalizeEffectId(effect and effect.id) or ""] == true
end

local function firstRealEffect(effects)
    for _, effect in ipairs(effects or {}) do
        if type(effect) == "table" and not isOperatorEffect(effect) then
            return effect
        end
    end
    return nil
end

local function realEffectsOnly(effects)
    local out = {}
    for _, effect in ipairs(effects or {}) do
        if type(effect) == "table" and not isOperatorEffect(effect) then
            out[#out + 1] = effect
        end
    end
    return cloneEffectListEffects(out, false)
end

local function selectMarkerEffectIdFromEffect(base_effect, marker_range)
    local selected_marker = MARKER_EFFECT_ID_DEFAULT
    local presentation = "default"
    local base_effect_id_raw = base_effect and base_effect.id or nil
    local base_effect_id_norm = normalizeEffectId(base_effect_id_raw)

    if marker_range == 2 or marker_range == "target" or marker_range == "Target" then
        selected_marker = MARKER_EFFECT_ID_TARGET
        presentation = "target-generic"
        if base_effect_id_norm == "firedamage" then
            selected_marker = MARKER_EFFECT_ID_TARGET_DESTRUCTION
            presentation = "destruction"
        end
    end

    return selected_marker, presentation, base_effect_id_raw, base_effect_id_norm
end

local function selectMarkerEffectId(base, marker_range)
    local base_effect = base and base.effects and base.effects[1] or nil
    return selectMarkerEffectIdFromEffect(base_effect, marker_range)
end

local function createDraft(record_id, emitter, marker_range)
    local base = core.magic.spells.records[emitter.base_spell_id]
    -- Target shell marker is intentionally inert (invisible/silent) so vanilla
    -- target cast animation/text keys still happen while SFP launches the real
    -- payload only after late Spellcast_Success authorization.
    local marker_effect_id, presentation, base_effect_id_raw, base_effect_id_norm = selectMarkerEffectId(base, marker_range)
    local marker_effect = {
        id = marker_effect_id,
        range = marker_range or "self",
        area = 0,
        duration = 0,
        magnitudeMin = 0,
        magnitudeMax = 0,
    }

    local draft = core.magic.spells.createRecordDraft {
        id = record_id,
        name = string.format("Spellforge %s", record_id),
        cost = (base and base.cost) or 0,
        isAutocalc = false,
        effects = { marker_effect },
    }

    log.debug(string.format(
        "createRecordDraft called id=%s effect_count=%d marker=%s marker_range=%s",
        tostring(record_id),
        #(draft.effects or {}),
        tostring(marker_effect.id),
        tostring(marker_effect.range)
    ))
    log.debug(string.format(
        "shell marker selected root_base=%s effect_raw=%s effect_norm=%s marker=%s presentation=%s range=%s",
        tostring(emitter and emitter.base_spell_id),
        tostring(base_effect_id_raw),
        tostring(base_effect_id_norm),
        tostring(marker_effect.id),
        tostring(presentation),
        tostring(marker_effect.range)
    ))
    return draft
end

local function safeTitle(value)
    local title = tostring(value or "")
    if title == "" then
        return "Spellforge Spell"
    end
    if #title > 48 then
        return string.sub(title, 1, 48)
    end
    return title
end

local function sanitizeIdPart(value)
    local text = string.lower(tostring(value or ""))
    text = string.gsub(text, "[^%w_]+", "_")
    text = string.gsub(text, "^_+", "")
    text = string.gsub(text, "_+$", "")
    if text == "" then
        return tostring(os.time())
    end
    if #text > 32 then
        return string.sub(text, 1, 32)
    end
    return text
end

local function createEffectListFrontendDraft(record_id, title, effects, marker_range)
    local real_effect = firstRealEffect(effects)
    local marker_effect_id, presentation, base_effect_id_raw, base_effect_id_norm = selectMarkerEffectIdFromEffect(real_effect, marker_range)
    local marker_effect = {
        id = marker_effect_id,
        range = marker_range or 0,
        area = 0,
        duration = 0,
        magnitudeMin = 0,
        magnitudeMax = 0,
    }

    local draft = core.magic.spells.createRecordDraft {
        id = record_id,
        name = safeTitle(title),
        cost = 0,
        isAutocalc = false,
        effects = { marker_effect },
    }

    log.debug(string.format(
        "effect-list frontend marker selected effect_raw=%s effect_norm=%s marker=%s presentation=%s range=%s",
        tostring(base_effect_id_raw),
        tostring(base_effect_id_norm),
        tostring(marker_effect.id),
        tostring(presentation),
        tostring(marker_effect.range)
    ))
    return draft
end

local function addToSpellbook(actor, engine_id)
    local actor_spells = types.Actor.spells(actor)
    log.debug(string.format("ActorSpells:add before actor=%s engine_id=%s", tostring(actor and actor.recordId), tostring(engine_id)))
    log.info(string.format("ActorSpells:add called actor=%s engine_id=%s", tostring(actor and actor.recordId), tostring(engine_id)))
    local ok, add_err = pcall(actor_spells.add, actor_spells, engine_id)
    if not ok then
        log.error(string.format("compiler ActorSpells:add failed actor=%s engine_id=%s err=%s", tostring(actor and actor.recordId), tostring(engine_id), tostring(add_err)))
        return false, add_err
    end
    log.debug(string.format("ActorSpells:add after actor=%s engine_id=%s", tostring(actor and actor.recordId), tostring(engine_id)))
    log.info("ActorSpells:add completed")
    return true, nil
end

local function rootRealEffectCount(entry)
    if type(entry) ~= "table" then
        return 0
    end
    local first = entry.node_metadata and entry.node_metadata[1]
    if not first or type(first.real_effects) ~= "table" then
        return 0
    end
    return #first.real_effects
end

local function firstErrorMessage(result)
    local first = result and result.errors and result.errors[1]
    return tostring((first and (first.message or first.error)) or (result and (result.error or result.error_message)) or "unknown")
end

local function markerRangeForPlan(plan, effects)
    local group = plan and plan.groups and plan.groups[1] or nil
    if group and group.range ~= nil then
        return group.range
    end
    local first = firstRealEffect(effects)
    if first and first.range ~= nil then
        return first.range
    end
    return 0
end

function compiler.compileEffectList(actor, recipe, request_id, opts)
    local options = opts or {}
    local normalized = recipe_model.normalize(recipe, options.recipe_options)
    if not normalized.ok then
        log.info(string.format("effect-list compile validation failed error_count=%d", #(normalized.errors or {})))
        return {
            request_id = request_id,
            ok = false,
            success = false,
            errors = normalized.errors,
            warnings = normalized.warnings,
            error = firstErrorMessage(normalized),
        }
    end

    local compiled = plan_cache.compileOrGet(normalized.effects, options)
    if not compiled.ok then
        log.info(string.format("effect-list compile plan failed recipe_id=%s reason=%s", tostring(compiled.recipe_id), firstErrorMessage(compiled)))
        return {
            request_id = request_id,
            ok = false,
            success = false,
            recipe_id = compiled.recipe_id,
            errors = compiled.errors,
            warnings = compiled.warnings,
            error = firstErrorMessage(compiled),
        }
    end

    local attached = plan_cache.attachHelperRecords(compiled.recipe_id, options)
    if not attached.ok then
        log.info(string.format("effect-list compile helper materialization failed recipe_id=%s reason=%s", tostring(compiled.recipe_id), firstErrorMessage(attached)))
        return {
            request_id = request_id,
            ok = false,
            success = false,
            recipe_id = compiled.recipe_id,
            errors = attached.errors,
            warnings = attached.warnings,
            error = firstErrorMessage(attached),
        }
    end

    local cached = records.getByRecipeId(compiled.recipe_id)
    if cached and cached.frontend_spell_id then
        local added_ok, add_err = addToSpellbook(actor, cached.frontend_spell_id)
        if not added_ok then
            return { request_id = request_id, ok = false, success = false, recipe_id = compiled.recipe_id, error = tostring(add_err) }
        end
        log.info(string.format(
            "SPELLFORGE_UI_COMPILE_OK saved_id=%s recipe_id=%s spell_id=%s reused=true helpers=%s slots=%s",
            tostring(options.saved_recipe_id),
            tostring(compiled.recipe_id),
            tostring(cached.frontend_spell_id),
            tostring(attached.record_count or 0),
            tostring(attached.plan and attached.plan.slot_count)
        ))
        return {
            request_id = request_id,
            ok = true,
            success = true,
            recipe_id = compiled.recipe_id,
            spell_id = cached.frontend_spell_id,
            frontend_logical_id = cached.frontend_logical_id,
            generated_spell_ids = cached.generated_spell_ids,
            generated_engine_spell_ids = cached.generated_engine_spell_ids,
            helper_record_count = attached.record_count,
            slot_count = attached.plan and attached.plan.slot_count or nil,
            reused = true,
            source_kind = "effect_list",
        }
    end

    local frontend_logical_id = string.format(
        "spellforge_ui_%s_%s",
        tostring(compiled.recipe_id),
        sanitizeIdPart(request_id)
    )
    local marker_range = markerRangeForPlan(attached.plan or compiled.plan, normalized.effects)
    local title = options.title or recipe.title or recipe.name or "Spellforge Spell"
    local draft = createEffectListFrontendDraft(frontend_logical_id, title, normalized.effects, marker_range)
    local created_record, create_error = records.createRecord(draft)
    if create_error then
        log.error(string.format("effect-list frontend createRecord failed logical_id=%s err=%s", tostring(frontend_logical_id), tostring(create_error)))
        return {
            request_id = request_id,
            ok = false,
            success = false,
            recipe_id = compiled.recipe_id,
            error = tostring(create_error),
            errors = { { message = tostring(create_error) } },
        }
    end

    local frontend_engine_id = created_record and created_record.id or nil
    if type(frontend_engine_id) ~= "string" or frontend_engine_id == "" then
        return {
            request_id = request_id,
            ok = false,
            success = false,
            recipe_id = compiled.recipe_id,
            error = "world.createRecord returned frontend record without id",
            errors = { { message = "world.createRecord returned frontend record without id" } },
        }
    end

    local added_ok, add_err = addToSpellbook(actor, frontend_engine_id)
    if not added_ok then
        return { request_id = request_id, ok = false, success = false, recipe_id = compiled.recipe_id, error = tostring(add_err) }
    end

    local helper_engine_ids = {}
    for _, helper in ipairs(attached.plan and attached.plan.helper_records or {}) do
        if helper and type(helper.engine_id) == "string" then
            helper_engine_ids[#helper_engine_ids + 1] = helper.engine_id
        end
    end
    local generated_engine_spell_ids = { frontend_engine_id }
    for _, helper_id in ipairs(helper_engine_ids) do
        generated_engine_spell_ids[#generated_engine_spell_ids + 1] = helper_id
    end

    records.put(compiled.recipe_id, {
        canonical = compiled.canonical,
        source_kind = "effect_list",
        frontend_name = safeTitle(title),
        frontend_logical_id = frontend_logical_id,
        frontend_spell_id = frontend_engine_id,
        generated_spell_ids = { frontend_logical_id },
        generated_engine_spell_ids = generated_engine_spell_ids,
        node_metadata = {
            {
                logical_id = frontend_logical_id,
                engine_id = frontend_engine_id,
                marker_range = marker_range,
                real_effects = realEffectsOnly(normalized.effects),
                effect_list = cloneEffectListEffects(normalized.effects, true),
            },
        },
        recipe = normalized.recipe,
    })

    log.info(string.format(
        "SPELLFORGE_UI_COMPILE_OK saved_id=%s recipe_id=%s spell_id=%s reused=false helpers=%s slots=%s",
        tostring(options.saved_recipe_id),
        tostring(compiled.recipe_id),
        tostring(frontend_engine_id),
        tostring(attached.record_count or 0),
        tostring(attached.plan and attached.plan.slot_count)
    ))

    return {
        request_id = request_id,
        ok = true,
        success = true,
        recipe_id = compiled.recipe_id,
        spell_id = frontend_engine_id,
        frontend_logical_id = frontend_logical_id,
        generated_spell_ids = { frontend_logical_id },
        generated_engine_spell_ids = generated_engine_spell_ids,
        helper_record_count = attached.record_count,
        slot_count = attached.plan and attached.plan.slot_count or nil,
        reused = false,
        source_kind = "effect_list",
        root_real_effect_count = #realEffectsOnly(normalized.effects),
    }
end

function compiler.compile(actor, recipe, request_id, opts)
    if type(recipe) == "table" and type(recipe.nodes) ~= "table" then
        return compiler.compileEffectList(actor, recipe, request_id, opts)
    end

    local node_count = type(recipe) == "table" and type(recipe.nodes) == "table" and #recipe.nodes or 0
    local root_base_spell_id = nil
    if type(recipe) == "table" and type(recipe.nodes) == "table" and type(recipe.nodes[1]) == "table" then
        root_base_spell_id = recipe.nodes[1].base_spell_id
    end
    log.debug(string.format("compile entry request_id=%s actor=%s nodes=%d", tostring(request_id), tostring(actor and actor.recordId), node_count))
    log.info(string.format("compile requested root_base_spell_id=%s node_count=%d", tostring(root_base_spell_id), node_count))

    local marker_range = "self"
    local root_base = root_base_spell_id and core.magic.spells.records[root_base_spell_id] or nil
    local root_effect = root_base and root_base.effects and root_base.effects[1] or nil
    if root_effect and root_effect.range ~= nil then
        marker_range = root_effect.range
    end

    local checked = validate.run(recipe, {
        known_base_spell_ids = KNOWN_BASE_SPELL_IDS,
    })
    if not checked.ok then
        log.info(string.format("validation failed error_count=%d", #(checked.errors or {})))
        return { request_id = request_id, ok = false, errors = checked.errors }
    end
    log.info(string.format("validation passed node_count=%d", node_count))

    local canonical = canonicalize.run(recipe)
    -- TODO(2.2c): cache compiled plans by canonical effect-list recipe hash/version,
    -- distinct from this transitional generated-record metadata cache.
    local cached = nil
    if not debug_marker_range_from_root then
        cached = records.getByRecipeId(canonical.recipe_id)
    end
    if cached then
        local added_ok, add_err = addToSpellbook(actor, cached.frontend_spell_id)
        if not added_ok then
            return { request_id = request_id, ok = false, error = tostring(add_err) }
        end
        log.info(string.format(
            "cache hit recipe_id=%s frontend_logical_id=%s frontend_engine_id=%s",
            tostring(canonical.recipe_id),
            tostring(cached.frontend_logical_id),
            tostring(cached.frontend_spell_id)
        ))
        local result_payload = {
            request_id = request_id,
            ok = true,
            recipe_id = canonical.recipe_id,
            spell_id = cached.frontend_spell_id,
            reused = true,
            root_real_effect_count = rootRealEffectCount(cached),
        }
        log.info(string.format(
            "compile result payload: spell_id=%s logical_id=%s engine_id=%s",
            tostring(result_payload.spell_id),
            tostring(cached.frontend_logical_id),
            tostring(cached.frontend_spell_id)
        ))
        return result_payload
    end

    local emitters = {}
    collectEmitters(recipe.nodes, emitters)
    if #emitters == 0 then
        return { request_id = request_id, ok = false, error = "Recipe has no emitter nodes" }
    end

    local generated_spell_ids = {}
    local generated_engine_spell_ids = {}
    local node_metadata = {}
    -- TODO(2.2c): allocate per-emission helper records up to MAX_PROJECTILES_PER_CAST
    -- as structural cookies for unambiguous hit routing.

    for idx, emitter in ipairs(emitters) do
        local logical_id = string.format("spellforge_%s_n%d", canonical.recipe_id, idx - 1)
        local draft = createDraft(logical_id, emitter, marker_range)
        log.debug(string.format("world.createRecord before logical_id=%s draft=%s", tostring(logical_id), tostring(draft)))
        log.info(string.format("world.createRecord called logical_id=%s", tostring(logical_id)))
        local created_record, create_error = records.createRecord(draft)
        if create_error then
            log.error(string.format("compiler world.createRecord failed logical_id=%s err=%s", tostring(logical_id), tostring(create_error)))
            return { request_id = request_id, ok = false, errors = { { message = tostring(create_error) } } }
        end
        local engine_id = created_record and created_record.id or nil
        log.info(string.format(
            "world.createRecord ids draft_id=%s engine_id=%s record_obj=%s",
            tostring(draft and draft.id),
            tostring(engine_id),
            tostring(created_record)
        ))
        log.debug(string.format("world.createRecord after logical_id=%s return=%s", tostring(logical_id), tostring(created_record)))
        if type(engine_id) ~= "string" or engine_id == "" then
            log.error(string.format("compiler world.createRecord missing engine_id logical_id=%s", tostring(logical_id)))
            return { request_id = request_id, ok = false, errors = { { message = "world.createRecord returned record without id" } } }
        end

        local base = core.magic.spells.records[emitter.base_spell_id]
        generated_spell_ids[#generated_spell_ids + 1] = logical_id
        generated_engine_spell_ids[#generated_engine_spell_ids + 1] = engine_id
        node_metadata[#node_metadata + 1] = {
            logical_id = logical_id,
            engine_id = engine_id,
            base_spell_id = emitter.base_spell_id,
            real_effects = cloneEffects(base and base.effects or {}),
        }
    end

    local frontend_logical_spell_id = generated_spell_ids[1]
    local frontend_spell_id = generated_engine_spell_ids[1]
    local added_ok, add_err = addToSpellbook(actor, frontend_spell_id)
    if not added_ok then
        return { request_id = request_id, ok = false, error = tostring(add_err) }
    end

    records.put(canonical.recipe_id, {
        canonical = canonical.canonical,
        frontend_logical_id = frontend_logical_spell_id,
        frontend_spell_id = frontend_spell_id,
        generated_spell_ids = generated_spell_ids,
        generated_engine_spell_ids = generated_engine_spell_ids,
        node_metadata = node_metadata,
        recipe = recipe,
    })

    log.info(string.format(
        "compiled recipe_id=%s frontend_logical_id=%s frontend_engine_id=%s",
        canonical.recipe_id,
        tostring(frontend_logical_spell_id),
        tostring(frontend_spell_id)
    ))

    local result_payload = {
        request_id = request_id,
        ok = true,
        recipe_id = canonical.recipe_id,
        spell_id = frontend_spell_id,
        reused = false,
        root_real_effect_count = rootRealEffectCount({ node_metadata = node_metadata }),
    }
    log.info(string.format(
        "compile result payload: spell_id=%s logical_id=%s engine_id=%s",
        tostring(result_payload.spell_id),
        tostring(frontend_logical_spell_id),
        tostring(frontend_spell_id)
    ))
    return result_payload
end

function compiler.handleCompileEvent(payload)
    if not payload or not payload.actor then
        return { request_id = payload and payload.request_id, ok = false, success = false, error_message = "Missing actor", error = "Missing actor" }
    end

    local ok, result_or_err = pcall(compiler.compile, payload.actor, payload.recipe, payload.request_id, {
        saved_recipe_id = payload.saved_recipe_id,
        title = payload.title,
        recipe_options = payload.recipe_options,
        limits = payload.limits,
    })
    if not ok then
        local err = tostring(result_or_err)
        log.error(string.format("handleCompileEvent failed request_id=%s err=%s", tostring(payload and payload.request_id), err))
        return {
            request_id = payload and payload.request_id,
            ok = false,
            success = false,
            error_message = err,
            error = err,
            errors = { { message = err } },
        }
    end

    return result_or_err
end

function compiler.emitResult(sender, result)
    if sender and type(sender.sendEvent) == "function" then
        sender:sendEvent(events.COMPILE_RESULT, result)
    end
end

return compiler
