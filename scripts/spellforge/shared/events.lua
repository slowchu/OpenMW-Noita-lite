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

events.QUERY_SPELL_METADATA = "Spellforge_QuerySpellMetadata"
events.QUERY_SPELL_METADATA_RESULT = "Spellforge_QuerySpellMetadataResult"

events.INTERCEPT_CAST = "Spellforge_InterceptCast"
events.INTERCEPT_DISPATCH_RESULT = "Spellforge_InterceptDispatchResult"

return events
