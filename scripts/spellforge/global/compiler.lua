local core = require("openmw.core")
local types = require("openmw.types")

local validate = require("scripts.spellforge.shared.validate")
local canonicalize = require("scripts.spellforge.global.canonicalize")
local records = require("scripts.spellforge.global.records")
local events = require("scripts.spellforge.shared.events")
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

local function createDraft(record_id, emitter, marker_range)
    local base = core.magic.spells.records[emitter.base_spell_id]
    -- Target shell marker is intentionally inert (invisible/silent) so vanilla
    -- target cast animation/text keys still happen while SFP launches the real
    -- payload only after late Spellcast_Success authorization.
    local marker_effect_id = MARKER_EFFECT_ID_DEFAULT
    if marker_range == 2 or marker_range == "target" or marker_range == "Target" then
        local base_effect = base and base.effects and base.effects[1] or nil
        local base_effect_id = base_effect and base_effect.id or nil
        -- For fire/destruction target shells, borrow only cast-presentation flavor
        -- from destruction marker variant; projectile/hit/area stays inert.
        if base_effect_id == "fireDamage" then
            marker_effect_id = MARKER_EFFECT_ID_TARGET_DESTRUCTION
        else
            marker_effect_id = MARKER_EFFECT_ID_TARGET
        end
    end
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

    log.info(string.format(
        "createRecordDraft called id=%s effect_count=%d marker=%s marker_range=%s",
        tostring(record_id),
        #(draft.effects or {}),
        tostring(marker_effect.id),
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

function compiler.compile(actor, recipe, request_id)
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

    local ok, result_or_err = pcall(compiler.compile, payload.actor, payload.recipe, payload.request_id)
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
