local helper_records = require("scripts.spellforge.global.helper_records")
local projectile_registry = require("scripts.spellforge.global.projectile_registry")
local sfp_adapter = require("scripts.spellforge.global.sfp_adapter")

local runtime_hits = {}

function runtime_hits.firstEffectId(helper)
    local first_effect = helper and helper.effects and helper.effects[1] or nil
    return first_effect and first_effect.id or nil
end

function runtime_hits.resolveHelperHit(payload)
    local engine_id = payload and (payload.spellId or payload.spell_id) or nil
    local projectile, projectile_id, projectile_id_source = sfp_adapter.extractProjectileFromHit(payload)
    local telemetry = sfp_adapter.magicHitTelemetry(payload)
    local registry_entry = projectile_id and projectile_registry.getByProjectileId(projectile_id) or nil

    local mapping = nil
    if type(engine_id) == "string" and engine_id ~= "" then
        mapping = helper_records.getByEngineId(engine_id)
    end
    if not mapping and registry_entry then
        mapping = helper_records.getByEngineId(registry_entry.helper_engine_id)
        engine_id = registry_entry.helper_engine_id
    end
    if type(engine_id) ~= "string" or engine_id == "" then
        return {
            ok = false,
            projectile = projectile,
            projectile_id = projectile_id,
            projectile_id_source = projectile_id_source,
            telemetry = telemetry,
            error = "hit payload missing spellId",
        }
    end
    if not mapping then
        return {
            ok = false,
            engine_id = engine_id,
            projectile = projectile,
            projectile_id = projectile_id,
            projectile_id_source = projectile_id_source,
            telemetry = telemetry,
            error = string.format("helper record metadata not found for engine_id=%s", tostring(engine_id)),
        }
    end

    local hit_record = projectile_registry.markHit(projectile_id, mapping.engine_id, payload, telemetry, {
        recipe_id = mapping.recipe_id,
        slot_id = mapping.slot_id,
    })
    registry_entry = (hit_record and hit_record.entry) or registry_entry

    return {
        ok = true,
        error = nil,
        duplicate = hit_record and hit_record.first_hit == false or false,
        first_hit = hit_record and hit_record.first_hit or false,
        hit_key = hit_record and hit_record.hit_key or nil,
        previous = hit_record and hit_record.previous or nil,
        mapping = mapping,
        recipe_id = mapping.recipe_id,
        slot_id = mapping.slot_id,
        helper_engine_id = mapping.engine_id,
        effect_id = runtime_hits.firstEffectId(mapping),
        projectile = projectile,
        projectile_id = projectile_id,
        projectile_id_source = projectile_id_source,
        projectile_registry_entry = registry_entry,
        hit_record = hit_record,
        telemetry = telemetry,
        impactSpeed = telemetry and telemetry.impactSpeed or nil,
        maxSpeed = telemetry and telemetry.maxSpeed or nil,
        velocity = telemetry and telemetry.velocity or nil,
        magMin = telemetry and telemetry.magMin or nil,
        magMax = telemetry and telemetry.magMax or nil,
        casterLinked = telemetry and telemetry.casterLinked or nil,
        stackLimit = telemetry and telemetry.stackLimit or nil,
        stackCount = telemetry and telemetry.stackCount or nil,
        hit_pos = payload and (payload.hitPos or payload.hit_pos) or nil,
        hit_normal = payload and (payload.hitNormal or payload.hit_normal) or nil,
        attacker = payload and payload.attacker or nil,
        target = payload and payload.target or nil,
        raw_payload = payload,
    }
end

return runtime_hits
