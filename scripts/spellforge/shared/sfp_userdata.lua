local sfp_userdata = {}

local SCHEMA = "spellforge_sfp_userdata_v1"

local ALLOWED_SCALARS = {
    string = true,
    number = true,
    boolean = true,
}

local function setScalar(out, key, value)
    if ALLOWED_SCALARS[type(value)] then
        out[key] = value
    end
end

local function firstNonNil(...)
    local count = select("#", ...)
    for i = 1, count do
        local value = select(i, ...)
        if value ~= nil then
            return value
        end
    end
    return nil
end

local function mappingField(mapping, key)
    if type(mapping) == "table" then
        return mapping[key]
    end
    return nil
end

local function copyKnownScalars(source, keys)
    local out = {
        spellforge = true,
        schema = SCHEMA,
    }
    for _, key in ipairs(keys) do
        setScalar(out, key, source[key])
    end
    return out
end

function sfp_userdata.schema()
    return SCHEMA
end

function sfp_userdata.buildHelperUserData(args)
    local input = args or {}
    local mapping = input.mapping
    local out = {
        spellforge = true,
        schema = SCHEMA,
    }

    setScalar(out, "runtime", input.runtime or "2.2c_dev_helper")
    setScalar(out, "recipe_id", firstNonNil(input.recipe_id, mappingField(mapping, "recipe_id")))
    setScalar(out, "slot_id", firstNonNil(input.slot_id, mappingField(mapping, "slot_id")))
    setScalar(out, "helper_engine_id", firstNonNil(input.helper_engine_id, mappingField(mapping, "engine_id")))
    setScalar(out, "job_kind", input.job_kind or input.kind)
    setScalar(out, "job_id", input.job_id)
    setScalar(out, "parent_job_id", input.parent_job_id)
    setScalar(out, "source_job_id", input.source_job_id)
    setScalar(out, "depth", input.depth)
    setScalar(out, "source_slot_id", firstNonNil(input.source_slot_id, mappingField(mapping, "trigger_source_slot_id"), mappingField(mapping, "timer_source_slot_id")))
    setScalar(out, "source_postfix_opcode", firstNonNil(input.source_postfix_opcode, mappingField(mapping, "source_postfix_opcode")))
    setScalar(out, "payload_slot_id", input.payload_slot_id)
    setScalar(out, "source_helper_engine_id", input.source_helper_engine_id)
    setScalar(out, "trigger_source_slot_id", input.trigger_source_slot_id)
    setScalar(out, "trigger_payload_slot_id", input.trigger_payload_slot_id)
    setScalar(out, "has_trigger_payload", input.has_trigger_payload)
    setScalar(out, "trigger_route", input.trigger_route)
    setScalar(out, "trigger_duplicate_key", input.trigger_duplicate_key)
    setScalar(out, "timer_source_slot_id", input.timer_source_slot_id)
    setScalar(out, "timer_payload_slot_id", input.timer_payload_slot_id)
    setScalar(out, "has_timer_payload", input.has_timer_payload)
    setScalar(out, "timer_delay_ticks", input.timer_delay_ticks)
    setScalar(out, "timer_delay_seconds", input.timer_delay_seconds)
    setScalar(out, "timer_scheduled_tick", input.timer_scheduled_tick)
    setScalar(out, "timer_due_tick", input.timer_due_tick)
    setScalar(out, "timer_scheduled_seconds", input.timer_scheduled_seconds)
    setScalar(out, "timer_due_seconds", input.timer_due_seconds)
    setScalar(out, "timer_delay_semantics", input.timer_delay_semantics)
    setScalar(out, "timer_duplicate_key", input.timer_duplicate_key)
    setScalar(out, "timer_id", input.timer_id)
    setScalar(out, "cast_id", input.cast_id)
    setScalar(out, "emission_index", firstNonNil(input.emission_index, mappingField(mapping, "emission_index")))
    setScalar(out, "group_index", firstNonNil(input.group_index, mappingField(mapping, "group_index")))
    setScalar(out, "fanout_count", input.fanout_count)
    setScalar(out, "pattern_kind", input.pattern_kind)
    setScalar(out, "pattern_index", input.pattern_index)
    setScalar(out, "pattern_count", input.pattern_count)
    setScalar(out, "speed_plus", input.speed_plus)
    setScalar(out, "speed_plus_mode", input.speed_plus_mode)
    setScalar(out, "speed_plus_value", input.speed_plus_value)
    setScalar(out, "speed_plus_base_speed", input.speed_plus_base_speed)
    setScalar(out, "speed_plus_multiplier", input.speed_plus_multiplier)
    setScalar(out, "speed_plus_speed", input.speed_plus_speed)
    setScalar(out, "speed_plus_max_speed", input.speed_plus_max_speed)
    setScalar(out, "speed_plus_field", input.speed_plus_field)
    setScalar(out, "speed_plus_capped", input.speed_plus_capped)
    setScalar(out, "size_plus", input.size_plus)
    setScalar(out, "size_plus_mode", input.size_plus_mode)
    setScalar(out, "size_plus_value", input.size_plus_value)
    setScalar(out, "size_plus_multiplier", input.size_plus_multiplier)
    setScalar(out, "size_plus_field", input.size_plus_field)
    setScalar(out, "size_plus_capped", input.size_plus_capped)
    setScalar(out, "size_plus_base_area", input.size_plus_base_area)
    setScalar(out, "size_plus_area", input.size_plus_area)

    return out
