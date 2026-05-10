local emission_slots = require("scripts.spellforge.global.emission_slots")
local plan_cache = require("scripts.spellforge.global.plan_cache")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_emission_slots")
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

local function compilePlan(effects)
    local result = plan_cache.compileOrGet(effects)
    if result.ok then
        return result.plan, result
    end
    return nil, result
end

local function countSlotsBy(slots, field, value)
    local count = 0
    for _, slot in ipairs(slots or {}) do
        if slot[field] == value then
            count = count + 1
        end
    end
    return count
end

local function run()
    if not dev.smokeTestsEnabled() then
        return
    end
    plan_cache.clearForTests()

    local single_plan = compilePlan({
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    })
    local single = emission_slots.allocate(single_plan)
    local single_slot = single.slots and single.slots[1]
    assertLine(single.ok == true, "1 single emitter allocation ok")
    assertLine(single.slot_count == 1, "1 single emitter slot_count=1")
    assertLine(single_slot and single_slot.kind == "primary_emission", "1 single emitter kind=primary_emission")
    assertLine(single_slot and single_slot.range == 2, "1 single emitter range=target")
    assertLine(single_slot and single_slot.effects and single_slot.effects[1] and string.lower(tostring(single_slot.effects[1].id)) == "firedamage", "1 single emitter effect id=firedamage")

    local multicast_plan = compilePlan({
        { id = "spellforge_multicast", params = { count = 3 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    })
    local multicast = emission_slots.allocate(multicast_plan)
    assertLine(multicast.ok == true, "2 multicast allocation ok")
    assertLine(multicast.slot_count == 3, "2 multicast slot_count=3")
    assertLine(multicast.slots and multicast.slots[1] and multicast.slots[1].slot_id ~= multicast.slots[2].slot_id, "2 multicast deterministic unique slot ids")
    assertLine(multicast.slots and multicast.slots[1] and multicast.slots[1].group_index == 1, "2 multicast slots reference fire group")

    local multicast_next_group_plan = compilePlan({
        { id = "spellforge_multicast", params = { count = 3 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
        { id = "shield", range = 0, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    })
    local multicast_next_group = emission_slots.allocate(multicast_next_group_plan)
    local shield_count = 0
    for _, slot in ipairs(multicast_next_group.slots or {}) do
        if slot.effects and slot.effects[1] and string.lower(tostring(slot.effects[1].id)) == "shield" then
            shield_count = shield_count + 1
        end
    end
    assertLine(multicast_next_group.ok == true, "3 multicast-next-group allocation ok")
    assertLine(multicast_next_group.slot_count == 4, "3 multicast-next-group slot_count=4")
    assertLine(shield_count == 1, "3 shield group not multicast")

    local pattern_plan = compilePlan({
        { id = "spellforge_burst", params = { count = 5 } },
        { id = "spellforge_multicast", params = { count = 5 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    })
    local pattern = emission_slots.allocate(pattern_plan)
    local burst_on_all = true
    for _, slot in ipairs(pattern.slots or {}) do
        local has_burst = false
        for _, op in ipairs(slot.prefix_ops or {}) do
            if op.opcode == "Burst" then
                has_burst = true
            end
        end
        if not has_burst then
            burst_on_all = false
            break
        end
    end
    assertLine(pattern.ok == true, "4 pattern allocation ok")
    assertLine(pattern.slot_count == 5, "4 pattern slot_count=5")
    assertLine(burst_on_all, "4 burst metadata preserved per slot")

    local trigger_plan = compilePlan({
        { id = "spellforge_multicast", params = { count = 5 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
        { id = "spellforge_trigger" },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    })
    local trigger = emission_slots.allocate(trigger_plan)
    local trigger_payload_slots = countSlotsBy(trigger.slots, "source_postfix_opcode", "Trigger")
    assertLine(trigger.ok == true, "5 trigger allocation ok")
    assertLine(countSlotsBy(trigger.slots, "kind", "primary_emission") == 5, "5 trigger has 5 primary slots")
    assertLine(trigger_payload_slots == 5, "5 trigger has 5 payload slot executions")

    local timer_plan = compilePlan({
        { id = "spellforge_multicast", params = { count = 2 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
        { id = "spellforge_timer", params = { seconds = 1.0 } },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    })
    local timer = emission_slots.allocate(timer_plan)
    local timer_payload_slots = countSlotsBy(timer.slots, "source_postfix_opcode", "Timer")
    local timer_sources_clean = true
    for _, slot in ipairs(timer.slots or {}) do
        if slot.kind == "primary_emission" then
            local first = slot.effects and slot.effects[1] or nil
            if type(slot.effects) ~= "table" or #slot.effects ~= 1 or string.lower(tostring(first and first.id)) ~= "firedamage" then
                timer_sources_clean = false
                break
            end
        end
    end
    assertLine(timer.ok == true, "6 timer allocation ok")
    assertLine(countSlotsBy(timer.slots, "kind", "primary_emission") == 2, "6 timer has 2 primary slots")
    assertLine(timer_payload_slots == 2, "6 timer has 2 payload slot executions")
    assertLine(timer_sources_clean, "6 timer source slots exclude payload effects")

    local cap_plan = compilePlan({
        { id = "spellforge_multicast", params = { count = 8 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
        { id = "spellforge_trigger" },
        { id = "spellforge_multicast", params = { count = 8 } },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    })
    local cap = emission_slots.allocate(cap_plan)
    assertLine(cap.ok == false, "7 cap exceeded returns failure")
    assertLine(type(cap.errors) == "table" and #cap.errors > 0, "7 cap exceeded has readable error")

    local deterministic_first = emission_slots.allocate(multicast_plan)
    local deterministic_second = emission_slots.allocate(multicast_plan)
    local same_slots = deterministic_first.ok and deterministic_second.ok and deterministic_first.slot_count == deterministic_second.slot_count
    if same_slots then
        for i, slot in ipairs(deterministic_first.slots or {}) do
            local other = deterministic_second.slots and deterministic_second.slots[i]
            if not other or other.slot_id ~= slot.slot_id or other.kind ~= slot.kind then
                same_slots = false
                break
            end
        end
    end
    assertLine(same_slots, "8 repeated allocation deterministic")

    local invalid_plan = {
        recipe_id = "invalid",
        groups = {},
        parse_result = { ok = false },
    }
    local invalid_alloc = emission_slots.allocate(invalid_plan)
    assertLine(invalid_alloc.ok == false, "9 parse-failed plan is not allocated")

    plan_cache.clearForTests()
    local integrated_result = plan_cache.compileOrGet({
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    })
    local attached = plan_cache.attachEmissionSlots(integrated_result.recipe_id)
    local reused = plan_cache.compileOrGet({
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    })
    assertLine(attached.ok == true and attached.plan and attached.plan.slot_count == 1, "10 plan cache integration attaches slots")
    assertLine(reused.ok == true and reused.reused == true and reused.plan and reused.plan.slot_count == 1, "10 plan cache reuse remains stable with slots")

    log.info("smoke emission slots run complete")
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
