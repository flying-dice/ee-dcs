---
column: backlog
labels: [bug, backend]
priority: med
updatedAt: 2026-09-21T19:05:00.000Z
---
# task_board first assignment pass should be a random stagger, not a fixed offset

> **Paths re-pointed 2026-09-21.** The Lua baseline was deleted; port modules below name their
> `packages/ee-mission/src/*.ts` counterparts. **Line numbers were taken against the Lua tree**
> and will not map exactly — locate by symbol, or read the original with
> `git show <pre-deletion-commit>:Scripts/ee-dcs/<module>.lua`. EECH C-source citations are
> unaffected.


Found during the sprint-02 port validation. **Neither tree matches EECH** on the task board's *first*
assignment pass. The recurring cadence is correct in both (180 s).

EECH sets the first timer per keysite to a uniform random draw, and only *subsequent* intervals to
the full cadence:

```c
raw->assign_timer = frand1 () * KEYSITE_TASK_ASSIGN_TIMER;  // ks_creat.c:166 - FIRST pass
raw->assign_timer = KEYSITE_TASK_ASSIGN_TIMER;              // ks_updt.c:118  - subsequent
#define KEYSITE_TASK_ASSIGN_TIMER (3.0 * ONE_MINUTE)        // keysite.h:69
```

So EECH's first pass is uniform in [0, 180) per keysite, mean 90 s.

| | first pass | faithful? |
|---|---|---|
| Lua `task_board.ts:594` | `ASSIGN_CADENCE` (180) | No - hardcodes the maximum |
| TS `task_board.ts:590` (before sprint 02) | `45` (invented) | No - tuned by feel; **removed, see below** |
| EECH `ks_creat.c:166` | `frand1() * 180`, per keysite | - |

## What sprint 02 already did

The TS tree carried `INITIAL_ASSIGNMENT_DELAY_SECONDS = 45` with a self-admitting comment
("*made a healthy rotary campaign look empty*"). That is a tuned-by-feel constant of exactly the kind
CLAUDE.md's PRIME DIRECTIVE calls a latent bug, and it was a genuine **port regression** - it made the
TS tree fire the board twice in a 310 s window where Lua fired once, spawning an extra helicopter CAS
section. It was removed and the first fire aligned to `ASSIGN_CADENCE`, restoring lua/ts parity.

That was deliberately the *narrow* fix: it removes an invented number without inventing a replacement.
Both trees are now consistently unfaithful rather than inconsistently unfaithful. This card closes the
remaining gap.

## Options

- **(a) Random stagger in [0, ASSIGN_CADENCE)** - literally what `ks_creat.c:166` does. Most faithful.
  Introduces run-to-run nondeterminism, so `packages/ee-mission/test/campaign-smoke.lua` would need a
  seeded RNG to stay comparable. Note EECH is nondeterministic here *by design*.
- **(b) `ASSIGN_CADENCE / 2` (90 s)** - the expected value of the C's distribution, documented as the
  proxy for EECH's per-keysite stagger given the port collapses those into one global pass
  (`task_board.ts:52-56`). Deterministic, but 90 is still a number that does not appear in the C.

Recommend (a) with a seeded harness: the PRIME DIRECTIVE measures fidelity against the C, and the
determinism objection is a *test* problem with a standard test solution.

## Important context - do not "fix" this by reintroducing 45

The removed constant's comment shows it was a band-aid over a different defect: the rotary campaign
looks empty at start because CAS fires before its targets exist. That is **card 08**
(spawn-queue race), and it has its own root cause and fix. Shortening this offset masks the symptom
and corrupts the assignment cadence. Fix card 08 on its own terms.

## Checklist

- [ ] Pick (a) or (b); record as an ADR in `docs/bots/decisions/`
- [ ] Apply to whichever tree survives the Lua deprecation (card 10)
- [ ] If (a): seed the RNG in the smoke harness so the differential comparison stays deterministic
- [ ] Cite `ks_creat.c:166` + `ks_updt.c:118` + `keysite.h:69` at the constant
- [ ] Confirm the differential suite still passes

## Comments

- **claude** (2026-09-21T19:05:00.000Z): Raised from sprint 02. The regression itself (TS `45`) is already fixed and verified - tick counts went from 413 vs 414 to 413 vs 413, and 2761 vs 2762 to 2761 vs 2761, with the spurious `Heli-CAS-2` gone. What remains is that both trees hardcode the *maximum* of EECH's distribution rather than sampling it. Lower priority than the cards it sits near because the behavioural effect is one delayed first pass, not an ongoing cadence error - but it is a real citation gap and the investigation that produced it is already written down here.
