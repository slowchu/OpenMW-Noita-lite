# Spellforge Current State — 2.2c Feature-Gated Runtime

This file tracks the current implementation state of Spellforge / OpenMW-Noita-lite.

`ARCHITECTURE.md` remains the authoritative design and module-contract document. This file is intentionally more practical: it records what exists, what is feature-gated, what is known to work in smoke/live paths, and what remains deferred.

---

## Current Snapshot

Live 2.2c remains **feature-gated and default-off**. The stable 2.2b intercept-dispatch path is still preserved as the working foundation and fallback path.

### Currently implemented behind dev/live gates

- **2.2b intercept + vanilla cast-success authorization foundation**
  - player cast input
  - animation text-key intercept
  - cast-success authorization
  - global dispatch through SFP/MagExp

- **Live 2.2c simple-helper dispatch**
  - feature-gated by `SpellforgeDev.enable_live_2_2c_runtime`
  - routes eligible casts through:
    - effect-list parse / plan cache
    - helper records
    - orchestrator jobs
    - SFP/MagExp launch
    - `userData` hit identity

- **Primary Multicast fanout**
  - feature-gated by `SpellforgeDev.enable_live_multicast`
  - supports primary-only Multicast helper fanout
  - bounded by project projectile/job limits

- **Primary Spread/Burst aiming**
  - feature-gated by `SpellforgeDev.enable_live_spread_burst`
  - applies launch-time deterministic direction patterns
  - does not steer projectiles after launch

- **Trigger v0**
  - feature-gated by `SpellforgeDev.enable_live_trigger`
  - conservative live shape:
    - one source helper hit
    - one simple payload helper, payload Multicast v0, or payload Spread/Burst v0 when separately enabled
  - duplicate hit suppression exists
  - payload Multicast v0 is separately gated by `SpellforgeDev.enable_live_payload_multicast_v0`
  - payload Spread/Burst v0 is separately gated by `SpellforgeDev.enable_live_payload_pattern_v0`
  - nested Trigger/Timer v1 can use Trigger as the first or second stage only when `SpellforgeDev.enable_live_nested_trigger_timer_v1` is enabled

- **Timer v0**
  - feature-gated by `SpellforgeDev.enable_live_timer`
  - conservative live shape:
    - one source helper
    - one delayed payload helper, payload Multicast v0, or payload Spread/Burst v0 when separately enabled
  - uses OpenMW `async:newSimulationTimer`
  - Timer waiting is handled by OpenMW simulation time
  - payload execution remains orchestrator-bounded after the async callback
  - payload Multicast v0 uses one Timer schedule/callback to enqueue the bounded payload group
  - nested Trigger/Timer v1 can use Timer as the first or second stage only when `SpellforgeDev.enable_live_nested_trigger_timer_v1` is enabled

- **Payload Multicast v0**
  - feature-gated by `SpellforgeDev.enable_live_payload_multicast_v0`
  - supports only direct one-layer payload fanout:
    - source -> Timer -> Multicast N simple payload helpers
    - source -> Trigger -> Multicast N simple payload helpers
  - fanout is resolved from compiled emission slots/helper records and enqueued through the orchestrator
  - arbitrary nested Trigger/Timer, Chain, and recursive payload runtime remain deferred

- **Payload Spread/Burst v0**
  - feature-gated by `SpellforgeDev.enable_live_payload_pattern_v0`
  - requires payload Multicast v0
  - supports only direct one-layer payload patterns:
    - source -> Timer -> Multicast N + Spread/Burst simple payload helpers
    - source -> Trigger -> Multicast N + Spread/Burst simple payload helpers
  - applies deterministic launch-time directions and does not steer after launch

- **Nested Trigger/Timer v1**
  - feature-gated by `SpellforgeDev.enable_live_nested_trigger_timer_v1`
  - requires the relevant live Trigger and Timer gates
  - supports only:
    - source -> Timer -> Trigger -> final simple payload
    - source -> Trigger -> Timer -> final simple payload
  - maximum live nested payload depth is 2 for this milestone
  - second-stage Timer uses OpenMW async simulation timers
  - second-stage Trigger uses existing hit routing and duplicate suppression
  - execution remains bounded and orchestrator-queued
  - same-kind nesting, depth greater than 2, Chain, and arbitrary recursion remain deferred

- **Nested Final Payload Fanout v0**
  - feature-gated by `SpellforgeDev.enable_live_nested_final_fanout_v0`
  - requires nested Trigger/Timer v1 plus payload Multicast v0; final Spread/Burst also requires payload Pattern v0
  - supports only bounded final-stage fanout after mixed Trigger/Timer chains:
    - source -> Trigger -> Timer -> final Multicast simple payload helpers
    - source -> Timer -> Trigger -> final Multicast simple payload helpers
    - source -> Trigger -> Timer -> final Multicast + Spread/Burst simple payload helpers
    - source -> Timer -> Trigger -> final Multicast + Spread/Burst simple payload helpers
  - final fanout helpers are orchestrator-queued and SFP/MagExp-launched
  - Spread/Burst aiming is launch-time only
  - max live nested payload depth remains 2
  - nested behavior or Chain inside final fanout, nested Speed+/Size+, same-kind nesting, and depth greater than 2 remain deferred

- **Chain v0 targeting audit**
  - feature-gated by `SpellforgeDev.enable_live_chain_audit_v0`
  - audit-only and dry-run only; separate from live Chain payload launch
  - Chain magnitude is treated as sequential hop count, not parallel fanout
  - `Chain 3` means up to three sequential future payload launches, one hop at a time
  - classifies simple `source -> Chain -> payload` and `source -> Trigger -> Chain -> payload` plans as future runtime candidates when target context and caps are valid
  - resolves injected/mock candidates deterministically for smoke tests
  - supports `no_immediate_repeat` targeting, which excludes only the current hit target and allows A->B->A->B style bounces
  - enforces Chain hop, scan radius, candidate, target, and job caps
  - excludes caster, current hit target, invalid/dead/non-actor/different-cell/out-of-radius candidates
  - does not add actor scans, per-projectile Lua loops, post-launch steering, or Chain recursion
  - Chain with Multicast/Spread/Burst/Trigger/Timer/nested payload remains deferred

