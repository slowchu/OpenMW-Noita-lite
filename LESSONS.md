# Spellforge Lessons

This document records project lessons that should guide future Spellforge work.

It is not the architecture specification. `ARCHITECTURE.md` is authoritative for current design. This file captures practical lessons, engine discoveries, debugging failures, and process rules that should prevent repeated mistakes.

---

## Phase 1 Lessons — Carried Forward

### 1. Lua version discipline

OpenMW scripts use Lua 5.1/LuaJIT sandbox semantics.

Rules:

- Do not use Lua 5.3+ syntax or operators.
- Avoid native bitwise operators such as `&`, `|`, `~`, `<<`, `>>`.
- Use OpenMW-provided bit helpers where needed.
- Keep syntax conservative unless verified inside OpenMW.

### 2. API discipline

Do not invent OpenMW, SFP, or mod-framework APIs.

Rules:

- Prefer documented APIs.
- Prefer known integration patterns from working mods.
- If an API is uncertain, inspect docs/source or run a focused probe first.
- Do not let agents assume functions exist based on naming intuition.

### 3. Context discipline

Respect OpenMW's script-context boundaries.

PLAYER scripts own:

- input
- UI
- per-player state
- selected spell metadata cache
- animation text-key observation
- local intercept state

GLOBAL scripts own:

- world changes
- SFP / `I.MagExp` calls
- compiled plan cache
- helper records
- runtime orchestration
- cross-cell logic

Cross-context communication is event-based only.

### 4. Timer discipline

Use timers only where timers are appropriate.

Good uses:

- backend handshake timeouts
- request/response timeouts
- delayed Timer opcode payloads
- smoke-test timeouts

Bad uses:

- synchronizing cast dispatch to animation by guessing seconds
- replacing semantic animation text keys with hardcoded delays

Use `async:newUnsavableSimulationTimer` for transient waits and explicit bounded timeouts.

### 5. Record ID discipline

Keep ID layers explicit.

Important categories:

- **Logical IDs**: Spellforge bookkeeping IDs.
- **Engine IDs**: actual IDs returned by OpenMW record creation, including generated IDs.
- **Recipe IDs**: deterministic canonical hashes for authored recipes.
- **Emission slot IDs**: internal compiled-plan slots for v1 per-emission helper records.

For 2.2c+, per-emission helper spell records are internal runtime cookies. They should never become the player-facing recipe model.

Maintain explicit mappings:

```text
recipe_id → emission_slot → helper engine spell ID → logical emitter group / payload
```

### 6. Iteration discipline

Known iteration patterns:

- Actor spellbook membership checks are done by linear scan over iterable entries.
- Core spell records are iterated by value-side `record.id`.
- Do not assume table keys are the stable public IDs unless verified.

### 7. Logging discipline

Logging should support debugging without overwhelming runtime paths.

Recommended levels:

- `INFO`: phase boundaries, backend availability, compile success/failure, smoke assertions.
- `WARN`: cap enforcement, dropped jobs, missing optional backend, recoverable inconsistency.
- `ERROR`: failed dispatch, failed record creation, invalid runtime state, include the underlying `pcall` error.
- `DEBUG`: hit payload dumps, target filter spam, per-projectile traces, verbose record inspection.

Avoid raw `print` outside the shared logger.

High-frequency runtime paths should not log at `INFO` by default.

---

## Phase 2.1 Lessons

### 1. Cast-path discovery first

The first executor milestone should be observational.

Before payload logic, prove:

- player cast intent can be detected
- selected spell metadata can be identified
- global dispatch can be reached
- SFP launch can occur
- SFP hit events can be observed

Do not mix cast-path discovery with full opcode behavior.

### 2. Smoke harness behavior

For cast tests:

- include clear manual-cast guidance
- include timeout diagnostics
- fail loudly instead of hanging silently
- assert actual runtime results, not only metadata fields

---

## Phase 2.2b Lessons — Intercept Dispatch

### 1. Interception uses text-key release, not fixed timers

