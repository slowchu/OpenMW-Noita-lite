# Roadmap

Status as of start of Phase 2. Updated at milestone boundaries.

## Phase 1 — Foundation and Compiler (Complete)

### What shipped

The compiler milestone is done. Ten smoke assertions pass cleanly against a real OpenMW 0.51 RC1 instance with SFP installed. Specifically:

- Recipe data model with nine opcodes declared (though the list has since evolved — see Phase 2 opcode section below).
- Recipe validator enforcing structural rules (Trigger preceded by emitter, recursion depth, parameter ranges, known base spell IDs).
- Canonicalization with stable FNV-1a hashing. Identical recipes produce identical recipe IDs.
- Compiler that converts recipes into real `ESM::Spell` records via `core.magic.spells.createRecordDraft` + `world.createRecord`.
- Record cache keyed by recipe_id. Identical recipes reuse compiled records.
- Front-end compiled spells appear in the player's spellbook via `ActorSpells:add`, visible and selectable in the vanilla spell UI.
- PLAYER/GLOBAL script split with event-based dispatch.
- SFP handshake with three-second timeout, addressed replies via `actor:sendEvent`.
- Smoke test harness with ten assertions covering trivial compile, multicast recipe, recipe_id stability, cache reuse, invalid recipe rejection, and readable error surfacing.

### What was deliberately not proven in Phase 1

- No compiled spell has been cast. The cast path from player input through SFP to projectile to impact is untested against dynamically-created records.
- SFP's `launchSpell` has not been called with a `Generated:0xNN` engine ID. Unknown whether SFP's internal lookups handle dynamically-created records correctly.
- `MagExp_OnMagicHit` has not been observed firing for our spells, either from vanilla cast or from scripted launch.
- No runtime behavior — multicast fan-out, trigger payloads, chain logic — has been implemented. The compiled records are inert.
- Save/load behavior untested.
- No opcode beyond the trivial emitter has been exercised at runtime.
- No recipe has been composed through UI.

### Lessons captured

Several design decisions or gotchas surfaced during Phase 1 that are worth preserving:

- OpenMW's Lua sandbox does not expose LuaJIT's `bit` library. Use `openmw.util.bitXor` etc. for bitwise operations.
- `core.sendGlobalEvent` dispatches TO global scripts. Global-to-local replies must use `actorObject:sendEvent(name, payload)` and therefore must include the sender actor in P→G request payloads.
- `world.createRecord` assigns the engine-chosen `Generated:0xNN` RefId regardless of what `.id` was set on the draft. All downstream engine calls must use `newRecord.id`, not the draft's intended ID. Store both.
- `async:newSimulationTimer` is the saveable variant and requires a registered TimerCallback. `async:newUnsavableSimulationTimer` accepts inline closures and is correct for this project's transient timers (handshakes, TTLs).
- `types.Actor.spells` is iterable via `pairs()`, `ipairs()`, or numeric index. `:getAll()` does not exist. `:has()` does not exist.
- Colon syntax matters: `async:newX(...)` not `async.newX(...)`.

These belong in a permanent `LESSONS.md` or similar reference in the repo so future contributors and future-you don't relearn them.

---

## Phase 2 — Executor and Playable v1

Phase 2 produces a playable v1 mod: a working runtime executor that casts compiled spells, chains payloads, and fans out projectiles, plus the UI to author recipes. This is where the mod becomes demonstrable.

### Scope

Phase 2 ends when a player can:

1. Open a crafter window in-game.
2. Compose a recipe using the v1 opcode vocabulary.
3. Save it. The compiled spell appears in their spellbook.
4. Cast it. The spell behaves according to its recipe — projectiles fan out per Multicast + Burst, triggers fire payloads on impact, timers detonate delayed effects, chains hop between targets.
5. Iterate on recipes: edit, recompile, see the changes take effect.

### v1 opcode vocabulary — updated

Refined through Phase 1 retrospective and early Phase 2 discussions. Eight opcodes confirmed viable against current OpenMW 0.51 RC1 and current SFP:

