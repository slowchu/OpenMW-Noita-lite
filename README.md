# OpenMW Noita Lite

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the authoritative design and module contract.

Current project status:

- Milestone **2.2b intercept-dispatch** is the current working runtime foundation.
- The project is transitioning to Milestone **2.2c opcode runtime**.
- 2.2c will keep the working 2.2b cast intercept path and replace transitional prototype scaffolding with effect-list parsing, compiled plans, and bounded orchestration.

Project memory and process lessons are tracked in [`LESSONS.md`](LESSONS.md).
Current transitional state notes are tracked in [`CURRENT_STATE.md`](CURRENT_STATE.md).

## UI contract foundation

The interface contract now has a static effect-list recipe shape,
`spellforge-ui-recipe-v1`. It supports structured validation and dry-run
planning previews for the dev-gated spellcrafting shell.

The global event API is:

- `Spellforge_ValidateRecipe` -> `Spellforge_ValidateResult`
- `Spellforge_PreviewRecipe` -> `Spellforge_PreviewResult`
- `Spellforge_QueryUiCatalog` -> `Spellforge_UiCatalogResult`

Validation returns stable issue fields: `code`, `path`, `message`, `severity`,
and optional `details`. Preview returns the normalized recipe, recipe id, bounds,
groups, emission slots, helper specs, and conservative deferred-runtime notes.
Preview does not materialize helper records, launch projectiles, or require the
SFP backend to be ready.

Preview also includes `feature_matrix`, a machine-readable support summary for
the future UI. It lists active features, required dev/live gates, bounded limits,
and deferred reasons for valid-but-not-live-supported combinations such as
Bounce+Timer or source-level Bounce+Multicast, while marking narrow supported
Bounce Trigger payload fanout and Bounce Trigger Chain shapes as feature-gated
instead of broadly unsupported.

The UI catalog result is static metadata for building the interface: recipe
schema version, supported operator opcodes/effect IDs, operator parameters,
feature matrix catalog, event names, relevant limits, and dry-run defaults.

Player scripts also have a UI API boundary in `player/ui.lua`. It wraps catalog,
validate, preview, save, delete, and lifecycle event plumbing behind simple calls
and caches the latest results for the visible shell. The first dev/smoke-gated
spellcrafting shell lives in `player/spellcrafting_ui.lua` and opens with `Y`
when dev hotkeys or smoke tests are enabled. The shell fits itself to the
detected `Windows` UI layer, opens from a safe top-left position, and logs its
`screen=`, `layer=`, `window=`, and `position=` dimensions on open. The visible
Create action now saves, validates, previews, materializes helper records, and
creates a player-visible generated frontend spell while keeping live runtime
behavior behind the existing dev/smoke gates. If preview reports a deferred
runtime combination, Create is blocked before helper records or frontend spells
are materialized; the player UI wrapper applies the same guard for cached
deferred previews. Saved recipe loads sanitize malformed operator parameter
maps before rendering.

Saved UI recipes use `spellforge-saved-recipe-v1`: stable saved ids, title/name
metadata, normalized effect-list recipes with `ui_id` fields, recipe ids from
validation/preview, and explicit unsupported-version errors. Generated spell
lifecycle state is stored separately so UI-created spells can move through
draft, validate, preview, compile-pending, compiled, stale, delete-pending, and
deleted states without exposing helper records to the player spellbook.

The plan-cache smoke add-on also includes a player-side UI API smoke. It
exercises catalog, cache, save, validate, preview, compile, delete, and
spellbook-pollution checks through the same wrapper the visible shell uses,
including the cached deferred-preview compile guard. Player storage keeps a
small read-through cache so UI calls can read saved recipes and lifecycle state
immediately after writes.

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
- `SpellforgeDev.enable_live_chain_multicast_v0`
- `SpellforgeDev.enable_live_bounce_v0`
- `SpellforgeDev.enable_live_homing_v0`
- `SpellforgeDev.enable_live_soft_homing_v0`
- `SpellforgeDev.enable_live_soft_homing_probe`
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
`enable_live_chain_audit_v0`, `enable_live_chain_runtime_v0`,
`enable_live_chain_multicast_v0`,
`enable_live_bounce_v0`, `enable_live_homing_v0`,
`enable_live_soft_homing_v0`, `enable_live_soft_homing_probe`, and
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
smoke plus the audit-only nested payload planner, Chain audit/runtime smoke,
Chain Speed+/Size+ payload modifier probes, and bounded Chain+Multicast branch
observability probes,
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
mutation smoke, `Numpad -` for live Size+ v0 helper-spec mutation smoke,
`K` for live Homing v0 SFP 1.7 `forceVec` dry-run plus the delayed soft
redirect/retarget runtime/probe, or `Numpad .` for
the chaos budget high-fanout stress suite, including Chain+Multicast high-fanout
checks. Press `G` for the Bounce v0
    hardening smoke plus Bounce Trigger payload Multicast/Spread/Burst dry-runs,
    post-bounce simple/fanout probes, and gate rejection checks,
    `H` for the Bounce Trigger->Chain no-target/mock/live probe, `J` for manual
    Bounce surface/contact diagnostics, or `Y` for the dev/smoke-gated
    spellcrafting shell.
