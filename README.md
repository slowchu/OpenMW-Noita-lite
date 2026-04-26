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
- `SpellforgeDev.enable_live_2_2c_simple_dispatch`

All default to `false` for normal gameplay. `enable_debug_launch` also requires
`enable_dev_hotkeys`.

The 2.2c dev-only helper-record launch smoke requires both
`enable_smoke_tests` and `enable_dev_launch`. Loading
`spellforge_smoke_dev_launch.omwscripts` loads a global helper that enables
those keys plus `enable_live_2_2c_simple_dispatch` for the dev launch harness
and lowers the Spellforge log filter to `info` if it was stricter. In that
harness, press `L` for the 2.2c.8
single-helper launch smoke, `M` for the 2.2c.9 Multicast x3 launch smoke,
and `T` for the 2.2c.10 Timer payload smoke, which logs the predicted Timer
travel endpoint and payload resolution position. Press `G` for the 2.2c.11
simple Trigger payload smoke, and `Y` for the Multicast x3 Trigger cardinality
smoke. Press `N` for the feature-flagged live 2.2c simple-dispatch bridge smoke.

Smoke `.omwscripts` files are add-ons. Load them alongside
`spellforge.omwscripts`, which owns the load-context records and global backend.
