# P5 — live witness runbook (epic #17)

**Status: PENDING. Not run. Do not mark epic #17 closed until this passes.**

P1–P4 are complete and green offline. P5 is the only remaining gate, and it **cannot** be
satisfied by re-injecting the bundle into an existing mission — the epic requires a freshly
generated archive. The probe session of 2026-09-22 was diagnostic, not the witness.

## Why a fresh mission is mandatory

`main.ts` runs `reset.nuke()` at boot and the campaign discovers airbases from the map at
inject time. Re-injection into a running campaign wipes and reseeds state, so it exercises
neither generated-archive placement nor clean-boot ground clearance. An old `.miz` also
carries pre-P2 FARP/parking authoring. Lua re-injection alone is explicitly **not** an
equivalent test.

## Prerequisites

1. `npm run build --workspace ee-mission` from the repo root (TSTL is the only producer of
   `dist/ee-dcs.lua`).
2. `npm run dev --workspace dcs-eech-mapgen` — the `predev` hook syncs the bundle into
   `apps/web/src/generated/campaign-bundle.lua`. **Check the reported KB size changes**, or you
   will generate from a stale bundle. Watch the port: 5173 may already be taken.
3. Generate a small two-sided Caucasus mission with stock mission-authored FARPs.
4. Record, before flying anything: source commit, bundle **and** archive SHA-256, generator
   config/seed, DCS build, launch sites and IDs, aircraft types, observation settings.
5. Load and **run** the mission (not the main menu). Bring up the bridge at
   `http://127.0.0.1:25570/rpc` (JSON-RPC `id` must be a **string**).

## Evidence matrix — all rows required

| Scenario | Required observation |
|---|---|
| BLUE + RED fixed-wing at ordinary airfields | correct ramp placement, active/alive members, unobstructed taxi, real takeoff. Include a previously affected airfield (Sukhumi) where practical |
| BLUE + RED helicopters at authored FARPs, plus an ordinary-airfield helicopter control | correct live base identity, activation/survival, departure of the expected members, hot representation retained |
| Clean generated start | ground placement/clearance works with **no** manual deletion beforehand |
| Normal return + second wave at the same site | each returning aircraft credited once; stock and abstract slots reconcile; **actual stand release observed**; newly named aircraft depart again |
| Deliberately full/contended parking | no overlapping leases, no duplicate aircraft, no false launch success; record the actual wait/rejection behaviour including DCS-held reservations after takeoff |
| Staggered return + controlled one-member loss | only the returned member is credited; the loss is not an RTB; no still-airborne member removed by cleanup |
| Debug disabled | lifecycle correctness persists with probes off |

## Specific checks this port now demands

- **Departure crash falsifier (probe Finding 8).** The pre-P2 control
  (`dcs-bugs/aircraft-lifecycle/probe-events-pre-p2.txt`, 305 events) contains departure
  crashes — losses under 60 s from BIRTH, all at FARPs, all on the `-2` second aircraft of a
  pair. If P2's 0-based `Term_Index` fix was the cause, these should now be **absent**.
  **If they persist, the parking defect was not the cause** and the sprint-03 RED
  `Heli-CAS-1-2107-1` crash needs a different explanation. Do not claim it fixed by association.
- **Taxi is slow.** A Sukhumi departure took ~7.5 minutes in the control run. Elapsed time is
  not evidence of failure; the 120 s diagnostics window is shorter than a real departure.
- **`TO_AC` stays true after takeoff.** A stand still flagged occupied by an airborne aircraft
  is correct behaviour, not a leak.
- **Do not use `getParking(true)`** as a capacity read — measured unreliable.
- **Backlog card 28 is still open**, so expect aircraft losses never to regenerate. That is a
  known separate defect, not a P5 failure.

## Closing

Attach the mission, the procedure, correlated lifecycle events, parking observations,
before/after reserve-task-slot values, regression results and at least one failing negative
control to epic #17 and issue #11. If a required row cannot be run, report it **pending** and
leave the epic open. The closed state of #2/#3 does not close #17.