The Trigger, Timer, Chain+Multicast, nested final fanout, and Bounce smokes now
also assert compact branch metadata on launch jobs and SFP `userData` so nested
or fanout regressions are easier to separate in logs. The dev smoke probe also
resets synthetic launch-density accounting between probe events. Chain+Multicast
probe smokes keep one real continuation sibling per hop and virtualize
non-continuing smoke siblings after branch metadata/userData is built, so the
smoke can validate bounded fanout without dumping every sibling on screen. Real
launched Chain payload siblings use `SPELLFORGE_CHAIN_HOP_PAYLOAD_OK`; smoke-only
non-continuing siblings use compact per-hop
`SPELLFORGE_CHAIN_HOP_PAYLOAD_VIRTUAL_OK` summaries.

Smoke `.omwscripts` files are add-ons. Load them alongside
`spellforge.omwscripts`, which owns the load-context records and global backend.
The live Timer smoke uses a phased dev-only checker around the gameplay
`async:newSimulationTimer` path; the checker does not mature the Timer by
burning orchestrator ticks or directly invoking the callback. On callback,
Timer now attempts the SFP 1.7 source-projectile detonation path before
enqueueing payload jobs; if the source projectile already hit, the smoke records
a safe skip and still verifies the payload launch.
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
`SpellforgeDev.enable_live_size_plus`. `SpellforgeDev.enable_live_chain_multicast_v0`
enables bounded direct Chain+Multicast and Trigger->Chain+Multicast simple
payload shapes; sibling payloads share one continuation claim per hop, so fanout
does not become exponential branching. Each hop is a discrete hit-routed
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
`SPELLFORGE_CHAIN_MODIFIED_PAYLOAD_OK`. Chain with Spread/Burst,
Trigger/Timer payloads, Speed+/Size+ plus Multicast, recursion, nested runtime branches, per-frame actor
scans, post-launch steering, and per-projectile updates remains deferred.

Chaos budget v0 is separately gated by
`SpellforgeDev.enable_chaos_budget_v0`; it keeps normal gameplay on the default
bring-up caps while allowing dev smokes to stress bounded fanout with higher
limits. The chaos profile currently raises projectiles per cast 32 -> 64,
payload/direct fanout 8 -> 16, nested final fanout 8 -> 16, nested payload jobs
32 -> 64, jobs per tick 16 -> 24, and Chain scan candidates 16 -> 24. The
separate live-launch density cap is a pacing rail: normal/default helper launch
density remains 8 per simulation update window, while chaos high-fanout launches
get an adaptive first-update burst of 8 per launch group and then drain the tail
at 4 per simulation update window. Queued overflow preserves that sustained cap
when the executor resumes it on later updates. The `Numpad .` smoke also spaces
high-fanout probe phases and polls queued jobs to completion so stress coverage
does not overload the spell/audio pipeline all at once. Hard caps still reject over-budget spells,
Chain stays sequential, direct/Trigger Chain+Multicast is capped at 8 in the chaos profile, and Chain+Pattern, Chain recursion,
actor scans, post-launch steering, and per-projectile updates remain deferred.

SFP 1.7 release support is handled at the Spellforge adapter boundary. The
adapter forwards explicit launch fields such as `spawnOffset`, `maxLifetime`,
`muteCastGlow`, `boltSound`, `boltLightId`, and `spinSpeed`, and normalizes
table-based `detonateSpellAtPos` calls onto SFP 1.7's ordered positional
signature. Timer source detonation uses the registered source projectile
position/cell, then `cancelSpell`, and does not add per-frame projectile loops.

