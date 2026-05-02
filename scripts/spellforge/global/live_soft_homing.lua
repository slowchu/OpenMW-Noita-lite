local util = require("openmw.util")

local ok_world, world = pcall(require, "openmw.world")
local ok_types, types = pcall(require, "openmw.types")

local dev = require("scripts.spellforge.shared.dev")
local limits = require("scripts.spellforge.shared.limits")
local log = require("scripts.spellforge.shared.log").new("global.live_soft_homing")
local projectile_registry = require("scripts.spellforge.global.projectile_registry")
local runtime_stats = require("scripts.spellforge.global.runtime_stats")
local sfp_adapter = require("scripts.spellforge.global.sfp_adapter")

local live_soft_homing = {}

local TAG_PREFIX = "spellforge_soft_homing:"
local entries = {}
local order = {}
local pending_by_tag = {}
local next_entry_index = 1
local now_seconds = 0
local retarget_budget_window = nil
local retarget_scans_in_window = 0

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

local function finiteNonNegative(value, fallback)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge or n < 0 then
        return fallback
    end
    return n
end

local function clampUnit(value, fallback)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then
        n = fallback
    end
    if n == nil then
        n = 0
    end
    if n < 0 then
        return 0
    end
    if n > 1 then
        return 1
    end
    return n
end

local function vectorFromPosition(value, z_offset)
    if value == nil then
        return nil
    end
    local position = readField(value, "position") or readField(value, "pos") or value
    local x = tonumber(readField(position, "x"))
    local y = tonumber(readField(position, "y"))
    local z = tonumber(readField(position, "z"))
    if x == nil or y == nil or z == nil then
        return nil
    end
    return util.vector3(x, y, z + (tonumber(z_offset) or 0))
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

local function distanceSquared(a, b)
    if a == nil or b == nil then
        return nil
    end
    local ok, ax, ay, az, bx, by, bz = pcall(function()
        return component(a, "x"), component(a, "y"), component(a, "z"),
            component(b, "x"), component(b, "y"), component(b, "z")
    end)
    if not ok then
        return nil
    end
    local dx = ax - bx
    local dy = ay - by
    local dz = az - bz
    return dx * dx + dy * dy + dz * dz
end

local function dot(a, b)
    if a == nil or b == nil then
        return nil
    end
    return component(a, "x") * component(b, "x")
        + component(a, "y") * component(b, "y")
        + component(a, "z") * component(b, "z")
end

local function normalize(delta)
    if delta == nil then
        return nil
    end
    local ok_len, length = pcall(function()
        return delta:length()
    end)
    if not ok_len or tonumber(length) == nil or length <= 0.0001 then
        return nil
    end
    local ok_norm, direction = pcall(function()
        return delta:normalize()
    end)
    if not ok_norm then
        return nil
    end
    return direction
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
    if object == nil then
        return false
    end
    local valid = readField(object, "isValid")
    if type(valid) == "boolean" then
        return valid
    end
    local method_valid = callMethod(object, "isValid")
    if type(method_valid) == "boolean" then
        return method_valid
    end
    return true
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

local function countActorKind(kind, counts)
    if kind == "creature" then
        counts.creature = counts.creature + 1
    elseif kind == "npc" then
        counts.npc = counts.npc + 1
    elseif kind == "player" then
        counts.player = counts.player + 1
    elseif kind == "actor" then
        counts.actor = counts.actor + 1
    end
end

local function softAimHeightForKind(kind)
    if kind == "creature" then
        return limits.SOFT_HOMING_CREATURE_AIM_HEIGHT or limits.HOMING_CREATURE_AIM_HEIGHT or 32
    end
    return limits.SOFT_HOMING_AIM_HEIGHT or limits.HOMING_AIM_HEIGHT
end

local function activeCount()
    return #order
end

local function removeEntry(entry_id)
    entries[entry_id] = nil
    for index, id in ipairs(order) do
        if id == entry_id then
            table.remove(order, index)
            return
        end
    end
end

