local types = require("openmw.types")

local emission_slots = require("scripts.spellforge.global.emission_slots")
local helper_specs = require("scripts.spellforge.global.helper_record_specs")
local helper_records = require("scripts.spellforge.global.helper_records")
local plan_cache = require("scripts.spellforge.global.plan_cache")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_helper_records")
local dev = require("scripts.spellforge.shared.dev")

local state = {
    ran = false,
}

local function assertLine(ok, label, detail)
    if ok then
        log.info("PASS " .. label)
    else
        log.error("FAIL " .. label .. (detail and (" :: " .. detail) or ""))
    end
end

local function compileAllocateSpecs(effects)
    local compiled = plan_cache.compileOrGet(effects)
    if not compiled.ok then
        return nil, { ok = false, error = "compile failed" }
    end

    local slots = emission_slots.allocate(compiled.plan)
    if not slots.ok then
        return nil, { ok = false, error = "slot allocation failed" }
    end

    local specs = helper_specs.generate(compiled.plan, slots)
    if not specs.ok then
        return nil, { ok = false, error = "spec generation failed" }
    end

    return {
        plan = compiled.plan,
        slots = slots,
        specs = specs,
    }, nil
end

local function countBy(records, predicate)
    local count = 0
    for _, rec in ipairs(records or {}) do
        if predicate(rec) then
            count = count + 1
        end
    end
    return count
end

local function spellbookHasAny(actor, engine_ids)
    local set = {}
    for _, id in ipairs(engine_ids or {}) do
        set[id] = true
    end

    local actor_spells = types.Actor.spells(actor)
    for _, entry in pairs(actor_spells) do
        if entry and set[entry.id] then
            return true
        end
    end
    return false
end

