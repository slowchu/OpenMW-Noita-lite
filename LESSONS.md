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

## Phase 2.2b Additions

1. **Interception uses text-key release, not fixed timers**
   - Player intercept dispatch is keyed to spellcast `<variant> release` and aborts on `<variant> stop`.

2. **Round-trip metadata gate before interception**
   - Player script queries global metadata (`Spellforge_QuerySpellMetadata`) before arming intercept.

3. **Root-only dispatch scope for 2.2b**
   - Executor dispatches only root emitter `real_effects` and records root cookies for hit observability.
