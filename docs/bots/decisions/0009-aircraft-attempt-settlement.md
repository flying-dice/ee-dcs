# 0009 — Aircraft submission attempts: settlement, refund routing and registry placement

Date: 2026-09-22. Status: accepted. Context: epic #17 package P1 (sprint 04).

## Context

`spawn_queue` defers every `coalition.addGroup` and returns a lazy proxy, so
`task_board.try_assign` committed a ledger debit, an ASSIGNED state and a keysite slot
before the real API had ever been called. A drain-time nil/throw was logged and never
reported back. P1 introduces `aircraft_lifecycle.ts`: an `AircraftAllocation` (the debit
facts) owning one-to-many `AircraftAttempt` records (the physical submissions).

Three questions had no EECH answer and needed a Lead call.

## Decision

**1. "Unknown is not failed" is the settlement rule.** Only `failed_no_creation`
(API returned nil or threw, no BIRTH correlated, no group visible, existence query
succeeded) and `cancelled` refund. A throw *after* a BIRTH, a partial group, or a failed
existence query resolve to `ambiguous`: no refund, no respawn, and the attempt stays
visible in `unresolved()`. Rationale: a double-spawn or a phantom refund corrupts the
ledger permanently, whereas an unresolved attempt is merely visible. This mirrors
`assign.c:245-296` / `assign.c:524-620`, where every side effect is gated on success and a
failed assignment simply commits nothing.

**2. Retry rides the existing assignment mechanism.** `unassign()` restores `UNASSIGNED`,
restores the `board:<id>` dedup marker and re-lists the task; `tick()`/`ASSIGN_CADENCE`
and the existing expiry then retry it. No new timer, no new cadence, no new constant.
Sourced: `ts_msgs.c:128-152` (re-link to `LIST_TYPE_UNASSIGNED_TASK`) and
`ts_updt.c:99-124`, where the UNASSIGNED `expire_timer` *is* the retry window —
verified by Lead against `E:\eech_source_code`.

**3. A refund whose launch base changed hands credits the allocating SIDE, not the base.**
`recycle_side(side)` rather than `recycle_base(captured base)`. There is **no EECH
precedent** — the C cannot reach this state, because it has no deferred-submission window
for a base to be captured inside. Losing the credit silently was the alternative and is
rejected: it leaks inventory and breaks the per-role conservation invariant the epic
requires (`initial idle = current idle + allocated + confirmed losses`). This is a
**DCS-only proxy for a state EECH cannot enter**, documented as such in the module header —
it is not a tuned value and must not be cited as precedent for inventing others.

**4. Late BIRTH is an accepted, documented divergence.** Proof of failure is synchronous:
BIRTH armed across the API call plus an immediate `Group.getByName`. A BIRTH arriving on a
later frame after a nil return would misclassify as proven failure. Closing that window
needs a settlement delay, and **no EECH value exists to source one from**, so none was
invented. Recorded in the module header. Revisit only with live DCS evidence that the
window is actually reachable (P5).

**5. The attempt registry is module-local, not on `S`.** This departs from the CLAUDE.md
"registries live on `S`" rule, because the records hold closures (`on_reverted`) and live
DCS handles, which are not serialisable — the same choice `spawn_diagnostics.ts` already
makes. Accepted because persistence is unbuilt and the generation fence already handles
re-injection. The *facts* are serialisable if persistence later needs them; the hook is not.

## Consequences

- Ambiguous attempts accumulate and are counted, not swept. If live testing (P5) shows them
  occurring in normal play, that is a finding about DCS, not a reason to start refunding them.
- P2/P3 inherit the allocation record, which carries exactly the facts that
  `supply.classify_role`'s group-name-prefix identity currently guesses at.
- The delayed-callback fence exists and is tested but has no production caller in P1 scope;
  P2/P3 are expected to use it.