- **Chain v0 live runtime**
  - feature-gated by `SpellforgeDev.enable_live_chain_runtime_v0`
  - supports direct `source -> Chain N -> simple payload` and `source -> Trigger -> Chain N -> simple payload`
  - supports the narrow Chain payload modifier shapes:
    - `source -> Chain N -> Speed+ -> simple payload`
    - `source -> Chain N -> Size+ -> simple payload`
    - `source -> Trigger -> Chain N -> Speed+ -> simple payload`
    - `source -> Trigger -> Chain N -> Size+ -> simple payload`
  - Chain payload Speed+ also requires `SpellforgeDev.enable_live_speed_plus`
  - Chain payload Size+ also requires `SpellforgeDev.enable_live_size_plus`
  - `Chain N` launches up to N sequential payload hops, one hop per accepted hit event
  - uses `no_immediate_repeat` targeting, excluding only the current hit target and allowing A->B->A->B bounces
  - uses deterministic mock providers for smokes and a bounded real provider on discrete Chain hit/hop events when `openmw.world.activeActors` is available
  - real-provider candidates are filtered through a player-local line-of-sight raycast before selection
  - each Chain hop is orchestrator-queued, SFP/MagExp-launched, and carries continuation `userData`
  - Chain continuation `userData` and Speed+/Size+ modifier metadata coexist on modified payload launches
  - stops cleanly at max hops or when no valid target exists
  - duplicate hit suppression is scoped per cast/chain/hop/projectile identity
  - Chain with Multicast/Spread/Burst/Trigger/Timer/nested payload, Chain recursion, per-frame actor scans, per-projectile Lua loops, and post-launch steering remain deferred

- **Speed+ v1**
  - feature-gated by `SpellforgeDev.enable_live_speed_plus`
  - launch-time initial speed mutation using SFP Beta3 `data.speed`
  - optionally mirrors the bounded speed into `maxSpeed`
  - does not enable `accelerationExp`, speed-scaled damage, physics impulse, `forceVec`, or per-projectile steering

- **Size+ v0**
  - feature-gated by `SpellforgeDev.enable_live_size_plus`
  - helper-spec mutation of existing effect `area`
  - does not scale projectile mesh, hitbox, collision volume, physics impulse, or post-launch projectile state

- **Chaos budget v0**
  - dev/test-gated by `SpellforgeDev.enable_chaos_budget_v0`
  - default profile keeps the conservative bring-up caps
  - chaos profile raises selected high-fanout caps for smoke/stress coverage while preserving hard safety rails
  - effective chaos caps include Multicast/payload fanout 16, projectiles per cast 64, nested payload jobs 64, jobs per tick 24, and live helper launch density 4 per simulation update window
  - Chain remains sequential; Chain branch/fanout budget is reported as 1 and Chain+Multicast/Pattern remains deferred
  - over-budget spells reject before unsafe enqueue/launch and are visible in runtime stats

- **SFP/MagExp Beta boundary support**
  - centralized `global/sfp_adapter.lua`
  - forwards supported launch metadata:
    - `userData`
    - `muteAudio`
    - `muteLight`
    - `speed`
    - `maxSpeed`
    - `accelerationExp`
    - `areaVfxRecId`
    - `areaVfxScale`
    - `vfxRecId`
    - `boltModel`
    - `hitModel`
    - `excludeTarget`
    - `forcedEffects`
  - Spellforge does not synthesize area VFX from bolt VFX

### Still not live-supported

- arbitrary nested payload runtime beyond gated mixed depth-2 Trigger/Timer paths
- same-kind Trigger/Timer nesting
- depth greater than 2
- nested behavior inside final fanout
- Chain runtime beyond the narrow direct/Trigger simple payload and Speed+/Size+ payload-modifier shapes
- Homing/Bounce/Gravity runtime
- Speed+ acceleration behavior
- Speed+ damage scaling
- post-launch projectile mutation
- per-projectile Lua update loops
- per-projectile actor scans
- visible Noita wand/deck UI

### Important current truth

The 25-helper performance stress fixture is a **logical orchestrator fast-forward stress test**. It is useful for testing plan shape, helper materialization, bounded fanout, and queue behavior, but it is **not proof of real delayed nested Timer gameplay**.

The next recommended milestone should stay audit-led and feature-gated, such as another narrowly bounded nested-runtime slice or the next Chain payload policy decision.

---

## Working Foundation

The 2.2b intercept-dispatch path is still the baseline runtime foundation.

The current live path remains:

1. player cast input
2. animation text-key intercept
3. vanilla cast-success authorization
4. global dispatch through SFP/MagExp

When live 2.2c is enabled, eligible recipes can route through the 2.2c helper/orchestrator path. Non-qualifying recipes or safe pre-enqueue failures fall back to the 2.2b root-effect dispatch path. Post-enqueue live failures do not fall back, to avoid duplicate effects.

---

## Runtime Architecture

Desired runtime pipeline:

```text
effect list
-> parser
-> canonical recipe id
-> plan cache
-> emission slot allocation
-> helper spec generation
-> helper record materialization
-> orchestrator jobs
-> SFP/MagExp launch
-> SFP/MagExp hit event
-> helper hit routing
-> Trigger/Timer payload enqueue
-> payload helper launch
```

Important identity model:

- **helper record** = effect/helper identity
- **SFP userData** = cast/emission/job identity
- **orchestrator** = bounded runtime execution identity

Core performance rule:

Compile/evaluate spell structure once. Encode behavior into helper records and launch fields where possible. Let SFP/OpenMW handle projectile flight and collision. Use Lua only for discrete launch, hit, timer, and payload jobs. Do not add per-projectile Lua brains.

---

## Current Feature Flags

All normal gameplay flags default to `false`.

Known dev/live flags:

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

The live runtime is deliberately opt-in while 2.2c is hardened.

---

## Known Limits

Current shared limits include:

- `MAX_RECURSION_DEPTH = 3`
- `MAX_PROJECTILES_PER_CAST = 32`
- `MAX_CHAIN_HOPS = 5`
- `MAX_SCAN_RADIUS = 2048`
- `MAX_CHAIN_AUDIT_HOPS = 5`
- `MAX_CHAIN_TARGETS_PER_HOP = 1`
- `MAX_CHAIN_SCAN_RADIUS = 1024`
- `MAX_CHAIN_SCAN_CANDIDATES = 16`
- `MAX_CHAIN_JOBS_PER_CAST = 5`
- `MAX_JOBS_PER_TICK = 16`

Chain-related limits guard Chain audit/dry-run probes, the narrow direct/Trigger simple-payload Chain v0 runtime, and the bounded real target provider.

---

## Current Deferred Work

### Nested payloads

