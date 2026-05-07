local limits = require("scripts.spellforge.shared.limits")

local defs = {}

defs.VERSION = "spellforge-feature-matrix-v1"

defs.FLAGS = {
    LIVE_2_2C = "SpellforgeDev.enable_live_2_2c_runtime",
    MULTICAST = "SpellforgeDev.enable_live_multicast",
    SPREAD_BURST = "SpellforgeDev.enable_live_spread_burst",
    TRIGGER = "SpellforgeDev.enable_live_trigger",
    TIMER = "SpellforgeDev.enable_live_timer",
    SPEED_PLUS = "SpellforgeDev.enable_live_speed_plus",
    SIZE_PLUS = "SpellforgeDev.enable_live_size_plus",
    PAYLOAD_MULTICAST = "SpellforgeDev.enable_live_payload_multicast_v0",
    PAYLOAD_PATTERN = "SpellforgeDev.enable_live_payload_pattern_v0",
    NESTED_TRIGGER_TIMER = "SpellforgeDev.enable_live_nested_trigger_timer_v1",
    NESTED_FINAL_FANOUT = "SpellforgeDev.enable_live_nested_final_fanout_v0",
    CHAIN = "SpellforgeDev.enable_live_chain_runtime_v0",
    CHAIN_MULTICAST = "SpellforgeDev.enable_live_chain_multicast_v0",
    BOUNCE = "SpellforgeDev.enable_live_bounce_v0",
    PIERCE = "SpellforgeDev.enable_live_pierce_v0",
    HOMING = "SpellforgeDev.enable_live_homing_v0",
    SOFT_HOMING = "SpellforgeDev.enable_live_soft_homing_v0",
}

defs.OPCODE_TO_FEATURE = {
    Multicast = "multicast",
    Spread = "spread_burst",
    Burst = "spread_burst",
    ["Speed+"] = "speed_plus",
    ["Size+"] = "size_plus",
    Chain = "chain",
    Bounce = "bounce",
    Pierce = "pierce",
    Homing = "homing",
    Trigger = "trigger",
    Timer = "timer",
}

defs.FEATURE_DEFS = {
    {
        id = "simple_projectile",
        display_name = "Simple projectile",
        category = "core",
        status = "feature_gated",
        gates = { defs.FLAGS.LIVE_2_2C },
        summary = "Compiled helper/orchestrator dispatch for ordinary emitter groups.",
    },
    {
        id = "multicast",
        display_name = "Multicast",
        category = "fanout",
        status = "feature_gated",
        gates = { defs.FLAGS.LIVE_2_2C, defs.FLAGS.MULTICAST },
        summary = "Primary Multicast fanout, with payload Multicast covered by its payload gate.",
    },
    {
        id = "spread_burst",
        display_name = "Spread/Burst",
        category = "fanout",
        status = "feature_gated",
        gates = { defs.FLAGS.LIVE_2_2C, defs.FLAGS.SPREAD_BURST },
        summary = "Launch-time deterministic pattern directions for Multicast emissions.",
    },
    {
        id = "trigger",
        display_name = "Trigger",
        category = "payload",
        status = "feature_gated",
        gates = { defs.FLAGS.LIVE_2_2C, defs.FLAGS.TRIGGER },
        summary = "Direct Trigger payload routing for conservative payload groups.",
    },
    {
        id = "timer",
        display_name = "Timer",
        category = "payload",
        status = "feature_gated",
        gates = { defs.FLAGS.LIVE_2_2C, defs.FLAGS.TIMER },
        summary = "Direct Timer payload routing through OpenMW simulation timers.",
    },
    {
        id = "payload_multicast",
        display_name = "Payload Multicast",
        category = "payload",
        status = "feature_gated",
        gates = { defs.FLAGS.LIVE_2_2C, defs.FLAGS.PAYLOAD_MULTICAST },
        summary = "Direct Trigger/Timer payload Multicast groups, including Bounce/Pierce-owned Trigger payload fanout.",
    },
    {
        id = "payload_pattern",
        display_name = "Payload Spread/Burst",
        category = "payload",
        status = "feature_gated",
        gates = { defs.FLAGS.LIVE_2_2C, defs.FLAGS.PAYLOAD_MULTICAST, defs.FLAGS.PAYLOAD_PATTERN },
        summary = "Direct Trigger/Timer payload Multicast plus Spread/Burst groups, including Bounce/Pierce-owned Trigger payload patterns.",
    },
    {
        id = "nested_trigger_timer",
        display_name = "Nested Trigger/Timer",
        category = "payload",
        status = "feature_gated_narrow",
        gates = { defs.FLAGS.LIVE_2_2C, defs.FLAGS.NESTED_TRIGGER_TIMER },
        summary = "Opposite-kind depth-2 Trigger/Timer chains only.",
    },
    {
        id = "nested_final_fanout",
        display_name = "Nested Final Fanout",
        category = "payload",
        status = "feature_gated_narrow",
        gates = { defs.FLAGS.LIVE_2_2C, defs.FLAGS.NESTED_FINAL_FANOUT },
        summary = "Bounded final Multicast or pattern fanout after mixed depth-2 Trigger/Timer chains.",
    },
    {
        id = "speed_plus",
        display_name = "Speed+",
        category = "modifier",
        status = "feature_gated",
        gates = { defs.FLAGS.LIVE_2_2C, defs.FLAGS.SPEED_PLUS },
        summary = "Launch-time speed mutation.",
    },
    {
        id = "size_plus",
        display_name = "Size+",
        category = "modifier",
        status = "feature_gated",
        gates = { defs.FLAGS.LIVE_2_2C, defs.FLAGS.SIZE_PLUS },
        summary = "Helper effect area mutation.",
    },
    {
        id = "chain",
        display_name = "Chain",
        category = "targeting",
        status = "feature_gated_narrow",
        gates = { defs.FLAGS.LIVE_2_2C, defs.FLAGS.CHAIN },
        summary = "Direct and Trigger->Chain simple payload hops, plus narrow Speed+/Size+ payload modifiers.",
    },
    {
        id = "chain_multicast",
        display_name = "Chain+Multicast",
        category = "targeting",
        status = "feature_gated_narrow",
        gates = { defs.FLAGS.LIVE_2_2C, defs.FLAGS.CHAIN, defs.FLAGS.CHAIN_MULTICAST },
        summary = "Bounded sibling fanout per Chain hop with one continuation claim per hop.",
    },
    {
        id = "bounce",
        display_name = "Bounce",
        category = "targeting",
        status = "feature_gated_narrow",
        gates = { defs.FLAGS.LIVE_2_2C, defs.FLAGS.BOUNCE },
        summary = "Bounce v0 source projectiles, Trigger payload fanout, and the narrow Trigger->Chain payload bridge.",
    },
    {
        id = "pierce",
        display_name = "Pierce",
        category = "targeting",
        status = "feature_gated_narrow",
        gates = { defs.FLAGS.LIVE_2_2C, defs.FLAGS.PIERCE },
        summary = "Pierce v0 source projectiles, Trigger payload fanout, and the narrow Trigger->Chain payload bridge.",
    },
    {
        id = "homing",
        display_name = "Homing",
        category = "targeting",
        status = "feature_gated_narrow",
        gates = { defs.FLAGS.LIVE_2_2C, defs.FLAGS.HOMING },
        optional_gates = { defs.FLAGS.SOFT_HOMING },
        summary = "Narrow primary Homing -> simple target projectile shape.",
    },
}

