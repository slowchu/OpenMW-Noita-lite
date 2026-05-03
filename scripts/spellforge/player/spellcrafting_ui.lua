local async = require("openmw.async")
local input = require("openmw.input")
local I = require("openmw.interfaces")
local openmw_ui = require("openmw.ui")
local util = require("openmw.util")

local dev = require("scripts.spellforge.shared.dev")
local log = require("scripts.spellforge.shared.log").new("player.spellcrafting_ui")
local operator_params = require("scripts.spellforge.shared.operator_params")
local ui_api = require("scripts.spellforge.player.ui")

local spellcrafting_ui = {}

local v2 = util.vector2

local LAYER_NAME = "Windows"
local MAX_WINDOW_SIZE = v2(820, 560)
local MIN_WINDOW_SIZE = v2(500, 420)
local SCREEN_MARGIN = 8
local DEFAULT_TITLE = "New Spell"

local function mkColor(r, g, b, a)
    if util.color and util.color.rgba then
        return util.color.rgba(r, g, b, a or 1)
    end
    if util.color and util.color.rgb then
        return util.color.rgb(r, g, b)
    end
    return nil
end

local COLOR = {
    title        = mkColor(0.96, 0.84, 0.52),
    subtitle     = mkColor(0.72, 0.72, 0.78),
    section      = mkColor(0.92, 0.82, 0.55),
    text         = mkColor(0.93, 0.93, 0.93),
    muted        = mkColor(0.62, 0.62, 0.66),
    accent       = mkColor(0.65, 0.85, 1.00),
    selected     = mkColor(1.00, 0.82, 0.45),
    success      = mkColor(0.55, 0.92, 0.65),
    error        = mkColor(0.98, 0.55, 0.55),
    warning      = mkColor(0.98, 0.82, 0.50),
    info         = mkColor(0.78, 0.86, 0.95),
    fire         = mkColor(1.00, 0.62, 0.30),
    frost        = mkColor(0.55, 0.85, 1.00),
    shock        = mkColor(0.92, 0.85, 0.42),
    poison       = mkColor(0.62, 0.92, 0.55),
    shield       = mkColor(0.95, 0.85, 0.55),
    restore      = mkColor(0.75, 0.95, 0.85),
    drain        = mkColor(0.78, 0.55, 0.95),
    op_modifier  = mkColor(0.82, 0.62, 1.00),
    op_scope     = mkColor(0.55, 0.92, 0.92),
}

local GLYPHS = {
    cursor  = ">>",
    bullet  = "*",
    sep     = "  -  ",
    sub_sep = ", ",
    blank   = "  ",
}

local SUBTITLE = "Compose base effects and operators into a spell."
local BANNER_TITLE = "SPELLFORGE  --  Spellmaking"