local function retire(entry, reason)
    if not entry or entry.retired then
        return
    end
    entry.retired = true
    entry.retire_reason = reason
    if entry.pending_tag then
        pending_by_tag[entry.pending_tag] = nil
        entry.pending_tag = nil
    end
    if reason == "hit" then
        runtime_stats.inc("homing_entry_retired_hit")
    elseif reason == "timeout" then
        runtime_stats.inc("homing_entry_retired_timeout")
    elseif reason == "missing_state" then
        runtime_stats.inc("homing_entry_retired_missing_state")
    elseif reason == "api_failure" then
        runtime_stats.inc("homing_entry_retired_api_failure")
    elseif reason == "static_overshot" then
        runtime_stats.inc("homing_entry_retired_static_overshot")
    end
    log.info(string.format(
        "SPELLFORGE_SOFT_HOMING_RETIRED entry_id=%s projectile_id=%s reason=%s redirects=%s state_ok=%s",
        tostring(entry.entry_id),
        tostring(entry.projectile_id),
        tostring(reason),
        tostring(entry.redirect_count or 0),
        tostring(entry.state_ok_count or 0)
    ))
    removeEntry(entry.entry_id)
end

local function targetPosition(entry)
    if entry.target_object ~= nil and objectValid(entry.target_object) then
        local object_pos = vectorFromPosition(entry.target_object, softAimHeightForKind(entry.target_kind or actorKind(entry.target_object)))
        if object_pos ~= nil then
            return object_pos
        end
    end
    return entry.target_position
end

local function targetStillValid(entry)
    if entry == nil then
        return false
    end
    if entry.target_object ~= nil then
        return objectValid(entry.target_object) and actorAlive(entry.target_object)
    end
    return entry.target_position ~= nil
end

local function enterStaticOvershotSearch(entry)
    if entry == nil then
        return
    end
    runtime_stats.inc("homing_static_overshot_search_ticks")
    if entry.static_overshot_searching then
        return
    end
    entry.static_overshot_searching = true
    entry.next_retarget_time = now_seconds
    runtime_stats.inc("homing_static_overshot_search_started")
    log.info(string.format(
        "SPELLFORGE_SOFT_HOMING_SEARCHING entry_id=%s projectile_id=%s reason=static_overshot redirects=%s retarget_count=%s",
        tostring(entry.entry_id),
        tostring(entry.projectile_id),
        tostring(entry.redirect_count or 0),
        tostring(entry.retarget_count or 0)
    ))
end

local function retargetIntervalForEntry(entry)
    if entry ~= nil and entry.target_object == nil then
        return finiteNonNegative(
            limits.HOMING_SEARCH_RETARGET_INTERVAL_SECONDS,
            limits.HOMING_STEER_INTERVAL_SECONDS or 0.25
        )
    end
    return finiteNonNegative(limits.HOMING_RETARGET_INTERVAL_SECONDS, 1.0)
end

local function retargetRadiusForEntry(entry)
    local default_radius = tonumber(limits.HOMING_RADIUS) or 768
    if entry ~= nil and entry.target_object == nil then
        local fallback_radius = tonumber(limits.HOMING_FALLBACK_RETARGET_RADIUS) or default_radius
        if fallback_radius > default_radius then
            return fallback_radius
        end
    end
    return default_radius
end

local function targetBehindDirection(projectile_position, target_position, current_direction)
    local direction = normalize(current_direction)
    if projectile_position == nil or target_position == nil or direction == nil then
        return false
    end
    local forward = dot(target_position - projectile_position, direction)
    return forward ~= nil and forward < 0
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
    local candidate_distance_sq = tonumber(candidate.distance_sq) or math.huge
    local best_distance_sq = tonumber(best.distance_sq) or math.huge
    if candidate_distance_sq ~= best_distance_sq then
        return candidate_distance_sq < best_distance_sq
    end
    return tostring(candidate.id or "") < tostring(best.id or "")
end

local function sameToken(a, b)
    return a ~= nil and b ~= nil and tostring(a) == tostring(b)
end

