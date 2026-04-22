local async = require("openmw.async")
local camera = require("openmw.camera")
local core = require("openmw.core")
local input = require("openmw.input")
local nearby = require("openmw.nearby")
local self = require("openmw.self")
local types = require("openmw.types")
local util = require("openmw.util")

local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("player.init")

local INTERCEPT_DELAY = 0.94

local state = {
    backend = "INIT",
    handshake_timer = nil,
    unavailable_logged = false,
    is_casting = false,
    pending_query = {},
}

local function firstKnownSpellId()
    for _, record in pairs(core.magic.spells.records) do
        if record and type(record.id) == "string" and record.id ~= "" then
            return record.id
        end
    end
    return nil
end

local function cancelHandshakeTimer()
    if state.handshake_timer then
        state.handshake_timer:cancel()
        state.handshake_timer = nil
    end
end

local function requestBackend()
    state.backend = "PENDING"
    core.sendGlobalEvent(events.CHECK_BACKEND, {
        sender = self.object,
    })

    cancelHandshakeTimer()
    state.handshake_timer = async:newUnsavableSimulationTimer(3, function()
        if state.backend == "PENDING" then
            state.backend = "UNAVAILABLE"
            if not state.unavailable_logged then
                log.warn("backend handshake timeout after 3 seconds")
                state.unavailable_logged = true
            end
        end
    end)
end

local function compileHardcodedRecipe()
    if state.backend ~= "READY" then
        if not state.unavailable_logged then
            log.warn("compile hotkey ignored: backend not ready")
            state.unavailable_logged = true
        end
        return
    end

    local base_spell_id = firstKnownSpellId()
    if not base_spell_id then
        log.error("compile hotkey failed: no base spell IDs available")
        return
    end

    local request_id = string.format("dev-%d", os.time())
    local recipe = {
        nodes = {
            { kind = "emitter", base_spell_id = base_spell_id },
        },
    }

    core.sendGlobalEvent(events.COMPILE_RECIPE, {
        sender = self.object,
        actor = self,
        actor_id = self.recordId,
        request_id = request_id,
        recipe = recipe,
    })
end

local function resolveSpellSource()
    local selected = core.magic.getSelectedSpell and core.magic.getSelectedSpell()
    if selected and selected.id then
        return selected.id
    end

    selected = types.Player.getSelectedSpell and types.Player.getSelectedSpell(self)
    if selected and selected.id then
        return selected.id
    end

    selected = types.Player.getSelectedEnchantedItem and types.Player.getSelectedEnchantedItem(self)
    if selected and selected.id then
        return selected.id
    end

    selected = types.Actor.getSelectedSpell and types.Actor.getSelectedSpell(self)
    if selected and selected.id then
        return selected.id
    end

    return nil
end

local function getCameraCastData()
    local cp = -camera.getPitch()
    local cy = camera.getYaw()
    local direction = util.vector3(
        math.cos(cp) * math.sin(cy),
        math.cos(cp) * math.cos(cy),
        math.sin(cp)
    )
    local start_pos = camera.getPosition()

    local ray = nearby.castRay(start_pos, start_pos + (direction * 500), { ignore = self })
    local hit_object = nil
    if ray.hit and ray.hitObject then
        hit_object = ray.hitObject
    end

    return start_pos, direction, hit_object, ray.hitPos or start_pos
end

local function dispatchIntercept(spell_id)
    local start_pos, direction, hit_object, hit_pos = getCameraCastData()
    core.sendGlobalEvent(events.INTERCEPT_CAST, {
        sender = self,
        spell_id = spell_id,
        start_pos = start_pos,
        direction = direction,
        hit_object = hit_object,
        hit_pos = hit_pos,
    })
end

local function queueIntercept(spell_id)
    if state.is_casting then
        return
    end

    local magicka = types.Actor.stats.dynamic.magicka(self).current
    local spell = core.magic.spells.records[spell_id]
    if not spell or magicka < (spell.cost or 0) then
        return
    end

    state.is_casting = true
    async:newUnsavableSimulationTimer(INTERCEPT_DELAY, function()
        state.is_casting = false
        if types.Actor.getStance(self) ~= types.Actor.STANCE.Spell then
            return
        end
        local selected_spell_id = resolveSpellSource()
        if selected_spell_id ~= spell_id then
            return
        end
        dispatchIntercept(spell_id)
    end)
end

local function querySpellOwnership(spell_id)
    local request_id = string.format("query-%d-%d", os.time(), math.random(1, 99999))
    state.pending_query[request_id] = spell_id
    core.sendGlobalEvent(events.QUERY_COMPILED_SPELL, {
        sender = self.object,
        request_id = request_id,
        spell_id = spell_id,
    })
end

local function onBackendReady(payload)
    cancelHandshakeTimer()
    state.backend = "READY"
    state.unavailable_logged = false
    log.info(string.format("backend ready version=%s", tostring(payload and payload.backend_version)))
end

local function onBackendUnavailable(payload)
    cancelHandshakeTimer()
    state.backend = "UNAVAILABLE"
    if not state.unavailable_logged then
        log.warn(string.format("backend unavailable: %s", tostring(payload and payload.reason)))
        state.unavailable_logged = true
    end
end

local function onCompileResult(payload)
    if payload.ok then
        log.info(string.format("compile success recipe_id=%s engine_spell_id=%s reused=%s", tostring(payload.recipe_id), tostring(payload.spell_id), tostring(payload.reused)))
    else
        log.error(string.format("compile failed request=%s error=%s", tostring(payload.request_id), tostring(payload.error or "validation failed")))
    end
end

local function onKeyPress(key)
    local symbol = key.symbol and string.lower(key.symbol) or ""
    if symbol == "k" or key.code == input.KEY.K then
        compileHardcodedRecipe()
        return false
    end
    return true
end

local function onInputAction(action)
    if action ~= input.ACTION.Use then
        return
    end
    if state.backend ~= "READY" then
        return
    end
    if types.Actor.getStance(self) ~= types.Actor.STANCE.Spell then
        return
    end

    local spell_id = resolveSpellSource()
    if not spell_id then
        return
    end

    querySpellOwnership(spell_id)
end

return {
    engineHandlers = {
        onFrame = function()
            if state.backend == "INIT" then
                requestBackend()
            end
        end,
        onKeyPress = onKeyPress,
        onInputAction = onInputAction,
    },
    eventHandlers = {
        [events.BACKEND_READY] = onBackendReady,
        [events.BACKEND_UNAVAILABLE] = onBackendUnavailable,
        [events.COMPILE_RESULT] = onCompileResult,
        [events.QUERY_COMPILED_SPELL_RESULT] = function(payload)
            local request_id = payload and payload.request_id
            local spell_id = request_id and state.pending_query[request_id]
            if not spell_id then
                return
            end
            state.pending_query[request_id] = nil
            if payload.ours == true and payload.spell_id == spell_id then
                queueIntercept(spell_id)
            end
        end,
    },
}
