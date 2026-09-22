# ADR 0007: Bake generated FARPs before mission load

Accepted, 2026-09-22; observed generated-campaign RED and BLUE sections passed
activation, survival and takeoff checks. See the report's validation record.

## Context

The same hot AH-64D specification activated and flew from an empty mission-loaded
stock FARP, and again after aircraft-only recycling at that FARP. At a fresh
runtime-created stock FARP with four free pads, both returned units were inactive
and disappeared by +1 second without birth events. The comparison supports an
initialization boundary but does not isolate the responsible engine subsystem.
See [reproduction and evidence](../../../dcs-bugs/runtime-farp-spawning/README.md).

## Decision

The web generator writes each FARP zone's stock four-position static object into
the `.miz` before mission load, under the appropriate coalition country. Use the
exact runtime logical name, unique IDs beyond client-slot IDs, and unlimited
warehouse records keyed by static unit ID. Runtime initialization reuses the
existing object. Preserve hot starts and bounded spawn diagnostics.

## Consequences

- Users must regenerate and reload missions; bundle injection alone cannot
  change how an existing FARP was initialized.
- Authored FARP aircraft recycling is demonstrated. Observed generated-campaign
  RED Mi-24V and BLUE AH-64D CAS sections also passed; one separate RED crash remains.
- Older missions keep their dynamic fallback. Destroying/recreating a physical
  FARP is not covered by aircraft recycling evidence.
- This does not implement an occupancy-aware parking allocator or alter spawn
  accounting, mission cadence, retries or refunds.
- Keep ED reproduction files and detailed workaround limits in `dcs-bugs/`.