1. **Multicast** (count 2–8) — emits N copies of the next emitter.
2. **Spread** — forward cone distribution for multicast projectiles. No parameters; spacing is fixed ~12–15° per projectile. Cone aligns with emission direction and caster aim.
3. **Burst** — spherical distribution for multicast projectiles using Fibonacci sphere algorithm. Auto-converts to hemispherical when emission is on/near a surface (reflects into-surface directions to opposite hemisphere).
4. **Speed+** — scales projectile velocity via SFP's `launchSpell` speed param.
5. **Size+** — scales AoE radius on the compiled spell's effect parameters. VFX scale is bonus if SFP supports it.
6. **Trigger** — scope opener. Attaches a payload to the preceding emitter. Fires payload on each impact (including per-bounce, if Bounce lands in v1.1).
7. **Timer** (seconds 0.5–5.0) — scope opener. Fires payload after T seconds regardless of impact, at projectile's last known position.
8. **Chain** (hops 1–5) — on impact, redirect to next-nearest actor for N hops.

### Deferred to v1.1 — pending framework updates

- **Damage+** — viable if the compiled spell's effect magnitude is honored at cast time. Confirm with SFP dev before promoting.
- **Pierce** (count 1–3) — deferred pending SFP's collision-off + ray-pierce API change.
- **Bounce** (count 1–5) — deferred pending SFP hit-type distinction API.
- **Heavy** — per-projectile gravity via SFP launch params. Deferred pending confirmation that Lua Physics gravity is exposed per-projectile in SFP.

### Deferred to later versions

- **Seeking** — cheap homing variant. v1.2 after perf profiling.
- **Lifesteal / Manasteal** — post-hit damage-scaled effect on caster. v1.2.
- **Boomerang** — re-evaluable once SFP acceleration API lands.
- **Homing** — park indefinitely unless someone specifically wants to own per-tick target acquisition.
- **Persistent hazards, DoT patches, orbiting projectiles** — separate mod category.
- **Wand metaphor with shuffle/charges/recharge** — v2 consideration.
- **NPC casting of composed spells** — v2.

---

## Phase 2 Milestones

Four milestones, roughly sequential. Each is independently testable and ends at a demonstrable state.

### Milestone 2.1 — First Cast

Prove the end-to-end cast path works against a compiled record. Smallest possible executor.

**Goals:**
- Cast a hardcoded trivial recipe (single emitter, no modifiers) from the player's spellbook.
- Watch the projectile fly via SFP's `launchSpell`.
- Watch it damage a target via vanilla spell effects.
- Observe `MagExp_OnMagicHit` fire for the compiled spell.

**What this milestone proves:**
- SFP's `launchSpell` accepts `Generated:0xNN` engine IDs.
- Compiled `ESM::Spell` records produce correct damage when cast.
- The hit event subscription actually fires for our spells.
- The player's standard cast input (spell stance + cast key) works on compiled spells without special handling.

**Deliverables:**
- Global-side `onSpellCast` (or equivalent) hook that intercepts casts of compiled front-end spells and routes through the executor.
- Executor's basic "cast" function that resolves the root emitter and calls `launchSpell` with appropriate params.
- Hit event subscriber that logs incoming events, verifies the cookie lookup path works, and does nothing else.
- One smoke test extension that casts a hardcoded compiled spell and asserts the hit event fires within N seconds (or times out with a clear failure).

**Open unknowns this milestone resolves:**
- Whether SFP's `launchSpell` honors dynamically-created spell IDs.
- Whether OpenMW's cast pipeline routes dynamic records through `MagExp_OnMagicHit` normally.
- Whether the vanilla cast path applies damage, consumes magicka, awards XP on dynamic records.

**Note:** If any of those resolve negatively, the executor architecture in ARCHITECTURE.md needs revisiting. This milestone exists specifically to surface those unknowns early.

### Milestone 2.2 — Runtime Executor Core

Build out the runtime logic for the v1 opcode vocabulary.

