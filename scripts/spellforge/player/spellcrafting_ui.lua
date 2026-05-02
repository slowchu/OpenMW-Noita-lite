local async = require("openmw.async")
local input = require("openmw.input")
local I = require("openmw.interfaces")
local openmw_ui = require("openmw.ui")
local util = require("openmw.util")

local dev = require("scripts.spellforge.shared.dev")
local log = require("scripts.spellforge.shared.log").new("player.spellcrafting_ui")
local ui_api = require("scripts.spellforge.player.ui")

local spellcrafting_ui = {}

local v2 = util.vector2

local LAYER_NAME = "Windows"
local MAX_WINDOW_SIZE = v2(760, 520)
local MIN_WINDOW_SIZE = v2(480, 400)
local SCREEN_MARGIN = 8
local DEFAULT_TITLE = "Spellforge Spell"

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
    ["Size+"] = { percent = 50 },
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
    status = "Press Preview or Validate.",
    status_kind = "info",
    preview = nil,
    last_validation = nil,
    last_layout = nil,
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
    if #text > max_len then
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
    local palette_w = clamp(math.floor(content_w * 0.18), 100, 130)
    local right_w = clamp(math.floor(content_w * 0.31), 170, 235)
    local recipe_w = content_w - palette_w - right_w - gap * 2
    if recipe_w < 210 then
        right_w = math.max(150, right_w - (210 - recipe_w))
        recipe_w = content_w - palette_w - right_w - gap * 2
    end
    if recipe_w < 190 then
        palette_w = math.max(90, palette_w - (190 - recipe_w))
        recipe_w = content_w - palette_w - right_w - gap * 2
    end
    recipe_w = math.max(160, recipe_w)

    local top_h = 26
    local action_h = 24
    local main_h = math.max(245, content_h - top_h - action_h - 20)
    local effects_h = clamp(math.floor(main_h * 0.27), 96, 116)
    local operators_h = math.max(120, main_h - effects_h - gap)
    local saved_h = clamp(math.floor(main_h * 0.28), 92, 130)
    local preview_h = clamp(math.floor(main_h * 0.25), 86, 112)
    local editor_h = math.max(112, main_h - saved_h - preview_h - gap * 2)

    return {
        screen = screen,
        layer = layer,
        size_source = size_source,
        window = v2(window_w, window_h),
        gap = gap,
        content_w = content_w,
        content_h = content_h,
        top_h = top_h,
        main_h = main_h,
        action_h = action_h,
        palette_w = palette_w,
        palette_button_w = math.max(72, palette_w - 24),
        effects_h = effects_h,
        operators_h = operators_h,
        recipe_w = recipe_w,
        recipe_button_w = math.max(120, recipe_w - 56),
        recipe_list_h = math.max(120, main_h - 70),
        right_w = right_w,
        right_button_w = math.max(92, right_w - 34),
        saved_h = saved_h,
        editor_h = editor_h,
        preview_h = preview_h,
        title_w = math.max(150, math.min(270, content_w - 160)),
        field_label_w = right_w < 190 and 48 or 62,
        field_input_w = math.max(74, math.min(140, right_w - 88)),
        number_w = right_w < 190 and 44 or 54,
        preview_text_w = math.max(140, right_w - 40),
        preview_text_h = math.max(50, preview_h - 40),
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

local function paragraph(text, size)
    return {
        template = template("textParagraph"),
        type = openmw_ui.TYPE.TextEdit,
        props = {
            text = tostring(text or ""),
            size = size or v2(180, 60),
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
    return {
        template = template(options.disabled and "boxTransparent" or "box"),
        props = {
            size = options.size or v2(options.width or 86, options.height or 24),
        },
        events = options.disabled and nil or {
            mouseClick = async:callback(function()
                callback()
            end),
        },
        content = openmw_ui.content {
            padded(textLayout(label, { box_size = v2((options.width or 86) - 8, 0) })),
        },
    }
end

local function section(title, body, size)
    return {
        template = template("box"),
        props = {
            size = size,
        },
        content = openmw_ui.content {
            padded(column({
                textLayout(title, { header = true }),
                spacer(0, 4),
                body,
            })),
        },
    }
end

local function textInput(value, onChange, opts)
    local options = opts or {}
    local current = tostring(value or "")
    return {
        template = template("textEditLine"),
        type = openmw_ui.TYPE.TextEdit,
        props = {
            text = current,
            size = options.size or v2(options.width or 140, 0),
            multiline = false,
        },
        events = {
            textChanged = async:callback(function(text)
                current = tostring(text or "")
                onChange(current)
            end),
        },
    }
end

local function numberInput(value, onChange, opts)
    local options = opts or {}
    local current = tostring(value or 0)
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
                current = tostring(text or "")
                local n = tonumber(current)
                if n ~= nil then
                    onChange(n)
                end
            end),
            focusLoss = async:callback(function()
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

local function defaultOperatorParams(opcode)
    return cloneValue(DEFAULT_OPERATOR_PARAMS[opcode] or {}, 0)
end

local function normalizedParamsForEffect(effect, opcode)
    if type(effect and effect.params) == "table" then
        return cloneValue(effect.params, 0)
    end
    if opcode then
        return defaultOperatorParams(opcode)
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
    return out
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

local function effectLabel(effect, index)
    local opcode = opcodeForEffect(effect)
    if opcode then
        local params = type(effect.params) == "table" and effect.params or {}
        if next(params) ~= nil then
            local parts = {}
            for key, value in pairs(params) do
                parts[#parts + 1] = string.format("%s=%s", tostring(key), tostring(value))
            end
            table.sort(parts)
            return string.format("%d. %s (%s)", index, opcode, table.concat(parts, ", "))
        end
        return string.format("%d. %s", index, opcode)
    end
    return string.format(
        "%d. %s %s %s-%s %ss",
        index,
        tostring(effect and effect.id or "?"),
        rangeName(effect and effect.range),
        tostring(effect and effect.magnitudeMin or 0),
        tostring(effect and effect.magnitudeMax or 0),
        tostring(effect and effect.duration or 0)
    )
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

local function addEffect(effect)
    state.effects[#state.effects + 1] = cloneValue(effect, 0)
    state.selected_index = #state.effects
    state.preview = nil
    setStatus("Recipe changed.", "info")
    render()
end

local function addOperator(opcode)
    local effect_id = operatorEffectId(opcode)
    if not effect_id then
        setStatus("Catalog does not expose " .. tostring(opcode) .. ".", "error")
        render()
        return
    end
    addEffect({
        id = effect_id,
        params = cloneValue(DEFAULT_OPERATOR_PARAMS[opcode] or {}, 0),
    })
end

local function moveSelected(delta)
    local i = state.selected_index
    local j = i and (i + delta) or nil
    if not i or not j or j < 1 or j > #state.effects then
        return
    end
    state.effects[i], state.effects[j] = state.effects[j], state.effects[i]
    state.selected_index = j
    state.preview = nil
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
    state.preview = nil
    render()
end

local function newRecipe()
    state.title = DEFAULT_TITLE
    state.effects = {}
    state.selected_index = nil
    state.selected_saved_id = nil
    state.preview = nil
    state.last_validation = nil
    setStatus("New recipe.", "info")
    render()
end

local function loadSaved(saved)
    state.title = saved.title or saved.name or DEFAULT_TITLE
    state.effects = sanitizeEffects(saved.recipe and saved.recipe.effects or {})
    state.selected_index = #state.effects > 0 and 1 or nil
    state.selected_saved_id = saved.id
    state.preview = nil
    state.last_validation = nil
    setStatus("Loaded " .. tostring(saved.title or saved.id) .. ".", "info")
    log.info(string.format(
        "SPELLFORGE_SPELLCRAFT_UI_LOAD_OK saved_id=%s effects=%s",
        tostring(saved.id),
        tostring(#state.effects)
    ))
    render()
end

local function saveRecipe()
    local payload = {
        title = state.title,
        recipe = currentRecipe(),
    }
    local result
    if state.selected_saved_id then
        result = ui_api.updateRecipe(state.selected_saved_id, payload)
    else
        result = ui_api.saveRecipe(payload)
    end
    if result and result.ok then
        state.selected_saved_id = result.saved_recipe and result.saved_recipe.id or state.selected_saved_id
        setStatus("Saved " .. tostring(result.saved_recipe and result.saved_recipe.title or state.title) .. ".", "success")
        log.info(string.format(
            "SPELLFORGE_SPELLCRAFT_UI_SAVE_OK saved_id=%s",
            tostring(state.selected_saved_id)
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
        state.preview = nil
        state.last_validation = nil
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
    setStatus("Validating...", "info")
    render()
    ui_api.validateRecipe(currentRecipe(), function(result)
        state.last_validation = result
        if result and result.ok == true then
            setStatus("Valid. recipe_id=" .. tostring(result.recipe_id), "success")
            log.info(string.format("SPELLFORGE_SPELLCRAFT_UI_VALIDATE_OK recipe_id=%s", tostring(result.recipe_id)))
        else
            local first = result and result.errors and result.errors[1]
            setStatus(first and first.message or "Validation failed.", "error")
            log.warn(string.format(
                "SPELLFORGE_SPELLCRAFT_UI_VALIDATE_FAILED reason=%s",
                tostring(first and first.message or "unknown")
            ))
        end
        render()
    end)
end

local function previewRecipe()
    setStatus("Previewing...", "info")
    render()
    ui_api.previewRecipe(currentRecipe(), function(result)
        if result and result.ok == true then
            state.preview = result.preview
            setStatus("Preview ready. recipe_id=" .. tostring(result.recipe_id), "success")
            log.info(string.format(
                "SPELLFORGE_SPELLCRAFT_UI_PREVIEW_OK recipe_id=%s groups=%s slots=%s helpers=%s",
                tostring(result.recipe_id),
                tostring(state.preview and state.preview.group_count),
                tostring(state.preview and state.preview.slot_count),
                tostring(state.preview and state.preview.helper_spec_count)
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
    end)
end

local function compileDeferred()
    local saved = saveRecipe()
    if not saved or not saved.ok or not state.selected_saved_id then
        return
    end
    local result = state.selected_saved_id and ui_api.requestCompileSavedRecipe(state.selected_saved_id) or nil
    local first = result and result.errors and result.errors[1]
    setStatus(first and first.message or "Compile is deferred.", "info")
    log.info(string.format(
        "SPELLFORGE_SPELLCRAFT_UI_COMPILE_DEFERRED saved_id=%s reason=%s",
        tostring(state.selected_saved_id),
        tostring(first and first.message or "deferred")
    ))
    render()
end

local function operatorPalette(m)
    local items = {}
    for _, entry in ipairs(state.catalog and state.catalog.operators or {}) do
        items[#items + 1] = button(entry.display_name or entry.opcode, function()
            addOperator(entry.opcode)
        end, { width = m.palette_button_w })
        items[#items + 1] = spacer(0, 2)
    end
    if #items == 0 then
        items[#items + 1] = paragraph("Catalog loading...", v2(math.max(76, m.palette_w - 28), 48))
    end
    return section("Operators", column(items), v2(m.palette_w, m.operators_h))
end

local function effectPalette(m)
    local items = {}
    for _, entry in ipairs(BASE_EFFECTS) do
        items[#items + 1] = button(entry.label, function()
            addEffect(entry.effect)
        end, { width = m.palette_button_w })
        items[#items + 1] = spacer(0, 2)
    end
    return section("Effects", column(items), v2(m.palette_w, m.effects_h))
end

local function recipeStack(m)
    local items = {}
    if #state.effects == 0 then
        items[#items + 1] = paragraph("No effects yet.", v2(math.max(120, m.recipe_w - 36), 42))
    else
        for i, effect in ipairs(state.effects) do
            local selected = i == state.selected_index
            items[#items + 1] = button(shortText(effectLabel(effect, i), math.max(22, math.floor(m.recipe_button_w / 7))), function()
                state.selected_index = i
                render()
            end, { width = m.recipe_button_w, height = 24, disabled = false })
            if selected then
                items[#items] = row({
                    textLayout(">"),
                    spacer(4, 0),
                    items[#items],
                }, { size = v2(math.max(130, m.recipe_w - 20), 24) })
            end
            items[#items + 1] = spacer(0, 2)
        end
    end

    local controls = row({
        button("Up", function() moveSelected(-1) end, { width = 42 }),
        spacer(4, 0),
        button("Down", function() moveSelected(1) end, { width = 50 }),
        spacer(4, 0),
        button("Remove", removeSelected, { width = 62 }),
        spacer(4, 0),
        button("New", newRecipe, { width = 46 }),
    })

    return section("Spell Recipe", column({
        column(items, { size = v2(math.max(120, m.recipe_w - 26), m.recipe_list_h) }),
        spacer(0, 4),
        controls,
    }), v2(m.recipe_w, m.main_h))
end

local function rangeButtons(effect, m)
    local self_w = m.right_w < 190 and 40 or 48
    local touch_w = m.right_w < 190 and 46 or 54
    local target_w = m.right_w < 190 and 54 or 62
    return row({
        button("Self", function()
            effect.range = 0
            render()
        end, { width = self_w }),
        spacer(4, 0),
        button("Touch", function()
            effect.range = 1
            render()
        end, { width = touch_w }),
        spacer(4, 0),
        button("Target", function()
            effect.range = 2
            render()
        end, { width = target_w }),
    })
end

local function fieldLine(label, editor, m)
    return row({
        textLayout(label, { box_size = v2(m.field_label_w, 0) }),
        spacer(4, 0),
        editor,
    })
end

local function selectedEditor(m)
    local effect = selectedEffect()
    if not effect then
        return section("Selected Effect", paragraph("Select a recipe row to edit it.", v2(math.max(130, m.right_w - 38), math.max(50, m.editor_h - 56))), v2(m.right_w, m.editor_h))
    end

    local opcode = opcodeForEffect(effect)
    local lines = {
        fieldLine("ID", textInput(effect.id, function(value)
            effect.id = value
            state.preview = nil
        end, { width = m.field_input_w }), m),
        spacer(0, 4),
    }

    if opcode then
        lines[#lines + 1] = textLayout("Operator: " .. opcode)
        local params = normalizedParamsForEffect(effect, opcode) or {}
        effect.params = params
        local param_defs = state.catalog and state.catalog.operators_by_opcode and state.catalog.operators_by_opcode[opcode]
        local names = {}
        for name in pairs(param_defs and param_defs.parameters or params) do
            names[#names + 1] = name
        end
        table.sort(names)
        if #names == 0 then
            lines[#lines + 1] = paragraph("No parameters.", v2(math.max(130, m.right_w - 38), 32))
        end
        for _, name in ipairs(names) do
            if params[name] == nil then
                params[name] = (DEFAULT_OPERATOR_PARAMS[opcode] or {})[name] or 1
            end
            lines[#lines + 1] = spacer(0, 4)
            lines[#lines + 1] = fieldLine(name, numberInput(params[name], function(value)
                params[name] = value
                state.preview = nil
            end, { width = m.number_w }), m)
        end
    else
        lines[#lines + 1] = textLayout("Range")
        lines[#lines + 1] = spacer(0, 2)
        lines[#lines + 1] = rangeButtons(effect, m)
        lines[#lines + 1] = spacer(0, 4)
        lines[#lines + 1] = fieldLine("Min", numberInput(effect.magnitudeMin or 0, function(value)
            effect.magnitudeMin = value
            state.preview = nil
        end, { width = m.number_w }), m)
        lines[#lines + 1] = spacer(0, 4)
        lines[#lines + 1] = fieldLine("Max", numberInput(effect.magnitudeMax or 0, function(value)
            effect.magnitudeMax = value
            state.preview = nil
        end, { width = m.number_w }), m)
        lines[#lines + 1] = spacer(0, 4)
        lines[#lines + 1] = fieldLine("Area", numberInput(effect.area or 0, function(value)
            effect.area = value
            state.preview = nil
        end, { width = m.number_w }), m)
        lines[#lines + 1] = spacer(0, 4)
        lines[#lines + 1] = fieldLine("Duration", numberInput(effect.duration or 0, function(value)
            effect.duration = value
            state.preview = nil
        end, { width = m.number_w }), m)
    end

    return section("Selected Effect", column(lines), v2(m.right_w, m.editor_h))
end

local function savedRecipes(m)
    local rows = {}
    local saved = ui_api.getSavedRecipes()
    for i, entry in ipairs(saved or {}) do
        if i > 5 then
            break
        end
        rows[#rows + 1] = button(shortText(entry.title or entry.id, math.max(16, math.floor(m.right_button_w / 7))), function()
            loadSaved(entry)
        end, { width = m.right_button_w })
        rows[#rows + 1] = spacer(0, 2)
    end
    if #rows == 0 then
        rows[#rows + 1] = paragraph("No saved recipes.", v2(math.max(110, m.right_w - 38), 32))
    end
    return section("Saved", column(rows), v2(m.right_w, m.saved_h))
end

local function previewPanel(m)
    local preview = state.preview or {}
    local matrix = preview.feature_matrix or {}
    local lines = {
        "Status: " .. tostring(state.status),
    }
    if preview.recipe_id then
        lines[#lines + 1] = "Recipe: " .. tostring(preview.recipe_id)
    end
    if preview.group_count then
        lines[#lines + 1] = string.format("Groups: %s  Slots: %s  Helpers: %s",
            tostring(preview.group_count),
            tostring(preview.slot_count or 0),
            tostring(preview.helper_spec_count or 0)
        )
    end
    if matrix.live_runtime_status then
        lines[#lines + 1] = "Runtime: " .. tostring(matrix.live_runtime_status)
    end
    if matrix.deferred_reasons and #matrix.deferred_reasons > 0 then
        lines[#lines + 1] = "Deferred: " .. table.concat(matrix.deferred_reasons, ", ")
    end
    return section("Preview", paragraph(table.concat(lines, "\n"), v2(m.preview_text_w, m.preview_text_h)), v2(m.right_w, m.preview_h))
end

local function titleEditor(m)
    return row({
        textLayout("Name"),
        spacer(8, 0),
        textInput(state.title, function(value)
            state.title = value
        end, { width = m.title_w }),
    })
end

local function actionButtons()
    return row({
        button("Save", saveRecipe, { width = 54 }),
        spacer(5, 0),
        button("Validate", validateRecipe, { width = 70 }),
        spacer(5, 0),
        button("Preview", previewRecipe, { width = 70 }),
        spacer(5, 0),
        button("Compile", compileDeferred, { width = 70 }),
        spacer(5, 0),
        button("Delete", deleteSaved, { width = 60 }),
        spacer(5, 0),
        button("Cancel", function()
            spellcrafting_ui.close()
        end, { width = 60 }),
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
                        row({
                            textLayout("Spellmaking", { header = true, size = 20 }),
                            spacer(16, 0),
                            titleEditor(m),
                        }, { size = v2(m.content_w, m.top_h) }),
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
                                savedRecipes(m),
                                spacer(0, m.gap),
                                selectedEditor(m),
                                spacer(0, m.gap),
                                previewPanel(m),
                            }),
                        }, { size = v2(m.content_w, m.main_h) }),
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
