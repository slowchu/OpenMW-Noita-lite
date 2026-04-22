local async = require("openmw.async")
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local types = require("openmw.types")
local util = require("openmw.util")

local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("global.executor")
local records = require("scripts.spellforge.global.records")

local executor = {}

local watchers = {}
local cookies = {}
local dispatch_spell_cache = {}
local cast_counter = 0
local target_filter_registered = false

local function nextCookieId()
    cast_counter = cast_counter + 1
    return string.format("sf_cookie_%d_%d", os.time(), cast_counter)
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
    return records.findByEngineSpellId(engine_id)
end

local function resolveNodeForSpell(spell_id)
    return records.findNodeByEngineSpellId(spell_id)
end

local function buildDirectionFromActor(actor)
    return actor.rotation * util.vector3(0, 1, 0)
end

local function ensureDispatchSpell(node)
    if not node then
        return nil, "missing node"
    end
    if dispatch_spell_cache[node.engine_id] then
        return dispatch_spell_cache[node.engine_id], nil
    end

    local logical_id = string.format("spellforge_dispatch_%s_%s", tostring(node.engine_id), tostring(node.node_index or 0))
    local draft = core.magic.spells.createRecordDraft {
        id = logical_id,
        name = string.format("Spellforge Dispatch %s", tostring(node.node_index or 0)),
        isAutocalc = false,
        cost = 0,
        effects = node.real_effects,
    }
    local created, err = records.createRecord(draft)
    if err then
        return nil, err
    end
    local engine_id = created and created.id or nil
    if type(engine_id) ~= "string" or engine_id == "" then
        return nil, "dispatch record missing id"
    end
    dispatch_spell_cache[node.engine_id] = engine_id
    return engine_id, nil
end

local function resolveSpreadDirections(base_direction, count, spread_arc)
    local out = {}
    if count <= 1 then
        out[1] = base_direction
        return out
    end

    local arc = math.rad(spread_arc or 0)
    local yaw_step = count > 1 and (arc / (count - 1)) or 0
    local yaw_start = -arc / 2

    for i = 1, count do
        local yaw = yaw_start + ((i - 1) * yaw_step)
        local x = (base_direction.x * math.cos(yaw)) - (base_direction.y * math.sin(yaw))
        local y = (base_direction.x * math.sin(yaw)) + (base_direction.y * math.cos(yaw))
        out[i] = util.vector3(x, y, base_direction.z)
    end

    return out
end

