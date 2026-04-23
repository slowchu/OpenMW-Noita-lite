local async = require("openmw.async")
local core = require("openmw.core")
local input = require("openmw.input")
local self = require("openmw.self")
local types = require("openmw.types")

local events = require("scripts.spellforge.shared.events")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_compiler")

local state = {
    backend = "INIT",
    handshake_timer = nil,
    pending = {},
    running = false,
}

local function assertLine(ok, label)
    if ok then
        log.info("PASS " .. label)
    else
        log.error("FAIL " .. label)
    end
end

local function logCompileCauses(recipe_label, payload)
    if not payload or type(payload.errors) ~= "table" then
        return
    end
    for _, err in ipairs(payload.errors) do
        local message = err.message or tostring(err)
        log.error(string.format("  cause[%s]: %s", recipe_label, tostring(message)))
    end
end

local KNOWN_COMBAT_SPELL_IDS = {
    "fireball",
    "frostball",
    "lightning bolt",
    "fire bite",
}

local function resolveSmokeBaseSpellId()
    local default_id = KNOWN_COMBAT_SPELL_IDS[1]
    local default_record = core.magic.spells.records[default_id]
    if default_record then
        return default_id
    end

    for i = 2, #KNOWN_COMBAT_SPELL_IDS do
        local fallback_id = KNOWN_COMBAT_SPELL_IDS[i]
        if core.magic.spells.records[fallback_id] then
            log.warn(string.format("base_spell_id default missing; using fallback id=%s (default=%s)", fallback_id, default_id))
            return fallback_id
        end
    end

    log.error(string.format(
        "no known vanilla combat spell found; checked ids=%s",
        table.concat(KNOWN_COMBAT_SPELL_IDS, ", ")
    ))
    return nil
end

local function nextRequestId(prefix)
    return string.format("%s-%d", prefix, os.time() + math.random(1, 100000))
end

local function compile(recipe, request_id)
    core.sendGlobalEvent(events.COMPILE_RECIPE, {
        sender = self.object,
        actor = self,
        actor_id = self.recordId,
        recipe = recipe,
        request_id = request_id,
    })
end

local function waitForResult(request_id, timeout_seconds, callback)
    state.pending[request_id] = callback
    async:newUnsavableSimulationTimer(timeout_seconds, function()
        if state.pending[request_id] then
            local cb = state.pending[request_id]
            state.pending[request_id] = nil
            cb({ ok = false, error = "timeout" })
        end
    end)
end

local function hasErrorContaining(errors, needle)
    if type(errors) ~= "table" then
        return false
    end
    for _, err in ipairs(errors) do
        local message = err and err.message
        if type(message) == "string" and string.find(string.lower(message), string.lower(needle), 1, true) then
            return true
        end
    end
    return false
end

local function runSpellbookEnumerationProbe(actor_spells, target_engine_id)
    local function probePairs()
        local count = 0
        local found = false
        for _, entry in pairs(actor_spells) do
            count = count + 1
            if entry and entry.id == target_engine_id then
                found = true
            end
        end
        log.info(string.format("spellbook probe pairs: count=%d found_engine_id=%s", count, tostring(found)))
    end

    local function probeIpairs()
        local count = 0
        local found = false
        for _, entry in ipairs(actor_spells) do
            count = count + 1
            if entry and entry.id == target_engine_id then
                found = true
            end
        end
        log.info(string.format("spellbook probe ipairs: count=%d found_engine_id=%s", count, tostring(found)))
    end

    local function probeNumeric()
        local count = 0
        local found = false
        local total = #actor_spells
        for i = 1, total do
            local entry = actor_spells[i]
            if entry then
                count = count + 1
                if entry.id == target_engine_id then
                    found = true
                end
            end
        end
        log.info(string.format("spellbook probe numeric: count=%d total=%d found_engine_id=%s", count, total, tostring(found)))
    end

    local function probeGetAll()
        if type(actor_spells.getAll) ~= "function" then
            log.info("spellbook probe getAll: unsupported")
            return
        end
        local ok, list_or_err = pcall(actor_spells.getAll, actor_spells)
        if not ok then
            log.info(string.format("spellbook probe getAll: error=%s", tostring(list_or_err)))
            return
        end
        local count = 0
        local found = false
        for _, entry in pairs(list_or_err) do
            count = count + 1
            if entry and entry.id == target_engine_id then
                found = true
            end
        end
        log.info(string.format("spellbook probe getAll: count=%d found_engine_id=%s", count, tostring(found)))
    end

    -- OpenMW docs:
    -- - ActorSpells usage: pairs(mySpells) and numeric indexing are equivalent.
    --   https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_types.html#type-actorspells
    -- - List iterable supports pairs/ipairs/#/numeric indexing.
    --   https://openmw.readthedocs.io/en/latest/reference/lua-scripting/iterables.html#list-iterable
    probePairs()
    probeIpairs()
    probeNumeric()
    probeGetAll()
end

local function spellbookHasSpell(actor, spell_id)
    local actor_spells = types.Actor.spells(actor)
    for i = 1, #actor_spells do
        local entry = actor_spells[i]
        if entry and entry.id == spell_id then
            return true
        end
    end
    return false
end

