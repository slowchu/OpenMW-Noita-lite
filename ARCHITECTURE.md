# Spellforge Architecture

Authoritative architecture for **OpenMW Spellforge**, a Noita-inspired spell composition system for OpenMW 0.51+.

This document supersedes the earlier recipe-graph / generated-node-record design. If code and this document disagree, treat that as design drift and resolve it deliberately.

---

## 1. Project Goal

Spellforge lets the player build Morrowind spells that behave more like Noita spell chains:

- multicast
- spread
- burst
- speed/size modifiers
- delayed effects
- trigger payloads
- chained effects

The important constraint is that Spellforge is still a Morrowind/OpenMW mod, not a full replacement spell engine.

The player authors spells through a Morrowind-like spellmaking flow. A Spellforge recipe is an ordered spell effect list containing both:

1. **Vanilla magical effects**  
   These are the actual spell effects: Fire Damage, Frost Damage, Shield, Resist Magic, etc.

2. **Spellforge custom magical effects**  
   These are control/modifier effects: Multicast, Trigger, Timer, Speed+, Size+, Spread, Burst, Chain, Bounce, Pierce, and Homing.

The recipe is the spell effect list.

There is no separate wand/deck/tree data model exposed to the player in v1.

---

## 2. Current Milestone State

### Completed: Milestone 2.2b — Intercept Dispatch Pipeline

The current working foundation is the intercept-dispatch path:

1. Player selects a compiled Spellforge spell.
2. Player naturally casts through the normal spell stance/cast animation.
3. The player script observes cast animation text keys.
4. Cast success is authorized through OpenMW's skill progression success signal.
5. On release, Spellforge dispatches the stored runtime payload through the global backend.

The key success-gating rule:

- `I.SkillProgression.addSkillUsedHandler`
- `SKILL_USE_TYPES.Spellcast_Success`
- Used as the authoritative signal that the vanilla cast succeeded.

This is intentionally better than trying to reimplement vanilla chance-to-cast logic in Lua.

### In progress: Milestone 2.2c — Opcode Runtime

2.2c introduces the real Spellforge runtime:

- effect-list parser
- emitter grouping
- prefix/postfix operator binding
- compiled plan cache
- central bounded job queue
- opcode execution

2.2c should not be built on the older recipe-graph model.

---

## 3. Non-Goals for v1

Spellforge v1 does not attempt to support:

- true Noita endgame density
- arbitrary recursive loops
- hundreds of active projectiles
- fully dynamic custom magic effect record generation at runtime
- NPC usage of composed Spellforge spells
- multiplayer/TES3MP correctness
- persistent world hazards such as lava floors, fire patches, ice walls, etc.
- unbounded or per-frame homing projectiles
- live editing while combat is active
- exact vanilla parity for every reflection/resist/cost edge case

The v1 goal is readable, bounded, stable spell composition.

---

## 4. Four-Layer Architecture

Spellforge is divided into four layers.

```text
┌──────────────────────────────────────────────┐
│  1. Authoring Layer                          │
│  Player-facing spellmaker/effect-list UI     │
└────────────────────┬─────────────────────────┘
                     │ recipe/effect list
┌────────────────────▼─────────────────────────┐
│  2. Compilation Layer                        │
│  Validate, group, bind, cache compiled plans │
└────────────────────┬─────────────────────────┘
                     │ compiled plan
┌────────────────────▼─────────────────────────┐
│  3. Dispatch Layer                           │
│  Existing 2.2b intercept/cast-success gate   │
└────────────────────┬─────────────────────────┘
                     │ authorized cast
┌────────────────────▼─────────────────────────┐
│  4. Orchestration Layer                      │
│  Bounded job queue executes runtime behavior │
└──────────────────────────────────────────────┘
```

### 4.1 Authoring

The player builds a spell as an ordered effect list.

Example:

```text
1. Multicast
2. Fire Damage on Target
3. Trigger
4. Frost Damage on Target
```

This reads as:

```text
Multicast the next emitter.
Launch Fire Damage.
When Fire Damage resolves, run Frost Damage payload.
```

The UI may eventually look like a modified Morrowind spellmaker, but internally the recipe remains a flat ordered effect list with possible compiled scopes.

### 4.2 Compilation

The compiler receives an ordered effect list and produces a compiled plan.

The compiler is responsible for:

- recognizing vanilla emitters
- recognizing Spellforge operator effects
- grouping compatible emitters
- binding prefix operators
- binding postfix operators
- computing static bounds
- rejecting invalid recipes
- caching compiled plans by deterministic recipe hash

The compiler does not execute gameplay behavior.

### 4.3 Dispatch

The dispatch layer reuses the working 2.2b intercept pipeline.

The player still casts normally. Spellforge does not fire unless vanilla casting succeeds.

The dispatch layer is responsible for:

- detecting that the selected spell is a Spellforge spell
- arming intercept state
- waiting for cast-success authorization
- firing only on the correct release text key
- forwarding an authorized cast to the global runtime

### 4.4 Orchestration

The orchestrator owns runtime spell jobs.

It is responsible for:

- active job registry
- bounded per-tick advancement
- delayed Timer jobs
- Trigger payload jobs
- Multicast/Burst fanout jobs
- Chain hop jobs
- enforcing hard runtime caps

No opcode should recurse synchronously.

All fanout and nested behavior must enqueue bounded jobs.

### 4.5 IR runtime adapter and launch modifier policy

The shared IR runtime path is the long-term owner of event-resumed payload behavior
and the shared source launch path owns source launch decoration.
Runtime IR preserves `prefix_ops`, `modifier_chain`, `postfix_chain`, entries,
scopes, payload bindings, and continuations so event opcodes can resume payloads
without knowing the semantics of every modifier that may prefix that payload.

`Trigger`, `Timer`, `Bounce`, `Pierce`, and `Chain` are event adapters. They may
pass event facts such as origin, direction, hit position, current hit target,
projectile identity, continuation identity, gates, and caps into the shared
runtime path. They must not interpret `Speed+` or `Size+` themselves, compute
their launch mutations, copy Chain-specific modifier logic, or add
event-specific Speed+/Size+ branches.

Payload launch-modifier semantics belong in
`scripts/spellforge/global/launch_modifier_policy.lua`. That module owns:

- inspection of payload entry `prefix_ops` and `modifier_chain`
- inspection of source entry `prefix_ops` and `modifier_chain`
- supported/deferred modifier combination decisions
- stable rejection reasons for unsupported combinations
- Speed+ launch-field mutation computation
- Size+ helper-spec mutation before helper records are materialized
- shared policy preflight for cached plans before event adapters enqueue jobs

For IR-planned payload jobs, `scripts/spellforge/global/runtime_job_planner.lua`
is the shared place that applies accepted launch-modifier mutations to runtime
job specs. Legacy Chain compatibility code may preserve or copy policy-produced
metadata while that migration is being completed, but it must not recompute
modifier semantics. Event adapters should consume those job specs and their event
context. They may pass gate and cap values into the shared policy, but they
should not branch on modifier kind.

For source launches, `launch_modifier_policy.lua` also owns supported/deferred
source modifier decisions. Generic source launch/spec creation applies
policy-produced source mutations before SFP launch fields are finalized. Generic
source fanout code owns primary Multicast/Spread/Burst sibling emission, including
Bounce/Pierce source fanout. Bounce and Pierce adapters may add only their own
event/source facts such as `bounceEnabled`, `bounceMax`, `bouncePower`,
`detonateOnActorHit`, `piercing`, `pierceLimit`, and event identity. They must
not compute or interpret Speed+/Size+ fields, and they must not own
Multicast/Spread/Burst fanout semantics.

The policy may return a mutation set, not just a single modifier. Combined
Speed+ Size+ on one simple payload branch is handled by applying the Speed+
launch-field mutation and Size+ helper-spec mutation from the same policy result.
Single or combined Speed+/Size+ may also compose with direct Trigger/Timer
payload Multicast and direct Trigger/Timer payload Spread/Burst + Multicast when
the matching Multicast/Pattern and modifier gates are enabled. Bounded Chain
payload Multicast and Spread/Burst + Multicast can consume the same policy for
zero, one, or both Speed+/Size+ modifiers while Chain keeps one continuation
claim per hop.
Source policy supports ordinary source Speed+/Size+ simple launches, ordinary
source combined Speed+ Size+ simple launches, ordinary source Speed+/Size+
Multicast, ordinary source combined Speed+ Size+ Multicast, and ordinary source
Speed+/Size+ or combined Speed+ Size+ Spread/Burst + Multicast through generic
launch/spec creation. It also supports
`Bounce/Pierce -> Speed+/Size+ -> simple target emitter`, plus Bounce/Pierce
primary source Multicast or Spread/Burst + Multicast with zero, one, or both
Speed+/Size+ modifiers. Unmodified Bounce/Pierce source fanout with Trigger
simple payload must pass conservative event-budget accounting before registration:
`source_fanout_count * event_count_per_source * payload_fanout_count`, capped by
`MAX_EVENT_SOURCE_RESUMES_PER_CAST` and the source-kind payload-job caps. Bounce/
Pierce source Timer continuations schedule once per source emission or source
fanout sibling through `live_timer.lua`, not once per Bounce/Pierce event. Source
Speed+/Size+ plus Trigger payloads, simple no-fanout Bounce/Pierce combined
Speed+ Size+, direct source Bounce/Pierce/Chain Homing compositions, direct
source Chain, arbitrary nested source-event runtime, repeated same-actor Pierce
ticks, post-launch steering, and recursive source modifier stacks remain rejected
with stable classified reasons until separately proven or marked unsupported by
design.

Chain owns target acquisition, LOS, hop sequencing, duplicate suppression, and
the single Chain continuation claim for each hop. Chain payload emitters may
carry one bounded Trigger or Timer side continuation. Trigger side payloads route
through `live_trigger.lua`; Timer side payloads route through `live_timer.lua`.
Those side continuations use separate idempotency keys and may fire for fanout
siblings when `max_hops * chain_payload_fanout_count * side_payload_fanout_count`
stays under the Chain side-continuation caps. They must not advance Chain, create
Chain->Chain recursion, or turn fanout siblings into independent Chain branches.

