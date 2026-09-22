# FARP spawning workarounds

## Implemented workaround: author the FARP before mission load

The clean positive control dynamically spawned two hot-parking AH-64Ds from an
empty Mission Editor FARP. Both became active and flew. The user also confirmed
that destroying those aircraft and respawning a fresh pair at the same FARP
worked. The final same-specification runtime-FARP comparison failed: both units
disappeared by +1 second despite four initially free pads. This supports the
authored-FARP workaround. [Generated-campaign validation](generated-campaign-validation.md)
now confirms observed RED Mi-24V and BLUE AH-64D sections activate, survive and take
off, with intact sections airborne at +120 seconds. One separate RED departure
crash was recorded; this is not a claim that every generated site is safe.

### Mission author procedure

1. Place the stock four-position **FARP** in Mission Editor, owned by the intended
   coalition. Its serialized shape must be `FARPS`, not the small `FARP` shape or
   a single/invisible helipad.
2. Leave pads empty for the controlled dynamic-spawn test. A group that has taken
   off may still reserve parking; visual emptiness is not evidence of free pads.
3. Save and load the mission so DCS initializes the heliport at mission startup.
4. Link dynamic aircraft departures to the loaded Airbase ID, preserving the
   proven hot-parking type/action and group specification.
5. Confirm `isActive()` and subsequent survival; wait for takeoff or inspect why
   an active aircraft is still grounded. An API handle alone is insufficient.
6. To recycle a wave, remove the aircraft group only, inspect parking release,
   and spawn uniquely named replacements against the same retained FARP.

### Generator implementation

The generator now writes a coalition-owned static FARP into each
generated mission at the corresponding FARP trigger-zone location. The static
unit name must match the campaign's logical base name exactly, including the
trigger-zone prefix. Both coalitions' static IDs must avoid client-slot IDs, and
warehouse entries must address their corresponding static unit IDs.

The archive regression verifies those properties for BLUE and RED, including
client-slot ID collisions and non-FARP/empty missions. Web type checks, tests and
production build pass. The mission suite also passes its campaign golden checks.

Runtime initialization must discover and reuse the authored object instead of
queuing a duplicate static. The offline regression checks repeated initialization
and verifies that helicopter hot departures reference the existing Airbase ID.
The campaign's existing dynamic fallback remains for older missions, but that
fallback is not evidence that those missions gain the workaround.

Regenerate and reload the `.miz` after the generator/bundle change. Rebuilding the
application or injecting updated Lua cannot retroactively make a runtime-created
FARP mission-authored. Existing downloaded archives keep their embedded content.

### Limits to verify

- Additional terrain/site coverage beyond the validated RED Mi-24V and BLUE AH-64D sections.
- Normal campaign routing and repeated waves; the successful live control used
  a reference AH-64D specification.
- Occupancy/exhaustion: four-position rotation is not an occupancy-aware parking
  allocator. Do not promise unlimited concurrent waves or assume pad release.
- Capture/repair that destroys and recreates the physical FARP may cross the same
  runtime-creation boundary; it is not covered by aircraft-only recycling.

## Changes not supported as fixes

- Switching hot departures to cold: the controlled cold test also failed.
- Removing links, changing start time, or calling `activateGroup`: some variants
  left inactive placeholders and did not demonstrate operational aircraft.
- Changing runtime parking IDs/coordinates alone: a tested pair disappeared.
- Ground-hot placement on pads: one of two helicopters crashed in the trial.
- Automatic retries/refunds: diagnostics do neither, because transient API
  states are not sufficient to make campaign accounting decisions.

## Diagnostics retained with the workaround

With campaign debug enabled, `[spawn_probe]` records the final submitted group,
departure and parking fields, base identity and parking observations, real API
outcome, unit activation/survival samples and lifecycle events. Correlate by
generation, sequence and group. Queries that fail are `QUERY_ERROR`, not missing
aircraft or zero capacity. Probes end after 120 simulation seconds and do not
alter aircraft or campaign state.