The parser/slot allocator can represent nested payload structures. The live Trigger/Timer selectors now accept direct payload Multicast when `SpellforgeDev.enable_live_payload_multicast_v0` is enabled, direct payload Spread/Burst when `SpellforgeDev.enable_live_payload_pattern_v0` is also enabled, the narrow opposite-kind nested Trigger/Timer v1 shape when `SpellforgeDev.enable_live_nested_trigger_timer_v1` is enabled, and bounded final-stage fanout when `SpellforgeDev.enable_live_nested_final_fanout_v0` is enabled. They still reject Chain, same-kind nesting, depth greater than 2, nested behavior inside final fanout, and arbitrary recursive payload runtime.

Not live-supported yet:

- Trigger inside Trigger
- Timer inside Timer
- nested behavior inside final fanout
- nested Speed+/Size+
- arbitrary recursive payload chains

Nested payload audit remains the preflight for future runtime expansion.

### Chain

Simple direct Chain and Trigger->Chain live payload launch now exists behind `SpellforgeDev.enable_live_chain_runtime_v0`. Chain payloads can also use one Speed+ or Size+ modifier before a simple final payload when the matching `SpellforgeDev.enable_live_speed_plus` or `SpellforgeDev.enable_live_size_plus` flag is enabled. The audit-only resolver still classifies candidates and resolves deterministic mock sequential hops separately from runtime, and the live runtime can fall back to a bounded real target provider when no injected smoke provider is present.

Rules for future Chain:

- no actor scans per projectile per frame
- only resolve targets inside bounded chain-hop jobs
- enforce `MAX_CHAIN_HOPS`
- enforce `MAX_SCAN_RADIUS`
- enforce `MAX_CHAIN_AUDIT_HOPS`, `MAX_CHAIN_TARGETS_PER_HOP`, `MAX_CHAIN_SCAN_CANDIDATES`, and `MAX_CHAIN_JOBS_PER_CAST`
- enforce per-cast scan/job budget
- no synchronous recursive launches
- all chain hops must go through the orchestrator

Still deferred:

- Chain with Multicast/Spread/Burst
- Chain with Trigger/Timer payloads
- Chain with both Speed+ and Size+ on the same payload branch
- Chain recursion or Chain->Chain composition
- Chain inside mixed nested Trigger/Timer or nested final fanout
- real broad actor scans
- post-launch steering

### VFX

Spellforge forwards explicit impact/flight presentation metadata where available.

Current boundary policy:

- pass explicit `areaVfxRecId` if present
- pass explicit `areaVfxScale` if present
- pass bolt `vfxRecId` separately
- never promote bolt `vfxRecId` into area VFX override
- if no explicit area VFX exists, pass nil and allow SFP/effect defaults to handle fallback

Suspected upstream SFP issue remains possible if SFP collision code treats bolt VFX as an area VFX override.

### Speed+

Implemented v1 behavior:

- `data.speed`
- bounded initial speed mutation
- optional `maxSpeed`

Deferred:

- `accelerationExp`
- force vectors
- damage scaling based on velocity
- post-launch speed mutation
- per-frame steering

### Size+

Implemented v0 behavior:

- helper effect `area` mutation

Deferred:

- projectile mesh scaling
- projectile collision scaling
- hitbox scaling
- physics impulse scaling
- post-launch projectile mutation

---

# Milestone History / Chronological Notes

The section below is a historical implementation ledger. Older entries may say “not wired into live casting yet” because that was true at the time the milestone landed. Later milestones supersede earlier limitations.

## 2.2c.1 — Parser Skeleton

Effect-list grouping and binding validation were added.

Historical status:

- not wired into live 2.2b casting at the time
- replaced graph-oriented assumptions with ordered effect-list parsing as the intended direction

## 2.2c.2 — Canonical Effect-List Hashing

Canonical recipe ID generation was added.

Includes:

- operator params
- compiler-version salt
- normalized effect-list serialization

Historical status:

- not wired into live 2.2b casting at the time

## 2.2c.3 — Plan Cache Shape

Compiled effect-list plan cache shape was added.

Historical status:

- staged-only in-memory plan cache at the time
- not wired into live 2.2b casting yet

## 2.2c.4 — Emission Slot Allocation

Per-emission helper-slot allocation skeleton was added.

Historical status:

- metadata-only at the time
- no helper records yet
- not wired into live 2.2b casting yet

Current relevance:

- emission slots now carry primary/payload identity, parent slot IDs, source postfix opcode, Trigger/Timer source IDs, prefix/postfix metadata, and payload bindings.

## 2.2c.5 — Helper Record Spec Generation

Helper record spec generation was added.

Historical status:

- metadata-only at the time
- no live helper records yet
- not wired into live 2.2b casting yet

Current relevance:

- helper specs preserve routing metadata and presentation metadata.
- Spellforge does not synthesize area VFX from bolt VFX.

## 2.2c.6 — Helper Record Materialization

Helper-record materialization was added in staged/dev smoke paths.

Properties:

- creates internal helper spell records
- does not add helper records to the player spellbook
- preserves recipe/slot/helper mapping

Historical status:

- not wired into live 2.2b casting at the time

## 2.2c.7 — Orchestrator Skeleton

Central orchestrator/job queue skeleton was added.

Historical status:

- dummy jobs only at first
- no opcode execution
- no SFP launch
- not wired into live 2.2b casting at the time

Current relevance:

- live helper jobs, Trigger payload jobs, and Timer payload jobs now run through the orchestrator.

## 2.2c.8 — Dev Simple-Emitter Launch

Dev-only simple-emitter helper launch path was added behind `SpellforgeDev.enable_dev_launch`.

Proved:

- one helper-record SFP launch
- hit routing back to recipe ID + slot ID

Historical limitations:

- did not execute opcodes
- did not replace live 2.2b dispatch

## 2.2c.9 — Dev Multicast Simple-Emitter Fanout

Dev-only Multicast simple-emitter fanout was added behind `SpellforgeDev.enable_dev_launch`.

Proved:

```text
Multicast x3 -> Fire Damage
```

Materializes:

- three helper records
- three dev launch jobs
- three SFP launches
- distinct slot IDs

Historical limitations:

- did not implement Trigger/Timer/Chain/Spread/Burst runtime
- did not replace live 2.2b dispatch

## 2.2c.10 — Dev Timer Runtime

Dev-only Timer runtime was added behind `SpellforgeDev.enable_dev_launch`.

Proved:

```text
Multicast x2 -> Fire Damage -> Timer 1.0 -> Frost Damage
```

Behavior:

- launches source helpers
- queues delayed Timer payload jobs
- resolves Timer payload at a predicted travel endpoint or local-raycast-clamped position
- launches Frost helpers from computed resolution point
- routes Frost hits back to slot IDs

Historical limitations:

- exact projectile speed matching remained TODO
- did not implement Trigger/Chain/Spread/Burst runtime
- did not replace live 2.2b dispatch

