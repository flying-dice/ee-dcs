# Generated campaign live validation — 22 September 2026

Read-only observation of the user's newly loaded Caucasus campaign through DCS Studio mission JSON-RPC and bounded `dcs.log` excerpts. DCS reports **2.9.29.27468** (x86_64, MT, Windows); bridge `/health` was OK. No mission objects or campaign state were changed. Mission Lua reported `_DMT_GEN=1` and `_DMT_DEBUG=true`.

## Mission-authored launch sites

`env.mission.coalition.{red,blue}.country[].static.group[].units[]` contains **10** campaign-named units with `type="FARP"`, `shape_name="FARPS"`: five RED and five BLUE. The two RED launch sites below appear in that mission definition at the same coordinates as their `[spawn_probe]` base records. `StaticObject.getByName` and `Airbase.getByName` also resolved each site live, with matching IDs and coalitions. This confirms these are mission-authored stock FARPs in the loaded mission, not merely runtime-created names.

| Authored RED FARP | Mission x,y | Live airbase/static ID | Campaign launch |
| --- | --- | ---: | --- |
| `FARP-farp_H3-852c28d7fffffff-1` | -230197.32, 780290.53 | 6 | `Heli-CAS-1-2107` |
| `FARP-farp_H3-852c281bfffffff-4` | -241023.78, 815797.33 | 9 | `Heli-CAS-1-2108` |

BLUE example `FARP-farp_H3-852c2e37fffffff-2` is also authored and resolves live as coalition 2, airbase/static ID 2. `coalition.getStaticObjects` did not enumerate the FARPs, although named lookup resolved them; authored definition plus named lookup are the relevant checks.

## RED Mi-24V campaign sections

At campaign time **t=180 s**, generation 1, sequence 189 and 190 submitted real CAS groups through the queue to `coalition.addGroup`. Both probes recorded `TakeOffParkingHot` / `From Parking Area Hot`, two `Mi-24V` with parking 1/2, the matching authored FARP ID in `helipad` and `link`, four available parking terminals before submission, `phase=api_result outcome=returned`, and birth events for both units. At elapsed 0 the units were present with life 16 but inactive, then all four were **active, life 16, and still present at +1, +5 and +30 s**. Thus these were not the earlier one-second disappearing placeholders.

| Group / base | Takeoff events after submission | +120 s probe | Result |
| --- | --- | --- | --- |
| `Heli-CAS-1-2108`, `...281b...-4` | Unit 1 +60.2 s; unit 2 +81.26 s | Both present, active, life 16, `in_air=true`; AGL 99.1 m and 88.9 m | **PASS** for the two-aircraft section. |
| `Heli-CAS-1-2107`, `...28d7...-1` | Unit 2 +91.44 s; unit 1 crash event +46.48 s | Unit 2 present, active, life 16, `in_air=true`, AGL 129.6 m; unit 1 absent | **PASS** for activation and one takeoff; separate departure crash prevents calling this an intact two-aircraft section. |

The crashed unit `Heli-CAS-1-2107-1` was at `(-230215.43, 2398.03, 780294.56)`, AGL 40.85 m at +1 s; at +30 s it was at `(-230213.25, 2398.39, 780294.43)`, AGL 40.19 m, then logged crash event ID 5 at +46.48 s. The base was `FARP-farp_H3-852c28d7fffffff-1`. The trace does not establish why it crashed.

At a later live RPC sample at **t=594.4 s**, `Heli-CAS-1-2108` still had both units active/alive/airborne; `Heli-CAS-1-2107` had its surviving unit active/alive/airborne. This is an end-to-end RED demonstration of the pre-authored-FARP workaround for the immediate disappearance defect, with the recorded crash as a distinct residual.

## BLUE AH-64D campaign sections

The first CAS/BLUE generator pass produced no helicopter task. Its next scheduled pass at **t=905 s** created CAS tasks #19 and #20, which the task board assigned at **t=1080 s**. The live mission definition contains both launch FARPs as BLUE stock `FARP`/`FARPS`: `FARP-farp_H3-852c2eaffffffff-3` at (-274923.19, 778659.78), and `FARP-farp_H3-852c285bfffffff-5` at (-278890.85, 826197.02).

At t=1080 s, generation 1, sequence **191** submitted `Heli-CAS-2-2109` (two `AH-64D`) from the first FARP, ID 3; sequence **193** submitted `Heli-CAS-2-2111` from the second, ID 5. Both used `TakeOffParkingHot` / `From Parking Area Hot` with matching helipad/link IDs. Both API calls returned, all four birth events appeared, and all four aircraft were present, active and life 14 at +1, +5 and +30 s. Each section had one `in_air=true` unit by +30 s. A concurrent RED Mi-24V section was sequence 192.

