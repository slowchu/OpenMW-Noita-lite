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
deferred reasons, and Pack H reason classifications:
`feature_gated`, `unsupported_by_design`, `future_deferred`,
`cap_or_budget_rejected`, `gate_disabled`, and `internal_error`. Narrow supported
Bounce/Pierce Trigger payload fanout, event-source fanout/Timer, Chain
fanout/side-continuation, Homing composition, and bounded depth-2 nesting report
as feature-gated instead of stale deferred entries.

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
- `SpellforgeDev.enable_live_pierce_v0`
- `SpellforgeDev.enable_live_homing_v0`
- `SpellforgeDev.enable_live_soft_homing_v0`
- `SpellforgeDev.enable_live_soft_homing_probe`
- `SpellforgeDev.enable_chaos_budget_v0`
- `SpellforgeDev.enable_ir_trigger_runtime_v0`
- `SpellforgeDev.enable_ir_timer_runtime_v0`
- `SpellforgeDev.enable_ir_bounce_runtime_v0`
- `SpellforgeDev.enable_ir_chain_runtime_v0`
- `SpellforgeDev.enable_ir_pierce_runtime_v0`
- `SpellforgeDev.enable_ir_runtime_strict_v0`
- `SpellforgeDev.enable_legacy_trigger_runtime_v0`
- `SpellforgeDev.enable_legacy_timer_runtime_v0`
- `SpellforgeDev.enable_legacy_bounce_runtime_v0`
- `SpellforgeDev.enable_legacy_chain_runtime_v0`