Player intercept dispatch should be keyed to the spellcast animation's semantic text keys.

Rules:

- Arm on the appropriate `<variant> start` key.
- Dispatch on `<variant> release`.
- Abort on `<variant> stop`.
- Do not use fixed-second timers to guess cast release timing.

The text-key approach is more robust across self/touch/target variants and animation-speed differences.

### 2. Cast success uses engine authority

The working 2.2b success gate uses OpenMW's skill progression signal:

```text
I.SkillProgression.addSkillUsedHandler
SKILL_USE_TYPES.Spellcast_Success
```

This avoids reimplementing vanilla chance-to-cast logic in Lua.

The handler should remain narrowly scoped to active Spellforge intercept state. If future OpenMW payloads expose actor or spell identity, use that information to tighten matching.

### 3. Metadata gating before interception is transitional

2.2b currently queries global metadata with `Spellforge_QuerySpellMetadata` before arming intercept.

This proved the dispatch path, but it is transitional.

Future cleanup should move Spellforge spell metadata into a player-side cache so cast input can arm intercept synchronously.

Do not rely on async request/response timing during the same input event that starts a cast animation.

### 4. Root-only dispatch scope is prototype scaffolding

2.2b dispatches only root emitter `real_effects` and records root cookies for hit observability.

This is prototype scaffolding used to prove:

```text
intercept → global dispatch → SFP launch → SFP hit observation
```

2.2c replaces this with:

- effect-list parsing
- emitter groups
- per-emission helper records
- compiled plans
- central bounded job queue

Do not treat the 2.2b root-only dispatch model as the final opcode runtime.

---

## Phase 2.2c Planning Lessons — Opcode Runtime

### 1. Recipe model discipline

The player-facing Spellforge recipe is an ordered Morrowind spell effect list.

Rules:

- Vanilla effects are emitters.
- Spellforge custom effects are operators.
- The recipe is not a separate exposed graph/tree model.
- The compiler may create internal scopes and plans, but those are compiled representations only.

Do not reintroduce the old recipe-graph model as the authoring model.

### 2. Prefix binding discipline

For v1, prefix operators bind forward to the next emitter group.

There are no prefix-binding exceptions in v1.

Multicast consumes only the next emitter group, not the entire remaining recipe.

### 3. Pattern operator discipline

Burst and Spread are pattern modifiers.

Rules:

- Burst and Spread do not create emissions by themselves.
- Burst and Spread are valid only in a prefix chain that also contains Multicast.
- If Multicast has no explicit Burst or Spread, runtime uses the default Multicast distribution.

Invalid examples:

```text
Burst → Fireball
Spread → Speed+ → Fireball
```

Both should fail validation with readable errors.

### 4. Trigger and Timer cardinality discipline

Trigger and Timer payloads execute once per emission of the bound emitter group, not once per group definition.

Example:

```text
Multicast x5 → Fireball → Trigger → Frost
```

Expected behavior:

- five Fireball emissions launch
- each Fireball carries its own Trigger payload
- each hit executes Frost from that Fireball's resolution point
- the payload plan is compiled once
- each payload execution receives its own shot state

### 5. Per-emission helper record discipline

Spellforge v1 uses per-emission helper spell records as structural cookies for SFP hit routing.

Rules:

- Helper records are internal runtime implementation details.
- Helper records should not appear as player-facing recipe records.
- Total static emission slots per recipe are capped by `MAX_PROJECTILES_PER_CAST`.
- Same canonical recipe should reuse the same helper-record set.
- Editing a recipe produces a new hash and may produce a new helper-record set.

This is acceptable for v1 because the record count is bounded.

### 6. Hard-cap discipline

Required v1 limits:

```lua
MAX_RECURSION_DEPTH = 3
MAX_PROJECTILES_PER_CAST = 32
MAX_CHAIN_HOPS = 5
MAX_SCAN_RADIUS = 2048
MAX_JOBS_PER_TICK = 16
```

Static compiler checks should reject obvious overflows.

