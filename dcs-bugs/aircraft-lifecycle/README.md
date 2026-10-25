# Aircraft lifecycle — live evidence (epic #17)

Evidence captured from a running, freshly generated two-sided Caucasus mission on
**2026-09-22** via the in-DCS JSON-RPC bridge (`http://127.0.0.1:25570/rpc`). Analysis and
conclusions live in [`docs/bots/LIVE-PROBE-2026-09-22.md`](../../docs/bots/LIVE-PROBE-2026-09-22.md);
this directory holds the raw capture.

## `probe-events-pre-p2.txt`

Raw event ring from a temporary read-only `world.addEventHandler` probe (`_G.__PROBE`),
one line per event:

```
t=<mission seconds> id=<event id> unit=<unit name> place=<name(id=..,cat=..)> | nil
```

Captured ids: `BIRTH=15 TAKEOFF=3 LAND=4 DEAD=8 CRASH=5 RUNWAY_TAKEOFF=54 RUNWAY_TOUCH=55`
(measured on this build, not assumed).

This file serves two purposes:

1. **P3 fixtures.** Real timings for the staggered return/loss case — e.g. `Heli-CAS-1-2055`,
   where `-1` crashed on touchdown at t=1954 and `-2` landed normally at t=1956, two seconds
   apart. Also demonstrates that `LAND` carries a real landing-site identity while `CRASH`/`DEAD`
   carry `place=nil`, and that `RUNWAY_TOUCH` fires for a crash as well as a recovery.
2. **The pre-P2 control.** Departure crashes (age < 60 s from BIRTH) in this capture are the
   baseline for the Finding 8 falsifier: after P2's parking-lease work lands, a comparable
   mission should show them disappear. **If they persist, the parking defect was not the cause**
   and the sprint-03 RED `Heli-CAS-1-2107-1` departure crash needs a different explanation.

The capture is from a mission whose bundle already includes the P1 submission work, and
predates P2/P3. It is a control for the parking hypothesis only — it is **not** the P5
acceptance witness, which requires a fresh mission after the lifecycle work is complete.
