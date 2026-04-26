local sfp_adapter = require("scripts.spellforge.global.sfp_adapter")

local projectile_registry = {}

local by_projectile_id = {}
local projectile_ids_by_helper = {}
local projectile_ids_by_recipe = {}
local projectile_ids_by_slot = {}
local last_launch_by_helper = {}
local last_hit_by_helper = {}
local by_launch_instance_id = {}
local processed_hits = {}
local next_launch_index = 1

local function appendList(map, key, value)
    if key == nil or value == nil then
        return
    end
    local list = map[key]
    if not list then
        list = {}
        map[key] = list
    end
    list[#list + 1] = value
end

local function cloneList(list)
    local out = {}
    for i, value in ipairs(list or {}) do
        out[i] = value
    end
    return out
end

local function compactLaunchResult(launch_result)
    local result = launch_result or {}
    return {
        ok = result.ok == true,
        capability = result.capability,
        projectile_id = result.projectile_id,
        projectile_id_source = result.projectile_id_source,
        launch_returns_projectile = result.launch_returns_projectile == true,
        can_extract_projectile_id = result.can_extract_projectile_id == true,
        warnings = result.warnings,
        capability_notes = result.capability_notes,
    }
end

function projectile_registry.registerLaunch(launch_result, metadata)
    local result = launch_result or {}
    local input = metadata or {}
    local projectile_id = result.projectile_id
    local launch_instance_id = string.format("launch_%d", next_launch_index)
    next_launch_index = next_launch_index + 1
    local entry = {
        launch_instance_id = launch_instance_id,
        projectile_id = projectile_id,
        projectile_id_source = result.projectile_id_source,
        projectile = result.projectile,
        helper_engine_id = input.helper_engine_id,
        recipe_id = input.recipe_id,
        slot_id = input.slot_id,
        job_id = input.job_id,
        job_kind = input.job_kind,
        source_job_id = input.source_job_id,
        parent_job_id = input.parent_job_id,
        reason = input.reason or input.kind,
        start_pos = input.start_pos,
        direction = input.direction,
        launch_result = compactLaunchResult(result),
        hit = false,
        hit_payload = nil,
        telemetry = nil,
        last_state = nil,
    }

    if entry.helper_engine_id then
        last_launch_by_helper[entry.helper_engine_id] = entry
    end
    by_launch_instance_id[launch_instance_id] = entry

    if projectile_id ~= nil then
        by_projectile_id[projectile_id] = entry
        appendList(projectile_ids_by_helper, entry.helper_engine_id, projectile_id)
        appendList(projectile_ids_by_recipe, entry.recipe_id, projectile_id)
        appendList(projectile_ids_by_slot, entry.slot_id, projectile_id)
    end

    return entry
end

function projectile_registry.hitKey(projectile_id, helper_engine_id, metadata)
    if projectile_id ~= nil then
        return "projectile:" .. tostring(projectile_id)
    end

    local input = metadata or {}
    return string.format(
        "helper:%s:%s:%s",
        tostring(input.recipe_id),
        tostring(input.slot_id),
        tostring(helper_engine_id)
    )
end

function projectile_registry.getByProjectileId(projectile_id)
    return by_projectile_id[projectile_id]
end

function projectile_registry.getProjectilesForHelper(helper_engine_id)
    return cloneList(projectile_ids_by_helper[helper_engine_id])
end

function projectile_registry.getProjectilesForRecipe(recipe_id)
    return cloneList(projectile_ids_by_recipe[recipe_id])
end

function projectile_registry.getProjectilesForSlot(slot_id)
    return cloneList(projectile_ids_by_slot[slot_id])
end

function projectile_registry.getLastLaunchForHelper(helper_engine_id)
    return last_launch_by_helper[helper_engine_id]
end

function projectile_registry.getLastHitForHelper(helper_engine_id)
    return last_hit_by_helper[helper_engine_id]
end

function projectile_registry.markHit(projectile_id, helper_engine_id, hit_payload, telemetry, metadata)
    local input = metadata or {}
    local entry = projectile_id and by_projectile_id[projectile_id] or nil
    if not entry and input.launch_instance_id then
        entry = by_launch_instance_id[input.launch_instance_id]
    end
    if not entry and helper_engine_id then
        entry = last_launch_by_helper[helper_engine_id]
    end

    local hit_key = projectile_registry.hitKey(projectile_id, helper_engine_id, {
        recipe_id = input.recipe_id or (entry and entry.recipe_id),
        slot_id = input.slot_id or (entry and entry.slot_id),
    })
    local previous = processed_hits[hit_key]
    local hit_record = {
        ok = true,
        first_hit = previous == nil,
        hit_key = hit_key,
        previous = previous,
        entry = entry,
        projectile_id = projectile_id,
        helper_engine_id = helper_engine_id,
        hit_payload = hit_payload,
        telemetry = telemetry or sfp_adapter.magicHitTelemetry(hit_payload),
    }
    if previous == nil then
        processed_hits[hit_key] = hit_record
    end

    if entry then
        entry.hit = true
        entry.hit_payload = hit_payload
        entry.telemetry = hit_record.telemetry
        entry.last_hit_key = hit_key
    end

    if helper_engine_id then
        last_hit_by_helper[helper_engine_id] = hit_record
    end

    return hit_record
end

function projectile_registry.markState(projectile_id, state_payload)
    local entry = projectile_id and by_projectile_id[projectile_id] or nil
    if entry then
        entry.last_state = state_payload
    end
    return entry
end

function projectile_registry.clearHitMarksForTests()
    last_hit_by_helper = {}
    processed_hits = {}
end

function projectile_registry.clearForTests()
    by_projectile_id = {}
    projectile_ids_by_helper = {}
    projectile_ids_by_recipe = {}
    projectile_ids_by_slot = {}
    last_launch_by_helper = {}
    last_hit_by_helper = {}
    by_launch_instance_id = {}
    processed_hits = {}
    next_launch_index = 1
end

return projectile_registry
