# Spellforge Module Inventory

Pack H.5 cleanup inventory. This classifies Spellforge Lua modules by ownership
so cleanup does not collapse real runtime boundaries just to reduce file count.

## OpenMW Entry Points

These files are loaded directly by `.omwscripts` and should not be renamed
without updating the manifest and proving script load:

| file | load kind | category | notes |
|---|---|---|---|
| `scripts/spellforge/context/effects.lua` | `LOAD` | shared_contract | custom magic effect records |
| `scripts/spellforge/global/init.lua` | `GLOBAL` | runtime_boundary | global backend event registration |
| `scripts/spellforge/player/init.lua` | `PLAYER` | runtime_boundary | player intercept/UI bootstrap |
| `scripts/spellforge/tests/enable_dev_launch_flags.lua` | `GLOBAL` | smoke_entrypoint | dev/smoke flag setup |
| `scripts/spellforge/tests/smoke_compiler.lua` | `PLAYER` | smoke_entrypoint | compiler smoke |
| `scripts/spellforge/tests/smoke_canonicalize.lua` | `PLAYER` | smoke_entrypoint | canonicalization/parser smoke |
| `scripts/spellforge/tests/smoke_cast.lua` | `PLAYER` | smoke_entrypoint | cast lifecycle smoke |
| `scripts/spellforge/tests/smoke_dev_launch.lua` | `PLAYER` | smoke_entrypoint | helper launch smoke |
| `scripts/spellforge/tests/smoke_dev_multicast.lua` | `PLAYER` | smoke_entrypoint | Multicast smoke |
| `scripts/spellforge/tests/smoke_dev_spread.lua` | `PLAYER` | smoke_entrypoint | Spread smoke |
| `scripts/spellforge/tests/smoke_dev_burst.lua` | `PLAYER` | smoke_entrypoint | Burst smoke |
| `scripts/spellforge/tests/smoke_dev_timer.lua` | `PLAYER` | smoke_entrypoint | Timer smoke |
| `scripts/spellforge/tests/smoke_dev_trigger.lua` | `PLAYER` | smoke_entrypoint | Trigger smoke |
| `scripts/spellforge/tests/smoke_sfp_projectile_state.lua` | `PLAYER` | smoke_entrypoint | SFP projectile-state smoke |
| `scripts/spellforge/tests/smoke_helper_hit_idempotency.lua` | `PLAYER` | smoke_entrypoint | helper/userData hit smoke |
| `scripts/spellforge/tests/smoke_live_simple_dispatch.lua` | `PLAYER` | smoke_entrypoint | live runtime conformance driver |
| `scripts/spellforge/tests/smoke_emission_slots.lua` | `GLOBAL` | smoke_entrypoint | emission-slot smoke |
| `scripts/spellforge/tests/smoke_helper_records.lua` | `GLOBAL` | smoke_entrypoint | helper-record smoke |
| `scripts/spellforge/tests/smoke_helper_specs.lua` | `GLOBAL` | smoke_entrypoint | helper-spec smoke |
| `scripts/spellforge/tests/smoke_orchestrator.lua` | `GLOBAL` | smoke_entrypoint | orchestrator smoke |
| `scripts/spellforge/tests/smoke_parser.lua` | `PLAYER` | smoke_entrypoint | parser smoke |
| `scripts/spellforge/tests/smoke_plan_cache.lua` | `GLOBAL` | smoke_entrypoint | plan cache/feature matrix/UI API smoke |
| `scripts/spellforge/tests/smoke_player_ui_api.lua` | `PLAYER` | smoke_entrypoint | player UI API smoke |

## Runtime Modules

### core_runtime

- `scripts/spellforge/global/canonicalize.lua`
- `scripts/spellforge/global/canonicalize_effect_list.lua`
- `scripts/spellforge/global/compiler.lua`
- `scripts/spellforge/global/dev_launch.lua`
- `scripts/spellforge/global/dev_runtime.lua`
- `scripts/spellforge/global/emission_slots.lua`
- `scripts/spellforge/global/executor.lua`
- `scripts/spellforge/global/helper_record_specs.lua`
- `scripts/spellforge/global/helper_records.lua`
- `scripts/spellforge/global/orchestrator.lua`
- `scripts/spellforge/global/parser.lua`
- `scripts/spellforge/global/plan_cache.lua`
- `scripts/spellforge/global/projectile_registry.lua`
- `scripts/spellforge/global/records.lua`
- `scripts/spellforge/global/runtime_hits.lua`
- `scripts/spellforge/global/runtime_launch.lua`
- `scripts/spellforge/global/runtime_stats.lua`
- `scripts/spellforge/global/sfp_adapter.lua`
- `scripts/spellforge/global/sfp_smoke.lua`

### shared_contract

