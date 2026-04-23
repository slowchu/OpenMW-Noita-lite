-- Pattern reference: Trap Handling's load-context custom effect registration (adapted).

content.magicEffects.records.spellforge_composed = {
    name = "Composed Spell",
    school = "alteration",
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
