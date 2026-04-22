local core = require("openmw.core")
local types = require("openmw.types")

local validate = require("scripts.spellforge.shared.validate")
local canonicalize = require("scripts.spellforge.global.canonicalize")
local records = require("scripts.spellforge.global.records")
local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("global.compiler")

local compiler = {}

local KNOWN_BASE_SPELL_IDS = {}
for spell_id in pairs(core.magic.spells.records) do
    KNOWN_BASE_SPELL_IDS[spell_id] = true
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
    return core.magic.spells.createRecordDraft {
        id = record_id,
        name = string.format("Spellforge %s", record_id),
        cost = 0,
        effects = base.effects,
    }
end

local function addToSpellbook(actor, spell_id)
    local actor_spells = types.Actor.spells(actor)
    actor_spells:add(spell_id)
end

function compiler.compile(actor, recipe, request_id)
    local checked = validate.run(recipe, {
        known_base_spell_ids = KNOWN_BASE_SPELL_IDS,
    })
    if not checked.ok then
        return { request_id = request_id, ok = false, errors = checked.errors }
    end

    local canonical = canonicalize.run(recipe)
    local cached = records.getByRecipeId(canonical.recipe_id)
    if cached then
        addToSpellbook(actor, cached.frontend_spell_id)
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
        records.createRecord(draft)
        generated_spell_ids[#generated_spell_ids + 1] = record_id
    end

    local frontend_spell_id = generated_spell_ids[1]
    addToSpellbook(actor, frontend_spell_id)

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

function compiler.emitResult(result)
    core.sendGlobalEvent(events.COMPILE_RESULT, result)
end

return compiler