**Goals:**
- Cookie table: in-flight SFP projectiles tracked by instance ID with payload pointers.
- Payload resolution: on `MagExp_OnMagicHit`, look up cookie, walk payload opcodes, dispatch next emissions.
- Multicast + Spread + Burst: fan-out logic with correct 3D distribution math (Fibonacci sphere for Burst, forward cone for Spread).
- Trigger: payload attachment and execution at impact position.
- Timer: `newUnsavableSimulationTimer` scheduling payload execution at last known position.
- Chain: on-hit proximity query via `nearby.actors`, launch at next-nearest target, decrement hop counter.
- Speed+, Size+: parameter passthrough to `launchSpell` and effect magnitude scaling.
- Hard caps enforced: max concurrent projectiles per player, max per cast, cookie table size, TTL reap.

**Performance-tiered dispatch:**
- `launchSpell` for player-visible primary casts and for trigger sub-projectiles.
- `detonateSpellAtPos` for terminal AoE payloads (the frost-damage-in-10ft case).
- `applySpellToActor` for direct on-hit debuffs.

**Deliverables:**
- `global/executor.lua` with cookie table, dispatch logic, payload walker.
- Extension of smoke test suite to cover:
  - Multicast fan-out (count and direction verified).
  - Trigger payload firing at impact position.
  - Timer firing at expected simulation time.
  - Chain hopping to a second target and terminating after N hops.
- Updated architecture doc with any API discoveries.

**What this milestone proves:**
- The full v1 opcode vocabulary works at runtime.
- The cookie table survives realistic cast volumes.
- Hard caps actually trigger correctly under pathological recipes.
- Cross-opcode composition (Multicast + Trigger + Chain) works without surprises.

**Open design decisions to resolve:**
- Burst emission axis when triggered on a surface impact: confirm Fibonacci sphere + hemispherical-reflection-near-surface produces good visual feel.
- Trigger payload inheritance: does a Multicast'd projectile inherit the Trigger payload of its parent? (Likely yes — each projectile carries its own payload reference from the recipe graph.)
- Chain target selection rules: nearest unhit actor in radius R? Exclude unconscious/dead targets? Configurable per-recipe later?

### Milestone 2.3 — Policy Module

Make the gameplay policy decisions explicit and implemented. Composite spells bypass the vanilla cast path, so nothing is automatic.

**Goals:**
- Magicka cost calculation: computed at compile time from recipe structure, cached on front-end record. Linear in Multicast count, quadratic in damage scaling, additive across modifier tree.
- Charge-once semantics: cost deducted at front-end cast only. All internal `launchSpell` calls pass `isFree = true`.
- Skill XP: awarded based on root emitter's primary school, scaled by magicka spent, applied once per cast. Uses OpenMW's `SkillProgression` interface.
- Fatigue: standard vanilla fatigue cost on front-end cast, not multiplied by multicast count.
- Failure chance: vanilla formula applied to compiled spell's cost vs. caster's skill. On failure, magicka partially consumed, no payload runs.
- Reflection: applies to front-end cast only. Sub-projectiles and AoEs do not roll for reflection.
- "Not enough magicka" UI feedback matching vanilla.

**Deliverables:**
- `global/policy.lua` with each decision as a named function, documented with rationale.
- Settings menu hooks for policy tuning (where applicable — not everything should be configurable).
- Smoke test extensions for cost calculation stability across equivalent recipes.
- Player-visible display: the crafter shows recipe cost before saving.

**What this milestone proves:**
- Playtest feedback will be meaningful rather than dominated by broken economics.
- The mod feels like Morrowind magic rather than a minigame bolted on.
- Recipes have real cost/benefit tradeoffs that reward thoughtful composition.

### Milestone 2.4 — UI / Crafter

The player-facing authoring interface. This is what makes the mod a product rather than a tech demo.

**Goals:**
- Crafter window that opens as a UI mode (so it pauses the game and plays with the mode stack).
- Click-to-place interaction: click palette item to pick up, click slot to place, right-click to cancel.
- Palette: grouped opcode icons by category (Emitters, Launch Modifiers, Scope Openers).
- Slot board: flat ordered list with visible nested payload containers for Trigger/Timer scopes.
- Inspector panel: selected slot details, computed cost, validation errors, expected-behavior summary.
- Status line: current held opcode, recipe validity, cost.
- Validity feedback: green/red slot highlighting based on whether the held opcode is valid there.
- Controller and keyboard support from day one, not retrofitted.
- Save/load flow: authored recipe persists via `openmw.storage`, compile action produces a spellbook entry.
- Magic Window Extender integration if present: compiled spells render with distinct treatment and recipe-summary tooltips.