local function run(player)
    if not dev.smokeTestsEnabled() then
        return
    end
    plan_cache.clearForTests()
    helper_records.clearForTests()

    local single_data = compileAllocateSpecs({
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    })
    local single = helper_records.materialize(single_data.specs)
    local single_record = single.records and single.records[1]
    assertLine(single.ok == true, "1 single emitter materialization ok")
    assertLine(single.record_count == 1, "1 single emitter record_count=1")
    assertLine(single_record and type(single_record.logical_id) == "string" and single_record.logical_id ~= "", "1 logical_id non-empty")
    assertLine(single_record and type(single_record.engine_id) == "string" and single_record.engine_id ~= "", "1 engine_id non-empty")
    assertLine(single_record and helper_records.getByLogicalId(single_record.logical_id) ~= nil, "1 lookup by logical_id works")
    assertLine(single_record and helper_records.getByEngineId(single_record.engine_id) ~= nil, "1 lookup by engine_id works")
    assertLine(single_record and helper_records.getByRecipeSlot(single_record.recipe_id, single_record.slot_id) ~= nil, "1 lookup by recipe+slot works")
    assertLine(single_record and single_record.effects and single_record.effects[1] and string.lower(tostring(single_record.effects[1].id)) == "firedamage", "1 firedamage payload preserved")

    local multicast_data = compileAllocateSpecs({
        { id = "spellforge_multicast", params = { count = 3 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    })
    local multicast = helper_records.materialize(multicast_data.specs)
    local unique_engine_ids = {}
    for _, rec in ipairs(multicast.records or {}) do
        unique_engine_ids[rec.engine_id] = true
    end
    local unique_count = 0
    for _ in pairs(unique_engine_ids) do
        unique_count = unique_count + 1
    end
    assertLine(multicast.ok == true, "2 multicast materialization ok")
    assertLine(multicast.record_count == 3, "2 multicast record_count=3")
    assertLine(unique_count == 3, "2 three unique engine IDs")
    assertLine(countBy(multicast.records, function(rec)
        return rec.effects and rec.effects[1] and string.lower(tostring(rec.effects[1].id)) == "firedamage"
    end) == 3, "2 multicast firedamage payload preserved")

    local repeat_first = helper_records.materialize(multicast_data.specs)
    local repeat_second = helper_records.materialize(multicast_data.specs)
    assertLine(repeat_first.ok == true and repeat_second.ok == true, "3 repeated materialization calls succeed")
    assertLine(repeat_second.reused == true, "3 repeated materialization reports reused=true")
    assertLine(repeat_second.records and repeat_first.records and repeat_second.records[1] and repeat_first.records[1]
        and repeat_second.records[1].engine_id == repeat_first.records[1].engine_id, "3 lookup mappings remain stable")

    local mixed_data = compileAllocateSpecs({
        { id = "spellforge_multicast", params = { count = 3 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
        { id = "shield", range = 0, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    })
    local mixed = helper_records.materialize(mixed_data.specs)
    local shield_record = mixed.records and mixed.records[4]
    assertLine(mixed.ok == true and mixed.record_count == 4, "4 multicast-next-group record_count=4")
    assertLine(shield_record and shield_record.effects and shield_record.effects[1]
        and string.lower(tostring(shield_record.effects[1].id)) == "shield", "4 shield helper is fourth record")
    assertLine(shield_record and shield_record.emission_index == 1, "4 shield helper is not multicast copy")

    local trigger_data = compileAllocateSpecs({
        { id = "spellforge_multicast", params = { count = 5 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
        { id = "spellforge_trigger" },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    })
    local trigger = helper_records.materialize(trigger_data.specs)
    assertLine(trigger.ok == true, "5 trigger materialization ok")
    assertLine(countBy(trigger.records, function(rec)
        return rec.trigger_source_slot_id ~= nil
    end) == 5, "5 trigger payload routing survives with five executions")

    local timer_data = compileAllocateSpecs({
        { id = "spellforge_multicast", params = { count = 2 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
        { id = "spellforge_timer", params = { seconds = 1.0 } },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    })
    local timer = helper_records.materialize(timer_data.specs)
    assertLine(timer.ok == true, "6 timer materialization ok")
    assertLine(countBy(timer.records, function(rec)
        return rec.timer_source_slot_id ~= nil
    end) == 2, "6 timer payload routing survives with two executions")

    local too_many_specs = {
        recipe_id = "cap-test",
        specs = {},
    }
    for i = 1, 33 do
        too_many_specs.specs[i] = {
            recipe_id = "cap-test",
            slot_id = string.format("cap-test:s%d", i),
            logical_id = string.format("spellforge_helper_cap_test_s%d", i),
            planned_name = "cap test",
            cost = 0,
            is_autocalc = false,
            internal = true,
            visible_to_player = false,
            effects = {
                { id = "firedamage", range = 2, area = 0, duration = 1, magnitudeMin = 1, magnitudeMax = 1 },
            },
            routing = {},
        }
    end
    local cap = helper_records.materialize(too_many_specs)
    assertLine(cap.ok == false, "7 cap defense fails")
    assertLine(type(cap.errors) == "table" and #cap.errors > 0, "7 cap defense readable error")

    local invalid = helper_records.materialize({
        recipe_id = "bad",
        specs = {
            { recipe_id = "bad", slot_id = "bad:s1" },
        },
    })
    assertLine(invalid.ok == false, "8 invalid spec input fails")
    assertLine(type(invalid.errors) == "table" and #invalid.errors > 0, "8 invalid spec input readable error")

    plan_cache.clearForTests()
    local integrated = plan_cache.compileOrGet({
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    })
    local attached_records = plan_cache.attachHelperRecords(integrated.recipe_id)
    local reused_plan = plan_cache.compileOrGet({
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    })
    assertLine(attached_records.ok == true and attached_records.plan and attached_records.plan.helper_record_count == 1,
        "9 plan cache integration helper records attached")
    assertLine(reused_plan.ok == true and reused_plan.reused == true and reused_plan.plan and reused_plan.plan.helper_record_count == 1,
        "9 plan cache reuse stable with helper records")

    local check_ids = {}
    for _, rec in ipairs(single.records or {}) do
        check_ids[#check_ids + 1] = rec.engine_id
    end
    local pollution_detected = spellbookHasAny(player, check_ids)
    assertLine(pollution_detected == false, "10 no player spellbook pollution for helper records")

    log.info("smoke helper records run complete")
end

return {
    engineHandlers = {
        onPlayerAdded = function(player)
            if state.ran then
                return
            end
            state.ran = true
            run(player)
        end,
    },
}
