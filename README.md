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
- `SpellforgeDev.enable_live_payload_multicast_v0`
- `SpellforgeDev.enable_live_payload_pattern_v0`
- `SpellforgeDev.enable_live_nested_trigger_timer_v1`
- `SpellforgeDev.enable_live_nested_final_fanout_v0`
- `SpellforgeDev.enable_live_chain_audit_v0`
- `SpellforgeDev.enable_live_chain_runtime_v0`
- `SpellforgeDev.enable_chaos_budget_v0`

All default to `false` for normal gameplay. `enable_debug_launch` also requires
`enable_dev_hotkeys`.

The 2.2c dev-only helper-record launch smoke requires both
`enable_smoke_tests` and `enable_dev_launch`. Loading
`spellforge_smoke_dev_launch.omwscripts` loads a global helper that enables
those keys plus `enable_live_2_2c_runtime`, `enable_live_multicast`,
`enable_live_spread_burst`, `enable_live_trigger`, `enable_live_timer`,
`enable_live_speed_plus`, `enable_live_size_plus`,
`enable_live_payload_multicast_v0`, `enable_live_payload_pattern_v0`,
`enable_live_nested_trigger_timer_v1`, `enable_live_nested_final_fanout_v0`,
`enable_live_chain_audit_v0`, `enable_live_chain_runtime_v0`, and
`enable_chaos_budget_v0` for the dev launch harness
and lowers the Spellforge log filter to `info` if it was stricter. In that
harness, press `Numpad 0` for the performance stress spell (`Fireball -> Timer
1s -> Multicast 8 Burst Frostball -> Trigger -> Multicast 2 Fire Damage
10pt/10ft`), `Numpad +` for the 2.2c.8 single-helper launch smoke, `Numpad 1`
for the 2.2c.9 Multicast x3 launch smoke, and `Numpad 2` for the
2.2c.10 Timer payload smoke, which logs the predicted Timer travel endpoint and
payload resolution position. Press `Numpad 3` for the 2.2c.11 simple Trigger
payload smoke, and `Numpad 4` for the Multicast x3 Trigger cardinality smoke.
Press `Numpad 5` for the feature-flagged live 2.2c simple-dispatch bridge
smoke plus the audit-only nested payload planner, Chain audit/runtime smoke, and
Chain Speed+/Size+ payload modifier probes,
`Numpad 6` for the
live Multicast x3 primary-helper fanout smoke, `Numpad 7` for live Spread x3
primary aiming, `Numpad 8` for live Burst x3
primary aiming, `Numpad 9` for live Trigger v0 post-hit payload smoke plus
Trigger payload Multicast/Spread/Burst v0, Trigger->Timer v1, and
Trigger->Timer final fanout,
`Numpad /` for the phased live Timer v0 async
simulation-delay smoke plus Timer payload Multicast/Spread/Burst v0 and
Timer->Trigger v1 and Timer->Trigger final fanout,
`Numpad *` for live Speed+ v1 `data.speed`
mutation smoke, `Numpad -` for live Size+ v0 helper-spec mutation smoke, or
`Numpad .` for the chaos budget high-fanout stress suite.