local function launchFromNode(actor, node, launch_ctx, start_pos, direction, hit_object)
    if interfaces.MagExp == nil or type(interfaces.MagExp.launchSpell) ~= "function" then
        return nil, "I.MagExp.launchSpell missing"
    end

    local dispatch_spell_id, dispatch_err = ensureDispatchSpell(node)
    if not dispatch_spell_id then
        return nil, dispatch_err
    end

    local count = launch_ctx.multicast or 1
    local spread_arc = launch_ctx.spread_arc or 0
    local directions = resolveSpreadDirections(direction, count, spread_arc)

    local cookie_ids = {}
    for i = 1, count do
        local cookie_id = nextCookieId()
        local ok, err = pcall(interfaces.MagExp.launchSpell, {
            attacker = actor,
            spellId = dispatch_spell_id,
            startPos = start_pos,
            direction = directions[i],
            hitObject = hit_object,
            isFree = true,
            speed = launch_ctx.speed_multiplier,
            radius = launch_ctx.size_multiplier,
        })
        if not ok then
            log.error(string.format("executor launchSpell failed node=%s err=%s", tostring(node.engine_id), tostring(err)))
        else
            cookie_ids[#cookie_ids + 1] = cookie_id
            cookies[cookie_id] = {
                recipe_id = launch_ctx.recipe_id,
                node_index = node.node_index,
                payload = node.payload,
                trigger = node.trigger,
                created_at = core.getSimulationTime(),
            }
        end
    end

    return cookie_ids, nil
end

local function buildLaunchContext(node, recipe_id)
    local ctx = {
        multicast = 1,
        spread_arc = 0,
        speed_multiplier = 1,
        size_multiplier = 1,
        recipe_id = recipe_id,
    }

    for _, mod in ipairs(node.launch_mods or {}) do
        if mod.opcode == "Multicast" then
            ctx.multicast = math.max(1, tonumber(mod.params and mod.params.count) or 1)
        elseif mod.opcode == "Spread" then
            ctx.spread_arc = tonumber(mod.params and mod.params.arc) or 0
        elseif mod.opcode == "Speed+" then
            ctx.speed_multiplier = ctx.speed_multiplier * (1 + ((tonumber(mod.params and mod.params.percent) or 0) / 100))
        elseif mod.opcode == "Size+" then
            ctx.size_multiplier = ctx.size_multiplier * (1 + ((tonumber(mod.params and mod.params.percent) or 0) / 100))
        elseif mod.opcode == "Burst" then
            ctx.multicast = math.max(ctx.multicast, tonumber(mod.params and mod.params.count) or 1)
            ctx.spread_arc = 360
        end
    end

    return ctx
end

local function executePayload(actor, recipe_id, sequence, hit_pos, direction, hit_object)
    local pending_mods = {}

    for _, node in ipairs(sequence or {}) do
        if node.kind == "emitter" then
            local found_recipe, _, found_node = resolveNodeForSpell(node.engine_id or "")
            local effective_node = found_node
            if not effective_node then
                for _, entry in ipairs((records.getByRecipeId(recipe_id) or {}).node_entries or {}) do
                    if entry.node_path and node.node_path and #entry.node_path == #node.node_path then
                        effective_node = entry
                    end
                end
            end

            if effective_node then
                effective_node.launch_mods = pending_mods
                local launch_ctx = buildLaunchContext(effective_node, found_recipe or recipe_id)
                launchFromNode(actor, effective_node, launch_ctx, hit_pos, direction, hit_object)
            end
            pending_mods = {}
        elseif node.kind == "terminal" then
            if interfaces.MagExp and type(interfaces.MagExp.detonateSpellAtPos) == "function" then
                local _, _, terminal_node = resolveNodeForSpell(node.engine_id or "")
                local spell_id = nil
                if terminal_node then
                    spell_id = ensureDispatchSpell(terminal_node)
                else
                    spell_id = node.base_spell_id
                end
                pcall(interfaces.MagExp.detonateSpellAtPos, {
                    spellId = spell_id,
                    pos = hit_pos,
                    attacker = actor,
                    isFree = true,
                })
            end
        else
            pending_mods[#pending_mods + 1] = node
        end
    end
end

function executor.onQueryCompiledSpell(payload)
    local sender = payload and payload.sender
    if not sender then
        return
    end
    local spell_id = payload and payload.spell_id
    local recipe_id = select(1, findSpellforgeEntry(spell_id))
    sender:sendEvent(events.QUERY_COMPILED_SPELL_RESULT, {
        request_id = payload and payload.request_id,
        spell_id = spell_id,
        ours = recipe_id ~= nil,
        recipe_id = recipe_id,
    })
end

function executor.onInterceptCast(payload)
    if not payload or not payload.sender or type(payload.spell_id) ~= "string" then
        return
    end

    local recipe_id, _, node = resolveNodeForSpell(payload.spell_id)
    if not recipe_id or not node then
        return
    end

    local actor = payload.sender
    local launch_ctx = buildLaunchContext(node, recipe_id)
    local _, err = launchFromNode(actor, node, launch_ctx, payload.start_pos, payload.direction or buildDirectionFromActor(actor), payload.hit_object)
    if err then
        log.error(string.format("intercept launch failed spell_id=%s err=%s", tostring(payload.spell_id), tostring(err)))
        return
    end

    if node.trigger and node.trigger.opcode == "Timer" then
        local delay = tonumber(node.trigger.seconds) or 0.1
        async:newUnsavableSimulationTimer(delay, function()
            executePayload(actor, recipe_id, node.trigger.payload, payload.hit_pos or payload.start_pos, payload.direction, payload.hit_object)
        end)
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
end

function executor.onMagicHit(payload)
    local attacker_id = payload and payload.attacker and payload.attacker.recordId or nil
    local victim_id = payload and payload.target and payload.target.recordId or nil
    local spell_id = payload and (payload.spellId or payload.spell_id) or nil
    log.info(string.format("MagExp_OnMagicHit attacker=%s victim=%s spell_id=%s", tostring(attacker_id), tostring(victim_id), tostring(spell_id)))

    local recipe_id, _, node = resolveNodeForSpell(spell_id)
    if recipe_id and node and node.trigger and node.trigger.opcode == "Trigger" then
        executePayload(payload.attacker, recipe_id, node.trigger.payload, payload.hitPos, payload.direction, payload.target)
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

function executor.onCastRequest(payload)
    local sender = payload and payload.sender
    local actor = payload and payload.actor or sender
    local request_id = payload and payload.request_id
    local engine_id = payload and payload.spell_id
    if not sender or not actor or not engine_id then
        sendResult(sender, request_id, false, "missing sender/actor/spell_id")
        return
    end

    local recipe_id, _, node = resolveNodeForSpell(engine_id)
    if not recipe_id or not node then
        sendResult(sender, request_id, false, "spell is not in Spellforge compiled index")
        return
    end

    local launch_ctx = buildLaunchContext(node, recipe_id)
    local start_pos = actor.position + util.vector3(0, 0, 120)
    local direction = buildDirectionFromActor(actor)
    local _, err = launchFromNode(actor, node, launch_ctx, start_pos, direction, nil)
    sendResult(sender, request_id, err == nil, err)
end


function executor.onCastDiagSignal(payload)
    log.info(string.format("diagnostic cast signal group=%s key=%s", tostring(payload and payload.groupname), tostring(payload and payload.key)))
end

function executor.onPlayerAdded()
    if target_filter_registered then
        return
    end
    if interfaces.MagExp and type(interfaces.MagExp.setTargetFilter) == "function" then
        interfaces.MagExp.setTargetFilter("spellforge_filter_dead", function(target)
            if not target then
                return true
            end
            local is_dead = types.Actor.isDead and types.Actor.isDead(target)
            return not is_dead
        end)
        target_filter_registered = true
        log.info("registered MagExp target filter for dead actors")
    end
end

return executor
