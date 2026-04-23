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
   These are control/modifier effects: Multicast, Trigger, Timer, Speed+, Size+, Spread, Burst, Chain.

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
- homing projectiles unless a cheap bounded implementation becomes available
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

Prefix operators bind forward.

They apply to the next emitter group only unless explicitly defined otherwise.

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

v1 contains exactly eight Spellforge operators.

| Opcode | Kind | Range / Parameters | Binding | Notes |
|---|---|---|---|---|
| Multicast | Prefix | count 2–8 | next emitter group | emits N copies |
| Spread | Prefix | forward cone preset/angle | next emitter group | modifies aim vectors |
| Burst | Prefix | bounded burst count | next emitter group | spherical/Fibonacci burst |
| Speed+ | Prefix | percent scalar | next emitter group | modifies projectile speed |
| Size+ | Prefix | percent scalar | next emitter group | modifies area/VFX scale where supported |
| Chain | Prefix | hops 1–5 | next emitter group | bounded target hopping |
| Trigger | Postfix | none | previous emitter group | payload on resolution |
| Timer | Postfix | 0.5–5.0s | previous emitter group | payload after delay |

Any doc/code mentioning v1 `Damage+` or `Pierce` is stale unless those are explicitly reintroduced later.

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

For Target and Touch emitters, Trigger depends on knowing when an emission resolves.

The runtime should use the best available event source, currently expected to be SFP hit events such as `MagExp_OnMagicHit`.

A major implementation question:

```text
Does the hit event identify a projectile/cast instance, or only a spell ID?
```

If only spell ID is available, the runtime must not rely on `spell_id` alone for per-projectile cookies once Multicast exists.

Possible fallback strategies:

- per-launch unique helper spell records
- spell ID + attacker + timestamp queue
- SFP-supported launch cookie, if available
- bounded active launch table keyed by enough available payload fields

This must be solved before real Multicast + Trigger behavior is considered complete.

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
- respect hard static caps where calculable
- avoid malformed generated records or invalid effect definitions

Validation should produce readable errors.

Example errors:

```text
Slot 1: Trigger has no emitter above it.
Slot 3: Multicast must be followed by an emitter group.
Slot 5: Timer duration must be between 0.5 and 5.0 seconds.
Recipe rejected: no vanilla emitter effects found.
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
4. Frost Damage on Target
```

Binding:

```text
Trigger binds to Fire Damage.
Trigger payload is Burst + Frost Damage.
Burst binds to Frost Damage.
```

Execution:

```text
Fire projectile launches.
On impact, payload runs.
Burst emits bounded Frost projectiles from impact position.
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
- readable validation errors exist
- compiled plan can be printed/debugged
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

**Trigger payload**  
The effect-list segment that runs when the bound emitter resolves.

**Compiled plan**  
Internal validated representation of the recipe used by the runtime.

**Shot state**  
Mutable runtime state passed through opcode execution.

**Job**  
A bounded unit of runtime work advanced by the orchestrator.

**SFP**  
Spell Framework Plus, exposed as `I.MagExp`.

**2.2b**  
Current working intercept-dispatch milestone.

**2.2c**  
Opcode runtime design and implementation milestone.
