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
        description = "Distribute multicast copies across an arc in degrees.",
        parameters = {
            arc = { type = "number", min = 0, max = 360 },
        },
    },
    ["Damage+"] = {
        kind = "launch_modifier",
        display_name = "Damage+",
        description = "Scale damage magnitudes on the next emitter by percent.",
        parameters = {
            percent = { type = "number", min = -90, max = 400 },
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
            hops = { type = "integer", min = 1, max = 5 },
        },
    },
    Pierce = {
        kind = "launch_modifier",
        display_name = "Pierce",
        description = "Allow projectile to pass through N actors before terminating.",
        parameters = {
            count = { type = "integer", min = 1, max = 3 },
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
            seconds = { type = "number", min = 0.05, max = 30 },
        },
    },
}

return opcodes