local function consumeRetargetBudget()
    local interval = finiteNonNegative(limits.HOMING_STEER_INTERVAL_SECONDS, 0.25)
    if interval <= 0 then
        interval = 0.25
    end
    local window = math.floor(now_seconds / interval)
    if retarget_budget_window ~= window then
        retarget_budget_window = window
        retarget_scans_in_window = 0
    end
    local max_scans = tonumber(limits.MAX_HOMING_RETARGET_SCANS_PER_TICK) or 1
    if max_scans <= 0 or retarget_scans_in_window >= max_scans then
        runtime_stats.inc("homing_retarget_skipped_budget")
        return false
    end
    retarget_scans_in_window = retarget_scans_in_window + 1
    return true
end

local function selectRetargetCandidate(entry, projectile_position, current_direction)
    local actors = activeActors()
    if actors == nil then
        return nil, "homing_retarget_actor_scan_unavailable", nil
    end

    local radius = retargetRadiusForEntry(entry)
    if radius <= 0 then
        return nil, "homing_retarget_radius_invalid", nil
    end
    local radius_sq = radius * radius
    local inspect_cap = tonumber(limits.HOMING_SCAN_CANDIDATES) or 64
    if inspect_cap < 1 then
        inspect_cap = 1
    end
    local candidate_cap = tonumber(limits.MAX_HOMING_CANDIDATES_PER_SCAN) or 4
    if candidate_cap < 1 then
        candidate_cap = 1
    end
    local direction = normalize(current_direction)
    local min_dot = tonumber(limits.HOMING_RETARGET_MIN_DOT or limits.HOMING_SCAN_MIN_DOT) or 0.35
    local min_forward = tonumber(limits.HOMING_RETARGET_MIN_FORWARD or limits.HOMING_SCAN_MIN_FORWARD) or 64

    local caster_id = entry.caster_id or objectToken(entry.caster)
    local current_target_id = entry.target_id
    local counts = {
        inspected = 0,
        candidates = 0,
        cone_rejected = 0,
        creature = 0,
        npc = 0,
        player = 0,
        actor = 0,
        candidate_cap = candidate_cap,
        radius = radius,
    }
    if direction == nil then
        return nil, "homing_retarget_direction_missing", counts
    end
    local best = nil

    local ok = pcall(function()
        for _, object in ipairs(actors) do
            counts.inspected = counts.inspected + 1
            if counts.inspected > inspect_cap then
                break
            end
            local kind = actorKind(object)
            if kind ~= nil and objectValid(object) and actorAlive(object) then
                local candidate_id = objectToken(object)
                if not sameToken(candidate_id, caster_id) and not sameToken(candidate_id, current_target_id) then
                    local position = vectorFromPosition(object, softAimHeightForKind(kind))
                    local distance_sq = distanceSquared(projectile_position, position)
                    if distance_sq ~= nil and distance_sq > 0.0001 and distance_sq <= radius_sq then
                        local delta = position - projectile_position
                        local distance = math.sqrt(distance_sq)
                        local forward = dot(delta, direction)
                        local alignment = forward and forward / distance or nil
                        if forward ~= nil and alignment ~= nil and forward >= min_forward and alignment >= min_dot then
                            local lateral_sq = math.max(distance_sq - (forward * forward), 0)
                            counts.candidates = counts.candidates + 1
                            countActorKind(kind, counts)
                            local candidate = {
                                id = candidate_id,
                                object = object,
                                position = position,
                                kind = kind,
                                distance_sq = distance_sq,
                                forward = forward,
                                alignment = alignment,
                                aim_error = math.sqrt(lateral_sq),
                            }
                            if candidateBetter(candidate, best) then
                                best = candidate
                            end
                            if counts.candidates >= candidate_cap then
                                break
                            end
                        else
                            counts.cone_rejected = counts.cone_rejected + 1
                        end
                    end
                end
            end
        end
    end)
    if not ok then
        return nil, "homing_retarget_actor_scan_failed", counts
    end
    if best ~= nil then
        return best, nil, counts
    end
    return nil, "homing_retarget_target_missing", counts
end

