---
column: backlog
labels: [bug, backend]
priority: high
updatedAt: 2026-09-21T19:55:00.000Z
---
# Live-validate the restored SEAD and BAI generators

Sprint 02 found that **the SEAD and BAI task generators were silently dead in the TypeScript port**
and fixed them. That is a significant behavioural restoration which no offline test can fully
validate, and it has never run in a live DCS mission.

## What was broken

12 sites across `packages/ee-mission/src/{cas_bai_sead,supply,supply_flight,troop}.ts` tested
`string.match(name, pattern) !== undefined`. TSTL types `string.match` as a LuaMultiReturn, and used
directly in an expression it compiles to a **table constructor** — `({string.match(n, p)})` — which
is never nil. So every such test was **always true** and every `=== undefined` test always false.

Consequences in the shipping TS bundle:

- `groupFlag()` classified **every** ground group as `FRONTLINE_FLAG_PRIMARY`.
- `aaTargets()` therefore returned **0 targets on every pass** — SEAD and BAI generated nothing, ever.
- `supply.ts` `classify_role` / `classify_group` always returned the **first** `PREFIX_ROLES` entry's
  role, so RTB recycling credited the wrong reserve pool.

Fixed with a documented `matches()` helper per file that destructures to force the single-value form.
Offline evidence: golden-vs-typescript now clean at 310 s and 2100 s.

## Why this needs live validation

The offline harness compares **spawned group/static names and tick counts**. It did not catch a dead
generator for however long the bug existed, because the orphaned tasks expired without ever spawning
anything. Parity with the baseline is necessary but not sufficient here — two generators that
previously produced nothing now produce sorties, and their live behaviour (payloads, routing, target
selection against real DCS AA units, board contention) is unexercised.

## Checklist

- [ ] Run `check` (DCS Studio static analysis) once Studio is reachable
- [ ] Live-inject and confirm SEAD sorties are generated, assigned, and engage real AA
- [ ] Confirm BAI sorties target SECONDARY/ARTILLERY echelon groups, not PRIMARY (`highlevl.c:637` vs `:877`)
- [ ] Confirm reserve accounting is correct now that `classify_role` returns real roles — watch for pools drifting
- [ ] Multi-hour soak per the `live-validation` skill
- [ ] Add board-task creation counts to the harness `SUMMARY_JSON` so a dead generator fails the suite in future

## Comments

- **claude** (2026-09-21T19:55:00.000Z): Raised from sprint 02. The last checklist item is the durable lesson — the regression net proved its worth twice today, but this bug slipped past it because the net measures spawns, not task creation. A generator that creates tasks which never spawn is invisible to it. Worth closing that blind spot before trusting the net further.
