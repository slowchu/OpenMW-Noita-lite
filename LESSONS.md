# Spellforge Lessons

## Phase 1 Lessons (carried forward)

1. **Lua version discipline**
   - OpenMW uses Lua 5.1/LuaJIT sandbox semantics for scripts.
   - Avoid Lua 5.3 bitwise operators; use OpenMW-provided bit helpers where needed.

2. **API discipline**
   - Do not invent OpenMW/SFP APIs.
   - Prefer documented APIs and known integration patterns only.

3. **Context discipline**
   - PLAYER scripts: input/UI/per-player state.
   - GLOBAL scripts: world changes, SFP calls, cross-cell logic.
   - Cross-context communication is event-based only.

4. **Timer discipline**
   - Use `async:newUnsavableSimulationTimer` for transient waits/timeouts.
   - Keep timeout windows bounded and explicit in smoke harnesses.

5. **Record ID discipline**
   - Keep both:
     - logical IDs (Spellforge bookkeeping),
     - engine IDs (`Generated:*`) for engine-facing calls.

6. **Iteration discipline**
   - Actor spellbook membership checks are done by linear scan over iterable entries.
   - Core spell records are iterated by value-side `record.id`.

7. **Logging discipline**
   - `INFO`: phase boundaries and smoke assertions.
   - `ERROR`: include underlying `pcall` error message before returning failure.
   - Avoid raw `print`.

## Phase 2.1 Additions

1. **Cast-path discovery first**
   - The first executor milestone is observational: prove cast/hit plumbing before payload logic.

2. **Smoke harness behavior**
   - For cast tests, include manual-cast guidance and timeout diagnostics to avoid silent hangs.


## OpenMW 0.51 load context

Custom magic effect records and custom ingredient records must be
registered at content-load time via a load-context script. They
cannot be created at runtime via world.createRecord. Custom spell
records can be created either via load context or at runtime.

The .omwscripts manifest flag for load-context scripts is LOAD:
followed by the script path. LOAD entries must appear before
GLOBAL and PLAYER entries.

Load-context scripts run once, immediately after all content
files are loaded, before global or player scripts start. They
access the openmw.content module to add records.

Example manifest:
    LOAD:   scripts/mymod/context/effects.lua
    GLOBAL: scripts/mymod/global/init.lua
    PLAYER: scripts/mymod/player/init.lua

Reference: skrow42's Trap Handling mod (nexusmods 58681).

## Load-context script file requirements

Every load-context script must explicitly require openmw.content
at the top of the file. There are no implicit globals:

    local content = require('openmw.content')

Forgetting this produces "attempt to index global 'content' (a
nil value)" at whatever line first dereferences content.

## Load-context scripts cannot return arbitrary tables

OpenMW inspects a load-context script's returned table for
recognized section keys (engineHandlers, eventHandlers, etc.).
Unknown keys produce "Not supported section" errors at load time.

For a pure record-registration script, do not return a table at
all. If other modules need to share constants with the context
script, put those constants in a separate shared module that
both can require.

## Adding a new script requires manifest + file, not just file

Writing a .lua file is not sufficient for OpenMW to execute it.
The file must also be declared in an .omwscripts manifest with
the correct flag (LOAD, GLOBAL, PLAYER, NPC/CREATURE, or CUSTOM).

Verify manifest changes take effect by fully restarting OpenMW
after edits. Reloadlua in-console may not pick up manifest
changes.

## Custom magic effect records: template semantics

The template field on content.magicEffects.records.X is a
construction-time full-record clone, not a runtime inheritance
hook. OpenMW initializes the new record as a copy of the
template record, then overwrites fields from the Lua table. If
template is omitted or nil, the record starts from blank()
instead.

After load, the template reference is gone. The custom record
is a standalone MGEF record containing whatever data template
cloned plus explicit overrides.

## "Custom effect = vanilla no-op" is incomplete

