---
column: review
labels: [bug, backend]
priority: high
agent: codex
live: false
status: Implemented; tests/review pass; scoped live trial routes 23 groups and verifies movement
updatedAt: 2026-09-22T00:00:00.000Z
---
# Keep airbase grounds clear for aircraft

User observed `FP-Vaziani-2043` and `FP-Vaziani-2045` on the runway. The waiting
F-15C began taxiing after their authorized removal and subsequently took off;
untouched comparison jets remained stationary. See
[evidence](../../dcs-bugs/airbase-ground-obstructions/README.md).

## Scope

- Prevent generated ground units/statics from occupying airbase movement areas,
  using runway and parking geometry with a conservative fallback.
- Periodically scan airbases for movable AI ground groups inside the protected
  area and give them a safe waypoint out, as explicitly requested by the user.
- Avoid route-reset loops; protect aircraft/player control, clean scheduler state
  on reset, and retain bounded diagnostic evidence of detection/order/clearance.
- Do not silently spawn or direct groups into unsafe fallback positions.

## Acceptance

- [x] Demonstrate obstruction/removal/taxi/takeoff causal sequence at Vaziani
- [x] Shared geometry guards relevant generated ground placement paths
- [x] Active loop issues safe exit routes without repeated retasking
- [x] Regression tests cover geometry, safe exit, exclusions and reset lifecycle
- [x] Mission suite passes; frozen baselines retained alongside real-clearance integration
- [x] Scoped live loop trial routes 23 groups and confirms physical movement without route churn
- [ ] Full outside-envelope clearance and fresh production mission startup

Owner: senior-developer / airbase_clearance (GPT-5.6-Sol, non-Astra).
