-- Pattern reference: Trap Handling's load-context custom effect registration (adapted).

content.magicEffects.records.spellforge_composed = {
    template = content.magicEffects.records.open,
    name = "Composed Spell",
    school = "alteration",
    icon = "icons\\s\\tx_scroll_openlock.dds",
    description = "Spellforge marker effect. Runtime payload resolution is handled by Spellforge executor.",
    hasMagnitude = false,
    hasArea = false,
    hasDuration = false,
    harmful = false,
    allowsEnchanting = false,
    allowsSpellmaking = false,
}

return {
    marker_effect_id = "spellforge_composed",
}
