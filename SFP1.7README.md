# SPELL FRAMEWORK PLUS (MagExp) v2.0

**SPELL FRAMEWORK PLUS** is a standardized spell-launching engine for OpenMW Lua. It dehardcodes the magic system and provides a unified public interface (`I.MagExp`) for modders to trigger spell casts, control projectiles in flight, and hook into lifecycle events.

---

## 1. Setup for Modders

0. (Optional) Have **MaxYari's LuaPhysics** enabled for physics impulse support.
1. Ensure `SPELL_FRAMEWORK_PLUS.omwscripts` is loaded.
2. Ensure your mod has a dependency or check for the interface.

> [!NOTE]
> MaxYari's LuaPhysics is no longer a hard dependency. MagExp degrades gracefully — the `impactImpulse` feature will silently do nothing if LuaPhysics is not loaded.

---

## 2. Public API: `I.MagExp` (Global)

Call these from any **Global Script** using `local I = require('openmw.interfaces')`.

### Core

| Function | Description |
|:--|:--|
| `launchSpell(data)` | Launch a spell. Auto-detects routing (Self/Touch/Target). Returns the projectile object. |
| `emitProjectileFromObject(data)` | Emit a projectile spell directly from a non-actor Static/Door/Activator `data.source` without causing engine crashes. |
| `applySpellToActor(spellId, caster, target, hitPos, isAoe, item)` | Directly apply a spell to an actor. |
| `detonateSpellAtPos(spellId, caster, pos, cell, item)` | Trigger an AoE blast at a world position. |
| `addTargetFilter(fn)` | Register a global filter `fn(target) → bool` to veto hits. |
| `registerLockableEffect(id)` | Register an effect ID to allow spells to interact with doors and containers. |
| `registerUniversalEffect(id)`| Register an effect ID to allow Touch spells to interact with ANY game object (Statics, Activators, etc.) and emit a `MagExp_OnMagicHit` hook for it. |
| `STACK_CONFIG` | Table controlling spell stacking limits. |

### In-Flight Spell Control

| Function | Description |
|:--|:--|
| `getSpellState(projId, tag)` | Request a state snapshot. Reply arrives as `MagExp_SpellState` event with the same `tag`. |
| `setSpellPhysics(projId, data)` | Mutate any physics property of a live spell (see full field list below). |
| `redirectSpell(projId, direction)` | Change the flight direction. Speed is preserved. |
| `setSpellSpeed(projId, speed)` | Set the projectile speed. Direction is preserved. |
| `setSpellPaused(projId, paused)` | Freeze or unfreeze a projectile in place. |
| `cancelSpell(projId)` | Force-cancel and remove a live spell. |
| `setSpellBounce(projId, enabled, max, power)` | Configure bounce on a live spell. |
| `setSpellDetonateOnActor(projId, bool)` | Toggle whether actor contact detonates a bouncing spell. |
| `getActiveSpellIds()` | Returns a table of all live spell projectile IDs. |

### Lifecycle Hooks

Override these to respond to events globally:
```lua
I.MagExp.onEffectApplied    = function(actor, effect) end
I.MagExp.onEffectTick       = function(actor, effect) end
I.MagExp.onEffectOver       = function(actor, effect) end
I.MagExp.onProjectileBounce = function(data) end
-- data: { projectile, spellId, attacker, hitPos, hitNormal, bounceCount, speed }
```

---

## 3. Usage from Player / Local Scripts

Player and local scripts cannot call `I.MagExp` directly. Use global events:

```lua
local core = require('openmw.core')
local self = require('openmw.self')

core.sendGlobalEvent('MagExp_CastRequest', {
    attacker  = self,
    spellId   = "fireball",
    startPos  = self.position + util.vector3(0, 0, 120),
    direction = self.rotation * util.vector3(0, 1, 0),
    isFree    = true
})
```

---

## 4. `launchSpell` Parameter Table

All fields except the first four are optional.

