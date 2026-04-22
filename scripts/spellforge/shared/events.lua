local events = {}

--[[
Payload: {
  sender: Actor
}
Sent by PLAYER to request backend readiness check.
]]
events.CHECK_BACKEND = "Spellforge_CheckBackend"

--[[
Payload: { backend_version: string|nil }
Sent by GLOBAL when backend dependencies are ready.
]]
events.BACKEND_READY = "Spellforge_BackendReady"

--[[
Payload: { reason: string }
Sent by GLOBAL when backend dependencies are unavailable.
]]
events.BACKEND_UNAVAILABLE = "Spellforge_BackendUnavailable"

--[[
Payload: {
  sender: Actor,         -- originating player/local actor object
  recipe: table,          -- validated by shared/validate.lua
  request_id: string,     -- caller-generated correlation id
  actor_id: string|nil    -- optional debugging actor id
}
Sent by PLAYER to request compilation.
]]
events.COMPILE_RECIPE = "Spellforge_CompileRecipe"

--[[
Payload: {
  request_id: string,
  ok: boolean,
  recipe_id: string|nil,
  spell_id: string|nil,
  reused: boolean|nil,
  errors: table|nil,
  error: string|nil
}
Sent by GLOBAL with compile result.
]]
events.COMPILE_RESULT = "Spellforge_CompileResult"

--[[
Payload: {
  sender: Actor,          -- originating player/local actor object
  spell_id: string|nil,
  recipe_id: string|nil,
  request_id: string|nil
}
Sent by PLAYER to request record/cache deletion.
]]
events.DELETE_COMPILED = "Spellforge_DeleteCompiled"

--[[
Payload: {
  sender: Actor,          -- originating player/local actor object
  spell_id: string,       -- compiled front-end engine spell id
  request_id: string
}
Sent by PLAYER to request a one-shot SFP launchSpell call for diagnostics.
]]
events.CAST_REQUEST = "Spellforge_CastRequest"

--[[
Payload: {
  sender: Actor,          -- originating player/local actor object
  spell_id: string,       -- compiled front-end engine spell id
  request_id: string,
  timeout_seconds: number|nil
}
Sent by PLAYER to register a temporary observer for MagExp_OnMagicHit.
]]
events.BEGIN_CAST_OBSERVE = "Spellforge_BeginCastObserve"

--[[
Payload: {
  request_id: string,
  ok: boolean,
  error: string|nil
}
Sent by GLOBAL to acknowledge CAST_REQUEST / BEGIN_CAST_OBSERVE.
]]
events.CAST_OBSERVE_RESULT = "Spellforge_CastObserveResult"

--[[
Payload: {
  request_id: string|nil,
  spell_id: string|nil,
  matched: boolean,
  attacker_id: string|nil,
  victim_id: string|nil
}
Sent by GLOBAL to PLAYER when a watched hit event arrives.
]]
events.CAST_HIT_OBSERVED = "Spellforge_CastHitObserved"

return events
