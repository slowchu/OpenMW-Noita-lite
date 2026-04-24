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

local fire_reference = content.magicEffects.records.fireDamage
local destruction_marker_school = fire_reference and fire_reference.school or "destruction"
local destruction_marker_icon = fire_reference and fire_reference.icon or nil
local destruction_cast_static = fire_reference and fire_reference.castStatic or nil
local destruction_cast_sound = fire_reference and fire_reference.castSound or nil
local destruction_particle = fire_reference and fire_reference.particle or nil
-- TODO(2.2b hardening): if fire reference fields are unavailable in some content
-- stacks, provide an explicit bundled Spellforge icon/cast fallback.

content.magicEffects.records.spellforge_marker_target_destruction = {
    name = "Spellforge Target Marker (Destruction)",
    school = destruction_marker_school,
    description = "Internal target shell marker using manual fire/destruction cast presentation. Real projectile/hit behavior is SFP-dispatched.",
    hasMagnitude = false,
    hasArea = false,
    hasDuration = false,
    harmful = false,
    allowsEnchanting = false,
    allowsSpellmaking = false,
    -- Safety rule: do not use template cloning (see LESSONS.md Open Lock incident).
    -- Only borrow known-safe presentation flavor from fire/destruction reference.
    icon = destruction_marker_icon,
    castStatic = destruction_cast_static,
    castSound = destruction_cast_sound,
    particle = destruction_particle,
    -- Always inert/silent for vanilla placeholder projectile path.
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
