local limits = require("scripts.spellforge.shared.limits")
local parser = require("scripts.spellforge.global.parser")

local feature_matrix = {}

feature_matrix.VERSION = "spellforge-feature-matrix-v1"

local FLAG_LIVE_2_2C = "SpellforgeDev.enable_live_2_2c_runtime"
local FLAG_MULTICAST = "SpellforgeDev.enable_live_multicast"
local FLAG_SPREAD_BURST = "SpellforgeDev.enable_live_spread_burst"
local FLAG_TRIGGER = "SpellforgeDev.enable_live_trigger"
local FLAG_TIMER = "SpellforgeDev.enable_live_timer"
local FLAG_SPEED_PLUS = "SpellforgeDev.enable_live_speed_plus"
local FLAG_SIZE_PLUS = "SpellforgeDev.enable_live_size_plus"
local FLAG_PAYLOAD_MULTICAST = "SpellforgeDev.enable_live_payload_multicast_v0"
local FLAG_PAYLOAD_PATTERN = "SpellforgeDev.enable_live_payload_pattern_v0"
local FLAG_NESTED_TRIGGER_TIMER = "SpellforgeDev.enable_live_nested_trigger_timer_v1"
local FLAG_NESTED_FINAL_FANOUT = "SpellforgeDev.enable_live_nested_final_fanout_v0"
local FLAG_CHAIN = "SpellforgeDev.enable_live_chain_runtime_v0"
local FLAG_CHAIN_MULTICAST = "SpellforgeDev.enable_live_chain_multicast_v0"
local FLAG_BOUNCE = "SpellforgeDev.enable_live_bounce_v0"
local FLAG_HOMING = "SpellforgeDev.enable_live_homing_v0"
local FLAG_SOFT_HOMING = "SpellforgeDev.enable_live_soft_homing_v0"

local OPCODE_TO_FEATURE = {
    Multicast = "multicast",
    Spread = "spread_burst",
    Burst = "spread_burst",
    ["Speed+"] = "speed_plus",
    ["Size+"] = "size_plus",
    Chain = "chain",
    Bounce = "bounce",
    Homing = "homing",
    Trigger = "trigger",
    Timer = "timer",
}

