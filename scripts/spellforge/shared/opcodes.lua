local limits = require("scripts.spellforge.shared.limits")

local opcodes = {
    Multicast = {
        kind = "launch_modifier",
        display_name = "Multicast",
        description = "Emit multiple copies of the next emitter.",
        parameters = {
            count = { type = "integer", min = 2, max = 8 },
        },
    },
    Spread = {
        kind = "launch_modifier",
        display_name = "Spread",
        description = "Apply spread preset to multicast emissions.",
        parameters = {
            preset = { type = "integer", min = 1, max = 4 },
        },
    },
    Burst = {
        kind = "launch_modifier",
        display_name = "Burst",
        description = "Emit spherical burst copies of the next emitter.",
        parameters = {
            count = { type = "integer", min = 2, max = 16 },
            -- TODO(2.2c): validate Burst+Multicast combinations against MAX_PROJECTILES_PER_CAST
            -- during effect-list compile planning. Keep vocab/range-only validation here.
        },
    },
    ["Speed+"] = {
        kind = "launch_modifier",
        display_name = "Speed+",
        description = "Scale projectile velocity on the next emitter by percent.",
        parameters = {
            percent = { type = "number", min = -90, max = 400 },
        },
    },
    ["Size+"] = {
        kind = "launch_modifier",
        display_name = "Size+",
        description = "Scale projectile size / AoE radius by percent.",
        parameters = {
            percent = { type = "number", min = -90, max = 300 },
        },
    },
    Chain = {
        kind = "launch_modifier",
        display_name = "Chain",
        description = "Redirect projectile on hit to nearest actor up to N hops.",
        parameters = {
            hops = { type = "integer", min = 1, max = limits.MAX_CHAIN_HOPS },
        },
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
            seconds = { type = "number", min = 0.5, max = 5.0 },
        },
    },
}

return opcodes
