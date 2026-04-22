-- Load-context custom effect registration for marker-only compiled spells.
-- Pattern reference: skrow42 Trap Handling disarmtrap_load.lua (custom effect via content.magicEffects.records).

local function register(content)
    if type(content) ~= "table" or type(content.magicEffects) ~= "table" or type(content.magicEffects.records) ~= "table" then
        return
    end

    local records = content.magicEffects.records
    local template = records.open or records.unlock
    if not template then
        return
    end

    records.spellforge_composed = {
        template = template,
        name = "Composed Spell",
        school = "alteration",
        icon = "icons\\s\\tx_scroll_open.tga",
        description = "Marker effect used by Spellforge runtime dispatcher.",
        hasMagnitude = false,
        hasArea = false,
        hasDuration = false,
        harmful = false,
        allowsEnchanting = false,
        allowsSpellmaking = false,
    }
end

register(content)

return {}
