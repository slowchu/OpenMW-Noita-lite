local util = require("openmw.util")

local limits = require("scripts.spellforge.shared.limits")

local ok_world, world = pcall(require, "openmw.world")
local ok_types, types = pcall(require, "openmw.types")

local live_homing = {}

local function readField(value, key)
    if value == nil then
        return nil
    end
    local ok, result = pcall(function()
        return value[key]
    end)
    if ok then
        return result
    end
    return nil
end

local function isFinite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function clamp(value, min_value, max_value)
    local n = tonumber(value)
    if not isFinite(n) then
        return nil
    end
    if n < min_value then
        return min_value
    end
    if n > max_value then
        return max_value
    end
    return n
end

local function positionOf(value)
    if value == nil then
        return nil
    end
    local position = readField(value, "position") or readField(value, "pos")
    if position ~= nil then
        return position
    end
    if readField(value, "x") ~= nil and readField(value, "y") ~= nil then
        return value
    end
    return nil
end

local function vectorFromPosition(value, height)
    local position = positionOf(value)
    if not position then
        return nil
    end
    return util.vector3(
        tonumber(readField(position, "x")) or 0,
        tonumber(readField(position, "y")) or 0,
        (tonumber(readField(position, "z")) or 0) + (tonumber(height) or 0)
    )
end

local function vectorKey(vector)
    if vector == nil then
        return nil
    end
    local ok, x, y, z = pcall(function()
        return vector.x, vector.y, vector.z
    end)
    if not ok or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    return string.format("%.5f,%.5f,%.5f", x, y, z)
end

local function component(vector, key)
    return tonumber(readField(vector, key)) or 0
end

local function vectorLength(vector)
    if vector == nil then
        return nil
    end
    local ok, length = pcall(function()
        return vector:length()
    end)
    if ok and type(length) == "number" then
        return length
    end
    local x = component(vector, "x")
    local y = component(vector, "y")
    local z = component(vector, "z")
    return math.sqrt(x * x + y * y + z * z)
end

local function dot(a, b)
    return component(a, "x") * component(b, "x")
        + component(a, "y") * component(b, "y")
        + component(a, "z") * component(b, "z")
end

local function scalarToken(value)
    if value == nil then
        return nil
    end
    local value_type = type(value)
    if value_type == "string" then
        return value ~= "" and value or nil
    elseif value_type == "number" or value_type == "boolean" then
        return tostring(value)
    end
    return nil
end

local function callMethod(value, key)
    local fn = readField(value, key)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, result = pcall(fn, value)
    if ok then
        return result
    end
    return nil
end

local function objectToken(value)
    local direct = scalarToken(value)
    if direct then
        return direct
    end
    if value == nil then
        return nil
    end
    return scalarToken(readField(value, "id"))
        or scalarToken(readField(value, "recordId"))
        or scalarToken(readField(value, "refId"))
        or scalarToken(readField(value, "name"))
        or scalarToken(callMethod(value, "getFormId"))
        or tostring(value)
end

local function objectValid(object)
    local valid = readField(object, "isValid")
    if type(valid) == "boolean" then
        return valid
    end
    local method_valid = callMethod(object, "isValid")
    if type(method_valid) == "boolean" then
        return method_valid
    end
    return object ~= nil
end

local function typeObjectIsInstance(type_table, object)
    local table_type = type(type_table)
    if table_type == "table" or table_type == "userdata" then
        local object_is_instance = readField(type_table, "objectIsInstance")
        if type(object_is_instance) ~= "function" then
            return false
        end
        local ok, result = pcall(object_is_instance, object)
        return ok and result == true
    end
    return false
end

