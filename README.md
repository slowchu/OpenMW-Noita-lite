# OpenMW Noita Lite

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the authoritative design and module contract.

Current project status:

- Milestone **2.2b intercept-dispatch** is the current working runtime foundation.
- The project is transitioning to Milestone **2.2c opcode runtime**.
- 2.2c will keep the working 2.2b cast intercept path and replace transitional prototype scaffolding with effect-list parsing, compiled plans, and bounded orchestration.

Project memory and process lessons are tracked in [`LESSONS.md`](LESSONS.md).
Current transitional state notes are tracked in [`CURRENT_STATE.md`](CURRENT_STATE.md).

## Dev and smoke gates

Staged smoke scripts and dev hotkeys are gated by dev setting keys:

- `SpellforgeDev.enable_smoke_tests`
- `SpellforgeDev.enable_dev_hotkeys`
- `SpellforgeDev.enable_debug_launch`
- `SpellforgeDev.enable_dev_launch`
- `SpellforgeDev.enable_live_2_2c_runtime`
- `SpellforgeDev.enable_live_multicast`
- `SpellforgeDev.enable_live_spread_burst`
- `SpellforgeDev.enable_live_trigger`
- `SpellforgeDev.enable_live_timer`
- `SpellforgeDev.enable_live_speed_plus`
- `SpellforgeDev.enable_live_size_plus`

All default to `false` for normal gameplay. `enable_debug_launch` also requires
`enable_dev_hotkeys`.

The 2.2c dev-only helper-record launch smoke requires both
`enable_smoke_tests` and `enable_dev_launch`. Loading
`spellforge_smoke_dev_launch.omwscripts` loads a global helper that enables
those keys plus `enable_live_2_2c_runtime`, `enable_live_multicast`,
`enable_live_spread_burst`, `enable_live_trigger`, `enable_live_timer`,
`enable_live_speed_plus`, and `enable_live_size_plus` for the dev launch harness
and lowers the Spellforge log filter to `info` if it was stricter. In that
harness, press `Numpad 0` for the performance stress spell (`Fireball -> Timer
1s -> Multicast 8 Burst Frostball -> Trigger -> Multicast 2 Fire Damage
10pt/10ft`), `Numpad +` for the 2.2c.8 single-helper launch smoke, `Numpad 1`
for the 2.2c.9 Multicast x3 launch smoke, and `Numpad 2` for the
2.2c.10 Timer payload smoke, which logs the predicted Timer travel endpoint and
payload resolution position. Press `Numpad 3` for the 2.2c.11 simple Trigger
payload smoke, and `Numpad 4` for the Multicast x3 Trigger cardinality smoke.
Press `Numpad 5` for the feature-flagged live 2.2c simple-dispatch bridge
smoke, `Numpad 6` for the live Multicast x3 primary-helper fanout smoke,
`Numpad 7` for live Spread x3 primary aiming, `Numpad 8` for live Burst x3
primary aiming, `Numpad 9` for live Trigger v0 post-hit payload smoke,
`Numpad /` for the phased live Timer v0 async simulation-delay smoke,
`Numpad *` for live Speed+ v1 `data.speed`
mutation smoke, or `Numpad -` for live Size+ v0 helper-spec mutation smoke.

Smoke `.omwscripts` files are add-ons. Load them alongside
`spellforge.omwscripts`, which owns the load-context records and global backend.
The live Timer smoke uses a phased dev-only checker around the gameplay
`async:newSimulationTimer` path; the checker does not mature the Timer by
burning orchestrator ticks or directly invoking the callback.