Homing launch-time targeting semantics belong in
`scripts/spellforge/global/homing_launch_policy.lua` and reusable helpers in
`scripts/spellforge/global/live_homing.lua`. That policy owns Homing support/defer
decisions, bounded target metadata acquisition, launch-time forceVec computation,
soft-Homing registration decisions, Homing caps, and stable Homing rejection
reasons. Source launch and runtime payload jobs may carry Homing metadata next to
Speed+/Size+, fanout, Pattern, Trigger, Timer, Bounce, Pierce, or Chain metadata,
but event adapters and fanout code must not compute Homing targets or forceVec.
Homing may run only bounded launch-time scans or use the existing central
low-frequency soft-Homing manager. Current explicitly requested soft-Homing
registration remains single-projectile; multi-sibling soft fanout must defer
with a stable Homing policy reason until every sibling can be registered safely.
Ordinary Homing fanout should continue using launch-time `forceVec`. It must not add
per-projectile Spellforge Lua brains, per-frame actor scans, or high-frequency
retarget loops.

Size+ is special only because helper specs must be mutated before helper records
are materialized. That pre-materialization step must still route through the
shared launch modifier policy, not through Trigger-, Timer-, Bounce-, Pierce-,
Chain-, or source-event-specific code.

All new policy support remains behind the normal live 2.2c gates and the
relevant opcode/modifier gates. This policy must not add per-frame actor scans,
per-projectile Spellforge Lua brains, unbounded actor scans, post-launch
projectile mutation loops, or arbitrary recursive modifier stacking.

Pack H adds a support-truth closure contract on top of the runtime policy:

- `feature_matrix.analyze` is the public support truth and is backed by runtime IR when a plan has IR artifacts.
- `feature_matrix.lua`, `feature_matrix_ir.lua`, continuation planning, runtime job planning, and live smoke behavior must agree for representative supported and unsupported shapes.
- `SpellforgeDev.enable_ir_runtime_strict_v0` is smoke/dev-only. In strict mode, supported Trigger/Timer/Bounce/Pierce/Chain shapes must use the IR adapter/planner/job-planner path with zero unexpected fallback or mismatch.
- Legacy Trigger/Timer/Bounce/Chain paths may remain only as explicit debug/quarantine paths; strict smoke treats unexpected legacy fallback as a failure.
- Remaining unsafe v1 shapes should be classified as `unsupported_by_design`, while plausible future work should be classified as `future_deferred`; both must reject before enqueue.

#### Launch modifier policy review checklist

A new change violates this architecture if it:

- adds Speed+/Size+ mutation logic to `live_trigger.lua`, `live_timer.lua`,
  `live_bounce.lua`, `live_pierce.lua`, or `live_chain.lua`
- adds Speed+/Size+ mutation logic to a source event adapter instead of shared
  launch policy/source launch code
- adds event-specific support/deferred reasons such as
  `bounce_trigger_speed_plus_supported`
- copies Chain modifier inspection into another event adapter
- branches in an event adapter on payload Speed+/Size+
- branches in an event adapter on source Speed+/Size+
- adds Bounce/Pierce-specific Multicast/Spread/Burst fanout logic to
  `live_bounce.lua` or `live_pierce.lua`
- adds event-specific fanout reasons such as `bounce_multicast_supported` or
  `pierce_burst_supported`
- mutates helper specs outside `launch_modifier_policy.lua` for payload or source
  Size+
- applies Speed+/Size+ fields outside `runtime_job_planner.lua` or
  `launch_modifier_policy.lua` for payload jobs, or outside
  `launch_modifier_policy.lua` / generic source launch-spec application for
  source launches
- expands support by adding one-off Trigger/Timer/Bounce/Pierce/Chain modifier
  branches instead of broadening the shared policy
- copies Trigger/Timer side-payload builders into Chain instead of routing side
  continuations through the shared Trigger/Timer IR paths
- lets Chain fanout siblings create multiple independent Chain continuation
  claims
- computes Homing targets or forceVec in `live_trigger.lua`, `live_timer.lua`,
  `live_bounce.lua`, `live_pierce.lua`, `live_chain.lua`, source fanout code, or
  Chain target-provider code
- adds per-projectile Homing Lua brains, per-frame actor scans, or high-frequency
  retarget loops

A valid change:

- updates `launch_modifier_policy.lua` to inspect, accept, defer, or prepare a
  payload or source modifier combination
- updates `runtime_job_planner.lua` to apply policy-produced mutations to
  IR-planned jobs
- updates generic source launch/spec creation to apply policy-produced source
  mutations before launch
- updates generic source fanout and event-source budget code so Bounce/Pierce
  source siblings consume shared fanout semantics
- lets event adapters pass only event context, gates, and caps into the shared
  policy/runtime path
- lets Chain attach/preserve side-continuation metadata while Trigger/Timer
  adapters and the shared IR job planner own side-payload enqueue behavior
