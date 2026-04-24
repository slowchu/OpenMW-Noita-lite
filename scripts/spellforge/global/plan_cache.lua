local limits = require("scripts.spellforge.shared.limits")
local parser = require("scripts.spellforge.global.parser")
local canonicalize_effect_list = require("scripts.spellforge.global.canonicalize_effect_list")
local emission_slots = require("scripts.spellforge.global.emission_slots")

local plan_cache = {}

local CANONICAL_VERSION = "spellforge-effect-list-v1"

local plans_by_recipe_id = {}

local function cloneParams(params)
    local out = {}
    local keys = {}
    for key in pairs(params or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        out[key] = params[key]
    end
    return out
end

local function sanitizeEffect(effect)
    if type(effect) ~= "table" then
        return {
            id = tostring(effect),
        }
    end

    return {
        id = effect.id,
        range = effect.range,
        area = effect.area,
        duration = effect.duration,
        magnitudeMin = effect.magnitudeMin,
        magnitudeMax = effect.magnitudeMax,
        params = cloneParams(effect.params),
    }
end

local function sanitizeEffects(effects)
    local out = {}
    for i, effect in ipairs(effects or {}) do
        out[i] = sanitizeEffect(effect)
    end
    return out
end

local function cloneOp(op)
    if type(op) ~= "table" then
        return nil
    end
    return {
        opcode = op.opcode,
        effect_id = op.effect_id,
        params = cloneParams(op.params),
        index = op.index,
        payload_scope = op.payload_scope,
    }
end

local function cloneEffects(effects)
    local out = {}
    for i, effect in ipairs(effects or {}) do
        out[i] = sanitizeEffect(effect)
    end
    return out
end

local function cloneGroups(groups)
    local out = {}
    for i, group in ipairs(groups or {}) do
        local prefix_ops = {}
        for j, op in ipairs(group.prefix_ops or {}) do
            prefix_ops[j] = cloneOp(op)
        end

        local postfix_ops = {}
        for j, op in ipairs(group.postfix_ops or {}) do
            postfix_ops[j] = cloneOp(op)
        end

        out[i] = {
            kind = group.kind,
            range = group.range,
            effects = cloneEffects(group.effects),
            prefix_ops = prefix_ops,
            postfix_ops = postfix_ops,
            payload = group.payload and {
                scope = group.payload.scope,
                effects = cloneEffects(group.payload.effects),
                note = group.payload.note,
            } or nil,
            emission_count_static = group.emission_count_static,
        }
    end
    return out
end

local function cloneErrors(errors)
    local out = {}
    for i, err in ipairs(errors or {}) do
        out[i] = {
            path = err.path,
            message = err.message,
        }
    end
    return out
end

local function summarizeBounds(groups, effect_count)
    local bounds = {
        static_emission_count = 0,
        max_projectiles = limits.MAX_PROJECTILES_PER_CAST,
        has_trigger = false,
        has_timer = false,
        has_multicast = false,
        has_pattern = false,
        has_chain = false,
        group_count = #(groups or {}),
        effect_count = effect_count or 0,
    }

    for _, group in ipairs(groups or {}) do
        bounds.static_emission_count = bounds.static_emission_count + (group.emission_count_static or 1)

        for _, op in ipairs(group.prefix_ops or {}) do
            if op.opcode == "Multicast" then
                bounds.has_multicast = true
            elseif op.opcode == "Burst" or op.opcode == "Spread" then
                bounds.has_pattern = true
            elseif op.opcode == "Chain" then
                bounds.has_chain = true
            end
        end

        for _, op in ipairs(group.postfix_ops or {}) do
            if op.opcode == "Trigger" then
                bounds.has_trigger = true
            elseif op.opcode == "Timer" then
                bounds.has_timer = true
            end
        end
    end

    return bounds
end

local function buildPlan(effects, parse_result, canonical)
    local groups = cloneGroups(parse_result.groups)
    local plan = {
        recipe_id = canonical.recipe_id,
        canonical = canonical.canonical,
        canonical_version = CANONICAL_VERSION,
        source_kind = "effect_list",
        effects = sanitizeEffects(effects),
        parse_result = {
            ok = parse_result.ok,
            warnings = cloneErrors(parse_result.warnings),
            errors = cloneErrors(parse_result.errors),
        },
        groups = groups,
        bounds = summarizeBounds(groups, #(effects or {})),
        warnings = cloneErrors(parse_result.warnings),
        created_runtime_records = false,
        helper_records = {},
        runtime_status = "staged_only",
    }
    return plan
end

function plan_cache.put(plan)
    if type(plan) ~= "table" or type(plan.recipe_id) ~= "string" or plan.recipe_id == "" then
        return false
    end
    plans_by_recipe_id[plan.recipe_id] = plan
    return true
end

function plan_cache.get(recipe_id)
    return plans_by_recipe_id[recipe_id]
end

function plan_cache.has(recipe_id)
    return plans_by_recipe_id[recipe_id] ~= nil
end

function plan_cache.clearForTests()
    plans_by_recipe_id = {}
end

function plan_cache.clear()
    plan_cache.clearForTests()
end

function plan_cache.compileOrGet(effects, opts)
    local canonical = canonicalize_effect_list.run(effects, opts)
    local cached = plan_cache.get(canonical.recipe_id)
    if cached then
        return {
            ok = true,
            reused = true,
            recipe_id = canonical.recipe_id,
            canonical = canonical.canonical,
            plan = cached,
        }
    end

    local parse_result = parser.parseEffectList(effects, opts)
    if not parse_result.ok then
        return {
            ok = false,
            reused = false,
            recipe_id = canonical.recipe_id,
            canonical = canonical.canonical,
            errors = cloneErrors(parse_result.errors),
            warnings = cloneErrors(parse_result.warnings),
        }
    end

    local plan = buildPlan(effects, parse_result, canonical)
    plan_cache.put(plan)

    return {
        ok = true,
        reused = false,
        recipe_id = canonical.recipe_id,
        canonical = canonical.canonical,
        plan = plan,
        warnings = cloneErrors(parse_result.warnings),
    }
end

function plan_cache.attachEmissionSlots(recipe_id, opts)
    local plan = plan_cache.get(recipe_id)
    if not plan then
        return {
            ok = false,
            errors = {
                { path = "recipe_id", message = string.format("No cached plan for recipe_id=%s", tostring(recipe_id)) },
            },
            warnings = {},
        }
    end

    local allocated = emission_slots.allocate(plan, opts)
    if not allocated.ok then
        return allocated
    end

    plan.emission_slots = allocated.slots
    plan.slot_count = allocated.slot_count
    plan.slot_warnings = allocated.warnings

    return {
        ok = true,
        recipe_id = recipe_id,
        slot_count = allocated.slot_count,
        warnings = allocated.warnings,
        plan = plan,
    }
end

return plan_cache
