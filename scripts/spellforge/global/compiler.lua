local core = require("openmw.core")
local types = require("openmw.types")

local validate = require("scripts.spellforge.shared.validate")
local canonicalize = require("scripts.spellforge.global.canonicalize")
local records = require("scripts.spellforge.global.records")
local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("global.compiler")

local compiler = {}

local MARKER_EFFECT_ID = "spellforge_composed"

local KNOWN_BASE_SPELL_IDS = {}
for _, record in pairs(core.magic.spells.records) do
    if record and type(record.id) == "string" and record.id ~= "" then
        KNOWN_BASE_SPELL_IDS[record.id] = true
    end
end

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

local function collectEmitters(nodes, out)
    for _, node in ipairs(nodes or {}) do
        if node.kind == "emitter" then
            out[#out + 1] = node
        end
        if node.payload then
            collectEmitters(node.payload, out)
        end
    end
end

local function createDraft(record_id, emitter)
    local base = core.magic.spells.records[emitter.base_spell_id]
    local marker_effect = {
        id = MARKER_EFFECT_ID,
        range = "self",
        area = 0,
        duration = 0,
        magnitudeMin = 0,
        magnitudeMax = 0,
    }

    local marker_ok, marker_draft_or_err = pcall(core.magic.spells.createRecordDraft, {
        id = record_id,
        name = string.format("Spellforge %s", record_id),
        cost = (base and base.cost) or 0,
        isAutocalc = false,
        effects = { marker_effect },
    })

    if marker_ok then
        local marker_draft = marker_draft_or_err
        log.info(string.format("createRecordDraft called id=%s effect_count=%d marker=%s", tostring(record_id), #(marker_draft.effects or {}), MARKER_EFFECT_ID))
        return marker_draft, true, nil
    end

    log.error(string.format("createRecordDraft marker failed id=%s marker=%s err=%s", tostring(record_id), MARKER_EFFECT_ID, tostring(marker_draft_or_err)))

    local fallback_ok, fallback_draft_or_err = pcall(core.magic.spells.createRecordDraft, {
        id = record_id,
        name = string.format("Spellforge %s", record_id),
        cost = (base and base.cost) or 0,
        isAutocalc = false,
        effects = base and base.effects or {},
    })
    if not fallback_ok then
        log.error(string.format("createRecordDraft fallback failed id=%s err=%s", tostring(record_id), tostring(fallback_draft_or_err)))
        return nil, false, tostring(fallback_draft_or_err)
    end

    local fallback_draft = fallback_draft_or_err
    log.warn(string.format("createRecordDraft fell back to base effects id=%s effect_count=%d", tostring(record_id), #(fallback_draft.effects or {})))
    return fallback_draft, false, nil
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

function compiler.compile(actor, recipe, request_id)
    local node_count = type(recipe) == "table" and type(recipe.nodes) == "table" and #recipe.nodes or 0
    local root_base_spell_id = nil
    if type(recipe) == "table" and type(recipe.nodes) == "table" and type(recipe.nodes[1]) == "table" then
        root_base_spell_id = recipe.nodes[1].base_spell_id
    end
    log.debug(string.format("compile entry request_id=%s actor=%s nodes=%d", tostring(request_id), tostring(actor and actor.recordId), node_count))
    log.info(string.format("compile requested root_base_spell_id=%s node_count=%d", tostring(root_base_spell_id), node_count))

    local checked = validate.run(recipe, {
        known_base_spell_ids = KNOWN_BASE_SPELL_IDS,
    })
    if not checked.ok then
        log.info(string.format("validation failed error_count=%d", #(checked.errors or {})))
        return { request_id = request_id, ok = false, errors = checked.errors }
    end
    log.info(string.format("validation passed node_count=%d", node_count))

    local canonical = canonicalize.run(recipe)
    local cached = records.getByRecipeId(canonical.recipe_id)
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
            marker_effect_applied = cached.marker_effect_applied == true,
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
    local marker_effect_applied = true

    for idx, emitter in ipairs(emitters) do
        local logical_id = string.format("spellforge_%s_n%d", canonical.recipe_id, idx - 1)
        local draft, used_marker, draft_error = createDraft(logical_id, emitter)
        if not draft then
            return { request_id = request_id, ok = false, errors = { { message = tostring(draft_error or "createRecordDraft failed") } } }
        end
        if used_marker ~= true then
            marker_effect_applied = false
        end
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
        marker_effect_applied = marker_effect_applied,
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
        marker_effect_applied = marker_effect_applied,
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
        return { request_id = payload and payload.request_id, ok = false, error = "Missing actor" }
    end
    return compiler.compile(payload.actor, payload.recipe, payload.request_id)
end

function compiler.emitResult(sender, result)
    if sender and type(sender.sendEvent) == "function" then
        sender:sendEvent(events.COMPILE_RESULT, result)
    end
end

return compiler
