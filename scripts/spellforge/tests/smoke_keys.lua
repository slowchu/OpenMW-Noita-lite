local input = require("openmw.input")

local smoke_keys = {}

local SYMBOLS = {
    num0 = { "0", "kp0", "kp_0", "num0", "num_0", "numpad0", "numpad_0", "keypad0", "keypad_0" },
    num1 = { "1", "kp1", "kp_1", "num1", "num_1", "numpad1", "numpad_1", "keypad1", "keypad_1" },
    num2 = { "2", "kp2", "kp_2", "num2", "num_2", "numpad2", "numpad_2", "keypad2", "keypad_2" },
    num3 = { "3", "kp3", "kp_3", "num3", "num_3", "numpad3", "numpad_3", "keypad3", "keypad_3" },
    num4 = { "4", "kp4", "kp_4", "num4", "num_4", "numpad4", "numpad_4", "keypad4", "keypad_4" },
    num5 = { "5", "kp5", "kp_5", "num5", "num_5", "numpad5", "numpad_5", "keypad5", "keypad_5" },
    num6 = { "6", "kp6", "kp_6", "num6", "num_6", "numpad6", "numpad_6", "keypad6", "keypad_6" },
    num7 = { "7", "kp7", "kp_7", "num7", "num_7", "numpad7", "numpad_7", "keypad7", "keypad_7" },
    num8 = { "8", "kp8", "kp_8", "num8", "num_8", "numpad8", "numpad_8", "keypad8", "keypad_8" },
    num9 = { "9", "kp9", "kp_9", "num9", "num_9", "numpad9", "numpad_9", "keypad9", "keypad_9" },
    divide = { "/", "kp/", "kp_divide", "num_divide", "numpaddivide", "numpad_divide", "keypaddivide", "keypad_divide" },
    multiply = { "*", "kp*", "kp_multiply", "num_multiply", "numpadmultiply", "numpad_multiply", "keypadmultiply", "keypad_multiply" },
    minus = { "-", "kp-", "kp_minus", "num_minus", "numpadminus", "numpad_minus", "keypadminus", "keypad_minus" },
    plus = { "+", "kp+", "kp_plus", "num_plus", "numpadplus", "numpad_plus", "keypadplus", "keypad_plus" },
}

local KEY_NAMES = {
    num0 = { "KP_0", "NUM_0", "NUMPAD_0", "NUMPAD0" },
    num1 = { "KP_1", "NUM_1", "NUMPAD_1", "NUMPAD1" },
    num2 = { "KP_2", "NUM_2", "NUMPAD_2", "NUMPAD2" },
    num3 = { "KP_3", "NUM_3", "NUMPAD_3", "NUMPAD3" },
    num4 = { "KP_4", "NUM_4", "NUMPAD_4", "NUMPAD4" },
    num5 = { "KP_5", "NUM_5", "NUMPAD_5", "NUMPAD5" },
    num6 = { "KP_6", "NUM_6", "NUMPAD_6", "NUMPAD6" },
    num7 = { "KP_7", "NUM_7", "NUMPAD_7", "NUMPAD7" },
    num8 = { "KP_8", "NUM_8", "NUMPAD_8", "NUMPAD8" },
    num9 = { "KP_9", "NUM_9", "NUMPAD_9", "NUMPAD9" },
    divide = { "KP_DIVIDE", "NUM_DIVIDE", "NUMPAD_DIVIDE" },
    multiply = { "KP_MULTIPLY", "NUM_MULTIPLY", "NUMPAD_MULTIPLY" },
    minus = { "KP_MINUS", "NUM_MINUS", "NUMPAD_MINUS" },
    plus = { "KP_PLUS", "NUM_PLUS", "NUMPAD_PLUS", "KP_ADD", "NUM_ADD", "NUMPAD_ADD" },
}

local LABELS = {
    num0 = "Numpad 0",
    num1 = "Numpad 1",
    num2 = "Numpad 2",
    num3 = "Numpad 3",
    num4 = "Numpad 4",
    num5 = "Numpad 5",
    num6 = "Numpad 6",
    num7 = "Numpad 7",
    num8 = "Numpad 8",
    num9 = "Numpad 9",
    divide = "Numpad /",
    multiply = "Numpad *",
    minus = "Numpad -",
    plus = "Numpad +",
}

local function matchesSymbol(symbol, accepted)
    for _, value in ipairs(accepted or {}) do
        if symbol == value then
            return true
        end
    end
    return false
end

local function matchesKeyCode(code, key_names)
    if code == nil or type(input.KEY) ~= "table" then
        return false
    end
    for _, name in ipairs(key_names or {}) do
        local expected = input.KEY[name]
        if expected ~= nil and code == expected then
            return true
        end
    end
    return false
end

function smoke_keys.matches(key, id)
    local symbol = key and key.symbol and string.lower(tostring(key.symbol)) or ""
    return matchesSymbol(symbol, SYMBOLS[id]) or matchesKeyCode(key and key.code, KEY_NAMES[id])
end

function smoke_keys.label(id)
    return LABELS[id] or tostring(id)
end

return smoke_keys