**Deliverables:**
- `player/ui.lua`, `player/ui_palette.lua`, `player/ui_slots.lua` implemented against the real compiler/executor.
- Visual asset pass (opcode icons, slot frames, palette layout).
- `player/storage.lua` reads/writes authored recipes via `openmw.storage`.
- Integration test: compose a recipe in-game, save, cast, confirm behavior matches inspector prediction.

**What this milestone proves:**
- The system is usable by a player who has not read the source code.
- Recipes are readable back from the UI (not just authored forward).
- The iteration loop — compose → cast → adjust — feels tight.

**Open design decisions:**
- How to present trigger nesting visually: indented nested containers? Collapsible? Fixed depth limit with a visible depth indicator?
- How to handle recipe overflow: what does the UI show when a recipe hits the 20-emitter cap?
- Naming compiled spells: auto-generated from root emitter ("Fireball Composite"), or player-provided?

---

## Cross-cutting concerns (not milestones)

Track these alongside milestones, not as sequential blockers.

### LESSONS.md / DESIGN_CHANGES.md

Start maintaining two separate documents early in Phase 2:

- `LESSONS.md` — non-obvious OpenMW/SFP gotchas discovered during implementation. Permanent reference. Start with the Phase 1 lessons enumerated above.
- `DESIGN_CHANGES.md` — decisions and their rationale over time. E.g., "opcode count changed from 10 to 9 to 8 (dropped Element Swap, then merged Spread parameters into preset)". Captures process, not state.

Both are useful as the project grows and as other developers engage with the code.

### SFP dev collaboration

The SFP dev is an active stakeholder. Maintain:

- A running question list for them that gets asked in batches rather than drip-fed.
- A shared understanding of which v1.1 features depend on their framework work.
- Credit in README and in-game when the mod ships.

Specifically pending confirmation from SFP dev at start of Phase 2:

1. Does `launchSpell` work cleanly with `Generated:0xNN` engine IDs? (Unblocks Milestone 2.1.)
2. Is gravity exposed per-projectile on `launchSpell`? (Unblocks Heavy in v1.1.)
3. Does the planned Pierce API also support Bounce semantics, or would that be a separate API change? (Affects v1.1 scope.)
4. Does SFP honor damage magnitudes on compiled `ESM::Spell` records, or override them? (Determines whether Damage+ is v1 or v1.1.)

### Performance profiling

Does not block any milestone but should be a background concern starting in Milestone 2.2. Specifically:

- Average `launchSpell` cost per projectile with realistic recipes.
- Peak concurrent projectiles during stress-test recipes.
- Cookie table memory footprint over a long play session.
- Recipe compile time distribution.

No target numbers yet — we need a baseline. Capture on a test machine and record in the repo for comparison across Phase 2 changes.

### Playtest capture

Once Milestone 2.4 lands, gather informal playtest feedback before declaring v1 done. Worth a week or two of friends/community testing before public release. Specifically watch for:

- Recipes that feel broken or unexpected (executor bugs).
- Recipes that feel mechanically correct but boring (design / opcode vocabulary issues).
- UI friction points (crafter usability).
- Cost/XP feel (policy tuning).

---

## v1 Release

Defined as: Milestones 2.1 through 2.4 complete, playtest feedback incorporated, documentation updated to reflect final opcode vocabulary, credits assigned, public release post drafted.

This is not a Phase 2 milestone itself — it's the Phase 2 exit criterion.

## What's not in Phase 2

Everything past v1: the v1.1 opcode expansions (Damage+, Pierce, Bounce, Heavy), the v1.2 nice-to-haves (Seeking, Lifesteal), the v2 ambitions (wand mechanics, NPC usage, native-hook migration if dehardcoded spellcasting lands). Phase 3 scope will be determined after v1 ships and the actual playtest data is in hand.

One principle worth stating explicitly: **the mod ships when v1 is solid, not when every tier of deferred content is complete.** A shipped v1 with eight well-tuned opcodes is more valuable than an unshipped v1 with twelve opcodes that all sort of work. Defer aggressively.
