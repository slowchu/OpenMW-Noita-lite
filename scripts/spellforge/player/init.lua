local async = require("openmw.async")
local camera = require("openmw.camera")
local core = require("openmw.core")
local input = require("openmw.input")
local interfaces = require("openmw.interfaces")
local nearby = require("openmw.nearby")
local self = require("openmw.self")
local types = require("openmw.types")
local util = require("openmw.util")

local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("player.init")

local state = {
    backend = "INIT",
    handshake_timer = nil,
    unavailable_logged = false,
    is_casting = false,
    animation_diag_registered = false,
    pending_spell_queries = {},
    spell_metadata_cache = {},
    pending_metadata_by_spell_id = {},
    last_selected_spell_id = nil,
    pending_intercept_spell_id = nil,
    pending_intercept_variant = nil,
    intercept_spell_id = nil,
    intercept_variant = nil,
    pending_cast_authorized = false,
    skill_handler_registered = false,
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
    log.debug(string.format("compile request sent request_id=%s", request_id))
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
        log.error(string.format("compile failed request=%s error=%s", tostring(payload.request_id), tostring(payload.error or payload.error_message or "validation failed")))
    end
end

local function resolveSelectedSpell()
    if core.magic and type(core.magic.getSelectedSpell) == "function" then
        local spell = core.magic.getSelectedSpell()
        if spell and spell.id then
            return spell
        end
    end

    if types.Player and type(types.Player.getSelectedSpell) == "function" then
        local spell = types.Player.getSelectedSpell(self)
        if spell and spell.id then
            return spell
        end
    end

    if types.Player and type(types.Player.getSelectedEnchantedItem) == "function" then
        local enchanted = types.Player.getSelectedEnchantedItem(self)
        if enchanted and enchanted.id then
            return enchanted
        end
    end

    local actor_spell = types.Actor.getSelectedSpell(self)
    if actor_spell and actor_spell.id then
        return actor_spell
    end

    return nil
end

local function querySpellMetadata(spell_id, callback)
    local request_id = string.format("spell-query-%d", os.time() + math.random(1, 100000))
    state.pending_spell_queries[request_id] = callback
    core.sendGlobalEvent(events.QUERY_SPELL_METADATA, {
        sender = self.object,
        request_id = request_id,
        spell_id = spell_id,
    })

    async:newUnsavableSimulationTimer(0.25, function()
        if state.pending_spell_queries[request_id] then
            local cb = state.pending_spell_queries[request_id]
            state.pending_spell_queries[request_id] = nil
            cb({ is_spellforge = false, error = "metadata query timeout" })
        end
    end)
end

local function refreshSpellMetadata(spell_id, reason)
    if type(spell_id) ~= "string" or spell_id == "" then
        return
    end
    if state.backend ~= "READY" then
        return
    end
    if state.pending_metadata_by_spell_id[spell_id] then
        return
    end

    state.pending_metadata_by_spell_id[spell_id] = true
    querySpellMetadata(spell_id, function(meta)
        state.pending_metadata_by_spell_id[spell_id] = nil
        if type(meta) ~= "table" then
            state.spell_metadata_cache[spell_id] = {
                is_spellforge = false,
                updated_at = os.time(),
                error = "invalid metadata response",
            }
            return
        end

        state.spell_metadata_cache[spell_id] = {
            is_spellforge = meta.is_spellforge == true,
            recipe_id = meta.recipe_id,
            root_base_spell_id = meta.root_base_spell_id,
            frontend_spell_id = meta.frontend_spell_id,
            updated_at = os.time(),
            reason = reason,
            error = meta.error,
        }
        log.debug(string.format(
            "metadata cache updated spell_id=%s is_spellforge=%s reason=%s",
            tostring(spell_id),
            tostring(meta.is_spellforge == true),
            tostring(reason)
        ))
    end)
end

local function classifyVariant(root_base_spell_id)
    local base = root_base_spell_id and core.magic.spells.records[root_base_spell_id] or nil
    local range = base and base.effects and base.effects[1] and base.effects[1].range or nil

    -- OpenMW spell effect range in records is numeric in many runtimes:
    --   0=self, 1=touch, 2=target.
    -- Keep string handling for compatibility with environments exposing symbolic strings.
    if range == 2 or range == "target" or range == "Target" then
        return "target"
    end
    if range == 1 or range == "touch" or range == "Touch" then
        return "touch"
    end
    return "self"
end

local function canAffordSpell(spell_id)
    local spell_record = core.magic.spells.records[spell_id]
    if not spell_record then
        return false
    end
    local magicka = types.Actor.stats.dynamic.magicka(self)
    local current_magicka = magicka and magicka.current or 0
    return current_magicka >= (spell_record.cost or 0)
end

local function dispatchInterceptCast(spell_id)
    local cp = -camera.getPitch()
    local cy = camera.getYaw()
    local camera_dir = util.vector3(
        math.cos(cp) * math.sin(cy),
        math.cos(cp) * math.cos(cy),
        math.sin(cp)
    )

    local start_pos = camera.getPosition()
    local hit_object = nil
    local hit_pos = start_pos

    local ray = nearby.castRay(start_pos, start_pos + (camera_dir * 500), { ignore = self })
    if ray and ray.hit and ray.hitObject then
        hit_object = ray.hitObject
    end
    if ray and ray.hitPos then
        hit_pos = ray.hitPos
    end

    core.sendGlobalEvent(events.INTERCEPT_CAST, {
        sender = self.object,
        spell_id = spell_id,
        start_pos = start_pos,
        direction = camera_dir,
        hit_object = hit_object,
        hit_pos = hit_pos,
    })

    log.info(string.format("intercept dispatch sent spell_id=%s", tostring(spell_id)))
end

local function sendDebugVanillaFireball()
    local cp = -camera.getPitch()
    local cy = camera.getYaw()
    local camera_dir = util.vector3(
        math.cos(cp) * math.sin(cy),
        math.cos(cp) * math.cos(cy),
        math.sin(cp)
    )

    local start_pos = camera.getPosition()
    local hit_object = nil
    local hit_pos = start_pos

    local ray = nearby.castRay(start_pos, start_pos + (camera_dir * 500), { ignore = self })
    if ray and ray.hit and ray.hitObject then
        hit_object = ray.hitObject
    end
    if ray and ray.hitPos then
        hit_pos = ray.hitPos
    end

    core.sendGlobalEvent(events.DEBUG_LAUNCH_VANILLA_FIREBALL, {
        sender = self.object,
        start_pos = start_pos,
        direction = camera_dir,
        hit_object = hit_object,
        hit_pos = hit_pos,
    })
    log.info(string.format(
        "debug vanilla fireball launch request sent start_pos=%s direction=%s hit_object=%s",
        tostring(start_pos),
        tostring(camera_dir),
        tostring(hit_object and hit_object.recordId or hit_object)
    ))
end

local function clearInterceptState()
    state.is_casting = false
    state.pending_intercept_spell_id = nil
    state.pending_intercept_variant = nil
    state.intercept_spell_id = nil
    state.intercept_variant = nil
    state.pending_cast_authorized = false
end

local function spellAlwaysSucceeds(spell_id)
    local spell_record = spell_id and core.magic.spells.records[spell_id] or nil
    if type(spell_record) ~= "table" then
        return false
    end

    if spell_record.alwaysSucceedFlag ~= nil then
        return spell_record.alwaysSucceedFlag == true or spell_record.alwaysSucceedFlag == 1
    end
    if spell_record.alwaysSucceed ~= nil then
        return spell_record.alwaysSucceed == true or spell_record.alwaysSucceed == 1
    end
    return false
end

local function registerSkillProgressionHandler()
    if state.skill_handler_registered then
        return
    end

    local progression = interfaces.SkillProgression
    if progression == nil or type(progression.addSkillUsedHandler) ~= "function" then
        log.warn("skill progression unavailable: addSkillUsedHandler missing")
        return
    end

    local use_types = progression.SKILL_USE_TYPES or {}
    local spellcast_success = use_types.Spellcast_Success
    if spellcast_success == nil then
        log.warn("skill progression unavailable: SKILL_USE_TYPES.Spellcast_Success missing")
        return
    end

    progression.addSkillUsedHandler(function(skillid, params)
        log.info(string.format(
            "SKILL_USED_RAW skillid=%s useType=%s",
            tostring(skillid),
            tostring(params and params.useType)
        ))

        local selected_spell = resolveSelectedSpell()
        local selected_spell_id = selected_spell and selected_spell.id or state.last_selected_spell_id
        local selected_meta = selected_spell_id and state.spell_metadata_cache[selected_spell_id] or nil
        local selected_is_cached_spellforge = selected_meta and selected_meta.is_spellforge == true or false
        local should_log_diag = state.pending_intercept_spell_id ~= nil
            or state.intercept_spell_id ~= nil
            or state.is_casting == true
            or selected_is_cached_spellforge

        if should_log_diag then
            log.info(string.format(
                "SPELLFORGE_SKILL_USE_DIAG skillid=%s useType=%s expectedSuccess=%s skill=%s source=%s actor=%s selected_spell_id=%s pending_spell_id=%s intercept_spell_id=%s is_casting=%s pending_cast_authorized=%s",
                tostring(skillid),
                tostring(params and params.useType),
                tostring(spellcast_success),
                tostring(params and params.skill),
                tostring(params and params.source),
                tostring(params and params.actor),
                tostring(selected_spell_id),
                tostring(state.pending_intercept_spell_id),
                tostring(state.intercept_spell_id),
                tostring(state.is_casting),
                tostring(state.pending_cast_authorized)
            ))
        end

        if not params or params.useType ~= spellcast_success then
            return
        end

        if selected_is_cached_spellforge and not state.is_casting and state.intercept_spell_id == nil and state.pending_intercept_spell_id == nil then
            log.info(string.format(
                "SPELLFORGE_SKILL_SUCCESS_OUTSIDE_INTERCEPT_WINDOW useType=%s selected_spell_id=%s",
                tostring(params.useType),
                tostring(selected_spell_id)
            ))
        end

        if state.is_casting then
            state.pending_cast_authorized = true
            log.info(string.format(
                "cast authorization received useType=%s active_spell_id=%s",
                tostring(params.useType),
                tostring(state.intercept_spell_id)
            ))
        end
    end)

    state.skill_handler_registered = true
    log.info("registered skill progression Spellcast_Success handler")
end

local function registerAnimationTextKeys()
    if state.animation_diag_registered then
        return
    end
    if interfaces.AnimationController == nil or type(interfaces.AnimationController.addTextKeyHandler) ~= "function" then
        log.warn("animation diagnostics unavailable: AnimationController.addTextKeyHandler missing")
        return
    end

    interfaces.AnimationController.addTextKeyHandler("spellcast", function(groupname, key)
        if groupname ~= "spellcast" then
            return
        end

        local selected_spell = resolveSelectedSpell()
        core.sendGlobalEvent(events.CAST_DIAG_SIGNAL, {
            sender = self.object,
            groupname = groupname,
            key = key,
            selected_spell_id = (selected_spell and selected_spell.id) or state.intercept_spell_id,
        })

        if not state.is_casting then
            local pending_spell_id = state.pending_intercept_spell_id
            local pending_variant = state.pending_intercept_variant or "self"
            if pending_spell_id and key == (pending_variant .. " start") then
                local always_succeed = spellAlwaysSucceeds(pending_spell_id)
                state.pending_cast_authorized = always_succeed == true
                state.is_casting = true
                state.intercept_spell_id = pending_spell_id
                state.intercept_variant = pending_variant
                state.pending_intercept_spell_id = nil
                state.pending_intercept_variant = nil
                log.info(string.format(
                    "intercept armed spell_id=%s variant=%s alwaysSucceed=%s authorized_initial=%s",
                    tostring(state.intercept_spell_id),
                    tostring(state.intercept_variant),
                    tostring(always_succeed),
                    tostring(state.pending_cast_authorized)
                ))
            end
            return
        end

        local variant = state.intercept_variant or "self"
        if key == (variant .. " release") then
            local spell_id = state.intercept_spell_id
            local authorized = state.pending_cast_authorized == true

            if types.Actor.getStance(self) ~= types.Actor.STANCE.Spell then
                clearInterceptState()
                log.info("intercept release aborted: stance changed")
                return
            end

            log.info(string.format(
                "intercept release spell_id=%s variant=%s authorized=%s",
                tostring(spell_id),
                tostring(variant),
                tostring(authorized)
            ))
            if spell_id and authorized then
                dispatchInterceptCast(spell_id)
            else
                local reason = authorized and "missing spell_id" or "no authorization"
                log.info(string.format(
                    "intercept release suppressed spell_id=%s reason=%s",
                    tostring(spell_id),
                    reason
                ))
                log.info(string.format(
                    "SPELLFORGE_COMPILED_DISPATCH_SUPPRESSED spell_id=%s authorized=%s reason=%s",
                    tostring(spell_id),
                    tostring(authorized),
                    tostring(reason)
                ))
            end
            clearInterceptState()
        elseif key == (variant .. " stop") then
            clearInterceptState()
            log.info("intercept canceled on stop key")
        end
    end)

    state.animation_diag_registered = true
    log.info("registered spellcast text-key handler")
end

local function onInputAction(action)
    if action ~= input.ACTION.Use then
        return true
    end

    if types.Actor.getStance(self) ~= types.Actor.STANCE.Spell then
        return true
    end

    local selected = resolveSelectedSpell()
    local selected_spell_id = selected and selected.id
    if type(selected_spell_id) ~= "string" or selected_spell_id == "" then
        return true
    end

    local meta = state.spell_metadata_cache[selected_spell_id]
    if not meta then
        refreshSpellMetadata(selected_spell_id, "input-miss")
        return true
    end
    if meta.is_spellforge ~= true then
        return true
    end

    if state.is_casting or state.pending_intercept_spell_id ~= nil then
        return true
    end

    if not canAffordSpell(selected_spell_id) then
        log.info(string.format("intercept skipped: insufficient magicka spell_id=%s", tostring(selected_spell_id)))
        return true
    end

    local variant = classifyVariant(meta.root_base_spell_id)
    state.pending_intercept_spell_id = selected_spell_id
    state.pending_intercept_variant = variant
    state.pending_cast_authorized = false
    log.info(string.format("intercept pending spell_id=%s variant=%s", tostring(selected_spell_id), tostring(variant)))

    return true
end

local function onKeyPress(key)
    local symbol = key.symbol and string.lower(key.symbol) or ""
    if symbol == "k" or key.code == input.KEY.K then
        log.debug("handled dev compile hotkey")
        compileHardcodedRecipe()
        return false
    end
    if symbol == "v" or key.code == input.KEY.V then
        sendDebugVanillaFireball()
        return false
    end
    return true
end

return {
    engineHandlers = {
        onFrame = function()
            if state.backend == "INIT" then
                requestBackend()
                return
            end
            if state.backend ~= "READY" then
                return
            end

            local selected = resolveSelectedSpell()
            local selected_spell_id = selected and selected.id or nil
            if selected_spell_id ~= state.last_selected_spell_id then
                state.last_selected_spell_id = selected_spell_id
                refreshSpellMetadata(selected_spell_id, "selected-changed")
            end
        end,
        onKeyPress = onKeyPress,
        onInputAction = onInputAction,
    },
    eventHandlers = {
        [events.BACKEND_READY] = function(payload)
            onBackendReady(payload)
            registerSkillProgressionHandler()
            registerAnimationTextKeys()
        end,
        [events.BACKEND_UNAVAILABLE] = onBackendUnavailable,
        [events.QUERY_SPELL_METADATA_RESULT] = function(payload)
            local request_id = payload and payload.request_id
            local cb = request_id and state.pending_spell_queries[request_id]
            if cb then
                state.pending_spell_queries[request_id] = nil
                cb(payload)
            end
        end,
        [events.COMPILE_RESULT] = function(payload)
            onCompileResult(payload)
            if payload and payload.ok and payload.spell_id then
                refreshSpellMetadata(payload.spell_id, "compile-result")
            end
        end,
        [events.INTERCEPT_DISPATCH_RESULT] = function(payload)
            if payload and payload.ok ~= true then
                log.error(string.format("intercept dispatch failed spell_id=%s err=%s", tostring(payload.spell_id), tostring(payload.error)))
                log.info(string.format(
                    "SPELLFORGE_COMPILED_DISPATCH_SUPPRESSED spell_id=%s authorized=unknown reason=%s",
                    tostring(payload.spell_id),
                    tostring(payload.error or "dispatch failed")
                ))
            elseif payload and payload.ok == true then
                log.info(string.format(
                    "SPELLFORGE_COMPILED_DISPATCH_OK spell_id=%s dispatch_count=%s",
                    tostring(payload.spell_id),
                    tostring(payload.dispatch_count)
                ))
            end
        end,
    },
}