local FEATURE_DEFS = {
    {
        id = "simple_projectile",
        display_name = "Simple projectile",
        category = "core",
        status = "feature_gated",
        gates = { FLAG_LIVE_2_2C },
        summary = "Compiled helper/orchestrator dispatch for ordinary emitter groups.",
    },
    {
        id = "multicast",
        display_name = "Multicast",
        category = "fanout",
        status = "feature_gated",
        gates = { FLAG_LIVE_2_2C, FLAG_MULTICAST },
        summary = "Primary Multicast fanout, with payload Multicast covered by its payload gate.",
    },
    {
        id = "spread_burst",
        display_name = "Spread/Burst",
        category = "fanout",
        status = "feature_gated",
        gates = { FLAG_LIVE_2_2C, FLAG_SPREAD_BURST },
        summary = "Launch-time deterministic pattern directions for Multicast emissions.",
    },
    {
        id = "trigger",
        display_name = "Trigger",
        category = "payload",
        status = "feature_gated",
        gates = { FLAG_LIVE_2_2C, FLAG_TRIGGER },
        summary = "Direct Trigger payload routing for conservative payload groups.",
    },
    {
        id = "timer",
        display_name = "Timer",
        category = "payload",
        status = "feature_gated",
        gates = { FLAG_LIVE_2_2C, FLAG_TIMER },
        summary = "Direct Timer payload routing through OpenMW simulation timers.",
    },
    {
        id = "payload_multicast",
        display_name = "Payload Multicast",
        category = "payload",
        status = "feature_gated",
        gates = { FLAG_LIVE_2_2C, FLAG_PAYLOAD_MULTICAST },
        summary = "Direct Trigger/Timer payload Multicast groups.",
    },
    {
        id = "payload_pattern",
        display_name = "Payload Spread/Burst",
        category = "payload",
        status = "feature_gated",
        gates = { FLAG_LIVE_2_2C, FLAG_PAYLOAD_MULTICAST, FLAG_PAYLOAD_PATTERN },
        summary = "Direct Trigger/Timer payload Multicast plus Spread/Burst groups.",
    },
    {
        id = "nested_trigger_timer",
        display_name = "Nested Trigger/Timer",
        category = "payload",
        status = "feature_gated_narrow",
        gates = { FLAG_LIVE_2_2C, FLAG_NESTED_TRIGGER_TIMER },
        summary = "Opposite-kind depth-2 Trigger/Timer chains only.",
    },
    {
        id = "nested_final_fanout",
        display_name = "Nested Final Fanout",
        category = "payload",
        status = "feature_gated_narrow",
        gates = { FLAG_LIVE_2_2C, FLAG_NESTED_FINAL_FANOUT },
        summary = "Bounded final Multicast or pattern fanout after mixed depth-2 Trigger/Timer chains.",
    },
    {
        id = "speed_plus",
        display_name = "Speed+",
        category = "modifier",
        status = "feature_gated",
        gates = { FLAG_LIVE_2_2C, FLAG_SPEED_PLUS },
        summary = "Launch-time speed mutation.",
    },
    {
        id = "size_plus",
        display_name = "Size+",
        category = "modifier",
        status = "feature_gated",
        gates = { FLAG_LIVE_2_2C, FLAG_SIZE_PLUS },
        summary = "Helper effect area mutation.",
    },
    {
        id = "chain",
        display_name = "Chain",
        category = "targeting",
        status = "feature_gated_narrow",
        gates = { FLAG_LIVE_2_2C, FLAG_CHAIN },
        summary = "Direct and Trigger->Chain simple payload hops, plus narrow Speed+/Size+ payload modifiers.",
    },
    {
        id = "chain_multicast",
        display_name = "Chain+Multicast",
        category = "targeting",
        status = "feature_gated_narrow",
        gates = { FLAG_LIVE_2_2C, FLAG_CHAIN, FLAG_CHAIN_MULTICAST },
        summary = "Bounded sibling fanout per Chain hop with one continuation claim per hop.",
    },
    {
        id = "bounce",
        display_name = "Bounce",
        category = "targeting",
        status = "feature_gated_narrow",
        gates = { FLAG_LIVE_2_2C, FLAG_BOUNCE },
        summary = "Source/Trigger Bounce v0 and the narrow Trigger->Chain payload bridge.",
    },
    {
        id = "homing",
        display_name = "Homing",
        category = "targeting",
        status = "feature_gated_narrow",
        gates = { FLAG_LIVE_2_2C, FLAG_HOMING },
        optional_gates = { FLAG_SOFT_HOMING },
        summary = "Narrow primary Homing -> simple target projectile shape.",
    },
}

local FEATURE_BY_ID = {}
for _, def in ipairs(FEATURE_DEFS) do
    FEATURE_BY_ID[def.id] = def
end

local function cloneArray(values)
    local out = {}
    for i, value in ipairs(values or {}) do
        out[i] = value
    end
    return out
end

