# Spellforge Current State - 2.2c Feature-Gated Runtime

This file tracks the current implementation state of Spellforge / OpenMW-Noita-lite.

`ARCHITECTURE.md` remains the authoritative design and module-contract document. This file is intentionally more practical: it records what exists, what is feature-gated, what is known to work in smoke/live paths, and what remains deferred.

---

## Current Snapshot

Live 2.2c remains **feature-gated and default-off**. The stable 2.2b intercept-dispatch path is still preserved as the working foundation and fallback path.

Latest handoff truth:

- The public support matrix is IR-backed, and Trigger, Timer, Bounce, Chain, and Pierce now prefer the shared IR continuation/job-planning adapter path under their existing live gates.
- Legacy Trigger/Timer/Bounce/Chain fallback paths remain available during migration; Pierce is new and IR-only.
- Smoke90/Smoke91 proved the consolidated Trigger/Timer/Bounce/Chain IR adapter path with zero fallback/mismatch counts. Smoke101 proved Pierce v0 smoke plus the live SFP Pierce pass-through budget.
- `Pierce 3` now means three actor pass-throughs, then normal collision on the fourth actor or any geometry hit. Smoke101 showed projectiles piercing three distinct dremora and then colliding with a fourth distinct dremora, with no Spellforge limit-stop or old exit-nudge marker.
- Launch-modifier policy v5 is shared: `launch_modifier_policy.lua` owns Speed+/Size+ payload and source-launch decisions plus pre-materialization Size+ helper-spec mutation. `runtime_job_planner.lua` applies accepted payload mutations to IR-planned jobs, and generic source launch/spec creation applies accepted source mutations before SFP launch fields are finalized. Event adapters pass event context, gates, caps, and their own Bounce/Pierce facts, but do not interpret Speed+/Size+ semantics. The policy now supports payload Speed+/Size+ shapes, single and combined Speed+/Size+ direct Trigger/Timer payload Multicast fanout, single and combined Speed+/Size+ direct Trigger/Timer payload Spread/Burst + Multicast, ordinary source combined Speed+ Size+ simple launch, ordinary source Speed+/Size+ primary Multicast, ordinary source combined Speed+ Size+ primary Multicast, ordinary source Speed+/Size+ primary Spread/Burst + Multicast, ordinary source combined Speed+ Size+ primary Spread/Burst + Multicast, single Bounce/Pierce source Speed+ or Size+ simple launches, and Bounce/Pierce source Multicast or Spread/Burst + Multicast fanout with zero, one, or both Speed+/Size+ source modifiers. Bounce/Pierce source fanout may route existing Trigger simple payload continuations when the conservative event budget passes, and Bounce/Pierce source projectiles may now carry Timer continuations through the shared Timer/IR path. Event-source Timer schedules once per source emission or source fanout sibling, not once per Bounce/Pierce event, and budgets payload work as `source_fanout_count * timer_payload_fanout_count`. Chain now supports bounded direct and Trigger->Chain Spread/Burst + Multicast payload fanout plus combined Speed+ Size+ Multicast and combined Speed+ Size+ Spread/Burst + Multicast while preserving one Chain continuation claim per hop. Chain payload emitters may also carry bounded Trigger or Timer side continuations, including Chain fanout/pattern siblings when side-continuation budgets pass; side continuations do not advance Chain. Homing composition Pack F adds a shared `homing_launch_policy.lua` for launch-time Homing metadata/forceVec decisions across ordinary source launches, source Multicast/Spread/Burst, source Speed+/Size+, source Trigger/Timer continuations, and direct Trigger/Timer payload Homing fanout/modifier shapes. Nested continuation Pack G allows bounded depth-2 Trigger/Timer nesting, including same-kind Trigger->Trigger and Timer->Timer, with final payload fanout/pattern/modifier/Homing/non-recursive Chain shapes under shared planner caps. Source Speed+/Size+ plus Trigger payload, direct Bounce/Pierce source Chain, Chain recursion, Chain side payloads containing Chain, arbitrary nested Bounce/Pierce runtime, repeated same-actor Pierce ticks, depth greater than 2, and arbitrary recursion now report as classified future-deferred or unsupported-by-design v1 surfaces. The `I` all-IR smoke starts with `SPELLFORGE_PAYLOAD_MODIFIER_POLICY_CONFORMANCE_OK`, `SPELLFORGE_SOURCE_MODIFIER_POLICY_CONFORMANCE_OK`, `SPELLFORGE_PAYLOAD_MODIFIER_FANOUT_CONFORMANCE_OK`, `SPELLFORGE_PAYLOAD_MODIFIER_COMBINED_FANOUT_CONFORMANCE_OK`, `SPELLFORGE_PAYLOAD_MODIFIER_PATTERN_CONFORMANCE_OK`, `SPELLFORGE_LAUNCH_MODIFIER_CLOSURE_CONFORMANCE_OK`, `SPELLFORGE_EVENT_SOURCE_FANOUT_CONFORMANCE_OK`, `SPELLFORGE_EVENT_SOURCE_TIMER_CONFORMANCE_OK`, `SPELLFORGE_CHAIN_PATTERN_CONFORMANCE_OK`, `SPELLFORGE_CHAIN_EVENT_CONTINUATION_CONFORMANCE_OK`, `SPELLFORGE_HOMING_COMPOSITION_CONFORMANCE_OK`, and `SPELLFORGE_NESTED_CONTINUATION_CONFORMANCE_OK` to prove shared policy/fanout/Timer/Chain/Homing/nesting consumption without event-specific Speed+/Size+, Multicast/Pattern, Timer, Homing, or same-kind nested handlers.
- The spellcrafting shell is functional and intentionally not visually final. UI Pack 1 replaces the placeholder hardcoded base-effect palette with the available-effect catalog path and adds virtualized/paginated Base Effects, Operators, and saved-recipe lists without changing runtime support.
- Pack H is a runtime closure/support-truth audit, not a new opcode support pack. It adds feature-matrix reason classifications, explicit strict IR smoke mode (`SpellforgeDev.enable_ir_runtime_strict_v0`), legacy runtime quarantine flags, full A-G support-truth aggregation, feature-matrix/runtime agreement markers, and a smoke-harness structure marker. Supported v1 runtime behavior must run through runtime IR, continuation planning, runtime job planning, and shared policies with zero unexpected fallback/mismatch in strict mode.
- Pack H.5 is a cleanup/refactor pass only. It adds `MODULE_INVENTORY.md`, moves the large live dispatch recipe catalog into `scripts/spellforge/tests/fixtures/live_dispatch_recipes.lua`, leaves `scripts/spellforge/global/live_dispatch_recipes.lua` as a compatibility wrapper, deletes unused no-op prototype stubs, and adds `SPELLFORGE_SMOKE_FIXTURE_LOAD_OK` to the `I` smoke structure checks. Runtime behavior, support classifications, gates, SFP behavior, and UI visuals are unchanged.

### UI Pack 1 - available effects and virtual lists

UI Pack 1 starts the visible UI work without touching runtime semantics. The
normal spellcrafting palette now asks the backend for available base effects
instead of using the old local `BASE_EFFECTS` placeholder. The player API tries
to scan the player's spellbook for known effect IDs and sends that context to
global catalog/validation/preview/compile requests; if the scan is unavailable
or empty, the catalog reports a fallback source mode and the
`known_effect_scan_unavailable` capability warning. Operators still come from
the Spellforge operator catalog.

The visible shell uses paginated/virtualized lists for Base Effects, Operators,
and saved recipes. Base Effects show the source mode (`Known Effects`,
`Dev Catalog`, or `Fallback Catalog`), support text search, and include a compact
school/category filter. Validation remains backend-authoritative with stable
effect availability/bounds issue codes.

### Pack H reason audit

The feature matrix now keeps the existing stable `deferred_reasons` list for compatibility and also classifies those reasons for UI/runtime policy:

| classification | meaning | example reasons | runtime behavior | UI label |
|---|---|---|---|---|
| `feature_gated` | Supported when the listed live/dev gates are enabled | no deferred reason | plan/preview as supported, live stays default-off | Feature-gated |
| `unsupported_by_design` | Unsafe or intentionally outside v1 | `nested_depth_exceeded`, `chain_recursion_deferred`, `homing_bounce_physics_unsupported`, `homing_pierce_physics_unsupported`, `homing_chain_targeting_unsupported`, `pierce_bounce_deferred` | reject before enqueue | Unsupported in v1 |
| `future_deferred` | Plausible future runtime broadening, not a v1 promise | `bounce_chain_deferred`, `pierce_chain_deferred`, `source_modifier_nested_deferred`, `payload_modifier_nested_deferred`, `homing_nested_runtime_deferred` | reject before enqueue | Future/deferred |
| `cap_or_budget_rejected` | Shape is supported in principle but exceeds bounded caps | `*_cap_exceeded`, `*_budget_exceeded` | reject before enqueue | Over budget |
| `gate_disabled` | Required live/dev gate is off | `*_disabled` | reject before enqueue | Gate disabled |
| `internal_error` | Planner/parser/runtime mismatch or fallback problem | `payload_parse_failed`, `*fallback*`, `*mismatch*` | smoke failure in strict mode | Internal error |

Pack H smokes require `SPELLFORGE_RUNTIME_SUPPORT_TRUTH_CONFORMANCE_OK` with `stale_deferred_count=0`, `fallback_count=0`, and `mismatch_count=0`, plus `SPELLFORGE_FEATURE_RUNTIME_AGREEMENT_OK` from the plan-cache feature/runtime comparison.

### UI readiness report

- runtime support truth stable: yes; Pack H strict smoke passed with zero fallback/mismatch and zero stale deferred count
- feature matrix public contract stable: yes; `feature_matrix.analyze` is IR-backed and now reports classified reasons
- unsupported-by-design reasons available: yes
- create/update/delete flows stable: yes for the current dev-gated shell and saved recipe lifecycle
- remaining blockers before UI polish: run the player UI API smoke after UI Pack 1 and confirm the available-effect catalog, virtualized list, validation, preview, save/delete, and compile markers stay green
- recommended next UI task: continue UI ergonomics around recipe editing/status clarity, still without changing runtime semantics

A UI-facing static contract now feeds the dev-gated visible spellcrafting shell. It accepts the effect-list recipe model `spellforge-ui-recipe-v1`, returns structured validation issues, and can produce dry-run planning previews through emission slots and helper specs without materializing helper records, launching projectiles, or requiring the SFP backend to be ready.

The player side now has a UI API boundary, persistence/lifecycle model, and first visible shell for spellcrafting work. Saved recipes use `spellforge-saved-recipe-v1`, player storage keeps saved recipes plus generated-spell lifecycle state, and UI-created spell cleanup can request compiled-record/helper-record cleanup without adding helper records to the player spellbook.

The 2.2d IR migration is underway behind the existing default-off live gates: runtime IR, the public IR-backed feature matrix, continuation planning, and runtime job planning are in place. Live Trigger, Timer, Bounce, Chain, and Pierce now prefer IR-planned adapter paths whenever their matching live runtime gate is enabled; the explicit `SpellforgeDev.enable_ir_*_runtime_v0` flags still exist as dev overrides. The migrated adapters feed a shared `global/ir_runtime_adapter.lua` IR build/continuation/job planning helper and keep legacy runtime paths available as fallback during migration. Smoke90 and Smoke91 proved the consolidated all-IR adapter smoke with zero Trigger/Timer/Bounce/Chain fallback or mismatch counts; Smoke101 proved Pierce's SFP 1.8-backed event path and pass-through semantics.

### Currently implemented core/gated pieces

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

- **UI contract and spellcrafting shell**
  - static, non-live API for the spellcrafting interface
  - normalizes effect-list recipes into `spellforge-ui-recipe-v1`
  - validates recipes with structured `{ code, path, message, severity, details }` issues
  - previews compiled plan shape, bounds, emission slots, helper specs, and deferred runtime notes
  - includes a machine-readable feature matrix with active features, required gates, limits, and deferred reasons
  - exposes `Spellforge_ValidateRecipe` / `Spellforge_ValidateResult`, `Spellforge_PreviewRecipe` / `Spellforge_PreviewResult`, `Spellforge_QueryUiCatalog` / `Spellforge_UiCatalogResult`, and `Spellforge_QueryAvailableEffects` / `Spellforge_AvailableEffectsResult`
  - the catalog result exposes recipe schema metadata, available base effects, operator opcodes/effect IDs, operator parameters, feature definitions, event names, limits, and dry-run defaults
  - available base effects use a best-effort player-known spellbook scan when spell records are accessible, or an explicit `known_effect_scan_unavailable` fallback/static catalog path when they are not
  - backend validation remains authoritative for base-effect IDs, ranges, and magnitude/duration/area bounds; stable issue codes include `effect_unknown`, `effect_unavailable`, `effect_range_invalid`, `effect_bounds_invalid`, `known_effect_scan_unavailable`, and `operator_effect_not_base_effect`
  - player `ui.lua` wraps catalog, available-effects, save/update/delete, validate, preview, and lifecycle requests behind cacheable player-side calls
  - player `storage.lua` persists saved UI recipes and generated-spell lifecycle entries
  - saved recipe migration rejects unsupported saved schema versions with structured errors
  - generated spell lifecycle entries track draft, validated, previewed, compile-pending, compiled, stale, delete-pending, deleted, and error states
  - player `spellcrafting_ui.lua` opens a dev/smoke-gated vanilla-inspired `Spellmaking` shell on `Y`
  - the shell no longer uses a normal hardcoded `BASE_EFFECTS` palette; Base Effects, Operators, and saved recipes are paginated/virtualized, and Base Effects have text search plus a compact school filter
  - the shell uses the player UI API for catalog, save/update/delete, validate, preview, and real saved-recipe compile actions
  - compile saves, validates, previews, materializes helper records, creates one player-visible generated frontend spell, and leaves live runtime behavior behind the existing gates
  - if preview reports a deferred runtime combination, the visible Create action and cached player UI compile wrapper now block before materializing helper records or frontend spells

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
  - at Timer maturity, Spellforge attempts one bounded SFP 1.7 source detonation from the registered source projectile position, then cancels the source projectile and enqueues payload jobs
  - payload execution remains orchestrator-bounded after the async callback
  - payload Multicast v0 uses one Timer schedule/callback to enqueue the bounded payload group
  - nested Trigger/Timer v1 can use Timer as the first or second stage only when `SpellforgeDev.enable_live_nested_trigger_timer_v1` is enabled
  - when live Timer is enabled, Timer payload enqueueing prefers runtime IR + continuation/job planners, including bounded event-source Timer and depth-2 nested Timer shapes, then enqueues through the same orchestrator/runtime launch path