All default to `false` for normal gameplay. The explicit `enable_ir_*` flags are
developer overrides; Trigger, Timer, Bounce, Chain, and Pierce now prefer their IR
adapter path automatically when the matching live runtime gate is enabled.
`enable_ir_runtime_strict_v0` is smoke/dev-only: supported shapes must stay on
the IR adapter/planner/job-planner path and unexpected fallback/mismatch becomes
a smoke failure. The legacy flags are explicit debug quarantine switches and are
kept off by the standard smoke enable script.
Speed+/Size+ policy is shared: event adapters pass event context, gates, caps,
and their own Bounce/Pierce facts, while `launch_modifier_policy.lua` owns
modifier decisions and helper-spec prep. `runtime_job_planner.lua` applies
payload mutations to IR-planned jobs, and generic source launch/spec creation
applies source mutations before SFP launch fields are finalized. Combined
Speed+ Size+ is supported on one simple payload branch through the same policy;
single Speed+ or Size+ and combined Speed+ Size+ both compose with direct
Trigger/Timer payload Multicast and direct Trigger/Timer payload Spread/Burst +
Multicast. Ordinary source launches now support combined Speed+ Size+, source
modifier Multicast, and source modifier Spread/Burst + Multicast with one or
both Speed+/Size+ modifiers through the same policy path. Source
`Bounce/Pierce -> Speed+` or
`Bounce/Pierce -> Size+` simple launches remain feature-gated through source
policy. Bounce/Pierce primary source Multicast or Spread/Burst + Multicast
fanout now uses the shared source fanout path too, including zero, one, or both
Speed+/Size+ source modifiers and Trigger simple payload routing when the
event-source budget passes. Chain payload fanout now consumes the same policy for
bounded direct and Trigger->Chain Multicast or Spread/Burst + Multicast branches,
including combined Speed+ Size+ branches, while Chain itself keeps sole ownership
of hop targeting and one continuation claim per hop.
`enable_debug_launch` also requires
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
`enable_live_bounce_v0`, `enable_live_pierce_v0`, `enable_live_homing_v0`,
`enable_live_soft_homing_v0`, `enable_live_soft_homing_probe`,
`enable_chaos_budget_v0`, explicit IR runtime gates, and
`enable_ir_runtime_strict_v0`; it also disables legacy runtime debug flags for
quarantine checks and lowers the Spellforge log filter to `info` if it was
stricter. In that
harness, press `Numpad 0` for the performance stress spell (`Fireball -> Timer
1s -> Multicast 8 Burst Frostball -> Trigger -> Multicast 2 Fire Damage
10pt/10ft`), `Numpad +` for the 2.2c.8 single-helper launch smoke, `Numpad 1`
for the 2.2c.9 Multicast x3 launch smoke, and `Numpad 2` for the
2.2c.10 Timer payload smoke, which logs the predicted Timer travel endpoint and
payload resolution position. Press `Numpad 3` for the 2.2c.11 simple Trigger
payload smoke, and `Numpad 4` for the Multicast x3 Trigger cardinality smoke.
Press `Numpad 5` for the feature-flagged live 2.2c simple-dispatch bridge
smoke plus the audit-only nested payload planner, Chain audit/runtime smoke,
Chain Speed+/Size+ payload modifier probes, bounded Chain+Multicast branch
observability probes, and the narrow single-modifier Chain Multicast policy
checks,
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
`I` for the consolidated all-IR adapter migration plus payload/source modifier
policy conformance, single/combined payload fanout policy smokes,
single/combined payload Pattern policy smokes, launch modifier closure policy,
event-source fanout/Timer policy smokes, Chain fanout/side-continuation smokes,
Homing composition, bounded nested continuation, strict IR runtime status,
support-truth conformance, legacy quarantine, and smoke-harness structure checks,
`K` for live Homing v0 SFP 1.7 `forceVec` dry-run plus the delayed soft
redirect/retarget runtime/probe, or `Numpad .` for
the chaos budget high-fanout stress suite, including Chain+Multicast high-fanout
checks. Press `G` for the Bounce v0
    hardening smoke plus Bounce Trigger payload Multicast/Spread/Burst dry-runs,
    post-bounce simple/fanout probes, IR Bounce runtime gate checks, and gate
    rejection checks,
    `H` for the Bounce Trigger->Chain no-target/mock/live probe, `P` for the
    Pierce v0 source/Trigger fanout/Chain smoke, `L` for the
    manual Chain real-provider probe with per-shot candidate/LOS/handoff
    diagnostics, `J` for manual Bounce surface/contact diagnostics, or `Y` for
    the dev/smoke-gated spellcrafting shell.
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
runtime deferred. A single payload Speed+ or Size+ may prefix those direct
Trigger/Timer Multicast groups through the shared launch modifier policy when
the matching modifier gate is enabled; combined Speed+ Size+ with payload
Multicast is also supported for direct Trigger/Timer payload fanout through the
shared policy.
Payload Spread/Burst v0 runtime is separately gated by
`SpellforgeDev.enable_live_payload_pattern_v0`; it only applies launch-time
directions to direct Trigger/Timer payload Multicast groups and does not add
post-launch steering. One payload Speed+, one payload Size+, or combined
Speed+ Size+ may prefix those direct Pattern groups through the shared launch
modifier policy; Chain payload Pattern is supported only through the bounded
Chain fanout path, while Chain/Homing source targeting composition remains
deferred.
Nested Trigger/Timer v1 runtime is separately gated by
`SpellforgeDev.enable_live_nested_trigger_timer_v1`; Pack G allows bounded
depth-2 `Trigger -> Trigger`, `Timer -> Timer`, `Timer -> Trigger`, and
`Trigger -> Timer` shapes through the shared continuation planner.
Nested final fanout v0 is separately gated by
`SpellforgeDev.enable_live_nested_final_fanout_v0`; final payloads may use
already-supported Multicast, Spread/Burst + Multicast, Speed+/Size+/combined,
Homing, or non-recursive Chain shapes when their gates and caps pass. Depth
greater than 2, final Trigger/Timer continuations, Chain recursion, Homing
recursion, actor scans, post-launch steering, and per-projectile updates remain
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
Trigger -> Chain N simple payload hops, and Chain payload modifier
shapes `Chain N -> Speed+ -> simple payload`,
`Chain N -> Size+ -> simple payload`, and
`Chain N -> Speed+ -> Size+ -> simple payload` when the matching modifier gates
are enabled. Chain payload Speed+ also requires
`SpellforgeDev.enable_live_speed_plus`; Chain payload Size+ also requires
`SpellforgeDev.enable_live_size_plus`. `SpellforgeDev.enable_live_chain_multicast_v0`
enables bounded direct Chain+Multicast and Trigger->Chain+Multicast simple
payload shapes, plus the same Chain payload Multicast shape with one or both
Speed+/Size+ modifiers when the matching modifier gates are enabled. With the
payload Pattern gate, bounded direct Chain and Trigger->Chain Spread/Burst +
Multicast payload branches are supported too, again including combined Speed+
Size+ through the shared launch-modifier policy. Chain payload emitters may also
carry bounded Trigger or Timer side continuations; those route through the shared
Trigger/Timer IR paths and do not advance Chain. Sibling payloads share one
Chain continuation claim per hop, so fanout does not become exponential
branching. Each hop is a discrete hit-routed orchestrator job, uses
`no_immediate_repeat`, preserves Chain continuation `userData` alongside
modifier and side-continuation metadata, and stops at max hops or no valid
target.
The live path uses injected/mock candidates for deterministic smokes, then falls
back to a bounded real provider on discrete Chain hit/hop events when
`openmw.world.activeActors` is available. The real provider rejects non-actor hit
routes, compares actor base positions against a strict same-floor vertical
tolerance, filters the caster/current hit target before LOS, separates the
bounded active-actor inspection cap from the returned candidate cap, asks the
player-local script to raycast line of sight to the capped candidate set, and
launches payload bolts between raised actor aim points so close targets are
visible. When live Chain runtime is enabled, qualified Chain
payload hops prefer runtime IR plus the continuation/job planners, then merge
into the existing Chain enqueue path; this does not change target selection,
duplicate suppression, Chain+Multicast continuation grouping, or Speed+/Size+
metadata.
`Numpad 5` proves Chain runtime with deterministic mock candidates; use `L`
for visual real-provider checks against placed actors. Manual gameplay smoke on
`L` for `Fire Damage -> Trigger -> Chain 3 -> Frost Damage` should show
`SPELLFORGE_CHAIN_PROVIDER_REAL_OK`, `SPELLFORGE_CHAIN_LOS_REQUESTED`,
`SPELLFORGE_CHAIN_LOS_LOCAL_RESULT`, `SPELLFORGE_CHAIN_LOS_RESULT`,
`SPELLFORGE_CHAIN_REAL_TARGET_SELECTED`, `SPELLFORGE_CHAIN_HOP_ENQUEUED`, and
`SPELLFORGE_CHAIN_HOP_PAYLOAD_OK`, or a safe provider-unavailable/no-target
stop. The follow-up marker `SPELLFORGE_CHAIN_REAL_PROVIDER_FOLLOWUP_STATUS`
reports per-shot deltas for source hits, provider attempts, returned
candidates, active-actor/candidate cap hits, current/caster exclusions,
LOS-visible candidates, selected real targets, hop enqueueing, and payload
launch; `SPELLFORGE_CHAIN_REAL_PROVIDER_DIAGNOSTIC_STATUS` adds a single
diagnostic reason such as `no_source_actor_hit`, `no_candidates_returned`,
`actor_scan_cap_exhausted`, or `no_visible_target`. Smoke110 proved six
manual real-provider Chain probes with three real target selections, three
enqueued hops, three accepted payload launches, caster/current-hit prefiltering,
no cap hits, and clean `max_hops_reached` stops. The automated Chain runtime
suite also includes `SPELLFORGE_CHAIN_PROVIDER_PREFILTER_CAPS_OK`, a deterministic
injected-actor regression for that provider behavior. Modifier manual shapes to check are
`Fire Damage -> Trigger -> Chain 3 -> Speed+ -> Frost Damage` and
`Fire Damage -> Trigger -> Chain 3 -> Size+ -> Frost Damage`; the combined
shape is `Fire Damage -> Trigger -> Chain 3 -> Speed+ -> Size+ -> Frost Damage`.
The bounded Multicast/Pattern policy smoke shapes include
`Fire Damage -> Chain 3 -> Speed+ -> Multicast 3 -> Frost Damage` and
`Fire Damage -> Chain 3 -> Size+ -> Multicast 3 -> Frost Damage`, plus the
matching `Fire Damage -> Trigger -> Chain 3 -> ...` forms, plus
`Fire Damage -> Trigger -> Chain 3 -> Spread -> Multicast 3 -> Frost Damage`,
`Fire Damage -> Trigger -> Chain 3 -> Burst -> Multicast 3 -> Frost Damage`, and
`Fire Damage -> Trigger -> Chain 3 -> Speed+ -> Size+ -> Multicast 3 -> Frost Damage`.
Chain side-continuation proof shapes include
`Fire Damage -> Chain 3 -> Frost Damage -> Trigger -> Shock Damage`,
`Fire Damage -> Chain 3 -> Frost Damage -> Timer -> Shock Damage`,
`Fire Damage -> Trigger -> Chain 3 -> Frost Damage -> Trigger -> Shock Damage`,
and `Fire Damage -> Trigger -> Chain 3 -> Frost Damage -> Timer -> Shock Damage`.
Expected modifier markers include `SPELLFORGE_CHAIN_MODIFIER_QUALIFIED`,
one or both of `SPELLFORGE_CHAIN_SPEED_PLUS_APPLIED` and
`SPELLFORGE_CHAIN_SIZE_PLUS_APPLIED`,
`SPELLFORGE_CHAIN_MODIFIED_HOP_ENQUEUED`, and
`SPELLFORGE_CHAIN_MODIFIED_PAYLOAD_OK`; Pattern coverage also logs
`SPELLFORGE_CHAIN_PATTERN_CONFORMANCE_OK`,
`SPELLFORGE_CHAIN_PATTERN_CONTINUATION_CLAIM_OK`, and
`SPELLFORGE_CHAIN_PATTERN_SIBLING_NONCONTINUING_OK`; side-continuation coverage
logs `SPELLFORGE_CHAIN_EVENT_CONTINUATION_CONFORMANCE_OK`.
Chain recursion, Chain->Chain, Chain side payloads containing Chain,
Chain+Homing, per-frame actor scans, post-launch steering, and per-projectile
updates remain classified as unsupported/deferred v1 surfaces. Non-recursive Chain is allowed as a bounded Pack G
final payload when the nested depth and job budgets pass.