| BLUE group | Takeoff events after submission | +120 s probe | Result |
| --- | --- | --- | --- |
| `Heli-CAS-2-2109`, `...2eaffffffff-3` | Unit 1 +61.4 s; unit 2 +75.04 s | Both present, active and airborne; life 13/14, AGL 104.7/115.1 m | **PASS** for activation, survival and two takeoffs; unit 1 had lost one life point by +120 s. |
| `Heli-CAS-2-2111`, `...285bfffffff-5` | Unit 1 +60 s; unit 2 +75.5 s | Both present, active, life 14 and airborne; AGL 72.7/82.2 m | **PASS** for activation, survival and two takeoffs. |

**Issue #3 workaround verdict:** PASS for the observed generated campaign on both sides. The pre-authored FARP path avoided the previous immediate disappearance: two intact BLUE AH-64D sections and one intact RED Mi-24V section departed, with active/alive/airborne aircraft at +120 s. A separate RED departure crash remains unexplained. This does not prove every generated FARP or mission configuration works.

## Separate fixed-wing observation

The user's report of no airplane takeoffs through roughly 16 campaign minutes is corroborated for the three recon jets seen. Task creation and queue/API submission did occur: BLUE `Recon-2-2098` (F-15C) assigned from Tbilisi-Lochini and `Recon-2-2099` (F-15C) from Vaziani, queue sequences 180/181; RED `Recon-1-2106` (Su-27) from Beslan, sequence 188. All three `coalition.addGroup` calls returned. At live t=1044.7 s and again at **t=1112.1 s**, all three were present, active, life 20, grounded. At t=1112.1 their velocity components were exactly **(0,0,0)**, so they were stationary rather than taxiing. Positions at t=1112.1 were `Recon-2-2098-1` (-314480.22, 895825.38), `Recon-2-2099-1` (-318048.69, 902475.50), and `Recon-1-2106-1` (-148838.61, 843499.88), in DCS x/z coordinates.

The recon builder in `packages/ee-mission/src/recon.ts` submits `TakeOffParkingHot` / `From Parking Area Hot`, `airdromeId=homeAirbase.getID()`, departure speed 0, ETA 0 locked, and no explicit `parking`, `parking_id`, `start_time` or `uncontrolled` fields. This describes the submitted source template; the bridge did not expose a post-submission route/spec dump for those jets. The evidence identifies a fixed-wing ground-departure stall, not its cause. Separately, the observed keysite/OCA strike generator passes made **zero strike tasks** because candidates were fogged, already targeted for recon, or deduplicated, so the lack of strike aircraft in this window is a task-selection outcome rather than a demonstrated spawn failure.

At t=1377.2 s the three recon aircraft still had the same horizontal positions. The user visually reported infantry on Vaziani's runway, naming `FP-Vaziani-2043` and `FP-Vaziani-2045`. Live positions were `FP-Vaziani-2043-1` (-318213.75, 902325.88), **222.8 m** from stationary `Recon-2-2099-1`, and `FP-Vaziani-2045-1` (-318517.81, 902654.94), **502.3 m** away. Similar firing-point groups were present near the other stalled jets: `FP-Tbilisi-Lo-2072-1` 491.0 m from `Recon-2-2098-1`, and `FP-Beslan-2083-1` 531.9 m from `Recon-1-2106-1`. These are horizontal distances, not a runway/taxi-path intersection test. `base_defenses.ts` generates `FP-*` units at a random angle and radius around each base and snaps to land; its placement function has no runway/taxi clearance check. They are a plausible obstruction to investigate, but the current read-only evidence does **not** establish that they caused the jets to remain stationary.

### User-authorized Vaziani obstruction check

After the read-only baseline above, the user authorized removing **only** `FP-Vaziani-2043` and `FP-Vaziani-2045` and observing the jet. At t=1566.1 s, immediately before intervention, both one-unit groups were present and `Recon-2-2099-1` remained at (-318048.6875, 902475.5), active, life 20, grounded, velocity (0,0,0). At t=1599.6 s, `Group:destroy()` was called on exactly those two names; both calls succeeded. Named group lookups still returned handles in that same RPC response, but at the next sample, **t=1637 s**, both names were absent. No other group was destroyed or spawned by this check.

At t=1637 s, the F-15C had moved to (-318126.16, 902334.26) and had velocity (-5.89, 0, -5.90) m/s, active and still grounded: it had begun taxiing. At **t=1750.7 s**, more than 120 simulation seconds after removal, `Recon-2-2099-1` was active, life 20, **`inAir=true`**, at (-317088.67, 895994.32), altitude 4813.9 m and velocity (161.06, 62.56, -165.81) m/s. The two untouched recon controls, `Recon-2-2098-1` at Tbilisi-Lochini and `Recon-1-2106-1` at Beslan, were still active, life 20, grounded, with zero velocity and unchanged positions.

This before/after intervention strongly implicates the two Vaziani firing-point groups as a departure obstruction: the jet had sat motionless for over 1400 simulation seconds, then taxied and flew after their removal while the untouched controls stayed still. Removing both together does not identify which one mattered, nor rule out other obstruction or AI state effects. The fixed-wing finding is separate from the authored-FARP helicopter workaround verdict.

The current log did include `[spawn_probe]` submitted, API result, birth, takeoff, crash and +120 s samples. No probe query error appeared in the correlated RED or BLUE traces.