end

function sfp_userdata.buildLegacyDispatchUserData(args)
    local input = args or {}
    local out = {
        spellforge = true,
        schema = SCHEMA,
        runtime = "2.2b_live_dispatch",
    }

    setScalar(out, "recipe_id", input.recipe_id)
    setScalar(out, "source_spell_id", input.source_spell_id)
    setScalar(out, "dispatch_spell_id", input.dispatch_spell_id)
    setScalar(out, "effect_index", input.effect_index)

    return out
end

function sfp_userdata.compactSpellforgeUserData(user_data)
    if not sfp_userdata.isSpellforgeUserData(user_data) then
        return nil
    end
    return copyKnownScalars(user_data, {
        "runtime",
        "recipe_id",
        "slot_id",
        "helper_engine_id",
        "job_kind",
        "job_id",
        "parent_job_id",
        "source_job_id",
        "depth",
        "source_slot_id",
        "source_postfix_opcode",
        "payload_slot_id",
        "source_helper_engine_id",
        "trigger_source_slot_id",
        "trigger_payload_slot_id",
        "has_trigger_payload",
        "trigger_route",
        "trigger_duplicate_key",
        "timer_source_slot_id",
        "timer_payload_slot_id",
        "has_timer_payload",
        "timer_delay_ticks",
        "timer_delay_seconds",
        "timer_scheduled_tick",
        "timer_due_tick",
        "timer_scheduled_seconds",
        "timer_due_seconds",
        "timer_delay_semantics",
        "timer_duplicate_key",
        "timer_id",
        "cast_id",
        "emission_index",
        "group_index",
        "fanout_count",
        "pattern_kind",
        "pattern_index",
        "pattern_count",
        "speed_plus",
        "speed_plus_mode",
        "speed_plus_value",
        "speed_plus_base_speed",
        "speed_plus_multiplier",
        "speed_plus_speed",
        "speed_plus_max_speed",
        "speed_plus_field",
        "speed_plus_capped",
        "size_plus",
        "size_plus_mode",
        "size_plus_value",
        "size_plus_multiplier",
        "size_plus_field",
        "size_plus_capped",
        "size_plus_base_area",
        "size_plus_area",
        "source_spell_id",
        "dispatch_spell_id",
        "effect_index",
    })
end

function sfp_userdata.extract(payload)
    local data = payload or {}
    local user_data = data.userData
    if type(user_data) ~= "table" then
        user_data = data.user_data
    end
    if type(user_data) == "table" then
        return user_data
    end
    return nil
end

function sfp_userdata.isSpellforgeUserData(user_data)
    return type(user_data) == "table"
        and user_data.spellforge == true
        and user_data.schema == SCHEMA
end

return sfp_userdata