local function actorKind(object)
    if object == nil or not ok_types or types == nil then
        return nil
    end
    local object_type = readField(object, "type")
    if object_type ~= nil then
        if object_type == types.Player then
            return "player"
        end
        if object_type == types.NPC then
            return "npc"
        end
        if object_type == types.Creature then
            return "creature"
        end
    end
    if typeObjectIsInstance(types.Player, object) then
        return "player"
    end
    if typeObjectIsInstance(types.NPC, object) then
        return "npc"
    end
    if typeObjectIsInstance(types.Creature, object) then
        return "creature"
    end
    if typeObjectIsInstance(types.Actor, object) then
        return "actor"
    end
    return nil
end

local function countActorKind(kind, counters)
    if kind == "creature" then
        counters.creature = counters.creature + 1
    elseif kind == "npc" then
        counters.npc = counters.npc + 1
    elseif kind == "player" then
        counters.player = counters.player + 1
    elseif kind == "actor" then
        counters.actor = counters.actor + 1
    end
end

local function aimHeightForKind(kind)
    if kind == "creature" then
        return limits.HOMING_CREATURE_AIM_HEIGHT or 32
    end
    return limits.HOMING_AIM_HEIGHT
end

local function candidateBetter(candidate, best)
    if best == nil then
        return true
    end
    local candidate_aim_error = tonumber(candidate.aim_error) or math.huge
    local best_aim_error = tonumber(best.aim_error) or math.huge
    if candidate_aim_error ~= best_aim_error then
        return candidate_aim_error < best_aim_error
    end
    local candidate_alignment = tonumber(candidate.alignment) or -math.huge
    local best_alignment = tonumber(best.alignment) or -math.huge
    if candidate_alignment ~= best_alignment then
        return candidate_alignment > best_alignment
    end
    local candidate_distance = tonumber(candidate.distance) or math.huge
    local best_distance = tonumber(best.distance) or math.huge
    if candidate_distance ~= best_distance then
        return candidate_distance < best_distance
    end
    local candidate_id = tostring(candidate.id or "")
    local best_id = tostring(best.id or "")
    return candidate_id < best_id
end

local function attachActorScanCounts(target, inspected, counters)
    if target == nil then
        return nil
    end
    target.candidate_count = inspected
    target.actor_candidate_count = counters.total
    target.creature_candidate_count = counters.creature
    target.npc_candidate_count = counters.npc
    target.player_candidate_count = counters.player
    target.actor_kind_candidate_count = counters.actor
    return target
end

local function actorAlive(object)
    if not ok_types or not types or not types.Actor or not types.Actor.stats
        or not types.Actor.stats.dynamic or type(types.Actor.stats.dynamic.health) ~= "function" then
        return true
    end
    local ok, health = pcall(types.Actor.stats.dynamic.health, object)
    if not ok or health == nil then
        return true
    end
    local current = tonumber(health.current)
    return current == nil or current > 0
end

local function normalize(delta)
    if delta == nil then
        return nil, "homing_direction_missing"
    end
    local ok, normalized = pcall(function()
        return delta:normalize()
    end)
    if not ok or normalized == nil then
        return nil, "homing_direction_missing"
    end
    local length_ok, length = pcall(function()
        return delta:length()
    end)
    if not length_ok or tonumber(length) == nil or length <= 0.0001 then
        return nil, "homing_direction_zero"
    end
    return normalized, nil
end

local function activeActors()
    if not ok_world or world == nil then
        return nil
    end
    local actors = readField(world, "activeActors")
    if type(actors) ~= "table" and type(actors) ~= "userdata" then
        return nil
    end
    return actors
end

local function actorTargetFromObject(object)
    local kind = actorKind(object)
    if kind == nil or not objectValid(object) or not actorAlive(object) then
        return nil
    end
    local position = vectorFromPosition(object, aimHeightForKind(kind))
    if position == nil then
        return nil
    end
    return {
        id = objectToken(object),
        object = object,
        position = position,
        provider = "hit_object",
        candidate_count = 1,
        kind = kind,
    }
end