- **Payload Multicast / final fanout**
  - feature-gated by `SpellforgeDev.enable_live_payload_multicast_v0`
  - supports bounded direct payload fanout:
    - source -> Timer -> Multicast N simple payload helpers
    - source -> Trigger -> Multicast N simple payload helpers
  - also supports supported Bounce/Pierce/Chain side-continuation payload fanout and bounded depth-2 nested final payload fanout when the matching continuation gates and budgets pass
  - fanout is resolved from compiled emission slots/helper records and enqueued through the orchestrator
  - depth greater than 2, final payload Trigger/Timer recursion, Chain recursion, Homing recursion, and arbitrary recursive payload runtime remain unsupported/deferred

- **Payload Spread/Burst / final pattern**
  - feature-gated by `SpellforgeDev.enable_live_payload_pattern_v0`
  - requires payload Multicast v0
  - supports bounded direct payload patterns:
    - source -> Timer -> Multicast N + Spread/Burst simple payload helpers
    - source -> Trigger -> Multicast N + Spread/Burst simple payload helpers
  - also supports supported Bounce/Pierce/Chain side-continuation payload patterns and bounded depth-2 nested final payload patterns when the matching continuation gates and budgets pass
  - applies deterministic launch-time directions and does not steer after launch

- **Payload launch-modifier policy v5**
  - Speed+/Size+ payload semantics are owned by `global/launch_modifier_policy.lua` and applied to IR-planned runtime jobs by `global/runtime_job_planner.lua`
  - event adapters may pass source opcode, event context, origin/direction/hit identity, gates, and caps into the shared IR runtime path, but they must not compute Speed+/Size+ mutations or add event-specific Speed+/Size+ branches
  - Size+ helper-spec mutation is pre-materialized through the shared policy before helper records are created
  - legacy Chain compatibility code may preserve/copy policy-produced modifier metadata while migration is in progress, but it must not recompute modifier semantics
  - current live/synthetic proofs cover Trigger and Timer payload Speed+, Size+, combined Speed+ Size+ simple payload routes, single or combined Speed+/Size+ payload Multicast fanout, and single or combined Speed+/Size+ direct Trigger/Timer payload Spread/Burst + Multicast through the shared IR adapter
  - Chain Speed+/Size+ compatibility, including combined Speed+ Size+ on simple Chain payload branches, bounded Chain payload Multicast, bounded Chain payload Spread/Burst + Multicast, and Chain Trigger/Timer side-continuation payloads, remains preserved through the same policy/job-planning path
  - Bounce/Pierce policy consumption must be broadened through the shared policy/job-planner/source-launch path only, not by copying Trigger/Timer/Chain modifier logic
  - Chain recursion, Chain->Chain, side payloads containing Chain, arbitrary recursion, per-frame actor scans, and per-projectile Lua brains remain classified as future-deferred or unsupported-by-design

- **Source launch-modifier and event-source fanout/Timer policy v3**
  - Speed+/Size+ source semantics are owned by `global/launch_modifier_policy.lua`
  - direct simple Speed+, Size+, and combined Speed+ Size+ source launches apply policy metadata through generic launch-spec mutation
  - ordinary source Speed+/Size+ and combined Speed+ Size+ compose with primary Multicast and primary Spread/Burst + Multicast through the generic source launch closure path
  - `Bounce N -> Speed+ -> simple target emitter`, `Bounce N -> Size+ -> simple target emitter`, `Pierce N -> Speed+ -> simple target emitter`, and `Pierce N -> Size+ -> simple target emitter` are feature-gated source-policy shapes
  - Bounce/Pierce source Multicast and Spread/Burst + Multicast now launch through the generic source fanout path; each sibling carries Bounce/Pierce event-source metadata plus any shared source Speed+/Size+ policy metadata
  - unmodified Bounce/Pierce source fanout with Trigger simple payload routes through the existing IR continuation adapter only when `source_fanout_count * event_count_per_source * payload_fanout_count` stays under `MAX_EVENT_SOURCE_RESUMES_PER_CAST` and the Bounce/Pierce source caps
  - Bounce/Pierce source Timer continuations route through `live_timer.lua` and the shared IR adapter; Timer schedules once per source emission/fanout sibling and budgets payload work as `source_fanout_count * timer_payload_fanout_count` under `MAX_EVENT_SOURCE_TIMER_JOBS_PER_CAST`
  - Bounce/Pierce event adapters still only provide Bounce/Pierce runtime fields; they do not compute Speed+/Size+ fields, own Multicast/Spread/Burst fanout semantics, or schedule Timer payloads directly
  - Bounce/Pierce source Speed+/Size+ with Trigger payloads, simple no-fanout combined source Speed+ Size+, Homing source physics, direct source Chain, nested payload runtime, repeated same-actor Pierce ticks, post-launch steering, and recursive stacks remain classified as future-deferred or unsupported-by-design

- **Bounded Nested Continuation Pack G**
  - feature-gated by `SpellforgeDev.enable_live_nested_trigger_timer_v1`
  - final fanout still uses `SpellforgeDev.enable_live_nested_final_fanout_v0`; final Spread/Burst also requires payload Pattern v0
  - supports bounded depth-2 Trigger/Timer shapes through the shared continuation planner:
    - source -> Trigger -> Trigger -> final payload
    - source -> Timer -> Timer -> final payload
    - source -> Trigger -> Timer -> final payload
    - source -> Timer -> Trigger -> final payload
  - final payloads may use already-supported simple, Multicast, Spread/Burst + Multicast, Speed+/Size+/combined, Homing, or non-recursive Chain launch surfaces when their gates and caps pass
  - nested depth, final payload, and recursion checks are centralized in the shared planner/job-planner path; event adapters only pass event context
  - depth greater than 2, final payload Trigger/Timer, Chain recursion, Homing recursion, and arbitrary recursive payload runtime reject before enqueue as classified future-deferred or unsupported-by-design surfaces

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
  - Chain audit still treats Chain as sequential; live Chain+Multicast, Chain+Spread/Burst, and Chain Trigger/Timer side continuations are handled only by the separately gated bounded runtime path, while Chain recursion and nested Chain payloads remain classified as unsupported/deferred surfaces

- **Chain v0 live runtime**
  - feature-gated by `SpellforgeDev.enable_live_chain_runtime_v0`
  - supports direct `source -> Chain N -> simple payload` and `source -> Trigger -> Chain N -> simple payload`
  - supports Chain payload modifier shapes:
    - `source -> Chain N -> Speed+ -> simple payload`
    - `source -> Chain N -> Size+ -> simple payload`
    - `source -> Chain N -> Speed+ -> Size+ -> simple payload`
    - `source -> Trigger -> Chain N -> Speed+ -> simple payload`
    - `source -> Trigger -> Chain N -> Size+ -> simple payload`
    - `source -> Trigger -> Chain N -> Speed+ -> Size+ -> simple payload`
  - Chain payload Speed+ also requires `SpellforgeDev.enable_live_speed_plus`
  - Chain payload Size+ also requires `SpellforgeDev.enable_live_size_plus`
  - `SpellforgeDev.enable_live_chain_multicast_v0` enables bounded direct Chain+Multicast and Trigger->Chain+Multicast payload fanout
  - the same Chain Multicast gate allows one or both Speed+/Size+ modifiers on bounded Chain payload Multicast branches when the matching modifier gates are enabled
  - payload Spread/Burst + Multicast is supported for direct Chain and Trigger->Chain when the payload Pattern gate is enabled, including combined Speed+ Size+ Pattern fanout through the shared launch-modifier policy
  - Chain+Multicast and Chain+Pattern launch sibling payloads per hop but share one continuation claim per hop, so fanout does not branch into exponential Chain continuations
  - `Chain N` launches up to N sequential payload hops, one hop per accepted hit event
  - uses `no_immediate_repeat` targeting, excluding only the current hit target and allowing A->B->A->B bounces
  - uses deterministic mock providers for smokes and a bounded real provider on discrete Chain hit/hop events when `openmw.world.activeActors` is available
  - the real provider separates bounded active-actor inspection from the returned candidate cap and filters caster/current-hit actors before line-of-sight
  - real-provider candidates are filtered through a player-local line-of-sight raycast before selection
  - each Chain hop is orchestrator-queued, SFP/MagExp-launched, and carries continuation `userData`
  - when live Chain runtime is enabled, qualified Chain payload hops prefer runtime IR + continuation/job planners, then merge back into the existing bounded Chain enqueue path; target selection, duplicate suppression, Chain+Multicast continuation grouping, and Speed+/Size+ payload metadata remain legacy-compatible
  - Smoke88 proved deterministic IR Chain handoff/enqueue for direct Chain, Trigger Chain, Chain+Multicast, Trigger Chain+Multicast, and Chain Speed+/Size+ variants with zero fallback/mismatch; later Chain Pattern smokes add `SPELLFORGE_CHAIN_PATTERN_CONFORMANCE_OK` for direct/Trigger Pattern and combined Speed+ Size+ fanout, and Pack E smokes add `SPELLFORGE_CHAIN_EVENT_CONTINUATION_CONFORMANCE_OK` for Chain Trigger/Timer side continuations while preserving one Chain continuation claim per hop
  - Smoke110 proved six manual real-provider Chain probes with caster/current-hit prefiltering, zero actor-scan/candidate-cap hits, three selected real targets, three queued hops, three accepted payload launches, and clean `max_hops_reached` stops per shot
  - `SPELLFORGE_CHAIN_PROVIDER_PREFILTER_CAPS_OK` is the deterministic injected-actor regression for provider prefiltering and separate actor-scan/returned-candidate caps
  - Chain continuation `userData` and Speed+/Size+ modifier metadata coexist on modified payload launches
  - stops cleanly at max hops or when no valid target exists
  - duplicate hit suppression is scoped per cast/chain/hop/projectile identity and, for Chain+Multicast/Pattern, per hop continuation group
  - Chain recursion, Chain->Chain, Chain side payloads containing Chain, Chain with Homing, per-frame actor scans, per-projectile Lua loops, and post-launch steering remain classified as unsupported/deferred surfaces; non-recursive Chain may appear as a bounded depth-2 final payload through Pack G

- **Speed+ v1**
  - feature-gated by `SpellforgeDev.enable_live_speed_plus`
  - launch-time initial speed mutation using SFP Beta3 `data.speed`
  - optionally mirrors the bounded speed into `maxSpeed`
  - does not enable `accelerationExp`, speed-scaled damage, physics impulse, `forceVec`, or per-projectile steering

- **Size+ v0**
  - feature-gated by `SpellforgeDev.enable_live_size_plus`
  - helper-spec mutation of existing effect `area`
  - does not scale projectile mesh, hitbox, collision volume, physics impulse, or post-launch projectile state

