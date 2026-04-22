# Architecture

This document describes the design of a Noita-inspired spellcrafting system for OpenMW 0.51+. It is the working specification and should be updated as the implementation evolves. If code and this document disagree, that is a bug in one of them; fix the bug.

## Overview

The mod lets players author spells as ordered recipes of modifier and effect primitives, compile those recipes into runtime `ESM::Spell` records added to the player's spellbook, and cast them like any other spell. On cast, a Lua executor interprets the recipe's payload graph and dispatches sub-spells through Spell Framework Plus (SFP), producing Noita-style behaviors: multicast fan-outs, on-hit trigger chains, timed detonations, piercing and chaining projectiles, and so on.

This is a **compiler plus runtime executor** architecture, not an extension of vanilla spellmaking. The vanilla spellmaking altar cannot express what we need; OpenMW 0.51's runtime record creation API is what makes this possible for the first time.

## Goals

- Player-facing spell builder UI with a fixed opcode vocabulary and click-to-place interaction.
- Authored recipes compiled into real `ESM::Spell` records added to the player's spellbook and cast through the normal cast path (spell stance, quickcast, hotkey, etc.).
- Event-driven payload execution via SFP's `MagExp_OnMagicHit`.
- Support for ordered chains of modifiers, scope-opening triggers, and nested trigger payloads up to a bounded depth.
- Deliberate cost and progression policy, not accidental behavior inherited from the vanilla cast path we bypass.

## Non-Goals

- Intercepting or rewriting the player's arbitrary vanilla spell casts. We only execute our own compiled composite spells.
- Runtime creation of novel magic effect records. Our effect vocabulary is a fixed alphabet injected through the 0.51 load context at startup.
- True Noita endgame density (hundreds of branching projectiles per cast). Our scope is "readable modifier-rich chains," not "fill the screen."
- Homing projectiles in v1. True target-seeking is prohibitively expensive under the current Lua physics model.
- Persistent world hazards (walls of fire, ice floors). Out of scope for SFP's design.
- Multiplayer correctness. OpenMW itself is single-player and TES3MP is not a target.

## Foundation

### Required engine version

OpenMW 0.51 or later. The critical features we depend on:

- Runtime spell record creation via `core.magic.spells.createRecordDraft` + `world.createRecord` ([#8342]).
- Custom magic effect records injected through the load context ([#8791]).
- `core.magic.spells.records` read access for referencing existing vanilla spells from recipe nodes.

0.51 RC is acceptable for development but the API surface for load-context injection is flagged work-in-progress. Budget for minor refactoring when 0.51 ships stable.

### Required mods

- **Spell Framework Plus (`I.MagExp`)** — provides `launchSpell`, `applySpellToActor`, `detonateSpellAtPos`, and the `MagExp_OnMagicHit` / `MagExp_OnEffectApplied` / `MagExp_OnEffectTick` / `MagExp_OnEffectOver` event surface. All projectile execution routes through this framework.
- **MaxYari Lua Physics** — transitive dependency of SFP.

### Known engine issue to avoid

OpenMW RC [#9069] does not gracefully handle invalid effects on spells/enchantments/potions. The compiler **must** validate generated effect lists before calling `world.createRecord`. Do not let a malformed record reach the engine — it can crash.

## Conceptual Model

### Two layers

```
┌──────────────────────────────────────────────┐
│  UI Layer (PLAYER script)                    │
│  - Crafter window                            │
│  - Click-to-place interaction                │
│  - Recipe editing / validation feedback      │
│  - Persists recipes via storage API          │
└────────────────────┬─────────────────────────┘
                     │ Save recipe → Compile request
┌────────────────────▼─────────────────────────┐
│  Compiler (GLOBAL script)                    │
│  - Recipe graph → ESM::Spell records         │
│  - Effect list assembly                      │
│  - Hash-based canonicalization               │
│  - Register with ActorSpells:add             │
└────────────────────┬─────────────────────────┘
                     │ Player casts compiled spell
┌────────────────────▼─────────────────────────┐
│  Runtime Executor (GLOBAL script)            │
│  - Dispatch on cast / on hit                 │
│  - Payload resolution                        │
│  - Chain / multicast / trigger execution     │
│  - Cookie table for in-flight projectiles    │
└──────────────────────────────────────────────┘
```

The UI layer never calls `I.MagExp` or `world.createRecord` directly. All privileged operations happen in global scripts, reached through event dispatch. This follows the same PLAYER/GLOBAL split pattern validated by the multicast prototype.

### The compilation metaphor

A recipe is source code. The compiler produces a small bundle of `ESM::Spell` records — one per distinct projectile-emitting node in the graph — plus an out-of-engine metadata table linking each generated spell ID to its payload node. The player's spellbook contains only the **front-end** record; internal node records are implementation detail and should never appear in the spellbook UI.

When the player casts the front-end spell, the engine handles animation, magicka deduction (if any), and the first projectile launch through SFP. From that point forward, the executor takes over: each `MagExp_OnMagicHit` event is a lookup into the metadata table, which tells us what payload to resolve next.

## Data Model

### Recipe graph

A recipe is a tree of nodes. The root is always an emitter. Each emitter may have a payload, which is itself a sequence of modifier nodes terminating in either an emitter (chained projectile) or a terminal effect (AoE detonation, self-buff, etc.).

Example — `Fireball + Trigger → [Multicast 5 + Spread 360° + Fireball + Trigger → [Frost AoE 10ft]]`:

```
Emitter(Fireball)
└── Payload
    ├── Modifier(Multicast, count=5)
    ├── Modifier(Spread, arc=360°)
    ├── Emitter(Fireball)
    │   └── Payload
    │       └── Terminal(FrostAoE, radius=10ft)
```

### Node kinds

| Kind | Purpose | Examples |
|---|---|---|
| **Emitter** | Produces one or more projectiles / touch effects. Terminates a modifier chain. | Fireball, Frostbolt, Shock |
| **Launch modifier** | Prefix operator applied to the next emitter in sequence. Parameterized. | Multicast(N), Spread(θ), Damage+(%), Speed+(%), Size+(%) |
| **Scope opener** | Opens a payload attached to the most recent emitter. | Trigger |
| **Terminal effect** | Non-projectile effect resolved at a world position. | AoE blasts, self-buffs |

Launch modifiers compose left-to-right into a **launch context** that is consumed by the next emitter. A Trigger opens a payload scope that the compiler fills with everything up to the end of the payload or the next Trigger at the same level (bounded by recursion cap).

### The nine v1 opcodes

| Opcode | Kind | Parameter | Semantics |
|---|---|---|---|
| `Multicast` | Launch modifier | `count ∈ [2..8]` | Emits N copies of the next emitter |
| `Spread` | Launch modifier | `arc ∈ [0..360]°` | Distributes multicast copies across an arc |
| `Damage+` | Launch modifier | `percent` | Scales damage magnitudes on the next emitter |
| `Speed+` | Launch modifier | `percent` | Scales projectile velocity |
| `Size+` | Launch modifier | `percent` | Scales projectile radius / AoE / VFX scale |
| `Chain` | Launch modifier | `hops ∈ [1..5]` | On hit, redirect to next-nearest actor, N hops max |
| `Pierce` | Launch modifier | `count ∈ [1..3]` | Projectile continues through N actors before terminating |
| `Trigger` | Scope opener | — | Opens a payload scope on the previous emitter |
| `Timer` | Scope opener | `seconds` | Like Trigger, but detonates after T seconds regardless of impact |

Element is **not** an opcode. Morrowind already supplies all elemental damage effects; the composer picks the emitter's element at craft time. Homing is not an opcode (see Performance Architecture).

### Spread axis

When a multicast fans its projectiles, the axis of rotation is the most ambiguous parameter. Default behavior:

- Initial cast (from caster): axis is **world up** (projectiles fan horizontally).
- Triggered fan-out (from impact point): axis is **impact surface normal** for arcs ≤ 180°, **world up** for 360°.

This keeps wall-splats feeling like splats and ground-bursts feeling like novas. If playtesting demands per-modifier axis control, add it as an opcode parameter in v1.1.

## Compiler Layer

### Flow

1. Receive a recipe graph from the UI layer via `RecipeCompileRequest` event.
2. **Validate**:
   - Every Trigger has a preceding emitter at the same level.
   - Recursion depth ≤ configured cap (default 3).
   - Total emitter count across the tree ≤ configured cap (default 20).
   - All magnitudes and parameters in allowed ranges.
   - Every referenced base spell / effect ID exists.
3. **Canonicalize**: serialize the recipe deterministically and hash it (e.g., FNV-1a over a canonical string form). This produces a stable `recipe_id`.
4. **Cache check**: if `recipe_id` already exists in the compiled-records table, reuse it.
5. **Generate records**: walk the tree depth-first. For each emitter, build an `ESM::Spell` draft with the effect list assembled from the emitter's base effects plus any launch-modifier transformations that apply to damage/duration/area. Each record gets a generated ID of the form `spellforge_<recipe_id>_n<node_index>`.
6. **Register**: call `world.createRecord` on each record. Store the returned record references in the metadata table keyed by generated ID.
7. **Add front-end to spellbook**: the root emitter's generated record is added to the player's spells via `ActorSpells:add`. Internal nodes are not added.
8. **Return**: send `RecipeCompileComplete` back to the UI layer with the front-end spell ID so the crafter can display a success state.

### Canonicalization is mandatory

Without it, every cast of "the same" recipe creates fresh records and the record store grows without bound over a play session. Two recipes that serialize identically must produce the same `recipe_id` and reuse the same records. Order matters for ordered opcodes (Multicast before Trigger is not the same as Trigger before Multicast), so canonical form is positional, not sorted.

### Record metadata table

For every generated record, the metadata table stores:

```lua
{
  recipe_id     = "ab3f...",
  node_path     = {1, 2, 1},        -- path in the original recipe tree
  payload       = <payload subtree>,  -- resolved at hit time
  launch_ctx    = <launch context>,  -- compiled from preceding modifiers
  parent_recipe = <recipe ref>,
}
```

This table is the single source of truth for the executor. It lives in global script state and is persisted via the storage API.

## Runtime Executor

### Entry points

1. **Player cast** of a front-end compiled spell. Detected via an `onSpellCast` handler on the global controller. The executor wraps the initial launch with any root-level launch modifiers (multicast at the root, spread, etc.) and dispatches through SFP.
2. **Hit event** (`MagExp_OnMagicHit`). The executor looks up the hit spell's ID in the metadata table. If it's one of ours, it resolves the payload.
3. **Timer fire**. Scheduled via `async:newSimulationTimer` when a Timer opcode is compiled into a node. On fire, the executor runs the payload at the projectile's last known position.

### Cookie table

Every in-flight SFP projectile that belongs to us is tagged in a cookie table keyed by the projectile's spell instance ID:

```lua
{
  [instance_id] = {
    generated_spell_id = "spellforge_ab3f_n2",
    caster             = <actor>,
    spawn_time         = <simulation_time>,
    recipe_id          = "ab3f...",
  }
}
```

Entries have a TTL equal to the projectile's lifetime plus a small grace period. A periodic sweep reaps expired entries to prevent leaks from projectiles that despawn without triggering a hit event.

### Payload resolution

On hit, the executor:

1. Looks up the cookie for the impacting projectile.
2. Uses `generated_spell_id` to find the node's payload in the metadata table.
3. Walks the payload left-to-right, accumulating a launch context for each emitter, and dispatching each emitter either as a new SFP launch (for projectile emitters) or as a direct application (for terminal effects — see below).
4. For each new projectile launched, writes a new cookie entry.

### Performance-critical dispatch rule

**Do not reflexively use `I.MagExp.launchSpell` for every sub-emission.** Each SFP projectile costs us ongoing Lua Physics raycasts for its entire lifetime. Reserve `launchSpell` for the primary cast and for triggered sub-projectiles whose flight behavior the player is meant to see.

For payloads that are effectively instant-detonate, prefer:

- **`I.MagExp.detonateSpellAtPos(pos, spellId, radius, ...)`** — one-shot AoE at a world position. No projectile, no raycast tail. Use this for "on hit, frost damage in 10ft."
- **`I.MagExp.applySpellToActor(target, spellId, ...)`** — direct application to a specific actor. Use when the payload is a debuff on the hit target.

For secondary projectiles where SFP's event broadcast is unnecessary, consider `world.launchProjectile` (engine-native, uses vanilla collision instead of Lua Physics). The tradeoff is you lose `MagExp_OnMagicHit` and must handle `onProjectileHit` yourself — only worth it when you're sure no further chaining is needed.

Rule of thumb:

| Situation | Use |
|---|---|
| Player-visible primary cast | `launchSpell` |
| Triggered projectile that will itself trigger | `launchSpell` |
| Terminal AoE at impact point | `detonateSpellAtPos` |
| Terminal debuff on hit target | `applySpellToActor` |
| Leaf projectile with no further payload | `world.launchProjectile` (optional optimization) |

## Script Organization

```
scripts/spellforge/
├── player/
│   ├── init.lua              -- Player-side entry, handshake, input
│   ├── ui.lua                -- Crafter window, click-to-place
│   ├── ui_palette.lua        -- Opcode palette rendering
│   ├── ui_slots.lua          -- Slot widget + validation feedback
│   └── storage.lua           -- Persistence of authored recipes
├── global/
│   ├── init.lua              -- Global entry, SFP handshake reply
│   ├── compiler.lua          -- Recipe → ESM::Spell records
│   ├── executor.lua          -- Hit/timer dispatch, cookie table
│   ├── canonicalize.lua      -- Recipe hashing
│   ├── records.lua           -- createRecord wrapper + cache
│   └── policy.lua            -- Cost, XP, fatigue, failure
├── shared/
│   ├── opcodes.lua           -- Opcode definitions (single source)
│   ├── validate.lua          -- Recipe validation (used by UI + compiler)
│   └── events.lua            -- Event name constants
├── context/
│   └── effects.lua           -- Custom magic effect records (load context)
└── tests/
    ├── smoke_compiler.lua    -- Compiler smoke test
    ├── smoke_executor.lua    -- Executor smoke test
    └── smoke_chain.lua       -- End-to-end chain test
```

### Player ↔ Global event contract

Player scripts cannot call `I.MagExp` directly. All privileged work happens in global scripts, reached by event. Event names are constants in `shared/events.lua`.

| Event | Direction | Payload |
|---|---|---|
| `Spellforge_CheckBackend` | P → G | — |
| `Spellforge_BackendReady` | G → P | — |
| `Spellforge_BackendUnavailable` | G → P | `{reason}` |
| `Spellforge_CompileRecipe` | P → G | `{recipe, request_id}` |
| `Spellforge_CompileResult` | G → P | `{request_id, ok, spell_id, error?}` |
| `Spellforge_DeleteCompiled` | P → G | `{spell_id}` |

Any gameplay action that requires the backend blocks until the handshake completes, with a 3-second timeout falling back to `UNAVAILABLE`. Pattern inherited from the multicast prototype.

## UI Layer

### Interaction model

**Click-to-place**, not drag-and-drop. The player clicks a palette item to "pick up" that opcode (cursor/status changes to reflect the held item), then clicks a slot to place it. Right-click clears the held item. Clicking an occupied slot with nothing held picks up its contents.

Rationale: controller and keyboard support come naturally, `mouseMove` plumbing is avoided, and validity feedback is cleaner because the source and destination are known at hover time.

### Window composition

- **Palette** (left): grouped opcode icons, organized by category (Emitters, Launch Modifiers, Scope Openers).
- **Slot board** (center): the recipe being edited. For v1, a flat ordered list of slots with nested payload containers for Trigger/Timer scopes. Nesting is visible; the recipe's tree structure is shown literally rather than hidden in a flat sequence.
- **Inspector** (right): preview of the currently selected slot or held opcode, computed magicka cost, validation errors, expected behavior summary.
- **Status line** (bottom): `Placing: Multicast x5 — click a slot` / `Recipe valid — cost: 87 magicka` / `Invalid: Trigger at slot 3 has no preceding emitter`.

### Validity feedback

Before and during placement, slots highlight green/red based on whether the held opcode would be valid there. Examples:

- Trigger held: slots immediately following any emitter highlight green; others red.
- Emitter held: all empty slots green.
- Launch modifier held: all empty slots green, but the inspector warns if there is no subsequent emitter in the chain.

Validity rules live in `shared/validate.lua` and are used by both the UI (for highlighting) and the compiler (for authoritative rejection).

### Controller and keyboard

- D-pad / arrows: move focus across slots and palette items.
- A / Enter: pick up (from palette or occupied slot) or place (into empty slot).
- B / Esc: clear held / close window.
- X / 1-9 hotkeys: direct palette selection.
- Y / Tab: cycle between palette, board, and inspector regions.

### Magic Window Extender integration

If Magic Window Extender is installed, compiled front-end spells should appear in the magic window with a distinct icon or border treatment identifying them as composed spells, and tooltips should display the recipe summary. This uses MWE's modder API rather than overriding the built-in magic window. If MWE is not installed, compiled spells still appear in the vanilla spell list (because they're real records via `ActorSpells:add`) but without the enhanced tooltip.

## Performance Architecture

### Budget targets

- Idle (no casts in flight): negligible overhead beyond UI resident memory when the crafter is open.
- Single cast with 1 primary + 5 multicast triggers + 5 terminal AoEs: no observable frame impact on mid-range hardware.
- Worst-case legal recipe (depth 3, 20 emitters): brief stutter acceptable but no freeze.

### Hard caps (enforced in compiler)

| Cap | Default | Rationale |
|---|---|---|
| Recursion depth | 3 | Prevents exponential fan-out in pathological recipes |
| Total emitters per recipe | 20 | Bounds worst-case compile size |
| Multicast count per node | 8 | Combined with depth cap, limits total projectile count |
| Chain hops | 5 | Linear cost; this is a soft cap |
| Pierce count | 3 | Same |

### Hard caps (enforced in executor)

| Cap | Default | Rationale |
|---|---|---|
| Concurrent SFP projectiles per player | 30 | Raycast load limit |
| Concurrent SFP projectiles per cast | 20 | Prevents one cast from starving others |
| Cookie table size | 500 | Sanity check; TTL reap should keep this well under cap |

Exceeding an executor cap silently drops further launches for that cast and logs a warning. This is preferable to engine instability.

### Record lifecycle

Compiled records are canonicalized and cached. Identical recipes reuse the same records across the session. A session-end cleanup is not strictly necessary (records are discarded with the world on game exit) but a manual "clear compiled records" admin action should exist for testing.

## Progression and Balance Policy

Because composite spells bypass the vanilla cast path, nothing related to cost, skill progression, fatigue, or failure is automatic. The `policy.lua` module is the single point of decision for all of these, and its defaults should be configurable via the settings menu.

### Magicka cost

Computed at compile time and cached on the front-end record. A recipe's cost is the sum of its emitter base costs, multiplied per-emitter by the compounding multiplier of its launch modifiers, summed across the full tree including triggered payloads. Multicast multiplies linearly by count (5 fireballs cost roughly 5× one fireball, not less). Damage+ multipliers scale cost quadratically to discourage trivially stacking them.

The player is charged once at cast time, at the front-end record's cost. `isFree = true` is passed to every internal `launchSpell` to prevent re-deducting.

### Skill progression

Destruction / Alteration / etc. XP is awarded based on the primary school of the root emitter, scaled by magicka spent, applied once per cast. If the recipe contains emitters of multiple schools, each school receives a proportional share. Implemented via the `SkillProgression` interface.

### Fatigue

Standard vanilla fatigue cost applies to the front-end cast and is not multiplied by multicast. The composed spell is one cast, and the player's body casts it once.

### Failure chance

Computed from the caster's skill in the primary school versus the compiled spell's cost, using the vanilla failure formula. On failure, magicka is still partially consumed per vanilla rules and no payload runs.

### Reflection

Reflection applies to the front-end cast only. Triggered sub-projectiles and AoEs do not roll for reflection — they are framework-dispatched effects at known world positions, not caster-to-target spell transactions. This is a deliberate simplification; document it clearly in the help text so players understand the mechanic.

## Storage

OpenMW's storage API persists authored recipes. Layout:

```
spellforge:recipes:<recipe_id> → <serialized recipe>
spellforge:spellbook:<player_id>:<recipe_id> → <metadata>
spellforge:settings → <user settings>
```

Recipes are stored per-recipe rather than as one large blob so individual recipe edits don't rewrite the whole store. The compiler's record cache is not persisted — records are regenerated on load from the stored recipes.

## Known Limitations

- **SFP dependency**: we rely on framework contracts that are not part of the engine. Changes to SFP's event surface require our updates. Pin to a known-good SFP version and document it.
- **Lua Physics cost**: every in-flight SFP projectile pays raycast cost per tick. The architecture mitigates this but does not eliminate it. True high-density spellcasting (Noita endgame) is not a design target.
- **0.51 RC API instability**: the load context for custom effect injection is flagged work-in-progress. Expect minor refactoring before 0.51 stable.
- **No multiplayer consideration**: the design assumes single-player OpenMW. TES3MP or future multiplayer OpenMW would need a rethink of event timing and authority.
- **UI does not support live recipe editing during combat**: the crafter opens as a menu mode that pauses the game. Designed as a preparation tool.
- **Mad's dehardcoded spellcasting MR is not yet merged**: if and when it lands, we may be able to replace parts of the executor with native engine hooks. Design the executor with clean seams so that refactor is feasible.

## Deferred / Not in v1

Explicit deferrals, following the discipline established in the multicast prototype:

- **Homing** — prohibitively expensive without engine changes. Park indefinitely.
- **Reflect / Bounce** — straightforward to add but not core to v1. Target v1.1.
- **Delay** (as distinct from Timer) — relatively niche. v1.1.
- **Lifesteal / Manasteal** — requires post-hit damage resolution. Clean to add after v1 ships. v1.1.
- **Seeking** — cheap homing variant. Evaluate after v1 based on observed performance headroom. v1.2.
- **Gravity / Heavy / Light** — contingent on Lua Physics exposing per-body gravity multipliers. Investigate then decide.
- **Boomerang** — novelty modifier. v1.2 or later.
- **Split-on-timer** — likely emergent from Timer + Multicast in the executor; may not need a dedicated opcode.
- **Orbiting / Satellite projectiles** — new projectile behavior mode, not a modifier. Separate feature; defer.
- **Persistent world hazards** — fire patches, ice walls. Not appropriate for SFP. Separate mod category.
- **DoT patches at impact** — technically possible; defer until base system is stable.
- **Wand metaphor / randomized draw order** — Noita's wand mechanic proper (with shuffle, charges, recharge time) is a large design space. v1 ships with deterministic linear execution; wand mechanics are a v2 consideration.
- **NPC usage of composed spells** — v1 is player-only. NPCs continue to cast vanilla spells.

## Roadmap

### v1.0 — Foundation

- Nine opcodes: Multicast, Spread, Damage+, Speed+, Size+, Chain, Pierce, Trigger, Timer.
- Compiler with canonicalization and caching.
- Executor with cookie table and performance-tiered dispatch.
- Click-to-place UI with validity feedback and controller support.
- Cost, XP, fatigue, failure, reflection policy.
- Recipe persistence via storage API.
- Smoke test harness for compiler, executor, and chain behavior.
- MWE integration where available.

### v1.1 — Expansion

- Reflect, Delay, Lifesteal/Manasteal opcodes.
- Per-opcode axis control for Spread.
- Recipe import/export as shareable strings.
- Tutorial sequence for new players.

### v1.2 — Quality

- Seeking (limited homing).
- Gravity modifier if Lua Physics supports it.
- Performance profiling surfaced in debug mode.
- Recipe library / favorites UI.

### v2.0 — Depth

- Wand mechanic: shuffle, charges, recharge.
- NPC composed spell casting.
- Evaluate whether Mad's dehardcoded spellcasting has landed and plan a native-hooks migration.

## Glossary

**Recipe** — The player-authored graph of opcodes that describes a spell.

**Opcode** — A single primitive in the recipe vocabulary (e.g., Multicast, Trigger, Fireball).

**Emitter** — An opcode that produces one or more projectiles or effects.

**Launch modifier** — A prefix opcode that modifies the next emitter.

**Scope opener** — An opcode (Trigger, Timer) that opens a payload scope on the previous emitter.

**Payload** — The sub-graph of opcodes that runs when a scope opener fires.

**Front-end record** — The `ESM::Spell` record added to the player's spellbook representing the root of a compiled recipe.

**Node record** — An internal `ESM::Spell` record representing a non-root emitter in a compiled recipe. Not added to the spellbook.

**Cookie** — A metadata entry in the executor's in-flight projectile table, linking a specific projectile instance to its recipe node.

**Canonicalization** — Deterministic serialization of a recipe such that equivalent recipes hash to the same ID and reuse compiled records.

**SFP** — Spell Framework Plus; the `I.MagExp` interface. All projectile launches and hit events route through it.

**MWE** — Magic Window Extender; an optional dependency for enhanced spell list UI integration.

## Appendix A: Example compile

Recipe:

```
[Fireball] [Trigger] [Multicast 5] [Spread 360°] [Fireball] [Trigger] [FrostAoE 10ft]
```

Recipe tree (after parsing):

```
Emitter("fireball_base")
└── Payload
    ├── LaunchMod(Multicast, count=5)
    ├── LaunchMod(Spread, arc=360)
    ├── Emitter("fireball_base")
    │   └── Payload
    │       └── Terminal("frost_aoe_base", radius_ft=10)
```

Canonical form (sketch):

```
E:fireball_base|T|M:5|S:360|E:fireball_base|T|X:frost_aoe_base:r10
```

Hash: `ab3f9c2e` (recipe_id)

Records generated:

- `spellforge_ab3f9c2e_n0` — front-end fireball (added to spellbook)
- `spellforge_ab3f9c2e_n1` — inner fireball (metadata only)

Metadata:

```
spellforge_ab3f9c2e_n0:
  payload: [Multicast(5), Spread(360), launch → n1]
spellforge_ab3f9c2e_n1:
  payload: [detonate → frost_aoe_base radius=10ft]
```

Runtime trace on cast:

1. Player casts `spellforge_ab3f9c2e_n0`. SFP launches the front-end fireball. Cookie written.
2. Fireball impacts target. `MagExp_OnMagicHit` fires. Executor looks up cookie → finds `n0`'s payload.
3. Executor walks payload: Multicast(5) + Spread(360) → launches 5 copies of `n1` fanned in a 360° ring around world-up at the impact position. 5 cookies written.
4. Each `n1` fireball flies until impact or lifetime expiry.
5. On each `n1` impact: `MagExp_OnMagicHit` fires. Executor looks up cookie → finds `n1`'s payload.
6. Payload resolves: `detonateSpellAtPos(impact_pos, frost_aoe_base, radius=10ft)`. Terminal; no further chaining.

Total SFP projectiles in flight at peak: 6 (1 + 5). Total AoE detonations: up to 5. Within budget.

## Appendix B: Smoke test expectations

The smoke test harness (`tests/`) is a separate `.omwscripts` file that validates plumbing independently of gameplay. It should be runnable without affecting a player save.

- `smoke_compiler.lua`: constructs a hardcoded recipe graph, runs it through the compiler, asserts that records are created and that re-compiling the same recipe reuses them.
- `smoke_executor.lua`: registers a known recipe, issues a synthetic `MagExp_OnMagicHit` for the front-end spell, asserts the executor dispatches the expected payload.
- `smoke_chain.lua`: end-to-end test from player cast to terminal AoE, asserting cookie table lifecycle and cleanup.

Failures in smoke tests are logged loudly and block gameplay loading. Smoke tests are intended to catch breakage from OpenMW and SFP updates early, not to validate gameplay correctness.