local function selectActorTarget(payload, start_pos)
    local actors = activeActors()
    if actors == nil then
        return nil, "homing_actor_scan_unavailable"
    end
    local direction, direction_err = normalize(vectorFromPosition(payload.direction))
    if not direction then
        return nil, direction_err or "homing_direction_missing"
    end

    local caster_id = objectToken(payload.actor or payload.sender)
    local radius = tonumber(payload.homing_scan_radius or limits.HOMING_SCAN_RADIUS) or limits.HOMING_SCAN_RADIUS
    local candidate_cap = tonumber(payload.homing_scan_candidates or limits.HOMING_SCAN_CANDIDATES) or limits.HOMING_SCAN_CANDIDATES
    local min_dot = tonumber(payload.homing_scan_min_dot or limits.HOMING_SCAN_MIN_DOT) or limits.HOMING_SCAN_MIN_DOT
    local min_forward = tonumber(payload.homing_scan_min_forward or limits.HOMING_SCAN_MIN_FORWARD) or limits.HOMING_SCAN_MIN_FORWARD
    local inspected = 0
    local best = nil
    local actor_counts = {
        total = 0,
        creature = 0,
        npc = 0,
        player = 0,
        actor = 0,
    }

    local ok = pcall(function()
        for _, object in ipairs(actors) do
            inspected = inspected + 1
            if inspected > candidate_cap then
                break
            end
            local kind = actorKind(object)
            if kind ~= nil and objectValid(object) and actorAlive(object) and objectToken(object) ~= caster_id then
                actor_counts.total = actor_counts.total + 1
                countActorKind(kind, actor_counts)
                local position = vectorFromPosition(object, aimHeightForKind(kind))
                if position ~= nil then
                    local delta = position - start_pos
                    local distance = vectorLength(delta)
                    if distance ~= nil and distance > 0.001 and distance <= radius then
                        local forward = dot(delta, direction)
                        local alignment = forward / distance
                        if forward >= min_forward and alignment >= min_dot then
                            local lateral_sq = math.max((distance * distance) - (forward * forward), 0)
                            local candidate = {
                                id = objectToken(object),
                                object = object,
                                position = position,
                                provider = "actor_scan",
                                candidate_count = inspected,
                                alignment = alignment,
                                distance = distance,
                                aim_error = math.sqrt(lateral_sq),
                                kind = kind,
                            }
                            if candidateBetter(candidate, best) then
                                best = candidate
                            end
                        end
                    end
                end
            end
        end
    end)
    if not ok then
        return nil, "homing_actor_scan_failed"
    end
    if best then
        return attachActorScanCounts(best, inspected, actor_counts), nil
    end
    return nil, "homing_actor_target_missing"
end