| Parameter            | Type      | Default | Description |
|:---                  |:---       |:---     |:--- |
| **attacker**         | `Actor`   | Required | The casting actor. |
| **spellId**          | `string`  | Required | Spell record ID. |
| **startPos**         | `Vector3` | Required | World position where the spell spawns. |
| **direction**        | `Vector3` | Required | Initial flight direction. |
| **spellType**        | `number`  | Auto | Routing: Self/Touch/Target. |
| **area**             | `number`  | Auto | AoE radius in game units. |
| **isFree**           | `boolean` | `false` | Skip magicka cost check. |
| **speed**            | `number`  | `1500` | Initial speed (units/sec). |
| **maxSpeed**         | `number`  | `0` | Speed cap (0 = unlimited). |
| **accelerationExp**  | `number`  | `0` | Exponential speed multiplier per frame. Positive = accelerate, negative = decelerate. Does NOT change direction. |
| **forceVec**         | `Vector3` | `nil` | Continuous force applied to velocity each frame (units/sec²). Use negative direction for braking. |
| **minSpeed**         | `number`  | `0` | Speed floor when decelerating. |
| **bounceEnabled**    | `boolean` | `false` | Reflect off static geometry. |
| **bounceMax**        | `number`  | `0` | Max bounces before forced detonation. 0 = unlimited until lifetime. |
| **bouncePower**      | `number`  | `0.7` | Restitution coefficient (0 = dead stop, 1 = perfect elastic). |
| **detonateOnActorHit** | `boolean` | `true` | If false, actors are treated as static for bounce purposes. |
| **impactImpulse**    | `number`  | `0` | MaxYari LuaPhysics impulse magnitude applied to hit actor on detonation. |
| **isPaused**         | `boolean` | `false` | Spawn frozen in place. Unpause with `MagExp_SetPhysics`. |
| **maxLifetime**      | `number`  | `10` | Seconds before expiry. |
| **spawnOffset**      | `number`  | `80` | Distance ahead of `startPos` to spawn the carrier. |
| **vfxRecId**         | `string`  | Auto | Bolt VFX record ID (auto-detected from school). |
| **boltModel**        | `string`  | Auto | Bolt mesh path (resolved from `vfxRecId` if omitted). |
| **areaVfxRecId**     | `string`  | Auto | Override area explosion static VFX record. |
| **boltSound**        | `string`  | Auto | Looping flight sound. |
| **boltLightId**      | `string`  | Auto | Record ID of the light attached to the bolt. |
| **spinSpeed**        | `number`  | Auto | Rotation speed in rad/sec. |
| **isFree**           | `boolean` | `false` | Skip magicka check. |
| **unreflectable**    | `boolean` | `false` | Cannot be reflected. |
| **itemObject**       | `Object`  | `nil` | Source item (for enchantment logic). |
| **casterLinked**     | `boolean` | `false` | If true, hostile reactions are attributed to the `attacker`. |
| **isPaused**         | `boolean` | `false` | Spawn frozen in place. Note: Updating `speed` or `velocity` via `setSpellPhysics` will automatically set `isPaused = false` for legacy mod compatibility. |

---

## 5. `setSpellPhysics` / `MagExp_SetPhysics` Field Reference

These fields can be passed to `setSpellPhysics(projId, data)` or sent as `MagExp_SetPhysics` event directly to the projectile:

| Field | Type | Description |
|:--|:--|:--|
| `velocity` | `Vector3` | Full velocity override. |
| `speed` | `number` | Speed override (direction unchanged). |
| `direction` | `Vector3` | Direction redirect (speed unchanged). |
| `accelerationExp` | `number` | New exponential speed multiplier. |
| `forceVec` | `Vector3` | New continuous force. Set to `util.vector3(0,0,0)` to stop. |
| `maxSpeed` | `number` | New terminal velocity cap. |
| `bounceEnabled` | `boolean` | Enable/disable bouncing. |
| `bounceMax` | `number` | Max bounce count. |
| `bouncePower` | `number` | Restitution. |
| `detonateOnActorHit` | `boolean` | Actor-detonation toggle. |
| `spellId` | `string` | Override spell ID (changes what is applied on impact). |
| `area` | `number` | Override area radius. |
| `vfxRecId` | `string` | Override VFX identity. |
| `areaVfxRecId` | `string` | Override area explosion VFX. |
| `maxLifetime` | `number` | Override max lifetime. |
| `impactImpulse` | `number` | Override MaxYari impulse. |
| `isPaused` | `boolean` | Pause or unpause. |

---

## 6. In-Flight Spell Control

The **Live Spell Registry** tracks every projectile launched by MagExp. Each projectile's `proj.id` is the key.

