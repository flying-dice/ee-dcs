# Ground units obstruct AI aircraft departures

Status: live obstruction reproduced and removal workaround verified on
22 September 2026, DCS **2.9.29.27468**, Caucasus. Not submitted to ED.

This records a campaign placement defect and the observed DCS response. It does
not establish that DCS should allow aircraft to taxi through infantry. The
generator must keep airbase movement areas clear.

## Symptom

Three campaign reconnaissance jets spawned successfully and were active/alive,
but remained motionless on the ground for more than 15 minutes. The user spotted
two generated infantry groups on the runway at Vaziani:

- `FP-Vaziani-2043`
- `FP-Vaziani-2045`

Their positions were respectively 222.8 m and 502.3 m horizontally from the
stationary F-15C, `Recon-2-2099-1`. Distance from an aircraft alone is not a
taxiway/runway intersection test; the user's visual observation identified the
runway obstruction.

## Controlled before/after test

The user explicitly authorized removing those two groups only. The same
GPT-5.6-Sol observer measured the live mission before and after; no aircraft were
respawned, no routes were changed, and the mission was not reloaded.

| Mission time | Action / observation |
| ---: | --- |
| 1566.1 s | Vaziani F-15C active, life 20, grounded at x/z (-318048.6875, 902475.5), velocity (0,0,0); both infantry groups present. |
| 1599.6 s | Destroyed only the two named infantry groups; both calls succeeded. |
| 1637 s | Both infantry groups absent. F-15C had moved to (-318126.16, 902334.26), taxiing at approximately 8.33 m/s. |
| 1750.7 s | F-15C active, life 20, airborne; velocity (161.06, 62.56, -165.81) m/s. |

Untouched comparison aircraft `Recon-2-2098-1` at Tbilisi-Lochini and
`Recon-1-2106-1` at Beslan remained grounded with zero velocity and unchanged
positions. This strongly implicates the removed Vaziani infantry as a departure
obstruction. The experiment does not identify which of the two groups was
responsible, nor establish that every stationary aircraft has this cause.

Full bounded observations are retained in
[the live validation record](../runtime-farp-spawning/generated-campaign-validation.md).

## Placement defect

The observed `FP-*` placement path in `base_defenses.ts` chose random angles and
radii around the airbase center and snapped positions to land. It did not exclude
runways, taxiways or aircraft parking. A terrain-valid point is not necessarily a
safe point for a ground unit at an operational airbase.

The implemented fix covers generated ground placements and a periodic evacuation
loop. In a [guarded live trial](live-trial/README.md), 23 existing groups received
safe-exit routes and infantry physically moved at all three observed airfields;
no repeated route orders appeared in the next two intervals. Geometry, fallback,
test results and limits are detailed in [workarounds.md](workarounds.md).

## Reproducing / investigating

1. Run a mission with generated airbase defenses and a hot-parking AI fixed-wing
   departure. Retain the exact mission and placement seed when comparing runs.
2. Confirm the aircraft exists, is active/alive, and stays at the same position
   with zero velocity across samples. Record its group, airbase and mission time.
3. Inspect the runway, taxiways and parking for ground units, including infantry
   that can be easy to overlook. Record group names and coordinates.
4. In a disposable test, remove only identified obstructing groups, preserving
   the aircraft and route. Record whether movement/takeoff follows.
5. Keep an untouched comparison aircraft if available. Do not interpret a
   successful `addGroup` return as proof that the departure path is unobstructed.

The specific run is documented above; no standalone deterministic reproduction
mission for this obstruction has yet been packaged. The FARP investigation's
minimal `farp.miz` is a different test and does not reproduce this issue.