local function sortedKeys(set)
    local keys = {}
    for key in pairs(set or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

local function addSet(set, key)
    if key ~= nil and key ~= "" then
        set[key] = true
    end
end

local function hasSet(set, key)
    return set and set[key] == true
end

local function copySet(set)
    local out = {}
    for key, value in pairs(set or {}) do
        out[key] = value
    end
    return out
end

local function addAll(set, values)
    for _, value in ipairs(values or {}) do
        addSet(set, value)
    end
end

local function contextName(depth)
    if depth <= 0 then
        return "primary"
    elseif depth == 1 then
        return "payload"
    end
    return "nested_payload"
end

local function addFeature(summary, feature_id, depth)
    if not feature_id then
        return
    end
    addSet(summary.active, feature_id)
    addSet(summary.contexts[contextName(depth)], feature_id)
    summary.counts[feature_id] = (summary.counts[feature_id] or 0) + 1
    local previous_depth = summary.min_depth[feature_id]
    if previous_depth == nil or depth < previous_depth then
        summary.min_depth[feature_id] = depth
    end
end

local function hasOpcode(ops, opcode)
    for _, op in ipairs(ops or {}) do
        if op.opcode == opcode then
            return true
        end
    end
    return false
end

local function firstPostfixOpcode(group)
    for _, op in ipairs(group.postfix_ops or {}) do
        if op.opcode == "Trigger" or op.opcode == "Timer" then
            return op.opcode
        end
    end
    return nil
end

local function scanGroups(groups, summary, depth, payload_stack)
    summary.max_payload_depth = math.max(summary.max_payload_depth, depth)

    for _, group in ipairs(groups or {}) do
        local prefix = group.prefix_ops or {}
        local postfix = group.postfix_ops or {}
        local has_chain = hasOpcode(prefix, "Chain")
        local has_multicast = hasOpcode(prefix, "Multicast")
        local has_pattern = hasOpcode(prefix, "Spread") or hasOpcode(prefix, "Burst")
        local has_speed = hasOpcode(prefix, "Speed+")
        local has_size = hasOpcode(prefix, "Size+")
        local has_bounce = hasOpcode(prefix, "Bounce")
        local has_homing = hasOpcode(prefix, "Homing")
        local has_trigger = hasOpcode(postfix, "Trigger")
        local has_timer = hasOpcode(postfix, "Timer")

        for _, op in ipairs(prefix) do
            addFeature(summary, OPCODE_TO_FEATURE[op.opcode], depth)
        end
        for _, op in ipairs(postfix) do
            addFeature(summary, OPCODE_TO_FEATURE[op.opcode], depth)
        end

        if has_chain and has_multicast then
            addFeature(summary, "chain_multicast", depth)
            addSet(summary.combos, "chain_multicast")
        end
        if has_pattern and depth > 0 then
            addFeature(summary, "payload_pattern", depth)
        end
        if has_multicast and depth > 0 then
            addFeature(summary, "payload_multicast", depth)
        end
        if depth > 0 and (has_trigger or has_timer) then
            addFeature(summary, "nested_trigger_timer", depth)
        end
        if depth >= 2 and (has_multicast or has_pattern) then
            addFeature(summary, "nested_final_fanout", depth)
        end

        if has_chain and has_pattern then
            addSet(summary.deferred_reasons, "chain_pattern_deferred")
        end
        if has_chain and (has_trigger or has_timer) then
            addSet(summary.deferred_reasons, "chain_trigger_timer_deferred")
        end
        if has_chain and (has_speed or has_size) and has_multicast then
            addSet(summary.deferred_reasons, "chain_modifier_multicast_deferred")
        end
        if has_chain and has_speed and has_size then
            addSet(summary.deferred_reasons, "chain_modifier_combo_deferred")
        end
        if has_chain and hasSet(payload_stack, "Chain") then
            addSet(summary.deferred_reasons, "chain_recursion_deferred")
        end
        if has_chain and depth >= 2 then
            addSet(summary.deferred_reasons, "chain_nested_payload_deferred")
        end
        if depth > 0 and has_speed and not has_chain then
            addSet(summary.deferred_reasons, "payload_speed_plus_runtime_deferred")
        end
        if depth > 0 and has_size and not has_chain then
            addSet(summary.deferred_reasons, "payload_size_plus_runtime_deferred")
        end

        if has_bounce and has_timer then
            addSet(summary.deferred_reasons, "bounce_timer_deferred")
        end
        if has_bounce and (has_multicast or has_pattern) then
            addSet(summary.deferred_reasons, "bounce_fanout_deferred")
        end
        if has_bounce and has_chain then
            addSet(summary.deferred_reasons, "bounce_chain_deferred")
        end
        if has_bounce and (has_speed or has_size) then
            addSet(summary.deferred_reasons, "bounce_modifier_deferred")
        end

        if has_homing and (
            has_chain
            or has_bounce
            or has_multicast
            or has_pattern
            or has_speed
            or has_size
            or has_trigger
            or has_timer
            or depth > 0
        ) then
            addSet(summary.deferred_reasons, "homing_composition_deferred")
        end

        local payload_opcode = firstPostfixOpcode(group)
        if group.payload and type(group.payload.effects) == "table" and #group.payload.effects > 0 then
            summary.has_payload = true
            local child_stack = copySet(payload_stack)
            if payload_opcode then
                if hasSet(payload_stack, payload_opcode) then
                    addSet(summary.deferred_reasons, "same_kind_nested_trigger_timer_deferred")
                end
                addSet(child_stack, payload_opcode)
            end
            if has_chain then
                addSet(child_stack, "Chain")
            end

            local parsed = parser.parseEffectList(group.payload.effects)
            if parsed.ok then
                scanGroups(parsed.groups, summary, depth + 1, child_stack)
            else
                addSet(summary.deferred_reasons, "payload_parse_failed")
            end
        end
    end
end

local function buildSummary(plan)
    local summary = {
        active = { simple_projectile = true },
        counts = {},
        min_depth = {},
        contexts = {
            primary = {},
            payload = {},
            nested_payload = {},
        },
        combos = {},
        deferred_reasons = {},
        max_payload_depth = 0,
        has_payload = false,
    }
    summary.counts.simple_projectile = 1
    summary.min_depth.simple_projectile = 0
    summary.contexts.primary.simple_projectile = true

    scanGroups(plan and plan.groups or {}, summary, 0, {})

    if summary.max_payload_depth > limits.MAX_NESTED_PAYLOAD_DEPTH then
        addSet(summary.deferred_reasons, "nested_payload_depth_cap_deferred")
    end

    return summary
end

local function buildFeatureEntry(feature_id, summary)
    local def = FEATURE_BY_ID[feature_id] or {
        id = feature_id,
        display_name = feature_id,
        category = "unknown",
        status = "unknown",
        gates = {},
        summary = "",
    }

    return {
        id = def.id,
        display_name = def.display_name,
        category = def.category,
        status = def.status,
        active = summary.active[feature_id] == true,
        gates = cloneArray(def.gates),
        optional_gates = cloneArray(def.optional_gates),
        count = summary.counts[feature_id] or 0,
        min_payload_depth = summary.min_depth[feature_id],
        summary = def.summary,
    }
end

local function collectRequiredFlags(active_features)
    local set = {}
    addSet(set, FLAG_LIVE_2_2C)
    for _, feature_id in ipairs(active_features or {}) do
        local def = FEATURE_BY_ID[feature_id]
        if def then
            addAll(set, def.gates)
        end
    end
    return sortedKeys(set)
end

function feature_matrix.catalog()
    local out = {}
    local empty_summary = {
        active = {},
        counts = {},
        min_depth = {},
    }
    for i, def in ipairs(FEATURE_DEFS) do
        out[i] = buildFeatureEntry(def.id, empty_summary)
    end
    return out
end

function feature_matrix.analyze(plan, opts)
    local options = opts or {}
    local summary = buildSummary(plan or {})
    local active_feature_ids = sortedKeys(summary.active)
    local deferred_reasons = sortedKeys(summary.deferred_reasons)
    local active_features = {}
    for i, feature_id in ipairs(active_feature_ids) do
        active_features[i] = buildFeatureEntry(feature_id, summary)
    end

    local support_status = #deferred_reasons > 0 and "deferred" or "feature_gated"
    local required_flags = collectRequiredFlags(active_feature_ids)

    return {
        version = feature_matrix.VERSION,
        source_kind = plan and plan.source_kind or nil,
        recipe_id = plan and plan.recipe_id or nil,
        preview_status = "supported",
        live_runtime_status = support_status,
        default_enabled = false,
        active_feature_ids = active_feature_ids,
        active_features = active_features,
        contexts = {
            primary = sortedKeys(summary.contexts.primary),
            payload = sortedKeys(summary.contexts.payload),
            nested_payload = sortedKeys(summary.contexts.nested_payload),
        },
        combos = sortedKeys(summary.combos),
        deferred_reasons = deferred_reasons,
        required_flags = required_flags,
        optional_flags = { FLAG_SOFT_HOMING },
        limits = {
            max_projectiles_per_cast = limits.MAX_PROJECTILES_PER_CAST,
            max_payload_fanout = limits.MAX_PAYLOAD_FANOUT,
            max_chain_hops = limits.MAX_CHAIN_HOPS,
            max_chain_multicast_fanout = limits.MAX_CHAIN_MULTICAST_FANOUT,
            max_bounce_count = limits.MAX_BOUNCE_COUNT,
            max_nested_payload_depth = limits.MAX_NESTED_PAYLOAD_DEPTH,
        },
        notes = options.notes,
    }
end

return feature_matrix
