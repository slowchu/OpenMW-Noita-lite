local limits = require("scripts.spellforge.shared.limits")

local recipes = {}

recipes.CHAOS_HIGH_FANOUT_COUNT = limits.MAX_PAYLOAD_FANOUT_CHAOS
recipes.CHAOS_OVER_CAP_FANOUT_COUNT = limits.MAX_PAYLOAD_FANOUT_CHAOS + 1
recipes.CHAOS_CHAIN_MULTICAST_FANOUT_COUNT = limits.MAX_CHAIN_MULTICAST_FANOUT_CHAOS

recipes.SIMPLE_FIRE_DAMAGE_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.MULTICAST_X3_FIRE_DAMAGE_TARGET = {
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.MULTICAST_X16_FIRE_DAMAGE_TARGET = {
    { id = "spellforge_multicast", params = { count = recipes.CHAOS_HIGH_FANOUT_COUNT } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.MULTICAST_OVER_CHAOS_CAP_TARGET = {
    { id = "spellforge_multicast", params = { count = recipes.CHAOS_OVER_CAP_FANOUT_COUNT } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.SPREAD_MULTICAST_X3_FIRE_DAMAGE_TARGET = {
    { id = "spellforge_spread", params = { preset = 2 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.BURST_MULTICAST_X3_FIRE_DAMAGE_TARGET = {
    { id = "spellforge_burst", params = { count = 5 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TRIGGER_FIRE_FROST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.BOUNCE_FIRE_TARGET = {
    { id = "spellforge_bounce", params = { bounces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.BOUNCE_TRIGGER_FIRE_FROST_TARGET = {
    { id = "spellforge_bounce", params = { bounces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
}

recipes.BOUNCE_TRIGGER_CHAIN_FROST_TARGET = {
    { id = "spellforge_bounce", params = { bounces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
}

recipes.BOUNCE_TRIGGER_NESTED_TRIGGER_TARGET = {
    { id = "spellforge_bounce", params = { bounces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "shockdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
}

recipes.BOUNCE_TRIGGER_MULTICAST_FROST_TARGET = {
    { id = "spellforge_bounce", params = { bounces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
}

recipes.BOUNCE_TRIGGER_BURST_MULTICAST_FROST_TARGET = {
    { id = "spellforge_bounce", params = { bounces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_burst", params = { count = 5 } },
    { id = "spellforge_multicast", params = { count = 5 } },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
}

recipes.BOUNCE_TRIGGER_SPREAD_MULTICAST_FROST_TARGET = {
    { id = "spellforge_bounce", params = { bounces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_spread", params = { preset = 2 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
}

recipes.PIERCE_FIRE_TARGET = {
    { id = "spellforge_pierce", params = { pierces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.PIERCE_TRIGGER_FIRE_FROST_TARGET = {
    { id = "spellforge_pierce", params = { pierces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
}

recipes.PIERCE_TRIGGER_CHAIN_FROST_TARGET = {
    { id = "spellforge_pierce", params = { pierces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
}

recipes.PIERCE_TRIGGER_MULTICAST_FROST_TARGET = {
    { id = "spellforge_pierce", params = { pierces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
}

recipes.PIERCE_TRIGGER_BURST_MULTICAST_FROST_TARGET = {
    { id = "spellforge_pierce", params = { pierces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_burst", params = { count = 5 } },
    { id = "spellforge_multicast", params = { count = 5 } },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
}

recipes.PIERCE_TRIGGER_SPREAD_MULTICAST_FROST_TARGET = {
    { id = "spellforge_pierce", params = { pierces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_spread", params = { preset = 2 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
}

recipes.PIERCE_TIMER_TARGET = {
    { id = "spellforge_pierce", params = { pierces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
}

recipes.PIERCE_BOUNCE_TARGET = {
    { id = "spellforge_pierce", params = { pierces = 3 } },
    { id = "spellforge_bounce", params = { bounces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.PIERCE_HOMING_TARGET = {
    { id = "spellforge_pierce", params = { pierces = 3 } },
    { id = "spellforge_homing" },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.PIERCE_SPEED_PLUS_TARGET = {
    { id = "spellforge_pierce", params = { pierces = 3 } },
    { id = "spellforge_speed_plus", params = { percent = 50 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.PIERCE_SIZE_PLUS_TARGET = {
    { id = "spellforge_pierce", params = { pierces = 3 } },
    { id = "spellforge_size_plus", params = { percent = 100 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.PIERCE_CHAIN_TARGET = {
    { id = "spellforge_pierce", params = { pierces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
}

recipes.PIERCE_MULTICAST_TARGET = {
    { id = "spellforge_pierce", params = { pierces = 3 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.PIERCE_TRIGGER_NESTED_TRIGGER_TARGET = {
    { id = "spellforge_pierce", params = { pierces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "shockdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
}

recipes.PIERCE_TRIGGER_PIERCE_PAYLOAD_TARGET = {
    { id = "spellforge_pierce", params = { pierces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_pierce", params = { pierces = 2 } },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
}

recipes.BOUNCE_OVER_CAP_TARGET = {
    { id = "spellforge_bounce", params = { bounces = limits.MAX_BOUNCE_COUNT + 1 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
}

recipes.BOUNCE_MULTICAST_TARGET = {
    { id = "spellforge_bounce", params = { bounces = 3 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.BOUNCE_TIMER_TARGET = {
    { id = "spellforge_bounce", params = { bounces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
}

recipes.BOUNCE_CHAIN_TARGET = {
    { id = "spellforge_bounce", params = { bounces = 3 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "frostdamage", range = 2, area = 10, duration = 1, magnitudeMin = 20, magnitudeMax = 20 },
}

recipes.BOUNCE_SPEED_PLUS_TARGET = {
    { id = "spellforge_bounce", params = { bounces = 3 } },
    { id = "spellforge_speed_plus", params = { percent = 50 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.BOUNCE_SIZE_PLUS_TARGET = {
    { id = "spellforge_bounce", params = { bounces = 3 } },
    { id = "spellforge_size_plus", params = { percent = 100 } },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.BOUNCE_HOMING_TARGET = {
    { id = "spellforge_bounce", params = { bounces = 3 } },
    { id = "spellforge_homing" },
    { id = "firedamage", range = 2, area = 10, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TIMER_FIRE_FROST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.SPEED_PLUS_FIRE_DAMAGE_TARGET = {
    { id = "spellforge_speed_plus", params = { percent = 50 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.SIZE_PLUS_FIRE_DAMAGE_TARGET = {
    { id = "spellforge_size_plus", params = { percent = 100 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.VFX_METADATA_AUDIT_TARGET = {
    {
        id = "firedamage",
        range = 2,
        area = 5,
        duration = 1,
        magnitudeMin = 2,
        magnitudeMax = 20,
        areaVfxRecId = "spellforge_test_area_static",
        areaVfxScale = 1.25,
        vfxRecId = "spellforge_test_bolt_vfx",
        boltModel = "meshes/spellforge/test_bolt.nif",
        hitModel = "meshes/spellforge/test_impact.nif",
    },
}

recipes.VFX_METADATA_MISSING_AREA_TARGET = {
    {
        id = "firedamage",
        range = 2,
        area = 5,
        duration = 1,
        magnitudeMin = 2,
        magnitudeMax = 20,
        vfxRecId = "spellforge_test_bolt_vfx",
    },
}

recipes.NON_QUALIFYING_CHAIN_FIRE_DAMAGE_TARGET = {
    { id = "spellforge_chain", params = { hops = 1 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_FIRE_FROST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_SPEED_PLUS_FROST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "spellforge_speed_plus", params = { percent = 50 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_SIZE_PLUS_FROST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "spellforge_size_plus", params = { percent = 100 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_MULTICAST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_MULTICAST_X8_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "spellforge_multicast", params = { count = recipes.CHAOS_CHAIN_MULTICAST_FANOUT_COUNT } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_SPEED_PLUS_MULTICAST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "spellforge_speed_plus", params = { percent = 50 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_SIZE_PLUS_MULTICAST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "spellforge_size_plus", params = { percent = 100 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_BURST_MULTICAST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "spellforge_burst", params = { count = 3 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_SPEED_PLUS_BURST_MULTICAST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "spellforge_speed_plus", params = { percent = 50 } },
    { id = "spellforge_burst", params = { count = 3 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_SIZE_PLUS_BURST_MULTICAST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "spellforge_size_plus", params = { percent = 100 } },
    { id = "spellforge_burst", params = { count = 3 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_TRIGGER_PAYLOAD_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_SPEED_PLUS_TRIGGER_PAYLOAD_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "spellforge_speed_plus", params = { percent = 50 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_SIZE_PLUS_TIMER_PAYLOAD_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "spellforge_size_plus", params = { percent = 100 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TRIGGER_CHAIN_FROST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TRIGGER_CHAIN_SPEED_PLUS_FROST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "spellforge_speed_plus", params = { percent = 50 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TRIGGER_CHAIN_SIZE_PLUS_FROST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "spellforge_size_plus", params = { percent = 100 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TRIGGER_CHAIN_MULTICAST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TRIGGER_CHAIN_MULTICAST_X8_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "spellforge_multicast", params = { count = recipes.CHAOS_CHAIN_MULTICAST_FANOUT_COUNT } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TRIGGER_CHAIN_PAYLOAD_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TIMER_TRIGGER_CHAIN_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_CHAIN_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_SPEED_PLUS_CHAIN_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "spellforge_speed_plus", params = { percent = 50 } },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_SIZE_PLUS_CHAIN_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "spellforge_size_plus", params = { percent = 100 } },
    { id = "spellforge_chain", params = { hops = 3 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_ZERO_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = 0 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_NEGATIVE_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = -1 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.CHAIN_OVER_CAP_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_chain", params = { hops = limits.MAX_CHAIN_HOPS + 1 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TIMER_PAYLOAD_MULTICAST_X3_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TIMER_PAYLOAD_MULTICAST_X16_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "spellforge_multicast", params = { count = recipes.CHAOS_HIGH_FANOUT_COUNT } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TRIGGER_PAYLOAD_MULTICAST_X3_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TRIGGER_PAYLOAD_MULTICAST_X16_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_multicast", params = { count = recipes.CHAOS_HIGH_FANOUT_COUNT } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TIMER_PAYLOAD_BURST_MULTICAST_X5_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "spellforge_burst", params = { count = 5 } },
    { id = "spellforge_multicast", params = { count = 5 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TIMER_PAYLOAD_SPREAD_MULTICAST_X3_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "spellforge_spread", params = { preset = 2 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TIMER_PAYLOAD_SPREAD_MULTICAST_X16_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "spellforge_spread", params = { preset = 2 } },
    { id = "spellforge_multicast", params = { count = recipes.CHAOS_HIGH_FANOUT_COUNT } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TRIGGER_PAYLOAD_BURST_MULTICAST_X5_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_burst", params = { count = 5 } },
    { id = "spellforge_multicast", params = { count = 5 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TRIGGER_PAYLOAD_BURST_MULTICAST_X16_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_burst", params = { count = 8 } },
    { id = "spellforge_multicast", params = { count = recipes.CHAOS_HIGH_FANOUT_COUNT } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TRIGGER_PAYLOAD_SPREAD_MULTICAST_X3_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_spread", params = { preset = 2 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TRIGGER_INSIDE_TIMER_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TIMER_INSIDE_TRIGGER_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TIMER_INSIDE_TIMER_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TRIGGER_INSIDE_TRIGGER_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TIMER_TRIGGER_NESTED_MULTICAST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TRIGGER_TIMER_NESTED_MULTICAST_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TRIGGER_TIMER_NESTED_MULTICAST_X16_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "spellforge_multicast", params = { count = recipes.CHAOS_HIGH_FANOUT_COUNT } },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TRIGGER_TIMER_NESTED_BURST_MULTICAST_X5_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "spellforge_burst", params = { count = 5 } },
    { id = "spellforge_multicast", params = { count = 5 } },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TIMER_TRIGGER_NESTED_SPREAD_MULTICAST_X3_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_spread", params = { preset = 2 } },
    { id = "spellforge_multicast", params = { count = 3 } },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TIMER_TRIGGER_NESTED_SPREAD_MULTICAST_X16_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_spread", params = { preset = 2 } },
    { id = "spellforge_multicast", params = { count = recipes.CHAOS_HIGH_FANOUT_COUNT } },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TRIGGER_TIMER_NESTED_MULTICAST_OVER_CHAOS_CAP_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "spellforge_multicast", params = { count = recipes.CHAOS_OVER_CAP_FANOUT_COUNT } },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TIMER_TRIGGER_NESTED_MULTICAST_OVER_CAP_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "spellforge_multicast", params = { count = 9 } },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TIMER_TRIGGER_TIMER_DEPTH_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_trigger" },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TIMER_PAYLOAD_SPEED_PLUS_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "spellforge_speed_plus", params = { percent = 50 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.TIMER_PAYLOAD_SIZE_PLUS_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "spellforge_size_plus", params = { percent = 100 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.NESTED_DEPTH_REJECTION_TARGET = {
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "frostdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "shockdamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
    { id = "spellforge_timer", params = { seconds = 1.0 } },
    { id = "firedamage", range = 2, area = 5, duration = 1, magnitudeMin = 2, magnitudeMax = 20 },
}

recipes.NESTED_AUDIT_TARGETS = {
    timer_simple = recipes.TIMER_FIRE_FROST_TARGET,
    trigger_simple = recipes.TRIGGER_FIRE_FROST_TARGET,
    timer_payload_multicast = recipes.TIMER_PAYLOAD_MULTICAST_X3_TARGET,
    trigger_payload_multicast = recipes.TRIGGER_PAYLOAD_MULTICAST_X3_TARGET,
    timer_payload_burst_multicast = recipes.TIMER_PAYLOAD_BURST_MULTICAST_X5_TARGET,
    trigger_inside_timer = recipes.TRIGGER_INSIDE_TIMER_TARGET,
    timer_inside_trigger = recipes.TIMER_INSIDE_TRIGGER_TARGET,
    timer_payload_speed_plus = recipes.TIMER_PAYLOAD_SPEED_PLUS_TARGET,
    timer_payload_size_plus = recipes.TIMER_PAYLOAD_SIZE_PLUS_TARGET,
    chain = recipes.NON_QUALIFYING_CHAIN_FIRE_DAMAGE_TARGET,
    depth_rejection = recipes.NESTED_DEPTH_REJECTION_TARGET,
}

recipes.CHAIN_AUDIT_TARGETS = {
    simple = recipes.CHAIN_FIRE_FROST_TARGET,
    direct_chain_3 = recipes.CHAIN_FIRE_FROST_TARGET,
    trigger_chain_3 = recipes.TRIGGER_CHAIN_FROST_TARGET,
    hop_bounce = recipes.CHAIN_FIRE_FROST_TARGET,
    hop_no_target = recipes.CHAIN_FIRE_FROST_TARGET,
    multicast = recipes.CHAIN_MULTICAST_TARGET,
    pattern = recipes.CHAIN_BURST_MULTICAST_TARGET,
    trigger_timer = recipes.CHAIN_TRIGGER_PAYLOAD_TARGET,
    trigger_chain_multicast = recipes.TRIGGER_CHAIN_MULTICAST_TARGET,
    nested_payload = recipes.TRIGGER_CHAIN_PAYLOAD_TARGET,
    nested_trigger_timer = recipes.TIMER_TRIGGER_CHAIN_TARGET,
    recursion = recipes.CHAIN_CHAIN_TARGET,
    invalid_zero = recipes.CHAIN_ZERO_TARGET,
    invalid_negative = recipes.CHAIN_NEGATIVE_TARGET,
    over_cap = recipes.CHAIN_OVER_CAP_TARGET,
}

recipes.PRESENTATION_METADATA_FIELDS = {
    "areaVfxRecId",
    "areaVfxScale",
    "vfxRecId",
    "boltModel",
    "hitModel",
}


return recipes
