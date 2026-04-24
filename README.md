# OpenMW Noita Lite

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the authoritative design and module contract.

Current project status:

- Milestone **2.2b intercept-dispatch** is the current working runtime foundation.
- The project is transitioning to Milestone **2.2c opcode runtime**.
- 2.2c will keep the working 2.2b cast intercept path and replace transitional prototype scaffolding with effect-list parsing, compiled plans, and bounded orchestration.

Project memory and process lessons are tracked in [`LESSONS.md`](LESSONS.md).
Current transitional state notes are tracked in [`CURRENT_STATE.md`](CURRENT_STATE.md).

## Smoke test gate

Staged smoke scripts are now gated by a dev setting key:

- `SpellforgeDev.enable_smoke_tests`

Default is `false` for normal gameplay (reduced startup log noise).  
Set it to `true` in the dev environment to run smoke harness PASS/FAIL checks.
