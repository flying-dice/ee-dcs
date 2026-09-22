# Airbase obstruction workarounds

## Running mission: remove identified obstructions

The demonstrated remedy removed `FP-Vaziani-2043` and `FP-Vaziani-2045` while
leaving the waiting F-15C intact. It subsequently taxied and took off. This was
authorized for those exact groups; it is not a recommendation to delete all
airbase defenses indiscriminately.

For another mission, first identify ground units occupying the aircraft movement
area. Save their names and positions, remove or relocate only those obstructions,
then observe the existing aircraft's velocity and eventual takeoff. Parking,
taxiway and runway clearance all matter. Removing only units near the aircraft
may miss an obstruction farther along its departure path.

Existing missions retain already spawned ground units. A source-code fix alone
does not move them; regenerate/reload a mission with the corrected bundle or
perform a separately authorized targeted cleanup.

## Prevent recurrence in generated missions

A reusable airbase-ground exclusion rule now guards generated defenses, infantry
patrols, ground-force origins and restored groups, plus generated installation
statics and garrisons. It enumerates physical DCS AIRDROME objects across all
coalitions, including neutral fields and those the campaign labels as FOBs.

The protected circle conservatively covers reported runway lengths/widths and
parking positions with a 200 m edge buffer and a minimum 2,500 m radius. Missing
or invalid geometry uses the 2,500 m fallback. This is intentionally broader than
an exact runway polygon; it favors unobstructed airfields over close-in defenses.
Relocation tries at most 12 land positions, rejecting destinations inside any
protected airfield. If none is safe, it logs/skips instead of using the unsafe
origin. Generated installation objects at unsafe authored positions are skipped;
the generator does not move existing authored airport scenery.

The runtime safeguard scans AI ground groups every **30 simulation seconds**.
If a unit is inside protected grounds, it orders its whole group along a
two-point off-road route to a safe destination, using a 200 m destination margin
and requested speed of 4 m/s. Aircraft and groups containing a player-controlled
unit are excluded. Static objects cannot receive movement orders.

The loop tracks progress and does not reset routes while a group is making
progress. It retries after **120 seconds** without 50 m of progress, or after a
failed destination/task attempt. Cleared/disappeared groups leave the tracking
state, and old-generation timers stop after campaign reinjection. A failed sweep
is logged and the next interval remains scheduled.

Look for `[airbase_clearance]` records: `routed`, `cleared`, `stalled`, `failed`,
and summary counts. A route accepted by DCS is not evidence that the units
actually moved. The evacuation task replaces the group's current AI task;
automatic restoration of the previous task is not implemented.

`npm run test --workspace ee-mission` passes, including the clearance-enabled
campaign scenario and focused checks for off-center runways, FOB/neutral fields,
safe placement, player exclusion, movement orders, no route churn, stall retry,
bounded destination failure and stale timer cancellation. The frozen historical
Lua fixtures remain unchanged. The shared-branch handoff required removing the
temporary test-only clearance bypass: new explicit issued-order expectations
cover real clearance behavior and document the intentional placement changes in
[`CLEARANCE-DELTA.md`](../../packages/ee-mission/test/golden/CLEARANCE-DELTA.md).
Relocation preserves the candidate's bearing so defense rings do not collapse
onto one shared destination. This refinement postdates the retained live-trial
payload; that payload remains an immutable record of what was tested live.

The automatic loop has now been [tested in the running mission](live-trial/README.md).
Its first sweep detected and routed **23 groups**, with zero reported failures.
Infantry at Tbilisi, Vaziani and Beslan physically moved about 111 m and then
300 m from their starting positions. The next two intervals produced no repeated
route orders for those progressing groups. The loop remains active in that
mission, and the campaign generation stayed at 1.

This guarded trial loaded only the compiled cleanup dependencies, with a recorded
test-only adaptation preventing campaign-generation advancement. It did not
execute the campaign entry point or spawn/delete units. The exact payload and
builder are retained with the evidence. Full envelope clearance and a fresh
production mission startup remain separate checks; observed movement is not yet
proof that every airfield is clear. Future missions should embed the rebuilt
production bundle, not the trial payload.

## Limits

- Two Vaziani groups were removed together; the test did not isolate one culprit.
- The other two stationary recon jets were not cleared, so their causes remain
  unconfirmed.
- This is separate from runtime-FARP helicopter disappearance, whose workaround
  initializes FARPs before mission load.
- An active stationary jet can have other causes; verify obstruction rather than
  treating every stationary aircraft as this defect.
