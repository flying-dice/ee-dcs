# Live DCS probe — 2026-09-22 (epic #17, pre-P2/P3 design evidence)

Read-only probes against a freshly generated two-sided Caucasus mission, via the in-DCS
JSON-RPC bridge. **Not** the P5 acceptance witness — P2/P3 are unwritten. Purpose was to
resolve the DCS unknowns that P2 and P3 would otherwise have been designed on top of.

- Bridge: `http://127.0.0.1:25570/rpc`, `dcs-studio-mission` v0.4.0, `x-dcs-env: mission`.
  The `/mcp` endpoint in `.mcp.json` is **not** this bridge. Methods: `eval`, `console_read`,
  `repl_*`, `debug_*`, `dump_globals`, `ping`.
- Mission: theatre Caucasus, 25 airbases from `world.getAirbases()`, 4 authored stock FARPs
  (2 per side), campaign bundle including the P1 lifecycle work.
- Method: `eval` only. One temporary global event probe (`_G.__PROBE`) installed to capture
  BIRTH/TAKEOFF/LAND/DEAD/CRASH/RUNWAY_TAKEOFF/RUNWAY_TOUCH. No campaign code injected,
  no campaign state mutated.

## Event ids on this build (measured, not guessed)

`BIRTH=15  TAKEOFF=3  LAND=4  DEAD=8  CRASH=5  RUNWAY_TAKEOFF=54  RUNWAY_TOUCH=55`

## Finding 1 — `event.place` is populated, with identity (P3)

Every BIRTH / TAKEOFF / RUNWAY_TAKEOFF event carried a usable `place`, e.g.

```
t=146 id=54 unit=Recon-2-2048-1 place=Kutaisi(id=25,cat=0)
t=180 id=15 unit=Heli-CAS-1-2054-1 place=FARP-farp_H3-852d527bfffffff-1(id=3,cat=1)
```

`place:getName()`, `getID()` and `getDesc().category` all resolve. **P3 must use the event's
landing-site identity.** The current "credit the nearest friendly base anywhere on the map"
positional proxy in `supply.make_land_handler` is not required and should be retired.
LAND (`id=4`) was not observed in this window — the probe handler is still installed and will
capture it; confirm before P3 relies on it.

## Finding 2 — `getParking(true)` does NOT reflect occupancy (P2)

At FARP id=3 with three terminals flagged `TO_AC=true`, `getParking(true)` still returned
**4 of 4**. At Sukhumi, with `TO_AC=[24,23]` unchanged across a minute, the available count
moved 24 → 25.

**`getParking(available=true)` is unreliable as a capacity read.** P2 must derive occupancy
from the per-terminal `TO_AC` flag, and must treat a parking query failure as *unknown*,
never as zero or unlimited.

## Finding 3 — FARP terminals are `Term_Index` **0..3**, and our code emits "1".."4" (P2)

All four authored FARPs report exactly four terminals, `Term_Type=40`, `Term_Index` 0,1,2,3.

`farp_parking.configureDeparture` assigns `parking`/`parking_id` of "1","2","3","4"
(`farp_parking.ts:77-86`). With four helicopters spawned at FARP id=3 (`Heli-CAS-1-2054` and
`-2055`, two ships each), the observed occupancy was:

```
FARP id=3  [3:true  2:true  1:true  0:false]
```

Occupancy landed on Term_Index 1, 2 and 3 — so **the emitted parking value maps directly to
`Term_Index` (0-based)**, meaning:

- **`parking="4"` addresses a terminal that does not exist** — one aircraft in every four
  gets an invalid stand.
- **`Term_Index=0` can never be used** by the current allocator, permanently wasting one of
  the four pads.

The module header's citation of the ME exporter's "1 through 4" is 1-based *editor* naming;
the runtime index is 0-based. This is a concrete, measured defect for P2 to fix — and it is a
DCS-representation fact, not a campaign constant, so it is not a Prime Directive value.

## Finding 4 — a departed aircraft keeps its stand reserved (P2)

FARP id=3 still reported `[3:true 2:true 1:true]` while all four of its helicopters were
airborne at 1100–1250 m and 24–59 m/s.

**Confirms the epic's warning:** releasing a lease on takeoff would be wrong. A lease must be
held until the aircraft is retired/settled, not until it lifts.

## Finding 5 — the Sukhumi fixed-wing "stuck" symptom is a long taxi, not a blockage

`CAP-1-2049` and `Recon-1-2053` sat at a constant 8.3 m/s, alt ~16 m, for minutes, appearing
frozen. They were not:

