# Helicopter spawn diagnosis (issue #3)

## Live evidence — 2026-09-22 session

### Latest clean control and report location

The user's empty `farp.miz` supports dynamic hot AH-64D spawning: both units were
active by +1 second and airborne by +120 seconds, with birth/takeoff events and
visual confirmation. The user also confirmed a replacement pair took off after
the investigator destroyed the first pair and reused the same authored FARP.
The same investigator repeated the proven specification at a fresh runtime FARP
with four free pads. Both returned units were inactive and disappeared by +1 s,
remaining absent at +5/+30 s without birth/takeoff events. The recycled authored
pair remained active and airborne. Earlier occupied-pad cases must not be treated
as clean negative controls. Location and heliport/warehouse initialization remain
possible causes; this does not identify a single engine subsystem.

The shareable report and detailed workaround documentation live under
[`dcs-bugs/runtime-farp-spawning`](../../dcs-bugs/runtime-farp-spawning/README.md).
The generator now bakes stock FARPs and warehouses into the mission; web checks
and archive regression pass, as does the mission-loaded FARP reuse regression.
Generated campaign live acceptance remains pending.

### Working Mission Editor control supplied by user

At 00:28 BST the user saved and loaded `eech-caucasus (6).miz` with `Rotary-1`,
two AH-64Ds taking off hot from a stock FARP. At simulation time 40.9 both were
active with life 14; the first was airborne and the second still on the pad.
Preserved archive SHA-256:
`E0ED0CF30B71F337E00C5403968E3888D8E8D360E0DD11213DB3E3C56C58CCFC`.

The reference uses the same hot-start type/action, origin, `helipadId` and
`linkUnit` pattern as the adapter. Its aircraft and departure waypoint have
nonzero speed (41.6667 m/s), parking is 1/3, and the FARP is mission-loaded.
Those are comparisons, not established causes. Senior developer owns bounded
dynamic-clone, speed-only and runtime-FARP tests; original `Rotary-1` is preserved.
Raw reference/comparison material is under `scratchpad/issue3-me-reference/`.

`Issue3-ME-DynamicExact` then cloned the exact reference group onto its original
FARP through the real dynamic API, using unique names and omitting colliding IDs.
Both original helicopters were already airborne. The dynamic copy remained
present but inactive, life 14 and stationary through +120 seconds; no birth or
takeoff occurred. Removed only that test group afterward. Reference speeds,
payload, 1/3 parking and a mission-loaded FARP are therefore insufficient to make
this dynamic path activate. Aircraft identity and activation fields are the next
bounded tests; the earlier explicit-ID test changed only the FARP static ID.

Further bounded tests with unique aircraft IDs, explicit false activation flags,
omitted `start_time` and `activateGroup` still produced inactive placeholders.
Later parking inspection showed no free terminals at that authored FARP, so pad
reservation is a confound: those results do not prove dynamic spawning at an
empty authored FARP fails.

A fresh runtime FARP had four verified free terminals. `Issue3-ME-RuntimeParking`
used numeric runtime terminal IDs 3/2, actual pad coordinates, no `parking_id`,
and the reference hot mode/payload/speeds. Both aircraft appeared inactive with
life 14, then disappeared by +1 second, still absent at +5/+30 without births.
Runtime parking representation alone is therefore insufficient. Next control is
a disposable copy with an empty mission-loaded FARP and campaign triggers removed;
the supplied original archive remains unchanged.

### Earlier runtime-FARP controls

Connected to DCS Studio mission bridge 0.4.0 via its discovered JSON-RPC `eval`
method at `http://127.0.0.1:25570/rpc`. `/health` confirms mission state; `/mcp`
returns 404 in this installed version. The initially running mission had the old
bundle and zero live helicopter groups on both sides. Preserved its log before
injecting the rebuilt instrumented campaign (generation 2).

| Controlled case | Measured result |
| --- | --- |
| Original hot FARP departure, RED Mi-24V and BLUE AH-64D | Two units returned immediately; both absent by +1 second |
| RED cold-only change | Same disappearance |
| RED airborne control, same payload | Active and airborne at +1/+5 seconds |
| `start_time` set to current time | Exists but inactive; not a valid fix; test group removed |
| Omit `start_time` | Same disappearance |
| Simplify route to departure and one navigation point | Same disappearance |
| Remove departure `linkUnit` | Exists but inactive; not a valid fix; test groups removed |
| Fresh isolated FARP with explicit static `unitId=90001` | Same disappearance |
| Hot ground departure at measured runtime pad coordinates | One Mi-24V crashed at +0.16 seconds; the other became active and took off |
| Ordinary-airfield control at Kutaisi | Both AH-64Ds active and moving on the ground |

