# Spellforge Current State (Post-2.2b, Pre-2.2c)

This file tracks transitional implementation status.  
`ARCHITECTURE.md` remains the authoritative design specification.

## Working foundation

- **2.2b intercept dispatch is working and remains the current foundation.**
- The live path is still:
  - player cast input
  - animation text-key intercept
  - cast-success authorization
  - global dispatch via `I.MagExp.launchSpell`

## Transitional/prototype scaffolding still present

- Current compiler/executor code still includes prototype scaffolding for:
  - root-only `real_effects` dispatch
  - metadata query fallback when player cache misses
  - graph-oriented recipe-node assumptions in validator/canonicalization code paths
- These are transitional and should not be treated as final 2.2c runtime architecture.

## 2.2c direction

- 2.2c replaces graph-oriented compiler assumptions with **ordered effect-list parsing**.
- v1 structural-cookie strategy is **per-emission helper spell records** (internal only).
- No real opcode runtime is complete yet (no final Trigger/Timer/Multicast/Burst/Spread/Chain/Speed+/Size+ runtime behavior).
- 2.2c.1 parser skeleton now exists for effect-list grouping/binding validation, but it is not wired into live 2.2b casting yet.
- 2.2c.2 canonical effect-list hashing now exists (including operator params and compiler-version salt), but it is not wired into live 2.2b casting yet.
- Existing node-graph compiler path remains transitional scaffolding until a later migration PR.
