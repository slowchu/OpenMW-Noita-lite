# Spellforge Opcode Runtime Design (Milestone 2.2c)

Status: Draft
Milestone: 2.2c.0 — architecture design, no implementation
Supersedes: n/a
Updates: ARCHITECTURE.md (to be integrated after review)

## 1. Goals

Milestone 2.2b proved the dispatch pipeline: a compiled Spellforge spell can be cast, intercepted, and dispatched as real effects through SFP's launchSpell. The dispatched effects are currently a direct copy of the recipe's root base spell — no transformations, no modifiers, no fan-out.

Milestone 2.2c introduces opcodes: the operations that give Spellforge recipes their expressive power. A recipe is no longer "a base spell wrapped in our pipeline" but "a program that produces one or more modified dispatches when cast."

The design priorities for 2.2c, in order:

**Noita-style expressive composition.** The player authors recipes by stringing together opcodes left-to-right. Modifiers apply to what follows. Multicast replicates. Trigger nests. Chain hops. Complexity emerges from composition, not from a large opcode vocabulary.

**Bounded engine cost.** A recipe cannot spawn unlimited projectiles, recurse unboundedly, or dominate a frame. Hard limits are enforced at compile time where possible and at runtime otherwise. A pathological recipe fails loudly at compile, not silently at runtime.

**Compile-once, execute-many.** Recipes compile to an execution plan. The plan caches. Casts load the plan and dispatch, never re-parsing the authored form. Compilation may be expensive; dispatch must be cheap.

**Clean separation of layers.** Authoring (player UI), compilation (validation and planning), dispatch (intercept to orchestrator), and orchestration (job queue advancing across ticks) are distinct concerns. Each layer has a narrow interface to the next.

**Leveraging 2.2b's working foundation.** The intercept pipeline, marker-range-based animation variant, SkillProgression cast-success gating, SFP launchSpell dispatch, and MagExp_OnMagicHit cookie routing are all proven. 2.2c extends the dispatch side — what happens between "cast authorized" and "projectiles fly" — without revisiting the intercept or hit-routing layers.

What this milestone does not address: UI for recipe authoring, balance tuning of individual opcodes, persistence of player-authored recipes across saves, NPC casting of Spellforge recipes. Those are future milestones.

## 2. Architecture Overview

Spellforge is a four-layer system. Each layer produces output that the next consumes; layers do not reach past their neighbors.

```
┌──────────────────────────────────────────────────┐
│  Authoring Layer                                 │
│  Player UI produces authored recipe              │
│  (data structure — opcode list + parameters)     │
└───────────────────┬──────────────────────────────┘
                    │ authored recipe
                    ▼
┌──────────────────────────────────────────────────┐
│  Compilation Layer                               │
│  Validates, computes bounds, emits plan          │
│  Caches compiled plans by recipe hash            │
└───────────────────┬──────────────────────────────┘
                    │ compiled plan + front-end spell
                    ▼
┌──────────────────────────────────────────────────┐
│  Dispatch Layer (existing from 2.2b)             │
│  Player casts front-end spell                    │
│  Intercept fires, authorization received         │
│  Loads compiled plan, enqueues initial job       │
└───────────────────┬──────────────────────────────┘
                    │ initial job
                    ▼
┌──────────────────────────────────────────────────┐
│  Orchestration Layer                             │
│  Owns active spell jobs                          │
│  Advances bounded N jobs per tick                │
│  Spawns sub-jobs for Multicast, Trigger, Chain   │
│  Ultimately calls SFP launchSpell per projectile │
└──────────────────────────────────────────────────┘
```

The authoring layer produces data. The compilation layer produces plans. The dispatch layer hands plans to the orchestrator. The orchestrator does the work.

**Key properties of this split:**

Compilation can fail. The authored recipe might exceed hard limits, be structurally invalid, reference unknown base spells, or recurse too deeply. Compilation failure produces a readable error and blocks the recipe from being registered as a castable spell. The player never casts an invalid recipe.

Dispatch is cheap. Cast happens, plan lookup happens, initial job enqueues. All work happens in subsequent orchestrator ticks.

Orchestration is bounded. The orchestrator enforces MAX_JOBS_PER_TICK. No matter how exotic a recipe, each frame advances at most N jobs. Complex recipes stretch across more ticks; they do not spike.

The orchestrator is the only layer that calls SFP. The only sink for recipe execution is `I.MagExp.launchSpell`. Everything the orchestrator does ultimately produces (or schedules, or conditionally produces) launchSpell calls.

**What 2.2b already provides:**

- Compiler producing front-end marker spells (we extend this to also produce compiled plans)
- Intercept handler catching player casts of front-end spells
- SkillProgression-gated cast authorization
- Dispatch spell creation and launchSpell call for single-emitter case (we generalize this to handle N emitters via the orchestrator)
- MagExp_OnMagicHit routing with cookie matching (we extend cookies to carry job lineage)

**What 2.2c introduces:**

- Opcode vocabulary: eight operations with defined semantics
- Shot state: mutable table carrying recipe modifiers through execution
- Execution plan: compiled representation of authored recipe
- Job queue and orchestrator: central scheduler for bounded advancement
- Per-opcode job advance functions: how Multicast, Trigger, Chain, etc. translate to queued work

## 3. Recipe Format

A recipe is a flat ordered list of opcodes. This matches Noita's wand model: spells in slots, read left to right, each one operating on accumulated state.

### Authored form

The authored form is what the player's UI produces and what the mod stores for user-saved recipes. It is designed to be human-readable and round-trippable through JSON or Lua table serialization.

