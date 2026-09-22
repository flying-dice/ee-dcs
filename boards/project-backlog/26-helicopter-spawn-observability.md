---
column: doing
labels: [bug, backend]
priority: high
agent: codex
live: true
status: Authored-FARP workaround implemented and offline verified; generated campaign acceptance pending
updatedAt: 2026-09-21T23:25:00.000Z
---
# Diagnose missing helicopter groups (GitHub #3)

[Issue #3](https://github.com/flying-dice/ee-dcs/issues/3) concerns groups already
submitted to DCS; keep card 08's first-cycle scheduling race separate.

## Checklist

- [x] Trace the two named RED sections to dynamic FARPs in the full local log
- [x] Preserve builders' hot-start request in the shared FARP adapter
- [x] Add debug-gated submission, API result, unit samples and lifecycle events
- [x] Fault-inject API/query failures, empty/partial/delayed materialisation and disappearance
- [x] Verify campaign parity at 310 and 2100 seconds
- [x] Complete review and final checks
- [x] Prove initial and recycled dynamic AH-64D pairs fly at the same authored FARP
- [x] Repeat identical aircraft specification at fresh runtime FARP and retain failure evidence
- [x] Bake stock FARPs and ID-linked warehouses into generated missions
- [x] Retain ED report, minimal mission, scripts and detailed workarounds under dcs-bugs/
- [ ] Live-verify RED Mi-24V and BLUE AH-64D visibility, takeoff and CAS/BAI

## Comments


- **codex** (2026-09-21T23:10:00.000Z): Claimed issue #3. Local `DCS.openbeta/Logs/dcs.log` lines 1837–1845 identify both reported RED sections as dynamic-FARP launches (`ground_start=false`). Corrected the unconditional cold-start override in packages/ee-mission/src/farp_parking.ts:56 and added protected, bounded real-API observations in packages/ee-mission/src/spawn_diagnostics.ts:1 and packages/ee-mission/src/spawn_queue.ts:150. Regression coverage lives in packages/ee-mission/test/spawn-diagnostics.lua:1, packages/ee-mission/test/campaign-smoke.lua:447 and packages/ee-mission/test/run-tests.cjs:1. Build, 27 core checks, fault-injection tests and both campaign golden comparisons pass. This proves a start-mode correction, not the live root cause; DCS Studio localhost endpoint refuses connections.
- **codex** (2026-09-21T23:15:00.000Z): Eight-principle clean-code review and feature correctness review found no blocking introduced issues. Added successful FARP parking serialization and observer-registration/scheduling failure cases in packages/ee-mission/test/spawn-diagnostics.lua:135 after review highlighted that gap. Rebuilt full suite passes: 27 core checks, engine-boundary fault tests and exact campaign golden comparisons at 310/2100 seconds. Corrected premature `spawned` wording in packages/ee-mission/src/heli_war.ts:268 and :430. Updated docs/bots/decisions/0006-use-stock-four-position-farps.md:40, documented the live procedure in docs/bots/helicopter-spawn-diagnostics.md:1 and refreshed STATUS.md:4. Production diagnostic/adapter formatting and lint pass; the test runner retains its pre-existing unused `toleranceFor` warning. DCS Studio `check` and live acceptance remain unavailable. No commit or push; concurrent unrelated checkout edits preserved.
- **lead** (2026-09-21T23:25:00.000Z): User enabled live DCS and requested team leadership. Instrumented generation 2 proves original hot FARP groups vanish by +1 second; cold/simple-route controls also fail, while airborne and Kutaisi controls work. Existing-but-inactive controls are not successes. Assigned bounded live investigation to senior-developer and active-state tests to developer; see docs/bots/sprints/2026-09-22-sprint-03.md:1. Added activation logging in packages/ee-mission/src/spawn_diagnostics.ts:60; developer verified inactive/query-error cases in packages/ee-mission/test/spawn-diagnostics.lua:1 and full offline suite passes. Live evidence matrix is in docs/bots/helicopter-spawn-diagnostics.md:3. Final departure fix still pending.
