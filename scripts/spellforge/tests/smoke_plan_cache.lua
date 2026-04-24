local input = require("openmw.input")

local plan_cache = require("scripts.spellforge.global.plan_cache")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_plan_cache")

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

local function isNonEmptyString(v)
    return type(v) == "string" and v ~= ""
end

local function run()
    plan_cache.clearForTests()

    local fire_target = {
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    }

    local first = plan_cache.compileOrGet(fire_target)
    local recipe_id = first and first.recipe_id

    assertLine(first.ok == true and first.reused == false, "1 compile new plan")
    assertLine(isNonEmptyString(recipe_id), "1 recipe_id is non-empty")
    assertLine(first.plan and first.plan.bounds and first.plan.bounds.group_count == 1, "1 group_count is 1")
    assertLine(plan_cache.has(recipe_id), "1 plan exists in cache")

    local second = plan_cache.compileOrGet(fire_target)
    assertLine(second.ok == true and second.reused == true, "2 recompile same plan reused")
    assertLine(second.recipe_id == recipe_id, "2 recipe_id stable across recompiles")

    local changed_magnitude = {
        { id = "firedamage", range = 2, magnitudeMin = 11, magnitudeMax = 11, area = 0, duration = 1 },
    }
    local third = plan_cache.compileOrGet(changed_magnitude)
    assertLine(third.ok == true and third.reused == false, "3 changed magnitude compiles new plan")
    assertLine(third.recipe_id ~= recipe_id, "3 changed magnitude yields different recipe_id")

    local invalid = {
        { id = "spellforge_trigger" },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    }
    local invalid_result = plan_cache.compileOrGet(invalid)
    assertLine(invalid_result.ok == false, "4 parser failure returns ok=false")
    assertLine(type(invalid_result.errors) == "table" and #invalid_result.errors > 0, "4 parser failure has readable errors")
    assertLine(plan_cache.has(invalid_result.recipe_id) == false, "4 parser failure not cached as success")

    local multicast = {
        { id = "spellforge_multicast", params = { count = 3 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    }
    local multicast_result = plan_cache.compileOrGet(multicast)
    local multicast_bounds = multicast_result.plan and multicast_result.plan.bounds or {}
    assertLine(multicast_result.ok == true, "5 multicast compile succeeds")
    assertLine(multicast_bounds.has_multicast == true, "5 multicast summary has_multicast=true")
    assertLine(multicast_bounds.static_emission_count == 3, "5 multicast summary static_emission_count=3")

    local trigger = {
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
        { id = "spellforge_trigger" },
        { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    }
    local trigger_result = plan_cache.compileOrGet(trigger)
    local trigger_bounds = trigger_result.plan and trigger_result.plan.bounds or {}
    local trigger_group = trigger_result.plan and trigger_result.plan.groups and trigger_result.plan.groups[1]
    assertLine(trigger_result.ok == true, "6 trigger compile succeeds")
    assertLine(trigger_bounds.has_trigger == true, "6 trigger summary has_trigger=true")
    assertLine(trigger_group and trigger_group.payload and type(trigger_group.payload.effects) == "table", "6 trigger payload metadata stored")

    local pattern = {
        { id = "spellforge_burst", params = { count = 5 } },
        { id = "spellforge_multicast", params = { count = 5 } },
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    }
    local pattern_result = plan_cache.compileOrGet(pattern)
    local pattern_bounds = pattern_result.plan and pattern_result.plan.bounds or {}
    assertLine(pattern_result.ok == true, "7 pattern compile succeeds")
    assertLine(pattern_bounds.has_pattern == true, "7 pattern summary has_pattern=true")
    assertLine(pattern_bounds.has_multicast == true, "7 pattern summary has_multicast=true")

    plan_cache.clearForTests()
    assertLine(plan_cache.has(recipe_id) == false, "8 cache clear for tests")

    log.info("smoke plan cache run complete")
end

return {
    engineHandlers = {
        onFrame = function()
            if state.ran then
                return
            end
            state.ran = true
            run()
        end,
        onKeyPress = function(key)
            local symbol = key.symbol and string.lower(key.symbol) or ""
            if symbol == "k" or key.code == input.KEY.K then
                run()
                return false
            end
            return true
        end,
    },
}
