# Spellforge Roadmap

## Status

- **Phase 1 (Foundation + Compiler): complete**
  - Compiler pipeline validated by `smoke_compiler.lua`.
  - Recipe compile/cache/createRecord/add-to-spellbook path proven.
- **Phase 2 (Executor): in progress**
  - Current working milestone foundation: **2.2b Intercept Dispatch**.
  - Transition target: **2.2c Opcode Runtime** (effect-list parser + bounded runtime queue).

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
7. `Trigger`
8. `Timer`

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

## Lessons captured (carry-over constraints)

- No invented APIs: every OpenMW/SFP call must map to a documented source.
- Preserve PLAYER/UI -> GLOBAL privileged-work split via events.
- Always include `sender` for P->G calls requiring G->P reply.
- Use `async:newUnsavableSimulationTimer` for transient timers.
- Keep logical IDs separate from engine `Generated:*` IDs.
- Keep helper spell ID identity separate from SFP live projectile identity. SFP v1.7 Beta 2 exposes `launchSpell` projectile returns and live projectile state; Spellforge should continue using helper spell IDs as the stable fallback while future Homing/Bounce/Speed+/Chain work can use projectile IDs opportunistically.
- Log `pcall` error strings before returning failure.