Chaos budget v0 is separately gated by
`SpellforgeDev.enable_chaos_budget_v0`; it keeps normal gameplay on the default
bring-up caps while allowing dev smokes to stress bounded fanout with higher
limits. The chaos profile currently raises projectiles per cast 32 -> 64,
payload/direct fanout 8 -> 16, nested final fanout 8 -> 16, nested payload jobs
32 -> 64, jobs per tick 16 -> 24, Chain returned candidates 16 -> 24, and Chain
active-actor scan cap 64 -> 96. The
separate live-launch density cap is a pacing rail: normal/default helper launch
density remains 8 per simulation update window, while chaos high-fanout launches
get an adaptive first-update burst of 8 per launch group and then drain the tail
at 4 per simulation update window. Queued overflow preserves that sustained cap
when the executor resumes it on later updates. The `Numpad .` smoke also spaces
high-fanout probe phases and polls queued jobs to completion so stress coverage
does not overload the spell/audio pipeline all at once. Hard caps still reject over-budget spells,
Chain stays sequential, direct/Trigger Chain+Multicast is capped at 8 in the chaos profile, Chain+Pattern is capped by the same bounded job policy, and Chain recursion,
actor scans, post-launch steering, and per-projectile updates remain unsupported/deferred v1 surfaces.