```lua
local I = require('openmw.interfaces')

-- Get all live projectile IDs
local ids = I.MagExp.getActiveSpellIds()

-- Redirect the first one mid-flight
if ids[1] then
    I.MagExp.redirectSpell(ids[1], util.vector3(1, 0, 0))
end

-- Apply braking force (opposing velocity direction)
I.MagExp.setSpellPhysics(ids[1], {
    forceVec = util.vector3(0, -300, 0)  -- backward force
})

-- Query state asynchronously
I.MagExp.getSpellState(ids[1], "my_tag")
-- Then listen for:
-- MagExp_SpellState { tag = "my_tag", velocity = ..., position = ..., ... }
```

---

## 7. Bounce Physics

When `bounceEnabled = true`, a projectile reflects off static geometry using surface normal reflection:


**Rules:**
- **Actors**: Always detonate immediately (unless `detonateOnActorHit = false`).
- **Static / terrain**: Bounce up to `bounceMax` times. At the limit, the next hit detonates.
- Each bounce fires the `MagExp_OnProjectileBounce` global event and the `I.MagExp.onProjectileBounce` hook.

```lua
-- Bouncing grenade example
I.MagExp.launchSpell({
    attacker      = actor,
    spellId       = "grenade",
    startPos      = spawnPos, direction = dir,
    bounceEnabled = true,
    bounceMax     = 4,
    bouncePower   = 0.6,
    detonateOnActorHit = true,  -- default
})

-- Listen for bounces
I.MagExp.onProjectileBounce = function(data)
    print("Bounce #" .. data.bounceCount .. " at " .. tostring(data.hitPos))
end
```

---

## 8. Acceleration & Force Vectors

### `accelerationExp` — Exponential Signed Speed Modifier

Multiplies `signedSpeed` (a number that can be negative) each frame:
```
signedSpeed = signedSpeed × exp(accelerationExp × dt)
velocity    = baseDir × signedSpeed
```

- **Positive** → spell accelerates exponentially toward `maxSpeed`.
- **Negative** → spell decelerates. When `signedSpeed` drops through zero it **continues into negative territory**, reversing the velocity direction along the original launch axis. The spell will then accelerate backwards.
- `baseDir` is the "positive forward" axis captured at launch (or at the last explicit direction/velocity override). It is never changed by `accelerationExp` itself — only the sign of `signedSpeed` flips.
- `maxSpeed` caps `|signedSpeed|` in both directions (forward and reverse).

```lua
-- A spell that launches forward, slows, reverses, and flies back
I.MagExp.launchSpell({
    attacker      = actor, spellId = "boomerang",
    startPos      = pos, direction = dir,
    speed         = 2000,
    accelerationExp = -1.5,   -- decelerates, crosses zero, reverses
    maxSpeed      = 2000,     -- applies to |speed| in both directions
    maxLifetime   = 5,
})
```

> [!NOTE]
> To stop reversal at zero (classic deceleration only), use `forceVec` instead of `accelerationExp` and zero it out once velocity is near-zero.

### `forceVec` — True Directional Force

Added directly to velocity each frame:
```
velocity = velocity + forceVec * dt
```
Use for: homing, gravity, braking, sideways drift. To decelerate, set `forceVec` opposite to the initial direction:
```lua
-- Apply braking force on a launched spell
I.MagExp.setSpellPhysics(projId, {
    forceVec = dir:normalize() * -800   -- decelerate at 800 units/sec²
})
```
When `velocity:length() < 0.5` due to a forceVec, the projectile expires gracefully.

---

## 9. Speed-Scaled Damage

`impactSpeed` is captured at the exact frame of collision and forwarded in the `MagExp_OnMagicHit` event payload alongside `maxSpeed` from the registry. Use this to apply proportional damage:

```lua
-- In your global script's MagExp_OnMagicHit handler:
MagExp_OnMagicHit = function(data)
    if data.spellId ~= 'my_kinetic_spell' then return end
    
    -- We scale from magMin (at low speed) to magMax (at max speed)
    local magMin    = data.magMin or 10
    local magMax    = data.magMax or magMin
    local maxSpeed  = data.maxSpeed or 5000
    
    local ratio     = math.max(0.0, math.min(1.0, data.impactSpeed / maxSpeed))
    local finalDmg  = magMin + (magMax - magMin) * ratio
    
    if data.target and data.target:isValid() then
        -- Use Hit event to ensure reactions/bounties trigger correctly:
        data.target:sendEvent('Hit', {
            attacker = data.attacker,
            damage = { health = finalDmg },
            type = 'Thrust', sourceType = 'Magic', successful = true
        })
    end
end
```

