local async = require("openmw.async")
local core = require("openmw.core")
local types = require("openmw.types")
local util = require("openmw.util")

local dev = require("scripts.spellforge.shared.dev")
local events = require("scripts.spellforge.shared.events")
local dev_launch = require("scripts.spellforge.global.dev_launch")
local dev_runtime = require("scripts.spellforge.global.dev_runtime")
local live_simple_dispatch = require("scripts.spellforge.global.live_simple_dispatch")
local log = require("scripts.spellforge.shared.log").new("global.executor")
local records = require("scripts.spellforge.global.records")
local runtime_hits = require("scripts.spellforge.global.runtime_hits")
local sfp_adapter = require("scripts.spellforge.global.sfp_adapter")

local executor = {}

local watchers = {}
local dispatch_spell_cache = {}
local launch_cookies = {}

local player_ref = nil
local last_active_spell_ids = {}
local fireball_logged = false
local target_filter_registered = false
local DISPATCH_KIND_COMPILED = "compiled_spellforge"
local DISPATCH_KIND_DEBUG_FIREBALL = "debug_vanilla_fireball"

local function stringifyValue(value, depth)
    if depth <= 0 then
        return "<max-depth>"
    end
    local value_type = type(value)
    if value_type == "table" then
        local parts = {}
        for k, v in pairs(value) do
            parts[#parts + 1] = string.format("%s=%s", tostring(k), stringifyValue(v, depth - 1))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(value)
end

local function logSpellRecord(label, spell_id)
    local record = spell_id and core.magic.spells.records[spell_id] or nil
    if not record then
        log.debug(string.format("%s spell_id=%s record=nil", label, tostring(spell_id)))
        return
    end

    log.debug(string.format(
        "%s spell_id=%s name=%s type=%s cost=%s isAutocalc=%s record=%s",
        label,
        tostring(spell_id),
        tostring(record.name),
        tostring(record.type),
        tostring(record.cost),
        tostring(record.isAutocalc),
        tostring(record)
    ))

    local effects = record.effects
    if type(effects) ~= "table" then
        log.debug(string.format("%s spell_id=%s effects=nil", label, tostring(spell_id)))
        return
    end
    for i, effect in ipairs(effects) do
        log.debug(string.format(
            "%s effect[%d] id=%s range=%s area=%s duration=%s magnitudeMin=%s magnitudeMax=%s",
            label,
            i,
            tostring(effect.id),
            tostring(effect.range),
            tostring(effect.area),
            tostring(effect.duration),
            tostring(effect.magnitudeMin),
            tostring(effect.magnitudeMax)
        ))
    end
end

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

local function createDispatchSpellForEffect(recipe_id, effect_index, effect)
    local cache_key = string.format("%s:%d", tostring(recipe_id), effect_index)
    if dispatch_spell_cache[cache_key] then
        return dispatch_spell_cache[cache_key], nil
    end

    local draft = core.magic.spells.createRecordDraft {
        id = string.format("spellforge_%s_dispatch_%d", tostring(recipe_id), effect_index),
        name = string.format("Spellforge Dispatch %s %d", tostring(recipe_id), effect_index),
        cost = 0,
        isAutocalc = false,
        effects = { effect },
    }

    local created, create_err = records.createRecord(draft)
    if create_err then
        log.error(string.format("executor create dispatch spell failed recipe_id=%s effect_index=%s err=%s", tostring(recipe_id), tostring(effect_index), tostring(create_err)))
        return nil, tostring(create_err)
    end

    local dispatch_spell_id = created and created.id
    if type(dispatch_spell_id) ~= "string" or dispatch_spell_id == "" then
        return nil, "dispatch spell create returned invalid id"
    end

    dispatch_spell_cache[cache_key] = dispatch_spell_id
    return dispatch_spell_id, nil
end

local function launchSpell(actor, dispatch_spell_id, start_pos, direction, hit_object)
    local capabilities = sfp_adapter.capabilities()
    if not capabilities.has_interface then
        return false, "I.MagExp missing"
    end
    if not capabilities.has_launchSpell then
        return false, "I.MagExp.launchSpell missing"
    end

    log.debug(string.format(
        "executor launchSpell params attacker=%s spellId=%s startPos=%s direction=%s isFree=true hitObject=%s",
        tostring(actor and actor.recordId),
        tostring(dispatch_spell_id),
        tostring(start_pos),
        tostring(direction),
        tostring(hit_object and hit_object.recordId or hit_object)
    ))

    local result = sfp_adapter.launchSpell({
        attacker = actor,
        spellId = dispatch_spell_id,
        startPos = start_pos,
        direction = direction,
        hitObject = hit_object,
        isFree = true,
    })
    if not result.ok then
        log.error(string.format("executor launchSpell failed spell_id=%s err=%s", tostring(dispatch_spell_id), tostring(result.error)))
        return false, tostring(result.error)
    end

    log.debug(string.format(
        "executor launchSpell dispatched spell_id=%s actor=%s projectile_id=%s",
        tostring(dispatch_spell_id),
        tostring(actor and actor.recordId),
        tostring(result.projectile_id)
    ))
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

    log.debug(string.format(
        "cast request matched recipe_id=%s logical_id=%s engine_id=%s",
        tostring(recipe_id),
        tostring(entry.frontend_logical_id),
        tostring(engine_id)
    ))

    local ok, err = launchSpell(actor, engine_id, actor.position + util.vector3(0, 0, 120), actor.rotation * util.vector3(0, 1, 0), nil)
    sendResult(sender, request_id, ok, err)
end

function executor.onInterceptCast(payload)
    local sender = payload and payload.sender
    local engine_id = payload and payload.spell_id
    if not sender then
        return
    end

    local recipe_id, entry, root = records.findRootNodeByEngineSpellId(engine_id)
    if not recipe_id or not root then
        log.error(string.format("intercept cast missing metadata for spell_id=%s", tostring(engine_id)))
        sender:sendEvent(events.INTERCEPT_DISPATCH_RESULT, {
            ok = false,
            dispatch_kind = DISPATCH_KIND_COMPILED,
            spell_id = engine_id,
            error = "metadata not found",
        })
        return
    end

    local dispatched = 0
    -- Transitional 2.2b scaffolding:
    -- root-only real_effects dispatch proves intercept->launch path, not final 2.2c runtime.
    -- TODO(2.2c): move to compiled effect-list plan execution with bounded job orchestration.
    log.debug(string.format(
        "intercept metadata root recipe_id=%s spell_id=%s real_effect_count=%s real_effects=%s",
        tostring(recipe_id),
        tostring(engine_id),
        tostring(root.real_effects and #root.real_effects or 0),
        stringifyValue(root.real_effects, 3)
    ))

    if dev.liveSimpleDispatchEnabled() then
        local live_ok, live_result_or_err = pcall(live_simple_dispatch.tryDispatch, payload, entry, root, {
            source_recipe_id = recipe_id,
        })
        local live_result = live_ok and live_result_or_err or {
            ok = false,
            used_live_2_2c = true,
            error = tostring(live_result_or_err),
        }
        if live_result.ok and live_result.used_live_2_2c then
            launch_cookies[live_result.helper_engine_id] = {
                recipe_id = recipe_id,
                plan_recipe_id = live_result.plan_recipe_id,
                slot_id = live_result.slot_id,
                source_actor = sender,
                live_2_2c = true,
            }
            sender:sendEvent(events.INTERCEPT_DISPATCH_RESULT, {
                ok = true,
                dispatch_kind = DISPATCH_KIND_COMPILED,
                spell_id = engine_id,
                recipe_id = recipe_id,
                live_2_2c = true,
                live_2_2c_plan_recipe_id = live_result.plan_recipe_id,
                slot_id = live_result.slot_id,
                helper_engine_id = live_result.helper_engine_id,
                projectile_id = live_result.projectile_id,
                projectile_registered = live_result.projectile_registered == true,
                job_id = live_result.job_id,
                dispatch_count = 1,
            })
            return
        end
        if live_result.used_live_2_2c then
            log.warn(string.format(
                "SPELLFORGE_LIVE_2_2C_SIMPLE_DISPATCH_ERR spell_id=%s recipe_id=%s err=%s; falling back to 2.2b",
                tostring(engine_id),
                tostring(recipe_id),
                tostring(live_result.error or live_result.fallback_reason or "unknown")
            ))
        else
            log.debug(string.format(
                "SPELLFORGE_LIVE_2_2C_SIMPLE_DISPATCH_FALLBACK spell_id=%s recipe_id=%s reason=%s",
                tostring(engine_id),
                tostring(recipe_id),
                tostring(live_result.fallback_reason or "not_qualified")
            ))
        end
    end

    for effect_index, effect in ipairs(root.real_effects or {}) do
        log.debug(string.format(
            "intercept real_effect[%d] id=%s range=%s area=%s duration=%s magnitudeMin=%s magnitudeMax=%s",
            effect_index,
            tostring(effect.id),
            tostring(effect.range),
            tostring(effect.area),
            tostring(effect.duration),
            tostring(effect.magnitudeMin),
            tostring(effect.magnitudeMax)
        ))
        local dispatch_spell_id, dispatch_err = createDispatchSpellForEffect(recipe_id, effect_index, effect)
        if not dispatch_spell_id then
            sender:sendEvent(events.INTERCEPT_DISPATCH_RESULT, {
                ok = false,
                dispatch_kind = DISPATCH_KIND_COMPILED,
                spell_id = engine_id,
                error = dispatch_err,
            })
            return
        end

        logSpellRecord("dispatch spell record", dispatch_spell_id)
        if not fireball_logged then
            fireball_logged = true
            logSpellRecord("vanilla fireball record", "fireball")
        end

        local ok, launch_err = launchSpell(sender, dispatch_spell_id, payload.start_pos, payload.direction, payload.hit_object)
        if not ok then
            sender:sendEvent(events.INTERCEPT_DISPATCH_RESULT, {
                ok = false,
                dispatch_kind = DISPATCH_KIND_COMPILED,
                spell_id = engine_id,
                error = launch_err,
            })
            return
        end

        launch_cookies[dispatch_spell_id] = {
            recipe_id = recipe_id,
            node_path = { 1 },
            source_actor = sender,
        }
        dispatched = dispatched + 1
    end

    sender:sendEvent(events.INTERCEPT_DISPATCH_RESULT, {
        ok = dispatched > 0,
        dispatch_kind = DISPATCH_KIND_COMPILED,
        spell_id = engine_id,
        recipe_id = recipe_id,
        dispatch_count = dispatched,
    })
end

function executor.onDebugLaunchVanillaFireball(payload)
    local sender = payload and payload.sender
    if not sender then
        log.error("debug launch missing payload.sender")
        return
    end

    log.debug("debug launch requested: vanilla fireball via I.MagExp.launchSpell")
    logSpellRecord("vanilla fireball record", "fireball")

    local ok, launch_err = launchSpell(
        sender,
        "fireball",
        payload and payload.start_pos,
        payload and payload.direction,
        payload and payload.hit_object
    )
    if not ok then
        if type(sender.sendEvent) == "function" then
            sender:sendEvent(events.INTERCEPT_DISPATCH_RESULT, {
                ok = false,
                dispatch_kind = DISPATCH_KIND_DEBUG_FIREBALL,
                spell_id = "fireball",
                error = launch_err,
            })
        end
        return
    end

    launch_cookies["fireball"] = {
        recipe_id = "debug_vanilla_fireball",
        node_path = { 1 },
        source_actor = sender,
    }
    if type(sender.sendEvent) == "function" then
        sender:sendEvent(events.INTERCEPT_DISPATCH_RESULT, {
            ok = true,
            dispatch_kind = DISPATCH_KIND_DEBUG_FIREBALL,
            spell_id = "fireball",
            recipe_id = "debug_vanilla_fireball",
            dispatch_count = 1,
        })
    end
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
    log.debug(string.format("registered cast observe actor=%s spell_id=%s timeout=%s", tostring(actor_id), tostring(engine_id), tostring(timeout_seconds)))
end

function executor.onMagicHit(payload)
    log.debug(string.format("MagExp_OnMagicHit payload=%s", stringifyValue(payload, 4)))
    -- 2.2c helper hits use shared routing only when a dev/live 2.2c gate is enabled;
    -- live 2.2b dispatch cookies stay unchanged.

    local attacker_id = payload and payload.attacker and payload.attacker.recordId or nil
    local victim_id = payload and payload.target and payload.target.recordId or nil
    local spell_id = payload and (payload.spellId or payload.spell_id) or nil
    local hit_pos = payload and payload.hitPos or nil
    local helper_hit = nil
    if dev.devLaunchEnabled() then
        helper_hit = dev_runtime.resolveHelperHit(payload)
    elseif dev.liveSimpleDispatchEnabled() then
        helper_hit = runtime_hits.resolveHelperHit(payload)
    end
    local helper_mapping = helper_hit and helper_hit.ok and helper_hit.mapping or nil
    if helper_mapping and dev.devLaunchEnabled() then
        dev_launch.onHelperHit(helper_hit)
    end

    local cookie = spell_id and launch_cookies[spell_id] or nil
    if not cookie and helper_mapping then
        cookie = launch_cookies[helper_mapping.engine_id]
    end
    if cookie then
        log.debug(string.format(
            "Spellforge hit matched recipe_id=%s spell_id=%s attacker=%s victim=%s hit_pos=%s",
            tostring(cookie.recipe_id),
            tostring(spell_id),
            tostring(attacker_id),
            tostring(victim_id),
            tostring(hit_pos)
        ))
    end

    local recipe_id = nil
    if cookie then
        recipe_id = cookie.recipe_id
    elseif helper_mapping then
        recipe_id = helper_mapping.recipe_id
    elseif type(spell_id) == "string" then
        recipe_id = select(1, findSpellforgeEntry(spell_id))
    end

    for actor_id, watcher in pairs(watchers) do
        if watcher.sender and type(watcher.sender.sendEvent) == "function" then
            local match = recipe_id ~= nil and (watcher.spell_id == spell_id or recipe_id == select(1, findSpellforgeEntry(watcher.spell_id)))
            if match then
                watcher.sender:sendEvent(events.CAST_HIT_OBSERVED, {
                    request_id = watcher.request_id,
                    spell_id = spell_id,
                    matched = true,
                    attacker_id = attacker_id,
                    victim_id = victim_id,
                    recipe_id = recipe_id,
                    live_2_2c = cookie and cookie.live_2_2c == true or false,
                    live_2_2c_plan_recipe_id = cookie and cookie.plan_recipe_id or nil,
                    slot_id = helper_mapping and helper_mapping.slot_id or (cookie and cookie.slot_id or nil),
                    helper_engine_id = helper_mapping and helper_mapping.engine_id or nil,
                    projectile_id = helper_hit and helper_hit.projectile_id or nil,
                })
                watchers[actor_id] = nil
            end
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

local function ensureTargetFilter()
    if target_filter_registered then
        return
    end
    local capabilities = sfp_adapter.capabilities()
    if not capabilities.has_interface then
        return
    end
    if not capabilities.has_addTargetFilter and not capabilities.has_setTargetFilter then
        return
    end
    local registered = sfp_adapter.registerTargetFilter(function(target)
        local target_id = target and target.recordId or nil
        if target == nil then
            log.debug("target filter target=nil result=true")
            return true
        end
        local health = types.Actor.stats.dynamic.health(target)
        if not health then
            log.debug(string.format("target filter target=%s health=nil result=true", tostring(target_id)))
            return true
        end
        local allow = (health.current or 0) > 0
        log.debug(string.format(
            "target filter target=%s health=%s result=%s",
            tostring(target_id),
            tostring(health.current),
            tostring(allow)
        ))
        return allow
    end)
    target_filter_registered = registered.ok == true
    -- TODO(2.2c): route launch/hit work through a central bounded job queue/orchestrator.
end

function executor.onPlayerAdded(player)
    player_ref = player
    last_active_spell_ids = {}
    ensureTargetFilter()
    log.debug(string.format("diagnostic onPlayerAdded player=%s", tostring(player and player.recordId)))
end

function executor.onUpdate()
    if not player_ref then
        return
    end

    local current_ids = buildActiveSpellIdSet(player_ref)
    for id in pairs(current_ids) do
        if not last_active_spell_ids[id] then
            log.debug(string.format("diagnostic active spell added id=%s", tostring(id)))
        end
    end
    last_active_spell_ids = current_ids
end

function executor.onCastDiagSignal(payload)
    log.debug(string.format(
        "diagnostic cast signal group=%s key=%s selected_spell_id=%s sender=%s",
        tostring(payload and payload.groupname),
        tostring(payload and payload.key),
        tostring(payload and payload.selected_spell_id),
        tostring(payload and payload.sender and payload.sender.recordId)
    ))
end

return executor
