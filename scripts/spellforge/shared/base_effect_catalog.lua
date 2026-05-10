local validation = require("scripts.spellforge.shared.validation_contract")

local base_effect_catalog = {}

base_effect_catalog.VERSION = "spellforge-available-effects-v1"

local RANGE_SELF = 0
local RANGE_TOUCH = 1
local RANGE_TARGET = 2

local OPERATOR_EFFECT_IDS = {
    spellforge_multicast = true,
    spellforge_spread = true,
    spellforge_burst = true,
    spellforge_speed_plus = true,
    spellforge_size_plus = true,
    spellforge_chain = true,
    spellforge_bounce = true,
    spellforge_pierce = true,
    spellforge_homing = true,
    spellforge_trigger = true,
    spellforge_timer = true,
}

local STATIC_EFFECTS = {
    { id = "firedamage", display_name = "Fire Damage", school = "Destruction", category = "Damage", range = RANGE_TARGET, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1, allowed_ranges = { RANGE_TOUCH, RANGE_TARGET }, color = "fire" },
    { id = "frostdamage", display_name = "Frost Damage", school = "Destruction", category = "Damage", range = RANGE_TARGET, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1, allowed_ranges = { RANGE_TOUCH, RANGE_TARGET }, color = "frost" },
    { id = "shockdamage", display_name = "Shock Damage", school = "Destruction", category = "Damage", range = RANGE_TARGET, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1, allowed_ranges = { RANGE_TOUCH, RANGE_TARGET }, color = "shock" },
    { id = "poisondamage", display_name = "Poison Damage", school = "Destruction", category = "Damage", range = RANGE_TOUCH, magnitudeMin = 6, magnitudeMax = 6, area = 0, duration = 5, allowed_ranges = { RANGE_TOUCH, RANGE_TARGET }, color = "poison" },
    { id = "damagehealth", display_name = "Damage Health", school = "Destruction", category = "Damage", range = RANGE_TOUCH, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1, allowed_ranges = { RANGE_TOUCH, RANGE_TARGET }, color = "drain" },
    { id = "drainhealth", display_name = "Drain Health", school = "Destruction", category = "Damage", range = RANGE_TOUCH, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 5, allowed_ranges = { RANGE_TOUCH, RANGE_TARGET }, color = "drain" },
    { id = "absorbhealth", display_name = "Absorb Health", school = "Mysticism", category = "Absorb", range = RANGE_TOUCH, magnitudeMin = 6, magnitudeMax = 6, area = 0, duration = 5, allowed_ranges = { RANGE_TOUCH, RANGE_TARGET }, color = "drain" },
    { id = "restorehealth", display_name = "Restore Health", school = "Restoration", category = "Restore", range = RANGE_SELF, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "restore" },
    { id = "restorefatigue", display_name = "Restore Fatigue", school = "Restoration", category = "Restore", range = RANGE_SELF, magnitudeMin = 12, magnitudeMax = 12, area = 0, duration = 1, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "restore" },
    { id = "restoremagicka", display_name = "Restore Magicka", school = "Restoration", category = "Restore", range = RANGE_SELF, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "restore" },
    { id = "fortifyhealth", display_name = "Fortify Health", school = "Restoration", category = "Fortify", range = RANGE_SELF, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 20, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "restore" },
    { id = "fortifyfatigue", display_name = "Fortify Fatigue", school = "Restoration", category = "Fortify", range = RANGE_SELF, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 20, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "restore" },
    { id = "fortifymagicka", display_name = "Fortify Magicka", school = "Restoration", category = "Fortify", range = RANGE_SELF, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 20, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "restore" },
    { id = "shield", display_name = "Shield", school = "Alteration", category = "Defense", range = RANGE_SELF, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 20, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "shield" },
    { id = "fireshield", display_name = "Fire Shield", school = "Alteration", category = "Defense", range = RANGE_SELF, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 20, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "fire" },
    { id = "frostshield", display_name = "Frost Shield", school = "Alteration", category = "Defense", range = RANGE_SELF, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 20, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "frost" },
    { id = "lightningshield", display_name = "Lightning Shield", school = "Alteration", category = "Defense", range = RANGE_SELF, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 20, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "shock" },
    { id = "resistfire", display_name = "Resist Fire", school = "Restoration", category = "Resist", range = RANGE_SELF, magnitudeMin = 20, magnitudeMax = 20, area = 0, duration = 20, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "fire" },
    { id = "resistfrost", display_name = "Resist Frost", school = "Restoration", category = "Resist", range = RANGE_SELF, magnitudeMin = 20, magnitudeMax = 20, area = 0, duration = 20, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "frost" },
    { id = "resistshock", display_name = "Resist Shock", school = "Restoration", category = "Resist", range = RANGE_SELF, magnitudeMin = 20, magnitudeMax = 20, area = 0, duration = 20, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "shock" },
    { id = "resistpoison", display_name = "Resist Poison", school = "Restoration", category = "Resist", range = RANGE_SELF, magnitudeMin = 20, magnitudeMax = 20, area = 0, duration = 20, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "poison" },
    { id = "weaknessfire", display_name = "Weakness to Fire", school = "Destruction", category = "Weakness", range = RANGE_TARGET, magnitudeMin = 25, magnitudeMax = 25, area = 0, duration = 10, allowed_ranges = { RANGE_TOUCH, RANGE_TARGET }, color = "fire" },
    { id = "weaknessfrost", display_name = "Weakness to Frost", school = "Destruction", category = "Weakness", range = RANGE_TARGET, magnitudeMin = 25, magnitudeMax = 25, area = 0, duration = 10, allowed_ranges = { RANGE_TOUCH, RANGE_TARGET }, color = "frost" },
    { id = "weaknessshock", display_name = "Weakness to Shock", school = "Destruction", category = "Weakness", range = RANGE_TARGET, magnitudeMin = 25, magnitudeMax = 25, area = 0, duration = 10, allowed_ranges = { RANGE_TOUCH, RANGE_TARGET }, color = "shock" },
    { id = "weaknesspoison", display_name = "Weakness to Poison", school = "Destruction", category = "Weakness", range = RANGE_TARGET, magnitudeMin = 25, magnitudeMax = 25, area = 0, duration = 10, allowed_ranges = { RANGE_TOUCH, RANGE_TARGET }, color = "poison" },
    { id = "burden", display_name = "Burden", school = "Alteration", category = "Control", range = RANGE_TARGET, magnitudeMin = 20, magnitudeMax = 20, area = 0, duration = 15, allowed_ranges = { RANGE_TOUCH, RANGE_TARGET }, color = "drain" },
    { id = "feather", display_name = "Feather", school = "Alteration", category = "Utility", range = RANGE_SELF, magnitudeMin = 20, magnitudeMax = 20, area = 0, duration = 30, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "shield" },
    { id = "jump", display_name = "Jump", school = "Alteration", category = "Movement", range = RANGE_SELF, magnitudeMin = 20, magnitudeMax = 20, area = 0, duration = 15, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "shield" },
    { id = "levitate", display_name = "Levitate", school = "Alteration", category = "Movement", range = RANGE_SELF, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 20, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "shield" },
    { id = "slowfall", display_name = "Slowfall", school = "Alteration", category = "Movement", range = RANGE_SELF, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 20, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "shield" },
    { id = "waterbreathing", display_name = "Water Breathing", school = "Alteration", category = "Utility", range = RANGE_SELF, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 30, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "frost" },
    { id = "waterwalking", display_name = "Water Walking", school = "Alteration", category = "Utility", range = RANGE_SELF, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 30, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "frost" },
    { id = "open", display_name = "Open", school = "Alteration", category = "Utility", range = RANGE_TARGET, magnitudeMin = 20, magnitudeMax = 20, area = 0, duration = 1, allowed_ranges = { RANGE_TOUCH, RANGE_TARGET }, color = "shield" },
    { id = "paralyze", display_name = "Paralyze", school = "Illusion", category = "Control", range = RANGE_TARGET, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 3, allowed_ranges = { RANGE_TOUCH, RANGE_TARGET }, color = "drain" },
    { id = "silence", display_name = "Silence", school = "Illusion", category = "Control", range = RANGE_TARGET, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 10, allowed_ranges = { RANGE_TOUCH, RANGE_TARGET }, color = "drain" },
    { id = "blind", display_name = "Blind", school = "Illusion", category = "Control", range = RANGE_TARGET, magnitudeMin = 20, magnitudeMax = 20, area = 0, duration = 10, allowed_ranges = { RANGE_TOUCH, RANGE_TARGET }, color = "drain" },
    { id = "chameleon", display_name = "Chameleon", school = "Illusion", category = "Stealth", range = RANGE_SELF, magnitudeMin = 20, magnitudeMax = 20, area = 0, duration = 20, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "shield" },
    { id = "invisibility", display_name = "Invisibility", school = "Illusion", category = "Stealth", range = RANGE_SELF, magnitudeMin = 1, magnitudeMax = 1, area = 0, duration = 10, allowed_ranges = { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, color = "shield" },
    { id = "telekinesis", display_name = "Telekinesis", school = "Mysticism", category = "Utility", range = RANGE_SELF, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 20, allowed_ranges = { RANGE_SELF }, color = "shock" },
    { id = "detectanimal", display_name = "Detect Animal", school = "Mysticism", category = "Detect", range = RANGE_SELF, magnitudeMin = 50, magnitudeMax = 50, area = 0, duration = 20, allowed_ranges = { RANGE_SELF }, color = "shock" },
    { id = "detectkey", display_name = "Detect Key", school = "Mysticism", category = "Detect", range = RANGE_SELF, magnitudeMin = 50, magnitudeMax = 50, area = 0, duration = 20, allowed_ranges = { RANGE_SELF }, color = "shock" },
    { id = "detectenchantment", display_name = "Detect Enchantment", school = "Mysticism", category = "Detect", range = RANGE_SELF, magnitudeMin = 50, magnitudeMax = 50, area = 0, duration = 20, allowed_ranges = { RANGE_SELF }, color = "shock" },
}

local STATIC_BY_ID = nil

local function cloneValue(value, depth)
    if type(value) ~= "table" then
        return value
    end
    if (depth or 0) >= 4 then
        return tostring(value)
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = cloneValue(v, (depth or 0) + 1)
    end
    return out
end

local function normalizeId(value)
    if value == nil then
        return nil
    end
    local text = string.lower(tostring(value))
    if text == "" then
        return nil
    end
    return text
end

local function staticById()
    if STATIC_BY_ID then
        return STATIC_BY_ID
    end
    local by_id = {}
    for _, entry in ipairs(STATIC_EFFECTS) do
        by_id[normalizeId(entry.id)] = entry
    end
    STATIC_BY_ID = by_id
    return by_id
end

local function sortedKeys(tbl)
    local keys = {}
    for key in pairs(tbl or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

local function displayNameFromId(effect_id)
    local text = tostring(effect_id or "")
    text = string.gsub(text, "_", " ")
    text = string.gsub(text, "(%l)(%u)", "%1 %2")
    text = string.gsub(text, "^%l", string.upper)
    text = string.gsub(text, " (%l)", function(ch) return " " .. string.upper(ch) end)
    return text ~= "" and text or "Unknown Effect"
end

local function sampleNumber(sample, key, fallback)
    local value = sample and sample[key]
    if value == nil and key == "magnitudeMin" then
        value = sample and (sample.minMagnitude or sample.min)
    elseif value == nil and key == "magnitudeMax" then
        value = sample and (sample.maxMagnitude or sample.max)
    end
    local n = tonumber(value)
    if n ~= nil then
        return n
    end
    return fallback
end

local function entryFromTemplate(template, mode, known, source, sample)
    local entry = cloneValue(template or {}, 0)
    entry.id = normalizeId(entry.id or (sample and sample.id))
    entry.display_name = entry.display_name or displayNameFromId(entry.id)
    entry.school = entry.school or "Unknown"
    entry.category = entry.category or entry.school
    entry.default_range = sampleNumber(sample, "range", entry.range or RANGE_TARGET)
    entry.default_magnitude_min = sampleNumber(sample, "magnitudeMin", entry.magnitudeMin or 1)
    entry.default_magnitude_max = sampleNumber(sample, "magnitudeMax", entry.magnitudeMax or entry.default_magnitude_min or 1)
    entry.default_duration = sampleNumber(sample, "duration", entry.duration or 1)
    entry.default_area = sampleNumber(sample, "area", entry.area or 0)
    entry.range = entry.default_range
    entry.magnitudeMin = entry.default_magnitude_min
    entry.magnitudeMax = entry.default_magnitude_max
    entry.duration = entry.default_duration
    entry.area = entry.default_area
    entry.allowed_ranges = cloneValue(entry.allowed_ranges or { RANGE_SELF, RANGE_TOUCH, RANGE_TARGET }, 0)
    entry.known = known == true
    entry.source = source
    entry.source_mode = mode
    return entry
end

local function normalizeKnownSamples(payload)
    local known = {}
    local samples = {}
    local known_ids = type(payload and payload.known_effect_ids) == "table" and payload.known_effect_ids or {}
    local known_samples = type(payload and payload.known_effect_samples) == "table" and payload.known_effect_samples or {}
    for _, value in ipairs(known_ids) do
        local id = normalizeId(value)
        if id and not OPERATOR_EFFECT_IDS[id] and string.sub(id, 1, 11) ~= "spellforge_" then
            known[id] = true
        end
    end
    for key, sample in pairs(known_samples) do
        local id = normalizeId((type(sample) == "table" and sample.id) or key)
        if id and not OPERATOR_EFFECT_IDS[id] and string.sub(id, 1, 11) ~= "spellforge_" then
            known[id] = true
            if type(sample) == "table" then
                samples[id] = cloneValue(sample, 0)
                samples[id].id = id
            end
        end
    end
    return known, samples
end

local function addWarnings(result, reason)
    if not reason then
        return
    end
    result.warnings[#result.warnings + 1] = validation.warning(
        "available_effects",
        "Player-known effect scanning is unavailable; using the static fallback catalog.",
        "known_effect_scan_unavailable",
        { reason = reason }
    )
    result.capability_notes.known_effect_scan_unavailable = true
end

local function appendEntry(result, entry)
    result.base_effects[#result.base_effects + 1] = entry
    result.base_effects_by_id[entry.id] = entry
end

local function normalizedAvailableResult(payload)
    if type(payload) ~= "table" or type(payload.base_effects) ~= "table" then
        return nil
    end
    local result = cloneValue(payload, 0)
    if type(result.base_effects_by_id) ~= "table" then
        result.base_effects_by_id = {}
    end
    for _, entry in ipairs(result.base_effects or {}) do
        local id = normalizeId(entry and entry.id)
        if id then
            entry.id = id
            result.base_effects_by_id[id] = entry
        end
    end
    result.ok = result.ok ~= false
    result.catalog_version = result.catalog_version or base_effect_catalog.VERSION
    result.schema_version = result.schema_version or "spellforge-ui-recipe-v1"
    result.source_mode = result.source_mode or result.source or "fallback_static"
    result.source = result.source or result.source_mode
    result.base_effect_count = result.base_effect_count or #result.base_effects
    result.warnings = result.warnings or {}
    result.capability_notes = result.capability_notes or {}
    result.enforce_known_effects = result.enforce_known_effects == true or result.source_mode == "player_known"
    return result
end

function base_effect_catalog.buildAvailableEffects(payload)
    local p = payload or {}
    local prebuilt = normalizedAvailableResult(p)
    if prebuilt then
        return prebuilt
    end

    local known, samples = normalizeKnownSamples(p)
    local known_keys = sortedKeys(known)
    local source_mode = "fallback_static"
    local fallback_reason = p.known_effect_scan_reason or "known_effect_scan_unavailable"
    if p.dev_full_catalog == true then
        source_mode = "dev_full_catalog"
        fallback_reason = nil
    elseif p.known_effect_scan_status == "ok" then
        source_mode = "player_known"
        fallback_reason = #known_keys == 0 and "known_effect_scan_empty" or nil
    end

    local result = {
        ok = true,
        catalog_version = base_effect_catalog.VERSION,
        schema_version = "spellforge-ui-recipe-v1",
        source_mode = source_mode,
        source = source_mode,
        base_effects = {},
        base_effects_by_id = {},
        warnings = {},
        capability_notes = {},
        enforce_known_effects = source_mode == "player_known",
    }

    local static_by_id = staticById()
    if source_mode == "player_known" then
        for _, id in ipairs(known_keys) do
            local template = static_by_id[id] or { id = id, display_name = displayNameFromId(id), school = "Unknown", category = "Known" }
            appendEntry(result, entryFromTemplate(template, source_mode, true, "player_known_spell", samples[id]))
        end
        if fallback_reason == "known_effect_scan_empty" then
            result.capability_notes.known_effect_scan_empty = true
        end
    else
        local source = source_mode == "dev_full_catalog" and "dev_full_catalog" or "static_fallback"
        for _, template in ipairs(STATIC_EFFECTS) do
            appendEntry(result, entryFromTemplate(template, source_mode, source_mode == "dev_full_catalog", source, nil))
        end
        addWarnings(result, fallback_reason)
    end

    result.base_effect_count = #result.base_effects
    return result
end

local function availableFromPayload(payload)
    local result = normalizedAvailableResult(payload)
    if result then
        return result
    end
    return base_effect_catalog.buildAvailableEffects(payload)
end

local function rangeAllowed(entry, range_value)
    for _, allowed in ipairs(entry.allowed_ranges or {}) do
        if tonumber(allowed) == range_value then
            return true
        end
    end
    return false
end

local function validateBounds(errors, effect, index)
    local path = string.format("effects[%d]", index)
    local range = tonumber(effect.range)
    if range == nil or (range ~= RANGE_SELF and range ~= RANGE_TOUCH and range ~= RANGE_TARGET) then
        errors[#errors + 1] = validation.error(path .. ".range", "effect range must be Self, Touch, or Target", "effect_range_invalid", {
            value = effect.range,
        })
    end

    local mag_min = tonumber(effect.magnitudeMin)
    local mag_max = tonumber(effect.magnitudeMax)
    local duration = tonumber(effect.duration)
    local area = tonumber(effect.area)
    if mag_min == nil or mag_max == nil or mag_min < 0 or mag_max < 0 or mag_max < mag_min
        or duration == nil or duration < 0
        or area == nil or area < 0 then
        errors[#errors + 1] = validation.error(path, "effect magnitude, duration, and area bounds are invalid", "effect_bounds_invalid", {
            magnitudeMin = effect.magnitudeMin,
            magnitudeMax = effect.magnitudeMax,
            duration = effect.duration,
            area = effect.area,
        })
    end
end

function base_effect_catalog.validateRecipeEffects(effects, available_payload)
    local available = availableFromPayload(available_payload)
    local errors = {}
    local warnings = {}

    if available.capability_notes and available.capability_notes.known_effect_scan_unavailable then
        warnings[#warnings + 1] = validation.warning(
            "available_effects",
            "True player-known effect enforcement is unavailable; validation is using the fallback catalog.",
            "known_effect_scan_unavailable",
            { source_mode = available.source_mode }
        )
    end

    for index, effect in ipairs(effects or {}) do
        local id = normalizeId(effect and effect.id)
        if id and not OPERATOR_EFFECT_IDS[id] then
            if string.sub(id, 1, 11) == "spellforge_" then
                errors[#errors + 1] = validation.error(
                    string.format("effects[%d].id", index),
                    "Spellforge operator id is not a base magical effect",
                    "operator_effect_not_base_effect",
                    { effect_id = effect.id }
                )
            else
                local entry = available.base_effects_by_id and available.base_effects_by_id[id]
                if not entry then
                    local code = available.source_mode == "player_known" and "effect_unavailable" or "effect_unknown"
                    errors[#errors + 1] = validation.error(
                        string.format("effects[%d].id", index),
                        string.format("base effect is not available: %s", tostring(effect.id)),
                        code,
                        { effect_id = effect.id, source_mode = available.source_mode }
                    )
                elseif available.enforce_known_effects == true and entry.known ~= true then
                    errors[#errors + 1] = validation.error(
                        string.format("effects[%d].id", index),
                        string.format("base effect is not available to the player: %s", tostring(effect.id)),
                        "effect_unavailable",
                        { effect_id = effect.id, source_mode = available.source_mode }
                    )
                else
                    validateBounds(errors, effect, index)
                    local range = tonumber(effect.range)
                    if range ~= nil and not rangeAllowed(entry, range) then
                        errors[#errors + 1] = validation.error(
                            string.format("effects[%d].range", index),
                            string.format("effect range is not available for %s", tostring(effect.id)),
                            "effect_range_invalid",
                            { effect_id = effect.id, range = effect.range }
                        )
                    end
                end
            end
        end
    end

    return {
        ok = #errors == 0,
        errors = errors,
        warnings = warnings,
        source_mode = available.source_mode,
        base_effect_count = available.base_effect_count or #(available.base_effects or {}),
    }
end

function base_effect_catalog.isOperatorEffectId(effect_id)
    return OPERATOR_EFFECT_IDS[normalizeId(effect_id)] == true
end

function base_effect_catalog.staticEffects()
    return cloneValue(STATIC_EFFECTS, 0)
end

return base_effect_catalog
