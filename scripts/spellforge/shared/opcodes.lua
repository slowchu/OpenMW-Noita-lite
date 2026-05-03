local limits = require("scripts.spellforge.shared.limits")

local opcodes = {
    Multicast = {
        kind = "launch_modifier",
        display_name = "Multicast",
        description = "Emit multiple copies of the next emitter.",
        parameters = {
            count = { type = "integer", min = 2, max = limits.MAX_PAYLOAD_FANOUT_HARD, default = 3 },
        },
    },
    Spread = {
        kind = "launch_modifier",
        display_name = "Spread",
        description = "Apply spread preset to multicast emissions.",
        parameters = {
            preset = { type = "integer", min = 1, max = 4, default = 1 },
        },
    },
    Burst = {
        kind = "launch_modifier",
        display_name = "Burst",
        description = "Emit spherical burst copies of the next emitter.",
        parameters = {
            count = { type = "integer", min = 2, max = 16, default = 5 },
            -- TODO(2.2c): validate Burst+Multicast combinations against MAX_PROJECTILES_PER_CAST
            -- during effect-list compile planning. Keep vocab/range-only validation here.
        },
    },
    ["Speed+"] = {
        kind = "launch_modifier",
        display_name = "Speed+",
        description = "Scale projectile velocity on the next emitter by percent.",
        parameters = {
            percent = { type = "number", min = -90, max = 400, default = 50 },
        },
    },
    ["Size+"] = {
        kind = "launch_modifier",
        display_name = "Size+",
        description = "Scale projectile size / AoE radius by percent.",
        parameters = {
            percent = { type = "number", min = -90, max = 300, default = 100 },
        },
    },
    Chain = {
        kind = "launch_modifier",
        display_name = "Chain",
        description = "Redirect projectile on hit to nearest actor up to N hops.",
        parameters = {
            hops = { type = "integer", min = 1, max = limits.MAX_CHAIN_HOPS, default = 3 },
        },
    },
    Bounce = {
        kind = "launch_modifier",
        display_name = "Bounce",
        description = "Reflect the projectile off surfaces or actors up to N bounces.",
        parameters = {
            bounces = { type = "integer", min = 1, max = limits.MAX_BOUNCE_COUNT_HARD, default = 3 },
        },
    },
    Homing = {
        kind = "launch_modifier",
        display_name = "Homing",
        description = "Apply bounded SFP force-vector aim assist toward the launch target.",
        parameters = {},
    },
    Trigger = {
        kind = "scope_opener",
        display_name = "Trigger",
        description = "Open payload scope resolved when previous emitter impacts.",
        parameters = {},
    },
    Timer = {
        kind = "scope_opener",
        display_name = "Timer",
        description = "Open payload scope resolved after N seconds.",
        parameters = {
            seconds = { type = "number", min = 0.5, max = 5.0, default = 1.0 },
        },
    },
}

return opcodes
