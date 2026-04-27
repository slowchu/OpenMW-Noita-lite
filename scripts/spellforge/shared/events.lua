local events = {}

events.CHECK_BACKEND = "Spellforge_CheckBackend"
events.BACKEND_READY = "Spellforge_BackendReady"
events.BACKEND_UNAVAILABLE = "Spellforge_BackendUnavailable"

events.COMPILE_RECIPE = "Spellforge_CompileRecipe"
events.COMPILE_RESULT = "Spellforge_CompileResult"

events.DELETE_COMPILED = "Spellforge_DeleteCompiled"

events.CAST_REQUEST = "Spellforge_CastRequest"
events.BEGIN_CAST_OBSERVE = "Spellforge_BeginCastObserve"
events.CAST_OBSERVE_RESULT = "Spellforge_CastObserveResult"
events.CAST_HIT_OBSERVED = "Spellforge_CastHitObserved"
events.CAST_DIAG_SIGNAL = "Spellforge_CastDiagSignal"
events.INTERCEPT_DISPATCH_SUPPRESSED = "Spellforge_InterceptDispatchSuppressed"
events.RUNTIME_STATS_REQUEST = "Spellforge_RuntimeStatsRequest"
events.RUNTIME_STATS_RESULT = "Spellforge_RuntimeStatsResult"

events.QUERY_SPELL_METADATA = "Spellforge_QuerySpellMetadata"
events.QUERY_SPELL_METADATA_RESULT = "Spellforge_QuerySpellMetadataResult"

events.INTERCEPT_CAST = "Spellforge_InterceptCast"
events.INTERCEPT_DISPATCH_RESULT = "Spellforge_InterceptDispatchResult"
events.DEBUG_LAUNCH_VANILLA_FIREBALL = "Spellforge_DebugLaunchVanillaFireball"

events.DEV_LAUNCH_SIMPLE_EMITTER = "Spellforge_DevLaunchSimpleEmitter"
events.DEV_LAUNCH_MULTICAST_EMITTER = "Spellforge_DevLaunchMulticastEmitter"
events.DEV_LAUNCH_SPREAD_EMITTER = "Spellforge_DevLaunchSpreadEmitter"
events.DEV_LAUNCH_BURST_EMITTER = "Spellforge_DevLaunchBurstEmitter"
events.DEV_LAUNCH_TIMER_EMITTER = "Spellforge_DevLaunchTimerEmitter"
events.DEV_LAUNCH_TRIGGER_EMITTER = "Spellforge_DevLaunchTriggerEmitter"
events.DEV_LAUNCH_PERF_STRESS = "Spellforge_DevLaunchPerfStress"
events.DEV_LAUNCH_RESULT = "Spellforge_DevLaunchResult"
events.DEV_LAUNCH_TIMER_RESULT = "Spellforge_DevLaunchTimerResult"
events.DEV_LAUNCH_TRIGGER_RESULT = "Spellforge_DevLaunchTriggerResult"
events.DEV_LAUNCH_PERF_STRESS_RESULT = "Spellforge_DevLaunchPerfStressResult"
events.DEV_LAUNCH_HIT_OBSERVED = "Spellforge_DevLaunchHitObserved"
events.DEV_LAUNCH_PROBE_UNKNOWN_HELPER = "Spellforge_DevLaunchProbeUnknownHelper"
events.DEV_LAUNCH_LOOKUP_RESULT = "Spellforge_DevLaunchLookupResult"
events.DEV_HELPER_HIT_IDEMPOTENCY_PROBE = "Spellforge_DevHelperHitIdempotencyProbe"
events.DEV_HELPER_HIT_IDEMPOTENCY_RESULT = "Spellforge_DevHelperHitIdempotencyResult"

events.SFP_CAPABILITIES_REQUEST = "Spellforge_SfpCapabilitiesRequest"
events.SFP_CAPABILITIES_RESULT = "Spellforge_SfpCapabilitiesResult"
events.SFP_SPELL_STATE_REQUEST = "Spellforge_SfpSpellStateRequest"
events.SFP_SPELL_STATE_RESULT = "Spellforge_SfpSpellStateResult"
events.SFP_EMIT_OBJECT_PROBE_REQUEST = "Spellforge_SfpEmitObjectProbeRequest"
events.SFP_EMIT_OBJECT_PROBE_RESULT = "Spellforge_SfpEmitObjectProbeResult"

events.LIVE_SIMPLE_DISPATCH_PROBE = "Spellforge_LiveSimpleDispatchProbe"
events.LIVE_SIMPLE_DISPATCH_PROBE_RESULT = "Spellforge_LiveSimpleDispatchProbeResult"

return events