Runtime checks must still enforce caps because not all behavior is statically knowable.

### 7. No synchronous recursion

No opcode should recursively execute payloads directly.

Trigger, Timer, Multicast, Burst, and Chain must enqueue bounded jobs.

Runtime fanout should be advanced by the central orchestrator, with at most `MAX_JOBS_PER_TICK` jobs advanced per update.

---

## OpenMW 0.51 Load Context Lessons

### 1. Custom records and load context

Custom magic effect records and custom ingredient records must be registered at content-load time through a load-context script.

They cannot be created at runtime through `world.createRecord`.

Custom spell records can be created either:

- at load context, or
- at runtime.

### 2. Manifest ordering

The `.omwscripts` manifest flag for load-context scripts is `LOAD:` followed by the script path.

`LOAD` entries must appear before `GLOBAL` and `PLAYER` entries.

Example:

```text
LOAD:   scripts/mymod/context/effects.lua
GLOBAL: scripts/mymod/global/init.lua
PLAYER: scripts/mymod/player/init.lua
```

Load-context scripts run once immediately after all content files are loaded, before global or player scripts start.

They access `openmw.content` to add records.

Reference pattern: skrow42's Trap Handling mod.

### 3. Load-context script file requirements

Every load-context script must explicitly require `openmw.content` at the top of the file.

```lua
local content = require('openmw.content')
```

There are no implicit globals.

Forgetting this produces an error like:

```text
attempt to index global 'content' (a nil value)
```

### 4. Load-context scripts cannot return arbitrary tables

OpenMW inspects a script's returned table for recognized section keys such as `engineHandlers` and `eventHandlers`.

Unknown keys produce load-time `Not supported section` errors.

For a pure record-registration script, do not return a table at all.

If constants need to be shared, put them in a separate shared module required by both the load-context script and runtime scripts.

### 5. Adding a script requires manifest plus file

Creating a `.lua` file is not enough.

The file must also be declared in an `.omwscripts` manifest with the correct flag:

- `LOAD`
- `GLOBAL`
- `PLAYER`
- `NPC`
- `CREATURE`
- `CUSTOM`

Fully restart OpenMW after manifest edits.

`reloadlua` may not pick up manifest changes.

---

## Custom Magic Effect Lessons

### 1. Template semantics

The `template` field on `content.magicEffects.records.X` is a construction-time full-record clone.

OpenMW initializes the new record as a copy of the template record, then overwrites fields from the Lua table.

If `template` is omitted or nil, the record starts from `blank()` instead.

After load, the template reference is gone. The custom record is standalone.

### 2. "Custom effect = vanilla no-op" is incomplete

Refined model:

- Bespoke gameplay behavior is keyed to exact effect IDs.
- Custom IDs do not trigger built-in bespoke behavior such as Open's unlock logic, Lock's lock logic, or Summon's summoning logic.
- Generic cast-pipeline behavior still runs for custom effects.
- Generic behavior is driven by effect record fields, instance range, and fallback cast/VFX/SFX behavior.
- Spell effect instance range drives projectile behavior.
- `RT_Target` can build a projectile/bolt path.
- `RT_Self` and `RT_Touch` do not use the same target projectile path.

Accurate statement:

> Custom effect IDs are gameplay no-ops unless bespoke code handles them, but vanilla casting still processes them through generic range/projectile/VFX/SFX behavior.

### 3. Defining a truly inert marker effect

To create a custom magic effect that vanilla casts treat as fully inert:

1. Omit the `template` field.
2. Start from blank.
3. On the spell effect instance, set range to `Self` to avoid target projectile behavior.
4. If full visual silence is needed, explicitly set `castStatic`, `hitStatic`, `bolt`, and associated sounds to silent or invisible assets.

For Spellforge, a visible cast effect may be acceptable because the player should receive casting feedback.

### 4. The Open Lock incident

During Milestone 2.2a, the marker effect used:

```lua
 template = content.magicEffects.records.open
```