- `world.searchObjects` over a 300 m sphere around each returned **0 other units** — no
  obstruction, so the existing clearance work is not implicated.
- Positions changed continuously; `CAP-1-2049` finally fired RUNWAY_TAKEOFF at **t=445 s** and
  TAKEOFF at t=456 s — roughly **7.5 minutes** of taxi.
- The Kutaisi recon (`Recon-2-2048`) took off at t=146 s from the same code path.

Do not treat a stationary-looking jet, or an elapsed observation window, as a failed departure.
This is direct support for the epic's "unknown is not failed" rule and for the P0-b decision
not to bake an observation timeout into the harness. It also means the **120 s spawn-diagnostics
sample window is shorter than a real Sukhumi departure** and cannot, alone, prove a launch failed.

## Housekeeping

`_G.__PROBE` (event ring + handler) is still installed in the running mission. It is additive
and read-only; a mission reload clears it.

## Finding 6 — LAND **does** carry `place` (P3 unknown closed)

Observed after the first write-up, at t≈1700–1960:

```
t=1712 id=4  unit=Recon-2-2048-1     place=Kutaisi(id=25,cat=0)
t=1956 id=4  unit=Heli-CAS-1-2055-2  place=FARP-farp_H3-852d527bfffffff-1(id=3,cat=1)
```

`S_EVENT_LAND` carries a full landing-site identity for both an airdrome and an authored FARP.
**P3 can and must use it.** `supply.make_land_handler`'s "credit the nearest friendly base"
positional proxy is now unnecessary and should be retired, not merely documented.

By contrast **CRASH (5) and DEAD (8) carry `place=nil`** — a loss has no site. P3 must not
expect one, and must not treat a missing `place` as a landing.

## Finding 7 — the staggered return/loss case is real, and was captured live

```
t=1953 id=55 Heli-CAS-1-2055-1 RUNWAY_TOUCH place=FARP(id=3)
t=1954 id=5  Heli-CAS-1-2055-1 CRASH        place=nil
t=1955 id=55 Heli-CAS-1-2055-2 RUNWAY_TOUCH place=FARP(id=3)
t=1956 id=4  Heli-CAS-1-2055-2 LAND         place=FARP(id=3)
```

One member of a two-ship crashed on touchdown while the other landed normally, two seconds
apart. Under the current `make_land_handler`, member 2's LAND credits **every unit returned by
`getUnits()`** and schedules destruction of the whole group — so this exact sequence credits a
crashed airframe as a recovery. This is no longer a hypothetical P3 regression case; it is an
observed one. Use these timings as the fixture.

Note also that RUNWAY_TOUCH (55) fires for a crash as well as a landing — **a runway-contact
event does not mean completed recovery**, exactly as the epic warns.

## Finding 8 — departure crashes cluster on the SECOND member of a pair at FARPs (hypothesis)

12 CRASH events in ~35 minutes. Correlating each against its BIRTH place and age:

```
Heli-CAS-2-2062-2  age=44s   born FARP id=2
Heli-CAS-1-2072-2  age=48s   born FARP id=3
```

Both are **departure** crashes (the rest are 189–1774 s old, i.e. mission/combat losses), both
at authored FARPs, and both are the **`-2`, second unit of a two-ship**. `Heli-CAS-1-2072-1`
took off normally two seconds after its wingman crashed.

**Hypothesis, not a conclusion:** this is consistent with the Finding 3 parking defect — the
allocator hands out "1".."4" where only `Term_Index` 0..3 exist, so a group can receive an
invalid stand for its second aircraft while pad 0 is never used. That would place or stack the
second helicopter wrongly at spawn. This is the most plausible lead yet for the unexplained
sprint-03 RED `Heli-CAS-1-2107-1` departure crash, which was never root-caused.

**Do not close that investigation on this basis.** It is a correlation over two events. The
test is: after P2 lands, re-run a comparable mission and check whether young (<60 s) FARP
departure crashes disappear. If they persist, the parking defect was not the cause.


## Capture grown to 305 events (t=10594) — earlier findings hold

Re-verified on the larger sample:

| check | result |
| --- | --- |
| LAND events | **15**, and **15/15 carry a usable `place`** (zero `place=nil`) |
| aircraft losses reported as CRASH (5) | **40 of 40** |
| aircraft losses reported as DEAD (8) | **0 of 70** DEAD events were aircraft |

Finding 1 (retire the positional proxy) and backlog card 28 (nothing ever regenerates) are
both stable results, not small-sample artefacts.