### Magnitude Detection Logic
The framework provides `magMin` and `magMax` by:
1. Scanning all effects in the spell record for Health or Elemental damage (Fire, Frost, Shock, Poison).
2. Summing their total magnitudes.
3. **Fallback**: If no explicit damage effects are found (e.g. a mod using "Script Effect" or a "Lock" template to store custom data), it returns the magnitude of the **very first effect** in the spell.

---

## 10. Physics Impulse on Impact (MaxYari LuaPhysics)

Set `impactImpulse` (a magnitude in LuaPhysics force units) to knock back a hit actor using MaxYari's physics engine:

```lua
I.MagExp.launchSpell({
    attacker      = actor,
    spellId       = "kinetic_bolt",
    startPos      = pos, direction = dir,
    impactImpulse = 2000,   -- knocked back proportional to hit direction
})
```

The impulse is applied via `LuaPhysics_ApplyImpulse` event sent directly to the hit actor. If MaxYari LuaPhysics is not loaded, this is a no-op (the event is silently ignored).

---

## 11. Magic Impact Event: `MagExp_OnMagicHit`

Broadcasted globally on every spell impact (projectile, touch, self).

### Field Reference (`MagicHitInfo`)

| Field           | Type         | Description |
|:---             |:---          |:--- |
| `attacker`      | `GameObject` | The casting actor. |
| `target`        | `GameObject` | The hit object. |
| `spellId`       | `string`     | Spell record ID. |
| `hitPos`        | `Vector3`    | Impact world position. |
| `hitNormal`     | `Vector3`    | Surface normal at impact. |
| `school`        | `string`     | Magic school (e.g. `"alteration"`). |
| `element`       | `string`     | `fire`, `frost`, `shock`, `poison`, `heal`, or `default`. |
| `damage`        | `table`      | `{ health, magicka, fatigue }` (Average damage values). |
| **`magMin`**    | `number`     | Aggregated minimum magnitude of damage/primary effects. |
| **`magMax`**    | `number`     | Aggregated maximum magnitude of damage/primary effects. |
| `spellType`     | `number`     | 0=Self, 1=Touch, 2=Target. |
| `isAoE`         | `boolean`    | True if part of an area blast. |
| `area`          | `number`     | AoE radius (if applicable). |
| **`impactSpeed`** | `number`   | Projectile speed (units/sec) at the moment of collision. |
| **`maxSpeed`**  | `number`     | Terminal velocity cap from the launch parameters. |
| `velocity`      | `Vector3`    | Final velocity vector at impact. |
| `unreflectable` | `boolean`    | Cannot be reflected. |
| `casterLinked`  | `boolean`    | Attributed to caster. |
| `stackLimit`    | `number`     | Stacking limit for this spell on the target. |
| `stackCount`    | `number`     | Current instances after this hit. |

---

## 12. Effect Lifecycle Events

| Event/Hook | When fired |
|:--|:--|
| `onEffectApplied` / `MagExp_OnEffectApplied` | Spell is added to an actor's active spells. |
| `onEffectTick` / `MagExp_OnEffectTick` | Each cleanup cycle while spell is still active (~10/sec). |
| `onEffectOver` / `MagExp_OnEffectOver` | Spell expires or actor dies. |

---

## 13. Precision Targeting: `I.SharedRay`

```lua
local I   = require('openmw.interfaces')
local ray = I.SharedRay.get()

if ray.hit and ray.hitObject then
    core.sendGlobalEvent('MagExp_CastRequest', {
        attacker  = self,
        spellId   = "spark",
        hitObject = ray.hitObject,
        hitPos    = ray.hitPos
    })
end
```

---

## 14. Code Examples

### A. Kinetic Bolt (Paused Phase 1 → Active Phase 2)

```lua
-- Phase 1: Launch frozen in place
local bolt = I.MagExp.launchSpell({
    attacker = actor, spellId = 'kb_launch',
    startPos = spawnPos, direction = dir,
    speed = 0, isPaused = true,
    vfxRecId = 'VFX_Soul_Trap', boltModel = 'meshes/w/magic_target.nif',
    boltLightId = 'kinetic_light', boltSound = 'alteration bolt',
    maxSpeed = 5000, isFree = true,
})

-- Phase 2: Release it
bolt:sendEvent('MagExp_SetPhysics', {
    velocity        = dir * 40,
    accelerationExp = 2.25,
    isPaused        = false
})
```