- updates `homing_launch_policy.lua` / `live_homing.lua` to broaden bounded
  launch-time Homing support or central soft-Homing registration behavior
- adds conformance smokes proving multiple event adapters consume the same policy
  without event-specific modifier code

Temporary legacy Chain compatibility code may preserve or copy policy-produced
modifier metadata while the migration is in progress. It must not recompute
Speed+/Size+ semantics, inspect modifiers independently, or become the template
for other event adapters.

---

## 5. Script Boundary

Spellforge uses OpenMW's PLAYER/GLOBAL split.

### PLAYER script responsibilities

The player script may:

- observe input/cast intent
- track selected spell metadata
- observe animation text keys
- receive cast-success authorization
- send authorized dispatch requests to global scripts
- show UI/debug messages

The player script should not:

- call `I.MagExp` directly
- create records
- own the runtime job queue
- execute opcode behavior
- do expensive per-frame parsing

### GLOBAL script responsibilities

The global script may:

- own backend handshake
- access SFP / `I.MagExp`
- own compiled plan cache
- own active job queue
- execute opcode behavior
- receive SFP hit events
- create runtime helper records if absolutely necessary
- apply/detonate/launch spell effects

All privileged runtime work belongs in global scripts.

---

## 6. Recipe Model

A Spellforge recipe is an ordered effect list.

Each entry is one of:

1. **Emitter effect**
   - vanilla magical effect
   - examples: Fire Damage, Frost Damage, Shield, Restore Health

2. **Prefix operator**
   - Spellforge effect that modifies the next emitter group
   - examples: Multicast, Spread, Burst, Speed+, Size+, Chain

3. **Postfix operator**
   - Spellforge effect that binds to the immediately preceding emitter group
   - examples: Trigger, Timer

There is no exposed recipe tree.

The compiler may internally produce a plan with scopes and payloads, but this is a compiled representation, not the authoring model.

---

## 7. Emitter Groups

An emitter group is one or more compatible consecutive vanilla magical effects that resolve as one spell emission.

### Grouping rules

Consecutive vanilla effects form one emitter group when:

- they are compatible in range
- no Spellforge control-flow operator appears between them
- the compiler can safely dispatch them as one emission

A group breaks when:

- range changes
- a Spellforge operator appears
- an effect cannot share dispatch semantics with the current group

### Ranges

The compiler recognizes at least:

- Self
- Touch
- Target

Range matters because Self effects resolve immediately, Touch effects resolve on contact, and Target effects generally travel as projectiles.

### Target emitter grouping

OpenMW can represent multiple target-range effects as a single projectile-like spell behavior. Spellforge should preserve this grouping where possible instead of naively launching each effect separately.

Bad:

```text
Fire Damage target
Frost Damage target
Shock Damage target

=> launch three unrelated projectiles
```

Preferred:

```text
Fire Damage target
Frost Damage target
Shock Damage target

=> one emitter group with three effects
```

---

## 8. Operator Binding Rules

### Prefix operators

Prefix operators bind forward to the next emitter group. v1 has no exceptions to this rule.

v1 prefix operators:

- Multicast
- Spread
- Burst
- Speed+
- Size+
- Chain

Example:

```text
1. Speed+
2. Multicast
3. Fire Damage on Target
4. Shield on Self
```

Binding:

```text
Speed+ and Multicast apply to Fire Damage only.
Shield is not affected.
```

### Postfix operators

Postfix operators bind backward.

They attach to the immediately preceding emitter group.

v1 postfix operators:

- Trigger
- Timer

Example:

```text
1. Fire Damage on Target
2. Trigger
3. Frost Damage on Target
```

Binding:

```text
Trigger binds to Fire Damage.
Frost Damage becomes Trigger's payload.
```

### Prefix Chains and Pattern Operators

A prefix chain is the sequence of prefix operators immediately preceding an emitter group. The entire chain binds to that emitter group as a unit.

All of these are valid chains:

```text
Multicast x5 → Fireball
Burst → Multicast x5 → Fireball
Multicast x5 → Burst → Fireball
Burst → Speed+ → Multicast x5 → Fireball
Size+ → Multicast x3 → Spread → Fireball
```

Pattern operators (Burst, Spread) shape the spatial distribution of emissions produced by a Multicast. They do not generate emissions themselves.

Binding rule: A prefix chain containing Burst or Spread is invalid unless the same prefix chain also contains Multicast. Pattern operators cannot apply to a single emission.

Invalid:

```text
Burst → Fireball
(Compile error: "Burst requires a Multicast in the same prefix chain")

Spread → Speed+ → Fireball
(Compile error: "Spread requires a Multicast in the same prefix chain")
```

Default pattern: A Multicast without an explicit Burst or Spread uses a default forward-spread distribution similar to vanilla Morrowind's multi-projectile behavior. This default is a runtime parameter, not a separate opcode.

---

## 9. Trigger and Timer Semantics

### Trigger

Trigger binds to the emitter group directly above it.

Trigger payload is:

```text
everything after Trigger until the end of the current scope
```