local function retargetReason(entry, projectile_position, current_target, current_direction, candidate)
    if candidate == nil then
        return nil, nil
    end
    local current_distance_sq = distanceSquared(projectile_position, current_target)
    if not targetStillValid(entry) then
        return "target_invalid", current_distance_sq
    end
    if current_target == nil then
        return "target_missing", current_distance_sq
    end
    if entry.target_object == nil then
        return "static_target", current_distance_sq
    end
    local normalized_direction = normalize(current_direction)
    if normalized_direction ~= nil then
        local to_target = current_target - projectile_position
        local forward = dot(normalized_direction, to_target)
        if forward ~= nil and forward < 0 then
            return "overshot", current_distance_sq
        end
    end
    if current_distance_sq ~= nil then
        local switch_ratio = clampUnit(limits.HOMING_SWITCH_RATIO, 0.65)
        if candidate.distance_sq < current_distance_sq * switch_ratio * switch_ratio then
            return "closer", current_distance_sq
        end
    end
    return nil, current_distance_sq
end

local function maybeRetarget(entry, projectile_position, current_direction)
    if projectile_position == nil or entry == nil or entry.retired then
        return false
    end
    local max_retargets = tonumber(limits.HOMING_MAX_RETARGETS_PER_PROJECTILE) or 1
    if (entry.retarget_count or 0) >= max_retargets then
        return false
    end
    if now_seconds < (entry.next_retarget_time or now_seconds) then
        return false
    end
    if not consumeRetargetBudget() then
        entry.next_retarget_time = now_seconds + retargetIntervalForEntry(entry)
        return false
    end

    runtime_stats.inc("homing_retarget_attempted")
    local current_target = targetPosition(entry)
    local candidate, err, counts = selectRetargetCandidate(entry, projectile_position, current_direction)
    if counts ~= nil then
        runtime_stats.inc("homing_retarget_candidates_seen", counts.candidates)
        runtime_stats.inc("homing_retarget_creature_candidates", counts.creature)
        runtime_stats.inc("homing_retarget_npc_candidates", counts.npc)
        runtime_stats.inc("homing_retarget_actor_candidates", counts.actor)
        runtime_stats.inc("homing_retarget_cone_rejected", counts.cone_rejected)
    end
    entry.next_retarget_time = now_seconds + retargetIntervalForEntry(entry)

    if candidate == nil then
        runtime_stats.inc("homing_target_missing")
        log.info(string.format(
            "SPELLFORGE_SOFT_HOMING_RETARGET_SKIPPED entry_id=%s projectile_id=%s reason=%s radius=%s inspected=%s candidate_count=%s candidate_cap=%s cone_rejections=%s creature_candidates=%s npc_candidates=%s",
            tostring(entry.entry_id),
            tostring(entry.projectile_id),
            tostring(err or "homing_retarget_target_missing"),
            tostring(counts and counts.radius or 0),
            tostring(counts and counts.inspected or 0),
            tostring(counts and counts.candidates or 0),
            tostring(counts and counts.candidate_cap or 0),
            tostring(counts and counts.cone_rejected or 0),
            tostring(counts and counts.creature or 0),
            tostring(counts and counts.npc or 0)
        ))
        return false
    end

    local reason, previous_distance_sq = retargetReason(entry, projectile_position, current_target, current_direction, candidate)
    if reason == nil then
        runtime_stats.inc("homing_retarget_skipped_not_better")
        return false
    end

    local old_target_id = entry.target_id
    entry.target_id = candidate.id
    entry.target_object = candidate.object
    entry.target_position = candidate.position
    entry.target_provider = "retarget_actor_scan"
    entry.target_kind = candidate.kind
    entry.static_overshot_searching = false
    entry.retarget_count = (entry.retarget_count or 0) + 1
    runtime_stats.inc("homing_retarget_ok")
    runtime_stats.inc("homing_target_acquired")
    log.info(string.format(
        "SPELLFORGE_SOFT_HOMING_RETARGET_OK entry_id=%s projectile_id=%s old_target_id=%s new_target_id=%s target_kind=%s reason=%s retarget_count=%s distance=%s previous_distance=%s radius=%s alignment=%s aim_error=%s forward=%s inspected=%s candidate_count=%s candidate_cap=%s cone_rejections=%s creature_candidates=%s npc_candidates=%s",
        tostring(entry.entry_id),
        tostring(entry.projectile_id),
        tostring(old_target_id),
        tostring(entry.target_id),
        tostring(entry.target_kind),
        tostring(reason),
        tostring(entry.retarget_count),
        tostring(candidate.distance_sq and math.sqrt(candidate.distance_sq) or nil),
        tostring(previous_distance_sq and math.sqrt(previous_distance_sq) or nil),
        tostring(counts and counts.radius or 0),
        tostring(candidate.alignment),
        tostring(candidate.aim_error),
        tostring(candidate.forward),
        tostring(counts and counts.inspected or 0),
        tostring(counts and counts.candidates or 0),
        tostring(counts and counts.candidate_cap or 0),
        tostring(counts and counts.cone_rejected or 0),
        tostring(counts and counts.creature or 0),
        tostring(counts and counts.npc or 0)
    ))
    return true