This cloned Open's bolt, cast statics, sounds, and icon. When cast, the spell spawned a purple Open-style projectile.

Root cause:

- not gameplay fallback to Open's hardcoded handler
- direct data inheritance through the template clone

Diagnostic clue:

- icon path pointed at Open's icon asset

Fix:

- omit `template`
- set spell effect instance range to `Self`

Lesson:

> When a custom record behaves like a specific vanilla record, check the template field first.

---

## Compiler and Record-Creation Lessons

### 1. Silent fallback is an anti-pattern

During Milestone 2.2a, the compiler could fall back to base effects if `createRecordDraft` failed with the marker effect.

That fallback logged a warning but returned success.

This caused smoke tests to pass while the actual compiled record contained real vanilla effects instead of the intended marker-only payload.

Rule:

- compilation steps must propagate errors
- do not silently substitute alternative strategies
- smoke tests must inspect actual records, not only compiler metadata

### 2. Validate before creating records

Invalid generated records can destabilize OpenMW.

The compiler should validate:

- effect IDs
- ranges
- magnitudes
- area
- duration
- operator parameters
- emission caps
- required bindings

Do not let malformed records reach `world.createRecord`.

### 3. Canonicalization must reflect behavior

Canonical recipe hashes must include behavior-relevant data.

For 2.2c effect-list recipes, canonicalization should include:

- compiler format/version marker
- ordered effect IDs
- ranges
- area
- duration
- magnitude min/max
- operator IDs
- operator parameters

Do not hash only high-level node names if actual effect payloads can differ.

---

## Animation Synchronization Lessons

When timing script actions to animation events, subscribe to animation text keys rather than hardcoding seconds.

Reasons:

- text keys fire at semantic moments
- self/touch/target variants have different timings
- animation speed changes do not invalidate semantic text keys
- animation replacers are less likely to break text-key logic than fixed timers

Example:

```text
Use addTextKeyHandler('spellcast', ...)
React to the "release" text key.
```

Do not use a hardcoded `newUnsavableSimulationTimer(0.94, ...)` as a cast-release substitute.

Exception:

Short timeouts for request/response patterns are appropriate when no corresponding engine event exists.

---

## Agent / Codex Process Lessons

### 1. Agent file-editing hazard

When an agent edits a file that was previously hand-edited outside the agent's view, the agent may regenerate the file from its mental model and lose human edits.

Observed example:

- a human manually added `require('openmw.content')`
- the agent later made unrelated edits to the same file
- the require line disappeared

Mitigations:

- commit manual edits before asking for more agent edits
- paste current file contents when necessary
- use targeted edit instructions
- verify files after the agent reports completion
- be especially careful with load-context files and manifest entries

### 2. Milestone scoping discipline

A milestone should have one primary deliverable verifiable by one smoke test or in-game check.

Bad milestone shape:

```text
marker effect + compiler + executor + intercept + opcodes + filters + tests
```

This encourages shallow scaffolding and weak verification.

Good milestone shape:

```text
one deliverable
one verification action
one rollback point
```

Future milestone prompts should fit on one screen of numbered steps.

### 3. Research-before-implementation pattern

When engine behavior cannot be answered from docs or code alone, do structured research before implementation.

Useful research prompt shape:

- numbered questions
- cite every factual claim
- ranked confidence: high / medium / speculation
- explicit open questions
- implementation recommendation

This pattern worked for:

- OSSC pattern transferability analysis
- custom magic effect template semantics

Structured research prevented implementation from proceeding under the wrong model.

---

## Current Cleanup Guidance

When asking Codex or another agent to clean up the repo:

1. Treat `ARCHITECTURE.md` as the authoritative design.
2. Treat this `LESSONS.md` as required project memory.
3. Preserve 2.2b intercept-dispatch behavior.
4. Do not implement new opcode runtime behavior during cleanup.
5. Label old graph-oriented code as prototype/transitional.
6. Align docs/comments with the effect-list recipe model.
7. Add TODOs for 2.2c parser/compiler/orchestrator work instead of half-implementing it.