Refined model:
- Bespoke gameplay (Open's unlock logic, Lock's lock logic,
  Summon's summoning) is keyed to exact effect IDs. Custom IDs
  don't trigger these built-in behaviors.
- Generic cast-pipeline behavior (projectile spawning, cast
  statics, hit statics, sounds, animation) runs for any custom
  effect because it's driven by the effect record's fields or
  by per-school fallback defaults for empty fields.
- Spell effect instance range drives projectile behavior. If the
  instance range is RT_Target, the projectile manager builds a
  bolt; if RT_Self or RT_Touch, it does not.

The accurate statement: custom effect IDs are gameplay no-ops
unless bespoke code handles them, but vanilla casting still
processes them through the generic cast pipeline for
range/projectile/VFX/SFX purposes.

## Defining a truly inert marker effect

To create a custom magic effect that vanilla casts will treat as
fully no-op:

1. Omit the template field. Start from blank.
2. On the spell effect instance (in the spell record), set
   range to Self. This prevents the projectile manager's
   target-range bolt path from running.
3. If full visual silence is needed, explicitly set castStatic,
   hitStatic, bolt, and associated sound fields to silent/
   invisible assets. Empty fields fall back to per-school
   defaults.

For Spellforge, steps 1 and 2 are sufficient. The fallback cast
VFX is acceptable because we want visible casting feedback for
the player.

## The Open Lock incident (debugging retrospective)

During Milestone 2.2a, our marker effect was defined with
template = content.magicEffects.records.open. The record cloned
Open's bolt, cast statics, sounds, and icon. When cast, the
spell spawned a purple orb projectile (Open's default bolt).

Root cause was NOT gameplay fallback to the template's handler.
Root cause was direct data inheritance via the template clone.
The visual icon path pointing at tx_scroll_openlock.dds (Open's
icon) was the diagnostic clue that led to the finding.

Fix: omit template, set spell effect instance range to Self.

Lesson: when a custom record behaves like a specific vanilla
record, check the template field first. The template is a
deeper clone than the documentation suggests.

Reference: Research_document_custom_effects.txt.

## Compiler silent-fallback anti-pattern

During Milestone 2.2a, the compiler was designed to fall back
to "base effects" if createRecordDraft failed with the marker
effect. The fallback logged a WARN but returned a success
payload. This caused the smoke test's "contains only marker
effect" assertion to PASS while the actual compiled record
contained real vanilla effects.

The silent fallback masked a real registration failure and
misdirected debugging effort onto visual behavior
(hypothesizing Open Lock template leak) when the actual
problem was the marker effect not loading.

Rule: compilation steps must propagate errors rather than
substitute alternative strategies. Smoke test assertions must
inspect actual record contents rather than trusting compiler-
populated metadata fields.

## Synchronizing script logic with animation

When timing script actions to animation events, subscribe to
animation text keys rather than hardcoding seconds.

- Text keys fire at semantically meaningful moments regardless
  of animation speed or variant.
- Different animation variants (self/touch/target cast) have
  different durations, and a single hardcoded value won't fit
  all of them.
- Future animation changes or mod overrides don't break
  text-key-driven code, but do break hardcoded timers.

Example: use addTextKeyHandler('spellcast', ...) and react to
the "release" text key rather than newUnsavableSimulationTimer
with a hardcoded 0.94s delay.

Exception: short timeouts for request/response patterns (e.g.,
SFP handshake with 3s timeout) are appropriate for timers
because they have no corresponding engine events to sync with.

## Agent file-editing hazard

When the agent edits a file that was previously hand-edited by
a human (out-of-band from the agent's own changes), the agent
may regenerate the file from its mental model and lose human
edits.

Observed example: we added a require('openmw.content') line
manually, the agent later made unrelated edits to the same
file, and the require line disappeared.

Mitigations:
- Before asking the agent to edit a previously-touched file,
  paste its current contents as context
- Use targeted edit instructions ("add this line, remove that
  line") rather than "update the file"
- Verify file contents after the agent reports done,
  especially for files with known manual fixes
- Push manual edits to the repo immediately so the agent's
  view of the tree includes them

## Milestone scoping discipline

A single milestone should have one primary deliverable verifiable
by one smoke test or in-game check. When a milestone grows to
many steps spanning multiple concerns (marker effect + compiler
+ executor + intercept + opcodes + filters + tests), the agent
tends to produce shallow coverage across all of them rather
than deep completion of any.

Symptom: a thorough-sounding summary with no actually-verified
outcomes.

Future milestones fit on one screen of numbered steps, and the
Definition of Done is a single verification action.

Reference: original Milestone 2.2 was split into 2.2a / 2.2b /
2.2c after initial attempt produced scaffolding but no verified
working code.

## Research-before-implementation pattern

When a question about engine behavior cannot be answered from
existing docs or code alone, structured research is a cheaper
first move than trial-and-error implementation.

The research prompt shape that worked:
- A through F numbered questions
- "Cite every factual claim" constraint
- Explicit ranked-confidence recommendations (high / medium /
  speculation)
- Explicit "open questions" section for things the research
  couldn't answer

Used successfully in Milestone 2.2a for:
- OSSC pattern transferability analysis
- Custom magic effect template semantics

Both research passes redirected implementation away from
incorrect models at the right time.