Homing v0 is separately gated by `SpellforgeDev.enable_live_homing_v0`. The
supported shape is `Homing -> simple target projectile`: Spellforge computes
one bounded SFP 1.7 `forceVec` at helper launch time toward an actor selected by
a bounded forward cone scan, an explicit target position, or a hit position
fallback. The scan prioritizes aim-line error before distance and uses a lower
creature aim height so small creatures under the crosshair do not lose to a
nearer off-axis NPC. It preserves Homing metadata in compact `userData` and keeps the
assist launch/job scoped. `SpellforgeDev.enable_live_soft_homing_v0` lets this
narrow primary shape use the central low-frequency soft redirect manager instead
of launch-time `forceVec`; `SpellforgeDev.enable_live_soft_homing_probe` keeps
the single-projectile instrumentation probe on the `K` smoke. The manager waits
for a short initial delay, requests SFP state at low frequency, and attempts
blended `redirectSpell` nudges. The current blend is `0.35`, strong enough to
curve visibly without snapping directly onto the target. It may run rare bounded retarget scans and only
switches when the cached target is missing, invalid, static, overshot, or when a
nearby actor is substantially closer. Explicit-position fallback entries get a
wider retarget radius and faster search interval for long shots, but still use
forward-cone filtering plus the same capped candidate inspection, manager tick,
and retarget budget. If the fallback point moves behind the projectile and no
forward actor retarget is chosen, the manager stops steering toward the stale
point and keeps bounded projectile-position retarget scans alive on the steer
cadence until hit, actor acquisition, or timeout. Normal actor target switching
still uses the slower retarget cooldown. It does not enable high-fanout Homing
or Chain/Multicast integration. Homing does not add actor scans per projectile
per frame or per-projectile Lua update loops.
Homing with Bounce, Chain,
Trigger/Timer, Multicast/Spread/Burst, Speed+, Size+, nested payload runtime,
and recursion remains deferred.

Bounce v0 is separately gated by `SpellforgeDev.enable_live_bounce_v0`.
The supported v0 shapes are:

- `Bounce N -> simple target emitter`
- `Bounce N -> target emitter -> Trigger -> simple payload`
- `Bounce N -> target emitter -> Trigger -> payload Multicast`, requiring
  `SpellforgeDev.enable_live_payload_multicast_v0`
- `Bounce N -> target emitter -> Trigger -> payload Spread/Burst + Multicast`,
  requiring payload Multicast plus
  `SpellforgeDev.enable_live_payload_pattern_v0`
- `Bounce N -> target emitter -> Trigger -> Chain N -> simple payload`,
  requiring `SpellforgeDev.enable_live_chain_runtime_v0`

Smoke76/manual checks proved SFP bounce callbacks and Spellforge routing for
actor/contact hits, interior wall/statics, exterior wall/statics, and
terrain/ground. The source projectile belongs to Bounce, manually detonates the
source spell at each bounce position, routes any supported Trigger payload from
the bounce event, and cancels the source projectile on the final configured
bounce. SFP 1.7 bounce events expose the bounce point but do not always include
a hit actor, so Spellforge does one bounded Chain-provider lookup at that bounce
point, infers the nearest valid actor as the Chain source when available, and
routes into the existing Chain runtime with `no_immediate_repeat` targeting. If
no Chain candidate exists, the runtime stops safely without failure.

The v0 detonation path is event-driven through SFP 1.7
`MagExp_OnProjectileBounce`; Spellforge also applies SFP 1.7
`setSpellBounce`/`setSpellDetonateOnActor` immediately after source launch so
the live source projectile carries the bounce fields. It does not add per-frame
scans, Lua projectile updates, post-launch steering, or per-projectile Lua
brains. Bounce with Timer, Homing, source Speed+/Size+, direct source Chain,
arbitrary nested payload runtime, recursion, and unsupported fanout remains
deferred.

The `G` smoke now also runs Bounce hardening probes before the live launch:
source-only qualification, Trigger simple post-bounce detonation, Trigger->Chain
payload dry-run qualification, Trigger payload Multicast/Spread/Burst dry-run
qualification, one synthetic Bounce Trigger payload Multicast post-bounce
launch, disabled-gate/cap rejection, unsupported source fanout, Timer, direct
source Chain, Speed+, Size+, Homing, and nested payload deferrals, and a
live-launch assertion that only the source projectile is launched while the
simple Trigger payload is detonated in place.
Press `H` for the live `Bounce 3 Fire Damage -> Trigger -> Chain 3 -> Frost
Damage` probe; it first checks synthetic no-target and mock-candidate handoff
paths, then you can aim at an actor near another actor, or at a nearby surface
with valid actors close to the bounce point, to watch Bounce infer a Chain source
target and route into Chain. Empty real-provider scenes should log a safe
no-candidate stop rather than a smoke failure.
