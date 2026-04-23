local async = require("openmw.async")
local interfaces = require("openmw.interfaces")
local types = require("openmw.types")
local util = require("openmw.util")

local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("global.executor")
local records = require("scripts.spellforge.global.records")

local executor = {}

local watchers = {}
local player_ref = nil
local last_active_spell_ids = {}

local function sendResult(sender, request_id, ok, err)
    if sender and type(sender.sendEvent) == "function" then
        sender:sendEvent(events.CAST_OBSERVE_RESULT, {
            request_id = request_id,
            ok = ok,
            error = err,
        })
    end
end

local function findSpellforgeEntry(engine_id)
    local recipe_id, entry = records.findByEngineSpellId(engine_id)
    if recipe_id then
        return recipe_id, entry
    end
    return nil, nil
end

local function launchSpell(actor, engine_id)
    if interfaces.MagExp == nil then
        return false, "I.MagExp missing"
    end
    if type(interfaces.MagExp.launchSpell) ~= "function" then
        return false, "I.MagExp.launchSpell missing"
    end

    local start_pos = actor.position + util.vector3(0, 0, 120)
    local direction = actor.rotation * util.vector3(0, 1, 0)
    local ok, err = pcall(interfaces.MagExp.launchSpell, {
        attacker = actor,
        spellId = engine_id,
        startPos = start_pos,
        direction = direction,
        isFree = true,
    })
    if not ok then
        log.error(string.format("executor launchSpell failed engine_id=%s err=%s", tostring(engine_id), tostring(err)))
        return false, tostring(err)
    end
    log.info(string.format("executor launchSpell dispatched engine_id=%s actor=%s", tostring(engine_id), tostring(actor and actor.recordId)))
    return true, nil
end

function executor.onCastRequest(payload)
    local sender = payload and payload.sender
    local actor = payload and payload.actor or sender
    local request_id = payload and payload.request_id
    local engine_id = payload and payload.spell_id
    if not sender then
        return
    end
    if not actor then
        sendResult(sender, request_id, false, "missing actor")
        return
    end

    local recipe_id, entry = findSpellforgeEntry(engine_id)
    if not entry then
        sendResult(sender, request_id, false, "spell is not in Spellforge compiled index")
        return
    end

    log.info(string.format(
        "cast request matched recipe_id=%s logical_id=%s engine_id=%s",
        tostring(recipe_id),
        tostring(entry.frontend_logical_id),
        tostring(engine_id)
    ))
    local ok, err = launchSpell(actor, engine_id)
    sendResult(sender, request_id, ok, err)
end

function executor.onBeginObserve(payload)
    local sender = payload and payload.sender
    local request_id = payload and payload.request_id
    local engine_id = payload and payload.spell_id
    local timeout_seconds = payload and payload.timeout_seconds or 30
    if not sender then
        return
    end
    local actor_id = sender.recordId or tostring(sender)
    watchers[actor_id] = {
        sender = sender,
        request_id = request_id,
        spell_id = engine_id,
    }
    async:newUnsavableSimulationTimer(timeout_seconds, function()
        if watchers[actor_id] and watchers[actor_id].request_id == request_id then
            watchers[actor_id] = nil
            sendResult(sender, request_id, false, "observe timeout")
        end
    end)
    sendResult(sender, request_id, true, nil)
    log.info(string.format("registered cast observe actor=%s spell_id=%s timeout=%s", tostring(actor_id), tostring(engine_id), tostring(timeout_seconds)))
end

function executor.onMagicHit(payload)
    local attacker_id = payload and payload.attacker and payload.attacker.recordId or nil
    local victim_id = payload and payload.target and payload.target.recordId or nil
    local spell_id = payload and (payload.spellId or payload.spell_id) or nil
    local school = payload and payload.school or nil
    local hit_pos = payload and payload.hitPos or nil
    log.info(string.format(
        "MagExp_OnMagicHit attacker=%s victim=%s spell_id=%s school=%s hit_pos=%s",
        tostring(attacker_id),
        tostring(victim_id),
        tostring(spell_id),
        tostring(school),
        tostring(hit_pos)
    ))

    local recipe_id = nil
    if type(spell_id) == "string" then
        recipe_id = select(1, findSpellforgeEntry(spell_id))
    end
    if recipe_id then
        log.info(string.format("hit event matched Spellforge spell recipe_id=%s spell_id=%s", tostring(recipe_id), tostring(spell_id)))
    else
        log.info(string.format("hit event not ours, ignoring spell_id=%s", tostring(spell_id)))
    end

    for actor_id, watcher in pairs(watchers) do
        if watcher.spell_id == spell_id and watcher.sender and type(watcher.sender.sendEvent) == "function" then
            watcher.sender:sendEvent(events.CAST_HIT_OBSERVED, {
                request_id = watcher.request_id,
                spell_id = spell_id,
                matched = recipe_id ~= nil,
                attacker_id = attacker_id,
                victim_id = victim_id,
            })
            watchers[actor_id] = nil
        end
    end
end

local function buildActiveSpellIdSet(actor)
    local ids = {}
    for _, active_spell in pairs(types.Actor.activeSpells(actor)) do
        if active_spell and type(active_spell.id) == "string" then
            ids[active_spell.id] = true
        end
    end
    return ids
end

function executor.onPlayerAdded(player)
    player_ref = player
    last_active_spell_ids = {}
    log.info(string.format("diagnostic onPlayerAdded player=%s", tostring(player and player.recordId)))
    log.info("diagnostic note: OpenMW global engine handlers do not document onSpellCast; using onUpdate/animation text-key probes instead")
end

function executor.onUpdate()
    if not player_ref then
        return
    end

    local current_ids = buildActiveSpellIdSet(player_ref)
    local count = 0
    for _ in pairs(current_ids) do
        count = count + 1
    end
    if count > 0 then
        log.debug(string.format("diagnostic active spell count=%d", count))
    end
    for id in pairs(current_ids) do
        if not last_active_spell_ids[id] then
            log.info(string.format("diagnostic active spell added id=%s", tostring(id)))
        end
    end
    for id in pairs(last_active_spell_ids) do
        if not current_ids[id] then
            log.info(string.format("diagnostic active spell removed id=%s", tostring(id)))
        end
    end
    last_active_spell_ids = current_ids
end

function executor.onCastDiagSignal(payload)
    log.info(string.format(
        "diagnostic cast signal group=%s key=%s selected_spell_id=%s sender=%s",
        tostring(payload and payload.groupname),
        tostring(payload and payload.key),
        tostring(payload and payload.selected_spell_id),
        tostring(payload and payload.sender and payload.sender.recordId)
    ))
end

return executor