Smoke `.omwscripts` files are add-ons. Load them alongside
`spellforge.omwscripts`, which owns the load-context records and global backend.
The live Timer smoke uses a phased dev-only checker around the gameplay
`async:newSimulationTimer` path; the checker does not mature the Timer by
burning orchestrator ticks or directly invoking the callback.
The nested payload planner smoke audits compiled plan structure and asserts
that audit-only probes do not call SFP launches.
Payload Multicast v0 runtime is separately gated by
`SpellforgeDev.enable_live_payload_multicast_v0`; it only enables direct
Trigger/Timer payload Multicast groups and keeps arbitrary nested payload
runtime deferred.
Payload Spread/Burst v0 runtime is separately gated by
`SpellforgeDev.enable_live_payload_pattern_v0`; it only applies launch-time
directions to direct Trigger/Timer payload Multicast groups and does not add
post-launch steering.
Nested Trigger/Timer v1 runtime is separately gated by
`SpellforgeDev.enable_live_nested_trigger_timer_v1`; it only enables the
depth-2 opposite-kind shapes `Timer -> Trigger` and `Trigger -> Timer`.
Nested final fanout v0 is separately gated by
`SpellforgeDev.enable_live_nested_final_fanout_v0`; it only enables bounded
final Multicast/Spread/Burst groups after those mixed depth-2 chains, while
same-kind nesting, depth greater than 2, nested behavior or Chain inside final
fanout, actor scans, post-launch steering, and per-projectile updates remain
deferred.
Chain v0 targeting audit is separately gated by
`SpellforgeDev.enable_live_chain_audit_v0`; it treats Chain magnitude as a
sequential max-hop count, resolves injected/mock targets for deterministic
dry-run smoke coverage, and supports the `no_immediate_repeat` rule where only
the current hit target is excluded. It does not enable live Chain payload
launches, actor scans, Chain recursion, post-launch steering, or per-projectile
updates.
Chain v0 live runtime is separately gated by
`SpellforgeDev.enable_live_chain_runtime_v0`; it enables direct Chain N,
Trigger -> Chain N simple payload hops, and the narrow Chain payload modifier
shapes `Chain N -> Speed+ -> simple payload` and
`Chain N -> Size+ -> simple payload`. Chain payload Speed+ also requires
`SpellforgeDev.enable_live_speed_plus`; Chain payload Size+ also requires
`SpellforgeDev.enable_live_size_plus`. Each hop is a discrete hit-routed
orchestrator job, uses `no_immediate_repeat`, preserves Chain continuation
`userData` alongside modifier metadata, and stops at max hops or no valid target.
The live path uses injected/mock candidates for deterministic smokes, then falls
back to a bounded real provider on discrete Chain hit/hop events when
`openmw.world.activeActors` is available. The real provider rejects non-actor hit
routes, compares actor base positions against a strict same-floor vertical
tolerance, asks the player-local script to raycast line of sight to the capped
candidate set, and launches payload bolts between raised actor aim points so
close targets are visible.
Manual gameplay smoke on `L` for
`Fire Damage -> Trigger -> Chain 3 -> Frost Damage` should show
`SPELLFORGE_CHAIN_PROVIDER_REAL_OK`, `SPELLFORGE_CHAIN_LOS_REQUESTED`,
`SPELLFORGE_CHAIN_LOS_LOCAL_RESULT`, `SPELLFORGE_CHAIN_LOS_RESULT`,
`SPELLFORGE_CHAIN_REAL_TARGET_SELECTED`, `SPELLFORGE_CHAIN_HOP_ENQUEUED`, and
`SPELLFORGE_CHAIN_HOP_PAYLOAD_OK`, or a safe provider-unavailable/no-target
stop. Modifier manual shapes to check are
`Fire Damage -> Trigger -> Chain 3 -> Speed+ -> Frost Damage` and
`Fire Damage -> Trigger -> Chain 3 -> Size+ -> Frost Damage`; expected modifier
markers include `SPELLFORGE_CHAIN_MODIFIER_QUALIFIED`,
`SPELLFORGE_CHAIN_SPEED_PLUS_APPLIED` or `SPELLFORGE_CHAIN_SIZE_PLUS_APPLIED`,
`SPELLFORGE_CHAIN_MODIFIED_HOP_ENQUEUED`, and
`SPELLFORGE_CHAIN_MODIFIED_PAYLOAD_OK`. Chain with Multicast, Spread/Burst,
Trigger/Timer payloads, recursion, nested runtime branches, per-frame actor
scans, post-launch steering, and per-projectile updates remains deferred.

Chaos budget v0 is separately gated by
`SpellforgeDev.enable_chaos_budget_v0`; it keeps normal gameplay on the default
bring-up caps while allowing dev smokes to stress bounded fanout with higher
limits. The chaos profile currently raises projectiles per cast 32 -> 64,
payload/direct fanout 8 -> 16, nested final fanout 8 -> 16, nested payload jobs
32 -> 64, jobs per tick 16 -> 24, and Chain scan candidates 16 -> 24. The
separate live-launch density cap is a pacing rail: normal/default helper launch
density remains 8 per simulation update window, while chaos high-fanout launches
drain at 4 per simulation update window. Queued overflow preserves that cap when
the executor resumes it on later updates. The `Numpad .` smoke also spaces
high-fanout probe phases and polls queued jobs to completion so stress coverage
does not overload the spell/audio pipeline all at once. Hard caps still reject over-budget spells,
Chain stays sequential, and Chain+Multicast, Chain+Pattern, Chain recursion,
actor scans, post-launch steering, and per-projectile updates remain deferred.