For v1's flat effect-list model, "current scope" usually means the rest of the recipe.

Trigger fires when its bound emitter resolves.

Resolution rules:

| Bound emitter range | Trigger fires when |
|---|---|
| Target | Projectile collides/resolves |
| Touch | Touch contact resolves |
| Self | Immediately on cast |

Trigger is allowed on any emitter range.

No range-dependent validation should reject Trigger.

### Timer

Timer binds to the emitter group directly above it.

Timer payload is:

```text
everything after Timer until the end of the current scope
```

Timer fires after its configured delay.

v1 range:

```text
0.5s to 5.0s
```

Timer should enqueue a delayed job. It must not block or spin.

### Resolution Cardinality

Trigger and Timer payloads fire once per emission of the bound emitter group, not once per group.

Example: `Multicast x5 → Fireball → Trigger → Frost`

Five Fireball projectiles launch. Each independently resolves its Trigger payload on hit. Total: 5 Frost emissions.

This matches Noita's behavior where each projectile is an independent entity carrying its own payload instance.

The payload plan itself is compiled once. Each payload execution runs the same plan from its own emission's resolution point (hit position for Target, touch point for Touch, caster for Self).

---

## 10. Multicast Semantics

Multicast is a prefix operator.

Multicast consumes only the next emitter group.

It does not multiply the entire remaining recipe.

Example:

```text
1. Multicast x3
2. Fire Damage on Target
3. Shield on Self
```

Execution:

```text
Fire Damage is emitted 3 times.
Shield is applied once.
```

This rule prevents trivial exponential blowups and makes player intent readable.

---

## 11. v1 Opcode Vocabulary

v1 currently contains eleven Spellforge operators.

| Opcode | Kind | Range / Parameters | Binding | Notes |
|---|---|---|---|---|
| Multicast | Prefix | count 2–8 | next emitter group | emits N copies |
| Spread | Prefix | forward cone preset/angle | next emitter group via prefix chain | pattern only; requires Multicast in same prefix chain |
| Burst | Prefix | spherical/hemisphere pattern | next emitter group via prefix chain | pattern only; requires Multicast in same prefix chain |
| Speed+ | Prefix | percent scalar | next emitter group | modifies projectile speed |
| Size+ | Prefix | percent scalar | next emitter group | modifies area/VFX scale where supported |
| Chain | Prefix | hops 1–5 | next emitter group | bounded target hopping |
| Bounce | Prefix | bounces 1-5 normal, 8 chaos | next emitter group | SFP-backed source bounce events |
| Pierce | Prefix | pierces 1-3 normal, 5 hard | next emitter group | SFP-backed pass-through through unique actors |
| Homing | Prefix | bounded force/target metadata | next emitter group | launch-time forceVec or central soft-Homing policy |
| Trigger | Postfix | none | previous emitter group | payload on resolution |
| Timer | Postfix | 0.5–5.0s | previous emitter group | payload after delay |

Any doc/code mentioning v1 `Damage+` is stale unless that opcode is explicitly reintroduced later.

---

## 12. Shot State

At runtime, opcodes operate on a mutable shot state.

A shot state represents one pending emission or payload execution.

Suggested fields:

```lua
{
    caster = <actor>,
    source_spell_id = "...",
    recipe_id = "...",
    plan = <compiled plan>,
    pc = 1,

    origin = <vector3>,
    direction = <vector3>,
    target = <object or nil>,
    hit_pos = <vector3 or nil>,

    recursion_depth = 0,
    projectile_count = 0,
    chain_hops_used = 0,

    modifiers = {
        multicast = 1,
        spread = nil,
        burst = nil,
        speed_scale = 1.0,
        size_scale = 1.0,
        chain_hops = 0,
    },
}
```

Shot state is copied when jobs fork.

A fork must increment or preserve counters deliberately.

Never let one branch mutate shared state used by another branch.

---

## 13. Compiled Plan

The compiled plan is the internal representation produced from a recipe effect list.

It should contain:

```lua
{
    recipe_id = "...",
    source_spell_id = "...",
    entries = {
        -- grouped emitters and bound operators
    },
    bounds = {
        max_recursion_depth = 3,
        max_projectiles = 32,
        max_chain_hops = 5,
    },
}
```

The exact table shape may evolve, but it must support:

- deterministic replay
- readable validation errors
- simple debug traces
- bounded execution
- future UI summaries

The compiled plan should be cached by recipe hash.

---

## 14. Recipe Hashing / Canonicalization

Canonicalization is mandatory.

The same recipe must hash to the same recipe ID.

The canonical representation should include enough data to distinguish gameplay behavior:

- ordered effect IDs
- ranges
- magnitude min/max
- area
- duration
- operator IDs
- operator parameters
- any version marker for the compiler format

Do not hash only high-level node names if the actual effect payload can differ.

Recommended canonical version field:

```text
spellforge-plan-v1
```

This allows future compiler changes without silently reusing stale cached plans.

---

## 15. Runtime Job Queue

The orchestrator owns a central active job queue.

No opcode should directly recurse into payload execution.

