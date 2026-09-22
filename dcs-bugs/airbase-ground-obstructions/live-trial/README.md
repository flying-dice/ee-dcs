# Scoped cleanup live trial — 22 September 2026

This folder retains the **non-production** payload used for one authorized active-cleanup trial in the already-running Caucasus campaign. It is not the campaign bundle and must not replace `dist/ee-dcs.lua` in a mission archive. The current mission did **not** reload, and this trial does not validate a freshly generated mission running the final production bundle from boot.

`build_trial.py` extracts only the compiled `lualib_bundle`, `sides`, `campaign_state`, `airbase_clearance`, and `airbase_cleanup` factories. It replaces the **single** compiled campaign-state generation increment with an assertion that the generation remains equal to the value captured before load. It replaces the entry point with a call to `airbase_cleanup.schedule()` exactly once, guarded by `_G.__airbase_clearance_trial_scheduled`. No `index`, `main`, or `reset` module is required or executed. The extracted `campaign_state` has its own state table; the cleanup and clearance modules use only its generation and geometry helpers. `payload.json` records the original compiled-bundle and exact trial-payload SHA-256 values.

Offline checks before injection: builder asserted selected module markers, one generation edit, and the top-level dependency closure; Lua 5.1 `loadfile` and a stubbed load verified one timer registration and unchanged `_DMT_GEN=7`. The trial payload was then SHA-256 checked against `payload.json` immediately before its JSON-RPC `eval` submission. Live RPC returned `{generation=1, scheduled_at=3021.5}`. A later read reported generation 1 and the same single scheduler marker. The live campaign's generation did not advance.

## Baseline and bounded observations

At mission **t=3012.4 s** before injection, the trial marker was absent. Candidate ground groups `FP-Tbilisi-Lo-2072`, `FP-Beslan-2083`, `FP-Vaziani-2044`, and `FP-Vaziani-2046` all existed with zero velocity. The two previously removed Vaziani obstruction groups were not restored or recreated.

The first scheduled sweep, about **t=3051.5 s**, logged `detected=23 routed=23 cleared=0 failed=0`. Routed groups included infantry, air-defense, patrol, and one ground-column group at Tbilisi-Lochini, Vaziani, and Beslan. The four named candidates received safe destinations several kilometres outside their airfield envelopes. No group was created or destroyed by this trial; the loop set movement tasks on existing AI ground groups.

| Group | Position before trial (x,z), t=3012.4 | Position and velocity at t=3080.9 | Position and velocity at t=3129.9 |
| --- | --- | --- | --- |
| `FP-Tbilisi-Lo-2072` | (-315211.48, 895347.68), 0 | (-315107.53, 895387.67), (3.83, 1.16) m/s | (-314923.97, 895456.35), (3.74, 1.41) m/s |
| `FP-Beslan-2083` | (-149367.66, 843445.25), 0 | (-149258.21, 843426.52), (3.94, -0.67) m/s | (-149065.02, 843393.46), (3.94, -0.67) m/s |
| `FP-Vaziani-2044` | (-318711.00, 901723.31), 0 | (-318599.84, 901724.12), (4.00, 0.03) m/s | (-318403.85, 901725.53), (4.00, 0.03) m/s |
| `FP-Vaziani-2046` | (-318742.13, 902322.31), 0 | (-318630.71, 902325.32), (4.00, 0.11) m/s | (-318434.78, 902330.62), (4.00, 0.11) m/s |

At t=3120.2 s, after the next two expected 30-second scan times, generation was still 1 and the trial marker remained set. No new `routed`, `stalled`, `failed`, or `cleared` line appeared; routine sweeps log a summary only when one of those outcomes occurs. The moving groups' positions at t=3129.9 confirm that their route tasks continued to drive physical motion. These observations prove route assignment and sustained movement, **not** complete clearance of the several-kilometre envelope; no `cleared` event was yet observed. The authorized active loop remains scheduled in this mission after the bounded observation.