- **Homing v0**
  - feature-gated by `SpellforgeDev.enable_live_homing_v0`
  - uses `global/homing_launch_policy.lua` as the shared owner for Homing launch-time support/defer decisions, target metadata, bounded forceVec computation, and soft-Homing registration caps
  - supports `Homing -> simple target projectile`, `Homing -> Speed+/Size+/Speed+ Size+ -> simple target projectile`, `Homing -> Multicast/Spread/Burst + Multicast -> simple target projectile`, and those source fanout shapes with Speed+/Size+ modifiers
  - supports source Homing emitters with Trigger or Timer continuations, plus direct Trigger/Timer payload Homing with supported payload Multicast/Spread/Burst and Speed+/Size+ policy shapes
  - uses SFP 1.7 `forceVec` at helper launch time, with a bounded force vector computed once from launch start position to the selected target/position
  - can acquire one actor target at launch through a bounded forward cone scan, prioritizing aim-line error before distance and using a lower creature aim height so small creatures under the crosshair do not lose to a nearer off-axis NPC, then falls back to explicit target position or hit position
  - records compact Homing metadata in `userData`
  - `SpellforgeDev.enable_live_soft_homing_v0` allows accepted single-projectile Homing launches to launch without `forceVec` and register with the central low-frequency soft Homing manager for delayed `redirectSpell` nudges; explicitly requested multi-sibling soft Homing fanout remains deferred with `homing_soft_high_fanout_deferred`, while ordinary Homing fanout keeps using launch-time `forceVec`
  - `SpellforgeDev.enable_live_soft_homing_probe` enables a dev-only single-projectile viability probe that launches without target-directed `forceVec`, registers the helper with a central manager, waits briefly, requests SFP projectile state at low frequency, and attempts blended `redirectSpell` nudges
  - soft Homing redirect blend is tuned to `0.35`, giving the low-frequency nudges enough authority to curve toward stationary targets without restoring snap-turn behavior
  - soft Homing can now run a rare bounded retarget scan from the central manager, switching only when the cached target is missing/invalid/static/overshot or when a new actor is substantially closer
  - actor-backed soft Homing entries are eligible for that first retarget check on the first delayed steer, so short-lived projectiles can still report/use retarget diagnostics before their redirect cap is spent
  - explicit-position fallback entries use a wider retarget radius and faster search interval while keeping the same low-frequency manager, forward-cone filter, candidate cap, and per-tick retarget budget, so long shots can acquire actors after launch without snapping to off-axis targets
  - retargeting includes NPCs and creatures through defensive OpenMW actor checks, tracks candidate kind counts, and preserves Homing target metadata in redirect logs/stats
  - if an explicit fallback point has moved behind the projectile and no forward actor retarget is chosen, soft Homing stops steering toward that stale point and keeps bounded projectile-position retarget scans alive on the steer cadence until hit, actor acquisition, or timeout
  - does not add per-frame actor scans, per-projectile Lua update loops, high-fanout Homing, or gameplay-wide unbounded target reacquisition
  - Homing with Bounce source physics, Pierce source physics, or Chain source targeting is unsupported with stable reasons `homing_bounce_physics_unsupported`, `homing_pierce_physics_unsupported`, and `homing_chain_targeting_unsupported`
  - Homing recursion, arbitrary nested Homing runtime, and multi-sibling/high-fanout soft Homing remain unsupported/deferred

- **Bounce v0**
  - feature-gated by `SpellforgeDev.enable_live_bounce_v0`
  - supports:
    - `Bounce N -> simple target emitter`
    - `Bounce N -> target emitter -> Trigger -> simple payload`
    - `Bounce N -> target emitter -> Trigger -> payload Multicast` when payload Multicast v0 is enabled
    - `Bounce N -> target emitter -> Trigger -> payload Spread/Burst + Multicast` when payload Multicast and payload Pattern v0 are enabled
    - `Bounce N -> target emitter -> Trigger -> Chain N -> simple payload` when Chain runtime v0 is enabled
    - `Bounce N -> Speed+ -> simple target emitter` when Speed+ is enabled
    - `Bounce N -> Size+ -> simple target emitter` when Size+ is enabled
    - `Bounce N -> Multicast or Spread/Burst + Multicast -> simple target emitter`, optionally with zero, one, or both Speed+/Size+ source modifiers, when the matching gates are enabled
    - `Bounce N -> Multicast or Spread/Burst + Multicast -> target emitter -> Trigger -> simple payload` when Trigger is enabled and event-source budget passes
    - `Bounce N -> target emitter -> Timer -> simple payload`, payload Multicast, payload Spread/Burst + Multicast, or supported payload Speed+/Size+ shapes when Timer and matching payload gates are enabled
    - `Bounce N -> Multicast or Spread/Burst + Multicast -> target emitter -> Timer -> simple payload` when Timer is enabled and event-source Timer budget passes
  - Smoke76/manual checks observed bounce callbacks and clean routing for actor/contact hits, interior wall/statics, exterior wall/statics, and terrain/ground
  - Bounce event payloads do not always include a hit actor; the Chain bridge infers one source target near the bounce point through a bounded provider lookup when possible
  - real Bounce Trigger->Chain handoff stops safely when no valid Chain candidates exist, including `candidate_count=0`
  - when live Bounce v0 is enabled, Bounce Trigger simple-payload detonation and Chain handoff prefer IR planning/validation while keeping their existing live routes; Bounce Trigger payload Multicast and Spread/Burst fanout enqueue IR-planned jobs through the same orchestrator/runtime launch path
  - source-level Bounce with direct Chain, simple no-fanout combined Speed+ Size+, Homing, arbitrary nested payload runtime, recursion, post-launch steering, and per-projectile Lua brains remains deferred

- **Pierce v0**
  - feature-gated by `SpellforgeDev.enable_live_pierce_v0`
  - backed by SFP 1.8 `piercing`, `pierceLimit`, `setSpellPiercing`, and `MagExp_OnProjectilePierce`
  - supports:
    - `Pierce N -> simple target emitter`
    - `Pierce N -> target emitter -> Trigger -> simple payload`
    - `Pierce N -> target emitter -> Trigger -> payload Multicast` when payload Multicast v0 is enabled
    - `Pierce N -> target emitter -> Trigger -> payload Spread/Burst + Multicast` when payload Multicast and payload Pattern v0 are enabled
    - `Pierce N -> target emitter -> Trigger -> Chain N -> simple payload` when Chain runtime v0 is enabled
    - `Pierce N -> Speed+ -> simple target emitter` when Speed+ is enabled
    - `Pierce N -> Size+ -> simple target emitter` when Size+ is enabled
    - `Pierce N -> Multicast or Spread/Burst + Multicast -> simple target emitter`, optionally with zero, one, or both Speed+/Size+ source modifiers, when the matching gates are enabled
    - `Pierce N -> Multicast or Spread/Burst + Multicast -> target emitter -> Trigger -> simple payload` when Trigger is enabled and event-source budget passes
    - `Pierce N -> target emitter -> Timer -> simple payload`, payload Multicast, payload Spread/Burst + Multicast, or supported payload Speed+/Size+ shapes when Timer and matching payload gates are enabled
    - `Pierce N -> Multicast or Spread/Burst + Multicast -> target emitter -> Timer -> simple payload` when Timer is enabled and event-source Timer budget passes
  - `Pierce N` uses `N` as the pass-through budget: `Pierce 3` passes through three unique actors, then stops/detonates on the next actor or any normal geometry collision
  - Smoke101 proved the live source path against a line of actors: three Pierce events on three distinct dremora, followed by normal projectile collision on a fourth distinct dremora
  - SFP owns source projectile pass-through and one-hit-per-actor tracking; Spellforge only routes Trigger continuations from Pierce events
  - direct Trigger payload launches use a forward offset from the pierce hit position and carry the pierced actor as `current_hit_target_id` / `excludeTarget` where possible
  - Pierce Trigger payload and Chain routes use the shared IR runtime adapter; Pierce is new and IR-only with no legacy combo-specific runtime to preserve
  - source-level Pierce with Bounce, Homing, simple no-fanout combined Speed+ Size+, direct Chain, arbitrary nested payload runtime, recursion, repeated same-actor ticks, post-launch steering combinations, and per-projectile Lua brains remains deferred

- **Chaos budget v0**
  - dev/test-gated by `SpellforgeDev.enable_chaos_budget_v0`
  - default profile keeps the conservative bring-up caps
  - chaos profile raises selected high-fanout caps for smoke/stress coverage while preserving hard safety rails
  - effective chaos caps include Multicast/payload fanout 16, projectiles per cast 64, nested payload jobs 64, jobs per tick 24, live helper launch density 4 per simulation update window, and an adaptive first-update launch burst of 8 per launch group
  - Chain remains sequential; Chain+Multicast and Chain+Pattern have bounded fanout/job caps, with chaos/dev smokes raising the Multicast cap to 8 while preserving one continuation claim per hop
  - over-budget spells reject before unsafe enqueue/launch and are visible in runtime stats

- **SFP/MagExp 1.7/1.8 boundary support**
  - centralized `global/sfp_adapter.lua`
  - forwards supported launch metadata:
    - `userData`
    - `muteAudio`
    - `muteLight`
    - `muteCastGlow`
    - `speed`
    - `maxSpeed`
    - `minSpeed`
    - `accelerationExp`
    - `maxLifetime`
    - `forceVec`
    - `piercing`
    - `pierceLimit`
    - `spawnOffset`
    - `areaVfxRecId`
    - `areaVfxScale`
    - `vfxRecId`
    - `boltModel`
    - `hitModel`
    - `boltSound`
    - `boltLightId`
    - `spinSpeed`
    - `excludeTarget`
    - `forcedEffects`
  - `detonateSpellAtPos` table args are normalized onto SFP 1.7's ordered detonation signature
  - `cancelSpell` is used for Timer source cleanup after timed source detonation
  - Spellforge does not synthesize area VFX from bolt VFX

### Still not live-supported

- arbitrary nested payload runtime beyond gated bounded depth-2 Trigger/Timer Pack G shapes
- depth greater than 2
- Chain recursion, Chain->Chain, Chain side payloads containing Chain, Chain with Homing, and arbitrary Chain event recursion beyond the bounded direct/Trigger, Speed+/Size+, Multicast/Pattern, Trigger/Timer side-continuation, and non-recursive nested-final Chain shapes
- broader Homing combinations and Gravity runtime
- Bounce runtime beyond source-only, primary fanout, supported Speed+/Size+ source fanout, simple Trigger payload/fanout, Trigger->Chain simple-payload bridge, and source Timer continuation shapes
- Pierce runtime beyond source-only, primary fanout, supported Speed+/Size+ source fanout, simple Trigger payload/fanout, Trigger->Chain simple-payload bridge, and source Timer continuation shapes
- Speed+ acceleration behavior
- Speed+ damage scaling
- post-launch projectile mutation
- per-projectile Lua update loops
- per-projectile actor scans
- production Noita wand/deck UI
- UI-driven live compile/cast controls

### Important current truth

The 25-helper performance stress fixture is a **logical orchestrator fast-forward stress test**. It is useful for testing plan shape, helper materialization, bounded fanout, and queue behavior, but it is **not proof of real delayed nested Timer gameplay**.

The next recommended UI milestone should harden the visible shell's layout/interaction details and then wire real compile/cast only after UI-created frontend spell lifecycle behavior is exercised safely.

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
- `SpellforgeDev.enable_live_chain_multicast_v0`
- `SpellforgeDev.enable_live_bounce_v0`
- `SpellforgeDev.enable_live_homing_v0`
- `SpellforgeDev.enable_live_soft_homing_v0`
- `SpellforgeDev.enable_live_soft_homing_probe`
- `SpellforgeDev.enable_chaos_budget_v0`

The live runtime is deliberately opt-in while 2.2c is hardened.

---

## Known Limits

Current shared limits include:

- `MAX_RECURSION_DEPTH = 3`
- `MAX_LIVE_NESTED_CONTINUATION_DEPTH = 2`
- `MAX_NESTED_CONTINUATION_JOBS_PER_CAST = 32` by default, 64 in chaos
- `MAX_NESTED_FINAL_PAYLOAD_JOBS_PER_CAST = 32` by default, 64 in chaos
- `MAX_PROJECTILES_PER_CAST = 32`
- `MAX_CHAIN_HOPS = 5`
- `MAX_SCAN_RADIUS = 2048`
- `MAX_CHAIN_AUDIT_HOPS = 5`
- `MAX_CHAIN_TARGETS_PER_HOP = 1`
- `MAX_CHAIN_SCAN_RADIUS = 1024`
- `MAX_CHAIN_SCAN_CANDIDATES = 16`
- `MAX_CHAIN_JOBS_PER_CAST = 5`
- `MAX_CHAIN_MULTICAST_FANOUT = 3` by default, `8` in the chaos/dev profile
- `MAX_PIERCE_COUNT = 3`, hard cap `MAX_PIERCE_COUNT_HARD = 5`
- `MAX_EVENT_SOURCE_RESUMES_PER_CAST = 24`
- `MAX_EVENT_SOURCE_TIMER_JOBS_PER_CAST = 24`
- `MAX_BOUNCE_PAYLOAD_JOBS_PER_CAST = 24`
- `MAX_PIERCE_PAYLOAD_JOBS_PER_CAST = 15`
- `PIERCE_PAYLOAD_EXIT_OFFSET = 48`
- `MAX_JOBS_PER_TICK = 16`

Chain-related limits guard Chain audit/dry-run probes, the narrow direct/Trigger simple-payload Chain v0 runtime, and the bounded real target provider.

---

## Current Deferred Work

### Nested payloads

The parser/slot allocator can represent nested payload structures. The shared IR continuation planner now accepts bounded depth-2 Trigger/Timer nesting, including same-kind Trigger->Trigger and Timer->Timer, when `SpellforgeDev.enable_live_nested_trigger_timer_v1` is enabled. Final-stage fanout still uses `SpellforgeDev.enable_live_nested_final_fanout_v0`; final Spread/Burst also requires `SpellforgeDev.enable_live_payload_pattern_v0`. Final payloads may use supported Multicast, Spread/Burst + Multicast, Speed+/Size+/combined, Homing, or non-recursive Chain surfaces when their gates and caps pass. Depth greater than 2 and arbitrary recursive payload runtime still reject before enqueue.

Not live-supported yet:

- Trigger/Timer depth greater than 2
- final payload containing another Trigger/Timer continuation
- Chain recursion or Chain->Chain inside nested branches
- Homing recursion inside nested branches
- arbitrary recursive payload chains