- `scripts/spellforge/shared/dev.lua`
- `scripts/spellforge/shared/events.lua`
- `scripts/spellforge/shared/generated_spell_lifecycle.lua`
- `scripts/spellforge/shared/limits.lua`
- `scripts/spellforge/shared/log.lua`
- `scripts/spellforge/shared/opcodes.lua`
- `scripts/spellforge/shared/operator_params.lua`
- `scripts/spellforge/shared/recipe_model.lua`
- `scripts/spellforge/shared/saved_recipe_model.lua`
- `scripts/spellforge/shared/sfp_userdata.lua`
- `scripts/spellforge/shared/validate.lua`
- `scripts/spellforge/shared/validation_contract.lua`

### policy

- `scripts/spellforge/global/chaos_budget.lua`
- `scripts/spellforge/global/feature_matrix.lua`
- `scripts/spellforge/global/feature_matrix_defs.lua`
- `scripts/spellforge/global/feature_matrix_ir.lua`
- `scripts/spellforge/global/homing_launch_policy.lua`
- `scripts/spellforge/global/launch_modifier_policy.lua`
- `scripts/spellforge/global/live_homing.lua`
- `scripts/spellforge/global/live_size_plus.lua`
- `scripts/spellforge/global/live_speed_plus.lua`
- `scripts/spellforge/global/payload_multicast.lua`
- `scripts/spellforge/global/payload_pattern.lua`
- `scripts/spellforge/global/patterns.lua`

### planner

- `scripts/spellforge/global/continuation_planner.lua`
- `scripts/spellforge/global/ir_runtime_adapter.lua`
- `scripts/spellforge/global/nested_payload_audit.lua`
- `scripts/spellforge/global/nested_trigger_timer.lua`
- `scripts/spellforge/global/runtime_ir.lua`
- `scripts/spellforge/global/runtime_job_planner.lua`

### event_adapter

- `scripts/spellforge/global/live_bounce.lua`
- `scripts/spellforge/global/live_chain.lua`
- `scripts/spellforge/global/live_pierce.lua`
- `scripts/spellforge/global/live_soft_homing.lua`
- `scripts/spellforge/global/live_timer.lua`
- `scripts/spellforge/global/live_trigger.lua`

### runtime_boundary

- `scripts/spellforge/global/chain_target_provider.lua`
- `scripts/spellforge/global/chain_targeting.lua`
- `scripts/spellforge/global/init.lua`
- `scripts/spellforge/global/live_simple_dispatch.lua`
- `scripts/spellforge/global/live_dispatch_recipes.lua`

`global/live_dispatch_recipes.lua` is intentionally a compatibility wrapper. The
large recipe catalog now lives under `tests/fixtures`.

## UI Modules

### ui_global

- `scripts/spellforge/global/ui_catalog.lua`
- `scripts/spellforge/global/ui_contract.lua`

### ui_player

- `scripts/spellforge/player/init.lua`
- `scripts/spellforge/player/spellcrafting_ui.lua`
- `scripts/spellforge/player/storage.lua`
- `scripts/spellforge/player/ui.lua`
- `scripts/spellforge/player/ui_palette.lua`
- `scripts/spellforge/player/ui_slots.lua`

## Smoke Fixtures And Helpers

### smoke_fixture

- `scripts/spellforge/tests/fixtures/live_dispatch_recipes.lua`
- `scripts/spellforge/tests/smoke_keys.lua`

The live dispatch recipe catalog is table-based fixture data. It uses one module
table instead of hundreds of top-level locals to avoid another Lua local-variable
ceiling regression.

### smoke_entrypoint

All `scripts/spellforge/tests/smoke_*.lua` files listed under OpenMW entrypoints
are smoke entrypoints. They are intentionally kept out of runtime policy modules.

## Legacy Fallback

No legacy fallback path was deleted in Pack H.5. Legacy Trigger, Timer, Bounce,
and Chain runtime paths remain behind explicit dev quarantine flags and strict
IR smoke still treats unexpected fallback/mismatch as a failure.

## Prototype Or Dead Candidates

| file | loaded by `.omwscripts` | required by module | finding | action |
|---|---:|---:|---|---|
| `scripts/spellforge/global/policy.lua` | no | no | unused v0 policy/economics stub returning only zero cost | deleted |
| `scripts/spellforge/tests/smoke_chain.lua` | no | no | empty smoke stub superseded by live Chain conformance smokes | deleted |
| `scripts/spellforge/tests/smoke_executor.lua` | no | no | empty smoke stub superseded by orchestrator/runtime smokes | deleted |

## Pack H.5 Cleanup Decisions

- Moved the live dispatch recipe catalog from `global` to `tests/fixtures`.
- Added a compatibility wrapper at the old `global/live_dispatch_recipes.lua`
  require path.
- Added `SPELLFORGE_SMOKE_FIXTURE_LOAD_OK` to the `I` smoke structure check so
  the relocated fixture has an explicit load marker.
- Reduced `live_simple_dispatch.lua` top-level `local` declarations from the
  Lua ceiling risk line to 198 by converting two smoke probe helpers into private
  module functions.
- Deleted three unused/no-op prototype files listed above.
- Kept policy/planner/adapter/event-adapter boundaries intact.
- Did not change support truth, gates, runtime behavior, SFP behavior, or UI
  visuals.
