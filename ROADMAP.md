# Spellforge Roadmap

## Status

- **Phase 1 (Foundation + Compiler): complete**
  - Compiler pipeline validated by `smoke_compiler.lua`.
  - Recipe compile/cache/createRecord/add-to-spellbook path proven.
- **Phase 2 (Executor): in progress**
  - Current stable foundation: **2.2b Intercept Dispatch**.
  - Current live work: **2.2c Opcode Runtime** behind default-off gates.
  - Current migration work: **2.2d IR Runtime Adapter**. Runtime IR, the public IR-backed feature matrix, continuation planning, runtime job planning, and the shared IR runtime adapter exist. Trigger, Timer, Bounce, Chain, and Pierce prefer IR-planned paths under their matching live gates while legacy fallbacks remain available for migrated older opcodes.

## What was deliberately not proven in Phase 1

- Dynamic records through full cast lifecycle (`cast -> projectile -> hit`).
- SFP `launchSpell` behavior for `Generated:0xNN` IDs.
- Reliability of hit-event matching for dynamically created spells.
- Vanilla cast-side observations for dynamic records (magicka/animation/xp).
- Save/load continuity for runtime metadata used by executor paths.

## v1 Opcode Vocabulary (current)

1. `Multicast`
2. `Spread` (preset mode; no free-form arc parameter in v1 scope)
3. `Burst` (spherical; hemisphere auto-mode)
4. `Speed+`
5. `Size+`
6. `Chain`
7. `Bounce`
8. `Homing`
9. `Trigger`
10. `Timer`
11. `Pierce`

## Phase 2 Milestones

### 2.1 First Cast (this iteration)

- Add minimal global executor with:
  - SFP hit-event observation (`MagExp_OnMagicHit`).
  - Minimal cast request path for one-shot `launchSpell` diagnostics.
  - Spellforge spell-id matching via compiled metadata/cache.
- Add `smoke_cast.lua` harness and manifest:
  - Backend handshake.
  - Compile trivial recipe.
  - Verify spellbook membership.
  - Observe hit event within bounded timeout.

### 2.2 Payload Resolution

- Cookie table for in-flight spell instances.
- Minimal payload traversal for one-level trigger/terminal behavior.

### 2.3 Policy Layer

- Cost, XP, fatigue, reflection, and failure behavior.

### 2.4 Player UI Integration

- Recipe authoring, save/load, and compile UX.

## Current Runtime Truth

- The visible spellcrafting shell exists and is functional enough for runtime testing, but visual layout polish is deferred until opcode behavior is steadier.
- Trigger, Timer, Bounce, Chain, and Pierce are the main event/continuation opcodes currently routed through the shared IR continuation/job-planning path when their live gates are enabled.
- Bounce v0 supports the narrow source, Trigger payload fanout, Trigger->Chain, and shared-policy source Speed+/Size+ simple launch shapes documented in `CURRENT_STATE.md`; Bounce+Timer, Bounce+Homing, direct source Bounce+Chain, combined source Speed+ Size+, arbitrary nested payload runtime, recursion, and post-launch steering remain deferred.
- Pierce v0 is the final launch modifier opcode. `Pierce N` means N actor pass-throughs, then the next actor or any geometry collision stops/detonates normally. Smoke101 proved `Pierce 3` against a line of dremora: three distinct Pierce events, then normal collision on a fourth distinct dremora.
- Homing v0 remains intentionally narrow: primary `Homing -> simple target projectile` plus the central soft-Homing probe/runtime. Homing composition with Chain, Bounce, Trigger/Timer, Multicast/Spread/Burst, Speed+/Size+, and arbitrary nested payloads remains deferred.

## Near-Term Before UI Polish

1. Add a no-AoE or minimal-area Pierce diagnostic recipe so visual tests can distinguish true Pierce source hits from final explosion splash.
2. Continue broadening launch-modifier policy one narrow shape at a time; simple payload combined Speed+ Size+, single Speed+/Size+ with bounded Chain payload Multicast, and single source Speed+/Size+ on Bounce/Pierce simple launches now work, while combined Speed+ Size+ fanout, pattern, nested, Homing, and broader source-composition shapes remain deferred.
3. Continue broadening nested payload runtime one narrow supported shape at a time, without arbitrary recursion.

## Lessons captured (carry-over constraints)

- No invented APIs: every OpenMW/SFP call must map to a documented source.
- Preserve PLAYER/UI -> GLOBAL privileged-work split via events.
- Always include `sender` for P->G calls requiring G->P reply.
- Use `async:newUnsavableSimulationTimer` for transient timers.
- Keep logical IDs separate from engine `Generated:*` IDs.
- Keep helper spell ID identity separate from SFP live projectile identity. SFP v1.7 Beta 2 exposes `launchSpell` projectile returns and live projectile state; Spellforge should continue using helper spell IDs as the stable fallback while future Homing/Bounce/Speed+/Chain work can use projectile IDs opportunistically.
- Log `pcall` error strings before returning failure.
