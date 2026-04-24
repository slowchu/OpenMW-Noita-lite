-- Pattern reference: Trap Handling's load-context custom effect registration (adapted).

local content = require('openmw.content')

-- Inert shell marker resources:
-- - shell spells must still follow vanilla cast flow/text keys
-- - visuals/audio should be inert; real payload is launched later through SFP.
local static_records = content.statics and content.statics.records
if static_records then
    static_records.spellforge_invisible_static = {
        model = "meshes/spellforge/invisible_marker.nif",
    }
end

local sound_records = (content.sounds and content.sounds.records)
if sound_records then
    sound_records.spellforge_silence = {
        fileName = "sound/spellforge/silence.wav",
        volume = 0,
        minRange = 0,
        maxRange = 0,
    }
end
-- TODO(2.2b hardening): confirm load-context record table names for all supported
-- OpenMW versions in use; if unavailable, marker effect falls back to nil shell
-- VFX/SFX fields rather than crashing load-context.

content.magicEffects.records.spellforge_marker_target = {
    name = "Spellforge Target Marker",
    school = "alteration",
    description = "Internal target shell marker. Spellforge launches real payload after cast success authorization.",
    hasMagnitude = false,
    hasArea = false,
    hasDuration = false,
    harmful = false,
    allowsEnchanting = false,
    allowsSpellmaking = false,
    -- Keep normal vanilla cast/fizzle feedback on hands/animation.
    -- Inert only the placeholder projectile path (bolt/hit/area) for shell casts.
    hitStatic = static_records and "spellforge_invisible_static" or nil,
    areaStatic = static_records and "spellforge_invisible_static" or nil,
    bolt = static_records and "spellforge_invisible_static" or nil,
    hitSound = sound_records and "spellforge_silence" or nil,
    areaSound = sound_records and "spellforge_silence" or nil,
    boltSound = sound_records and "spellforge_silence" or nil,
}

-- Backward-compatibility marker ID for existing saves/content.
content.magicEffects.records.spellforge_composed = {
    name = "Composed Spell",
    school = "alteration",
    description = "Legacy Spellforge marker effect. Runtime payload resolution is handled by Spellforge executor.",
    hasMagnitude = false,
    hasArea = false,
    hasDuration = false,
    harmful = false,
    allowsEnchanting = false,
    allowsSpellmaking = false,
}