local function homingOps(ops)
    local out = {}
    for _, op in ipairs(ops or {}) do
        if op and op.opcode == "Homing" then
            out[#out + 1] = op
        end
    end
    return out
end

local function computeMutation(op)
    local params = op and op.params or {}
    local force = clamp(params.force or params.strength or limits.HOMING_FORCE_DEFAULT, limits.HOMING_FORCE_MIN, limits.HOMING_FORCE_MAX)
    if force == nil then
        return nil, "homing_force_invalid"
    end
    return {
        homing = true,
        homing_mode = "launch_force_vec",
        homing_force = force,
        homing_field = "forceVec",
        homing_force_capped = force ~= (tonumber(params.force or params.strength) or limits.HOMING_FORCE_DEFAULT),
    }, nil
end

function live_homing.computeMutation(op)
    return computeMutation(op)
end

function live_homing.selectV0Plan(plan)
    if type(plan) ~= "table" then
        return nil, "missing_plan", nil
    end

    local bounds = plan.bounds or {}
    if bounds.has_trigger or bounds.has_timer then
        return nil, "homing_payload_unsupported", "live_homing_payload_rejections"
    end
    if bounds.has_chain or bounds.has_bounce or bounds.has_speed_plus or bounds.has_size_plus then
        return nil, "homing_unsupported_combo", "live_homing_unsupported_combo_rejections"
    end
    if bounds.has_multicast or bounds.has_pattern then
        return nil, "homing_fanout_deferred", "live_homing_unsupported_combo_rejections"
    end
    if bounds.group_count ~= 1 then
        return nil, "not_single_group", "live_homing_unsupported_combo_rejections"
    end
    if tonumber(bounds.static_emission_count) ~= 1 then
        return nil, "homing_fanout_deferred", "live_homing_unsupported_combo_rejections"
    end

    local group = plan.groups and plan.groups[1] or nil
    if type(group) ~= "table" then
        return nil, "missing_group", nil
    end
    if type(group.effects) ~= "table" or #group.effects == 0 then
        return nil, "missing_emitter_effects", nil
    end
    if type(group.postfix_ops) == "table" and #group.postfix_ops > 0 then
        return nil, "homing_payload_unsupported", "live_homing_payload_rejections"
    end
    if group.payload ~= nil then
        return nil, "homing_payload_unsupported", "live_homing_payload_rejections"
    end

    local ops = homingOps(group.prefix_ops)
    if #ops == 0 then
        return nil, "homing_missing", nil
    end
    if #ops > 1 then
        return nil, "homing_ambiguous", "live_homing_unsupported_combo_rejections"
    end
    for _, op in ipairs(group.prefix_ops or {}) do
        if op.opcode ~= "Homing" then
            return nil, "homing_unsupported_combo", "live_homing_unsupported_combo_rejections"
        end
    end

    local mutation, err = computeMutation(ops[1])
    if not mutation then
        return nil, err, "live_homing_force_invalid"
    end

    return {
        mutation = mutation,
        primary_mode = "single",
        emission_count = 1,
    }, nil, nil
end

function live_homing.computeLaunchAssist(launch_payload, mutation)
    local payload = launch_payload or {}
    local start_pos = vectorFromPosition(payload.start_pos)
    if start_pos == nil then
        return nil, "homing_start_pos_missing"
    end

    local target = actorTargetFromObject(payload.homing_target_object or payload.hit_object)
    if target == nil and payload.homing_actor_scan ~= false then
        target = selectActorTarget(payload, start_pos)
    end

    local target_position = target and target.position or vectorFromPosition(payload.homing_target_position, 0)
    local target_id = target and target.id or payload.homing_target_id
    local target_provider = target and target.provider or "explicit_position"
    local candidate_count = target and target.candidate_count or nil
    local target_kind = target and target.kind or nil
    local actor_candidate_count = target and target.actor_candidate_count or nil
    local creature_candidate_count = target and target.creature_candidate_count or nil
    local npc_candidate_count = target and target.npc_candidate_count or nil
    if target_position == nil then
        local hit_object = payload.hit_object
        target_position = vectorFromPosition(hit_object, 0)
        target_id = target_id or objectToken(hit_object)
        target_provider = target_position ~= nil and "hit_position" or target_provider
    end
    if target_position == nil then
        return nil, "homing_target_missing"
    end

    local direction, direction_err = normalize(target_position - start_pos)
    if not direction then
        return nil, direction_err
    end

    local force = mutation and mutation.homing_force or limits.HOMING_FORCE_DEFAULT
    local force_vec = direction * force
    return {
        homing = true,
        homing_mode = mutation and mutation.homing_mode or "launch_force_vec",
        homing_force = force,
        homing_field = mutation and mutation.homing_field or "forceVec",
        homing_target_id = target_id,
        homing_target_object = target and target.object or nil,
        homing_target_position = target_position,
        homing_target_provider = target_provider,
        homing_target_kind = target_kind,
        homing_candidate_count = candidate_count,
        homing_actor_candidate_count = actor_candidate_count,
        homing_creature_candidate_count = creature_candidate_count,
        homing_npc_candidate_count = npc_candidate_count,
        homing_force_key = vectorKey(force_vec),
        homing_direction_key = vectorKey(direction),
        forceVec = force_vec,
        direction = direction,
    }, nil
end

return live_homing