SFP 1.7/1.8 release support is handled at the Spellforge adapter boundary. The
adapter forwards explicit launch fields such as `spawnOffset`, `maxLifetime`,
`muteCastGlow`, `boltSound`, `boltLightId`, `spinSpeed`, `piercing`, and
`pierceLimit`, and normalizes
table-based `detonateSpellAtPos` calls onto SFP 1.7's ordered positional
signature. Timer source detonation uses the registered source projectile
position/cell, then `cancelSpell`, and does not add per-frame projectile loops.
The repository's `SFP Reference` copy currently includes the tested Pierce
pass-through behavior used by Smoke101: `pierceLimit=N` is a pass-through
budget, so `Pierce 3` emits three Pierce events on three unique actors and then
lets the fourth actor or any geometry collision stop/detonate normally.

Homing v0 is separately gated by `SpellforgeDev.enable_live_homing_v0`.
`homing_launch_policy.lua` owns Homing support/defer decisions, launch-time
target metadata, bounded SFP 1.7 `forceVec` computation, and soft-Homing
registration caps. Supported source shapes now include `Homing -> simple target
projectile`, Homing with source Speed+/Size+/combined modifiers, Homing with
primary Multicast or Spread/Burst + Multicast, and those source fanout shapes
with Speed+/Size+ modifiers. Homing source emitters may also carry Trigger or
Timer continuations, and direct Trigger/Timer payloads may use Homing with
supported payload fanout/pattern/modifier policy shapes. Spellforge computes one
bounded `forceVec` at helper launch time toward an actor selected by a bounded
forward cone scan, an explicit target position, or a hit position fallback. The
scan prioritizes aim-line error before distance and uses a lower creature aim
height so small creatures under the crosshair do not lose to a nearer off-axis
NPC. It preserves Homing metadata in compact `userData` and keeps the assist
launch/job scoped. `SpellforgeDev.enable_live_soft_homing_v0` lets accepted
single-projectile Homing launches use the central low-frequency soft redirect
manager instead of launch-time `forceVec`; explicitly requested multi-sibling
soft Homing fanout is still deferred with `homing_soft_high_fanout_deferred`,
while ordinary Homing fanout keeps using launch-time `forceVec`.
`SpellforgeDev.enable_live_soft_homing_probe`
keeps the single-projectile instrumentation probe on the `K` smoke. The manager waits
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
beyond caps. Homing does not add actor scans per projectile per frame or
per-projectile Lua update loops. Homing with Bounce source physics, Pierce source
physics, or Chain source targeting is reported with stable unsupported reasons;
Homing recursion and arbitrary nested Homing runtime remain unsupported/deferred.

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
- `Bounce N -> Speed+ -> simple target emitter`, requiring
  `SpellforgeDev.enable_live_speed_plus`