### B. Bouncing Grenade

```lua
I.MagExp.launchSpell({
    attacker = actor, spellId = 'grenade', startPos = pos, direction = dir,
    speed    = 1800, bounceEnabled = true, bounceMax = 5, bouncePower = 0.55,
    areaVfxRecId = 'VFX_DefaultHit', impactImpulse = 1500
})
```

### C. Decelerating Homing Bolt (Mid-Flight Redirect)

```lua
-- Launch normally
local ids = I.MagExp.getActiveSpellIds()

-- On next frame, redirect and brake
I.MagExp.redirectSpell(ids[1], targetDir)
I.MagExp.setSpellPhysics(ids[1], {
    forceVec = targetDir:normalize() * -200   -- gentle brake
})
```

### D. Restricting Stacking

```lua
local I = require('openmw.interfaces')
if I.MagExp then
    I.MagExp.STACK_CONFIG.SPELL_LIMITS["gods_shield"] = 1
end
```

---

## 15. Utility Events

### `MagExp_BreakInvisibility`
```lua
core.sendGlobalEvent('MagExp_BreakInvisibility', { actor = myPlayer })
```

### `MagExp_CastRequest`
Launch a spell from a player/local script (see §3).

---

## 16. Internal Notes

- **Carrier Object**: Projectiles use `Colony_Assassin_act` static as the physical carrier.
- **Collision**: 5-point cross raycast pattern every frame, simulating a ~12-unit-radius sphere.
- **Registry**: All live projectiles are tracked in `activeSpellRegistry` and cleaned up on expiry or collision.
- **Sound/Light Anchors**: Separate carrier objects parented to the projectile via teleport each frame.

---

## 17. Static Object Interactions

Here are three APIs for configurable interactions with non-actors:

### A. Targeting Lockables (Doors & Containers)
Spells that should affect doors/containers must be registered with the interface function below:
```lua
I.MagExp.registerLockableEffect("my_custom_door_breaker")
```

### B. Universal Object Targeting
If you want a Touch or Projectile spell to detect absolutely ANY world object it hits (Walls, Statics, Activators, Lights) so you can attach a VFX emitter or a script to that mesh for any reason - register the effect as universal:
```lua
I.MagExp.registerUniversalEffect("my_custom_paint_spell")
```

### C. Emitting Projectiles From Non-Actors
To make a wall trap or an explosive barrel shoot a fireball, use this wrapper. All of the available fields are specified below:
```lua
I.MagExp.emitProjectileFromObject({
    -- Core Options
    source    = myMechanicalTrapStatic, -- A non-actor Static object (Required)
    spellId   = "fireball",             -- Spell record ID (Required)
    direction = util.vector3(0, 1, 0),  -- Forward trajectory vector (Required)
    -- Optional Overrides (Behavior is otherwise inherited from the spell record)
    attacker         = someActor, -- Attribution (for reactions/stats)
    startPos         = spawnPos,  -- Defaults to the object's center bounding box
    speed            = 2500,      -- Initial speed (Defaults to 1500)
    spawnOffset      = 80,        -- Distance ahead of startPos to spawn
    maxLifetime      = 10,        -- Expiry timeout in seconds
    area             = 15,        -- AoE override
    isPaused         = false,     -- Spawn frozen?
    unreflectable    = true,
    casterLinked     = true,      -- Attributed to the provided 'attacker'
    -- Optional Physics Config (MaxSpeed, Bouncing, Impulse)
    maxSpeed         = 3000,      -- Speed cap
    accelerationExp  = 1.5,       -- Exponential speed multiplier per frame
    impactImpulse    = 1500,      -- MaxYari LuaPhysics knockback
    bounceEnabled    = true,
    bounceMax         = 3,
    bouncePower      = 0.7,
    -- Optional Audiovisual Overrides
    vfxRecId         = "my_bolt_vfx_record",
    areaVfxRecId     = "my_area_vfx_record",
    boltModel        = "meshes/my/custom_bolt.nif",
    boltSound        = "alteration bolt",
    boltLightId      = "my_bolt_light_record",
    spinSpeed        = 15.0
})
```