Instead, opcodes enqueue work.

### Job shape

Suggested:

```lua
{
    id = "...",
    kind = "execute_plan" | "emit_group" | "trigger_payload" | "timer_payload" | "chain_hop",
    recipe_id = "...",
    shot = <shot state>,
    wake_time = nil,
}
```

### Per-tick behavior

Each update:

1. Remove expired/dead jobs.
2. Select ready jobs.
3. Advance at most `MAX_JOBS_PER_TICK`.
4. Enqueue follow-up jobs if needed.
5. Drop jobs that exceed hard limits.

This keeps pathological recipes from freezing the game.

---

## 16. Hard Limits

Hard limits are enforced in both compiler and runtime.

### Required v1 limits

```lua
MAX_RECURSION_DEPTH = 3
MAX_LIVE_NESTED_CONTINUATION_DEPTH = 2
MAX_NESTED_CONTINUATION_JOBS_PER_CAST = 32
MAX_NESTED_FINAL_PAYLOAD_JOBS_PER_CAST = 32
MAX_PROJECTILES_PER_CAST = 32
MAX_CHAIN_HOPS = 5
MAX_SCAN_RADIUS = 2048
MAX_JOBS_PER_TICK = 16
```

### Compiler enforcement

The compiler should reject recipes that statically exceed obvious limits.

Examples:

- no emitter exists
- operator has invalid parameter
- Trigger has no preceding emitter group
- Timer has no preceding emitter group
- known static projectile count exceeds max

### Runtime enforcement

The runtime must still guard dynamically.

Examples:

- Trigger payload tries to exceed recursion depth
- Chain cannot find valid targets
- Burst/Multicast would exceed projectile cap
- too many jobs are already active
- scan radius exceeded

Runtime should drop excess work safely and log a warning in debug/dev builds.

---

## 17. Dispatch Strategy

Spellforge should choose the cheapest dispatch method that preserves behavior.

### Preferred dispatch tiers

| Runtime situation | Preferred method |
|---|---|
| visible projectile that may trigger later | SFP `launchSpell` |
| direct application to a known actor | SFP `applySpellToActor` if available |
| terminal AoE at a position | SFP `detonateSpellAtPos` if available |
| self effect | direct apply path if available |
| diagnostic/prototype projectile | existing 2.2b dispatch path |

The runtime should avoid using SFP projectile launches for every effect when a cheaper direct apply/detonation path is enough.

Projectile launches are expensive because they require continued collision/raycast tracking.

---

## 18. Hit / Resolution Events

For Target and Touch emitters, Trigger depends on knowing when an emission resolves. The runtime uses SFP hit events (`MagExp_OnMagicHit`) for this.

### Identity Requirement

A hit event must uniquely identify the emission it resolves. Without this, Multicast, Chain, and nested Triggers cannot route payloads correctly — a hit event for "spell X" is ambiguous when multiple emissions of spell X are in flight.

This identity requirement is architectural. How it is achieved is an implementation choice that may evolve.

### v1 Default Implementation Strategy

v1 uses per-emission helper spell records as structural cookies. This approach is chosen because current SFP hit events do not expose a unique projectile or cast instance ID; `spell_id` is the most specific identifier available.

The compiler may allocate one helper spell record per static emission slot in the compiled plan. A Multicast x5 emitter therefore has five emission slots. Each slot maps to the same logical emitter group and payload, but uses a distinct helper spell ID so SFP hit events can be routed unambiguously.

### Emission Slot Counting

- Each emitter group contributes 1 slot by default
- Multicast N multiplies the emitter group's slot count by N
- Pattern opcodes (Spread, Burst) do not add slots — they modify spatial distribution only
- Speed+, Size+ do not add slots — they modify launch parameters only
- For cap accounting, Chain N counts as N additional emission slots per initial emission, unless implemented later as a non-projectile direct-apply chain
- Trigger/Timer payloads contribute their own slots per trigger-projectile emission
- Nested Trigger/Timer continuation runtime is bounded by `MAX_LIVE_NESTED_CONTINUATION_DEPTH` (2); depth greater than 2 rejects before enqueue

### Static Cap Enforcement

Total static emission slots per recipe must not exceed `MAX_PROJECTILES_PER_CAST` (32). The compiler rejects recipes that statically exceed this cap with a readable error identifying the overflow.

Example rejection: "Recipe exceeds projectile cap: requires 48 slots, maximum is 32. Reduce Multicast counts or remove Chain hops."

### Example Slot Allocations

| Recipe | Slots |
|---|---|
| Fireball | 1 |
| Multicast x5 → Fireball | 5 |
| Fireball → Trigger → Frost | 2 |
| Multicast x5 → Fireball → Trigger → Frost | 10 |
| Fireball → Trigger → Multicast x5 → Frost | 6 |
| Multicast x5 → Fireball → Trigger → Multicast x3 → Frost | 20 |
| Multicast x3 → Fireball → Trigger → Multicast x3 → Frost → Trigger → Shock | 21 |

### Record Caching

