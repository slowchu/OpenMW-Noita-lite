local emission_slots = require("scripts.spellforge.global.emission_slots")
local helper_specs = require("scripts.spellforge.global.helper_record_specs")
local plan_cache = require("scripts.spellforge.global.plan_cache")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_helper_specs")

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

local function compileAndAllocate(effects)
    local compiled = plan_cache.compileOrGet(effects)
    if not compiled.ok then
        return nil, nil, compiled
    end
    local allocated = emission_slots.allocate(compiled.plan)
    if not allocated.ok then
        return compiled.plan, nil, allocated
    end
    return compiled.plan, allocated, nil
end

local function countBy(specs, predicate)
    local count = 0
    for _, spec in ipairs(specs or {}) do
        if predicate(spec) then
            count = count + 1
        end
    end
    return count
end

local function run()
    plan_cache.clearForTests()

    local single_plan, single_slots = compileAndAllocate({
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    })
    local single = helper_specs.generate(single_plan, single_slots)
    local single_spec = single.specs and single.specs[1]
    assertLine(single.ok == true, "1 single emitter helper spec ok")
    assertLine(single.spec_count == 1, "1 single emitter spec_count=1")
    assertLine(single_spec and type(single_spec.logical_id) == "string" and single_spec.logical_id ~= "", "1 logical_id non-empty")
    assertLine(single_spec and single_spec.slot_id and string.find(single_spec.slot_id, ":s1", 1, true) ~= nil, "1 slot reference includes s1")
    assertLine(single_spec and single_spec.effects and single_spec.effects[1] and string.lower(tostring(single_spec.effects[1].id)) == "firedamage", "1 effect id=firedamage")
    assertLine(single_spec and single_spec.range == 2, "1 range=target")
    assertLine(single_spec and single_spec.internal == true and single_spec.visible_to_player == false, "1 internal and not visible to player")

    local multicast_plan, multicast_slots = compileAndAllocate({
        { id = "spellforge_multicast", params = { count = 3 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    })
    local multicast = helper_specs.generate(multicast_plan, multicast_slots)
    local unique_ids = {}
    for _, spec in ipairs(multicast.specs or {}) do
        unique_ids[spec.logical_id] = true
    end
    assertLine(multicast.ok == true, "2 multicast helper specs ok")
    assertLine(multicast.spec_count == 3, "2 multicast spec_count=3")
    assertLine((multicast.specs and #multicast.specs or 0) == 3 and next(unique_ids) ~= nil and (function() local c=0 for _ in pairs(unique_ids) do c=c+1 end return c end)() == 3, "2 deterministic unique logical IDs")
    assertLine(countBy(multicast.specs, function(spec)
        return spec.effects and spec.effects[1] and string.lower(tostring(spec.effects[1].id)) == "firedamage"
    end) == 3, "2 firedamage payload preserved")

    local mixed_plan, mixed_slots = compileAndAllocate({
        { id = "spellforge_multicast", params = { count = 3 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
        { id = "shield", range = 0, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    })
    local mixed = helper_specs.generate(mixed_plan, mixed_slots)
    local shield_spec = mixed.specs and mixed.specs[4]
    assertLine(mixed.ok == true, "3 multicast-next-group helper specs ok")
    assertLine(mixed.spec_count == 4, "3 multicast-next-group spec_count=4")
    assertLine(shield_spec and shield_spec.effects and shield_spec.effects[1] and string.lower(tostring(shield_spec.effects[1].id)) == "shield", "3 fourth spec is shield")
    assertLine(shield_spec and shield_spec.fanout and shield_spec.fanout.is_multicast == false, "3 shield spec is not multicast copy")

    local pattern_plan, pattern_slots = compileAndAllocate({
        { id = "spellforge_burst", params = { count = 5 } },
        { id = "spellforge_multicast", params = { count = 5 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    })
    local pattern = helper_specs.generate(pattern_plan, pattern_slots)
    assertLine(pattern.ok == true and pattern.spec_count == 5, "4 pattern helper specs count")
    assertLine(countBy(pattern.specs, function(spec)
        for _, op in ipairs(spec.routing and spec.routing.prefix_ops or {}) do
            if op.opcode == "Burst" then
                return true
            end
        end
        return false
    end) == 5, "4 burst metadata preserved")

    local trigger_plan, trigger_slots = compileAndAllocate({
        { id = "spellforge_multicast", params = { count = 5 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
        { id = "spellforge_trigger" },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    })
    local trigger = helper_specs.generate(trigger_plan, trigger_slots)
    assertLine(trigger.ok == true, "5 trigger helper specs ok")
    assertLine(countBy(trigger.specs, function(spec)
        return spec.routing and spec.routing.kind == "primary_emission"
    end) == 5, "5 trigger primary specs count=5")
    assertLine(countBy(trigger.specs, function(spec)
        return spec.routing and spec.routing.trigger_source_slot_id ~= nil
    end) == 5, "5 trigger payload routing count=5")

    local timer_plan, timer_slots = compileAndAllocate({
        { id = "spellforge_multicast", params = { count = 2 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
        { id = "spellforge_timer", params = { seconds = 1.0 } },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    })
    local timer = helper_specs.generate(timer_plan, timer_slots)
    assertLine(timer.ok == true, "6 timer helper specs ok")
    assertLine(countBy(timer.specs, function(spec)
        return spec.routing and spec.routing.timer_source_slot_id ~= nil
    end) == 2, "6 timer payload routing count=2")

    local det_first = helper_specs.generate(multicast_plan, multicast_slots)
    local det_second = helper_specs.generate(multicast_plan, multicast_slots)
    local deterministic = det_first.ok and det_second.ok and det_first.spec_count == det_second.spec_count
    if deterministic then
        for i, spec in ipairs(det_first.specs or {}) do
            local other = det_second.specs and det_second.specs[i]
            if not other or other.logical_id ~= spec.logical_id or other.slot_id ~= spec.slot_id then
                deterministic = false
                break
            end
        end
    end
    assertLine(deterministic, "7 repeated generation deterministic")

    local too_many_slots = {}
    for i = 1, 33 do
        too_many_slots[i] = {
            slot_id = string.format("%s:s%d", single_plan.recipe_id, i),
            group_index = 1,
            emission_index = i,
            kind = "primary_emission",
            range = 2,
            effects = {
                { id = "firedamage", range = 2, area = 0, duration = 1, magnitudeMin = 1, magnitudeMax = 1 },
            },
            prefix_ops = {},
            postfix_ops = {},
        }
    end
    local cap = helper_specs.generate(single_plan, too_many_slots)
    assertLine(cap.ok == false, "8 cap defense fails over max")
    assertLine(type(cap.errors) == "table" and #cap.errors > 0, "8 cap defense has readable error")

    local invalid_slots = helper_specs.generate(single_plan, nil)
    assertLine(invalid_slots.ok == false, "9 invalid slot input fails")
    assertLine(type(invalid_slots.errors) == "table" and #invalid_slots.errors > 0, "9 invalid slot input readable error")

    plan_cache.clearForTests()
    local integrated = plan_cache.compileOrGet({
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    })
    local attached = plan_cache.attachHelperSpecs(integrated.recipe_id)
    local reused = plan_cache.compileOrGet({
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    })
    assertLine(attached.ok == true and attached.plan and attached.plan.helper_spec_count == 1, "10 plan cache helper-spec attach works")
    assertLine(reused.ok == true and reused.reused == true and reused.plan and reused.plan.helper_spec_count == 1, "10 plan cache reuse stable after helper specs")

    log.info("smoke helper specs run complete")
end

return {
    engineHandlers = {
        onUpdate = function()
            if state.ran then
                return
            end
            state.ran = true
            run()
        end,
    },
}
