# Spellforge Lessons

## Phase 1 Lessons (carried forward)

1. **Lua version discipline**
   - OpenMW uses Lua 5.1/LuaJIT sandbox semantics for scripts.
   - Avoid Lua 5.3 bitwise operators; use OpenMW-provided bit helpers where needed.

2. **API discipline**
   - Do not invent OpenMW/SFP APIs.
   - Prefer documented APIs and known integration patterns only.

3. **Context discipline**
   - PLAYER scripts: input/UI/per-player state.
   - GLOBAL scripts: world changes, SFP calls, cross-cell logic.
   - Cross-context communication is event-based only.

4. **Timer discipline**
   - Use `async:newUnsavableSimulationTimer` for transient waits/timeouts.
   - Keep timeout windows bounded and explicit in smoke harnesses.

5. **Record ID discipline**
   - Keep both:
     - logical IDs (Spellforge bookkeeping),
     - engine IDs (`Generated:*`) for engine-facing calls.

6. **Iteration discipline**
   - Actor spellbook membership checks are done by linear scan over iterable entries.
   - Core spell records are iterated by value-side `record.id`.

7. **Logging discipline**
   - `INFO`: phase boundaries and smoke assertions.
   - `ERROR`: include underlying `pcall` error message before returning failure.
   - Avoid raw `print`.

## Phase 2.1 Additions

1. **Cast-path discovery first**
   - The first executor milestone is observational: prove cast/hit plumbing before payload logic.

2. **Smoke harness behavior**
   - For cast tests, include manual-cast guidance and timeout diagnostics to avoid silent hangs.

## Phase 2.2 Additions

1. **Marker-effect compilation for vanilla no-op casts**
   - Compiled Spellforge spellbook records now carry a custom marker effect (`spellforge_composed`) only.
   - Real emitter effects are preserved in global metadata (`real_effects`) and executed by the runtime dispatcher.

2. **Selective vanilla-cast interception pattern**
   - Interception is anchored on `onInputAction(input.ACTION.Use)` with stance, magicka, and delayed release checks.
   - Spell-source normalization uses a cascade: `core.magic.getSelectedSpell()` -> `types.Player.getSelectedSpell(self)` -> `types.Player.getSelectedEnchantedItem(self)` -> `types.Actor.getSelectedSpell(self)`.

3. **Player->Global ownership query before intercept**
   - Player context does not directly inspect global metadata storage.
   - Added query/reply event pair so player scripts can ask global whether a selected spell ID is Spellforge-owned before intercepting.

4. **Runtime cookie routing for payload execution**
   - Executor now tags launched projectiles and uses `MagExp_OnMagicHit` to route follow-up Trigger/Timer payloads.
   - AoE-style terminal payloads should prefer `I.MagExp.detonateSpellAtPos` where possible.

5. **Global MagExp target filter polish**
   - Register a global target filter to veto dead actors so dispatched projectiles do not waste payload logic on corpses.