defs.FEATURE_BY_ID = {}
for _, def in ipairs(defs.FEATURE_DEFS) do
    defs.FEATURE_BY_ID[def.id] = def
end

function defs.cloneArray(values)
    local out = {}
    for i, value in ipairs(values or {}) do
        out[i] = value
    end
    return out
end

function defs.sortedKeys(set)
    local keys = {}
    for key in pairs(set or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

function defs.addSet(set, key)
    if key ~= nil and key ~= "" then
        set[key] = true
    end
end

function defs.addAll(set, values)
    for _, value in ipairs(values or {}) do
        defs.addSet(set, value)
    end
end

function defs.buildFeatureEntry(feature_id, summary)
    local active_summary = summary or {}
    local def = defs.FEATURE_BY_ID[feature_id] or {
        id = feature_id,
        display_name = feature_id,
        category = "unknown",
        status = "unknown",
        gates = {},
        optional_gates = {},
        summary = "",
    }

    return {
        id = def.id,
        display_name = def.display_name,
        category = def.category,
        status = def.status,
        active = active_summary.active and active_summary.active[feature_id] == true or false,
        gates = defs.cloneArray(def.gates),
        optional_gates = defs.cloneArray(def.optional_gates),
        count = active_summary.counts and active_summary.counts[feature_id] or 0,
        min_payload_depth = active_summary.min_depth and active_summary.min_depth[feature_id] or nil,
        summary = def.summary,
    }
end

function defs.collectRequiredFlags(active_features)
    local set = {}
    defs.addSet(set, defs.FLAGS.LIVE_2_2C)
    for _, feature_id in ipairs(active_features or {}) do
        local def = defs.FEATURE_BY_ID[feature_id]
        if def then
            defs.addAll(set, def.gates)
        end
    end
    return defs.sortedKeys(set)
end

function defs.optionalFlags()
    return { defs.FLAGS.SOFT_HOMING }
end

function defs.limitReport()
    return {
        max_projectiles_per_cast = limits.MAX_PROJECTILES_PER_CAST,
        max_payload_fanout = limits.MAX_PAYLOAD_FANOUT,
        max_chain_hops = limits.MAX_CHAIN_HOPS,
        max_chain_multicast_fanout = limits.MAX_CHAIN_MULTICAST_FANOUT,
        max_bounce_count = limits.MAX_BOUNCE_COUNT,
        max_pierce_count = limits.MAX_PIERCE_COUNT,
        max_nested_payload_depth = limits.MAX_NESTED_PAYLOAD_DEPTH,
    }
end

function defs.catalog()
    local out = {}
    local empty_summary = {
        active = {},
        counts = {},
        min_depth = {},
    }
    for i, def in ipairs(defs.FEATURE_DEFS) do
        out[i] = defs.buildFeatureEntry(def.id, empty_summary)
    end
    return out
end

return defs