Records are cached by recipe canonical hash. Same recipe produces the same set of records across casts. Editing a recipe produces a new hash and new records; old records may be retained or garbage-collected in future milestones.

Record creation may be lazy — deferred to first cast of a recipe — to avoid upfront cost on compile.

### Future Flexibility

If SFP adds a per-launch cookie field to hit events, the identity requirement can be satisfied without helper records. The architectural requirement (unique per-emission identification) remains; only the mechanism changes.

Implementations should keep the cookie abstraction separate from other compilation concerns so this substitution is local.

---

## 19. 2.2b Prototype Compatibility

The existing 2.2b code may still contain:

- marker effect records
- generated helper spells
- real-effect metadata tables
- diagnostic SFP launches
- debug fireball dispatch
- verbose cast/hit logging

These are acceptable as prototype scaffolding.

However, they must not be treated as the final 2.2c architecture.

Recommended policy:

- keep 2.2b working
- label prototype-only paths clearly
- avoid deleting useful diagnostics too early
- do not build new opcode runtime directly on the old recipe-graph compiler

---

## 20. Metadata Query / Cast Race Rule

The player-side intercept path must not depend on a slow async metadata query during the same cast input that needs interception.

Bad pattern:

```text
Use pressed
→ query global metadata
→ animation start key may fire before response
→ intercept misses arming window
```

Preferred pattern:

```text
Compile succeeds
→ player-side cache receives spellforge metadata
→ cast input uses local cache synchronously
→ intercept arms before animation start/release flow
```

Metadata may still be refreshed asynchronously, but the cast-critical path should use local cached knowledge.

---

## 21. Validation Rules

A valid v1 recipe must:

- contain at least one vanilla emitter group
- contain only known vanilla effects and known Spellforge operators
- satisfy all operator parameter ranges
- have every prefix operator followed by an emitter group within its binding range
- have every Trigger/Timer preceded by an emitter group
- have every prefix chain containing Burst or Spread also contain Multicast
- have total static emission slots not exceeding `MAX_PROJECTILES_PER_CAST`
- respect hard static caps where calculable
- avoid malformed generated records or invalid effect definitions

Validation should produce readable errors.

Example errors:

```text
Slot 1: Trigger has no emitter above it.
Slot 2: Burst requires a Multicast in the same prefix chain.
Slot 3: Multicast must be followed by an emitter group.
Slot 4: Spread requires a Multicast in the same prefix chain.
Slot 5: Timer duration must be between 0.5 and 5.0 seconds.
Recipe rejected: no vanilla emitter effects found.
Recipe rejected: 48 emission slots exceeds cap of 32.
```

---

## 22. Example Parses

### Example A: Fireball + Shield + Trigger + Resist Magic

Recipe:

```text
1. Fire Damage on Target
2. Shield on Self
3. Trigger
4. Resist Magic on Self
```

Grouping:

```text
Group 1: Fire Damage on Target
Group 2: Shield on Self
Trigger binds to Group 2
Payload: Resist Magic on Self
```

Execution:

```text
Fire Damage launches normally.
Shield applies to caster.
Shield is Self range, so it resolves immediately.
Trigger fires immediately.
Resist Magic applies to caster.
```

### Example B: Multicast + Fireball + Shield

Recipe:

```text
1. Multicast x3
2. Fire Damage on Target
3. Shield on Self
```

Binding:

```text
Multicast binds to Fire Damage only.
Shield is outside Multicast's operand.
```

Execution:

```text
Three Fire Damage emissions.
One Shield application.
```

### Example C: Fireball + Trigger + Burst + Frost

Recipe:

```text
1. Fire Damage on Target
2. Trigger
3. Burst
4. Multicast x4
5. Frost Damage on Target
```

Binding:

```text
Trigger binds to Fire Damage.
Trigger payload is [Burst, Multicast x4, Frost Damage].
Burst + Multicast x4 prefix chain binds to Frost Damage.
Prefix chain contains Multicast, so Burst is valid.
```

Execution:

```text
Fire projectile launches.
On impact, payload runs.
4 Frost projectiles emit from impact position in hemisphere pattern.
```

Emission slots:

```text
Fire Damage: 1 slot
Frost Damage: 4 slots (from Multicast x4)
Total: 5 slots
```

### Example D: Burst + Multicast + Fireball + Trigger + Frost

Recipe:

```text
1. Burst
2. Multicast x5
3. Fire Damage on Target
4. Trigger
5. Frost Damage on Target
```

Prefix chain analysis:

```text
Chain 1: [Burst, Multicast x5] → Fire Damage
- Valid: chain contains Multicast
- Burst provides hemisphere pattern
- Multicast provides count = 5

Trigger binds backward to Fire Damage group.
Frost Damage is Trigger's payload.

Chain 2: [] → Frost Damage
- Valid: empty prefix chain
- No Multicast: 1 emission per trigger
```

Emission slots:

```text
Fire Damage group: 5 slots (from Multicast)
Frost Damage group: 5 slots (one per fire emission's trigger)
Total: 10 slots, well under cap of 32
```

Execution:

```text
Cast: 5 fireballs launch in hemisphere distribution.
Each fireball, on hit, runs its own Frost payload.
5 Frost projectiles total, each originating from its
corresponding fireball's hit position.
```

---

## 23. Proposed Module Layout

Final 2.2c-oriented layout:

```text
scripts/spellforge/
├── player/
│   ├── init.lua                  -- 2.2b intercept, local metadata cache
│   ├── ui.lua                    -- future spellforge authoring UI
│   └── metadata_cache.lua        -- selected spell / compiled plan cache
│
├── global/
│   ├── init.lua                  -- backend events, SFP event registration
│   ├── compiler.lua              -- effect-list recipe -> compiled plan
│   ├── parser.lua                -- grouping and operator binding
│   ├── orchestrator.lua          -- central bounded job queue
│   ├── executor.lua              -- dispatch helpers and hit resolution
│   ├── records.lua               -- runtime helper record/cache utilities
│   └── canonicalize.lua          -- deterministic recipe hashing
│
├── shared/
│   ├── events.lua                -- event name constants
│   ├── opcodes.lua               -- v1 opcode definitions
│   ├── limits.lua                -- hard caps
│   ├── validate.lua              -- effect-list validation
│   └── log.lua                   -- logging
│
└── context/
    └── effects.lua               -- Spellforge custom magic effects
```

Existing files do not need to match this immediately, but new 2.2c work should move toward this shape.

---

## 24. Logging Policy

Debug logging is useful during 2.2b/2.2c development, but high-frequency runtime paths must be quiet by default.

Default:

```text
info: milestones, compile success/failure, backend availability
warn: dropped jobs, cap enforcement, missing backend
error: failed dispatch, invalid runtime state
debug: hit payload dumps, target filters, per-projectile traces
```

Do not stringify full hit payloads or target filter decisions at info level during normal gameplay.

---

## 25. Acceptance Criteria for 2.2c.0

2.2c.0 is a design/code realignment milestone.

It is complete when:

- `ARCHITECTURE.md` describes the effect-list model.
- Old graph/tree language is removed or clearly marked deprecated.
- `shared/opcodes.lua` matches the v1 eight-opcode vocabulary.
- hard limits live in one shared module or are clearly centralized.
- old compiler/executor paths are labeled prototype where applicable.
- no new opcode behavior is implemented yet.
- 2.2b intercept dispatch still works.

---

## 26. Acceptance Criteria for 2.2c.1

2.2c.1 introduces parser/compiler skeleton only.

It is complete when:

- effect-list parser exists
- compatible vanilla effects become emitter groups
- prefix operators bind forward
- Trigger/Timer bind backward
- Multicast consumes only the next emitter group
- Burst/Spread validation requires Multicast in same prefix chain
- readable validation errors exist
- compiled plan can be printed/debugged
- emission slot enumeration produces correct counts for Section 18 table
- no real projectile fanout is required yet

---

## 27. Acceptance Criteria for 2.2c.2

2.2c.2 introduces the orchestrator skeleton.

It is complete when:

- global job queue exists
- jobs advance at most `MAX_JOBS_PER_TICK`
- dummy jobs can enqueue sub-jobs
- recursion/projectile/job caps are enforced
- no synchronous recursive opcode execution exists
- debug logs show enqueue/advance/drop/complete

---

## 28. Opcode Implementation Order

Implement opcodes one at a time.

Recommended order:

1. Speed+ / Size+ as shot-state mutators
2. Multicast
3. Timer
4. Trigger
5. Spread
6. Burst
7. Chain

Do not implement all eight in one PR.

Chain requires a target-acquisition subsystem (finding valid next-hop targets within range). Budget for that work before Chain implementation.

---

## 29. Glossary

**Recipe**  
The ordered Morrowind spell effect list containing vanilla effects and Spellforge operator effects.

**Emitter**  
A vanilla magical effect or compatible group of effects that produces an actual spell emission or application.

**Emitter group**  
One or more compatible consecutive vanilla effects compiled as one runtime emission.

**Prefix operator**  
A Spellforge effect that modifies the next emitter group.

**Postfix operator**  
A Spellforge effect that binds to the previous emitter group.

**Prefix chain**  
The sequence of prefix operators immediately preceding an emitter group. Binds to that emitter group as a unit.

**Pattern operator**  
A prefix operator that modifies spatial distribution of emissions (Burst, Spread). Requires a Multicast in the same prefix chain.

**Emission slot**  
A static unit of potential emission in the compiled plan. Used for cap accounting and helper-record allocation.

**Trigger payload**  
The effect-list segment that runs when the bound emitter resolves.

**Compiled plan**  
Internal validated representation of the recipe used by the runtime.

**Shot state**  
Mutable runtime state passed through opcode execution.

**Job**  
A bounded unit of runtime work advanced by the orchestrator.

**Helper spell record**  
A dynamically created spell record used as a structural cookie so SFP hit events can be routed to the correct emission.

**SFP**  
Spell Framework Plus, exposed as `I.MagExp`.

**2.2b**  
Current working intercept-dispatch milestone.

**2.2c**  
Opcode runtime design and implementation milestone.