Nested payload audit remains the preflight for future runtime expansion.

### Chain

Simple direct Chain and Trigger->Chain live payload launch now exists behind `SpellforgeDev.enable_live_chain_runtime_v0`. Chain payloads can also use one or both Speed+/Size+ modifiers before simple, Multicast, or Spread/Burst + Multicast payload branches when the matching modifier gates are enabled. Chain payloads can use bounded Multicast and Pattern sibling fanout when `SpellforgeDev.enable_live_chain_multicast_v0` is enabled; sibling payloads share one continuation claim per hop, so the next Chain hop advances at most once. Chain payload emitters can now carry bounded Trigger or Timer side continuations through the shared Trigger/Timer IR paths; side continuations may fire per sibling when budgets pass, but they do not advance Chain. The audit-only resolver still classifies candidates and resolves deterministic mock sequential hops separately from runtime, and the live runtime can fall back to a bounded real target provider when no injected smoke provider is present.

Rules for future Chain:

- no actor scans per projectile per frame
- only resolve targets inside bounded chain-hop jobs
- enforce `MAX_CHAIN_HOPS`
- enforce `MAX_SCAN_RADIUS`
- enforce `MAX_CHAIN_AUDIT_HOPS`, `MAX_CHAIN_TARGETS_PER_HOP`, `MAX_CHAIN_SCAN_CANDIDATES`, and `MAX_CHAIN_JOBS_PER_CAST`
- enforce per-cast scan/job budget
- no synchronous recursive launches
- all chain hops must go through the orchestrator

Still deferred at this milestone:

- Chain recursion or Chain->Chain composition
- Chain inside mixed nested Trigger/Timer or nested final fanout
- Chain side payloads containing Chain
- Chain with Homing
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
- Timer source detonation was originally blocked until current projectile position/cell became available; SFP 1.7 source detonation support is now covered by the later Timer/SFP pass

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

At that milestone, still deferred:

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

At that milestone, still deferred:

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

At that milestone, still deferred:

- live Chain payload launch
- real actor scans
- Chain recursion
- Chain with Multicast/Spread/Burst
- Chain with Trigger/Timer (later broadened by Pack E into bounded side continuations)
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
- Chain side payloads containing Chain
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
- Chain side payloads containing Chain
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
- candidates are capped by `MAX_CHAIN_SCAN_RADIUS`, `MAX_CHAIN_SCAN_ACTORS`, `MAX_CHAIN_SCAN_CANDIDATES`, and `MAX_CHAIN_VERTICAL_DELTA` using actor base positions
- candidates then pass through a bounded player-local LOS raycast gate, so walls/floors/ceilings can reject otherwise valid nearby actors
- real Chain payload bolts launch between raised actor aim points so same-floor close targets remain visible
- non-actor hit routes are stopped before they can advance Chain, which prevents wall/static collisions from forking extra hops
- caster/current-target exclusion is pre-filtered by the real provider and remains enforced by the resolver for `no_immediate_repeat`
- the provider returns real candidates when supported, or reports `chain_target_provider_unavailable` safely
- Chain stops cleanly at max hops, no valid target, or unavailable provider
- provider stats report real/mock attempts, availability, active actors inspected, returned candidates, cap/radius use, current/caster exclusions, and selection source

Still deferred:

- Chain with Multicast/Spread/Burst
- Chain side payloads containing Chain
- Chain recursion or Chain->Chain composition
- Chain inside mixed nested Trigger/Timer or nested final fanout
- hostility/friendly-fire filtering policy
- actor scans per projectile per frame
- per-projectile Lua loops
- post-launch steering

Manual gameplay smoke:

- press `Numpad 5` for deterministic/mock Chain runtime proof; press `L` for the dedicated visual/manual Chain real-provider probe
- the `L` probe now snapshots runtime stats before the shot and reports per-shot candidate/LOS/handoff deltas afterward
- live Chain target selection uses a strict same-floor vertical tolerance, LOS raycasts, and raised aim points
- use `Fire Damage -> Trigger -> Chain 3 -> Frost Damage`
- place at least two valid nearby actors
- hit actor A with the source helper
- expect `SPELLFORGE_CHAIN_PROVIDER_REAL_OK`, `SPELLFORGE_CHAIN_LOS_REQUESTED`, `SPELLFORGE_CHAIN_LOS_LOCAL_RESULT`, `SPELLFORGE_CHAIN_LOS_RESULT`, `SPELLFORGE_CHAIN_REAL_TARGET_SELECTED`, `SPELLFORGE_CHAIN_HOP_ENQUEUED`, and `SPELLFORGE_CHAIN_HOP_PAYLOAD_OK`
- expect `SPELLFORGE_CHAIN_REAL_PROVIDER_FOLLOWUP_STATUS` and `SPELLFORGE_CHAIN_REAL_PROVIDER_DIAGNOSTIC_STATUS` after the shot; useful diagnostic reasons include `no_source_actor_hit`, `no_candidates_returned`, `actor_scan_cap_exhausted`, `no_visible_target`, `provider_unavailable`, and `positive_handoff`
- Smoke110's expected healthy follow-up shape is `positive_handoff=true`, `provider_real_ok=3`, `real_target_selected=3`, `chain_hop_enqueued=3`, `chain_payload_launch_ok=3`, `current_excluded=3`, `caster_excluded=3`, and no cap hits
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
- Chain side payloads containing Chain
- Chain recursion or Chain->Chain composition
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
  - live helper launches per simulation update window: 8 default, 4 chaos sustained pacing cap, 8 chaos adaptive first-update launch burst
  - Chain returned candidates: 16 -> 24
  - Chain active-actor scan cap: 64 -> 96
  - Chain+Multicast fanout: 3 -> 8
- hard parser/runtime safety rails remain above the chaos profile and still reject over-budget recipes
- high-fanout smokes cover direct Multicast, Trigger payload Multicast, Timer payload Multicast, Trigger/Timer payload Spread/Burst, and mixed nested final fanout
- live helper launches have a separate density throttle so a high-fanout queue is chunked across real simulation update windows instead of allowing every launch job through the same drain pass
- chaos high-fanout launch groups now get a one-update adaptive burst allowance before falling back to the sustained density cap, so a 16-way spell reads closer to `8+4+4` instead of `4+4+4+4`
- queued overflow keeps the originating launch-density cap, so chaos high-fanout payloads continue draining at the chaos pacing cap even when the executor resumes them on later updates
- the chaos smoke harness spaces high-fanout probe phases slightly and polls queued jobs to completion instead of force-draining every chunk in the same callback
- queue/job/projectile/live-launch observations are recorded in runtime stats through `chaos_budget_*` counters
- `SPELLFORGE_CHAOS_BUDGET_PROFILE`, `SPELLFORGE_CHAOS_BUDGET_LIMITS`, `SPELLFORGE_CHAOS_BUDGET_REJECTED`, `SPELLFORGE_LIVE_LAUNCH_DENSITY_THROTTLED`, and `SPELLFORGE_CHAOS_STRESS_OK` mark profile use, caps, rejections, live-launch chunking, and stress success
- Chain simple runtime remains unchanged under the chaos profile, and the narrow Chain+Multicast runtime uses a bounded fanout-per-hop cap
- Chain target acquisition remains bounded to discrete hit/hop events

Still deferred at this milestone (later Chain fanout packs broadened Pattern, combined Multicast, and Trigger/Timer side continuations):

- Chain side payloads containing Chain
- Chain recursion or Chain->Chain composition
- Chain inside mixed nested Trigger/Timer or nested final fanout
- arbitrary unbounded recursion
- actor scans per projectile per frame
- per-projectile Lua loops
- post-launch steering

Manual gameplay smoke:

- press `Numpad .` for the chaos high-fanout budget stress suite
- manual shapes to sanity-check include `Multicast 16 Fireball`, `Fireball -> Trigger -> Multicast 16 Frostball`, `Fireball -> Timer 1s -> Multicast 16 Frostball`, `Fireball -> Trigger -> Multicast 16 + Burst Frostball`, and `Fireball -> Trigger -> Frostball -> Timer 1s -> Multicast 16 Shock`
- expected behavior: large visible output, queue drains, duplicate suppression remains active, over-budget recipes reject clearly, and Chain+Multicast launches bounded siblings without exponential continuation branching

---

## 2.2c.36 - SFP 1.7 Release Update + Timer Source Detonation

Spellforge now consumes the useful SFP 1.7 boundary additions while preserving the existing bounded runtime model.

What exists now:

- `global/sfp_adapter.lua` recognizes and forwards SFP 1.7 launch fields such as `spawnOffset`, `maxLifetime`, `muteCastGlow`, `boltSound`, `boltLightId`, `spinSpeed`, `minSpeed`, and selected physics/lifecycle fields when a Spellforge launch explicitly provides them
- SFP detonation table args are normalized to the SFP 1.7 positional order, so `forcedEffects`, area VFX scale, `excludeTarget`, `userData`, and mute flags land in the intended upstream slots
- live Timer callbacks attempt one source detonation at the registered source projectile's current position/cell, then call `cancelSpell` to remove the old source projectile
- if the source projectile already hit naturally, the Timer path records a safe skip and still enqueues the payload jobs
- Timer payload scheduling, duplicate suppression, and orchestrator queueing remain unchanged
- runtime stats now expose Timer source detonation checks, attempts, successes, failures, skips, and source cancel results

Still deferred:

- per-frame Timer projectile tracking
- post-launch steering
- gravity/homing semantics
- broader Bounce combinations beyond the v0 source/Trigger shape
- relying on SFP `continuousVfx` until it has its own smoke coverage
- using SFP launch `area` as a replacement for Size+ helper-spec area mutation

Manual gameplay smoke:

- use a visible Timer spell such as `Fireball -> Timer 1s -> Frostball`
- fire it into open space so the source projectile does not hit before the timer matures
- expected markers include `SPELLFORGE_LIVE_TIMER_ASYNC_CALLBACK`, `SPELLFORGE_LIVE_TIMER_SOURCE_DETONATED`, `SPELLFORGE_LIVE_TIMER_ASYNC_PAYLOAD_ENQUEUED`, and `SPELLFORGE_LIVE_TIMER_PAYLOAD_OK`
- if the source hits before the timer matures, the source detonation status should be `skipped_already_hit` and the payload should still launch after the async delay

---

## 2.2c.37 - Bounce v0 - Surface/Actor Bounce Detonation and Trigger Payloads

Spellforge now has a narrow SFP 1.7 Bounce v0 runtime for chaotic, event-driven bouncing without per-frame projectile ownership.

What exists now:

- `Bounce N` is parsed as a launch modifier and bounded by `MAX_BOUNCE_COUNT`
- live Bounce v0 is gated by `SpellforgeDev.enable_live_bounce_v0`
- the supported v0 runtime shapes are `Bounce N -> simple target emitter`, `Bounce N -> target emitter -> Trigger -> simple payload`, `Bounce N -> target emitter -> Trigger -> payload Multicast`, `Bounce N -> target emitter -> Trigger -> payload Spread/Burst + Multicast`, and `Bounce N -> target emitter -> Trigger -> Chain N -> simple payload`, each behind its existing live/runtime gates
- the source helper launches with SFP `bounceEnabled`, `bounceMax`, `bouncePower`, and `detonateOnActorHit=false`, then reinforces those fields through SFP 1.7 `setSpellBounce` and `setSpellDetonateOnActor` after launch so the live source projectile carries bounce behavior
- each SFP `MagExp_OnProjectileBounce` event manually detonates the source spell at the bounce position, then routes a supported Trigger payload from that bounce event
- a Bounce source may carry a Trigger payload branch that starts Chain, such as `Bounce 3 Fire Damage -> Trigger -> Chain 3 -> Frost Damage`; source-level Bounce still owns the bouncing projectile, and because SFP 1.7 bounce events expose a bounce point rather than a hit actor, Spellforge performs one bounded Chain-provider lookup at the bounce point, infers the nearest valid actor as the source hit when available, and then routes into the existing Chain runtime
- the final configured bounce also cancels the source projectile, so `Bounce 3` ends on the third bounce instead of waiting for a fourth collision
- Bounce userData preserves `source_prefix_opcode`, `bounce_id`, `bounce_index`, `bounce_max`, manual detonation state, Trigger payload identity, source/postfix metadata, and compact branch scope metadata
- Trigger duplicate suppression includes the bounce index, so each bounce can trigger once while duplicate events for the same bounce remain suppressed
- runtime stats expose Bounce qualification, source jobs, post-launch bounce toggles, bounce events, source detonation attempts/results, Trigger payload detonation attempts/results, duplicate suppression, and final cancel results

Still deferred at this milestone (later closure packs broadened source fanout and Timer separately):

- direct source Bounce + Chain
- Bounce + combined source Speed+ Size+
- nested Bounce payload runtime
- Bounce recursion
- Bounce + Homing and Gravity runtime
- per-projectile Lua update loops
- per-frame actor scans
- post-launch steering

Manual gameplay smoke:

- press `G` for the Bounce v0 hardening smoke
- press `H` for the live Bounce Trigger->Chain payload probe
- aim `Bounce 3 Fire Damage -> Trigger -> Frost Damage 20pt/10ft` at a wall, floor, ceiling, or actor
- aim the `H` probe at an actor near another valid actor, or at a nearby surface with valid actors close to the bounce point; expected markers include `SPELLFORGE_LIVE_BOUNCE_CHAIN_SOURCE_TARGET_INFERRED`, `SPELLFORGE_CHAIN_HOP_ENQUEUED`, and `SPELLFORGE_CHAIN_HOP_PAYLOAD_OK`
- aim `Bounce 3 Fire Damage -> Trigger -> Chain 3 -> Frost Damage` at an actor near another actor to exercise Chain payload routing
- expected markers include `SPELLFORGE_BOUNCE_SOURCE_LAUNCH_CONFIG` with `post_launch_bounce_ok=true`, `SPELLFORGE_BOUNCE_EVENT_SEEN`, `SPELLFORGE_LIVE_BOUNCE_SOURCE_DETONATED`, `SPELLFORGE_LIVE_BOUNCE_TRIGGER_PAYLOAD_DETONATED` or fanout/Chain handoff markers, and `SPELLFORGE_LIVE_BOUNCE_FINAL_CANCELLED`
- source damage is driven through SFP area detonation at the bounce point, so the v0 manual smoke uses AoE Fireball-style source damage

---

## 2.2c.38 - Bounce v0 Hardening Smoke Pass

The Bounce v0 smoke now locks down the runtime contract that was verified in gameplay.

What changed:

- the `G` smoke runs Trigger payload Bounce dry-run coverage before the live launch
- the `G` smoke also dry-runs `Bounce 3 Fire Damage -> Trigger -> Chain 3 -> Frost Damage` and asserts the payload branch routes to Chain runtime instead of a simple at-position detonation
- the smoke asserts Bounce disabled and over-cap recipes reject clearly
- the smoke now supersedes this older check: single Bounce source Speed+ or Size+ is supported through shared policy, while combined source Speed+ Size+ remains deferred
- the live Bounce launch assertion now checks that only the source projectile is launched
- the Trigger payload is expected to use `bounce_detonate_at_pos`, not a second payload projectile launch
- source job/userData assertions confirm `bounce_runtime`, `source_prefix_opcode=Bounce`, `source_postfix_opcode=Trigger`, and Trigger payload slot identity survive launch preparation
- the hardening pass keeps the runtime event-driven through SFP bounce events; it adds no per-frame actor scans, no per-projectile Lua update loops, and no post-launch steering

Still deferred at this milestone (later closure packs broadened source fanout and Timer separately):

- direct source Bounce + Chain
- Bounce + combined source Speed+ Size+
- nested Bounce payload runtime
- Bounce recursion

Manual smoke:

- press `G`
- confirm the preflight hardening probes pass before the live launch
- during the live launch, expect three bounce events, three source detonations, three Trigger payload at-position detonations, and one final cancel
- the old symptom of a second Frost payload projectile flying away should remain absent

---

## 2.2c.39 - Bounce Trigger Chain Payload Routing

Bounce now supports Chain as a Trigger payload branch while keeping direct source Bounce+Chain deferred.

What changed:

- `Bounce 3 Fire Damage -> Trigger -> Chain 3 -> Frost Damage` qualifies as a Bounce source with a Chain payload branch
- the source projectile still uses Bounce ownership, SFP bounce fields, per-bounce source detonation, and final-bounce cancellation
- SFP 1.7 bounce events do not report a hit actor, so Bounce Trigger->Chain uses one bounded Chain-provider lookup at the bounce point to infer the nearest valid actor as the source hit when available; that source-inference lookup compares against actor aim height with a Bounce-specific vertical tolerance, while normal Chain hops keep the stricter actor-to-actor vertical guard
- after that inferred source hit, the existing Chain runtime keeps `no_immediate_repeat` targeting and bounded hop/job limits
- wall, floor, ceiling, and other bounces still detonate the Bounce source; if no valid actor is near the bounce point, the Chain path stops cleanly with `no_valid_chain_target`
- Chain continuation userData and Bounce userData coexist on the source launch
- the `G` smoke covers the new Trigger->Chain payload dry-run before the normal live Bounce launch
- the `H` smoke launches the live Bounce Trigger->Chain shape for actor-near-actor gameplay testing

Still deferred at this milestone (later closure packs broadened source fanout and Timer separately):

- direct source Bounce + Chain
- Bounce + combined source Speed+ Size+
- nested Bounce payload runtime
- Bounce recursion

---

## 2.2c.40 - Branch Observability + Homing v0

Added a narrow Homing launch modifier pass while improving Chain branch diagnostics for Bounce-triggered Chain payloads.

What changed:

- Chain runtime logs and result payloads now include `branch_scope`; Bounce-triggered Chain branches use `bounce:<bounce_id>:<bounce_index>` while ordinary Chain routes use `default`
- Chain duplicate suppression still uses cast/chain/hop/projectile identity and now exposes the branch scope in logs so multiple Bounce branch continuations are easier to separate
- Chain payload `userData` can carry `branch_scope` alongside Chain and Bounce continuation identity
- `Homing -> simple target projectile` qualifies behind `SpellforgeDev.enable_live_homing_v0`
- Homing v0 computes one bounded launch-time SFP 1.7 `forceVec` from the launch start position toward an actor selected by one bounded forward cone scan, an explicit target position, or a hit position fallback
- Homing metadata (`homing_mode`, `homing_force`, `homing_field`, target id, force key, direction key) is preserved in launch jobs and compact `userData`
- the `K` smoke covers disabled rejection, dry-run qualification of `forceVec`, soft live launch without `forceVec` forwarding, Homing userData, delayed redirect telemetry, and runtime stats

Still deferred:

- Homing with Bounce
- Homing with Chain
- Homing with Trigger/Timer
- Homing with Multicast/Spread/Burst
- Homing with Speed+/Size+
- dynamic target reacquisition
- per-frame actor scans
- per-projectile Lua update loops
- post-launch Lua steering
- Gravity runtime

Manual smoke:

- press `K` for the Homing v0 smoke
- expect `SPELLFORGE_LIVE_HOMING_QUALIFIED`, `SPELLFORGE_LIVE_HOMING_APPLIED`, and `SPELLFORGE_LIVE_HOMING_DISPATCH_OK`
- for Bounce Trigger->Chain debugging, inspect `branch_scope` on Chain target/enqueue/payload/stop log markers

---

## 2.2c.41 - Soft Homing Viability Probe

Added a dev-only instrumentation probe for cheap low-frequency Homing steering.

What changed:

- `SpellforgeDev.enable_live_soft_homing_probe` gates the probe separately from `SpellforgeDev.enable_live_homing_v0`
- the `K` smoke dry-runs the existing `Homing -> simple target projectile` launch assist, then launches the live probe without target-directed `forceVec` and registers that one projectile with `global/live_soft_homing.lua`
- the central manager ticks from the existing global executor update path, caps active entries, waits for an initial delay, requests SFP state with `getSpellState`, and attempts blended `redirectSpell` nudges toward the cached launch target
- SFP state replies are routed to both the existing SFP smoke helper and the soft Homing manager
- runtime stats record registration, tick/update activity, state requests/results, redirect attempts/results, target acquisition/missing state, cap rejection, and retirement reasons
- compact Homing `userData` now preserves the target provider and candidate count; the soft probe keeps direction metadata but intentionally omits launch force metadata
- `HOMING_INITIAL_STEER_DELAY_SECONDS` and `HOMING_REDIRECT_BLEND` keep the probe from snapping toward a target at launch

Still deferred:

- general gameplay Homing semantics
- Homing on Multicast, Chain, Bounce, Trigger/Timer, nested payloads, or arbitrary fanout
- target reacquisition/retargeting beyond the cached launch target
- LOS checks for Homing candidates
- per-frame actor scans
- per-projectile Lua brains
- recursive Homing behavior

Manual smoke:

- press `K` for Homing v0 plus the soft redirect probe
- expected markers include `SPELLFORGE_LIVE_HOMING_QUALIFIED`, `SPELLFORGE_LIVE_HOMING_APPLIED`, `SPELLFORGE_SOFT_HOMING_PROBE_REGISTERED`, delayed `SPELLFORGE_SOFT_HOMING_REDIRECT_OK` with blend metadata or a clear retired/failure marker, and `SPELLFORGE_SOFT_HOMING_RETIRED`

---

## 2.2c.42 - Combined Branch Observability, Soft Homing v0, and Chain Multicast v0

This pass promotes the cheap soft Homing path to a narrow dev-gated runtime shape, adds branch identity fields for fanout observability, and enables bounded Chain+Multicast smokes without enabling arbitrary Chain branching.

What changed:

- added `SpellforgeDev.enable_live_soft_homing_v0` for the narrow primary `Homing -> simple target projectile` soft-redirect runtime
- kept `SpellforgeDev.enable_live_soft_homing_probe` as the single-projectile instrumentation probe
- added `SpellforgeDev.enable_live_chain_multicast_v0` for direct Chain+Multicast and Trigger->Chain+Multicast simple payload shapes
- Chain+Multicast fanout uses one continuation group per hop; N siblings may launch, but only one sibling hit can advance the next Chain hop
- branch metadata now survives through launch jobs and compact SFP `userData`: `branch_id`, `branch_parent_id`, `branch_kind`, `branch_index`, `branch_count`, and `chain_continuation_group_id`
- runtime stats now report Chain Multicast attempts/qualifications/jobs/payload results and branch observability maxima
- chaos budget reporting now includes Chain Multicast fanout caps
- deterministic smokes cover direct Chain 3 Multicast 8 and Trigger -> Chain 3 Multicast 8 under chaos/dev caps

Still deferred at this milestone (later Chain fanout packs broadened Pattern and combined Multicast):

- Chain+Trigger/Timer
- Chain recursion or independent Chain continuation per multicast sibling
- Homing on Multicast, Chain, Bounce, Trigger/Timer, nested payloads, or high fanout
- Homing LOS retarget checks
- per-frame actor scans, per-projectile Lua brains, and post-launch steering outside the central low-frequency soft Homing manager

Manual smoke:

- press `K` for Homing v0 plus the soft redirect runtime/probe path
- press `Numpad 5` for Chain runtime regression, including direct/Trigger Chain+Multicast high-fanout smokes
- press `Numpad .` for the chaos budget suite, including direct/Trigger Chain+Multicast high-fanout checks
- expected Chain+Multicast markers include `SPELLFORGE_CHAIN_MULTICAST_QUALIFIED`, `SPELLFORGE_CHAIN_MULTICAST_HOP_QUALIFIED`, `SPELLFORGE_CHAIN_HOP_ENQUEUED`, `SPELLFORGE_CHAIN_HOP_PAYLOAD_OK`, and a max-hop stop

---

## 2.2c.43 - Soft Homing Retarget v0

This pass makes soft Homing feel more like proximity attraction without changing the strict performance model.

What changed:

- launch-time actor acquisition now prioritizes aim-line error before distance and uses a lower creature aim height, which keeps small targets like mudcrabs from being beaten by closer off-axis NPCs
- the central `global/live_soft_homing.lua` manager now performs rare retarget checks during state-driven redirect updates
- a projectile can switch to a nearby actor if the cached target is missing, invalid, static, overshot, or if the new target is substantially closer by the existing hysteresis ratio
- retarget scans use bounded active-actor inspection, honor the existing active homing/update/retarget caps, and count NPC/creature/actor candidates for diagnostics
- creature targets are accepted through defensive OpenMW `types.Creature`/`types.Actor` checks rather than NPC-only assumptions
- redirect logs now include target provider, target kind, and retarget count; runtime stats summarize retarget attempts, successes, budget skips, not-better skips, and candidate-kind counts
- soft Homing entries can attempt the first bounded retarget scan on the first delayed steer, then return to the normal retarget cooldown
- fallback/no-actor soft Homing entries now use a larger retarget radius and a slightly longer redirect lifetime, while retaining the same capped candidate inspection, forward-cone filtering, and one retarget scan per manager tick
- fallback retargets reject behind/off-axis actors and continue searching after overshooting the explicit fallback point rather than pulling the projectile backward
- fallback/no-actor entries use a shorter retarget interval than normal target switching from registration onward, so distant targets can be acquired while the projectile still has time to redirect

Still deferred:

- Homing on Bounce, Chain, Trigger/Timer, Multicast/Spread/Burst, nested payloads, or high fanout
- LOS checks for Homing candidates
- per-frame actor scans
- per-projectile Lua brains
- recursive Homing behavior

Manual smoke:

- press `K` for Homing v0 plus the soft redirect runtime/probe path
- expected soft Homing markers include `SPELLFORGE_SOFT_HOMING_REGISTERED`, `SPELLFORGE_SOFT_HOMING_REDIRECT_OK`, optional `SPELLFORGE_SOFT_HOMING_RETARGET_OK` or `SPELLFORGE_SOFT_HOMING_RETARGET_SKIPPED`, and `SPELLFORGE_SOFT_HOMING_RETIRED`
- check runtime stats for `retarget_attempted`, `retarget_ok`, `retarget_candidates`, `retarget_creatures`, and `retarget_npcs`; retarget skip/ok logs include the effective radius used for the scan

---

## 2.2c.44 - Branch Observability Refinement

This pass tightens branch diagnostics without broadening runtime support.

What changed:

