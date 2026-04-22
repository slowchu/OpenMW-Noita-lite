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

return events