- `Bounce N -> Size+ -> simple target emitter`, requiring
  `SpellforgeDev.enable_live_size_plus`
- `Bounce N -> Multicast -> simple target emitter`, requiring
  `SpellforgeDev.enable_live_multicast`
- `Bounce N -> Spread/Burst -> Multicast -> simple target emitter`, requiring
  live Multicast plus `SpellforgeDev.enable_live_spread_burst`
- `Bounce N -> Speed+/Size+/Speed+ Size+ -> Multicast -> simple target emitter`,
  requiring the matching Speed+/Size+ and live Multicast gates
- `Bounce N -> Speed+/Size+/Speed+ Size+ -> Spread/Burst -> Multicast -> simple target emitter`,
  requiring the matching Speed+/Size+, live Multicast, and Spread/Burst gates
- `Bounce N -> Multicast or Spread/Burst + Multicast -> target emitter -> Trigger -> simple payload`,
  requiring the Trigger gate and a passing event-source budget
- `Bounce N -> target emitter -> Timer -> simple payload`, payload Multicast,
  payload Spread/Burst + Multicast, or supported payload Speed+/Size+ shapes,
  requiring Timer plus the matching payload gates
- `Bounce N -> Multicast or Spread/Burst + Multicast -> target emitter -> Timer -> simple payload`,
  requiring Timer plus a passing event-source Timer budget

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

When live Bounce v0 is enabled, Bounce Trigger simple-payload detonation and
Trigger->Chain handoff prefer runtime-IR planning/validation while preserving
their current live routes. Bounce Trigger payload Multicast and Spread/Burst
fanout enqueue IR-planned jobs through the same orchestrator/runtime launch path
used by the legacy handlers. The live gate defaults off, explicit IR dev
overrides remain available, and legacy fallback remains available.

The v0 detonation path is event-driven through SFP 1.7
`MagExp_OnProjectileBounce`; Spellforge also applies SFP 1.7
`setSpellBounce`/`setSpellDetonateOnActor` immediately after source launch so
the live source projectile carries the bounce fields. It does not add per-frame
scans, Lua projectile updates, post-launch steering, or per-projectile Lua
brains. Event-source Timer schedules once per source emission or source fanout
sibling, not once per bounce event, budgets payload work with
`MAX_EVENT_SOURCE_TIMER_JOBS_PER_CAST`, and routes maturity through the shared
Timer and IR adapter path. Bounce with Homing, simple no-fanout combined source Speed+
Size+, source Speed+/Size+ with Trigger payloads, direct source Chain, arbitrary
nested payload runtime, recursion, and post-launch steering remains deferred.

The `G` smoke now also runs Bounce hardening probes before the live launch:
source-only qualification, Trigger simple post-bounce detonation, Trigger->Chain
payload dry-run qualification, Trigger payload Multicast/Spread/Burst dry-run
qualification, one synthetic Bounce Trigger payload Multicast post-bounce
launch, one synthetic Bounce Trigger payload Burst post-bounce launch, IR Bounce
planner/enqueue counters, disabled-gate/cap rejection, event-source Timer policy
checks, direct source Chain, simple no-fanout Bounce combined source Speed+
Size+, Homing, and nested payload deferrals, shared source Speed+/Size+ policy checks, and a
live-launch assertion that only the source projectile is launched while the
simple Trigger payload is detonated in place.
Press `H` for the live `Bounce 3 Fire Damage -> Trigger -> Chain 3 -> Frost
Damage` probe; it first checks synthetic no-target and mock-candidate handoff
paths, then you can aim at an actor near another actor, or at a nearby surface
with valid actors close to the bounce point, to watch Bounce infer a Chain source
target and route into Chain. Empty real-provider scenes should log a safe
no-candidate stop rather than a smoke failure.