- Trigger payload jobs now assign explicit `branch_scope`, `branch_id`, `branch_parent_id`, `branch_kind`, `branch_index`, `branch_count`, and `chain_continuation_group_id` to both the orchestrator job and compact launch `userData`
- Timer payload schedules preserve parent branch context through the async callback, then assign the same branch fields to each matured payload job and payload launch `userData`
- Bounce source launches now carry a `bounce_source` branch identity, while per-bounce source detonation, simple Trigger payload detonation, and Trigger->Chain payload routing log explicit bounce branch IDs
- live simple-dispatch job summaries expose branch fields directly, so smoke probes can assert job/userData agreement instead of relying only on logs
- smoke assertions now cover branch metadata for simple Trigger/Timer payloads, Trigger/Timer payload Multicast and Pattern fanout, nested final fanout, Chain+Multicast payload branches, and Bounce source launches

Still deferred:

- no new Homing, Chain, Bounce, Trigger/Timer, Multicast, or nested gameplay combinations
- no per-frame scans, per-projectile Lua brains, or unbounded actor scans
- no arbitrary recursive branch runtime

Manual smoke:

- press `Numpad 9` and `Numpad /` to verify Trigger/Timer payload branch metadata across simple, fanout, pattern, and nested final payload jobs
- press `Numpad 5` or `Numpad .` to verify Chain+Multicast branch identity remains bounded by continuation groups
- press `G` for Bounce source branch identity, and `H` to inspect Bounce Trigger->Chain branch scopes in logs

---

## 2.2c.45 - Smoke52 Launch-Density Probe Hardening

This pass responds to smoke52 failures where dev probes exhausted the live launch-density counter inside one scripted callback chain, then judged queued fanout jobs before later updates could drain them.

What changed:

- dev smoke probes now reset the synthetic update budget at probe boundaries, matching the fact that normal gameplay resets launch-density accounting on `onUpdate`
- Chain runtime smoke simulation drains each fanout hop as one bounded job group across simulated update ticks, so Chain+Multicast can respect the cap without leaving sibling jobs stuck when the probe snapshots results
- Trigger post-hit smoke paths can opt into the same simulated update tick behavior for bounded non-chaos fanout checks
- Bounce branch scopes now use the existing `bounce:...` id directly instead of producing duplicated `bounce:bounce:...` labels

Still deferred:

- no new Homing, Chain, Bounce, Trigger/Timer, Multicast, or nested gameplay combinations
- live launch-density caps remain in place for actual gameplay updates
- no per-frame scans, per-projectile Lua brains, or unbounded actor scans

Manual smoke:

- rerun `Numpad 5` and `Numpad .` after smoke52 to verify Chain+Multicast, Chain Speed+/Size+, Trigger payload Burst, and branch observability counters recover
- inspect Bounce logs for readable branch scopes such as `bounce:<cast>:<slot>:<max>:b1` rather than duplicated `bounce:bounce:...`

---

## 2.2c.46 - Smoke53 Chain+Multicast Probe Visual Quieting

Smoke53 showed the smoke logic was healthy but could look erratic in-game because the Chain+Multicast probe force-drained all non-continuing fanout siblings inside the same scripted callback chain.

What changed:

- the Chain+Multicast smoke path still verifies every sibling branch's job/userData metadata and payload result
- only the first sibling for each Chain hop is launched as a real SFP projectile in the synchronous smoke simulation, because that is the only sibling allowed to claim the next continuation
- remaining smoke-only siblings become virtual completed payload jobs with the same branch identity, continuation group, and compact `userData`, avoiding the 8-way visual burst per hop while preserving branch assertions
- virtual siblings use compact per-hop `SPELLFORGE_CHAIN_HOP_PROBE_VIRTUALIZED` / `SPELLFORGE_CHAIN_HOP_PAYLOAD_VIRTUAL_OK` summaries so logs do not present smoke-only branches as real SFP launches or flood a frame with per-sibling lines
- `Numpad 5` now marks its automated run complete before the optional final manual-cast observe window, so skipping or delaying that cast no longer leaves the hotkey blocked as "already in progress"
- `Numpad 5` also yields briefly between heavy automated smoke stages and Chain runtime cases to reduce startup hitching without weakening branch/runtime assertions
- actual live Chain+Multicast gameplay is unchanged; this is only enabled through the explicit smoke probe option

Still deferred:

- no new Homing, Chain, Bounce, Trigger/Timer, Multicast, or nested gameplay combinations
- no Chain+Multicast exponential continuation branching
- no per-frame scans, per-projectile Lua brains, or unbounded actor scans

Manual smoke:

- rerun `Numpad 5`; Chain+Multicast should still pass branch metadata checks, but the high-fanout Chain probe should be much less visually noisy
- `SPELLFORGE_CHAIN_HOP_PROBE_VIRTUALIZED` and `SPELLFORGE_CHAIN_HOP_PAYLOAD_VIRTUAL_OK` summarize smoke-only non-continuing siblings; `SPELLFORGE_CHAIN_HOP_ENQUEUED` and `SPELLFORGE_CHAIN_HOP_PAYLOAD_OK` remain the markers for real launched siblings
- if you do not cast the compiled simple smoke spell after the optional prompt, the automated Numpad 5 smoke should still be available to rerun

---

## 2.2c.47 - UI Contract Milestone 1

This pass adds the first pre-interface API layer without changing live runtime behavior.

What changed:

- added `spellforge-ui-recipe-v1`, a normalized effect-list recipe shape for the future spellcrafting UI
- added structured validation issues with stable fields: `code`, `path`, `message`, `severity`, and optional `details`
- parser, plan-cache, emission-slot, and helper-spec validation paths now preserve structured issues while keeping the old readable `path`/`message` fields
- added static validate and preview contract functions plus global events: `Spellforge_ValidateRecipe`, `Spellforge_ValidateResult`, `Spellforge_PreviewRecipe`, and `Spellforge_PreviewResult`
- preview compiles or reuses a plan, attaches emission slots, and generates helper specs only; it does not materialize helper records or launch projectiles
- preview includes conservative runtime support notes for deferred combinations such as Chain+Multicast UI semantics, Bounce composition, Homing composition, and Trigger/Timer payload feature gates
- plan-cache smoke coverage now asserts recipe normalization, structured validation errors, and trigger payload preview slots/specs

Still deferred:

- visible spellcrafting interface
- persistence and generated spell lifecycle work
- UI-driven live compile/cast flow
- broader runtime support for arbitrary nested payloads, Chain/Bounce/Homing composition, or recursion

Manual smoke:

- load the plan-cache smoke suite and check for `PASS 9 ui recipe normalize succeeds`, `PASS 10 ui validate succeeds`, `PASS 11 ui validate error has code`, and `PASS 12 ui preview succeeds`
- no gameplay hotkey behavior should change from this pass

---

## 2.2c.48 - UI Feature Matrix Preview

This pass makes the preview contract more useful for the future interface without changing runtime dispatch.

What changed:

- added `global/feature_matrix.lua`, a static support matrix for UI-facing preview results
- preview results now include `preview.feature_matrix`
- the matrix lists active feature IDs, active feature entries, primary/payload/nested contexts, required dev/live flags, optional flags, relevant safety limits, and deferred reasons
- preview support now uses the matrix's `live_runtime_status`, `required_flags`, and `deferred_reasons`
- valid-but-not-live-supported combinations remain previewable and are marked as `deferred` rather than treated as validation failures
- plan-cache smoke coverage originally checked Trigger gate reporting and a representative deferred classification; later closure packs moved the active deferred UI guard to Bounce+Homing after Bounce+Timer became supported

Still deferred:

- visible spellcrafting interface controls
- persistence and generated spell lifecycle work
- UI-driven live compile/cast flow
- expanding live support for deferred combinations

Manual smoke:

- rerun the plan-cache smoke suite
- new expected markers at that milestone included `PASS 13 ui preview returns feature matrix` and `PASS 13 ui feature matrix detects Trigger`; current smokes use still-deferred Bounce+Homing for the deferred compile guard

---

## 2.2c.49 - UI Catalog Endpoint

This pass adds static metadata for the future spellcrafting interface.

What changed:

- added `global/ui_catalog.lua`
- added `Spellforge_QueryUiCatalog` / `Spellforge_UiCatalogResult`
- catalog results include recipe schema metadata, supported operator opcodes, Spellforge operator effect IDs, operator parameter specs, the feature matrix catalog, event names, relevant limits, and dry-run defaults
- the catalog endpoint does not require SFP readiness and does not materialize helper records or launch projectiles
- plan-cache smoke coverage now asserts catalog versioning, operator count, Multicast parameters, Trigger effect-ID mapping, feature-matrix catalog presence, preview event naming, and dry-run defaults

Still deferred:

- visible spellcrafting interface controls
- persistence and generated spell lifecycle work
- UI-driven live compile/cast flow

Manual smoke:

- rerun the plan-cache smoke suite
- new expected markers include `PASS 15 ui catalog succeeds`, `PASS 15 ui catalog exposes Multicast parameters`, `PASS 15 ui catalog maps Trigger effect id`, and `PASS 15 ui catalog marks preview dry-run`

---

## 2.2c.50 - Player UI API, Saved Recipes, and Generated Spell Lifecycle

This pass adds the invisible player-side boundary needed before the visible spellcrafting interface starts creating user-owned recipes.

What changed:

- added `shared/saved_recipe_model.lua` with `spellforge-saved-recipe-v1`
- added `shared/generated_spell_lifecycle.lua` for UI-created generated-spell state transitions
- replaced the player storage stub with a player-section saved recipe store and generated lifecycle store
- replaced the player UI stub with cacheable calls for catalog, validate, preview, saved recipe create/update/delete, saved recipe validate/preview, compile/recompile lifecycle, and lifecycle lookup
- validation/preview callbacks now persist successful recipe ids back onto the saved recipe and lifecycle entry
- generated spell compile was still deferred in this pass; later UI work enables real player-visible frontend spell creation
- global delete cleanup can remove compiled recipe index entries by recipe id and clear in-memory helper-record mappings for that recipe
- helper-record smoke coverage now asserts recipe cleanup removes recipe-slot and logical lookup mappings
- plan-cache smoke coverage now asserts saved recipe schema/version behavior and lifecycle draft/validate/preview/compile/stale/delete transitions

Still deferred:

- visible spellcrafting interface controls
- UI-driven live compile/cast buttons
- additional UI-created frontend spellbook lifecycle polish beyond the existing cleanup/delete scaffold
- broader runtime support for deferred gameplay combinations

Manual smoke:

- rerun the plan-cache smoke suite
- expected new markers include `PASS 16 saved recipe create succeeds`, `PASS 16 saved recipe unsupported version fails`, `PASS 17 lifecycle stores compile result`, and `PASS 17 lifecycle cleanup plan targets compiled spell`
- rerun the helper-record suite
- expected new markers include `PASS 11 helper cleanup clears recipe mappings` and `PASS 11 helper cleanup removes logical lookup`

---

## 2.2c.51 - Player UI API Smoke v0

This pass adds a player-side smoke harness for the invisible UI API boundary.

What changed:

- added `tests/smoke_player_ui_api.lua`
- wired the smoke into `spellforge_smoke_plan_cache.omwscripts`
- added a player storage read-through cache so saved recipes and lifecycle entries are visible immediately after writes, even when OpenMW player storage does not behave read-after-write inside the same simulation tick
- the smoke requests the UI catalog through `player/ui.lua`, verifies the cache path, saves a recipe through player storage, validates and previews the saved recipe through global event plumbing, checks lifecycle transitions, compiles a generated frontend spell, deletes the saved recipe, and confirms cleanup removes the frontend spellbook entry
- tightened generated lifecycle cleanup planning so preview-only recipes with a recipe id do not claim compiled cleanup unless a frontend/generated engine spell id exists

Still deferred:

- visible spellcrafting interface controls
- richer UI compile/recompile management controls
- broader UI-created frontend spellbook lifecycle polish

Manual smoke:

- rerun the plan-cache smoke suite
- expected new markers include `PASS 1 catalog request succeeds`, `PASS 2 save recipe succeeds`, `PASS 3 validate saved recipe succeeds`, `PASS 4 preview saved recipe succeeds`, `PASS 5 compile saved recipe succeeds`, `PASS 6 delete saved recipe succeeds`, and `smoke player ui api run complete`

---

## 2.2c.52 - Spellcrafting Interface Shell v0

This pass adds the first visible, vanilla-inspired spellcrafting shell and its dev-gated UI-created spellbook output path.

What changed:

- added `player/spellcrafting_ui.lua`
- wired the player `Y` hotkey to open/close the shell when dev hotkeys or smoke tests are enabled
- added a MWUI `Spellmaking` shell with effect and operator palettes, a recipe stack, selected-effect editing, saved-recipe loading, preview/status output, and action buttons
- the shell talks through `player/ui.lua` for catalog, save/update/delete, validate, preview, and compile requests instead of knowing global event plumbing
- the Create button saves, validates, previews, queues real saved-recipe compile, and reports the generated frontend spell id
- added sparse log markers for UI open/close, catalog, save, validate, preview, compile, and delete actions
- fixed delete-state rendering so the visible success status appears after a saved recipe is deleted
- fitted the shell to the detected OpenMW `Windows` UI layer with a compact 3-column layout and 8px top-left position so physical display scaling cannot center it off-screen
- hardened visible-shell saved recipe loading so malformed/non-table operator `params` values are reset to operator defaults instead of crashing recipe row rendering
- hardened shared parser/canonicalize/plan/helper clone paths so non-table `params` values are treated as empty parameter maps instead of reaching `pairs()`
- moved operator parameter defaults into the shared opcode contract and parser so UI-created Timer drafts with missing `seconds` normalize to `1.0` before validation/planning
- hardened the visible UI numeric editors and save/preview/create markers so operator params such as `Multicast(count=8)` and `Burst(count=8)` are easier to verify against planned slot counts
- synchronized the visible draft back to the normalized saved recipe after Save/Create and expanded UI/global compile markers with slot/helper counts to catch any future saved-vs-compiled recipe drift
- mirrored operator params into scalar `spellforge_param_*` fields and rebuilt params from those fields globally so player-to-global UI events preserve values like `Multicast(count=8)` even when nested Lua tables are stripped
- centralized scalar operator-param field generation in the shared operator-param helper, added numeric-string coercion, and expanded plan-cache smoke coverage across Timer, Multicast, Burst, Spread, Speed+, Size+, Chain, and Bounce params

Still deferred:

- production Noita wand/deck UI semantics
- richer generated-spell management controls
- richer vanilla visual parity and layout polish
- dynamic game-effect catalog beyond the current starter palette

Manual smoke:

- load the dev launch or plan-cache smoke setup so dev hotkeys or smoke tests are enabled
- press `Y` and confirm the `Spellmaking` shell opens fully on-screen, closes, and does not block normal gameplay after closing
- expected action markers include `SPELLFORGE_SPELLCRAFT_UI_OPENED`, `SPELLFORGE_SPELLCRAFT_UI_CATALOG_OK`, `SPELLFORGE_SPELLCRAFT_UI_SAVE_OK`, `SPELLFORGE_SPELLCRAFT_UI_VALIDATE_OK`, `SPELLFORGE_SPELLCRAFT_UI_PREVIEW_OK`, `SPELLFORGE_SPELLCRAFT_UI_COMPILE_OK`, `SPELLFORGE_SPELLCRAFT_UI_DELETE_OK`, and `SPELLFORGE_SPELLCRAFT_UI_CLOSED`
- `SPELLFORGE_SPELLCRAFT_UI_OPENED` also logs the detected physical `screen=`, UI `layer=`, fitted `window=`, and `position=` dimensions for layout debugging
- loading a saved recipe should emit `SPELLFORGE_SPELLCRAFT_UI_LOAD_OK` and should not produce `bad argument #1 to 'next'` or `pairs()` errors
- Create should add one generated frontend spell to the player spellbook, keep helper records out of the spellbook, and delete/recompile should clean up stale frontend metadata
- for `Fire -> Timer(seconds=1) -> Multicast(count=8) -> Burst(count=8) -> Fire`, preview/create should report `slots=9`, `helpers=9`, and `ops=` should include Timer, Multicast count 8, and Burst count 8

---

## 2.2c.53 - Spellcrafting Deferred Runtime Guard

This pass tightened the visible shell's contract with the live runtime after smoke67 showed a UI-created Bounce source with a Trigger payload Multicast compiling successfully while Bounce v0 still rejected that runtime shape.

What changed:

- the feature matrix temporarily marked `Bounce -> Trigger -> payload Multicast/Spread/Burst` as `bounce_trigger_payload_deferred`, matching the then-existing Bounce runtime rejection path
- the visible shell now displays preview-deferred status as a warning and blocks Create when preview returns any deferred runtime reason
- the player UI compile wrapper also refuses compile requests when the latest cached preview for the saved recipe is deferred
- plan-cache smoke coverage added the exact `Bounce 5 Fire Damage -> Trigger -> Multicast 8 Frost Damage` shape so the matrix could track the recipe before exposing it safely
- player UI API smoke coverage now checks that a cached deferred preview returns `ui_compile_deferred` synchronously without queueing a global compile

Still deferred:

- broader Bounce composition beyond the current simple Trigger payload, Trigger->Chain bridge, and Trigger payload fanout path

Manual smoke:

- in the `Y` shell, previewing a still-deferred combo such as `Bounce -> Homing -> Fire Damage` should show `Runtime: deferred`
- pressing Create on that still-deferred recipe should report `Create blocked` and log `SPELLFORGE_SPELLCRAFT_UI_COMPILE_DEFERRED`
- the player UI API smoke should include `PASS 7 deferred compile blocks request`, `PASS 7 deferred compile returns readable error`, and `PASS 7 deferred compile callback invoked synchronously`

---

## 2.2c.54 - Bounce Trigger Payload Fanout

This pass removes the temporary Bounce Trigger payload fanout deferral and routes the narrow supported shape through bounded Bounce-owned Trigger payload launch jobs.

What changed:

- `Bounce -> projectile -> Trigger -> payload Multicast/Spread/Burst` now qualifies when the existing Bounce, Trigger, payload Multicast, and payload Pattern gates are enabled
- Bounce events still detonate the source projectile at the bounce point, but fanout Trigger payloads now launch via the central orchestrator instead of being collapsed into the old single at-position payload detonation
- at this milestone, source-level `Bounce + Multicast/Spread/Burst`, direct `Bounce + Chain`, combined source Speed+ Size+, Bounce+Homing, and arbitrary nested Bounce payload runtime remained deferred with stable reason codes; later closure packs broadened source fanout and Timer separately
- the feature matrix now reports the Bounce Trigger payload Multicast shape as `feature_gated` with the payload Multicast gate instead of `bounce_trigger_payload_deferred`
- Bounce smoke coverage now includes source-only and Trigger simple payload probes, disabled-gate probes for Trigger Chain/Multicast/Pattern payloads, dry-run probes for Bounce Trigger payload Multicast/Burst/Spread, and synthetic post-bounce simple/Multicast probes that register bindings without launching visible source projectiles
- `H` now preflights a synthetic Bounce Trigger->Chain no-target bounce route before the live launch, proving duplicate bounce suppression and non-fatal `no_valid_chain_target` stops

Manual smoke:

- press `G` for the Bounce hardening suite; it should include source-only, Trigger simple post-bounce, Trigger payload Multicast/Burst/Spread, disabled-gate, and unsupported-shape PASS lines before the live simple Bounce launch
- press `H` for the Bounce Trigger->Chain suite; it should include a no-target post-bounce PASS before the live actor-near-actor launch
- in live logs, supported Bounce Trigger fanout should use `SPELLFORGE_BOUNCE_TRIGGER_PAYLOAD_MULTICAST_ENQUEUED`, `SPELLFORGE_BOUNCE_TRIGGER_PAYLOAD_PATTERN_ENQUEUED`, and `SPELLFORGE_LIVE_BOUNCE_TRIGGER_PAYLOAD_OK`
- simple `Bounce -> Fire Damage -> Trigger -> Frost Damage` should still use `SPELLFORGE_LIVE_BOUNCE_TRIGGER_PAYLOAD_DETONATED`

---

## 2.2c.55 - Smoke76 Bounce Support Truth

Smoke76/manual checks consolidate Bounce v0's proven surface and Chain-handoff behavior without broadening the runtime.

What is now documented as supported:

- `Bounce N -> simple target emitter`
- `Bounce N -> target emitter -> Trigger -> simple payload`
- `Bounce N -> target emitter -> Trigger -> payload Multicast`, gated by payload Multicast v0
- `Bounce N -> target emitter -> Trigger -> payload Spread/Burst + Multicast`, gated by payload Multicast and payload Pattern v0
- `Bounce N -> target emitter -> Trigger -> Chain N -> simple payload`, gated by Chain runtime v0

Observed bounce surfaces:

- actor/contact
- interior wall/static
- exterior wall/static
- terrain/ground

Chain handoff truth:

- SFP bounce events expose a bounce point and may not expose a hit actor
- Bounce Trigger->Chain performs one bounded source-target inference near the bounce point
- when no Chain source/next candidates exist, the runtime logs the no-target condition and stops safely without a smoke failure

Still deferred at this milestone (later closure packs broadened Timer separately):

- Bounce + Homing
- Bounce + combined source Speed+ Size+
- Bounce + direct source Chain
- Bounce + arbitrary nested payload runtime
- Bounce + recursion
- Bounce + post-launch steering
- per-projectile Lua brains

Smoke/UI contract notes:

- `G` remains the Bounce hardening suite for source-only, Trigger simple, Trigger fanout, gate rejections, and unsupported-shape deferrals
- `H` distinguishes synthetic no-target safety, mock Chain handoff payload launch, live bounce-event routing, and real-provider safe stops
- `J` is the manual surface diagnostic for actor/contact, interior static, exterior static, and terrain/ground bounce callback checks
- the feature matrix reports narrow Bounce Trigger fanout, Bounce Trigger Chain, single source Bounce Speed+/Size+ simple launches, event-source fanout, and event-source Timer shapes as feature-gated, while still reporting Bounce+Homing, combined source Bounce Speed+ Size+, direct source Bounce+Chain, and nested Bounce payloads as deferred

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
- Chain+Multicast bounded branch-observed runtime
- Bounce v0 source/Trigger payload runtime
- Homing v0 launch modifier runtime
- Soft Homing v0 runtime and dev-only viability probe
- chaos budget v0 high-fanout stress profile
- IR Trigger runtime v0 dev migration
- IR Timer runtime v0 dev migration
- IR Bounce runtime v0 dev migration
- IR Chain runtime v0 dev migration
- IR Pierce runtime v0 dev migration

Representative hotkeys from the current README/dev harness:

The `Numpad 5` suite covers audit-only nested payload planning plus Chain audit/runtime, including Chain Speed+/Size+ payload modifier probes, bounded Chain+Multicast branch-observability smokes, and the IR Chain runtime dev migration. The `Numpad 9` and `Numpad /` suites also cover nested final payload fanout v0 plus the IR Trigger/Timer runtime dev migrations for direct supported payload shapes. `I` is the consolidated all-IR adapter migration smoke for Trigger, Timer, Bounce, and Chain. The `Numpad .` suite covers chaos budget high-fanout stress, including Chain+Multicast under the chaos cap. The `G` smoke covers Bounce v0 hardening, supported Trigger payload dry-run/post-bounce routes, IR Bounce simple-payload planning and fanout enqueueing, gate-disabled rejections, and unsupported-shape deferrals. The `H` smoke covers Bounce Trigger->Chain no-target/mock handoff plus live bounce-event routing and real-provider safe stops. The `P` smoke covers Pierce v0 source launch, SFP Pierce event routing, Trigger payload fanout, Trigger->Chain handoff, duplicate suppression, and deferred-shape rejections. Manual Pierce line tests should use the updated SFP Reference projectile-local file; Smoke101 proved `Pierce 3` pierces three actors and collides on the fourth. The `J` smoke covers manual Bounce surface/contact diagnostics. The `K` smoke covers Homing v0 launch-assist dry-run plus soft redirect runtime/probe checks. The `Y` dev/smoke hotkey opens the spellcrafting shell.

- `Numpad 0` — performance stress spell
- `I` - consolidated all-IR adapter migration smoke
- `Numpad 1` — Multicast x3 launch smoke
- `Numpad 2` — Timer payload smoke
- `Numpad 3` — simple Trigger payload smoke
- `Numpad 4` — Multicast x3 Trigger cardinality smoke
- `Numpad 5` — live 2.2c simple-dispatch bridge smoke plus nested/Chain audit, Chain runtime, Chain Speed+/Size+ payload modifier probes, and single-modifier Chain Multicast policy probes
- `Numpad 6` — live Multicast x3 primary-helper fanout smoke
- `Numpad 7` — live Spread x3 primary aiming
- `Numpad 8` — live Burst x3 primary aiming
- `Numpad 9` — live Trigger v0 post-hit payload smoke plus payload Multicast/Spread/Burst v0 and Trigger->Timer v1
- `Numpad /` — phased live Timer v0 async simulation-delay smoke plus payload Multicast/Spread/Burst v0 and Timer->Trigger v1
- `Numpad *` — live Speed+ v1 `data.speed` mutation smoke
- `Numpad -` — live Size+ v0 helper-spec mutation smoke
- `K` - live Homing v0 SFP 1.7 `forceVec` dry-run plus delayed soft redirect/retarget probe
- `Numpad .` - chaos budget high-fanout stress smoke
- `G` - Bounce v0 hardening smoke plus Bounce Trigger payload fanout dry-runs/post-bounce probes and IR Bounce runtime gate checks
- `H` - Bounce Trigger->Chain no-target/mock handoff plus live event/payload probe
- `P` - Pierce v0 source/Trigger fanout/Trigger->Chain smoke
- `L` - manual Chain real-provider visual probe with per-shot candidate/LOS/handoff diagnostics
- `J` - manual Bounce surface/contact diagnostic probe
- `Y` - dev/smoke-gated spellcrafting shell