Current note:

- live Timer v0 now uses OpenMW async simulation timers for gameplay delay.
- dev stress/fast-forward Timer behavior should not be confused with real gameplay delay.

## 2.2c.11 — Dev Trigger Runtime

Dev-only Trigger runtime was added behind `SpellforgeDev.enable_dev_launch`.

Proved:

```text
Fire Damage -> Trigger -> Frost Damage
```

Also tested cardinality for:

```text
Multicast x3 -> Fire Damage -> Trigger -> Frost Damage
```

Historical limitations:

- did not implement Chain/Spread/Burst runtime
- did not replace live 2.2b dispatch

## 2.2c.12 — Dev Runtime Consolidation

Shared `global/dev_runtime.lua` helpers consolidated:

- helper SFP launch
- helper-hit metadata routing
- payload job enqueueing
- payload launch context validation

No new opcode behavior was added in this milestone.

## 2.2c.13 — Dev Spread Aiming

Dev-only Spread aiming was added behind `SpellforgeDev.enable_dev_launch`.

Proved:

```text
Spread -> Multicast x3 -> Fire Damage
```

Behavior:

- launches three helper records
- deterministic forward-cone directions
- routes hits back to distinct slot IDs

Historical Spread mapping:

- preset 1-4 maps to world-up yaw side angles 10/15/22/30 degrees

## 2.2c.14 — Dev Burst Aiming

Dev-only Burst aiming was added behind `SpellforgeDev.enable_dev_launch`.

Proved:

```text
Burst -> Multicast x5 -> Fire Damage
```

Behavior:

- launches five helper records
- deterministic center-plus-ring directions
- routes hits back to distinct slot IDs

Historical Burst mapping:

- Burst `count` preserved as pattern-intensity metadata
- Multicast owns emission count
- ring angle uses a bounded mapping from Burst count

## SFP v1.7 Beta 2 / MagExp v2.0 Adaptation

A centralized `global/sfp_adapter.lua` boundary and dev projectile registry were added.

Added/probed:

- `launchSpell` projectile returns
- projectile ID derivation
- helper spell ID hit-routing fallback
- nil-safe MagicHit telemetry fields
- `getSpellState`
- `detonateSpellAtPos`
- `applySpellToActor`
- `emitProjectileFromObject`

Historical note:

- this milestone did not add live Chain/Homing/Bounce/Speed+/Size+ runtime.
- Speed+ and Size+ were added later.

## 2.2c.15 — SFP Beta Compatibility / userData

Helper launches now attach compact Spellforge `userData` cookies through `shared/sfp_userdata.lua`.

Hit routing prefers:

1. valid `payload.userData`
2. helper-record spell ID fallback

Also added:

- `muteAudio` pass-through
- `muteLight` pass-through
- small 2.2b observability cookie support

Still future at the time:

- `itemRequirements`
- `forcedEffects`
- `excludeTarget`

## Dev Helper-Hit Idempotency

Dev helper-hit routing gained explicit idempotency for payload scheduling.

Implemented:

- projectile registry `first_hit` / `hit_key`
- Trigger payload enqueue per-active-run keys
- Timer launch-time idempotency keys

Purpose:

- duplicate SFP hit events or watcher-level duplicate logs should not enqueue duplicate payload jobs

## Runtime Launch/Hit Seams

Reusable runtime launch/hit seams were added:

- `global/runtime_launch.lua`
- `global/runtime_hits.lua`

Responsibilities:

- helper SFP launch normalization
- projectile registration
- helper hit resolution
- telemetry normalization
- hit idempotency result shaping

## 2.2c.16 — Live Bridge

A feature-gated live simple-helper dispatch path was added in `global/live_simple_dispatch.lua`.

Gate:

- `SpellforgeDev.enable_live_2_2c_runtime`

Behavior:

- eligible simple non-payload casts route through:
  - `plan_cache`
  - `helper_records`
  - `orchestrator`
  - SFP/MagExp helper launch
- uses Spellforge `userData` hit identity
- returns distinct `compiled_spellforge_2_2c_helper` dispatch results

Fallback policy:

- non-qualifying or pre-enqueue failures can fall back to 2.2b root-only `real_effects`
- post-enqueue live failures do not fallback, to avoid duplicate effects

Historical limitation:

- this milestone did not enable live Trigger, Timer, Chain, Speed+, or Size+

## 2.2c.17 — Live Runtime Hardening

Runtime counters and smoke diagnostics were added for:

- live 2.2c helper qualification
- fallback
- suppression
- plan/helper reuse
- orchestrator queue/job lifecycle
- SFP launch results
- `userData` vs helper spell ID hit routing

Historical limitation:

- this milestone did not enable live Multicast, Trigger, Timer, Chain, Speed+, or Size+

## 2.2c.18 — Live Multicast Primary Fanout

Feature-gated live primary-only Multicast support was added.

Gates:

- `SpellforgeDev.enable_live_2_2c_runtime`
- `SpellforgeDev.enable_live_multicast`

Behavior:

- qualifying Multicast fanout enqueues all primary helper slots through the bounded orchestrator
- shared `cast_id`
- per-emission SFP `userData`
- per-emission `slot_id`
- `emission_index`
- `fanout_count`

Still not enabled by this milestone:

- live Trigger
- live Timer
- live Chain
- Speed+
- Size+
- Spread/Burst

## 2.2c.19 — Live Spread/Burst Primary Aiming

Feature-gated live primary-only Spread/Burst support was added.

Gates:

- `SpellforgeDev.enable_live_2_2c_runtime`
- `SpellforgeDev.enable_live_multicast`
- `SpellforgeDev.enable_live_spread_burst`

Behavior:

- applies launch-pattern logic during helper job preparation
- each primary helper receives a pattern-adjusted launch direction
- preserves shared `cast_id`
- preserves per-emission SFP `userData`
- preserves scalar pattern metadata

Still not enabled by this milestone:

- live Trigger
- live Timer
- live Chain
- Speed+
- Size+

## 2.2c.20 — Live Trigger Payload v0

Feature-gated live Trigger support was added.

Gate:

- `SpellforgeDev.enable_live_trigger`

Supported conservative shape:

```text
source helper hit -> one payload helper
```

Behavior:

- source helper hits resolve through SFP `userData` or helper spell ID fallback
- exactly one bounded Trigger payload helper job is enqueued through the orchestrator
- source/payload identity is carried in compact `userData`
- duplicate hit payload launches are suppressed

Still not enabled:

- live Timer in the same recipe
- Chain
- Speed+
- Size+
- payload Multicast (later added narrowly in 2.2c.27)
- payload Spread/Burst (later added narrowly in 2.2c.28)
- arbitrary recursive Trigger behavior

## 2.2c.21 — Live Timer Payload v0

Feature-gated live Timer support was added.

Gate:

- `SpellforgeDev.enable_live_timer`

Supported conservative shape:

```text
source helper -> one delayed payload helper
```

Behavior:

- schedules one bounded delayed payload helper
- enforces depth/expiry guards
- launches payload helper through SFP
- carries source/payload Timer `userData`
- includes post-delay smoke coverage

Historical limitation:

- original v0 still needed clearer real gameplay delay semantics, later corrected by 2.2c.25

Still not enabled:

- Chain
- Speed+
- Size+
- payload Multicast (later added narrowly in 2.2c.27)
- payload Spread/Burst (later added narrowly in 2.2c.28)
- Trigger+Timer combinations
- arbitrary recursive Timer behavior

## 2.2c.22 — Live Speed+ v1

Speed+ was upgraded from safe-rejection groundwork to feature-gated launch-time mutation.

Gate:

- `SpellforgeDev.enable_live_speed_plus`

Behavior:

- computes bounded speed value
- passes `data.speed` to SFP at launch
- records compact Speed+ metadata in `userData`
- preserves orchestrator-bounded dispatch
- rejects unsupported payload/Chain/Size+ combinations

Does not enable:

- `accelerationExp`
- speed-scaled damage
- physics impulse
- `forceVec`
- per-projectile Lua steering

## 2.2c.23 — Live Size+ v0

Feature-gated helper-spec Size+ support was added.

Gate:

- `SpellforgeDev.enable_live_size_plus`

Behavior:

- computes bounded scalar mutation during helper-spec preparation
- mutates existing helper effect `area`
- records compact Size+ metadata in `userData`
- preserves orchestrator-bounded dispatch
- rejects unsupported payload/Chain/Speed+ combinations

Does not enable:

- Chain
- physics impulse
- per-projectile Lua scaling
- arbitrary post-launch projectile mutation
- projectile mesh/hitbox/collision scaling

## 2.2c.24 — Timer/VFX Semantics Fix

Timer/VFX semantics were tightened.

Timer changes:

- live Timer wait jobs carry simulation-time due seconds in addition to diagnostic tick fields
- Timer smoke separates accumulated-simulation-delay verification from deterministic fast-forward coverage
- Timer source detonation remains blocked until current projectile position/cell are available

VFX boundary changes:

- SFP launch boundary forwards impact/flight presentation metadata:
  - `areaVfxRecId`
  - `areaVfxScale`
  - `vfxRecId`
  - `boltModel`
  - `hitModel`
- Spellforge does not treat bolt `vfxRecId` as an area VFX fallback

Clarification:

- this milestone did not change existing Size+ v0 behavior
- this milestone did not enable nested payloads, Chain, new Speed+ acceleration behavior, `forceVec`/Gravity, Bounce, or per-projectile Lua updates

## 2.2c.25 — Live Timer Async Simulation Delay

Live Timer gameplay scheduling was corrected to use OpenMW reliable simulation timers.

Mechanism:

- `async:newSimulationTimer`
- registered callback: `spellforge_live_timer_due`

Behavior:

- Timer waiting is handled by OpenMW simulation time
- payload execution remains orchestrator-bounded after the callback
- live Timer smoke is phased
- smoke proves:
  - pending-under-delay
  - no immediate payload
  - exactly one callback payload
  - pending timer clears after callback

Clarification:

- performance stress remains explicitly logical fast-forward
- performance stress is not a real delay test

Still not enabled:

- arbitrary nested payloads
- Chain
- new Size+ behavior
- new Speed+ acceleration behavior
- new VFX/SFP behavior
- per-projectile Spellforge updates

---

## 2.2c.27 - Payload Multicast v0 Runtime

Payload Multicast v0 runtime is enabled behind `SpellforgeDev.enable_live_payload_multicast_v0`.

Supported shapes:

- `Source -> Timer -> Multicast N simple payload helpers`
- `Source -> Trigger -> Multicast N simple payload helpers`

Runtime behavior:

- one Timer source schedule/callback can enqueue multiple payload jobs
- one accepted Trigger source hit can enqueue multiple payload jobs
- payload fanout is bounded by shared projectile/fanout limits
- every payload helper launches through orchestrator jobs and the existing SFP/MagExp launch path
- duplicate Timer schedules and duplicate Trigger hits suppress the whole payload group

Still deferred:

- arbitrary nested Trigger/Timer runtime
- Chain
- payload Speed+/Size+ runtime mutation
- per-projectile Lua loops
- actor scans

---

## 2.2c.28 - Payload Spread/Burst v0 Runtime

Payload Spread/Burst v0 runtime is enabled behind `SpellforgeDev.enable_live_payload_pattern_v0`, and requires `SpellforgeDev.enable_live_payload_multicast_v0`.

Supported shapes:

- `Source -> Timer -> Multicast N + Spread simple payload helpers`
- `Source -> Timer -> Multicast N + Burst simple payload helpers`
- `Source -> Trigger -> Multicast N + Spread simple payload helpers`
- `Source -> Trigger -> Multicast N + Burst simple payload helpers`

Runtime behavior:

- one Timer source schedule/callback can enqueue multiple patterned payload jobs
- one accepted Trigger source hit can enqueue multiple patterned payload jobs
- payload pattern fanout is bounded and orchestrator-queued
- Spread/Burst aiming is launch-time only
- duplicate Timer schedules and duplicate Trigger hits still suppress the whole payload group

Still deferred:

- arbitrary nested Trigger/Timer runtime
- Chain
- payload Speed+/Size+ runtime mutation
- post-launch steering
- per-projectile Lua loops
- actor scans

---

## 2.2c.29 - Nested Trigger/Timer v1 Runtime

Nested Trigger/Timer v1 runtime is enabled behind `SpellforgeDev.enable_live_nested_trigger_timer_v1`, and still requires the live Trigger and Timer gates.

Supported shapes:

- `Source -> Timer -> Trigger -> final simple payload`
- `Source -> Trigger -> Timer -> final simple payload`

Runtime behavior:

- maximum live nested payload depth is 2 for this milestone
- first-stage and second-stage waits/hits stay separated
- second-stage Timer uses OpenMW async simulation timers
- second-stage Trigger uses existing hit routing and duplicate suppression
- intermediate and final helpers are launched through bounded orchestrator jobs and the existing SFP/MagExp path
- direct payload Multicast/Spread/Burst v0 remains supported for depth-1 payload groups

Still deferred:

- same-kind Trigger->Trigger and Timer->Timer nesting
- depth greater than 2
- nested fanout/pattern under nested Trigger/Timer
- nested Speed+/Size+
- Chain
- post-launch steering
- per-projectile Lua loops
- actor scans

---

## 2.2c.29a - Nested Trigger/Timer v1 Qualification and Stage Handoff Fix

Nested Trigger/Timer v1 qualification now uses the full recipe effect list to preselect mixed Trigger+Timer plans before the simple Trigger/Timer v0 dispatchers can claim them. The compiled slot/helper qualifier remains the authority for accepting only the two v1 shapes.

Fix details:

- `Trigger -> Timer` and `Timer -> Trigger` candidates are routed into the nested v1 qualifier even when root plan bounds only describe the first-stage operator
- rejected nested candidates now report compact qualifier diagnostics, including stage kinds, slot IDs, depth, payload flags, and deferred Chain/fanout/pattern state
- rejection counters now fire for depth/fanout paths once the nested qualifier is entered
- successful paths still preserve root/intermediate/final stage identity through `userData`
- root and nested Timer stages continue to use OpenMW async simulation timers
- Trigger duplicate suppression remains per cast/source/stage

Still deferred:

- same-kind Trigger->Trigger and Timer->Timer nesting
- depth greater than 2
- nested fanout/pattern under nested Trigger/Timer
- nested Speed+/Size+
- Chain

Live smoke re-run confirmed the in-game handoff after this qualification fix.

---

## 2.2c.30 - Nested Final Payload Fanout v0 Runtime

Nested final payload fanout v0 is enabled behind `SpellforgeDev.enable_live_nested_final_fanout_v0`, and also requires the nested Trigger/Timer v1, payload Multicast v0, and relevant Trigger/Timer gates. Final Spread/Burst patterns additionally require `SpellforgeDev.enable_live_payload_pattern_v0`.

Supported shapes:

- `Source -> Trigger -> Timer -> Multicast N final simple payload helpers`
- `Source -> Timer -> Trigger -> Multicast N final simple payload helpers`
- `Source -> Trigger -> Timer -> Multicast N + Spread/Burst final simple payload helpers`
- `Source -> Timer -> Trigger -> Multicast N + Spread/Burst final simple payload helpers`

Runtime behavior:

- max live nested payload depth remains 2
- first-stage and second-stage Trigger/Timer conditions remain separated
- final fanout is resolved from compiled slot/helper metadata
- final fanout jobs are orchestrator-queued and launched through the existing SFP/MagExp path
- final Spread/Burst aiming is deterministic and launch-time only
- duplicate Trigger hits and Timer schedules suppress the final fanout group
- nested final fanout stats count qualification, jobs, pattern jobs, duplicate suppression, and cap/disabled rejections

Still deferred:

- same-kind Trigger->Trigger and Timer->Timer nesting
- depth greater than 2
- nested Trigger/Timer/Chain behavior inside final fanout
- nested Speed+/Size+
- Chain
- post-launch steering
- per-projectile Lua loops
- actor scans

---

## 2.2c.31 - Chain v0 Targeting Audit and Dry-Run Resolver

Added an audit-only Chain targeting layer behind `SpellforgeDev.enable_live_chain_audit_v0`.

What exists now:

- simple `Source -> Chain -> final simple payload` plans can be classified as bounded future runtime candidates
- target resolution accepts injected/mock candidate lists for deterministic smoke coverage
- resolver excludes caster, original source target, invalid/dead/non-actor/untargetable/different-cell/out-of-radius candidates
- target ordering is deterministic by distance, then stable target id
- hop, target, scan radius, candidate, and job caps are enforced
- Chain audit stats count plan audits, target resolution, future candidates, runtime deferral, and rejection categories
- live dispatch still rejects/defer Chain; no Chain payload jobs are enqueued

Still deferred:

- live Chain payload launch
- real actor scans
- Chain recursion
- Chain with Multicast/Spread/Burst
- Chain with Trigger/Timer
- Chain inside nested payload or final fanout
- per-projectile Lua loops
- post-launch steering

---

## 2.2c.31a - Chain N Hop Semantics Audit and Dry-Run Resolver

Updated Chain audit semantics so Chain magnitude means sequential max hop count rather than parallel fanout.

What exists now:

- `Chain N` means up to N sequential dry-run target decisions
- `Chain 3` can simulate three future chained payload launches, one hop at a time
- `no_immediate_repeat` is the default targeting mode
- `no_immediate_repeat` excludes only the current hit target, so A->B->A->B is allowed when those are the nearest valid choices
- direct `Source -> Chain 3 -> payload` can audit as a future runtime candidate
- `Source -> Trigger -> Chain 3 -> payload` can audit as a future runtime candidate
- dry-run hop simulation reports selected targets, completed hops, stop reason, and would-be job counts
- smoke coverage uses injected/mock candidates, including deterministic A->B->A->B bounce coverage

Still deferred:

- live Chain payload launch
- real actor scans
- Chain recursion
- Chain with Multicast/Spread/Burst
- Chain with Trigger/Timer payloads
- Chain inside mixed nested Trigger/Timer or final fanout
- per-projectile Lua loops
- post-launch steering

---

## 2.2c.32 - Chain v0 Live Runtime - Direct/Trigger Simple Payload

Promoted the audited Chain hop model into a narrow live runtime behind `SpellforgeDev.enable_live_chain_runtime_v0`.

What exists now:

- direct `Source -> Chain N -> simple payload` runtime works behind the feature/dev flag
- `Source -> Trigger -> Chain N -> simple payload` runtime works behind the feature/dev flag
- `Chain N` means up to N sequential payload launches, one hop at a time
- `no_immediate_repeat` excludes only the current hit target, so A->B->A->B bouncing is allowed
- each hop is started by an accepted source or chained-payload hit event
- Chain payload continuation uses `userData` hit routing with cast, chain, hop, source, and payload identity
- Chain hops are bounded, orchestrator-queued, and SFP/MagExp-launched
- duplicate hit suppression works per cast/chain/hop/projectile identity
- Chain stops at `max_hops` or when no valid target exists
- Chain audit/dry-run remains available separately behind `SpellforgeDev.enable_live_chain_audit_v0`

Still deferred:

- Chain with Multicast/Spread/Burst
- Chain with Trigger/Timer payloads
- Chain recursion or Chain->Chain composition
- Chain inside mixed nested Trigger/Timer or nested final fanout
- actor scans per projectile per frame
- per-projectile Lua loops
- post-launch steering

---

## 2.2c.33 - Chain Real Target Provider + Gameplay Smoke

