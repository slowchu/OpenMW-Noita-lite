# Spellforge Current State (Post-2.2b, Pre-2.2c)

This file tracks transitional implementation status.  
`ARCHITECTURE.md` remains the authoritative design specification.

## Working foundation

- **2.2b intercept dispatch is working and remains the current foundation.**
- The live path is still:
  - player cast input
  - animation text-key intercept
  - cast-success authorization
  - global dispatch via `I.MagExp.launchSpell`

## Transitional/prototype scaffolding still present

- Current compiler/executor code still includes prototype scaffolding for:
  - root-only `real_effects` dispatch
  - metadata query fallback when player cache misses
  - graph-oriented recipe-node assumptions in validator/canonicalization code paths
- These are transitional and should not be treated as final 2.2c runtime architecture.

## 2.2c direction

- 2.2c replaces graph-oriented compiler assumptions with **ordered effect-list parsing**.
- v1 structural-cookie strategy is **per-emission helper spell records** (internal only).
- No real opcode runtime is complete yet (no final Trigger/Timer/Multicast/Burst/Spread/Chain/Speed+/Size+ runtime behavior).
- 2.2c.1 parser skeleton now exists for effect-list grouping/binding validation, but it is not wired into live 2.2b casting yet.
- 2.2c.2 canonical effect-list hashing now exists (including operator params and compiler-version salt), but it is not wired into live 2.2b casting yet.
- 2.2c.3 compiled effect-list plan cache shape now exists (staged-only in-memory, not wired into live 2.2b casting yet).
- 2.2c.4 per-emission helper-slot allocation skeleton now exists (metadata-only, no helper records, not wired into live 2.2b casting yet).
- 2.2c.5 helper-record spec generation now exists (metadata-only, no live helper records, not wired into live 2.2b casting yet).
- 2.2c.6 helper-record materialization now exists in staged/dev smoke paths (creates internal helper records, does not add to player spellbook, not wired into live 2.2b casting yet).
- 2.2c.7 central orchestrator/job queue skeleton now exists (dummy jobs only, no opcode execution, no SFP launch, not wired into live 2.2b casting yet).
- 2.2c.8 dev-only simple-emitter launch path now exists behind `SpellforgeDev.enable_dev_launch`; it proves one helper-record SFP launch and hit routing back to recipe_id + slot_id, does not execute opcodes, and does not replace the live 2.2b dispatch path.
- 2.2c.9 dev-only Multicast simple-emitter fanout now exists behind `SpellforgeDev.enable_dev_launch`; it proves `Multicast x3 -> Fire Damage` materializes three helper records, enqueues three dev launch jobs, launches through SFP, and routes helper hits back to distinct slot_ids. It does not implement Trigger/Timer/Chain/Spread/Burst runtime and does not replace the live 2.2b dispatch path.
- 2.2c.10 dev-only Timer runtime now exists behind `SpellforgeDev.enable_dev_launch`; it proves `Multicast x2 -> Fire Damage -> Timer 1.0 -> Frost Damage` launches source helpers, queues delayed Timer payload jobs, resolves the Timer payload at a predicted travel endpoint or local-raycast-clamped position, launches Frost helpers from that computed resolution point, and routes Frost hits back to slot_ids. Exact projectile speed matching remains TODO; this does not implement Trigger/Chain/Spread/Burst runtime and does not replace the live 2.2b dispatch path.
- 2.2c.11 dev-only Trigger runtime now exists behind `SpellforgeDev.enable_dev_launch`; it proves `Fire Damage -> Trigger -> Frost Damage` schedules a Trigger payload job from the Fire helper hit position, launches the Frost helper through SFP, and can also prove per-emission cardinality for `Multicast x3 -> Fire Damage -> Trigger -> Frost Damage`. It does not implement Chain/Spread/Burst runtime and does not replace the live 2.2b dispatch path.
- 2.2c.12 dev runtime consolidation now exists behind the same dev gates; shared `global/dev_runtime.lua` helpers centralize helper SFP launch, helper-hit metadata routing, payload job enqueueing, and payload launch context validation. It adds no new opcode behavior and does not replace the live 2.2b dispatch path.
- 2.2c.13 dev-only Spread aiming now exists behind `SpellforgeDev.enable_dev_launch`; it proves `Spread -> Multicast x3 -> Fire Damage` launches three helper records from the same origin with deterministic forward-cone directions and routes hits back to distinct slot_ids. Spread preset 1-4 currently maps to world-up yaw side angles 10/15/22/30 degrees. It does not implement Burst/Chain runtime, does not change Trigger/Timer behavior, and does not replace the live 2.2b dispatch path.
- 2.2c.14 dev-only Burst aiming now exists behind `SpellforgeDev.enable_dev_launch`; it proves `Burst -> Multicast x5 -> Fire Damage` launches five helper records from the same origin with deterministic center-plus-ring directions and routes hits back to distinct slot_ids. Burst `count` is preserved as pattern-intensity metadata, while Multicast still owns emission count; the current dev mapping uses `clamp(10 + count, 12, 20)` degrees for the ring. It does not implement Chain runtime, does not change Trigger/Timer/Spread behavior, and does not replace the live 2.2b dispatch path.
- SFP v1.7 Beta 2 / MagExp v2.0 adaptation now has a centralized `global/sfp_adapter.lua` boundary plus a dev projectile registry. Dev launches capture `launchSpell` projectile returns when available, derive `proj.id` when possible, retain helper spellId hit routing as the fallback identity, and store nil-safe MagicHit telemetry fields (`impactSpeed`, `maxSpeed`, `velocity`, `magMin`, `magMax`, `casterLinked`, stack data) when present. `getSpellState`, `detonateSpellAtPos`, `applySpellToActor`, and `emitProjectileFromObject` are wrapped/probed for future milestones; object emitters are not wired into gameplay. Timer still uses its predicted travel/raycast fallback unless live SFP state is explicitly proven available in a later runtime change. Per-launch SFP `userData`/cookie passthrough remains a future request unless documented. No live 2.2b path replacement, Chain/Homing/Bounce/Speed+/Size+ runtime, or audiovisual suppression semantics were added.
- Dev helper-hit routing now has explicit idempotency for payload scheduling. The projectile registry records `first_hit`/`hit_key`, while Trigger payload enqueue uses per-active-run keys (`projectile_id` when present, helper/slot fallback otherwise) so duplicate SFP hit events or watcher-level duplicate logs cannot enqueue duplicate Trigger payload jobs; distinct projectile IDs for the same helper remain distinct. Timer payload jobs carry analogous launch-time idempotency keys; Timer scheduling remains launch/delay-driven, not helper-hit-driven. Duplicate `SPELLFORGE_DEV_HELPER_HIT` logs may still appear if SFP emits duplicate hit callbacks, but they are payload-safe and smoke-probed.
- Reusable 2.2c runtime launch/hit seams now exist in `global/runtime_launch.lua` and `global/runtime_hits.lua`. Dev smokes still provide fixtures/hotkeys/assertions, while shared modules own helper SFP launch normalization, projectile registration, helper hit resolution, telemetry normalization, and hit idempotency result shaping. `global/dev_runtime.lua` remains the dev-gated adapter for orchestrator job validation and payload enqueue helpers. No live 2.2b path replacement or new opcode behavior was added.
- The first feature-flagged live 2.2c simple dispatch bridge now exists in `global/live_simple_dispatch.lua`, gated by `SpellforgeDev.enable_live_2_2c_simple_dispatch` (default off). It only qualifies single stored-node, target-range, one-static-emission plans with one helper record and no Trigger/Timer/Chain/Spread/Burst/Speed+/Size+ behavior; qualifying casts use the shared plan-cache/helper-record/orchestrator/runtime-launch/SFP/projectile-registry path. Non-qualifying or failed bridge attempts fall back to the stable 2.2b root-only `real_effects` dispatch. Live helper hits can resolve through shared `runtime_hits` when the flag is enabled, while old 2.2b launch-cookie matching remains compatible for cast observers.
- Staged smoke suites are gated by `SpellforgeDev.enable_smoke_tests` (default off) to reduce normal-start log noise; enabling the key re-runs all smoke PASS/FAIL diagnostics.
- Player dev hotkeys are gated by `SpellforgeDev.enable_dev_hotkeys` and the debug fireball launch additionally requires `SpellforgeDev.enable_debug_launch`; both default off for normal gameplay.
- Existing node-graph compiler path remains transitional scaffolding until a later migration PR.