Additional current coverage: `Numpad 5` now includes Chain+Multicast branch-observability smokes, Chain Pattern/fanout policy smokes, Chain Trigger/Timer side-continuation smokes, plus IR Chain runtime planning/enqueue counters, `Numpad 9` and `Numpad /` assert Trigger/Timer branch metadata across fanout and nested final payloads, `Numpad /` asserts IR Timer runtime planning/enqueueing for simple, payload Multicast, and payload Spread/Burst shapes, `I` logs `SPELLFORGE_PAYLOAD_MODIFIER_POLICY_CONFORMANCE_OK`, `SPELLFORGE_SOURCE_MODIFIER_POLICY_CONFORMANCE_OK`, `SPELLFORGE_PAYLOAD_MODIFIER_FANOUT_CONFORMANCE_OK`, `SPELLFORGE_PAYLOAD_MODIFIER_COMBINED_FANOUT_CONFORMANCE_OK`, `SPELLFORGE_PAYLOAD_MODIFIER_PATTERN_CONFORMANCE_OK`, `SPELLFORGE_LAUNCH_MODIFIER_CLOSURE_CONFORMANCE_OK`, `SPELLFORGE_EVENT_SOURCE_FANOUT_CONFORMANCE_OK`, `SPELLFORGE_EVENT_SOURCE_TIMER_CONFORMANCE_OK`, `SPELLFORGE_CHAIN_PATTERN_CONFORMANCE_OK`, `SPELLFORGE_CHAIN_EVENT_CONTINUATION_CONFORMANCE_OK`, and `SPELLFORGE_IR_RUNTIME_ADAPTER_STATUS`, and Smoke90/Smoke91 assert all migrated adapter fallback/mismatch counts stay zero while supported/deferred adapter paths remain bounded. `Numpad .` includes Chain+Multicast high-fanout chaos checks, `G` checks Bounce source branch identity, source Speed+/Size+ policy composition, Trigger simple/fanout bounce-route metadata, IR Bounce planner/enqueue counters, gate rejections, and unsupported-shape deferrals, `H` checks Bounce Trigger->Chain no-target safety, mock handoff payload launch, live bounce-event routing, and real-provider safe stops, `P` checks Pierce source launch fields, source Speed+/Size+ policy composition, synthetic SFP Pierce contract routing, safe payload origin, Trigger payload fanout, Trigger->Chain handoff, duplicate suppression, and deferred-shape reasons, `L` logs `SPELLFORGE_CHAIN_REAL_PROVIDER_FOLLOWUP_STATUS` and `SPELLFORGE_CHAIN_REAL_PROVIDER_DIAGNOSTIC_STATUS` after a manual real-provider Chain shot, `J` checks manual surface/contact callback diagnostics, and `K` includes the soft redirect runtime/probe path with bounded retarget diagnostics. Smoke101 additionally proved the real SFP Pierce source line test after copying the updated SFP Reference file into the live SFP folder.

## 2.2c.58 - Pierce v0 IR Runtime Adapter

Spellforge now includes Pierce as the final launch modifier opcode, implemented against SFP 1.8 and the shared IR continuation/job planning pipeline.

What changed:

- added `spellforge_pierce` / `Pierce` metadata, parser support, UI catalog exposure, and Pierce caps (`MAX_PIERCE_COUNT = 3`, hard cap 5)
- added SFP adapter launch forwarding for `piercing` and `pierceLimit`, plus `setSpellPiercing` capability wrapping
- added `live_pierce.lua` to route `MagExp_OnProjectilePierce`, validate Spellforge userData/projectile identity, suppress duplicate actor/projectile/pierce-count events, and enqueue supported Trigger continuations through the IR runtime adapter
- Pierce source launches carry compact SFP `userData` and launch metadata for `pierce_runtime`, `pierce_role`, `pierce_id`, `pierce_limit`, source prefix/postfix opcodes, Trigger payload slots, and branch identity
- Trigger payload launches from Pierce events use a forward-safe payload origin (`PIERCE_PAYLOAD_EXIT_OFFSET = 48`) and carry the pierced actor as `current_hit_target_id` / `excludeTarget` where possible
- runtime IR, the IR feature matrix, the continuation planner, and runtime job planner all represent Pierce source, Pierce Trigger fanout, Pierce Trigger Pattern, Pierce Trigger Chain, and deferred Pierce shapes
- the `P` smoke covers source dry-run/launch, synthetic SFP Pierce event contract routing, simple/Multicast/Burst/Spread Trigger payload enqueueing, Trigger->Chain handoff, duplicate suppression, safe origin metadata, and stable deferred reasons
- Smoke101 proved the live SFP source projectile semantics for `Pierce 3`: `pierce_count=1`, `2`, and `3` occurred on three distinct dremora, then the projectile collided normally with a fourth distinct dremora; no `SPELLFORGE_LIVE_PIERCE_LIMIT_STOP` or old exit-nudge marker appeared

Still deferred at this milestone (later closure packs broadened Timer and source fanout separately):

- source-level Pierce with Bounce, Homing, combined Speed+ Size+, direct Chain, arbitrary nested payload runtime, recursion, repeated same-actor Pierce ticks, post-launch steering combinations, per-projectile Lua brains, and per-frame actor scans

Manual smoke:

- press `P` for the automated Pierce v0 smoke suite
- aim `Pierce 3 -> Fire Damage` through a line of actors; expected behavior is one source resolution on each of the first three unique actors, continued projectile flight through those actor contacts, then normal stop/detonation on the fourth actor or any geometry collision
- use a no-AoE or very small-area source spell for future Pierce visual diagnostics when possible, because the final fireball explosion can make pass-through damage hard to distinguish by eye
- aim `Pierce 3 -> Fire Damage -> Trigger -> Frost Damage`; expected behavior is Fire from SFP Pierce and Frost payload launch from a forward-offset exit point rather than the raw inside-actor hit point
- aim `Pierce 3 -> Fire Damage -> Trigger -> Chain 3 -> Frost Damage` near at least two actors; Chain should treat the pierced actor as the current hit target and seek another valid target
- expected markers include `SPELLFORGE_SFP_PIERCE_CONTRACT_OK`, `SPELLFORGE_LIVE_PIERCE_SOURCE_OK`, `SPELLFORGE_LIVE_PIERCE_EVENT`, `SPELLFORGE_IR_PIERCE_RUNTIME_ENQUEUED`, `SPELLFORGE_LIVE_PIERCE_TRIGGER_PAYLOAD_OK`, `SPELLFORGE_LIVE_PIERCE_DUPLICATE_SUPPRESSED`, `SPELLFORGE_PIERCE_PAYLOAD_ORIGIN_SAFE`, and `SPELLFORGE_PIERCE_DEFERRED`

---

## 2.2c.59 - Source Launch Modifier Policy v0

Spellforge added a shared source launch-modifier policy for narrow simple source-launch shapes. This was later broadened by the launch-modifier closure packs for ordinary source launches and by Pack B for Bounce/Pierce primary source fanout.

What changed:

- extended `global/launch_modifier_policy.lua` with source-entry inspection and source launch-spec mutation
- direct simple source Speed+ and Size+ launches now apply shared source-policy metadata before launch
- Bounce and Pierce source launches can compose one source Speed+ or one source Size+ through shared policy without event-adapter Speed+/Size+ semantics
- Bounce and Pierce source Multicast or Spread/Burst + Multicast fanout can compose zero, one, or both source Speed+/Size+ modifiers through shared source policy, with each primary sibling carrying Bounce/Pierce event metadata
- unmodified Bounce/Pierce source fanout with Trigger simple payload is budgeted before registration by `MAX_EVENT_SOURCE_RESUMES_PER_CAST`, `MAX_BOUNCE_PAYLOAD_JOBS_PER_CAST`, and `MAX_PIERCE_PAYLOAD_JOBS_PER_CAST`
- source Size+ helper specs are mutated before helper records are materialized
- source policy emits `SPELLFORGE_SOURCE_MODIFIER_POLICY_OK`, `SPELLFORGE_SOURCE_SPEED_PLUS_POLICY_APPLIED`, `SPELLFORGE_SOURCE_SIZE_PLUS_POLICY_APPLIED`, `SPELLFORGE_BOUNCE_SOURCE_MODIFIER_POLICY_OK`, `SPELLFORGE_PIERCE_SOURCE_MODIFIER_POLICY_OK`, and `SPELLFORGE_SOURCE_MODIFIER_POLICY_CONFORMANCE_OK`
- the public IR feature matrix marks single Bounce/Pierce source Speed+ or Size+ simple launches as feature-gated, marks Bounce/Pierce source fanout plus zero/one/both Speed+/Size+ modifiers as feature-gated, and keeps simple no-fanout Bounce/Pierce combined source Speed+ Size+ deferred with `source_modifier_combo_deferred`

Supported source-policy v0 shapes:

- `Speed+ -> simple target emitter`
- `Size+ -> simple target emitter`
- `Bounce N -> Speed+ -> simple target emitter`
- `Bounce N -> Size+ -> simple target emitter`
- `Pierce N -> Speed+ -> simple target emitter`
- `Pierce N -> Size+ -> simple target emitter`
- `Bounce/Pierce N -> Multicast -> simple target emitter`
- `Bounce/Pierce N -> Spread/Burst -> Multicast -> simple target emitter`
- `Bounce/Pierce N -> Speed+/Size+/Speed+ Size+ -> Multicast -> simple target emitter`
- `Bounce/Pierce N -> Speed+/Size+/Speed+ Size+ -> Spread/Burst -> Multicast -> simple target emitter`
- `Bounce/Pierce N -> Multicast or Spread/Burst + Multicast -> target emitter -> Trigger -> simple payload`, when the event-source budget passes
- `Bounce/Pierce N -> target emitter -> Timer -> simple payload`, payload Multicast, payload Spread/Burst + Multicast, or supported payload Speed+/Size+ shapes
- `Bounce/Pierce N -> Multicast or Spread/Burst + Multicast -> target emitter -> Timer -> simple payload`, when the event-source Timer budget passes

Still deferred for Bounce/Pierce source composition:

- simple no-fanout Bounce/Pierce source Speed+ Size+ together
- Bounce/Pierce source Speed+/Size+ with Trigger payloads
- Bounce/Pierce + Homing
- direct source Bounce/Pierce + Chain
- arbitrary nested payload runtime, source recursion, repeated same-actor Pierce ticks, post-launch steering, per-frame actor scans, and per-projectile Lua brains

---

## Recommended Next Roadmap

### 0. Pack H.5 cleanup verification

Run the `I` all-IR smoke after Pack H.5 cleanup. Required closure markers are:
`SPELLFORGE_IR_RUNTIME_STRICT_OK`, `SPELLFORGE_RUNTIME_SUPPORT_TRUTH_CONFORMANCE_OK`,
`SPELLFORGE_FEATURE_RUNTIME_AGREEMENT_OK`, `SPELLFORGE_LEGACY_RUNTIME_QUARANTINE_OK`,
`SPELLFORGE_SMOKE_HARNESS_STRUCTURE_OK`, and `SPELLFORGE_SMOKE_FIXTURE_LOAD_OK`.

### 1. UI polish, if Pack H.5 is green

The next major milestone can be visible spellcrafting UI polish once Pack H.5
confirms the relocated smoke fixture loads, `stale_deferred_count=0`, strict
fallback/mismatch counts are zero, and the feature matrix/runtime agreement
smoke is green. The UI should consume the IR-backed `feature_matrix` contract
and its classified reason buckets instead of duplicating runtime rules.

### 2. Future runtime broadening

Only after UI readiness or a deliberate runtime revisit: simple no-fanout
Bounce/Pierce combined source Speed+ Size+, Bounce/Pierce source Speed+/Size+
with Trigger payloads, direct Bounce/Pierce source Chain, arbitrary nested
event-source payload runtime, and other non-v1 shapes remain classified as
future-deferred or unsupported-by-design. Chain recursion, Chain->Chain, Homing
recursion, depth > 2, cyclic continuations, per-frame actor scans, and
per-projectile Lua brains remain outside v1.

---

## Things Not To Claim Yet

Do not claim:

- arbitrary nested payload runtime works live
- arbitrary payload Multicast works live beyond direct Trigger/Timer groups and bounded Pack G final payload groups
- arbitrary payload Spread/Burst works live beyond direct Trigger/Timer payload Multicast groups and bounded Pack G final payload groups
- arbitrary nested Trigger/Timer works live beyond the bounded depth-2 Pack G shapes
- arbitrary Chain works beyond the bounded direct/Trigger Chain, Speed+/Size+, Multicast/Pattern fanout, and Trigger/Timer side-continuation shapes
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
- Payload Speed+/Size+ works through the shared policy for Trigger/Timer simple payloads, Trigger/Timer single or combined modifier payload Multicast, Trigger/Timer single or combined modifier payload Spread/Burst + Multicast, and Chain/direct Trigger->Chain simple, Multicast, and Spread/Burst + Multicast payload shapes with zero, one, or both Speed+/Size+ modifiers. Ordinary source Speed+/Size+ works for simple, Multicast, and Spread/Burst + Multicast launches through the generic source closure path. Bounce/Pierce source composition supports one modifier on simple source launches, primary Multicast or Spread/Burst + Multicast source fanout with zero, one, or both Speed+/Size+ modifiers, unmodified Trigger simple payload routing under the event-source budget, and source Timer continuations under the event-source Timer budget.
- Homing v0 now works through shared launch-time Homing policy for ordinary source launch modifiers/fanout/pattern, source Trigger/Timer continuations, and direct Trigger/Timer payload Homing shapes. The visible `K` soft probe launches straight first, uses delayed blended redirect nudges, and can run rare bounded retarget scans from the central manager.
- Nested Trigger/Timer runtime remains bounded to Pack G depth-2 shapes; depth > 2 and arbitrary recursion reject before enqueue as unsupported/deferred v1 surfaces.