end

local function blendedDirection(current_direction, target_direction)
    if target_direction == nil then
        return nil
    end
    local current = normalize(current_direction)
    if current == nil then
        return target_direction
    end
    local blend = clampUnit(limits.HOMING_REDIRECT_BLEND, 0.25)
    local ok, direction = pcall(function()
        return normalize((current * (1 - blend)) + (target_direction * blend))
    end)
    if ok and direction ~= nil then
        runtime_stats.inc("homing_redirect_blended")
        return direction
    end
    return target_direction
end

local function requestState(entry)
    local projectile_id = entry.projectile_id
    if projectile_id == nil then
        runtime_stats.inc("homing_state_failed")
        retire(entry, "missing_state")
        return false
    end
    entry.state_request_count = (entry.state_request_count or 0) + 1
    local tag = TAG_PREFIX .. tostring(entry.entry_id) .. ":" .. tostring(entry.state_request_count)
    entry.pending_tag = tag
    entry.pending_since = now_seconds
    pending_by_tag[tag] = entry.entry_id
    runtime_stats.inc("homing_state_requested")

    local requested = sfp_adapter.requestSpellState(projectile_id, tag)
    if requested.ok ~= true then
        pending_by_tag[tag] = nil
        entry.pending_tag = nil
        runtime_stats.inc("homing_state_failed")
        retire(entry, "api_failure")
        return false
    end
    return true
end

