# ADR 0008: Protect airfield grounds at placement and during play

Accepted, 2026-09-22. Implemented; mission suite and focused review pass.
Automatic movement in live DCS is being checked separately.

## Context

Removing two generated runway infantry groups allowed a Vaziani F-15C to taxi
and take off after more than 1,400 simulation seconds stationary. Untouched jets
remained stationary. The user requires both safe placement and an active loop
that routes ground units out of airbase grounds.

## Decision

- Use a shared conservative envelope derived from DCS runway and parking
  geometry. Enumerate physical AIRDROME objects, including neutral fields and
  fields classified as helicopter-only FOBs by the campaign.
- Apply that envelope to generated defenses, patrols, restored ground groups,
  and generated installation objects. Preserve authored airfield infrastructure.
- Periodically inspect movable AI ground groups and send intruding groups to a
  safe outside waypoint. Exclude player-controlled groups and aircraft. Statics
  are covered at placement, because a movement task cannot clear them.
- Avoid route churn while groups make progress; retry stalled/failed movement
  on a bounded schedule and log outcomes. Old-generation timers must stop.
- Keep the pinned pre-deletion Lua baseline intact. Record separate, explicit
  expectations for the intentional clearance behavior and document every changed
  issued order. Run real clearance code during order comparison, retaining route,
  composition, task parameters, call multiplicity and task-count checks. The
  earlier test-only identity adapter is withdrawn following the shared-branch
  handoff: it hid the new placements from the order regression net.

## Consequences

The envelope intentionally favors clear airfields over close-in defenses. Missing
geometry uses a conservative fallback. Failed safe placement must skip/log rather
than fall back to the unsafe point. An evacuation order diverts the AI group from
its current assignment; it is not proof of physical movement until observed.

New code does not rewrite already embedded mission scripts. Live verification of
the automatic loop remains distinct from the successful manual-removal control.
See [report and workarounds](../../../dcs-bugs/airbase-ground-obstructions/README.md).