Pierce v0 is the SFP 1.8-backed bounded source pass-through modifier, gated by
`SpellforgeDev.enable_live_pierce_v0` and default-off in normal gameplay. It
supports:

- `Pierce N -> simple target emitter`
- `Pierce N -> target emitter -> Trigger -> simple payload`
- `Pierce N -> target emitter -> Trigger -> payload Multicast`, requiring
  `SpellforgeDev.enable_live_payload_multicast_v0`
- `Pierce N -> target emitter -> Trigger -> payload Spread/Burst + Multicast`,
  requiring payload Multicast plus
  `SpellforgeDev.enable_live_payload_pattern_v0`
- `Pierce N -> target emitter -> Trigger -> Chain N -> simple payload`,
  requiring `SpellforgeDev.enable_live_chain_runtime_v0`
- `Pierce N -> Speed+ -> simple target emitter`, requiring
  `SpellforgeDev.enable_live_speed_plus`
- `Pierce N -> Size+ -> simple target emitter`, requiring
  `SpellforgeDev.enable_live_size_plus`
- `Pierce N -> Multicast -> simple target emitter`, requiring
  `SpellforgeDev.enable_live_multicast`
- `Pierce N -> Spread/Burst -> Multicast -> simple target emitter`, requiring
  live Multicast plus `SpellforgeDev.enable_live_spread_burst`
- `Pierce N -> Speed+/Size+/Speed+ Size+ -> Multicast -> simple target emitter`,
  requiring the matching Speed+/Size+ and live Multicast gates
- `Pierce N -> Speed+/Size+/Speed+ Size+ -> Spread/Burst -> Multicast -> simple target emitter`,
  requiring the matching Speed+/Size+, live Multicast, and Spread/Burst gates
- `Pierce N -> Multicast or Spread/Burst + Multicast -> target emitter -> Trigger -> simple payload`,
  requiring the Trigger gate and a passing event-source budget
- `Pierce N -> target emitter -> Timer -> simple payload`, payload Multicast,
  payload Spread/Burst + Multicast, or supported payload Speed+/Size+ shapes,
  requiring Timer plus the matching payload gates
- `Pierce N -> Multicast or Spread/Burst + Multicast -> target emitter -> Timer -> simple payload`,
  requiring Timer plus a passing event-source Timer budget

The source projectile uses SFP `piercing=true` and `pierceLimit=N`; `N` is the
pass-through budget, so `Pierce 3` passes through three unique actors and then
stops/detonates on the next actor or any normal geometry collision. SFP owns
source application and one-hit-per-actor tracking. Spellforge observes
`MagExp_OnProjectilePierce`, routes any supported Trigger continuation through
the shared IR runtime adapter, offsets direct payload launches forward from the
pierce hit position, and carries the pierced actor as `current_hit_target_id` and
`excludeTarget` where possible. Event-source Timer schedules once per source
emission or source fanout sibling, not once per pierce event, budgets payload
work with `MAX_EVENT_SOURCE_TIMER_JOBS_PER_CAST`, and routes maturity through
the shared Timer and IR adapter path. Pierce with Bounce, Homing, simple
no-fanout combined source Speed+ Size+, source Speed+/Size+ with Trigger
payloads, direct source Chain, arbitrary nested payload runtime, recursion,
post-launch steering combinations, and repeated same-actor Pierce ticks remains
deferred.
Press `P` for the Pierce
smoke suite; expected markers include `SPELLFORGE_SFP_PIERCE_CONTRACT_OK`,
`SPELLFORGE_LIVE_PIERCE_SOURCE_OK`, `SPELLFORGE_LIVE_PIERCE_EVENT`,
`SPELLFORGE_IR_PIERCE_RUNTIME_ENQUEUED`,
`SPELLFORGE_LIVE_PIERCE_TRIGGER_PAYLOAD_OK`,
`SPELLFORGE_LIVE_PIERCE_DUPLICATE_SUPPRESSED`,
`SPELLFORGE_PIERCE_PAYLOAD_ORIGIN_SAFE`, and `SPELLFORGE_PIERCE_DEFERRED`.
Smoke101 proved the live line test: three distinct dremora produced
`pierce_count=1`, `2`, and `3`, and a fourth distinct dremora received the
normal projectile collision. For future visual Pierce checks, prefer a no-AoE
or very small-area source spell so final explosion splash does not obscure which
actors were actually pierced.