```lua
{
    name = "Triple Scatter Fireball",
    description = "Three fireballs in a forward spread",
    opcodes = {
        { op = "multicast", count = 3 },
        { op = "spread" },
        { op = "speed_plus", amount = 1 },
        { op = "emitter", base_spell_id = "fireball" },
    },
}
```

Every opcode entry has an `op` field naming the operation. Additional fields carry opcode-specific parameters. Emitters are opcodes too; they reference a vanilla Morrowind spell by ID.

The list is ordered and meaningful. `multicast` before `spread` before `speed_plus` before `emitter` produces a different result than the same opcodes in a different order. This matches Noita's non-shuffle wand semantics.

### Compiled form

Compilation transforms the authored recipe into an execution plan. The plan contains validated opcodes, pre-computed bounds, and cached lookups.

```lua
{
    name = "Triple Scatter Fireball",
    recipe_hash = "a3f9c2...",       -- for cache keying
    front_end_spell_id = "Generated:0xba",  -- vanilla ID for UI spellbook
    compiled_at = 1776990000,        -- compile timestamp
    estimated_projectiles = 3,        -- upper bound
    estimated_recursion_depth = 0,    -- no Trigger/Chain nesting
    estimated_duration_seconds = 2,   -- for UI hints
    opcodes = {
        { op = "multicast", count = 3 },
        { op = "spread" },
        { op = "speed_plus", amount = 1 },
        { op = "emitter",
          base_spell_id = "fireball",
          -- additional fields cached at compile time:
          base_spell_record_ref = <ref>,
          range = "target",
          real_effects = { ... },  -- from base spell
        },
    },
}
```

The compiled form may annotate opcode entries with cached data that compilation computed. For emitters this means holding a reference to the base spell record and a copy of its real effects, so dispatch doesn't re-query `core.magic.spells.records` on every cast.

### Validation

Compilation validates against several rules. Any violation fails compilation with a readable error.

**Structural rules:**

- The recipe must contain at least one emitter. A recipe with no emitters has no effect and is rejected.
- Opcodes that require a following operand (Multicast, Trigger, Timer, Spread, Burst, Chain, Speed+, Size+) must have at least one subsequent opcode available to operate on. A recipe ending in a modifier with nothing after it is rejected.
- Nested Triggers beyond MAX_RECURSION_DEPTH are rejected.

**Parameter range rules:**

- Multicast count: 2 to 8 inclusive.
- Timer duration: 0.5 to 5.0 seconds.
- Chain hops: 1 to 5 inclusive.
- Other opcodes have opcode-specific parameter constraints (detailed in section 6).

**Resource bound rules:**

- Estimated total projectiles must not exceed MAX_PROJECTILES_PER_CAST. Computed by walking the opcode list and multiplying Multicast counts along the chain.
- Estimated recursion depth must not exceed MAX_RECURSION_DEPTH. Each Trigger or Timer adds one level.
- Unknown emitter base spell IDs are rejected.

**What validation does not enforce:**

Balance. A recipe that spawns the maximum 32 projectiles with maximum damage is legal. Gameplay balance is a separate concern; the compiler's job is safety, not fairness.

### Recipe hashing

Each authored recipe produces a deterministic hash based on its opcode sequence and parameters. The hash is the cache key. Recompiling an identical recipe hits the cache and returns the previously-compiled plan. Editing any opcode parameter produces a different hash and triggers recompile.

This matches the 2.2a caching pattern. Players can iterate on recipes quickly; unchanged recipes don't regenerate their dispatch infrastructure.

### Example recipes

A few recipes at varying complexity to illustrate the format.

**Minimal — single fireball:**

```lua
{
    name = "Fireball",
    opcodes = {
        { op = "emitter", base_spell_id = "fireball" },
    },
}
```

Compiles to `estimated_projectiles = 1`, no multicast, no chain. Behaves exactly like base Morrowind fireball.

**Simple multicast:**

```lua
{
    name = "Triple Fireball",
    opcodes = {
        { op = "multicast", count = 3 },
        { op = "emitter", base_spell_id = "fireball" },
    },
}
```

Compiles to `estimated_projectiles = 3`. Three fireballs launched from the cast position.

**Modified multicast:**

```lua
{
    name = "Fast Triple Fireball",
    opcodes = {
        { op = "speed_plus", amount = 2 },
        { op = "multicast", count = 3 },
        { op = "emitter", base_spell_id = "fireball" },
    },
}
```

Compiles to 3 projectiles with 2x speed applied. Speed+ modifies shot state before Multicast fans out; all three inherit the modified state.

**Trigger chain:**

```lua
{
    name = "Fireball of Fireball",
    opcodes = {
        { op = "trigger" },
        { op = "emitter", base_spell_id = "fireball" },
        { op = "emitter", base_spell_id = "fireball" },
    },
}
```

The first emitter is the projectile that flies. On hit, the Trigger fires the second emitter at the hit position. Compiles to `estimated_recursion_depth = 1`.

**Chain example:**

```lua
{
    name = "Lightning Cascade",
    opcodes = {
        { op = "chain", hops = 3 },
        { op = "emitter", base_spell_id = "shock bolt" },
    },
}
```

Fires one shock bolt. On hit, seeks another target within range and fires again. Repeats up to 3 hops.

---

End of draft sections 1-3.

Remaining sections to write:

4. Shot State (data structure and mutation rules)
5. Job Queue (orchestrator design)
6. The 8 v1 Opcodes (detailed specs)
7. Emitters (how recipes reference vanilla spells)
8. Hard Limits (enforced constants)
9. Composition Rules (opcode interaction semantics)
10. Validation (compile-time and runtime checks)
11. Integration with 2.2b (where this plugs in)
12. Future Extensions (deferred opcodes and design directions)