These observations isolate ground-departure activation/placement; they do not yet
prove the final fix. Runtime parking reports terminal indices 0–3, whereas the
Mission Editor recipe uses names 1–4. That difference alone is not proof of an
indexing bug. Tests must include `Unit:isActive()`; inactive placeholders can
report existence, life and group size. Active-state logging and regressions are
being added. Senior developer owns subsequent live tests to avoid interference.

## Current finding and limits

The local 2026-09-21 DCS log identifies RED groups `Heli-CAS-1-2120` and
`Heli-CAS-1-2121` as departures from `FARP-farp_H3-852d524bfffffff-4` and
`FARP-farp_H3-852d527bfffffff-1` respectively (lines 1837–1845). Both requests
reached the real API (lines 1867–1871). Their later physical state is unknown.

The adapter previously replaced requested hot departures with cold departures.
It now preserves the requested type and its matching action. This restores the
documented hot-start policy; a live controlled comparison is still needed to
establish whether this explains the missing helicopters. Parking rotation,
asynchronous accounting and Apache asset errors remain separate candidates.

The downloaded `(6).miz` currently has a modification time later than the failing
run, so it must not be assumed to preserve that run's exact embedded executable.

## Capture one useful run

1. Generate a new mission using the rebuilt `dist/ee-dcs.lua`. Existing `.miz`
   files retain their old embedded Lua. Preserve the exact `.miz`, embedded Lua
   SHA-256, full `dcs.log`, DCS version and F10 visibility settings together.
2. Keep `_DMT_DEBUG = true` (the default). Find `[spawn_probe]` in the log to
   confirm the instrumented bundle is running. Setting it to false disables new
   probes and ends active probes at their next sample.
3. Follow one RED Mi-24V section and one BLUE AH-64D section by `gen`, `seq` and
   `group`. Use permissive F10 visibility for the test; a Lua presence query does
   not prove that the player can see that aircraft on the map.
4. Allow at least 120 simulation seconds after each submission. The observer logs
   immediately and at +1, +5, +30 and +120 seconds. These are diagnostic samples,
   not campaign timeouts. Pausing DCS pauses these intervals.
5. Retain the whole correlated trace, including query errors. Do not treat an
   absent event or the end of observation as a failed spawn or a reason to refund.

## What the trace means

- `phase=submitted`: final departure type/action, references, requested count,
  activation/visibility fields, parking, coordinates, fuel and pylons. This is
  emitted before the real API call, after the queue proxy has been returned.
- `base=...`: matching campaign Airbase identity, coalition/category, position,
  corresponding static identity, and all/free parking IDs, types and coordinates.
  An unsupported parking query is explicitly `QUERY_ERROR`, not zero capacity.
- `phase=api_result`: `returned`, `nil` or `threw`. A returned handle proves only
  API acceptance. The ordinary queue log now says `api_returned`, not `spawned`.
- `phase=sample`: group existence/size, then each expected named unit's presence,
  existence, life, `in_air`, XYZ, height above terrain and sorted true attributes.
  Each engine read is protected so one stale handle does not hide its neighbours.
- `phase=event`: DCS birth (15), takeoff (3), death (8), crash (5). Registration
  precedes submission so synchronous births are captured. Events are limited to
  the expected unit names and the same 120-second observation window.
- `phase=observation_complete`: observers are released. Old generations stop
  emitting on reinjection. Diagnostics never retry, refund or alter task state.

| Evidence | Next controlled test |
| --- | --- |
| API returned, all expected units absent | Compare final links/parking/activation against a working ME-authored FARP |
| Units appear, then die/disappear | Check placement, collisions, parking reuse and crash/death events |
| Units remain alive and grounded | Compare otherwise identical explicit cold/hot starts and FARP support |
| Units become airborne but F10 is empty | Check visibility settings and player coalition |
| Unit reads succeed but old combat-heli diagnostic is zero | Compare raw attributes; the old diagnostic is a presence predicate, not a count |
| Any `QUERY_ERROR` | Resolve the failed query before interpreting absence |

Start with a single Mi-24V section on a clean mission. Compare an ordinary hot
airfield, a Mission Editor stock FARP, and the dynamic stock FARP with the same
aircraft/payload and simple route. Change only cold/hot between those two cases;
then restore CAS/BAI routing and repeat the discriminating case with AH-64D.
Use a fresh mission per case to exclude existing parking occupants.

## Offline verification

`npm run test --workspace ee-mission` builds the bundle, runs 27 core parity
checks, fault-injects spawn/query outcomes, and compares the campaign with golden
fixtures at 310 and 2100 seconds. Diagnostic timers are disabled in the campaign
parity harness and tested independently. No golden snapshots were rewritten.
Offline fakes do not model DCS materialisation or establish live acceptance.
