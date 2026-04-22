local core = require("openmw.core")
local types = require("openmw.types")

local validate = require("scripts.spellforge.shared.validate")
local canonicalize = require("scripts.spellforge.global.canonicalize")
local records = require("scripts.spellforge.global.records")
local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("global.compiler")

local compiler = {}

local KNOWN_BASE_SPELL_IDS = {}
for _, record in pairs(core.magic.spells.records) do
    if record and type(record.id) == "string" and record.id ~= "" then
        KNOWN_BASE_SPELL_IDS[record.id] = true
    end
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
    local draft = core.magic.spells.createRecordDraft {
        id = record_id,
        name = string.format("Spellforge %s", record_id),
        cost = 0,
        effects = base.effects,
    }
    log.info(string.format("createRecordDraft called id=%s effect_count=%d", tostring(record_id), #(draft.effects or {})))
    return draft
end

local function addToSpellbook(actor, spell_id)
    local actor_spells = types.Actor.spells(actor)
    log.debug(string.format("ActorSpells:add before actor=%s spell_id=%s", tostring(actor and actor.recordId), tostring(spell_id)))
    log.info(string.format("ActorSpells:add called actor=%s spell_id=%s", tostring(actor and actor.recordId), tostring(spell_id)))
    local ok, add_err = pcall(actor_spells.add, actor_spells, spell_id)
    if not ok then
        log.error(string.format("compiler ActorSpells:add failed actor=%s spell_id=%s err=%s", tostring(actor and actor.recordId), tostring(spell_id), tostring(add_err)))
        return false, add_err
    end
    log.debug(string.format("ActorSpells:add after actor=%s spell_id=%s", tostring(actor and actor.recordId), tostring(spell_id)))
    log.info("ActorSpells:add completed")
    return true, nil
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
        return {
            request_id = request_id,
            ok = true,
            recipe_id = canonical.recipe_id,
            spell_id = cached.frontend_spell_id,
            reused = true,
        }
    end

    local emitters = {}
    collectEmitters(recipe.nodes, emitters)
    if #emitters == 0 then
        return { request_id = request_id, ok = false, error = "Recipe has no emitter nodes" }
    end

    local generated_spell_ids = {}
    for idx, emitter in ipairs(emitters) do
        local record_id = string.format("spellforge_%s_n%d", canonical.recipe_id, idx - 1)
        local draft = createDraft(record_id, emitter)
        log.debug(string.format("world.createRecord before id=%s draft=%s", tostring(record_id), tostring(draft)))
        log.info(string.format("world.createRecord called id=%s", tostring(record_id)))
        local created_record, create_error = records.createRecord(draft)
        if create_error then
            log.error(string.format("compiler world.createRecord failed id=%s err=%s", tostring(record_id), tostring(create_error)))
            return { request_id = request_id, ok = false, error = tostring(create_error) }
        end
        log.info(string.format("world.createRecord returned id=%s value=%s", tostring(record_id), tostring(created_record)))
        log.debug(string.format("world.createRecord after id=%s return=%s", tostring(record_id), tostring(created_record)))
        local created_id = created_record and created_record.id or record_id
        generated_spell_ids[#generated_spell_ids + 1] = created_id
    end

    local frontend_spell_id = generated_spell_ids[1]
    local added_ok, add_err = addToSpellbook(actor, frontend_spell_id)
    if not added_ok then
        return { request_id = request_id, ok = false, error = tostring(add_err) }
    end

    records.put(canonical.recipe_id, {
        canonical = canonical.canonical,
        frontend_spell_id = frontend_spell_id,
        generated_spell_ids = generated_spell_ids,
        recipe = recipe,
    })

    log.info(string.format("compiled recipe_id=%s frontend=%s", canonical.recipe_id, frontend_spell_id))

    return {
        request_id = request_id,
        ok = true,
        recipe_id = canonical.recipe_id,
        spell_id = frontend_spell_id,
        reused = false,
    }
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
