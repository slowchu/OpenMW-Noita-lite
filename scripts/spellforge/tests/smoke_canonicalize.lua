local input = require("openmw.input")

local canonicalize = require("scripts.spellforge.global.canonicalize_effect_list")
local parser = require("scripts.spellforge.global.parser")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_canonicalize")

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

local function hashFor(effects, opts)
    return canonicalize.run(effects, opts).recipe_id
end

local function run()
    local base_effects = {
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 20, area = 5, duration = 2 },
        { id = "spellforge_multicast", params = { count = 3 } },
        { id = "frostdamage", range = 2, magnitudeMin = 5, magnitudeMax = 7, area = 0, duration = 1 },
    }

    local cases = {
        {
            label = "1 deterministic same input",
            check = function()
                local a = hashFor(base_effects)
                local b = hashFor(base_effects)
                return a == b
            end,
        },
        {
            label = "2 effect order changes hash",
            check = function()
                local reordered = {
                    base_effects[3],
                    base_effects[2],
                    base_effects[1],
                }
                return hashFor(base_effects) ~= hashFor(reordered)
            end,
        },
        {
            label = "3 effect id case-insensitive",
            check = function()
                local variant = {
                    { id = "FireDamage", range = 2, magnitudeMin = 10, magnitudeMax = 20, area = 5, duration = 2 },
                    base_effects[2],
                    { id = "FROSTDAMAGE", range = 2, magnitudeMin = 5, magnitudeMax = 7, area = 0, duration = 1 },
                }
                return hashFor(base_effects) == hashFor(variant)
            end,
        },
        {
            label = "4 range changes hash",
            check = function()
                local variant = {
                    { id = "firedamage", range = 1, magnitudeMin = 10, magnitudeMax = 20, area = 5, duration = 2 },
                    base_effects[2],
                    base_effects[3],
                }
                return hashFor(base_effects) ~= hashFor(variant)
            end,
        },
        {
            label = "5 area changes hash",
            check = function()
                local variant = {
                    { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 20, area = 6, duration = 2 },
                    base_effects[2],
                    base_effects[3],
                }
                return hashFor(base_effects) ~= hashFor(variant)
            end,
        },
        {
            label = "6 magnitude changes hash",
            check = function()
                local variant = {
                    { id = "firedamage", range = 2, magnitudeMin = 11, magnitudeMax = 20, area = 5, duration = 2 },
                    base_effects[2],
                    base_effects[3],
                }
                return hashFor(base_effects) ~= hashFor(variant)
            end,
        },
        {
            label = "7 duration changes hash",
            check = function()
                local variant = {
                    { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 20, area = 5, duration = 3 },
                    base_effects[2],
                    base_effects[3],
                }
                return hashFor(base_effects) ~= hashFor(variant)
            end,
        },
        {
            label = "8 operator params change hash",
            check = function()
                local variant = {
                    base_effects[1],
                    { id = "spellforge_multicast", params = { count = 4 } },
                    base_effects[3],
                }
                return hashFor(base_effects) ~= hashFor(variant)
            end,
        },
        {
            label = "9 compiler version contributes to hash",
            check = function()
                local a = hashFor(base_effects, { compiler_version = "2.2c.2" })
                local b = hashFor(base_effects, { compiler_version = "2.2c.3" })
                return a ~= b
            end,
        },
        {
            label = "10 parsed-group form deterministic",
            check = function()
                local parsed = parser.parseEffectList(base_effects)
                if not parsed.ok then
                    return false
                end
                local a = canonicalize.run(parsed).recipe_id
                local b = canonicalize.run(parsed).recipe_id
                return a == b
            end,
        },
    }

    for _, case in ipairs(cases) do
        local ok, result = pcall(case.check)
        assertLine(ok and result == true, case.label, ok and nil or tostring(result))
    end

    log.info("smoke canonicalize run complete")
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
            if symbol == "h" or key.code == input.KEY.H then
                run()
                return false
            end
            return true
        end,
    },
}