local function runSmoke()
    if state.running then
        log.warn("smoke run already in progress")
        return
    end

    if state.backend ~= "READY" then
        log.warn("smoke run skipped: backend is not READY")
        return
    end

    local base_spell_id = resolveSmokeBaseSpellId()
    if not base_spell_id then
        log.error("no deterministic base spell available; aborting smoke")
        return
    end
    log.info(string.format("smoke fixture base_spell_id=%s", base_spell_id))

    state.running = true
    log.info("starting smoke compiler run")

    local trivial_recipe = {
        nodes = {
            { kind = "emitter", base_spell_id = base_spell_id },
        },
    }

    local multicast_recipe = {
        nodes = {
            { kind = "emitter", base_spell_id = base_spell_id, payload = {
                { opcode = "Multicast", params = { count = 3 } },
                { opcode = "Spread", params = { preset = 1 } },
                { kind = "emitter", base_spell_id = base_spell_id },
            } },
        },
    }

    local invalid_nested_recipe = {
        nodes = {
            { opcode = "Trigger" },
        },
    }

    local req1 = nextRequestId("smoke-trivial")
    compile(trivial_recipe, req1)
    waitForResult(req1, 3, function(result1)
        local ok1 = result1.ok
        assertLine(ok1, "trivial recipe compiles")
        if not ok1 then
            logCompileCauses("trivial", result1)
        end

        local ok2 = type(result1.spell_id) == "string" and result1.spell_id ~= ""
        assertLine(ok2, "trivial compile returns front-end spell_id")
        if not ok2 then
            logCompileCauses("trivial", result1)
        end

        local actor_spells = types.Actor.spells(self)
        log.info(string.format("spellbook probe target_engine_id=%s type=%s", tostring(result1.spell_id), type(result1.spell_id)))
        runSpellbookEnumerationProbe(actor_spells, result1.spell_id)

        local spellbook_has = result1.spell_id and spellbookHasSpell(self, result1.spell_id)
        local ok3 = spellbook_has == true
        assertLine(ok3, "front-end spell added to spellbook")
        if not ok3 then
            logCompileCauses("trivial", result1)
        end

        local effects = nil
        if type(result1.spell_id) == "string" and result1.spell_id ~= "" then
            local record = core.magic.spells.records[result1.spell_id]
            effects = record and record.effects or nil
        end
        local ok_marker_only = type(effects) == "table" and #effects == 1 and effects[1].id == "spellforge_composed"
        assertLine(ok_marker_only, "compiled spell contains only marker effect")

        local ok_meta_real_effects = type(result1.root_real_effect_count) == "number" and result1.root_real_effect_count > 0
        assertLine(ok_meta_real_effects, "compile metadata preserves real effects")

        local req2 = nextRequestId("smoke-cache")
        compile(trivial_recipe, req2)
        waitForResult(req2, 3, function(result2)
            local ok4 = result2.ok
            assertLine(ok4, "identical recipe recompiles")
            if not ok4 then
                logCompileCauses("cache", result2)
            end
            assertLine(result1.recipe_id == result2.recipe_id, "identical recipe_id is stable")
            local ok5 = result2.reused == true
            assertLine(ok5, "identical recipe reuses cache")
            if not ok5 then
                logCompileCauses("cache", result2)
            end

            local req3 = nextRequestId("smoke-multicast")
            compile(multicast_recipe, req3)
            waitForResult(req3, 3, function(result3)
                local ok6 = result3.ok
                assertLine(ok6, "multicast recipe compiles")
                if not ok6 then
                    logCompileCauses("multicast", result3)
                end

                local req4 = nextRequestId("smoke-invalid")
                compile(invalid_nested_recipe, req4)
                waitForResult(req4, 3, function(result4)
                    local ok7 = result4.ok == false
                    assertLine(ok7, "invalid nested-trigger recipe rejected")
                    if not ok7 then
                        logCompileCauses("invalid", result4)
                    end

                    local ok8 = type(result4.errors) == "table" and #result4.errors > 0
                    assertLine(ok8, "invalid recipe returns readable errors")
                    if not ok8 then
                        logCompileCauses("invalid", result4)
                    end

                    local ok9 = hasErrorContaining(result4.errors, "preceded by emitter")
                    assertLine(ok9, "invalid recipe reports structural trigger-order error")
                    if not ok9 then
                        logCompileCauses("invalid", result4)
                    end
                    log.info("smoke compiler run complete")
                    state.running = false
                end)
            end)
        end)
    end)
end

local function requestBackend()
    state.backend = "PENDING"
    core.sendGlobalEvent(events.CHECK_BACKEND, {
        sender = self.object,
    })
    state.handshake_timer = async:newUnsavableSimulationTimer(3, function()
        if state.backend == "PENDING" then
            state.backend = "UNAVAILABLE"
            log.warn("backend timeout after 3 seconds")
        end
    end)
end

local function onKeyPress(key)
    local symbol = key.symbol and string.lower(key.symbol) or ""
    if symbol == "u" or key.code == input.KEY.U then
        log.debug("handled smoke hotkey")
        runSmoke()
        return false
    end
    return true
end

return {
    engineHandlers = {
        onFrame = function()
            if state.backend == "INIT" then
                requestBackend()
            end
        end,
        onKeyPress = onKeyPress,
    },
    eventHandlers = {
        [events.BACKEND_READY] = function()
            if state.handshake_timer then
                state.handshake_timer:cancel()
                state.handshake_timer = nil
            end
            state.backend = "READY"
            log.info("backend ready for smoke harness")
        end,
        [events.BACKEND_UNAVAILABLE] = function(payload)
            if state.handshake_timer then
                state.handshake_timer:cancel()
                state.handshake_timer = nil
            end
            state.backend = "UNAVAILABLE"
            log.warn("backend unavailable: " .. tostring(payload and payload.reason))
        end,
        [events.COMPILE_RESULT] = function(payload)
            if not payload or not payload.request_id then
                return
            end
            local cb = state.pending[payload.request_id]
            if not cb then
                return
            end
            state.pending[payload.request_id] = nil
            cb(payload)
        end,
    },
}