Added a bounded real target provider for the existing simple Chain runtime.

What exists now:

- Chain runtime still uses injected/mock candidates first for deterministic smoke coverage
- when no injected provider is supplied, Chain asks a real provider backed by `openmw.world.activeActors`
- the real provider runs only on discrete Chain source/hop hit events
- candidates are capped by `MAX_CHAIN_SCAN_RADIUS`, `MAX_CHAIN_SCAN_CANDIDATES`, and `MAX_CHAIN_VERTICAL_DELTA` using actor base positions
- candidates then pass through a bounded player-local LOS raycast gate, so walls/floors/ceilings can reject otherwise valid nearby actors
- real Chain payload bolts launch between raised actor aim points so same-floor close targets remain visible
- non-actor hit routes are stopped before they can advance Chain, which prevents wall/static collisions from forking extra hops
- caster/current-target exclusion and `no_immediate_repeat` remain enforced by the resolver
- the provider returns real candidates when supported, or reports `chain_target_provider_unavailable` safely
- Chain stops cleanly at max hops, no valid target, or unavailable provider
- provider stats report real/mock attempts, availability, returned candidates, cap/radius use, and selection source

Still deferred:

- Chain with Multicast/Spread/Burst
- Chain with Trigger/Timer payloads
- Chain recursion or Chain->Chain composition
- Chain inside mixed nested Trigger/Timer or nested final fanout
- hostility/friendly-fire filtering policy
- actor scans per projectile per frame
- per-projectile Lua loops
- post-launch steering

Manual gameplay smoke:

- press `L` for the dedicated manual Chain real-provider probe; live Chain target selection now uses a strict same-floor vertical tolerance, LOS raycasts, and raised aim points
- use `Fire Damage -> Trigger -> Chain 3 -> Frost Damage`
- place at least two valid nearby actors
- hit actor A with the source helper
- expect `SPELLFORGE_CHAIN_PROVIDER_REAL_OK`, `SPELLFORGE_CHAIN_LOS_REQUESTED`, `SPELLFORGE_CHAIN_LOS_LOCAL_RESULT`, `SPELLFORGE_CHAIN_LOS_RESULT`, `SPELLFORGE_CHAIN_REAL_TARGET_SELECTED`, `SPELLFORGE_CHAIN_HOP_ENQUEUED`, and `SPELLFORGE_CHAIN_HOP_PAYLOAD_OK`
- if actor B is hit and actor A remains valid/nearby, `no_immediate_repeat` may bounce back toward A
- Chain should stop at hop 3, `no_valid_chain_target`, or `no_visible_chain_target`

---

## 2.2c.34 - Chain Payload Modifiers v0 - Speed+/Size+ on Chained Payloads

Extended the narrow live Chain runtime so simple chained payload helpers can carry one launch/spec modifier.

What exists now:

- direct `Fire Damage -> Chain 3 -> Speed+ -> Frost Damage` works behind Chain runtime and Speed+ gates
- direct `Fire Damage -> Chain 3 -> Size+ -> Frost Damage` works behind Chain runtime and Size+ gates
- `Fire Damage -> Trigger -> Chain 3 -> Speed+ -> Frost Damage` works behind Trigger, Chain runtime, and Speed+ gates
- `Fire Damage -> Trigger -> Chain 3 -> Size+ -> Frost Damage` works behind Trigger, Chain runtime, and Size+ gates
- Speed+ reuses the existing bounded launch-time `data.speed` / `maxSpeed` mutation path
- Size+ reuses the existing bounded helper-spec effect `area` mutation path before helper records are materialized
- the modifier applies to every chained payload hop
- Chain target selection is unchanged: `no_immediate_repeat` excludes only the current hit target
- Chain continuation `userData` and modifier metadata coexist on the same payload launch
- target acquisition still happens only on discrete Chain hit/hop events
- Chain work remains orchestrator-queued and bounded

Still deferred:

- Chain with Multicast/Spread/Burst
- Chain with Trigger/Timer payloads
- Chain recursion or Chain->Chain composition
- Chain with both Speed+ and Size+ on the same payload branch
- Chain inside mixed nested Trigger/Timer or nested final fanout
- actor scans per projectile per frame
- per-projectile Lua loops
- post-launch steering

Manual gameplay smoke:

- use `Fire Damage -> Trigger -> Chain 3 -> Speed+ -> Frost Damage` or `Fire Damage -> Trigger -> Chain 3 -> Size+ -> Frost Damage`
- place or find at least two valid nearby actors
- hit actor A with the source helper
- expect Chain to select actor B; if actor B is hit and actor A remains valid/nearby, `no_immediate_repeat` may bounce back toward A
- expected markers include `SPELLFORGE_CHAIN_MODIFIER_QUALIFIED`, `SPELLFORGE_CHAIN_REAL_TARGET_SELECTED`, `SPELLFORGE_CHAIN_SPEED_PLUS_APPLIED` or `SPELLFORGE_CHAIN_SIZE_PLUS_APPLIED`, `SPELLFORGE_CHAIN_MODIFIED_HOP_ENQUEUED`, `SPELLFORGE_CHAIN_MODIFIED_PAYLOAD_OK`, and a max-hop/no-target stop

---

## 2.2c.35 - Chaos Budget Pass - Raise Safe Caps and Add High-Fanout Stress Smokes

Added a dev-only chaos budget profile for bounded Noita-like stress testing without enabling new unsupported semantics.

What exists now:

- `SpellforgeDev.enable_chaos_budget_v0` enables the chaos/dev profile for smoke and test probes
- default profile keeps bring-up caps for normal feature-gated runtime
- chaos profile raises selected caps:
  - projectiles per cast: 32 -> 64
  - payload/direct fanout: 8 -> 16
  - nested final fanout: 8 -> 16
  - nested payload job budget: 32 -> 64
  - jobs per orchestrator tick: 16 -> 24
  - live helper launches per simulation update window: 8 default, 4 chaos pacing cap
  - Chain scan candidates: 16 -> 24