local BASE_EFFECTS = {
    {
        label = "Fire Damage",
        effect = { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    },
    {
        label = "Frost Damage",
        effect = { id = "frostdamage", range = 2, magnitudeMin = 8, magnitudeMax = 8, area = 0, duration = 1 },
    },
    {
        label = "Shield",
        effect = { id = "shield", range = 0, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 10 },
    },
}

local DEFAULT_OPERATOR_PARAMS = {
    Multicast = { count = 3 },
    Spread = { preset = 1 },
    Burst = { count = 5 },
    ["Speed+"] = { percent = 50 },
    ["Size+"] = { percent = 100 },
    Chain = { hops = 3 },
    Bounce = { bounces = 3 },
    Homing = {},
    Trigger = {},
    Timer = { seconds = 1.0 },
}

local RANGE_LABELS = {
    [0] = "Self",
    [1] = "Touch",
    [2] = "Target",
}

local state = {
    visible = false,
    mode_added = false,
    root = nil,
    catalog = nil,
    title = DEFAULT_TITLE,
    effects = {},
    selected_index = nil,
    selected_saved_id = nil,
    status = "Welcome to the Spellforge.",
    status_kind = "info",
    preview = nil,
    last_validation = nil,
    last_layout = nil,
    recipe_generation = 0,
}

local function templates()
    return I.MWUI and I.MWUI.templates or {}
end

local function template(name)
    return templates()[name]
end

local function cloneValue(value, depth)
    if type(value) ~= "table" then
        return value
    end
    if (depth or 0) >= 5 then
        return tostring(value)
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = cloneValue(v, (depth or 0) + 1)
    end
    return out
end

local function shortText(value, max_len)
    local text = tostring(value or "")
    if max_len and #text > max_len then
        return string.sub(text, 1, max_len - 3) .. "..."
    end
    return text
end

local function clamp(value, min_value, max_value)
    return math.max(min_value, math.min(max_value, value))
end

local function physicalScreenSize()
    local screen = openmw_ui.screenSize()
    return v2(screen and screen.x or MAX_WINDOW_SIZE.x, screen and screen.y or MAX_WINDOW_SIZE.y)
end

local function currentLayerSize()
    local layers = openmw_ui.layers
    local index = layers and layers.indexOf and layers.indexOf(LAYER_NAME) or nil
    local layer = index and layers[index] or nil
    if layer and layer.size then
        return layer.size, "layer"
    end
    return physicalScreenSize(), "screen"
end

local function layoutMetrics()
    local screen = physicalScreenSize()
    local layer, size_source = currentLayerSize()
    local available_w = math.max(1, layer.x - SCREEN_MARGIN * 2)
    local available_h = math.max(1, layer.y - SCREEN_MARGIN * 2)
    local window_w = math.floor(math.min(MAX_WINDOW_SIZE.x, available_w))
    local window_h = math.floor(math.min(MAX_WINDOW_SIZE.y, available_h))
    if layer.x >= MIN_WINDOW_SIZE.x + SCREEN_MARGIN * 2 then
        window_w = math.max(MIN_WINDOW_SIZE.x, window_w)
    end
    if layer.y >= MIN_WINDOW_SIZE.y + SCREEN_MARGIN * 2 then
        window_h = math.max(MIN_WINDOW_SIZE.y, window_h)
    end

    local content_w = math.max(1, window_w - 16)
    local content_h = math.max(1, window_h - 16)
    local gap = 6
    local palette_w = clamp(math.floor(content_w * 0.19), 110, 145)
    local right_w = clamp(math.floor(content_w * 0.31), 180, 245)
    local recipe_w = content_w - palette_w - right_w - gap * 2
    if recipe_w < 220 then
        right_w = math.max(160, right_w - (220 - recipe_w))
        recipe_w = content_w - palette_w - right_w - gap * 2
    end
    if recipe_w < 200 then
        palette_w = math.max(100, palette_w - (200 - recipe_w))
        recipe_w = content_w - palette_w - right_w - gap * 2
    end
    recipe_w = math.max(170, recipe_w)

    local banner_h = 60
    local status_h = 26
    local action_h = 30
    local main_h = math.max(240, content_h - banner_h - status_h - action_h - gap * 3)
    local effects_h = clamp(math.floor(main_h * 0.30), 110, 132)
    local operators_h = math.max(140, main_h - effects_h - gap)
    local saved_h = clamp(math.floor(main_h * 0.28), 100, 140)
    local preview_h = clamp(math.floor(main_h * 0.26), 100, 130)
    local editor_h = math.max(130, main_h - saved_h - preview_h - gap * 2)

    return {
        screen = screen,
        layer = layer,
        size_source = size_source,
        window = v2(window_w, window_h),
        gap = gap,
        content_w = content_w,
        content_h = content_h,
        banner_h = banner_h,
        main_h = main_h,
        status_h = status_h,
        action_h = action_h,
        palette_w = palette_w,
        palette_button_w = math.max(72, palette_w - 24),
        effects_h = effects_h,
        operators_h = operators_h,
        recipe_w = recipe_w,
        recipe_button_w = math.max(140, recipe_w - 56),
        recipe_list_h = math.max(140, main_h - 80),
        right_w = right_w,
        right_button_w = math.max(110, right_w - 34),
        saved_h = saved_h,
        editor_h = editor_h,
        preview_h = preview_h,
        title_w = math.max(140, math.min(260, content_w - 320)),
        field_label_w = right_w < 200 and 56 or 70,
        field_input_w = math.max(74, math.min(140, right_w - 96)),
        number_w = right_w < 200 and 50 or 60,
        preview_text_w = math.max(140, right_w - 40),
        preview_text_h = math.max(60, preview_h - 48),
    }
end

local function safePosition(layer_size, window_size)
    local max_x = math.max(0, layer_size.x - window_size.x - SCREEN_MARGIN)
    local max_y = math.max(0, layer_size.y - window_size.y - SCREEN_MARGIN)
    return v2(math.min(SCREEN_MARGIN, max_x), math.min(SCREEN_MARGIN, max_y))
end

local function destroyRoot()
    if state.root then
        state.root:destroy()
        state.root = nil
    end
end

local function textLayout(text, opts)
    local options = opts or {}
    local props = {
        text = tostring(text or ""),
        textSize = options.size or nil,
        textColor = options.color or nil,
        size = options.box_size or nil,
    }
    return {
        template = template(options.header and "textHeader" or "textNormal"),
        type = openmw_ui.TYPE.Text,
        props = props,
        external = options.external,
    }
end

local function paragraph(text, size, opts)
    local options = opts or {}
    return {
        template = template("textParagraph"),
        type = openmw_ui.TYPE.TextEdit,
        props = {
            text = tostring(text or ""),
            size = size or v2(180, 60),
            textColor = options.color or nil,
            readOnly = true,
            multiline = true,
            wordWrap = true,
        },
    }
end

local function spacer(width, height)
    return {
        type = openmw_ui.TYPE.Widget,
        props = {
            size = v2(width or 0, height or 0),
        },
    }
end

local function row(children, opts)
    local options = opts or {}
    return {
        type = openmw_ui.TYPE.Flex,
        props = {
            horizontal = true,
            arrange = options.arrange or openmw_ui.ALIGNMENT.Start,
            align = options.align,
            size = options.size,
        },
        external = options.external,
        content = openmw_ui.content(children or {}),
    }
end

local function column(children, opts)
    local options = opts or {}
    return {
        type = openmw_ui.TYPE.Flex,
        props = {
            horizontal = false,
            arrange = options.arrange or openmw_ui.ALIGNMENT.Start,
            align = options.align,
            size = options.size,
        },
        external = options.external,
        content = openmw_ui.content(children or {}),
    }
end

local render

local function padded(layout)
    return {
        template = template("padding"),
        content = openmw_ui.content { layout },
    }
end

local function button(label, callback, opts)
    local options = opts or {}
    local width = options.width or 86
    local height = options.height or 24
    local prefix = options.bullet and (options.bullet .. " ") or ""
    local label_text = prefix .. tostring(label)
    return {
        template = template(options.disabled and "boxTransparent" or "box"),
        props = {
            size = options.size or v2(width, height),
        },
        events = options.disabled and nil or {
            mouseClick = async:callback(function()
                callback()
            end),
        },
        content = openmw_ui.content {
            padded(textLayout(label_text, {
                box_size = v2(width - 8, 0),
                color = options.color,
                size = options.text_size,
            })),
        },
    }
end

local function sectionHeader(title)
    return textLayout(title, { header = true, color = COLOR.section })
end

local function section(title, body, size)
    return {
        template = template("box"),
        props = {
            size = size,
        },
        content = openmw_ui.content {
            padded(column({
                sectionHeader(title),
                spacer(0, 4),
                body,
            })),
        },
    }
end

local function textInput(value, onChange, opts)
    local options = opts or {}
    local current = tostring(value or "")
    local function eventText(value)
        if type(value) == "table" then
            if value.text ~= nil then
                return tostring(value.text)
            end
            if value.value ~= nil then
                return tostring(value.value)
            end
            if type(value.props) == "table" and value.props.text ~= nil then
                return tostring(value.props.text)
            end
        end
        return tostring(value or "")
    end
    return {
        template = template("textEditLine"),
        type = openmw_ui.TYPE.TextEdit,
        props = {
            text = current,
            size = options.size or v2(options.width or 140, 0),
            textColor = options.color or nil,
            multiline = false,
        },
        events = {
            textChanged = async:callback(function(text)
                current = eventText(text)
                onChange(current)
            end),
        },
    }
end

local function numberInput(value, onChange, opts)
    local options = opts or {}
    local current = tostring(value or 0)
    local function eventText(value)
        if type(value) == "table" then
            if value.text ~= nil then
                return tostring(value.text)
            end
            if value.value ~= nil then
                return tostring(value.value)
            end
            if type(value.props) == "table" and value.props.text ~= nil then
                return tostring(value.props.text)
            end
        end
        return tostring(value or "")
    end
    local function commit()
        local n = tonumber(current)
        if n ~= nil then
            onChange(n)
            return true
        end
        return false
    end
    return {
        template = template("textEditLine"),
        type = openmw_ui.TYPE.TextEdit,
        props = {
            text = current,
            size = options.size or v2(options.width or 54, 0),
            multiline = false,
        },
        events = {
            textChanged = async:callback(function(text)
                current = eventText(text)
                commit()
            end),
            focusLoss = async:callback(function(text)
                if text ~= nil then
                    current = eventText(text)
                end
                commit()
                render()
            end),
        },
    }
end

local function rangeName(range)
    return RANGE_LABELS[tonumber(range) or 0] or tostring(range)
end

local function operatorEffectId(opcode)
    for _, entry in ipairs(state.catalog and state.catalog.operator_effect_ids or {}) do
        if entry.opcode == opcode then
            return entry.effect_id
        end
    end
    return nil
end

local function opcodeForEffect(effect)
    if not effect then
        return nil
    end
    local by_effect = state.catalog and state.catalog.operator_opcode_by_effect_id or {}
    return by_effect[effect.id]
end

local function operatorKind(opcode)
    local def = state.catalog and state.catalog.operators_by_opcode and state.catalog.operators_by_opcode[opcode]
    return def and def.kind or nil
end

local function operatorDisplayName(opcode)
    local def = state.catalog and state.catalog.operators_by_opcode and state.catalog.operators_by_opcode[opcode]
    return (def and def.display_name) or opcode
end

local function operatorDescription(opcode)
    local def = state.catalog and state.catalog.operators_by_opcode and state.catalog.operators_by_opcode[opcode]
    return def and def.description or nil
end

local function colorForOpcode(opcode)
    local kind = operatorKind(opcode)
    if kind == "scope_opener" then
        return COLOR.op_scope
    end
    return COLOR.op_modifier
end

local function colorForEffectId(effect_id)
    local id = string.lower(tostring(effect_id or ""))
    if id == "" then
        return COLOR.text
    end
    if string.find(id, "fire", 1, true) then return COLOR.fire end
    if string.find(id, "frost", 1, true) then return COLOR.frost end
    if string.find(id, "shock", 1, true) or string.find(id, "lightning", 1, true) then return COLOR.shock end
    if string.find(id, "poison", 1, true) then return COLOR.poison end
    if string.find(id, "shield", 1, true) then return COLOR.shield end
    if string.find(id, "restore", 1, true) or string.find(id, "heal", 1, true) then return COLOR.restore end
    if string.find(id, "drain", 1, true) or string.find(id, "absorb", 1, true) then return COLOR.drain end
    return COLOR.text
end

local function colorForEffect(effect)
    local opcode = opcodeForEffect(effect)
    if opcode then
        return colorForOpcode(opcode)
    end
    return colorForEffectId(effect and effect.id)
end

local function defaultOperatorParams(opcode)
    local def = state.catalog and state.catalog.operators_by_opcode and state.catalog.operators_by_opcode[opcode]
    local out = {}
    if def and type(def.parameters) == "table" then
        for name, spec in pairs(def.parameters) do
            if type(spec) == "table" and spec.default ~= nil then
                out[name] = spec.default
            end
        end
    end
    if next(out) ~= nil then
        return out
    end
    return cloneValue(DEFAULT_OPERATOR_PARAMS[opcode] or {}, 0)
end

local function operatorParamDefault(opcode, name, fallback)
    local defaults = defaultOperatorParams(opcode)
    if defaults[name] ~= nil then
        return defaults[name]
    end
    return fallback
end

local function mergedOperatorParams(opcode, params)
    local out = defaultOperatorParams(opcode)
    if type(params) == "table" then
        for key, value in pairs(params) do
            out[key] = value
        end
    end
    return out
end

local function normalizedParamsForEffect(effect, opcode)
    if opcode then
        return mergedOperatorParams(opcode, operator_params.paramsForEffect(effect, opcode))
    end
    if type(effect and effect.params) == "table" then
        return cloneValue(effect.params, 0)
    end
    return nil
end

local function sanitizeEffect(effect, index)
    if type(effect) ~= "table" then
        return nil
    end
    local out = cloneValue(effect, 0)
    if type(out.id) ~= "string" or out.id == "" then
        out.id = "unknown"
    end
    if out.ui_id == nil or out.ui_id == "" then
        out.ui_id = string.format("effect:%s", tostring(index or 1))
    end

    local opcode = opcodeForEffect(out)
    out.params = normalizedParamsForEffect(out, opcode)
    return operator_params.mirrorEffect(out)
end

local function sanitizeEffects(effects)
    local out = {}
    for index, effect in ipairs(effects or {}) do
        local sanitized = sanitizeEffect(effect, index)
        if sanitized then
            out[#out + 1] = sanitized
        end
    end
    return out
end

local function paramsSummary(params)
    if type(params) ~= "table" then
        return ""
    end
    local parts = {}
    for key, value in pairs(params) do
        parts[#parts + 1] = string.format("%s=%s", tostring(key), tostring(value))
    end
    if #parts == 0 then
        return ""
    end
    table.sort(parts)
    return table.concat(parts, GLYPHS.sub_sep)
end

local function operatorSummary(effects)
    local parts = {}
    for _, effect in ipairs(effects or {}) do
        local opcode = opcodeForEffect(effect)
        if opcode then
            local summary = paramsSummary(operator_params.paramsForEffect(effect, opcode))
            if summary ~= "" then
                parts[#parts + 1] = string.format("%s(%s)", opcode, summary)
            else
                parts[#parts + 1] = tostring(opcode)
            end
        end
    end
    if #parts == 0 then
        return "none"
    end
    return table.concat(parts, ",")
end

local function effectLabel(effect, index)
    local opcode = opcodeForEffect(effect)
    local prefix = string.format("%d.", index)
    if opcode then
        local summary = paramsSummary(operator_params.paramsForEffect(effect, opcode))
        local name = operatorDisplayName(opcode)
        if summary ~= "" then
            return string.format("%s %s (%s)", prefix, name, summary)
        end
        return string.format("%s %s", prefix, name)
    end
    local mag_min = tonumber(effect and effect.magnitudeMin) or 0
    local mag_max = tonumber(effect and effect.magnitudeMax) or 0
    local mag = (mag_min == mag_max) and tostring(mag_min) or string.format("%s-%s", tostring(mag_min), tostring(mag_max))
    local duration = tonumber(effect and effect.duration) or 0
    local segments = {
        tostring(effect and effect.id or "?"),
        rangeName(effect and effect.range),
        mag,
        string.format("%ss", tostring(duration)),
    }
    return string.format("%s %s", prefix, table.concat(segments, GLYPHS.sep))
end

local function currentRecipe()
    return {
        title = state.title,
        effects = sanitizeEffects(state.effects),
    }
end

local function selectedEffect()
    if type(state.selected_index) ~= "number" then
        return nil
    end
    return state.effects[state.selected_index]
end

local function setStatus(text, kind)
    state.status = tostring(text or "")
    state.status_kind = kind or "info"
end

local function markRecipeChanged()
    state.recipe_generation = (state.recipe_generation or 0) + 1
    state.preview = nil
    state.last_validation = nil
end

local function requestStillCurrent(generation)
    return state.visible == true and generation == state.recipe_generation
end

local function firstErrorMessage(result, fallback)
    local first = result and result.errors and result.errors[1]
    return first and first.message or fallback or "Request failed."
end

local function previewDeferredReasons(preview)
    local matrix = preview and (preview.feature_matrix or preview.support) or {}
    if type(matrix.deferred_reasons) == "table" then
        return matrix.deferred_reasons
    end
    return {}
end

local function previewIsDeferred(preview)
    local matrix = preview and (preview.feature_matrix or preview.support) or {}
    return matrix.live_runtime_status == "deferred" or #previewDeferredReasons(preview) > 0
end

local function previewDeferredSummary(preview)
    local reasons = previewDeferredReasons(preview)
    if #reasons > 0 then
        return table.concat(reasons, ", ")
    end
    return "runtime combo deferred"
end

local function statusColor(kind)
    if kind == "success" then return COLOR.success end
    if kind == "error" then return COLOR.error end
    if kind == "warning" then return COLOR.warning end
    return COLOR.info
end

local function statusPrefix(kind)
    if kind == "success" then return "[OK]" end
    if kind == "error" then return "[!!]" end
    if kind == "warning" then return "[!]" end
    return "[i]"
end

local function addEffect(effect)
    state.effects[#state.effects + 1] = cloneValue(effect, 0)
    state.selected_index = #state.effects
    markRecipeChanged()
    setStatus(string.format("Added effect (%d total).", #state.effects), "info")
    render()
end

local function addOperator(opcode)
    local effect_id = operatorEffectId(opcode)
    if not effect_id then
        setStatus("Catalog does not expose " .. tostring(opcode) .. ".", "error")
        render()
        return
    end
    state.effects[#state.effects + 1] = cloneValue({
        id = effect_id,
        params = defaultOperatorParams(opcode),
    }, 0)
    state.selected_index = #state.effects
    markRecipeChanged()
    setStatus(string.format("Added %s operator.", operatorDisplayName(opcode)), "info")
    render()
end

local function moveSelected(delta)
    local i = state.selected_index
    local j = i and (i + delta) or nil
    if not i or not j or j < 1 or j > #state.effects then
        return
    end
    state.effects[i], state.effects[j] = state.effects[j], state.effects[i]
    state.selected_index = j
    markRecipeChanged()
    render()
end

local function removeSelected()
    local i = state.selected_index
    if not i or not state.effects[i] then
        return
    end
    table.remove(state.effects, i)
    if #state.effects == 0 then
        state.selected_index = nil
    elseif i > #state.effects then
        state.selected_index = #state.effects
    end
    markRecipeChanged()
    setStatus("Removed effect.", "info")
    render()
end

local function newRecipe()
    state.title = DEFAULT_TITLE
    state.effects = {}
    state.selected_index = nil
    state.selected_saved_id = nil
    markRecipeChanged()
    setStatus("New recipe started.", "info")
    render()
end

local function loadSaved(saved)
    state.title = saved.title or saved.name or DEFAULT_TITLE
    state.effects = sanitizeEffects(saved.recipe and saved.recipe.effects or {})
    state.selected_index = #state.effects > 0 and 1 or nil
    state.selected_saved_id = saved.id
    markRecipeChanged()
    setStatus("Loaded \"" .. tostring(saved.title or saved.id) .. "\".", "info")
    log.info(string.format(
        "SPELLFORGE_SPELLCRAFT_UI_LOAD_OK saved_id=%s effects=%s",
        tostring(saved.id),
        tostring(#state.effects)
    ))
    render()
end

local function saveRecipe()
    local recipe = currentRecipe()
    local payload = {
        title = state.title,
        recipe = recipe,
    }
    local result
    if state.selected_saved_id then
        result = ui_api.updateRecipe(state.selected_saved_id, payload)
    else
        result = ui_api.saveRecipe(payload)
    end
    if result and result.ok then
        state.selected_saved_id = result.saved_recipe and result.saved_recipe.id or state.selected_saved_id
        setStatus("Saved draft \"" .. tostring(result.saved_recipe and result.saved_recipe.title or state.title) .. "\".", "success")
        local saved_recipe = result.saved_recipe and result.saved_recipe.recipe or recipe
        if saved_recipe and type(saved_recipe.effects) == "table" then
            state.effects = sanitizeEffects(saved_recipe.effects)
            if type(state.selected_index) == "number" and state.selected_index > #state.effects then
                state.selected_index = #state.effects > 0 and #state.effects or nil
            end
        end
        log.info(string.format(
            "SPELLFORGE_SPELLCRAFT_UI_SAVE_OK saved_id=%s effects=%s ops=%s",
            tostring(state.selected_saved_id),
            tostring(saved_recipe.effects and #saved_recipe.effects or 0),
            operatorSummary(saved_recipe.effects)
        ))
    else
        local first = result and result.errors and result.errors[1]
        setStatus(first and first.message or "Save failed.", "error")
        log.warn(string.format(
            "SPELLFORGE_SPELLCRAFT_UI_SAVE_FAILED reason=%s",
            tostring(first and first.message or "unknown")
        ))
    end
    render()
    return result
end

local function deleteSaved()
    if not state.selected_saved_id then
        setStatus("No saved recipe selected.", "info")
        render()
        return
    end
    local deleted_id = state.selected_saved_id
    local result = ui_api.deleteRecipe(state.selected_saved_id)
    if result and result.ok then
        state.title = DEFAULT_TITLE
        state.effects = {}
        state.selected_index = nil
        state.selected_saved_id = nil
        markRecipeChanged()
        setStatus("Deleted saved recipe.", "success")
        log.info(string.format("SPELLFORGE_SPELLCRAFT_UI_DELETE_OK saved_id=%s", tostring(deleted_id)))
        render()
    else
        local first = result and result.errors and result.errors[1]
        setStatus(first and first.message or "Delete failed.", "error")
        log.warn(string.format("SPELLFORGE_SPELLCRAFT_UI_DELETE_FAILED saved_id=%s", tostring(deleted_id)))
        render()
    end
end

local function validateRecipe()
    local generation = state.recipe_generation
    local saved_id = state.selected_saved_id
    if saved_id then
        local saved = saveRecipe()
        if not saved or not saved.ok then
            return
        end
        generation = state.recipe_generation
    end
    setStatus("Validating recipe...", "info")
    render()
    local function onValidated(result)
        if not requestStillCurrent(generation) then
            return
        end
        state.last_validation = result
        if result and result.ok == true then
            setStatus("Valid recipe (id " .. tostring(result.recipe_id) .. ").", "success")
            log.info(string.format(
                "SPELLFORGE_SPELLCRAFT_UI_VALIDATE_OK recipe_id=%s ops=%s",
                tostring(result.recipe_id),
                operatorSummary(result.effects)
            ))
        else
            local first = result and result.errors and result.errors[1]
            setStatus(first and first.message or "Validation failed.", "error")
            log.warn(string.format(
                "SPELLFORGE_SPELLCRAFT_UI_VALIDATE_FAILED reason=%s",
                tostring(first and first.message or "unknown")
            ))
        end
        render()
    end
    if saved_id then
        ui_api.validateSavedRecipe(saved_id, onValidated)
    else
        ui_api.validateRecipe(currentRecipe(), onValidated)
    end
end

local function previewRecipe()
    local generation = state.recipe_generation
    local saved_id = state.selected_saved_id
    if saved_id then
        local saved = saveRecipe()
        if not saved or not saved.ok then
            return
        end
        generation = state.recipe_generation
    end
    setStatus("Previewing recipe...", "info")
    render()
    local function onPreviewed(result)
        if not requestStillCurrent(generation) then
            return
        end
        if result and result.ok == true then
            state.preview = result.preview
            if previewIsDeferred(state.preview) then
                setStatus("Preview deferred: " .. previewDeferredSummary(state.preview), "warning")
            else
                setStatus(string.format("Preview ready: %s slots.", tostring(state.preview and state.preview.slot_count or 0)), "success")
            end
            log.info(string.format(
                "SPELLFORGE_SPELLCRAFT_UI_PREVIEW_OK recipe_id=%s groups=%s slots=%s helpers=%s ops=%s",
                tostring(result.recipe_id),
                tostring(state.preview and state.preview.group_count),
                tostring(state.preview and state.preview.slot_count),
                tostring(state.preview and state.preview.helper_spec_count),
                operatorSummary(result.effects)
            ))
        else
            state.preview = nil
            local first = result and result.errors and result.errors[1]
            setStatus(first and first.message or "Preview failed.", "error")
            log.warn(string.format(
                "SPELLFORGE_SPELLCRAFT_UI_PREVIEW_FAILED reason=%s",
                tostring(first and first.message or "unknown")
            ))
        end
        render()
    end
    if saved_id then
        ui_api.previewSavedRecipe(saved_id, onPreviewed)
    else
        ui_api.previewRecipe(currentRecipe(), onPreviewed)
    end
end

local function compileRecipe()
    local saved = saveRecipe()
    if not saved or not saved.ok or not state.selected_saved_id then
        return
    end
    local saved_id = state.selected_saved_id
    local generation = state.recipe_generation
    setStatus("Creating spell...", "info")
    render()
    ui_api.validateSavedRecipe(saved_id, function(validate_result)
        if not requestStillCurrent(generation) then
            return
        end
        if not validate_result or validate_result.ok ~= true then
            setStatus(firstErrorMessage(validate_result, "Validation failed before compile."), "error")
            render()
            return
        end
        ui_api.previewSavedRecipe(saved_id, function(preview_result)
            if not requestStillCurrent(generation) then
                return
            end
            if not preview_result or preview_result.ok ~= true then
                setStatus(firstErrorMessage(preview_result, "Preview failed before compile."), "error")
                render()
                return
            end
            state.preview = preview_result.preview
            if previewIsDeferred(state.preview) then
                local reason_summary = previewDeferredSummary(state.preview)
                setStatus("Create blocked: " .. reason_summary .. ".", "warning")
                log.warn(string.format(
                    "SPELLFORGE_SPELLCRAFT_UI_COMPILE_DEFERRED saved_id=%s recipe_id=%s reason=%s",
                    tostring(saved_id),
                    tostring(preview_result.recipe_id),
                    reason_summary
                ))
                render()
                return
            end
            local queued = ui_api.requestCompileSavedRecipe(saved_id, function(compile_result)
                if not requestStillCurrent(generation) then
                    return
                end
                if compile_result and compile_result.ok == true then
                    setStatus("Created spell \"" .. tostring(state.title) .. "\".", "success")
                    log.info(string.format(
                        "SPELLFORGE_SPELLCRAFT_UI_COMPILE_OK saved_id=%s recipe_id=%s spell_id=%s slots=%s helpers=%s ops=%s",
                        tostring(saved_id),
                        tostring(compile_result.recipe_id),
                        tostring(compile_result.spell_id),
                        tostring(preview_result.preview and preview_result.preview.slot_count),
                        tostring(preview_result.preview and preview_result.preview.helper_spec_count),
                        operatorSummary(preview_result and preview_result.effects)
                    ))
                else
                    setStatus(firstErrorMessage(compile_result, "Create failed."), "error")
                    log.warn(string.format(
                        "SPELLFORGE_SPELLCRAFT_UI_COMPILE_FAILED saved_id=%s reason=%s",
                        tostring(saved_id),
                        firstErrorMessage(compile_result, "unknown")
                    ))
                end
                render()
            end)
            if not queued or not queued.ok then
                setStatus(firstErrorMessage(queued, "Create request failed."), "error")
                render()
            end
        end)
    end)
end

local function operatorPalette(m)
    local items = {}
    for _, entry in ipairs(state.catalog and state.catalog.operators or {}) do
        local label = entry.display_name or entry.opcode
        items[#items + 1] = button(label, function()
            addOperator(entry.opcode)
        end, {
            width = m.palette_button_w,
            color = colorForOpcode(entry.opcode),
        })
        items[#items + 1] = spacer(0, 2)
    end
    if #items == 0 then
        items[#items + 1] = paragraph("Catalog loading...", v2(math.max(76, m.palette_w - 28), 48), { color = COLOR.muted })
    end
    return section("Operators", column(items), v2(m.palette_w, m.operators_h))
end

local function effectPalette(m)
    local items = {}
    for _, entry in ipairs(BASE_EFFECTS) do
        items[#items + 1] = button(entry.label, function()
            addEffect(entry.effect)
        end, {
            width = m.palette_button_w,
            color = colorForEffectId(entry.effect.id),
        })
        items[#items + 1] = spacer(0, 2)
    end
    return section("Effects", column(items), v2(m.palette_w, m.effects_h))
end

local function recipeStack(m)
    local items = {}
    if #state.effects == 0 then
        items[#items + 1] = paragraph(
            "Empty recipe. Click an effect or operator on the left to add it.",
            v2(math.max(120, m.recipe_w - 36), 56),
            { color = COLOR.muted }
        )
    else
        for i, effect in ipairs(state.effects) do
            local selected = i == state.selected_index
            local color = selected and COLOR.selected or colorForEffect(effect)
            local label = shortText(effectLabel(effect, i), math.max(28, math.floor(m.recipe_button_w / 6)))
            items[#items + 1] = row({
                textLayout(selected and GLYPHS.cursor or GLYPHS.blank, {
                    color = COLOR.selected,
                    box_size = v2(22, 0),
                }),
                button(label, function()
                    state.selected_index = i
                    render()
                end, {
                    width = math.max(120, m.recipe_button_w - 24),
                    color = color,
                }),
            })
            items[#items + 1] = spacer(0, 2)
        end
    end

    local controls = row({
        button("Up", function() moveSelected(-1) end, { width = 44, color = COLOR.accent }),
        spacer(4, 0),
        button("Down", function() moveSelected(1) end, { width = 50, color = COLOR.accent }),
        spacer(4, 0),
        button("Remove", removeSelected, { width = 64, color = COLOR.error }),
        spacer(4, 0),
        button("New", newRecipe, { width = 50, color = COLOR.muted }),
    })

    return section("Spell Recipe", column({
        column(items, { size = v2(math.max(120, m.recipe_w - 26), m.recipe_list_h) }),
        spacer(0, 4),
        controls,
    }), v2(m.recipe_w, m.main_h))
end

local function rangeButtons(effect, m)
    local self_w = m.right_w < 200 and 44 or 52
    local touch_w = m.right_w < 200 and 50 or 58
    local target_w = m.right_w < 200 and 56 or 64
    local current = tonumber(effect.range) or 0
    local function tab(label, range_value, width)
        local active = current == range_value
        return button(label, function()
            if effect.range == range_value then
                return
            end
            effect.range = range_value
            markRecipeChanged()
            render()
        end, {
            width = width,
            color = active and COLOR.selected or COLOR.muted,
            bullet = active and GLYPHS.bullet or nil,
        })
    end
    return row({
        tab("Self", 0, self_w),
        spacer(4, 0),
        tab("Touch", 1, touch_w),
        spacer(4, 0),
        tab("Target", 2, target_w),
    })
end

local function fieldLine(label, editor, m)
    return row({
        textLayout(label, { box_size = v2(m.field_label_w, 0), color = COLOR.muted }),
        spacer(4, 0),
        editor,
    })
end

local function selectedEditor(m)
    local effect = selectedEffect()
    if not effect then
        return section("Selected Effect", paragraph(
            "Select an entry from the Spell Recipe to edit its parameters.",
            v2(math.max(130, m.right_w - 38), math.max(50, m.editor_h - 56)),
            { color = COLOR.muted }
        ), v2(m.right_w, m.editor_h))
    end

    local opcode = opcodeForEffect(effect)
    local color = colorForEffect(effect)
    local heading
    if opcode then
        local kind = operatorKind(opcode) or "operator"
        heading = row({
            textLayout(GLYPHS.bullet .. " " .. operatorDisplayName(opcode), { color = color }),
            spacer(6, 0),
            textLayout("[" .. kind .. "]", { color = COLOR.muted }),
        })
    else
        heading = textLayout(GLYPHS.bullet .. " " .. tostring(effect.id), { color = color })
    end

    local lines = {
        heading,
        spacer(0, 4),
        fieldLine("ID", textInput(effect.id, function(value)
            if effect.id == value then
                return
            end
            effect.id = value
            markRecipeChanged()
        end, { width = m.field_input_w }), m),
        spacer(0, 4),
    }

    if opcode then
        local description = operatorDescription(opcode)
        if description then
            lines[#lines + 1] = paragraph(description, v2(math.max(130, m.right_w - 38), 36), { color = COLOR.muted })
            lines[#lines + 1] = spacer(0, 4)
        end
        local params = normalizedParamsForEffect(effect, opcode) or {}
        effect.params = params
        local param_defs = state.catalog and state.catalog.operators_by_opcode and state.catalog.operators_by_opcode[opcode]
        local names = {}
        for name in pairs(param_defs and param_defs.parameters or params) do
            names[#names + 1] = name
        end
        table.sort(names)
        if #names == 0 then
            lines[#lines + 1] = textLayout("No parameters.", { color = COLOR.muted })
        end
        for _, name in ipairs(names) do
            if params[name] == nil then
                params[name] = operatorParamDefault(opcode, name, 1)
            end
            lines[#lines + 1] = fieldLine(name, numberInput(params[name], function(value)
                if params[name] == value then
                    return
                end
                params[name] = value
                markRecipeChanged()
            end, { width = m.number_w }), m)
            lines[#lines + 1] = spacer(0, 3)
        end
    else
        lines[#lines + 1] = textLayout("Range", { color = COLOR.muted })
        lines[#lines + 1] = spacer(0, 2)
        lines[#lines + 1] = rangeButtons(effect, m)
        lines[#lines + 1] = spacer(0, 4)
        lines[#lines + 1] = fieldLine("Min", numberInput(effect.magnitudeMin or 0, function(value)
            if effect.magnitudeMin == value then
                return
            end
            effect.magnitudeMin = value
            markRecipeChanged()
        end, { width = m.number_w }), m)
        lines[#lines + 1] = spacer(0, 3)
        lines[#lines + 1] = fieldLine("Max", numberInput(effect.magnitudeMax or 0, function(value)
            if effect.magnitudeMax == value then
                return
            end
            effect.magnitudeMax = value
            markRecipeChanged()
        end, { width = m.number_w }), m)
        lines[#lines + 1] = spacer(0, 3)
        lines[#lines + 1] = fieldLine("Area", numberInput(effect.area or 0, function(value)
            if effect.area == value then
                return
            end
            effect.area = value
            markRecipeChanged()
        end, { width = m.number_w }), m)
        lines[#lines + 1] = spacer(0, 3)
        lines[#lines + 1] = fieldLine("Duration", numberInput(effect.duration or 0, function(value)
            if effect.duration == value then
                return
            end
            effect.duration = value
            markRecipeChanged()
        end, { width = m.number_w }), m)
    end

    return section("Selected Effect", column(lines), v2(m.right_w, m.editor_h))
end

local function savedRecipes(m)
    local rows = {}
    local saved = ui_api.getSavedRecipes() or {}
    for i, entry in ipairs(saved) do
        if i > 5 then
            break
        end
        local active = entry.id == state.selected_saved_id
        local label = shortText(entry.title or entry.id, math.max(20, math.floor(m.right_button_w / 6)))
        rows[#rows + 1] = button(label, function()
            loadSaved(entry)
        end, {
            width = m.right_button_w,
            color = active and COLOR.selected or COLOR.text,
            bullet = active and GLYPHS.cursor or GLYPHS.bullet,
        })
        rows[#rows + 1] = spacer(0, 2)
    end
    if #rows == 0 then
        rows[#rows + 1] = paragraph(
            "No saved recipes yet. Click Save to keep the current one.",
            v2(math.max(110, m.right_w - 38), 44),
            { color = COLOR.muted }
        )
    elseif #saved > 5 then
        rows[#rows + 1] = textLayout(string.format("(+%d more)", #saved - 5), { color = COLOR.muted })
    end
    return section("Saved Recipes", column(rows), v2(m.right_w, m.saved_h))
end

local function previewLines(preview)
    local lines = {}
    if not preview or next(preview) == nil then
        return {
            { text = "No preview yet. Press Preview to compute one.", color = COLOR.muted },
        }
    end
    if preview.recipe_id then
        lines[#lines + 1] = { text = "Recipe id  : " .. tostring(preview.recipe_id), color = COLOR.text }
    end
    local has_counts = preview.group_count or preview.slot_count or preview.helper_spec_count
    if has_counts then
        lines[#lines + 1] = {
            text = string.format(
                "Groups: %s   Slots: %s   Helpers: %s",
                tostring(preview.group_count or 0),
                tostring(preview.slot_count or 0),
                tostring(preview.helper_spec_count or 0)
            ),
            color = COLOR.text,
        }
    end
    local matrix = preview.feature_matrix or {}
    if matrix.live_runtime_status then
        local rstatus = tostring(matrix.live_runtime_status)
        local rcolor = COLOR.text
        if rstatus == "ready" or rstatus == "ok" or rstatus == "live" then rcolor = COLOR.success
        elseif rstatus == "deferred" then rcolor = COLOR.warning
        elseif rstatus == "blocked" or rstatus == "error" then rcolor = COLOR.error
        end
        lines[#lines + 1] = { text = "Runtime    : " .. rstatus, color = rcolor }
    end
    if matrix.deferred_reasons and #matrix.deferred_reasons > 0 then
        lines[#lines + 1] = { text = "Deferred   : " .. table.concat(matrix.deferred_reasons, ", "), color = COLOR.warning }
    end
    return lines
end

local function previewPanel(m)
    local lines = previewLines(state.preview)
    local children = {}
    for i, line in ipairs(lines) do
        children[#children + 1] = textLayout(line.text, { color = line.color, box_size = v2(m.preview_text_w, 0) })
        if i < #lines then
            children[#children + 1] = spacer(0, 2)
        end
    end
    return section("Preview", column(children, { size = v2(m.preview_text_w, m.preview_text_h) }), v2(m.right_w, m.preview_h))
end

local function titleEditor(m)
    return row({
        textLayout("Name", { color = COLOR.muted }),
        spacer(8, 0),
        textInput(state.title, function(value)
            if state.title == value then
                return
            end
            state.title = value
            markRecipeChanged()
        end, { width = m.title_w, color = COLOR.selected }),
    })
end

local function bannerHeader(m)
    return {
        template = template("box"),
        props = {
            size = v2(m.content_w, m.banner_h),
        },
        content = openmw_ui.content {
            padded(column({
                textLayout(BANNER_TITLE, { header = true, size = 22, color = COLOR.title }),
                spacer(0, 2),
                row({
                    textLayout(SUBTITLE, { color = COLOR.subtitle }),
                    spacer(12, 0),
                    titleEditor(m),
                }),
            })),
        },
    }
end

local function statusBar(m)
    local kind = state.status_kind or "info"
    local text = string.format("%s  %s", statusPrefix(kind), state.status or "")
    local saved_label = state.selected_saved_id
        and string.format("Editing: %s", tostring(state.selected_saved_id))
        or "Unsaved draft"
    return {
        template = template("box"),
        props = {
            size = v2(m.content_w, m.status_h),
        },
        content = openmw_ui.content {
            padded(row({
                textLayout(text, { color = statusColor(kind), box_size = v2(math.max(120, m.content_w - 220), 0) }),
                spacer(8, 0),
                textLayout(saved_label, { color = COLOR.muted }),
            })),
        },
    }
end

local function actionButton(label, callback, kind, width)
    local color
    if kind == "primary" then
        color = COLOR.accent
    elseif kind == "danger" then
        color = COLOR.error
    elseif kind == "muted" then
        color = COLOR.muted
    else
        color = COLOR.text
    end
    return button(label, callback, { width = width or 70, height = 26, color = color })
end

local function actionButtons()
    return row({
        actionButton("Save", saveRecipe, "primary", 60),
        spacer(6, 0),
        actionButton("Validate", validateRecipe, "primary", 76),
        spacer(6, 0),
        actionButton("Preview", previewRecipe, "primary", 76),
        spacer(6, 0),
        actionButton("Create", compileRecipe, nil, 70),
        spacer(6, 0),
        actionButton("Delete", deleteSaved, "danger", 64),
        spacer(6, 0),
        actionButton("Close", function()
            spellcrafting_ui.close()
        end, "muted", 60),
    })
end

local function buildLayout()
    local m = layoutMetrics()
    local position = safePosition(m.layer, m.window)
    m.position = position
    state.last_layout = m
    return {
        layer = LAYER_NAME,
        type = openmw_ui.TYPE.Window,
        props = {
            position = position,
            size = m.window,
        },
        content = openmw_ui.content {
            {
                template = template("boxSolid"),
                props = {
                    relativeSize = v2(1, 1),
                    size = v2(0, 0),
                },
                content = openmw_ui.content {
                    padded(column({
                        bannerHeader(m),
                        spacer(0, m.gap),
                        row({
                            column({
                                effectPalette(m),
                                spacer(0, m.gap),
                                operatorPalette(m),
                            }),
                            spacer(m.gap, 0),
                            recipeStack(m),
                            spacer(m.gap, 0),
                            column({
                                selectedEditor(m),
                                spacer(0, m.gap),
                                savedRecipes(m),
                                spacer(0, m.gap),
                                previewPanel(m),
                            }),
                        }, { size = v2(m.content_w, m.main_h) }),
                        spacer(0, m.gap),
                        statusBar(m),
                        spacer(0, m.gap),
                        actionButtons(),
                    })),
                },
            },
        },
    }
end

render = function()
    destroyRoot()
    if not state.visible then
        return
    end
    state.root = openmw_ui.create(buildLayout(), { noWarnUnused = true })
end

local function ensureCatalog()
    if state.catalog then
        return
    end
    ui_api.requestCatalog(function(result)
        if result and result.ok == true then
            state.catalog = result
            setStatus("Catalog loaded.", "success")
            log.info(string.format(
                "SPELLFORGE_SPELLCRAFT_UI_CATALOG_OK operators=%s",
                tostring(result.operators and #result.operators or 0)
            ))
        else
            setStatus("Catalog request failed.", "error")
            log.warn("SPELLFORGE_SPELLCRAFT_UI_CATALOG_FAILED")
        end
        render()
    end)
end

local function addUiMode()
    if state.mode_added then
        return
    end
    local ui_interface = I.UI
    if ui_interface and ui_interface.addMode then
        local mode = ui_interface.MODE and ui_interface.MODE.Interface or "Interface"
        local ok = pcall(ui_interface.addMode, mode, { windows = {} })
        state.mode_added = ok
    end
end

local function removeUiMode()
    if not state.mode_added then
        return
    end
    local ui_interface = I.UI
    if ui_interface and ui_interface.removeMode then
        local mode = ui_interface.MODE and ui_interface.MODE.Interface or "Interface"
        pcall(ui_interface.removeMode, mode)
    end
    state.mode_added = false
end

function spellcrafting_ui.open()
    if state.visible then
        return
    end
    state.visible = true
    addUiMode()
    ensureCatalog()
    render()
    local m = state.last_layout
    log.info(string.format(
        "SPELLFORGE_SPELLCRAFT_UI_OPENED screen=%sx%s layer=%sx%s source=%s window=%sx%s position=%sx%s",
        tostring(m and m.screen and m.screen.x),
        tostring(m and m.screen and m.screen.y),
        tostring(m and m.layer and m.layer.x),
        tostring(m and m.layer and m.layer.y),
        tostring(m and m.size_source),
        tostring(m and m.window and m.window.x),
        tostring(m and m.window and m.window.y),
        tostring(m and m.position and m.position.x),
        tostring(m and m.position and m.position.y)
    ))
end

function spellcrafting_ui.close()
    if not state.visible then
        return
    end
    state.visible = false
    destroyRoot()
    removeUiMode()
    log.info("SPELLFORGE_SPELLCRAFT_UI_CLOSED")
end

function spellcrafting_ui.toggle()
    if state.visible then
        spellcrafting_ui.close()
    else
        spellcrafting_ui.open()
    end
end

function spellcrafting_ui.isVisible()
    return state.visible
end

function spellcrafting_ui.handleKeyPress(key)
    local symbol = key and key.symbol and string.lower(key.symbol) or ""
    if symbol == "y" or (key and key.code == input.KEY.Y) then
        if not (dev.devHotkeysEnabled() or dev.smokeTestsEnabled()) then
            return true
        end
        spellcrafting_ui.toggle()
        return false
    end
    return true
end

return spellcrafting_ui