local function registerEntry(input)
    local options = input or {}
    local mode = options.registration_mode or "probe"
    local gate_ok = mode == "runtime" and dev.liveSoftHomingEnabled() or dev.liveSoftHomingProbeEnabled()
    if not gate_ok then
        runtime_stats.inc(mode == "runtime" and "homing_runtime_rejected_disabled" or "homing_probe_rejected_disabled")
        return { ok = false, error = mode == "runtime" and "soft_homing_disabled" or "soft_homing_probe_disabled" }
    end
    if activeCount() >= (limits.MAX_HOMING_PROJECTILES_ACTIVE or 4) then
        runtime_stats.inc("homing_probe_rejected_cap")
        return { ok = false, error = "soft_homing_active_cap" }
    end

    local projectile_id = options.projectile_id
    if projectile_id == nil then
        runtime_stats.inc("homing_state_failed")
        return { ok = false, error = "projectile_id_missing" }
    end

    local target_position = vectorFromPosition(options.target_position or options.homing_target_position, 0)
    if target_position == nil and options.target_object ~= nil then
        target_position = vectorFromPosition(options.target_object, softAimHeightForKind(options.target_kind or actorKind(options.target_object)))
    end
    if target_position == nil then
        runtime_stats.inc("homing_target_missing")
        return { ok = false, error = "homing_target_missing" }
    end

    local capabilities = sfp_adapter.capabilities()
    if capabilities.has_getSpellState ~= true or capabilities.has_redirectSpell ~= true then
        runtime_stats.inc("homing_state_failed")
        return { ok = false, error = "soft_homing_sfp_api_missing" }
    end

    local entry_id = string.format("soft_homing_%d", next_entry_index)
    next_entry_index = next_entry_index + 1
    local entry = {
        entry_id = entry_id,
        projectile_id = projectile_id,
        cast_id = options.cast_id,
        recipe_id = options.recipe_id,
        slot_id = options.slot_id,
        helper_engine_id = options.helper_engine_id,
        job_id = options.job_id,
        caster = options.caster,
        target_id = options.target_id,
        target_object = options.target_object,
        target_position = target_position,
        target_provider = options.target_provider,
        target_kind = options.target_kind,
        caster_id = objectToken(options.caster),
        start_time = now_seconds,
        next_steer_time = now_seconds + (limits.HOMING_INITIAL_STEER_DELAY_SECONDS or limits.HOMING_STEER_INTERVAL_SECONDS or 0.25),
        next_retarget_time = now_seconds + (limits.HOMING_INITIAL_STEER_DELAY_SECONDS or limits.HOMING_STEER_INTERVAL_SECONDS or 0.25),
        max_lifetime = finiteNonNegative(options.max_lifetime, limits.HOMING_MAX_LIFETIME_SECONDS or 3.0),
        redirect_count = 0,
        state_ok_count = 0,
        retarget_count = 0,
        registration_mode = mode,
    }
    entries[entry_id] = entry
    order[#order + 1] = entry_id
    runtime_stats.inc(mode == "runtime" and "homing_runtime_registered" or "homing_probe_registered")
    runtime_stats.inc("homing_target_acquired")
    runtime_stats.max("homing_active_max_observed", activeCount())
    log.info(string.format(
        "%s entry_id=%s projectile_id=%s recipe_id=%s cast_id=%s slot_id=%s helper_engine_id=%s target_id=%s provider=%s target_kind=%s active=%s",
        mode == "runtime" and "SPELLFORGE_SOFT_HOMING_REGISTERED" or "SPELLFORGE_SOFT_HOMING_PROBE_REGISTERED",
        tostring(entry_id),
        tostring(projectile_id),
        tostring(entry.recipe_id),
        tostring(entry.cast_id),
        tostring(entry.slot_id),
        tostring(entry.helper_engine_id),
        tostring(entry.target_id),
        tostring(entry.target_provider),
        tostring(entry.target_kind),
        tostring(activeCount())
    ))
    return {
        ok = true,
        entry_id = entry_id,
        projectile_id = projectile_id,
        active_count = activeCount(),
        target_position_key = vectorKey(target_position),
    }
end

function live_soft_homing.registerProbe(input)
    local opts = input or {}
    opts.registration_mode = "probe"
    return registerEntry(opts)
end

function live_soft_homing.registerRuntime(input)
    local opts = input or {}
    opts.registration_mode = "runtime"
    return registerEntry(opts)
end

function live_soft_homing.onResolvedHit(hit)
    local projectile_id = hit and hit.projectile_id or nil
    if projectile_id == nil then
        return
    end
    for _, entry_id in ipairs(order) do
        local entry = entries[entry_id]
        if entry and entry.projectile_id == projectile_id then
            retire(entry, "hit")
            return
        end
    end
end

function live_soft_homing.onSpellState(payload)
    local tag = payload and payload.tag or nil
    local entry_id = tag and pending_by_tag[tag] or nil
    if not entry_id then
        return false
    end
    pending_by_tag[tag] = nil
    local entry = entries[entry_id]
    if not entry or entry.retired then
        return true
    end
    entry.pending_tag = nil
    entry.pending_since = nil
    entry.state_ok_count = (entry.state_ok_count or 0) + 1
    runtime_stats.inc("homing_state_ok")
    projectile_registry.markState(entry.projectile_id, payload)

    local position = vectorFromPosition(payload and payload.position, 0)
    local state_direction = vectorFromPosition(payload and (payload.direction or payload.velocity), 0)
    maybeRetarget(entry, position, state_direction)
    local target = targetPosition(entry)
    if entry.target_object == nil and targetBehindDirection(position, target, state_direction) then
        enterStaticOvershotSearch(entry)
        entry.next_steer_time = now_seconds + (limits.HOMING_STEER_INTERVAL_SECONDS or 0.25)
        return true
    end
    local target_direction = position and target and normalize(target - position) or nil
    if target_direction == nil then
        runtime_stats.inc("homing_target_missing")
        retire(entry, "missing_state")
        return true
    end
    local direction = blendedDirection(state_direction, target_direction)

    runtime_stats.inc("homing_redirect_attempted")
    local result = sfp_adapter.redirectSpell(entry.projectile_id, direction)
    if result.ok == true then
        entry.redirect_count = (entry.redirect_count or 0) + 1
        entry.next_steer_time = now_seconds + (limits.HOMING_STEER_INTERVAL_SECONDS or 0.25)
        runtime_stats.inc("homing_redirect_ok")
        log.info(string.format(
            "SPELLFORGE_SOFT_HOMING_REDIRECT_OK entry_id=%s projectile_id=%s redirect_count=%s target_id=%s target_provider=%s target_kind=%s retarget_count=%s direction_key=%s target_direction_key=%s blend=%s",
            tostring(entry.entry_id),
            tostring(entry.projectile_id),
            tostring(entry.redirect_count),
            tostring(entry.target_id),
            tostring(entry.target_provider),
            tostring(entry.target_kind),
            tostring(entry.retarget_count or 0),
            tostring(vectorKey(direction)),
            tostring(vectorKey(target_direction)),
            tostring(limits.HOMING_REDIRECT_BLEND or 0.25)
        ))
    else
        runtime_stats.inc("homing_redirect_failed")
        retire(entry, "api_failure")
    end
    return true
end

function live_soft_homing.onUpdate(dt)
    local delta = finiteNonNegative(dt, 0)
    now_seconds = now_seconds + delta
    if activeCount() == 0 then
        return
    end
    runtime_stats.inc("homing_tick_runs")

    local snapshot = {}
    for _, entry_id in ipairs(order) do
        snapshot[#snapshot + 1] = entry_id
    end

    local considered = 0
    local max_updates = limits.MAX_HOMING_UPDATES_PER_TICK or 2
    for _, entry_id in ipairs(snapshot) do
        if considered >= max_updates then
            break
        end
        local entry = entries[entry_id]
        if entry and not entry.retired then
            local registry_entry = projectile_registry.getByProjectileId(entry.projectile_id)
            if registry_entry and registry_entry.hit == true then
                retire(entry, "hit")
            elseif now_seconds - entry.start_time >= entry.max_lifetime then
                retire(entry, "timeout")
            elseif entry.pending_tag and now_seconds - (entry.pending_since or now_seconds) > (limits.HOMING_STATE_TIMEOUT_SECONDS or 0.75) then
                runtime_stats.inc("homing_state_failed")
                retire(entry, "missing_state")
            elseif entry.pending_tag == nil
                and (entry.redirect_count or 0) < (limits.HOMING_MAX_REDIRECTS_PER_PROJECTILE or 3)
                and now_seconds >= (entry.next_steer_time or now_seconds) then
                runtime_stats.inc("homing_entries_considered")
                runtime_stats.inc("homing_entries_updated")
                considered = considered + 1
                requestState(entry)
            end
        end
    end
    if considered == 0 and activeCount() > 0 then
        runtime_stats.inc("homing_retarget_skipped_cooldown")
    end
end

function live_soft_homing.summary()
    return {
        active_count = activeCount(),
        pending_state_count = (function()
            local count = 0
            for _ in pairs(pending_by_tag) do
                count = count + 1
            end
            return count
        end)(),
    }
end

function live_soft_homing.clearForTests()
    entries = {}
    order = {}
    pending_by_tag = {}
    next_entry_index = 1
    now_seconds = 0
    retarget_budget_window = nil
    retarget_scans_in_window = 0
end

return live_soft_homing