- hard parser/runtime safety rails remain above the chaos profile and still reject over-budget recipes
- high-fanout smokes cover direct Multicast, Trigger payload Multicast, Timer payload Multicast, Trigger/Timer payload Spread/Burst, and mixed nested final fanout
- live helper launches have a separate density throttle so a high-fanout queue is chunked across real simulation update windows instead of allowing every launch job through the same drain pass
- queued overflow keeps the originating launch-density cap, so chaos high-fanout payloads continue draining at the chaos pacing cap even when the executor resumes them on later updates
- the chaos smoke harness spaces high-fanout probe phases slightly and polls queued jobs to completion instead of force-draining every chunk in the same callback
- queue/job/projectile/live-launch observations are recorded in runtime stats through `chaos_budget_*` counters
- `SPELLFORGE_CHAOS_BUDGET_PROFILE`, `SPELLFORGE_CHAOS_BUDGET_LIMITS`, `SPELLFORGE_CHAOS_BUDGET_REJECTED`, `SPELLFORGE_LIVE_LAUNCH_DENSITY_THROTTLED`, and `SPELLFORGE_CHAOS_STRESS_OK` mark profile use, caps, rejections, live-launch chunking, and stress success
- Chain simple runtime remains unchanged under the chaos profile
- Chain target acquisition remains bounded to discrete hit/hop events

Still deferred:

- Chain with Multicast/Spread/Burst
- Chain with Trigger/Timer payloads
- Chain recursion or Chain->Chain composition
- Chain inside mixed nested Trigger/Timer or nested final fanout
- arbitrary unbounded recursion
- actor scans per projectile per frame
- per-projectile Lua loops
- post-launch steering

Manual gameplay smoke:

- press `Numpad .` for the chaos high-fanout budget stress suite
- manual shapes to sanity-check include `Multicast 16 Fireball`, `Fireball -> Trigger -> Multicast 16 Frostball`, `Fireball -> Timer 1s -> Multicast 16 Frostball`, `Fireball -> Trigger -> Multicast 16 + Burst Frostball`, and `Fireball -> Trigger -> Frostball -> Timer 1s -> Multicast 16 Shock`
- expected behavior: large visible output, queue drains, duplicate suppression remains active, over-budget recipes reject clearly, and Chain+Multicast remains deferred

---

## SFP Beta3 VFX Audit Note

Projectile collision may call `detonateSpellAtPos` with `data.areaVfxRecId` or possibly `data.vfxRecId`.

Potential upstream issue:

- if bolt VFX is used as an area VFX override
- and SFP resolves area overrides through Static records
- AoE impact VFX can fail instead of falling back to the MagicEffect `areaStatic`

Spellforge policy:

- pass a valid `areaVfxRecId` when available
- do not synthesize `areaVfxRecId` from bolt VFX
- keep bolt `vfxRecId` separate

Recommended SFP-side behavior:

- pass only `data.areaVfxRecId` as the area VFX override
- pass nil when it is absent
- keep bolt `vfxRecId` separate
- allow default effect area static fallback when no explicit area override exists

---

## Smoke / Dev Harness Notes

Staged smoke suites are gated by:

```text
SpellforgeDev.enable_smoke_tests
```

Player dev hotkeys are gated by:

```text
SpellforgeDev.enable_dev_hotkeys
```

Debug fireball launch additionally requires:

```text
SpellforgeDev.enable_debug_launch
```

The dev launch harness can enable:

- live 2.2c runtime
- live Multicast
- live Spread/Burst
- live Trigger
- live Timer
- live Speed+
- live Size+
- live payload Multicast v0
- live payload Spread/Burst v0
- live nested Trigger/Timer v1
- live nested final payload fanout v0
- Chain v0 audit/dry-run resolver
- Chain v0 direct/Trigger simple-payload runtime
- Chain payload Speed+/Size+ modifier runtime
- chaos budget v0 high-fanout stress profile

Representative hotkeys from the current README/dev harness:

The `Numpad 5` suite covers audit-only nested payload planning plus Chain audit/runtime, including Chain Speed+/Size+ payload modifier probes. The `Numpad 9` and `Numpad /` suites also cover nested final payload fanout v0. The `Numpad .` suite covers chaos budget high-fanout stress.

- `Numpad 0` — performance stress spell
- `Numpad +` — simple-helper launch smoke
- `Numpad 1` — Multicast x3 launch smoke
- `Numpad 2` — Timer payload smoke
- `Numpad 3` — simple Trigger payload smoke
- `Numpad 4` — Multicast x3 Trigger cardinality smoke
- `Numpad 5` — live 2.2c simple-dispatch bridge smoke plus nested/Chain audit, Chain runtime, and Chain Speed+/Size+ payload modifier probes
- `Numpad 6` — live Multicast x3 primary-helper fanout smoke
- `Numpad 7` — live Spread x3 primary aiming
- `Numpad 8` — live Burst x3 primary aiming
- `Numpad 9` — live Trigger v0 post-hit payload smoke plus payload Multicast/Spread/Burst v0 and Trigger->Timer v1
- `Numpad /` — phased live Timer v0 async simulation-delay smoke plus payload Multicast/Spread/Burst v0 and Timer->Trigger v1
- `Numpad *` — live Speed+ v1 `data.speed` mutation smoke
- `Numpad -` — live Size+ v0 helper-spec mutation smoke
- `Numpad .` - chaos budget high-fanout stress smoke

---

## Recommended Next Roadmap

### 1. Remaining payload Speed+/Size+ runtime policy

Decide whether non-Chain payload branches can safely inherit existing Speed+/Size+ mutation paths.

### 2. Broader nested payload runtime

Evaluate depth > 2, nested behavior inside final fanout, and same-kind Trigger/Timer after the depth-2 runtime settles.

### 3. Broader Chain v0

Evaluate only one narrow shape at a time. Chain must remain job-budgeted and scan-budgeted.

---

## Things Not To Claim Yet

Do not claim:

- arbitrary nested payload runtime works live
- arbitrary payload Multicast works live beyond direct Trigger/Timer v0 groups
- arbitrary payload Spread/Burst works live beyond direct Trigger/Timer payload Multicast groups
- arbitrary nested Trigger/Timer works live beyond the depth-2 opposite-kind v1 shapes
- arbitrary Chain works beyond the narrow direct/Trigger simple and Speed+/Size+ payload-modifier shapes
- Speed+ acceleration works
- Size+ scales projectile mesh/hitbox/collision
- the 25-helper stress fixture proves real delayed nested Timer gameplay
- Spellforge performs per-projectile Lua steering
- Spellforge performs per-projectile actor scans

Current truth:

- Live Timer v0 real async delay works for conservative direct payload groups.
- Live Trigger v0 works for conservative direct payload groups.
- Direct Trigger/Timer payload Multicast and payload Spread/Burst v0 work only behind explicit dev flags.
- Speed+ v1 works as bounded launch-time `data.speed` mutation.
- Size+ v0 works as bounded helper effect `area` mutation.
- Chain payload Speed+/Size+ works only for direct Chain and Trigger->Chain simple payload shapes.
- Nested Trigger/Timer runtime remains bounded to the current depth-2 opposite-kind shapes.
