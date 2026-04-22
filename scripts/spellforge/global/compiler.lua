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
    for _, effect in ipairs(effects or {}) do
        out[#out + 1] = {
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

local function scaleMagnitude(value, percent)
    if type(value) ~= "number" then
        return value
    end
    local factor = 1 + ((percent or 0) / 100)
    if factor < 0 then
        factor = 0
    end
    return math.floor((value * factor) + 0.5)
end

local function scaleArea(value, percent)
    if type(value) ~= "number" then
        return value
    end
    local factor = 1 + ((percent or 0) / 100)
    if factor < 0 then
        factor = 0
    end
    return math.floor((value * factor) + 0.5)
end

local function applyLaunchMods(base_effects, mods)
    local out = cloneEffects(base_effects)
    local damage_percent = 0
    local size_percent = 0

    for _, mod in ipairs(mods or {}) do
        if mod.opcode == "Damage+" then
            damage_percent = damage_percent + (mod.params and mod.params.percent or 0)
        elseif mod.opcode == "Size+" then
            size_percent = size_percent + (mod.params and mod.params.percent or 0)
        end
    end

    if damage_percent ~= 0 or size_percent ~= 0 then
        for _, effect in ipairs(out) do
            effect.magnitudeMin = scaleMagnitude(effect.magnitudeMin, damage_percent)
            effect.magnitudeMax = scaleMagnitude(effect.magnitudeMax, damage_percent)
            effect.area = scaleArea(effect.area or 0, size_percent)
        end
    end

    return out
end

local function markerEffect()
    return {
        {
            id = MARKER_EFFECT_ID,
            range = core.magic.RANGE.Self,
            area = 0,
            duration = 0,
            magnitudeMin = 0,
            magnitudeMax = 0,
        },
    }
end

local function createDraft(record_id, display_name, cost)
    local draft = core.magic.spells.createRecordDraft {
        id = record_id,
        name = display_name,
        cost = cost,
        isAutocalc = false,
        effects = markerEffect(),
    }
    return draft
end

local function addToSpellbook(actor, engine_id)
    local actor_spells = types.Actor.spells(actor)
    local ok, add_err = pcall(actor_spells.add, actor_spells, engine_id)
    if not ok then
        log.error(string.format("compiler ActorSpells:add failed actor=%s engine_id=%s err=%s", tostring(actor and actor.recordId), tostring(engine_id), tostring(add_err)))
        return false, add_err
    end
    return true, nil
end

local function getSpellCost(spell_id)
    local spell = core.magic.spells.records[spell_id]
    if not spell then
        return 0
    end
    return tonumber(spell.cost) or 0
end

local function parseSequence(nodes, path, node_entries, runtime)
    local pending_mods = {}
    local last_emitter = nil

    for i, node in ipairs(nodes or {}) do
        local current_path = {}
        for j, value in ipairs(path) do
            current_path[j] = value
        end
        current_path[#current_path + 1] = i

        if node.kind == "emitter" then
            runtime.next_node_index = runtime.next_node_index + 1
            local node_index = runtime.next_node_index
            local base = core.magic.spells.records[node.base_spell_id]
            local node_entry = {
                node_index = node_index,
                node_path = current_path,
                base_spell_id = node.base_spell_id,
                launch_mods = pending_mods,
                real_effects = applyLaunchMods(base and base.effects or {}, pending_mods),
                payload = node.payload,
            }
            node_entries[#node_entries + 1] = node_entry
            last_emitter = node_entry
            pending_mods = {}

            runtime.total_cost = runtime.total_cost + getSpellCost(node.base_spell_id)

            if type(node.payload) == "table" then
                parseSequence(node.payload, current_path, node_entries, runtime)
            end
        elseif node.opcode == "Trigger" or node.opcode == "Timer" then
            if last_emitter then
                last_emitter.trigger = {
                    opcode = node.opcode,
                    seconds = node.params and node.params.seconds,
                    payload = node.payload,
                }
                if type(node.payload) == "table" then
                    parseSequence(node.payload, current_path, node_entries, runtime)
                end
            end
        else
            pending_mods[#pending_mods + 1] = {
                opcode = node.opcode,
                params = node.params,
            }
        end
    end
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

    local node_entries = {}
    local runtime = {
        total_cost = 0,
        next_node_index = -1,
    }
    parseSequence(recipe.nodes, {}, node_entries, runtime)
    if #node_entries == 0 then
        return { request_id = request_id, ok = false, error = "Recipe has no emitter nodes" }
    end

    local generated_spell_ids = {}
    local generated_engine_spell_ids = {}
    for _, node_entry in ipairs(node_entries) do
        local logical_id = string.format("spellforge_%s_n%d", canonical.recipe_id, node_entry.node_index)
        local display_name = node_entry.node_index == 0 and string.format("Spellforge %s", canonical.recipe_id) or string.format("Spellforge Internal %s.%d", canonical.recipe_id, node_entry.node_index)
        local draft = createDraft(logical_id, display_name, runtime.total_cost)
        local created_record, create_error = records.createRecord(draft)
        if create_error then
            return { request_id = request_id, ok = false, errors = { { message = tostring(create_error) } } }
        end
        local engine_id = created_record and created_record.id or nil
        if type(engine_id) ~= "string" or engine_id == "" then
            return { request_id = request_id, ok = false, errors = { { message = "world.createRecord returned record without id" } } }
        end

        node_entry.logical_id = logical_id
        node_entry.engine_id = engine_id

        generated_spell_ids[#generated_spell_ids + 1] = logical_id
        generated_engine_spell_ids[#generated_engine_spell_ids + 1] = engine_id
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
        node_entries = node_entries,
        recipe = recipe,
    })

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
