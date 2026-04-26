local interfaces = require("openmw.interfaces")

local sfp_adapter = {}

local MAGIC_HIT_TELEMETRY_FIELDS = {
    "impactSpeed",
    "maxSpeed",
    "velocity",
    "magMin",
    "magMax",
    "casterLinked",
    "stackLimit",
    "stackCount",
}

local function magExp()
    return interfaces.MagExp
end

local function hasFunction(name)
    local mag = magExp()
    return mag ~= nil and type(mag[name]) == "function"
end

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

local function normalizeId(value)
    if value == nil then
        return nil
    end
    local value_type = type(value)
    if value_type == "string" then
        if value == "" then
            return nil
        end
        return value
    elseif value_type == "number" then
        return tostring(value)
    end
    return nil
end

function sfp_adapter.extractProjectileId(projectile)
    local direct = normalizeId(projectile)
    if direct then
        return direct, "direct"
    end

    local id = normalizeId(readField(projectile, "id"))
    if id then
        return id, "id"
    end

    id = normalizeId(readField(projectile, "projId"))
    if id then
        return id, "projId"
    end

    id = normalizeId(readField(projectile, "projectileId"))
    if id then
        return id, "projectileId"
    end

    return nil, nil
end

function sfp_adapter.extractProjectileFromHit(payload)
    local data = payload or {}
    local projectile = data.projectile or data.proj or data.spellProjectile
    local projectile_id = normalizeId(data.projectile_id)
        or normalizeId(data.projectileId)
        or normalizeId(data.proj_id)
        or normalizeId(data.projId)

    local id_source = nil
    if projectile_id then
        id_source = "payload"
    elseif projectile ~= nil then
        projectile_id, id_source = sfp_adapter.extractProjectileId(projectile)
        if id_source then
            id_source = "projectile." .. id_source
        end
    end

    return projectile, projectile_id, id_source
end

function sfp_adapter.magicHitTelemetry(payload)
    local data = payload or {}
    local telemetry = {}
    local present_count = 0
    for _, field in ipairs(MAGIC_HIT_TELEMETRY_FIELDS) do
        local value = data[field]
        telemetry[field] = value
        telemetry["has_" .. field] = value ~= nil
        if value ~= nil then
            present_count = present_count + 1
        end
    end
    telemetry.present_count = present_count
    telemetry.has_any_beta2_fields = present_count > 0
    return telemetry
end

function sfp_adapter.capabilities()
    local mag = magExp()
    local has_launch_spell = hasFunction("launchSpell")
    return {
        has_interface = mag ~= nil,
        has_launchSpell = has_launch_spell,
        has_getActiveSpellIds = hasFunction("getActiveSpellIds"),
        has_getSpellState = hasFunction("getSpellState"),
        has_setSpellPhysics = hasFunction("setSpellPhysics"),
        has_redirectSpell = hasFunction("redirectSpell"),
        has_setSpellSpeed = hasFunction("setSpellSpeed"),
        has_setSpellPaused = hasFunction("setSpellPaused"),
        has_cancelSpell = hasFunction("cancelSpell"),
        has_setSpellBounce = hasFunction("setSpellBounce"),
        has_setSpellDetonateOnActor = hasFunction("setSpellDetonateOnActor"),
        has_detonateSpellAtPos = hasFunction("detonateSpellAtPos"),
        has_applySpellToActor = hasFunction("applySpellToActor"),
        has_emitProjectileFromObject = hasFunction("emitProjectileFromObject"),
        has_addTargetFilter = hasFunction("addTargetFilter"),
        has_setTargetFilter = hasFunction("setTargetFilter"),
        has_impactImpulse_field = mag ~= nil and has_launch_spell,
        has_impactImpulse_launch_field = mag ~= nil and has_launch_spell,
        has_magic_hit_impactSpeed = false,
        has_magic_hit_magMin_magMax = false,
        has_magic_hit_casterLinked = false,
    }
end

local function callFunction(name, ...)
    local mag = magExp()
    if mag == nil then
        return { ok = false, capability = false, error = "I.MagExp missing" }
    end
    local fn = mag[name]
    if type(fn) ~= "function" then
        return { ok = false, capability = false, error = "I.MagExp." .. name .. " missing" }
    end

    local ok, result = pcall(fn, ...)
    if not ok then
        return { ok = false, capability = true, error = tostring(result) }
    end
    return { ok = true, capability = true, result = result }
end

function sfp_adapter.launchSpell(data)
    local result = callFunction("launchSpell", data)
    if not result.ok then
        return result
    end

    local projectile = result.result
    local projectile_id, projectile_id_source = sfp_adapter.extractProjectileId(projectile)
    result.projectile = projectile
    result.projectile_id = projectile_id
    result.projectile_id_source = projectile_id_source
    result.launch_result_raw = projectile
    result.launch_returns_projectile = projectile ~= nil
    result.can_extract_projectile_id = projectile_id ~= nil
    result.warnings = {}
    result.capability_notes = {
        launch_returns_projectile = result.launch_returns_projectile,
        can_extract_projectile_id = result.can_extract_projectile_id,
    }
    return result
end

function sfp_adapter.getActiveSpellIds()
    return callFunction("getActiveSpellIds")
end

function sfp_adapter.requestSpellState(projectile_id, tag)
    if projectile_id == nil then
        return { ok = false, capability = false, error = "projectile_id missing" }
    end
    return callFunction("getSpellState", projectile_id, tag)
end

function sfp_adapter.setSpellPhysics(projectile_id, data)
    return callFunction("setSpellPhysics", projectile_id, data)
end

function sfp_adapter.redirectSpell(projectile_id, direction)
    return callFunction("redirectSpell", projectile_id, direction)
end

function sfp_adapter.setSpellSpeed(projectile_id, speed)
    return callFunction("setSpellSpeed", projectile_id, speed)
end

function sfp_adapter.setSpellPaused(projectile_id, paused)
    return callFunction("setSpellPaused", projectile_id, paused)
end

function sfp_adapter.cancelSpell(projectile_id)
    return callFunction("cancelSpell", projectile_id)
end

function sfp_adapter.setSpellBounce(projectile_id, enabled, max, power)
    return callFunction("setSpellBounce", projectile_id, enabled, max, power)
end

function sfp_adapter.setSpellDetonateOnActor(projectile_id, enabled)
    return callFunction("setSpellDetonateOnActor", projectile_id, enabled)
end

function sfp_adapter.detonateSpellAtPos(spell_id, caster, pos, cell, item)
    return callFunction("detonateSpellAtPos", spell_id, caster, pos, cell, item)
end

function sfp_adapter.applySpellToActor(spell_id, caster, target, hit_pos, is_aoe, item)
    return callFunction("applySpellToActor", spell_id, caster, target, hit_pos, is_aoe, item)
end

function sfp_adapter.emitProjectileFromObject(data)
    return callFunction("emitProjectileFromObject", data)
end

function sfp_adapter.registerTargetFilter(fn)
    if type(fn) ~= "function" then
        return { ok = false, capability = false, error = "target filter must be a function" }
    end
    if hasFunction("addTargetFilter") then
        return callFunction("addTargetFilter", fn)
    end
    if hasFunction("setTargetFilter") then
        return callFunction("setTargetFilter", fn)
    end
    return { ok = false, capability = false, error = "I.MagExp target filter API missing" }
end

return sfp_adapter
